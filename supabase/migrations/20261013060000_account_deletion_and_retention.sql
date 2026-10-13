create table private.deletion_safety_records (
    apple_id_hash bytea primary key check (pg_catalog.octet_length(apple_id_hash) = 32),
    operator_outcome text check (operator_outcome in ('dismissed', 'hidden', 'suspended')),
    delete_after bigint not null
);
create index deletion_safety_records_expiry_idx on private.deletion_safety_records (delete_after);
create table private.deletion_safety_blocks (
    apple_id_hash bytea not null references private.deletion_safety_records (apple_id_hash) on delete cascade,
    blocker_id uuid not null references auth.users (id) on delete cascade,
    block_id uuid not null unique,
    placed_day date not null,
    primary key (apple_id_hash, blocker_id)
);
create index deletion_safety_blocks_blocker_idx on private.deletion_safety_blocks (blocker_id);
create index reports_resolved_day_idx on private.reports (resolved_day) where status = 'resolved';
alter table private.deletion_safety_records enable row level security;
alter table private.deletion_safety_blocks enable row level security;
revoke all on table private.deletion_safety_records, private.deletion_safety_blocks
    from public, anon, authenticated, service_role;

-- Vault is platform-provisioned. This migration never provisions the key.
-- postgres has SELECT WITH GRANT OPTION on these managed Vault relations.
-- supabase_admin's platform grant to service_role cannot be revoked by postgres;
-- it remains an accepted limitation. The vault schema is not exposed by the Data API.
revoke select on table vault.secrets, vault.decrypted_secrets from public, anon, authenticated;
revoke select (decrypted_secret) on table vault.decrypted_secrets from public, anon, authenticated;

create function private.apple_safety_hash(account_id uuid)
returns bytea language plpgsql security definer set search_path = '' as $$
declare apple_provider_id text; safety_key text;
begin
    if account_id is null then perform private.raise_error('invalid_input', array['account_id']); end if;
    if not exists (select 1 from auth.users as u where u.id = account_id) then
        perform private.raise_error('not_authenticated');
    end if;
    -- Only managed Auth identity evidence is trusted, including for anonymous
    -- accounts whose client-controlled metadata claims an Apple identity.
    select i.provider_id into apple_provider_id from auth.identities as i
    where i.user_id = account_id and i.provider = 'apple' order by i.created_at, i.id limit 1;
    if not found then return null; end if;
    select s.decrypted_secret into safety_key from vault.decrypted_secrets as s
    where s.name = 'deletion_safety_hmac_key_v1';
    if safety_key is null or safety_key = '' then
        perform private.raise_error('prerequisite_missing', array['deletion_safety_key']);
    end if;
    return extensions.hmac(pg_catalog.convert_to('EEAPPLE1:apple:' || apple_provider_id, 'UTF8'),
        pg_catalog.convert_to(safety_key, 'UTF8'), 'sha256');
end;
$$;

