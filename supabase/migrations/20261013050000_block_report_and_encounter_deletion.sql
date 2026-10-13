alter table private.blocks
    add column block_id uuid not null default pg_catalog.gen_random_uuid(),
    add column placed_day date;
update private.blocks as b set placed_day = (pg_catalog.now() at time zone coalesce((
    select z.name from private.notification_preferences as n
    join private.iana_time_zones as z on z.name = n.time_zone where n.user_id = b.blocker_id
), 'UTC'))::date;
alter table private.blocks alter column placed_day set not null;
create unique index blocks_block_id_idx on private.blocks (block_id);
create index blocks_blocker_day_idx on private.blocks (blocker_id, placed_day desc, block_id);
alter table private.profiles add column operator_outcome text
    check (operator_outcome in ('dismissed', 'hidden', 'suspended'));

create table private.reports (
    report_id uuid primary key default pg_catalog.gen_random_uuid(),
    reporter_id uuid not null references auth.users (id) on delete cascade,
    subject_id uuid not null references auth.users (id) on delete cascade,
    encounter_id uuid references private.encounters (encounter_id) on delete set null,
    link_id uuid references private.external_links (link_id) on delete set null,
    reason text not null check (reason in ('spam', 'harassment', 'impersonation', 'other')),
    status text not null default 'open' check (status in ('open', 'resolved')),
    review_due_at bigint not null,
    outcome text check (outcome in ('dismissed', 'hidden', 'suspended')),
    resolved_day date,
    unique (reporter_id, subject_id),
    check (reporter_id <> subject_id),
    check (reason = 'impersonation' or link_id is null),
    check ((status = 'open' and outcome is null and resolved_day is null)
        or (status = 'resolved' and outcome is not null and resolved_day is not null))
);
create index reports_subject_status_idx on private.reports (subject_id, status);
create index reports_status_deadline_idx on private.reports (status, review_due_at, report_id);
create index reports_encounter_idx on private.reports (encounter_id);
create index reports_link_idx on private.reports (link_id);
alter table private.reports enable row level security;
revoke all on table private.reports from public, anon, authenticated, service_role;

-- Authorization and sort facts contain no card payload. Both branches share
-- the same gates; an explicit ID array probes encounters and views by PK.
-- ARRAY[null] and an empty array select nothing, never the caller's whole feed.
create function private.gated_encounter_facts(viewer_id uuid, encounter_ids uuid[],
    favorites_only boolean, allow_own_report boolean)
returns table (encounter_id uuid, counterpart_id uuid, kind text, day date, favorite boolean,
    compatible boolean, shared_interest_count integer)
language sql stable security definer set search_path = '' as $$
    with candidates as materialized (
        select e.encounter_id, e.kind,
            case when e.user_a = $1 then e.user_b else e.user_a end as counterpart_id,
            case when e.user_a = $1 then e.day_a else e.day_b end as day, v.favorite
        from private.encounter_views as v join private.encounters as e on e.encounter_id = v.encounter_id
        where $2 is null and v.viewer_id = $1 and $1 in (e.user_a, e.user_b)
          and v.revealed and (not $3 or v.favorite)
        union all
        select e.encounter_id, e.kind,
            case when e.user_a = $1 then e.user_b else e.user_a end,
            case when e.user_a = $1 then e.day_a else e.day_b end, v.favorite
        from (select distinct id from pg_catalog.unnest($2) as requested(id)) as ids
        -- Keep the probes parameterized even with a generic array plan and
        -- stale viewer statistics: neither join may start with all own views.
        cross join lateral (
            select e.* from private.encounters as e where e.encounter_id = ids.id offset 0
        ) as e
        cross join lateral (
            select v.favorite, v.revealed from private.encounter_views as v
            where v.encounter_id = ids.id and v.viewer_id = $1 offset 0
        ) as v
        where $2 is not null and $1 in (e.user_a, e.user_b)
          and v.revealed and (not $3 or v.favorite)
    ), viewer_zone as materialized (
        select z.name from (select $1 as viewer_id) as viewer
        left join private.notification_preferences as n on n.user_id = viewer.viewer_id
        left join private.iana_time_zones as z on z.name = n.time_zone
    ), retained as materialized (
        select c.* from candidates as c cross join viewer_zone as z
        where c.favorite or exists (select 1 from private.saved_links as s
            where s.viewer_id = $1 and s.encounter_id = c.encounter_id)
          or pg_catalog.now() < private.try_time_zone(z.name, (c.day + 30)::timestamp)
    ), counterparts as materialized (
        select distinct r.counterpart_id from retained as r
    ), owners as materialized (
        select p.user_id, a.compatible,
            case when exists (select 1 from private.field_visibility as f
                where f.owner_id = p.user_id and f.field = 'interests'
                  and (f.level = 'everyone_eligible' or (f.level = 'compatible_only' and a.compatible)))
                then a.shared_interest_count else 0 end as shared_interest_count
        from counterparts as c join private.profiles as p on p.user_id = c.counterpart_id
        cross join lateral private.encounter_authorization($1, p.user_id) as a
        where a.eligible and p.moderation_state = 'active'
          and exists (select 1 from private.profiles as viewer
              where viewer.user_id = $1 and viewer.moderation_state = 'active')
          and ($4 or not exists (select 1 from private.reports as r
              where r.reporter_id = $1 and r.subject_id = p.user_id))
    )
    select r.encounter_id, r.counterpart_id, r.kind, r.day, r.favorite,
        o.compatible, o.shared_interest_count
    from retained as r join owners as o on o.user_id = r.counterpart_id;
