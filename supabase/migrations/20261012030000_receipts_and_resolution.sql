create table private.sessions (
    session_id uuid primary key default pg_catalog.gen_random_uuid(),
    user_id uuid not null references auth.users (id) on delete cascade,
    starts_at timestamptz not null,
    expires_at timestamptz not null check (expires_at > starts_at),
    stopped_at timestamptz check (stopped_at >= starts_at)
);

create index sessions_owner_window_idx on private.sessions (user_id, starts_at, expires_at);

create table private.encounter_candidates (
    nonce_digest bytea not null check (pg_catalog.octet_length(nonce_digest) = 32),
    uploader_id uuid not null references auth.users (id) on delete cascade,
    receipt_id uuid not null,
    peer_id uuid not null references auth.users (id) on delete cascade,
    protocol_version smallint not null check (protocol_version = 1),
    role text not null check (role in ('central', 'peripheral')),
    prior_nonce_digest bytea check (pg_catalog.octet_length(prior_nonce_digest) = 32),
    start_own_token_digest bytea not null check (pg_catalog.octet_length(start_own_token_digest) = 32),
    start_peer_token_digest bytea not null check (pg_catalog.octet_length(start_peer_token_digest) = 32),
    start_observed_at bigint not null,
    checkpoint_own_token_digest bytea check (pg_catalog.octet_length(checkpoint_own_token_digest) = 32),
    checkpoint_peer_token_digest bytea check (pg_catalog.octet_length(checkpoint_peer_token_digest) = 32),
    checkpoint_observed_at bigint,
    observed_duration bigint not null check (observed_duration >= 0),
    session_flag boolean not null,
    is_final_evidence boolean not null,
    first_uploaded_at timestamptz not null,
    expires_at timestamptz not null,
    primary key (nonce_digest, uploader_id),
    unique (uploader_id, receipt_id),
    check (uploader_id <> peer_id),
    check (start_own_token_digest <> start_peer_token_digest),
    check (prior_nonce_digest is null or prior_nonce_digest <> nonce_digest),
    check ((checkpoint_own_token_digest is null and checkpoint_peer_token_digest is null and checkpoint_observed_at is null)
        or (checkpoint_own_token_digest is not null and checkpoint_peer_token_digest is not null and checkpoint_observed_at is not null)),
    check (expires_at <= first_uploaded_at + interval '48 hours'
        and expires_at <= pg_catalog.to_timestamp(start_observed_at::double precision) + interval '48 hours')
);

create index encounter_candidates_expiry_idx on private.encounter_candidates (expires_at);
create index encounter_candidates_pair_idx on private.encounter_candidates (uploader_id, peer_id);
create index encounter_candidates_prior_idx on private.encounter_candidates (prior_nonce_digest);

-- A date represents a UTC midnight, with no participant or confirmation time.
create table private.consumed_nonces (
    exchange_digest bytea primary key check (pg_catalog.octet_length(exchange_digest) = 32),
    delete_after date not null
);

create index consumed_nonces_delete_after_idx on private.consumed_nonces (delete_after);

create table private.encounters (
    encounter_id uuid primary key default pg_catalog.gen_random_uuid(),
    user_a uuid not null references auth.users (id) on delete cascade,
    user_b uuid not null references auth.users (id) on delete cascade,
    kind text not null check (kind in ('ambient', 'session', 'qr')),
    day_a date not null,
    day_b date not null,
    check (user_a < user_b),
    unique (user_a, user_b, kind, day_a, day_b)
);

create index encounters_user_a_day_idx on private.encounters (user_a, day_a);
create index encounters_user_b_day_idx on private.encounters (user_b, day_b);

create table private.encounter_views (
    encounter_id uuid not null references private.encounters (encounter_id) on delete cascade,
    viewer_id uuid not null references auth.users (id) on delete cascade,
    revealed boolean not null,
    reveal_report_day date not null,
    favorite boolean not null default false,
    primary key (encounter_id, viewer_id)
);

create index encounter_views_viewer_idx on private.encounter_views (viewer_id, reveal_report_day);

alter table private.sessions enable row level security;
alter table private.encounter_candidates enable row level security;
alter table private.consumed_nonces enable row level security;
alter table private.encounters enable row level security;
alter table private.encounter_views enable row level security;