-- Shared destructive portion of the block migration's pair-removal routine.
-- Callers take all account, nonce and pair locks before calling this overload.
-- A null peer removes all of this account's pairs, including hidden encounters
-- and candidate-only pairs. Tombstones contain scoped digests, never Auth IDs.
create function private.remove_encounter_pair(viewer_id uuid, peer_id uuid, input_encounter_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare deadline date;
begin
    deadline := ((pg_catalog.now() at time zone 'UTC') + interval '48 hours 300 seconds')::date;
    if ((pg_catalog.now() at time zone 'UTC') + interval '48 hours 300 seconds')::time <> time '00:00:00' then
        deadline := deadline + 1;
    end if;
    with removed as (
        delete from private.encounter_candidates as c
        where (c.uploader_id = viewer_id and ($2 is null or c.peer_id = $2))
           or (c.peer_id = viewer_id and ($2 is null or c.uploader_id = $2))
        returning c.nonce_digest, c.start_own_token_digest, c.start_peer_token_digest
    )
    insert into private.consumed_nonces as n (exchange_digest, delete_after)
    select distinct private.receipt_exchange_digest(r.nonce_digest,
        r.start_own_token_digest, r.start_peer_token_digest), deadline from removed as r
    on conflict (exchange_digest) do update set delete_after = greatest(n.delete_after, excluded.delete_after);
    delete from private.encounters as e
    where ((e.user_a = viewer_id and ($2 is null or e.user_b = $2))
        or (e.user_b = viewer_id and ($2 is null or e.user_a = $2)))
      and (input_encounter_id is null or e.encounter_id = input_encounter_id);
end;
$$;

create or replace function private.remove_encounter_pair(viewer_id uuid, input_encounter_id uuid, block_pair boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare peer uuid; lock_key bigint; zone_name text; result jsonb;
begin
    select g.counterpart_id into peer
    from private.visible_encounter_facts(viewer_id, array[input_encounter_id], false) as g;
    if peer is null then perform private.raise_error('not_found'); end if;
    for lock_key in
        select distinct pg_catalog.hashtextextended(pg_catalog.encode(n.digest, 'hex'), 0)
        from private.encounter_candidates as c
        cross join lateral (values (c.nonce_digest), (c.prior_nonce_digest)) as n(digest)
        where ((c.uploader_id = viewer_id and c.peer_id = peer)
            or (c.uploader_id = peer and c.peer_id = viewer_id)) and n.digest is not null order by 1
    loop perform pg_catalog.pg_advisory_xact_lock(lock_key); end loop;
    perform pg_catalog.pg_advisory_xact_lock(31003,
        pg_catalog.hashtext(least(viewer_id, peer)::text || ':' || greatest(viewer_id, peer)::text));
    perform 1 from private.encounters as e where e.encounter_id = input_encounter_id for update;
    if not found or not exists (select 1
        from private.visible_encounter_facts(viewer_id, array[input_encounter_id], false) as g
        where g.counterpart_id = peer) then perform private.raise_error('not_found'); end if;
    if block_pair then
        select z.name into zone_name from private.notification_preferences as n
        join private.iana_time_zones as z on z.name = n.time_zone where n.user_id = viewer_id;
        insert into private.blocks (blocker_id, blocked_id, placed_day)
        values (viewer_id, peer, (pg_catalog.now() at time zone coalesce(zone_name, 'UTC'))::date)
        on conflict (blocker_id, blocked_id) do nothing;
        select pg_catalog.jsonb_build_object('block_id', b.block_id, 'placed_day', b.placed_day)
        into result from private.blocks as b where b.blocker_id = viewer_id and b.blocked_id = peer;
    else result := pg_catalog.jsonb_build_object('deleted', true); end if;
    perform private.remove_encounter_pair(viewer_id, peer,
        case when block_pair then null::uuid else input_encounter_id end);
    return result;
end;
$$;

create function private.delete_own_account()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    caller uuid := auth.uid();
    safety_hash bytea;
    lock_key bigint;
    pair_key integer;
    operative_outcome text;
begin
    if caller is null then perform private.raise_error('not_authenticated'); end if;
    perform pg_catalog.pg_advisory_xact_lock(31001, pg_catalog.hashtext(caller::text));
    perform private.require_caller();
    -- Preflight before row locks or any change; the computed value never leaves
    -- the private transaction. Auth metadata and linked identity caches are ignored.
    perform private.apple_safety_hash(caller);
    for lock_key in
        select distinct pg_catalog.hashtextextended(pg_catalog.encode(n.digest, 'hex'), 0)
        from private.encounter_candidates as c
        cross join lateral (values (c.nonce_digest), (c.prior_nonce_digest)) as n(digest)
        where (c.uploader_id = caller or c.peer_id = caller) and n.digest is not null order by 1
    loop perform pg_catalog.pg_advisory_xact_lock(lock_key); end loop;
    for pair_key in
        select distinct pg_catalog.hashtext(least(caller, p.peer)::text || ':' || greatest(caller, p.peer)::text)
        from (
            select case when e.user_a = caller then e.user_b else e.user_a end as peer
            from private.encounters as e where e.user_a = caller or e.user_b = caller
            union select case when c.uploader_id = caller then c.peer_id else c.uploader_id end
            from private.encounter_candidates as c where c.uploader_id = caller or c.peer_id = caller
            union select case when b.blocker_id = caller then b.blocked_id else b.blocker_id end
            from private.blocks as b where b.blocker_id = caller or b.blocked_id = caller
        ) as p order by 1
    loop perform pg_catalog.pg_advisory_xact_lock(31003, pair_key); end loop;
    perform private.turn_discovery_off(caller);
    safety_hash := private.apple_safety_hash(caller);
    select p.operator_outcome into operative_outcome from private.profiles as p where p.user_id = caller;
    if safety_hash is not null then
        insert into private.deletion_safety_records (apple_id_hash, operator_outcome, delete_after)
        values (safety_hash, operative_outcome,
            pg_catalog.floor(extract(epoch from pg_catalog.clock_timestamp()))::bigint + 31536000)
        on conflict (apple_id_hash) do update set operator_outcome = excluded.operator_outcome,
            delete_after = excluded.delete_after;
        insert into private.deletion_safety_blocks (apple_id_hash, blocker_id, block_id, placed_day)
        select safety_hash, b.blocker_id, b.block_id, b.placed_day from private.blocks as b where b.blocked_id = caller
        on conflict (apple_id_hash, blocker_id) do nothing;
    end if;
    perform private.remove_encounter_pair(caller, null::uuid, null::uuid);
    delete from private.reports as r where r.reporter_id = caller or r.subject_id = caller;
    delete from private.saved_links as s where s.viewer_id = caller;
    delete from private.encounter_views as v where v.viewer_id = caller;
    delete from private.blocks as b where b.blocker_id = caller or b.blocked_id = caller;
    delete from private.deletion_safety_blocks as b where b.blocker_id = caller;
    delete from private.report_deliveries as d where d.user_id = caller;
    delete from private.linked_identities as i where i.user_id = caller;
    delete from private.external_links as l where l.owner_id = caller;
    delete from private.temporary_tokens as t where t.user_id = caller;
    delete from private.account_limit_events as e where e.user_id = caller;
    delete from private.sessions as s where s.user_id = caller;
    delete from private.user_interests as i where i.user_id = caller;
    delete from private.user_purposes as p where p.user_id = caller;
    delete from private.matching_preferences as p where p.user_id = caller;
    delete from private.field_visibility as v where v.owner_id = caller;
    delete from private.notification_preferences as n where n.user_id = caller;
    delete from private.profiles as p where p.user_id = caller;
    update private.server_settings as s set operator_account_id = null where s.operator_account_id = caller;
    -- Managed identities, sessions and refresh tokens cascade from hard Auth
    -- deletion. No exception is swallowed: any failure rolls back every step.
    delete from auth.users as u where u.id = caller;
    if not found then perform private.raise_error('not_authenticated'); end if;
    return pg_catalog.jsonb_build_object('deleted', true);
end;
$$;

create function private.restore_deletion_safety(account_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    safety_hash bytea;
    current_state text;
    retained private.deletion_safety_records%rowtype;
    pair_key integer;
    restored_count integer := 0;
begin
    if account_id is null then perform private.raise_error('invalid_input', array['account_id']); end if;
    perform pg_catalog.pg_advisory_xact_lock(31001, pg_catalog.hashtext(account_id::text));
    if not exists (select 1 from auth.users as u where u.id = account_id) then perform private.raise_error('not_authenticated'); end if;
    select p.moderation_state into current_state from private.profiles as p where p.user_id = account_id;
    if not found then perform private.raise_error('account_not_ready'); end if;
    safety_hash := private.apple_safety_hash(account_id);
    if safety_hash is not null then
        for pair_key in
            select distinct pg_catalog.hashtext(least(account_id, b.blocker_id)::text || ':' || greatest(account_id, b.blocker_id)::text)
            from private.deletion_safety_blocks as b where b.apple_id_hash = safety_hash and b.blocker_id <> account_id order by 1
        loop perform pg_catalog.pg_advisory_xact_lock(31003, pair_key); end loop;
        select r.* into retained from private.deletion_safety_records as r where r.apple_id_hash = safety_hash for update;
        if found then
            if retained.delete_after <= pg_catalog.floor(extract(epoch from pg_catalog.clock_timestamp()))::bigint then
                delete from private.deletion_safety_records as r where r.apple_id_hash = safety_hash;
            else
                -- Lock the retained child rows before Auth FK key-share locks.
                -- A deleting blocker removes its safety rows before Auth, too.
                perform b.block_id from private.deletion_safety_blocks as b
                where b.apple_id_hash = safety_hash order by b.blocker_id for update;
                perform u.id from auth.users as u where u.id = account_id or u.id in (
                    select b.blocker_id from private.deletion_safety_blocks as b where b.apple_id_hash = safety_hash
                ) order by u.id for key share;
                select p.moderation_state into current_state from private.profiles as p where p.user_id = account_id for update;
                if not found then
                    if not exists (select 1 from auth.users as u where u.id = account_id) then perform private.raise_error('not_authenticated'); end if;
                    perform private.raise_error('account_not_ready');
                end if;
                if retained.operator_outcome is not null then
                    current_state := case when retained.operator_outcome = 'dismissed' then 'active' else retained.operator_outcome end;
                    update private.profiles as p set moderation_state = current_state, operator_outcome = retained.operator_outcome
                    where p.user_id = account_id;
                end if;
                insert into private.blocks (blocker_id, blocked_id, block_id, placed_day)
                select b.blocker_id, account_id, b.block_id, b.placed_day
                from private.deletion_safety_blocks as b join auth.users as u on u.id = b.blocker_id
                where b.apple_id_hash = safety_hash and b.blocker_id <> account_id
                on conflict (blocker_id, blocked_id) do update
                    set block_id = excluded.block_id, placed_day = excluded.placed_day;
                get diagnostics restored_count = row_count;
                delete from private.deletion_safety_records as r where r.apple_id_hash = safety_hash;
                return pg_catalog.jsonb_build_object('applied', true, 'moderation_state', current_state, 'restored_block_count', restored_count);
            end if;
        end if;
    end if;
    return pg_catalog.jsonb_build_object('applied', false, 'moderation_state', current_state, 'restored_block_count', 0);
end;
$$;

create or replace function private.list_blocks()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare caller uuid := private.require_caller(); result jsonb;
begin
    with all_blocks as (
        select b.block_id, b.placed_day from private.blocks as b where b.blocker_id = caller
        union all
        select b.block_id, b.placed_day from private.deletion_safety_blocks as b
        join private.deletion_safety_records as r on r.apple_id_hash = b.apple_id_hash
        where b.blocker_id = caller and r.delete_after > pg_catalog.floor(extract(epoch from pg_catalog.now()))::bigint
    ), limited as (
        select b.* from all_blocks as b order by b.placed_day desc, b.block_id limit 201
    ), numbered as (
        select b.*, pg_catalog.row_number() over (order by b.placed_day desc, b.block_id) as position from limited as b
    )
    select pg_catalog.jsonb_build_object('blocks', coalesce(pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object('block_id', b.block_id, 'placed_day', b.placed_day)
        order by b.position) filter (where b.position <= 200), '[]'::jsonb), 'truncated', pg_catalog.count(*) > 200)
    into result from numbered as b;
    return result;
end;
$$;

create or replace function private.unblock(input_block_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare caller uuid := private.require_caller(); peer uuid; safety_hash bytea;
begin
    if input_block_id is null then perform private.raise_error('invalid_input', array['block_id']); end if;
    perform pg_catalog.pg_advisory_xact_lock(31001, pg_catalog.hashtext(caller::text));
    perform private.require_caller();
    -- Serialize with restoration on its record. If restoration consumed the
    -- record while we waited, look up its newly active block afterwards.
    select r.apple_id_hash into safety_hash from private.deletion_safety_records as r
    join private.deletion_safety_blocks as b on b.apple_id_hash = r.apple_id_hash
    where b.blocker_id = caller and b.block_id = input_block_id
      and r.delete_after > pg_catalog.floor(extract(epoch from pg_catalog.now()))::bigint for update of r;
    if found then
        delete from private.deletion_safety_blocks as b
        where b.apple_id_hash = safety_hash and b.blocker_id = caller and b.block_id = input_block_id;
        if not found then perform private.raise_error('not_found'); end if;
        return pg_catalog.jsonb_build_object('unblocked', true);
    end if;
    select b.blocked_id into peer from private.blocks as b where b.blocker_id = caller and b.block_id = input_block_id;
    if peer is null then perform private.raise_error('not_found'); end if;
    perform pg_catalog.pg_advisory_xact_lock(31003,
        pg_catalog.hashtext(least(caller, peer)::text || ':' || greatest(caller, peer)::text));
    delete from private.blocks as b where b.blocker_id = caller and b.block_id = input_block_id;
    if not found then perform private.raise_error('not_found'); end if;
    return pg_catalog.jsonb_build_object('unblocked', true);
end;
$$;

create or replace function private.cleanup_expired_data(cleanup_at timestamptz default pg_catalog.now())
returns void language plpgsql security definer set search_path = '' as $$
begin
    if cleanup_at is null then perform private.raise_error('invalid_input', array['cleanup_at']); end if;
    delete from private.encounter_candidates as c where c.expires_at < cleanup_at - interval '300 seconds';
    delete from private.temporary_tokens as t where t.delete_after <= extract(epoch from cleanup_at);
    delete from private.consumed_nonces as n where n.delete_after <= (cleanup_at at time zone 'UTC')::date;
    delete from private.account_limit_events as e
    where e.occurred_at < cleanup_at - case when e.bucket in ('register_time_zone', 'report_encounter_person')
        then interval '24 hours' else interval '1 hour' end;
    delete from private.qr_codes as q where q.expires_at <= pg_catalog.floor(extract(epoch from cleanup_at))::bigint;
    delete from private.sessions as s where least(s.expires_at, s.stopped_at) <= cleanup_at - interval '48 hours';
end;
$$;

create function private.cleanup_retained_data(cleanup_at timestamptz default pg_catalog.now())
returns void language plpgsql security definer set search_path = '' as $$
begin
    if cleanup_at is null then perform private.raise_error('invalid_input', array['cleanup_at']); end if;
    delete from private.encounter_views as v using private.encounters as e
    where e.encounter_id = v.encounter_id and not v.favorite
      and not exists (select 1 from private.saved_links as s where s.viewer_id = v.viewer_id and s.encounter_id = v.encounter_id)
      and exists (
          select 1 from (select v.viewer_id as id) as viewer
          left join private.notification_preferences as n on n.user_id = viewer.id
          left join private.iana_time_zones as z on z.name = n.time_zone
          where z.name is null or pg_catalog.timezone(z.name,
              ((case when e.user_a = v.viewer_id then e.day_a else e.day_b end) + 30)::timestamp) <= cleanup_at
      );
    delete from private.encounters as e where not exists (
        select 1 from private.encounter_views as v where v.encounter_id = e.encounter_id
    );
    delete from private.report_deliveries as d using private.notification_preferences as n, private.iana_time_zones as z
    where n.user_id = d.user_id and z.name = n.time_zone and d.status = 'closed'
      and d.report_day <= (cleanup_at at time zone z.name)::date - 30
      and not exists (select 1 from private.waiting_ambient_views(d.user_id, cleanup_at) as w
          where w.reveal_report_day <= d.report_day);
    delete from private.reports as r
    where r.status = 'resolved' and r.resolved_day <= (cleanup_at at time zone 'UTC')::date - 30;
    delete from private.deletion_safety_records as r
    where r.delete_after <= pg_catalog.floor(extract(epoch from cleanup_at))::bigint;
end;
$$;

do $$
begin
    perform cron.schedule('encounters-retention-cleanup', '0 * * * *', 'select private.cleanup_retained_data();');
end;
$$;

create function public.delete_own_account()
returns jsonb language sql security definer set search_path = '' as $$ select private.delete_own_account(); $$;

-- Complete the common own-account deletion-race mapping. Existing link,
-- session, QR, save, report and settings writers already use this helper.
create or replace function private.update_own_profile(input_display_name text, input_introduction text, input_contact_detail text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    caller uuid := private.require_caller();
    discovering boolean;
    new_name text := private.trim_input(coalesce(input_display_name, ''));
    new_introduction text := private.trim_input(coalesce(input_introduction, ''));
    new_contact text := private.trim_input(coalesce(input_contact_detail, ''));
    invalid_fields text[] := '{}'::text[];
    missing_fields text[] := '{}'::text[];
begin
    perform pg_catalog.pg_advisory_xact_lock(31001, pg_catalog.hashtext(caller::text));
    perform private.require_caller();
    -- All prerequisite-changing writes serialize on the profile row.
    select p.discovery_on into discovering from private.profiles as p where p.user_id = caller for update;
    if not found then
        perform private.raise_error('declaration_required');
    end if;
    if pg_catalog.char_length(new_name) > 30 then
        invalid_fields := pg_catalog.array_append(invalid_fields, 'display_name');
    end if;
    if pg_catalog.char_length(new_introduction) > 200 then
        invalid_fields := pg_catalog.array_append(invalid_fields, 'introduction');
    end if;
    if pg_catalog.char_length(new_contact) > 100 then
        invalid_fields := pg_catalog.array_append(invalid_fields, 'contact_detail');
    end if;
    if pg_catalog.cardinality(invalid_fields) > 0 then
        perform private.raise_error('invalid_input', invalid_fields);
    end if;
    if discovering and new_name = '' then
        missing_fields := pg_catalog.array_append(missing_fields, 'display_name');
    end if;
    if discovering and new_introduction = '' then
        missing_fields := pg_catalog.array_append(missing_fields, 'introduction');
    end if;
    if pg_catalog.cardinality(missing_fields) > 0 then
        perform private.raise_error('prerequisite_missing', missing_fields);
    end if;

    update private.profiles as p set display_name = new_name,
        introduction = new_introduction, contact_detail = new_contact
    where p.user_id = caller;
exception when foreign_key_violation then
    perform private.link_write_race(caller);
end;
$$;

create or replace function public.set_own_interests(interest_ids text[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    caller uuid := private.require_caller();
    discovering boolean;
begin
    perform pg_catalog.pg_advisory_xact_lock(31001, pg_catalog.hashtext(caller::text));
    perform private.require_caller();
    select p.discovery_on into discovering from private.profiles as p where p.user_id = caller for update;
    if not found then
        perform private.raise_error('declaration_required');
    end if;
    if interest_ids is null or coalesce(pg_catalog.array_ndims(interest_ids), 1) <> 1
        or pg_catalog.cardinality(interest_ids) > 10
        or (select pg_catalog.count(distinct selected.interest_id)
            from pg_catalog.unnest(interest_ids) as selected(interest_id)) > 10
        or exists (
            select 1 from pg_catalog.unnest(interest_ids) as selected(interest_id)
            where selected.interest_id is null or not exists (
                select 1 from private.interests as i where i.interest_id = selected.interest_id
            )
        ) then
        perform private.raise_error('invalid_input', array['interest_ids']);
    end if;
    if discovering and pg_catalog.cardinality(interest_ids) = 0 then
        perform private.raise_error('prerequisite_missing', array['interest']);
    end if;

    delete from private.user_interests as i where i.user_id = caller;
    insert into private.user_interests (user_id, interest_id)
    select distinct caller, selected.interest_id from pg_catalog.unnest(interest_ids) as selected(interest_id);
exception when foreign_key_violation then
    perform private.link_write_race(caller);
end;
$$;

create or replace function public.set_own_purposes(purposes text[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    caller uuid := private.require_caller();
begin
    perform pg_catalog.pg_advisory_xact_lock(31001, pg_catalog.hashtext(caller::text));
    perform private.require_caller();
    perform 1 from private.profiles as p where p.user_id = caller for update;
    if not found then
        perform private.raise_error('declaration_required');
    end if;
    if purposes is null or coalesce(pg_catalog.array_ndims(purposes), 1) <> 1
        or pg_catalog.cardinality(purposes) > 10 or exists (
        select 1 from pg_catalog.unnest(purposes) as selected(purpose)
        where selected.purpose is null or selected.purpose not in ('discovery', 'collaboration')
    ) then
        perform private.raise_error('invalid_input', array['purposes']);
    end if;

    delete from private.user_purposes as u where u.user_id = caller;
    insert into private.user_purposes (user_id, purpose)
    select distinct caller, selected.purpose from pg_catalog.unnest(purposes) as selected(purpose);
exception when foreign_key_violation then
    perform private.link_write_race(caller);
end;
$$;

create or replace function public.set_minimum_shared_interests(value integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    caller uuid := private.require_caller();
begin
    perform pg_catalog.pg_advisory_xact_lock(31001, pg_catalog.hashtext(caller::text));
    perform private.require_caller();
    perform 1 from private.profiles as p where p.user_id = caller for update;
    if not found then
        perform private.raise_error('declaration_required');
    end if;
    if value is null or value not between 1 and 10 then
        perform private.raise_error('invalid_input', array['value']);
    end if;

    insert into private.matching_preferences as m (user_id, minimum_shared_interests)
    values (caller, value)
    on conflict (user_id) do update set minimum_shared_interests = excluded.minimum_shared_interests;
exception when foreign_key_violation then
    perform private.link_write_race(caller);
end;
$$;

create or replace function private.set_field_visibility(input_field text, input_level text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    caller uuid := private.require_caller();
    invalid_fields text[] := '{}'::text[];
begin
    perform pg_catalog.pg_advisory_xact_lock(31001, pg_catalog.hashtext(caller::text));
    perform private.require_caller();
    perform 1 from private.profiles as p where p.user_id = caller for update;
    if not found then
        perform private.raise_error('declaration_required');
    end if;
    if input_field is null or input_field not in ('display_name', 'introduction', 'interests', 'purposes', 'contact_detail') then
        invalid_fields := pg_catalog.array_append(invalid_fields, 'field');
    end if;
    if input_level is null or input_level not in ('everyone_eligible', 'compatible_only', 'private') then
        invalid_fields := pg_catalog.array_append(invalid_fields, 'level');
    end if;
    if pg_catalog.cardinality(invalid_fields) > 0 then
        perform private.raise_error('invalid_input', invalid_fields);
    end if;

    insert into private.field_visibility as v (owner_id, field, level)
    values (caller, input_field, input_level)
    on conflict on constraint field_visibility_pkey do update set level = excluded.level;
exception when foreign_key_violation then
    perform private.link_write_race(caller);
end;
$$;

create or replace function public.issue_token_batch(covered_until bigint default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    caller uuid := private.require_caller();
    server_seconds numeric := extract(epoch from pg_catalog.now());
    start_window bigint := (pg_catalog.floor(server_seconds / 900) * 900)::bigint;
    horizon bigint := (pg_catalog.ceil((server_seconds + 43200) / 900) * 900)::bigint;
    new_batch_id uuid := pg_catalog.gen_random_uuid();
    window_start bigint;
    token_bytes bytea;
    windows jsonb := '[]'::jsonb;
begin
    if not private.account_is_ready(caller) then
        perform private.raise_error('account_not_ready');
    end if;
    if covered_until is not null and covered_until % 900 <> 0 then
        perform private.raise_error('invalid_input', array['covered_until']);
    end if;

    if private.record_account_event(caller, 'issue_token_batch', 20, interval '1 hour') then
        perform private.raise_error('rate_limited');
    end if;

    if covered_until is not null and covered_until > start_window then
        start_window := covered_until;
    end if;

    -- Check the whole requested batch before generating any secrets. The
    -- helper's account lock prevents another issue call passing concurrently.
    if exists (
        select 1 from private.temporary_tokens as t
        where t.user_id = caller
          and t.valid_from >= start_window and t.valid_from < horizon
          and t.valid_until > server_seconds
        group by t.valid_from
        having pg_catalog.count(*) >= 4
    ) then
        perform private.raise_error('rate_limited');
    end if;

    window_start := start_window;
    while window_start < horizon loop
        token_bytes := extensions.gen_random_bytes(16);
        insert into private.temporary_tokens (token_digest, user_id, batch_id, valid_from, valid_until, delete_after)
        values (pg_catalog.sha256(token_bytes), caller, new_batch_id, window_start, window_start + 900, window_start + 900 + 172800);
        windows := windows || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
            'token', pg_catalog.encode(token_bytes, 'hex'),
            'valid_from', window_start,
            'valid_until', window_start + 900
        ));
        window_start := window_start + 900;
    end loop;

    return pg_catalog.jsonb_build_object('batch_id', new_batch_id, 'windows', windows);
exception when foreign_key_violation then
    perform private.link_write_race(caller);
    return null;
end;
$$;

create or replace function private.run_account_report(account_id uuid, report_at timestamptz default pg_catalog.now())
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    fields text[] := '{}'::text[];
    due_day date;
    delivery_status text;
    newly_revealed uuid[];
    zone_name text;
begin
    if account_id is null then fields := pg_catalog.array_append(fields, 'account_id'); end if;
    if report_at is null then fields := pg_catalog.array_append(fields, 'report_at'); end if;
    if pg_catalog.cardinality(fields) > 0 then perform private.raise_error('invalid_input', fields); end if;
    perform pg_catalog.pg_advisory_xact_lock(31001, pg_catalog.hashtext(account_id::text));
    -- Recheck live Auth after serialization. Invalid stored zones fail closed,
    -- preserving the existing read gate for missing/corrupt registration.
    if not exists (select 1 from auth.users as u where u.id = account_id)
        or not private.account_is_ready(account_id) then
        return pg_catalog.jsonb_build_object('report_day', null, 'newly_revealed_encounter_ids', '[]'::jsonb, 'closed', false);
    end if;
    select z.name into zone_name from private.notification_preferences as n
    join pg_catalog.pg_timezone_names as z on z.name = n.time_zone where n.user_id = account_id;
    if zone_name is null then
        return pg_catalog.jsonb_build_object('report_day', null, 'newly_revealed_encounter_ids', '[]'::jsonb, 'closed', false);
    end if;
    due_day := (report_at at time zone zone_name)::date;
    while private.local_report_instant(account_id, due_day) > report_at loop due_day := due_day - 1; end loop;
    insert into private.report_deliveries (user_id, report_day, status) values (account_id, due_day, 'open')
    on conflict (user_id, report_day) do nothing;
    select d.status into delivery_status from private.report_deliveries as d
    where d.user_id = account_id and d.report_day = due_day for update;
    -- Older dates are due too. Close their open keys even when the latest key
    -- is a replay; never move an already revealed view's report membership.
    update private.report_deliveries as d set status = 'closed'
    where d.user_id = account_id and d.status = 'open' and d.report_day < due_day;
    if delivery_status = 'closed' then
        return pg_catalog.jsonb_build_object('report_day', due_day, 'newly_revealed_encounter_ids', '[]'::jsonb, 'closed', false);
    end if;
    -- Confirmation takes no peer account advisory locks. A peer's waiting view
    -- can arrive just after its assigned delivery closes; the next later report
    -- catches up every earlier assigned day and stamps this delivery's date.
    with revealed as (
        update private.encounter_views as v set revealed = true, revealed_report_day = due_day
        where v.viewer_id = account_id and v.encounter_id in (
            select w.encounter_id from private.waiting_ambient_views(account_id, report_at) as w
            where w.reveal_report_day <= due_day
        ) returning v.encounter_id
    ) select coalesce(pg_catalog.array_agg(r.encounter_id order by r.encounter_id), '{}'::uuid[])
    into newly_revealed from revealed as r;
    update private.report_deliveries as d set status = 'closed'
    where d.user_id = account_id and d.report_day = due_day;
    return pg_catalog.jsonb_build_object('report_day', due_day,
        'newly_revealed_encounter_ids', newly_revealed, 'closed', true);
exception when foreign_key_violation then
    if not exists (select 1 from auth.users as u where u.id = account_id) then
        return pg_catalog.jsonb_build_object('report_day', null, 'newly_revealed_encounter_ids', '[]'::jsonb, 'closed', false);
    end if;
    perform private.link_write_race(account_id);
    return null;
end;
$$;

create or replace function public.submit_receipts(receipts jsonb)
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
    locked_nonce_keys bigint[] := '{}'::bigint[];
    locked_pair_keys integer[] := '{}'::integer[];
    encounter_kind text;
    original_pair_found boolean;
    observation_a bigint;
    observation_b bigint;
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
    -- Take only the caller's account lock before sorted nonce and pair locks.
    -- A peer's concurrent report step is handled by later-report catch-up.
    perform pg_catalog.pg_advisory_xact_lock(31001, pg_catalog.hashtext(caller::text));
    perform private.require_caller();
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
        locked_nonce_keys := pg_catalog.array_append(locked_nonce_keys, lock_key);
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
        locked_pair_keys := pg_catalog.array_append(locked_pair_keys, pair_key);
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
                    where n.exchange_digest = private.receipt_exchange_digest(nonce, own_digest, peer_digest)
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
        -- Joined rows discovered through an original may name locks absent from
        -- this call. Defer them rather than taking more locks out of order.
        if not (pg_catalog.hashtextextended(pg_catalog.encode(a.nonce_digest, 'hex'), 0) = any(locked_nonce_keys))
            or (a.prior_nonce_digest is not null and not (
                pg_catalog.hashtextextended(pg_catalog.encode(a.prior_nonce_digest, 'hex'), 0) = any(locked_nonce_keys)))
            or not (pg_catalog.hashtext(least(a.uploader_id, a.peer_id)::text || ':'
                || greatest(a.uploader_id, a.peer_id)::text) = any(locked_pair_keys)) then
            continue;
        end if;
        if exists (select 1 from private.consumed_nonces as n
            where n.exchange_digest = private.receipt_exchange_digest(nonce, a.start_own_token_digest, a.start_peer_token_digest)
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
            perform private.confirm_encounter(a.uploader_id, b.uploader_id, encounter_kind,
                observation_a, observation_b, server_time);
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
    -- Recheck live Auth after a deletion race; expose no database identifiers.
    perform private.link_write_race(caller);
    return null;
end;
$$;

revoke all on all functions in schema private from public, anon, authenticated, service_role;
revoke all on function public.delete_own_account(), public.list_blocks(), public.unblock(uuid),
    public.set_own_interests(text[]), public.set_own_purposes(text[]), public.set_minimum_shared_interests(integer),
    public.update_own_profile(text, text, text), public.set_field_visibility(text, text),
    public.issue_token_batch(bigint), public.submit_receipts(jsonb)
    from public, anon, authenticated, service_role;
grant execute on function public.delete_own_account(), public.list_blocks(), public.unblock(uuid),
    public.set_own_interests(text[]), public.set_own_purposes(text[]), public.set_minimum_shared_interests(integer),
    public.update_own_profile(text, text, text), public.set_field_visibility(text, text),
    public.issue_token_batch(bigint), public.submit_receipts(jsonb) to authenticated;