$$;

-- Ordinary reads always retain the reporter hide. Only block pair removal
-- may bypass it, while sharing every other authorization/retention condition.
create function private.visible_encounter_facts(viewer_id uuid, encounter_ids uuid[] default null,
    favorites_only boolean default false)
returns table (encounter_id uuid, counterpart_id uuid, kind text, day date, favorite boolean,
    compatible boolean, shared_interest_count integer)
language sql stable security definer set search_path = '' as $$
    select g.* from private.gated_encounter_facts($1, $2, $3, false) as g;
$$;

-- Scalar and selected batch reads assemble each surviving owner's metadata
-- once. List callers supply only their deduplicated, capped encounter IDs.
create or replace function private.visible_encounter_cards(viewer_id uuid, encounter_ids uuid[] default null,
    favorites_only boolean default false)
returns table (encounter_id uuid, counterpart_id uuid, kind text, day date, favorite boolean,
    compatible boolean, shared_interest_count integer, shared_interest_ids jsonb, card jsonb)
language sql stable security definer set search_path = '' as $$
    with visible as materialized (
        select g.* from private.visible_encounter_facts($1, $2, $3) as g
    ), owners as materialized (
        select distinct p.user_id, p.display_name, p.introduction, p.contact_detail, g.compatible
        from visible as g join private.profiles as p on p.user_id = g.counterpart_id
    ), interests as materialized (
        select i.user_id, pg_catalog.jsonb_agg(i.interest_id order by i.interest_id) as value,
            pg_catalog.jsonb_agg(i.interest_id order by i.interest_id)
                filter (where v.interest_id is not null) as shared_ids
        from private.user_interests as i join owners as o on o.user_id = i.user_id
        left join private.user_interests as v on v.user_id = $1 and v.interest_id = i.interest_id
        group by i.user_id
    ), purposes as materialized (
        select p.user_id, pg_catalog.jsonb_agg(p.purpose order by p.purpose) as value
        from private.user_purposes as p join owners as o on o.user_id = p.user_id group by p.user_id
    ), fields as materialized (
        select f.owner_id, pg_catalog.jsonb_object_agg(f.field, case f.field
            when 'display_name' then pg_catalog.to_jsonb(o.display_name)
            when 'introduction' then pg_catalog.to_jsonb(o.introduction)
            when 'contact_detail' then pg_catalog.to_jsonb(o.contact_detail)
            when 'interests' then coalesce(i.value, '[]'::jsonb)
            when 'purposes' then coalesce(p.value, '[]'::jsonb) end) as value
        from private.field_visibility as f join owners as o on o.user_id = f.owner_id
        left join interests as i on i.user_id = o.user_id
        left join purposes as p on p.user_id = o.user_id
        where f.level = 'everyone_eligible' or (f.level = 'compatible_only' and o.compatible)
        group by f.owner_id
    ), links as materialized (
        select l.owner_id, pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'link_id', l.link_id, 'source', l.source, 'url', l.url, 'title', l.title,
            'description', l.description, 'main_language', l.main_language, 'tags', l.tags,
            'opening_text', l.opening_text, 'verification_state', l.verification_state
        ) order by l.display_order, l.link_id) as value
        from private.external_links as l join owners as o on o.user_id = l.owner_id
        where (l.visibility = 'everyone_eligible' or (l.visibility = 'compatible_only' and o.compatible))
          and (l.source <> 'github' or private.github_identity_is_live(l.owner_id))
        group by l.owner_id
    )
    select g.encounter_id, g.counterpart_id, g.kind, g.day, g.favorite,
        g.compatible, g.shared_interest_count,
        case when f.value ? 'interests' then coalesce(i.shared_ids, '[]'::jsonb) else '[]'::jsonb end,
        pg_catalog.jsonb_build_object('encounter_id', g.encounter_id, 'kind', g.kind, 'day', g.day)
        || coalesce(f.value, '{}'::jsonb)
        || case when l.value is null then '{}'::jsonb else pg_catalog.jsonb_build_object('links', l.value) end
        || case when f.value is null and l.value is null
            then pg_catalog.jsonb_build_object('shell', true) else '{}'::jsonb end
    from visible as g left join interests as i on i.user_id = g.counterpart_id
    left join fields as f on f.owner_id = g.counterpart_id
    left join links as l on l.owner_id = g.counterpart_id;