revoke all on table private.sessions, private.encounter_candidates, private.consumed_nonces,
    private.encounters, private.encounter_views from public, anon, authenticated;

-- Bind replay protection to the exchange's reciprocal start tokens, not to a
-- client-chosen nonce alone. Fixed-width digests make concatenation unambiguous.
create function private.receipt_exchange_digest(nonce_hash bytea, token_a_hash bytea, token_b_hash bytea)
returns bytea
language sql
immutable
strict
set search_path = ''
as $$
    select pg_catalog.sha256(nonce_hash || least(token_a_hash, token_b_hash)
        || greatest(token_a_hash, token_b_hash));
$$;

revoke all on function private.receipt_exchange_digest(bytea, bytea, bytea)
    from public, anon, authenticated, service_role;

create function public.submit_receipts(receipts jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    caller uuid := private.require_caller();
    server_time timestamptz := pg_catalog.now();
    server_seconds numeric := extract(epoch from pg_catalog.now());
    utc_day date := (pg_catalog.now() at time zone 'UTC')::date;
    nonce_deadline date;
    item jsonb;
    pair jsonb;
    submitted_id uuid;
    nonce bytea;
    prior_nonce bytea;
    own_digest bytea;
    peer_digest bytea;
    checkpoint_own bytea;
    checkpoint_peer bytea;
    start_seconds bigint;
    checkpoint_seconds bigint;
    duration_seconds bigint;
    own_token private.temporary_tokens%rowtype;
    peer_token private.temporary_tokens%rowtype;
    peer uuid;
    old_candidate private.encounter_candidates%rowtype;
    a private.encounter_candidates%rowtype;
    b private.encounter_candidates%rowtype;
    original_a private.encounter_candidates%rowtype;
    original_b private.encounter_candidates%rowtype;
    invalid_shape boolean;
    invalid_owner boolean;
    invalid_window boolean;
    status text;
    acknowledgements jsonb := '[]'::jsonb;
    accepted_nonces bytea[] := '{}'::bytea[];
    resolved_ids uuid[] := '{}'::uuid[];
    removed_exchanges bytea[];
    matched_ids uuid[];
    lock_key bigint;
    pair_key integer;
    encounter_kind text;
    original_pair_found boolean;
    observation_a bigint;
    observation_b bigint;
    ordered_a uuid;
    ordered_b uuid;
    encounter_day_a date;
    encounter_day_b date;
    new_encounter uuid;
    viewer uuid;
    viewer_observation bigint;
    viewer_zone text;
    viewer_report_hour integer;
    viewer_report_minute integer;
    local_now timestamp;
    report_day date;
begin
    if not private.account_is_ready(caller) then
        perform private.raise_error('account_not_ready');
    end if;
    if pg_catalog.jsonb_typeof(receipts) is distinct from 'array' then
        perform private.raise_error('invalid_input', array['receipts']);
    end if;
    if pg_catalog.jsonb_array_length(receipts) not between 1 and 50 then
        perform private.raise_error('invalid_input', array['receipts']);
    end if;
    -- An object and a UUID identity are necessary to return an acknowledgement.
    if exists (
        select 1 from pg_catalog.jsonb_array_elements(receipts) as r(value)
        where pg_catalog.jsonb_typeof(r.value) is distinct from 'object'
           or pg_catalog.jsonb_typeof(r.value->'id') is distinct from 'string'
           or coalesce(r.value->>'id', '') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    ) then
        perform private.raise_error('invalid_input', array['receipts']);
    end if;
    -- Take the account lock before sorted nonce locks, then sorted pair locks.
    -- Namespace 31001 (two integers) is disjoint from bigint nonce lock keys.
    perform pg_catalog.pg_advisory_xact_lock(31001, pg_catalog.hashtext(caller::text));
    if private.record_account_event(caller, 'submit_receipts', 60, interval '1 minute') then
        perform private.raise_error('rate_limited');
    end if;

    -- Lock every named exchange/prior digest in one sorted lock-key order before
    -- touching candidates. Concurrent reciprocal uploads therefore see each
    -- other's committed half, and only one transaction can consume a nonce.
    -- Hash collisions merely serialize extra work; sorting the actual keys also
    -- avoids collision-induced lock-order inversions. pgTAP is single-session.
    for lock_key in
        select distinct pg_catalog.hashtextextended(pg_catalog.encode(pg_catalog.sha256(pg_catalog.decode(case when n.value ~ '^[0-9a-f]{32}$' then n.value else '' end, 'hex')), 'hex'), 0)
        from pg_catalog.jsonb_array_elements(receipts) as r(value)
        cross join lateral (values (r.value->>'exchange_nonce'), (r.value->>'prior_exchange_nonce')) as n(value)
        where n.value ~ '^[0-9a-f]{32}$'
        order by 1
    loop
        perform pg_catalog.pg_advisory_xact_lock(lock_key);
    end loop;
    -- Pair locks (in the separate two-integer advisory namespace) also serialize
    -- different exchanges of one pair while their matched evidence is removed.
    -- Derive pairs solely from live server token ownership, never client IDs.
    for pair_key in
        select distinct pg_catalog.hashtext(least(caller, t.user_id)::text || ':' || greatest(caller, t.user_id)::text)
        from pg_catalog.jsonb_array_elements(receipts) as r(value)
        join private.temporary_tokens as t
          on t.token_digest = pg_catalog.sha256(pg_catalog.decode(
              case when r.value->'start'->>'peer_token' ~ '^[0-9a-f]{32}$' then r.value->'start'->>'peer_token' else '' end, 'hex'))
         and t.delete_after > server_seconds
        where t.user_id <> caller
        order by 1
    loop
        perform pg_catalog.pg_advisory_xact_lock(31003, pair_key);
    end loop;

    -- Store the entire call before resolving, including joined-before-original.
    for item in select r.value from pg_catalog.jsonb_array_elements(receipts) as r(value) loop
        submitted_id := (item->>'id')::uuid;
        status := 'rejected';
        nonce := null;
        prior_nonce := null;
        checkpoint_own := null;
        checkpoint_peer := null;
        checkpoint_seconds := null;
        invalid_shape := false;
        if not (item ?& array['id', 'protocol_version', 'role', 'exchange_nonce', 'start', 'observed_duration', 'session_flag', 'is_final_evidence'])
            or exists (select 1 from pg_catalog.jsonb_object_keys(item) as k(value)
                where k.value <> all(array['id', 'protocol_version', 'role', 'exchange_nonce', 'prior_exchange_nonce', 'start', 'checkpoint', 'observed_duration', 'session_flag', 'is_final_evidence']))
            or item->'protocol_version' is distinct from '1'::jsonb
            or pg_catalog.jsonb_typeof(item->'role') is distinct from 'string'
            or coalesce(item->>'role', '') not in ('central', 'peripheral')
            or pg_catalog.jsonb_typeof(item->'exchange_nonce') is distinct from 'string'
            or coalesce(item->>'exchange_nonce', '') !~ '^[0-9a-f]{32}$'
            or (coalesce(item->'prior_exchange_nonce', 'null'::jsonb) <> 'null'::jsonb
                and (pg_catalog.jsonb_typeof(item->'prior_exchange_nonce') <> 'string'
                    or item->>'prior_exchange_nonce' !~ '^[0-9a-f]{32}$'
                    or item->>'prior_exchange_nonce' = item->>'exchange_nonce'))
            or pg_catalog.jsonb_typeof(item->'observed_duration') is distinct from 'number'
            or coalesce(item->>'observed_duration', '') !~ '^[0-9]{1,16}$'
            or pg_catalog.jsonb_typeof(item->'session_flag') is distinct from 'boolean'
            or pg_catalog.jsonb_typeof(item->'is_final_evidence') is distinct from 'boolean' then
            invalid_shape := true;
        end if;
        if not invalid_shape then
            if (item->>'observed_duration')::numeric >= 9007199254740992 then
                invalid_shape := true;
            end if;
        end if;
        for pair in select item->'start' union all
            select item->'checkpoint' where coalesce(item->'checkpoint', 'null'::jsonb) <> 'null'::jsonb
        loop
            if pg_catalog.jsonb_typeof(pair) is distinct from 'object' then
                invalid_shape := true;
                continue;
            end if;
            if not (pair ?& array['own_token', 'peer_token', 'observed_at'])
                or (select pg_catalog.count(*) from pg_catalog.jsonb_object_keys(pair)) <> 3
                or pg_catalog.jsonb_typeof(pair->'own_token') is distinct from 'string'
                or coalesce(pair->>'own_token', '') !~ '^[0-9a-f]{32}$'
                or pg_catalog.jsonb_typeof(pair->'peer_token') is distinct from 'string'
                or coalesce(pair->>'peer_token', '') !~ '^[0-9a-f]{32}$'
                or pg_catalog.jsonb_typeof(pair->'observed_at') is distinct from 'number'
                or coalesce(pair->>'observed_at', '') !~ '^-?[0-9]{1,16}$' then
                invalid_shape := true;
            elsif pg_catalog.abs((pair->>'observed_at')::numeric) >= 9007199254740992 then
                invalid_shape := true;
            end if;
        end loop;
        if not invalid_shape then
            nonce := pg_catalog.sha256(pg_catalog.decode(item->>'exchange_nonce', 'hex'));
            if coalesce(item->'prior_exchange_nonce', 'null'::jsonb) <> 'null'::jsonb then
                prior_nonce := pg_catalog.sha256(pg_catalog.decode(item->>'prior_exchange_nonce', 'hex'));
            end if;
            own_digest := pg_catalog.sha256(pg_catalog.decode(item->'start'->>'own_token', 'hex'));
            peer_digest := pg_catalog.sha256(pg_catalog.decode(item->'start'->>'peer_token', 'hex'));
            start_seconds := (item->'start'->>'observed_at')::bigint;
            duration_seconds := (item->>'observed_duration')::bigint;
            invalid_owner := false;
            invalid_window := false;
            peer := null;
            -- Ownership checks for both pairs precede every window check.
            for pair in select item->'start' union all
                select item->'checkpoint' where coalesce(item->'checkpoint', 'null'::jsonb) <> 'null'::jsonb
            loop
                select t.* into own_token from private.temporary_tokens as t
                where t.token_digest = pg_catalog.sha256(pg_catalog.decode(pair->>'own_token', 'hex'))
                  and t.delete_after > server_seconds;
                select t.* into peer_token from private.temporary_tokens as t
                where t.token_digest = pg_catalog.sha256(pg_catalog.decode(pair->>'peer_token', 'hex'))
                  and t.delete_after > server_seconds;
                if own_token.user_id is distinct from caller or peer_token.user_id is null
                    or peer_token.user_id = caller then
                    invalid_owner := true;
                end if;
                peer := coalesce(peer, peer_token.user_id);
                if not coalesce(own_token.valid_from <= (pair->>'observed_at')::bigint
                    and (pair->>'observed_at')::bigint < own_token.valid_until
                    and peer_token.valid_from <= (pair->>'observed_at')::bigint
                    and (pair->>'observed_at')::bigint < peer_token.valid_until, false) then
                    invalid_window := true;
                end if;
            end loop;
            if not invalid_owner and not invalid_window then
                if start_seconds > server_seconds + 300 then
                    status := 'rejected';
                elsif start_seconds <= server_seconds - 172800 then
                    status := 'expired';
                elsif exists (select 1 from private.consumed_nonces as n
                    where n.exchange_digest in (
                        private.receipt_exchange_digest(nonce, own_digest, peer_digest),
                        private.receipt_exchange_digest(prior_nonce, own_digest, peer_digest))
                      and n.delete_after > utc_day) then
                    status := 'consumed';
                elsif exists (select 1 from private.encounter_candidates as c
                    where c.nonce_digest = nonce and c.uploader_id = caller and c.expires_at <= server_time) then
                    status := 'expired';
                else
                    select c.* into old_candidate from private.encounter_candidates as c
                    where c.nonce_digest = nonce and c.uploader_id = caller and c.expires_at > server_time;
                    if (old_candidate.uploader_id is not null and (
                        old_candidate.receipt_id <> submitted_id
                        or old_candidate.protocol_version <> 1
                        or old_candidate.role <> item->>'role'
                        or old_candidate.prior_nonce_digest is distinct from prior_nonce
                        or old_candidate.start_own_token_digest <> own_digest
                        or old_candidate.start_peer_token_digest <> peer_digest
                        or old_candidate.start_observed_at <> start_seconds))
                        or exists (select 1 from private.encounter_candidates as c
                            where c.uploader_id = caller and c.receipt_id = submitted_id
                              and c.nonce_digest <> nonce and c.expires_at > server_time - interval '300 seconds') then
                        status := 'rejected';
                    else
                        if coalesce(item->'checkpoint', 'null'::jsonb) <> 'null'::jsonb then
                            checkpoint_own := pg_catalog.sha256(pg_catalog.decode(item->'checkpoint'->>'own_token', 'hex'));
                            checkpoint_peer := pg_catalog.sha256(pg_catalog.decode(item->'checkpoint'->>'peer_token', 'hex'));
                            checkpoint_seconds := (item->'checkpoint'->>'observed_at')::bigint;
                        end if;
                        -- Expired rows cannot authorize or count against the cap; retain their
                        -- expired response for the 300-second observation-skew grace.
                        delete from private.encounter_candidates as c
                        where c.uploader_id = caller and c.expires_at <= server_time - interval '300 seconds';
                        if old_candidate.uploader_id is null and (select pg_catalog.count(*)
                            from private.encounter_candidates as c where c.uploader_id = caller and c.expires_at > server_time) >= 2000 then
                            status := 'candidate';
                            acknowledgements := acknowledgements || pg_catalog.jsonb_build_array(
                                pg_catalog.jsonb_build_object('id', submitted_id, 'status', status));
                            continue;
                        end if;
                        insert into private.encounter_candidates as c (
                            nonce_digest, uploader_id, receipt_id, peer_id, protocol_version, role, prior_nonce_digest,
                            start_own_token_digest, start_peer_token_digest, start_observed_at,
                            checkpoint_own_token_digest, checkpoint_peer_token_digest, checkpoint_observed_at,
                            observed_duration, session_flag, is_final_evidence, first_uploaded_at, expires_at
                        ) values (nonce, caller, submitted_id, peer, 1, item->>'role', prior_nonce,
                            own_digest, peer_digest, start_seconds, checkpoint_own, checkpoint_peer, checkpoint_seconds,
                            duration_seconds, (item->>'session_flag')::boolean, (item->>'is_final_evidence')::boolean,
                            server_time, least(server_time, pg_catalog.to_timestamp(start_seconds::double precision)) + interval '48 hours')
                        on conflict (nonce_digest, uploader_id) do update set
                            checkpoint_own_token_digest = excluded.checkpoint_own_token_digest,
                            checkpoint_peer_token_digest = excluded.checkpoint_peer_token_digest,
                            checkpoint_observed_at = excluded.checkpoint_observed_at,
                            observed_duration = excluded.observed_duration,
                            session_flag = excluded.session_flag,
                            is_final_evidence = excluded.is_final_evidence;
                        status := 'candidate';
                        accepted_nonces := pg_catalog.array_append(accepted_nonces, nonce);
                    end if;
                end if;
            end if;
        end if;
        acknowledgements := acknowledgements || pg_catalog.jsonb_build_array(
            pg_catalog.jsonb_build_object('id', submitted_id, 'status', status));
    end loop;

    -- Visit joined evidence as well when the newly uploaded half was an original.
    -- Only qualifying reciprocal pairs consume a resolution event.
    for nonce in
        select distinct c.nonce_digest from private.encounter_candidates as c
        where c.uploader_id = caller and c.expires_at > server_time
          and (c.nonce_digest = any(accepted_nonces) or c.prior_nonce_digest = any(accepted_nonces))
        order by c.nonce_digest
    loop
        select c.* into a from private.encounter_candidates as c
        where c.nonce_digest = nonce and c.uploader_id = caller and c.expires_at > server_time;
        if not found then continue; end if;
        if exists (select 1 from private.consumed_nonces as n
            where n.exchange_digest in (
                private.receipt_exchange_digest(nonce, a.start_own_token_digest, a.start_peer_token_digest),
                private.receipt_exchange_digest(a.prior_nonce_digest, a.start_own_token_digest, a.start_peer_token_digest))
              and n.delete_after > utc_day) then
            continue;
        end if;
        select c.* into b from private.encounter_candidates as c
        where c.nonce_digest = nonce and c.uploader_id = a.peer_id and c.peer_id = caller
          and c.expires_at > server_time and c.role <> a.role and c.protocol_version = a.protocol_version
          and c.prior_nonce_digest is not distinct from a.prior_nonce_digest
          and c.start_own_token_digest = a.start_peer_token_digest
          and c.start_peer_token_digest = a.start_own_token_digest;
        if not found then continue; end if;
        encounter_kind := null;
        observation_a := a.start_observed_at;
        observation_b := b.start_observed_at;
        original_pair_found := false;
        if a.prior_nonce_digest is not null then
            select c.* into original_a from private.encounter_candidates as c
            where c.nonce_digest = a.prior_nonce_digest and c.uploader_id = a.uploader_id
              and c.peer_id = b.uploader_id and c.expires_at > server_time
              and c.prior_nonce_digest is null and c.role = a.role and c.protocol_version = a.protocol_version;
            select c.* into original_b from private.encounter_candidates as c
            where c.nonce_digest = a.prior_nonce_digest and c.uploader_id = b.uploader_id
              and c.peer_id = a.uploader_id and c.expires_at > server_time
              and c.prior_nonce_digest is null and c.role = b.role and c.protocol_version = b.protocol_version;
            original_pair_found := original_a.uploader_id is not null and original_b.uploader_id is not null
                and original_a.start_own_token_digest = original_b.start_peer_token_digest
                and original_a.start_peer_token_digest = original_b.start_own_token_digest;
            if original_pair_found then
                observation_a := original_a.start_observed_at;
                observation_b := original_b.start_observed_at;
            end if;
        end if;
        -- Sessions require no original evidence. Use the first exchange dates
        -- when reciprocal originals exist; otherwise the matched starts are the
        -- only reported dates available. The final marker is never a gate.
        if a.session_flag and b.session_flag
            and exists (select 1 from private.sessions as s where s.user_id = a.uploader_id
                and s.starts_at <= pg_catalog.to_timestamp(a.start_observed_at::double precision)
                and s.expires_at > pg_catalog.to_timestamp(a.start_observed_at::double precision)
                and (s.stopped_at is null or s.stopped_at > pg_catalog.to_timestamp(a.start_observed_at::double precision)))
            and exists (select 1 from private.sessions as s where s.user_id = b.uploader_id
                and s.starts_at <= pg_catalog.to_timestamp(b.start_observed_at::double precision)
                and s.expires_at > pg_catalog.to_timestamp(b.start_observed_at::double precision)
                and (s.stopped_at is null or s.stopped_at > pg_catalog.to_timestamp(b.start_observed_at::double precision))) then
            encounter_kind := 'session';
        elsif a.observed_duration >= 120 and b.observed_duration >= 120 then
            if a.prior_nonce_digest is null
                and a.checkpoint_own_token_digest is not null and b.checkpoint_own_token_digest is not null
                and a.checkpoint_own_token_digest = b.checkpoint_peer_token_digest
                and a.checkpoint_peer_token_digest = b.checkpoint_own_token_digest then
                encounter_kind := 'ambient';
            elsif original_pair_found
                and a.start_observed_at - original_a.start_observed_at >= 120
                and b.start_observed_at - original_b.start_observed_at >= 120 then
                encounter_kind := 'ambient';
            end if;
        end if;
        if encounter_kind is null then continue; end if;
        -- Only qualifying pairs spend the resolution budget; refusal stores no event.
        if private.record_account_event(caller, 'resolve_receipts', 30, interval '1 minute') then
            continue;
        end if;

        if not exists (select 1 from private.blocks as blocked
            where (blocked.blocker_id = a.uploader_id and blocked.blocked_id = b.uploader_id)
               or (blocked.blocker_id = b.uploader_id and blocked.blocked_id = a.uploader_id)) then
            ordered_a := least(a.uploader_id, b.uploader_id);
            ordered_b := greatest(a.uploader_id, b.uploader_id);
            for viewer, viewer_observation in select a.uploader_id, observation_a union all select b.uploader_id, observation_b loop
                select n.time_zone into viewer_zone from private.notification_preferences as n where n.user_id = viewer;
                viewer_zone := coalesce(viewer_zone, 'UTC');
                if viewer = ordered_a then
                    encounter_day_a := (pg_catalog.to_timestamp(viewer_observation::double precision) at time zone viewer_zone)::date;
                else
                    encounter_day_b := (pg_catalog.to_timestamp(viewer_observation::double precision) at time zone viewer_zone)::date;
                end if;
            end loop;
            new_encounter := null;
            insert into private.encounters (user_a, user_b, kind, day_a, day_b)
            values (ordered_a, ordered_b, encounter_kind, encounter_day_a, encounter_day_b)
            on conflict (user_a, user_b, kind, day_a, day_b) do nothing
            returning encounter_id into new_encounter;
            -- A duplicate changes neither view nor reveal/favorite state.
            if new_encounter is not null then
                for viewer in select a.uploader_id union all select b.uploader_id loop
                    select n.time_zone, n.report_hour, n.report_minute into viewer_zone, viewer_report_hour, viewer_report_minute
                    from private.notification_preferences as n where n.user_id = viewer;
                    if not found then
                        viewer_zone := 'UTC'; viewer_report_hour := 21; viewer_report_minute := 0;
                    end if;
                    local_now := server_time at time zone viewer_zone;
                    report_day := local_now::date;
                    if local_now::time >= pg_catalog.make_time(viewer_report_hour, viewer_report_minute, 0) then
                        report_day := report_day + 1;
                    end if;
                    insert into private.encounter_views (encounter_id, viewer_id, revealed, reveal_report_day)
                    values (new_encounter, viewer, encounter_kind = 'session', report_day);
                end loop;
            end if;
        end if;

        -- First UTC midnight at least 48 hours plus skew grace after resolution.
        nonce_deadline := ((server_time at time zone 'UTC') + interval '48 hours 300 seconds')::date;
        if ((server_time at time zone 'UTC') + interval '48 hours 300 seconds')::time <> time '00:00:00' then
            nonce_deadline := nonce_deadline + 1;
        end if;
        -- Delete only matched receipts (and reciprocal originals when present),
        -- including a blocked resolution. Other dates/exchanges remain pending.
        with removed as (
            delete from private.encounter_candidates as c
            where c.uploader_id in (a.uploader_id, b.uploader_id)
              and (c.nonce_digest = nonce
                  or (original_pair_found and a.prior_nonce_digest is not null
                      and c.nonce_digest = a.prior_nonce_digest))
            returning c.uploader_id, c.receipt_id, c.nonce_digest,
                c.start_own_token_digest, c.start_peer_token_digest
        ) select pg_catalog.array_agg(distinct private.receipt_exchange_digest(
                     r.nonce_digest, r.start_own_token_digest, r.start_peer_token_digest)),
                 pg_catalog.array_agg(r.receipt_id) filter (where r.uploader_id = caller)
          into removed_exchanges, matched_ids
          from removed as r;
        insert into private.consumed_nonces as n (exchange_digest, delete_after)
        select distinct d.digest, nonce_deadline from pg_catalog.unnest(removed_exchanges) as d(digest)
        on conflict (exchange_digest) do update set delete_after = greatest(n.delete_after, excluded.delete_after);
        resolved_ids := resolved_ids || matched_ids;
    end loop;

    -- Only candidates accepted in this call can be upgraded to resolved.
    return (select pg_catalog.jsonb_agg(
        case when ack.value->>'status' = 'candidate' then
            case when (ack.value->>'id')::uuid = any(resolved_ids)
                then pg_catalog.jsonb_build_object('id', ack.value->'id', 'status', 'resolved')
                else ack.value end
            else ack.value end
        order by ack.ordinal)
        from pg_catalog.jsonb_array_elements(acknowledgements) with ordinality as ack(value, ordinal));
exception when foreign_key_violation then
    -- Account deletion may race validation once the shared helpers no longer
    -- lock Auth rows. Never return the participant UUID from a foreign-key error.
    perform private.raise_error('not_found');
    return null;
end;
$$;

revoke all on function public.submit_receipts(jsonb) from public, anon, authenticated, service_role;
grant execute on function public.submit_receipts(jsonb) to authenticated;