$$;

create function private.capped_encounter_card_list(viewer_account uuid, encounter_ids uuid[], favorites_only boolean)
returns jsonb language sql stable security definer set search_path = '' as $$
    with visible as materialized (
        select g.* from private.visible_encounter_facts($1, $2, $3) as g
    ), winners as (
        select distinct on (g.counterpart_id, g.kind, g.day) g.* from visible as g
        order by g.counterpart_id, g.kind, g.day, g.favorite desc, g.encounter_id
    ), limited as materialized (
        select g.* from winners as g
        order by g.day desc, g.shared_interest_count desc, g.encounter_id limit 201
    ), numbered as materialized (
        select g.*, pg_catalog.row_number() over (
            order by g.day desc, g.shared_interest_count desc, g.encounter_id
        ) as position from limited as g
    ), cards as materialized (
        select g.* from private.visible_encounter_cards($1, array(
            select n.encounter_id from numbered as n where n.position <= 200
        ), $3) as g
    )
    select pg_catalog.jsonb_build_object('cards', coalesce((
        select pg_catalog.jsonb_agg(g.card || pg_catalog.jsonb_build_object('favorite', g.favorite)
            || case when g.card ? 'interests' then
                pg_catalog.jsonb_build_object('shared_interest_ids', g.shared_interest_ids)
                else '{}'::jsonb end order by n.position)
        from cards as g join numbered as n on n.encounter_id = g.encounter_id
    ), '[]'::jsonb), 'truncated', (select pg_catalog.count(*) > 200 from numbered));
$$;
create or replace function private.encounter_card_list(viewer_account uuid, favorites_only boolean)
returns jsonb language sql stable security definer set search_path = '' as $$
    select private.capped_encounter_card_list($1, null, $2);
$$;
create or replace function private.report_card_list(viewer_account uuid, encounter_ids uuid[])
returns jsonb language sql stable security definer set search_path = '' as $$
    select private.capped_encounter_card_list($1, $2, false);
$$;

create or replace function private.list_saved_links()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare caller uuid := private.require_caller(); result jsonb;
begin
    with visible as materialized (
        select g.* from private.visible_encounter_facts(caller, array(
            select distinct s.encounter_id from private.saved_links as s where s.viewer_id = caller
        ), false) as g
    ), limited as materialized (
        select g.encounter_id, g.day, g.kind, l.*
        from visible as g join private.saved_links as s on s.viewer_id = caller and s.encounter_id = g.encounter_id
        join private.external_links as l on l.link_id = s.link_id and l.owner_id = g.counterpart_id
        where (l.visibility = 'everyone_eligible' or (l.visibility = 'compatible_only' and g.compatible))
          and (l.source <> 'github' or private.github_identity_is_live(l.owner_id))
        order by g.day desc, g.encounter_id, l.display_order, l.link_id limit 201
    ), numbered as (
        select l.*, pg_catalog.row_number() over (
            order by l.day desc, l.encounter_id, l.display_order, l.link_id
        ) as position from limited as l
    )
    select pg_catalog.jsonb_build_object('links', coalesce(pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object('encounter_id', l.encounter_id, 'day', l.day, 'kind', l.kind,
            'link', pg_catalog.jsonb_build_object('link_id', l.link_id, 'source', l.source, 'url', l.url,
                'title', l.title, 'description', l.description, 'main_language', l.main_language,
                'tags', l.tags, 'opening_text', l.opening_text, 'verification_state', l.verification_state))
        order by l.position) filter (where l.position <= 200), '[]'::jsonb),
        'truncated', pg_catalog.count(*) > 200) into result from numbered as l;
    return result;
end;
$$;

-- Updating a boolean cannot cause a foreign-key violation. Avoid the exception
-- subtransaction on this hot path; retain the old-state retention gate.
create or replace function private.set_encounter_favorite(input_encounter_id uuid, input_favorite boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare caller uuid := private.require_caller(); fields text[] := '{}'::text[];
begin
    if input_encounter_id is null then fields := pg_catalog.array_append(fields, 'encounter_id'); end if;
    if input_favorite is null then fields := pg_catalog.array_append(fields, 'favorite'); end if;
    if pg_catalog.cardinality(fields) > 0 then perform private.raise_error('invalid_input', fields); end if;
    perform pg_catalog.pg_advisory_xact_lock(31001, pg_catalog.hashtext(caller::text));
    perform private.require_caller();
    update private.encounter_views as v set favorite = input_favorite
    where v.viewer_id = caller and v.encounter_id = input_encounter_id
      and private.visible_encounter_card(caller, input_encounter_id) is not null;
    if not found then perform private.raise_error('not_found'); end if;
    return pg_catalog.jsonb_build_object('encounter_id', input_encounter_id, 'favorite', input_favorite);
end;
$$;

-- Caller holds its account lock. Discover nonce/prior keys without row locks,
-- sort actual advisory keys, then acquire the pair and finally encounter rows.
-- A concurrent upload may commit a new nonce between discovery and the pair
-- lock: remove that row too, without ever acquiring a nonce after the pair.
create function private.remove_encounter_pair(viewer_id uuid, input_encounter_id uuid, block_pair boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    peer uuid;
    lock_key bigint;
    deadline date;
    zone_name text;
    result jsonb;
begin
    select g.counterpart_id into peer
    from private.gated_encounter_facts(viewer_id, array[input_encounter_id], false, block_pair) as g;
    if peer is null then perform private.raise_error('not_found'); end if;
    for lock_key in
        select distinct pg_catalog.hashtextextended(pg_catalog.encode(n.digest, 'hex'), 0)
        from private.encounter_candidates as c
        cross join lateral (values (c.nonce_digest), (c.prior_nonce_digest)) as n(digest)
        where ((c.uploader_id = viewer_id and c.peer_id = peer)
            or (c.uploader_id = peer and c.peer_id = viewer_id)) and n.digest is not null
        order by 1
    loop
        perform pg_catalog.pg_advisory_xact_lock(lock_key);
    end loop;
    perform pg_catalog.pg_advisory_xact_lock(31003,
        pg_catalog.hashtext(least(viewer_id, peer)::text || ':' || greatest(viewer_id, peer)::text));
    perform 1 from private.encounters as e where e.encounter_id = input_encounter_id for update;
    if not found or not exists (select 1
        from private.gated_encounter_facts(viewer_id, array[input_encounter_id], false, block_pair) as g
        where g.counterpart_id = peer) then perform private.raise_error('not_found'); end if;
    if block_pair then
        select z.name into zone_name from private.notification_preferences as n
        join private.iana_time_zones as z on z.name = n.time_zone where n.user_id = viewer_id;
        insert into private.blocks (blocker_id, blocked_id, placed_day)
        values (viewer_id, peer, (pg_catalog.now() at time zone coalesce(zone_name, 'UTC'))::date)
        on conflict (blocker_id, blocked_id) do nothing;
        select pg_catalog.jsonb_build_object('block_id', b.block_id, 'placed_day', b.placed_day)
        into result from private.blocks as b where b.blocker_id = viewer_id and b.blocked_id = peer;
    else
        result := pg_catalog.jsonb_build_object('deleted', true);
    end if;
    deadline := ((pg_catalog.now() at time zone 'UTC') + interval '48 hours 300 seconds')::date;
    if ((pg_catalog.now() at time zone 'UTC') + interval '48 hours 300 seconds')::time <> time '00:00:00' then
        deadline := deadline + 1;
    end if;
    with removed as (
        delete from private.encounter_candidates as c
        where (c.uploader_id = viewer_id and c.peer_id = peer)
           or (c.uploader_id = peer and c.peer_id = viewer_id)
        returning c.nonce_digest, c.start_own_token_digest, c.start_peer_token_digest
    )
    insert into private.consumed_nonces as n (exchange_digest, delete_after)
    select distinct private.receipt_exchange_digest(r.nonce_digest,
        r.start_own_token_digest, r.start_peer_token_digest), deadline from removed as r
    on conflict (exchange_digest) do update set delete_after = greatest(n.delete_after, excluded.delete_after);
    delete from private.encounters as e
    where e.user_a = least(viewer_id, peer) and e.user_b = greatest(viewer_id, peer)
      and (block_pair or e.encounter_id = input_encounter_id);
    return result;
end;
$$;

create function private.block_encounter_person(input_encounter_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare caller uuid := private.require_caller();
begin
    if input_encounter_id is null then perform private.raise_error('invalid_input', array['encounter_id']); end if;
    perform pg_catalog.pg_advisory_xact_lock(31001, pg_catalog.hashtext(caller::text));
    perform private.require_caller();
    return private.remove_encounter_pair(caller, input_encounter_id, true);
exception when foreign_key_violation then
    perform private.link_write_race(caller);
    return null;
end;
$$;
create function private.delete_encounter(input_encounter_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare caller uuid := private.require_caller();
begin
    if input_encounter_id is null then perform private.raise_error('invalid_input', array['encounter_id']); end if;
    perform pg_catalog.pg_advisory_xact_lock(31001, pg_catalog.hashtext(caller::text));
    perform private.require_caller();
    return private.remove_encounter_pair(caller, input_encounter_id, false);
end;
$$;
create function private.list_blocks()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare caller uuid := private.require_caller(); result jsonb;
begin
    with limited as (
        select b.block_id, b.placed_day from private.blocks as b where b.blocker_id = caller
        order by b.placed_day desc, b.block_id limit 201
    ), numbered as (
        select b.*, pg_catalog.row_number() over (order by b.placed_day desc, b.block_id) as position
        from limited as b
    )
    select pg_catalog.jsonb_build_object('blocks', coalesce(pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object('block_id', b.block_id, 'placed_day', b.placed_day)
        order by b.position) filter (where b.position <= 200), '[]'::jsonb),
        'truncated', pg_catalog.count(*) > 200) into result from numbered as b;
    return result;
end;
$$;
create function private.unblock(input_block_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare caller uuid := private.require_caller(); peer uuid;
begin
    if input_block_id is null then perform private.raise_error('invalid_input', array['block_id']); end if;
    perform pg_catalog.pg_advisory_xact_lock(31001, pg_catalog.hashtext(caller::text));
    perform private.require_caller();
    select b.blocked_id into peer from private.blocks as b where b.blocker_id = caller and b.block_id = input_block_id;
    if peer is null then perform private.raise_error('not_found'); end if;
    perform pg_catalog.pg_advisory_xact_lock(31003,
        pg_catalog.hashtext(least(caller, peer)::text || ':' || greatest(caller, peer)::text));
    delete from private.blocks as b where b.blocker_id = caller and b.block_id = input_block_id;
    if not found then perform private.raise_error('not_found'); end if;
    return pg_catalog.jsonb_build_object('unblocked', true);
end;
$$;

create function private.report_encounter_person(input_encounter_id uuid, input_reason text, input_link_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    caller uuid := private.require_caller();
    subject uuid;
    fields text[] := '{}'::text[];
    card jsonb;
    new_report uuid;
begin
    if input_encounter_id is null then fields := pg_catalog.array_append(fields, 'encounter_id'); end if;
    if input_reason is null or input_reason not in ('spam', 'harassment', 'impersonation', 'other') then
        fields := pg_catalog.array_append(fields, 'reason');
    end if;
    if (input_reason = 'impersonation' and input_link_id is null)
        or (input_reason in ('spam', 'harassment', 'other') and input_link_id is not null) then
        fields := pg_catalog.array_append(fields, 'link_id');
    end if;
    if pg_catalog.cardinality(fields) > 0 then perform private.raise_error('invalid_input', fields); end if;
    if not exists (select 1 from private.profiles as p
        where p.user_id = caller and p.moderation_state = 'active') then
        perform private.raise_error('account_not_ready');
    end if;
    -- Derive the subject before serialization; all reporters share its lock.
    select g.counterpart_id into subject
    from private.visible_encounter_facts(caller, array[input_encounter_id], false) as g;
    if subject is null then perform private.raise_error('not_found'); end if;
    perform private.lock_account_pair(caller, subject);
    perform private.require_caller();
    if not exists (select 1 from private.profiles as p
        where p.user_id = caller and p.moderation_state = 'active') then
        perform private.raise_error('account_not_ready');
    end if;
    perform pg_catalog.pg_advisory_xact_lock(31003,
        pg_catalog.hashtext(least(caller, subject)::text || ':' || greatest(caller, subject)::text));
    perform 1 from private.profiles as p where p.user_id = subject for update;
    card := private.visible_encounter_card(caller, input_encounter_id);
    if card is null then perform private.raise_error('not_found'); end if;
    if input_reason = 'impersonation' and not exists (
        select 1 from pg_catalog.jsonb_array_elements(coalesce(card->'links', '[]'::jsonb)) as l(value)
        where l.value->>'link_id' = input_link_id::text
    ) then perform private.raise_error('not_found'); end if;
    if private.record_account_event(caller, 'report_encounter_person', 10, interval '24 hours') then
        perform private.raise_error('rate_limited');
    end if;
    insert into private.reports (reporter_id, subject_id, encounter_id, link_id, reason, review_due_at)
    values (caller, subject, input_encounter_id, input_link_id, input_reason,
        pg_catalog.floor(extract(epoch from pg_catalog.now()))::bigint + 259200)
    returning report_id into new_report;
    if (select pg_catalog.count(distinct r.reporter_id) from private.reports as r
        where r.subject_id = subject and r.status = 'open') >= 3 then
        -- A threshold may hide an active account; it never overrides suspension
        -- or records an operator decision, and never automatically reactivates.
        update private.profiles as p set moderation_state = 'hidden'
        where p.user_id = subject and p.moderation_state = 'active';
    end if;
    return pg_catalog.jsonb_build_object('report_id', new_report, 'status', 'open');
exception when foreign_key_violation then
    perform private.link_write_race(caller);
    return null;
end;
$$;

create function private.require_operator(account_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
    if account_id is null then perform private.raise_error('invalid_input', array['account_id']); end if;
    if not exists (select 1 from auth.users as u where u.id = account_id) then perform private.raise_error('not_authenticated'); end if;
    if not exists (select 1 from private.server_settings as s
        where s.singleton and s.operator_account_id = account_id) then perform private.raise_error('not_found'); end if;
end;
$$;
create function private.list_open_reports(account_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare result jsonb;
begin
    perform private.require_operator(account_id);
    with limited as (
        select r.* from private.reports as r where r.status = 'open'
        order by r.review_due_at, r.report_id limit 201
    ), numbered as (
        select r.*, pg_catalog.row_number() over (order by r.review_due_at, r.report_id) as position from limited as r
    )
    select pg_catalog.jsonb_build_object('reports', coalesce(pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object('report_id', r.report_id, 'subject_id', r.subject_id,
            'reporter_id', r.reporter_id, 'encounter_id', r.encounter_id, 'link_id', r.link_id,
            'reason', r.reason, 'status', r.status, 'review_due_at', r.review_due_at)
        order by r.position) filter (where r.position <= 200), '[]'::jsonb),
        'truncated', pg_catalog.count(*) > 200) into result from numbered as r;
    return result;
end;
$$;
-- The subject profile is locked by the caller, after both account locks.
-- Report resolution and account review apply exactly the same subject outcome.
create function private.apply_account_review(input_subject_id uuid, input_outcome text)
returns text language plpgsql security definer set search_path = '' as $$
declare subject_state text := case when input_outcome = 'dismissed' then 'active' else input_outcome end;
begin
    update private.profiles as p set moderation_state = subject_state, operator_outcome = input_outcome
    where p.user_id = input_subject_id;
    update private.reports as r set status = 'resolved', outcome = input_outcome,
        resolved_day = (pg_catalog.now() at time zone 'UTC')::date
    where r.subject_id = input_subject_id and r.status = 'open';
    return subject_state;
end;
$$;

create function private.list_moderated_accounts(account_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare result jsonb;
begin
    perform private.require_operator(account_id);
    with limited as (
        select p.user_id, p.moderation_state, p.operator_outcome
        from private.profiles as p where p.moderation_state <> 'active'
        order by (p.operator_outcome is not null), p.user_id limit 201
    ), numbered as (
        select p.*, pg_catalog.row_number() over (order by (p.operator_outcome is not null), p.user_id) as position from limited as p
    )
    select pg_catalog.jsonb_build_object('accounts', coalesce(pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object('account_id', p.user_id, 'moderation_state', p.moderation_state,
            'operator_outcome', p.operator_outcome, 'open_report_count', (
                select pg_catalog.count(*) from private.reports as r
                where r.subject_id = p.user_id and r.status = 'open'))
        order by p.position) filter (where p.position <= 200), '[]'::jsonb),
        'truncated', pg_catalog.count(*) > 200) into result from numbered as p;
    return result;
end;
$$;

create function private.review_account(input_account_id uuid, input_subject_id uuid, input_outcome text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare fields text[] := '{}'::text[]; subject_state text;
begin
    if input_account_id is null then fields := pg_catalog.array_append(fields, 'account_id'); end if;
    if input_subject_id is null then fields := pg_catalog.array_append(fields, 'subject_id'); end if;
    if input_outcome is null or input_outcome not in ('dismissed', 'hidden', 'suspended') then
        fields := pg_catalog.array_append(fields, 'outcome');
    end if;
    if pg_catalog.cardinality(fields) > 0 then perform private.raise_error('invalid_input', fields); end if;
    perform private.require_operator(input_account_id);
    perform private.lock_account_pair(input_account_id, input_subject_id);
    perform private.require_operator(input_account_id);
    perform 1 from auth.users as u where u.id = input_subject_id;
    if not found then perform private.raise_error('not_found'); end if;
    perform 1 from private.profiles as p where p.user_id = input_subject_id for update;
    if not found then perform private.raise_error('not_found'); end if;
    subject_state := private.apply_account_review(input_subject_id, input_outcome);
    return pg_catalog.jsonb_build_object('subject_id', input_subject_id,
        'outcome', input_outcome, 'moderation_state', subject_state);
end;
$$;

create function private.resolve_report(input_account_id uuid, input_report_id uuid, input_outcome text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    fields text[] := '{}'::text[];
    subject uuid;
    report private.reports%rowtype;
    subject_state text;
begin
    if input_account_id is null then fields := pg_catalog.array_append(fields, 'account_id'); end if;
    if input_report_id is null then fields := pg_catalog.array_append(fields, 'report_id'); end if;
    if input_outcome is null or input_outcome not in ('dismissed', 'hidden', 'suspended') then
        fields := pg_catalog.array_append(fields, 'outcome');
    end if;
    if pg_catalog.cardinality(fields) > 0 then perform private.raise_error('invalid_input', fields); end if;
    perform private.require_operator(input_account_id);
    select r.subject_id into subject from private.reports as r where r.report_id = input_report_id;
    if subject is null then perform private.raise_error('not_found'); end if;
    perform private.lock_account_pair(input_account_id, subject);
    perform private.require_operator(input_account_id);
    select p.moderation_state into subject_state from private.profiles as p where p.user_id = subject for update;
    if not found then perform private.raise_error('not_found'); end if;
    select r.* into report from private.reports as r where r.report_id = input_report_id for update;
    if not found then perform private.raise_error('not_found'); end if;
    if report.status = 'resolved' then
        if report.outcome <> input_outcome then perform private.raise_error('invalid_input', array['outcome']); end if;
    else
        subject_state := private.apply_account_review(subject, input_outcome);
    end if;
    return pg_catalog.jsonb_build_object('report_id', input_report_id, 'status', 'resolved',
        'outcome', input_outcome, 'moderation_state', subject_state);
end;
$$;

create index profiles_moderated_idx on private.profiles ((operator_outcome is not null), user_id) where moderation_state <> 'active';

-- Exact wire parameter names live on SQL wrappers, avoiding column ambiguity.
create function public.block_encounter_person(encounter_id uuid)
returns jsonb language sql security definer set search_path = '' as $$ select private.block_encounter_person($1); $$;
create function public.list_blocks()
returns jsonb language sql security definer set search_path = '' as $$ select private.list_blocks(); $$;
create function public.unblock(block_id uuid)
returns jsonb language sql security definer set search_path = '' as $$ select private.unblock($1); $$;
create function public.report_encounter_person(encounter_id uuid, reason text, link_id uuid default null)
returns jsonb language sql security definer set search_path = '' as $$ select private.report_encounter_person($1, $2, $3); $$;
create function public.delete_encounter(encounter_id uuid)
returns jsonb language sql security definer set search_path = '' as $$ select private.delete_encounter($1); $$;
create function service.list_open_reports(account_id uuid)
returns jsonb language sql security definer set search_path = '' as $$ select private.list_open_reports($1); $$;
create function service.resolve_report(account_id uuid, report_id uuid, outcome text)
returns jsonb language sql security definer set search_path = '' as $$ select private.resolve_report($1, $2, $3); $$;

create function service.list_moderated_accounts(account_id uuid)
returns jsonb language sql security definer set search_path = '' as $$ select private.list_moderated_accounts($1); $$;
create function service.review_account(account_id uuid, subject_id uuid, outcome text)
returns jsonb language sql security definer set search_path = '' as $$ select private.review_account($1, $2, $3); $$;

revoke all on all functions in schema private from public, anon, authenticated, service_role;
revoke all on function public.block_encounter_person(uuid), public.list_blocks(), public.unblock(uuid),
    public.report_encounter_person(uuid, text, uuid), public.delete_encounter(uuid),
    public.get_encounter_card(uuid), public.get_encounter_feed(), public.list_encounter_favorites(),
    public.set_encounter_favorite(uuid, boolean), public.save_link(uuid, uuid), public.unsave_link(uuid, uuid),
    public.list_saved_links(), public.get_daily_report(), public.reveal_ambient_now()
    from public, anon, authenticated, service_role;
grant execute on function public.block_encounter_person(uuid), public.list_blocks(), public.unblock(uuid),
    public.report_encounter_person(uuid, text, uuid), public.delete_encounter(uuid),
    public.get_encounter_card(uuid), public.get_encounter_feed(), public.list_encounter_favorites(),
    public.set_encounter_favorite(uuid, boolean), public.save_link(uuid, uuid), public.unsave_link(uuid, uuid),
    public.list_saved_links(), public.get_daily_report(), public.reveal_ambient_now() to authenticated;
revoke all on function service.list_open_reports(uuid), service.resolve_report(uuid, uuid, text),
    service.list_moderated_accounts(uuid), service.review_account(uuid, uuid, text)
    from public, anon, authenticated, service_role;
grant execute on function service.list_open_reports(uuid), service.resolve_report(uuid, uuid, text),
    service.list_moderated_accounts(uuid), service.review_account(uuid, uuid, text) to service_role;
