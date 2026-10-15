-- Snapshot the installed IANA names once. Reads use its primary key rather
-- than enumerating pg_timezone_names (which computes offsets for every zone).
-- Refresh this lookup in a migration when the installed tzdata adds names.
create table private.iana_time_zones (name text primary key);
insert into private.iana_time_zones (name) select z.name from pg_catalog.pg_timezone_names as z;
alter table private.iana_time_zones enable row level security;
revoke all on table private.iana_time_zones from public, anon, authenticated, service_role;

-- The cached zone catalog can outlive installed tzdata. A bad stored name
-- makes this account's retention unknown rather than aborting a batch.
create function private.try_time_zone(zone_name text, at_time timestamp)
returns timestamptz language plpgsql stable set search_path = '' as $$
begin
    return pg_catalog.timezone(zone_name, at_time);
exception when invalid_parameter_value then return null;
end;
$$;
create function private.try_time_zone(zone_name text, at_time timestamptz)
returns timestamp language plpgsql stable set search_path = '' as $$
begin
    return pg_catalog.timezone(zone_name, at_time);
exception when invalid_parameter_value then return null;
end;
$$;

create table private.saved_links (
    viewer_id uuid not null references auth.users (id) on delete cascade,
    encounter_id uuid not null references private.encounters (encounter_id) on delete cascade,
    link_id uuid not null references private.external_links (link_id) on delete cascade,
    primary key (viewer_id, encounter_id, link_id)
);
create index saved_links_encounter_idx on private.saved_links (encounter_id);
create index saved_links_link_idx on private.saved_links (link_id);
alter table private.saved_links enable row level security;
revoke all on table private.saved_links from public, anon, authenticated, service_role;

-- A saved reference retains a view only while its link is currently shareable.
-- This deliberately ignores expiry: an authorized save is itself a retention reason.
create function private.has_visible_saved_link(viewer_id uuid, input_encounter_id uuid)
returns boolean language sql stable set search_path = '' as $$
    select exists (
        select 1 from private.encounters as e
        join private.saved_links as s on s.encounter_id = e.encounter_id and s.viewer_id = $1
        join private.external_links as l on l.link_id = s.link_id
            and l.owner_id = case when e.user_a = $1 then e.user_b else e.user_a end
        join private.profiles as owner on owner.user_id = l.owner_id and owner.moderation_state = 'active'
        join private.profiles as viewer on viewer.user_id = $1 and viewer.moderation_state = 'active'
        cross join lateral private.encounter_authorization($1, l.owner_id) as a
        where e.encounter_id = $2 and $1 in (e.user_a, e.user_b) and a.eligible
          and (l.visibility = 'everyone_eligible' or (l.visibility = 'compatible_only' and a.compatible))
          and (l.source <> 'github' or private.github_identity_is_live(l.owner_id))
    );
$$;

-- Authorization always yields exactly one facts row, even for absent profiles.
-- Its default SRF estimate of 1000 rows would inflate every counterpart join.
alter function private.encounter_authorization(uuid, uuid) rows 1;

-- One set-returning gate for scalar and list reads, and favorite/save writes.
-- private.reports is created later: add its retained reporter/subject exclusion
-- to this predicate then. The scalar gate below delegates to this same query.
-- Resolve the viewer's zone once, authorize each distinct counterpart once,
-- and aggregate that owner's current fields/links once across all encounters.
create function private.visible_encounter_cards(viewer_id uuid, encounter_ids uuid[] default null,
    favorites_only boolean default false)
returns table (encounter_id uuid, counterpart_id uuid, kind text, day date, favorite boolean,
    compatible boolean, shared_interest_count integer, shared_interest_ids jsonb, card jsonb)
language sql stable security definer set search_path = '' as $$
    with candidates as materialized (
        select e.encounter_id, e.kind,
            case when e.user_a = $1 then e.user_b else e.user_a end as counterpart_id,
            case when e.user_a = $1 then e.day_a else e.day_b end as day, v.favorite
        from private.encounter_views as v
        join private.encounters as e on e.encounter_id = v.encounter_id
        where v.viewer_id = $1 and $1 in (e.user_a, e.user_b) and v.revealed
          and ($2 is null or e.encounter_id = any($2)) and (not $3 or v.favorite)
    ), viewer_zone as materialized (
        -- All registration, scheduling and retention use this shared lookup.
        -- Missing/invalid registration preserves fail-closed retention.
        select z.name
        from (select $1 as viewer_id) as viewer
        left join private.notification_preferences as n on n.user_id = viewer.viewer_id
        left join private.iana_time_zones as z on z.name = n.time_zone
    ), saved_encounters as materialized (
        select c.encounter_id from candidates as c
        where private.has_visible_saved_link($1, c.encounter_id)
    ), retained as materialized (
        select c.* from candidates as c cross join viewer_zone as z
        left join saved_encounters as s on s.encounter_id = c.encounter_id
        -- Add local calendar days before converting midnight to an instant.
        where c.favorite or s.encounter_id is not null
            or pg_catalog.now() < private.try_time_zone(z.name, (c.day + 30)::timestamp)
    ), counterparts as materialized (
        select distinct r.counterpart_id from retained as r
    ), owners as materialized (
        select p.user_id, p.display_name, p.introduction, p.contact_detail,
            a.compatible, a.shared_interest_count
        from counterparts as c join private.profiles as p on p.user_id = c.counterpart_id
        cross join lateral private.encounter_authorization($1, p.user_id) as a
        where a.eligible and p.moderation_state = 'active'
          and exists (select 1 from private.profiles as viewer
              where viewer.user_id = $1 and viewer.moderation_state = 'active')
    ), interests as materialized (
        select i.user_id, pg_catalog.jsonb_agg(i.interest_id order by i.interest_id) as value,
            pg_catalog.jsonb_agg(i.interest_id order by i.interest_id)
                filter (where v.interest_id is not null) as shared_ids
        from private.user_interests as i join owners as o on o.user_id = i.user_id
        left join private.user_interests as v on v.user_id = $1 and v.interest_id = i.interest_id
        group by i.user_id
    ), purposes as materialized (
        select p.user_id, pg_catalog.jsonb_agg(p.purpose order by p.purpose) as value
        from private.user_purposes as p join owners as o on o.user_id = p.user_id
        group by p.user_id
    ), fields as materialized (
        select f.owner_id, pg_catalog.jsonb_object_agg(f.field,
            case f.field
                when 'display_name' then pg_catalog.to_jsonb(o.display_name)
                when 'introduction' then pg_catalog.to_jsonb(o.introduction)
                when 'contact_detail' then pg_catalog.to_jsonb(o.contact_detail)
                when 'interests' then coalesce(i.value, '[]'::jsonb)
                when 'purposes' then coalesce(p.value, '[]'::jsonb)
            end
        ) as value
        from private.field_visibility as f join owners as o on o.user_id = f.owner_id
        left join interests as i on i.user_id = o.user_id
        left join purposes as p on p.user_id = o.user_id
        where f.level = 'everyone_eligible' or (f.level = 'compatible_only' and o.compatible)
        group by f.owner_id
    ), links as materialized (
        select l.owner_id, pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'link_id', l.link_id, 'source', l.source, 'url', l.url,
            'title', l.title, 'description', l.description,
            'main_language', l.main_language, 'tags', l.tags,
            'opening_text', l.opening_text, 'verification_state', l.verification_state
        ) order by l.display_order, l.link_id) as value
        from private.external_links as l join owners as o on o.user_id = l.owner_id
        where (l.visibility = 'everyone_eligible' or (l.visibility = 'compatible_only' and o.compatible))
          and (l.source <> 'github' or private.github_identity_is_live(l.owner_id))
        group by l.owner_id
    )
    select r.encounter_id, r.counterpart_id, r.kind, r.day, r.favorite,
        o.compatible, case when f.value ? 'interests' then
            pg_catalog.jsonb_array_length(coalesce(i.shared_ids, '[]'::jsonb)) else 0 end,
        case when f.value ? 'interests' then coalesce(i.shared_ids, '[]'::jsonb) else '[]'::jsonb end,
        pg_catalog.jsonb_build_object('encounter_id', r.encounter_id, 'kind', r.kind, 'day', r.day)
        || coalesce(f.value, '{}'::jsonb)
        || case when l.value is null then '{}'::jsonb
            else pg_catalog.jsonb_build_object('links', l.value) end
        || case when f.value is null and l.value is null
            then pg_catalog.jsonb_build_object('shell', true) else '{}'::jsonb end
    from retained as r join owners as o on o.user_id = r.counterpart_id
    left join interests as i on i.user_id = o.user_id
    left join fields as f on f.owner_id = o.user_id
    left join links as l on l.owner_id = o.user_id;
$$;

-- Keep the exact scalar gate contract: plain Card or SQL null, no own state.
-- ARRAY[null] selects no encounter; it must never mean the all-encounter scan.
create function private.visible_encounter_card(viewer_id uuid, encounter_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
    select g.card from private.visible_encounter_cards($1, array[$2], false) as g;
$$;

create or replace function private.get_encounter_card(input_encounter_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    caller uuid := private.require_caller();
    card jsonb;
begin
    if input_encounter_id is null then
        perform private.raise_error('invalid_input', array['encounter_id']);
    end if;
    -- The binding own-state amendment applies only to this endpoint. The gate
    -- still returns plain Card; saved IDs include only links in this response.
    select g.card || pg_catalog.jsonb_build_object('favorite', g.favorite,
        'saved_link_ids', coalesce((
            select pg_catalog.jsonb_agg(l.value->'link_id' order by l.position)
            from pg_catalog.jsonb_array_elements(coalesce(g.card->'links', '[]'::jsonb))
                with ordinality as l(value, position)
            join private.saved_links as s on s.viewer_id = caller
                and s.encounter_id = input_encounter_id and s.link_id::text = l.value->>'link_id'
        ), '[]'::jsonb)) into card
    from private.visible_encounter_cards(caller, array[input_encounter_id], false) as g;
    if card is null then perform private.raise_error('not_found'); end if;
    return card;
end;
$$;

-- Favorite filtering, gate, winner selection, ordering and the 201st sentinel
-- share a statement snapshot. Neither list depends on a capped feed result.
create function private.encounter_card_list(viewer_account uuid, favorites_only boolean)
returns jsonb language sql stable security definer set search_path = '' as $$
    with visible as materialized (
        select g.* from private.visible_encounter_cards($1, null, $2) as g
    ), winners as (
        select distinct on (g.counterpart_id, g.kind, g.day) g.* from visible as g
        order by g.counterpart_id, g.kind, g.day, g.favorite desc, g.encounter_id
    ), limited as (
        select g.* from winners as g
        order by g.day desc, g.shared_interest_count desc, g.encounter_id
        limit 201
    ), numbered as (
        select g.*, pg_catalog.row_number() over (
            order by g.day desc, g.shared_interest_count desc, g.encounter_id
        ) as position from limited as g
    )
    select pg_catalog.jsonb_build_object('cards', coalesce(pg_catalog.jsonb_agg(
        g.card || pg_catalog.jsonb_build_object('favorite', g.favorite)
        || case when g.card ? 'interests' then
            pg_catalog.jsonb_build_object('shared_interest_ids', g.shared_interest_ids)
            else '{}'::jsonb end
        order by g.position) filter (where g.position <= 200), '[]'::jsonb),
        'truncated', pg_catalog.count(*) > 200)
    from numbered as g;
$$;

create function private.get_encounter_feed()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    caller uuid := private.require_caller();
begin
    if not private.account_is_ready(caller) then perform private.raise_error('account_not_ready'); end if;
    if not private.effective_discovery_on(caller) then
        perform private.raise_error('prerequisite_missing', array['discovery']);
    end if;
    -- report_deliveries and run_account_report arrive in a later migration.
    -- Add the caller's due report step here then; do not invoke it yet.
    return private.encounter_card_list(caller, false);
end;
$$;

create function private.list_encounter_favorites()
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
    return private.encounter_card_list(private.require_caller(), true);
end;
$$;

create function private.set_encounter_favorite(input_encounter_id uuid, input_favorite boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    caller uuid := private.require_caller();
    fields text[] := '{}'::text[];
begin
    if input_encounter_id is null then fields := pg_catalog.array_append(fields, 'encounter_id'); end if;
    if input_favorite is null then fields := pg_catalog.array_append(fields, 'favorite'); end if;
    if pg_catalog.cardinality(fields) > 0 then perform private.raise_error('invalid_input', fields); end if;
    perform pg_catalog.pg_advisory_xact_lock(31001, pg_catalog.hashtext(caller::text));
    perform private.require_caller();
    -- UPDATE's gate sees the old retention reason, including when this removes
    -- the last one. There is deliberately no post-mutation authorization check.
    update private.encounter_views as v set favorite = input_favorite
    where v.viewer_id = caller and v.encounter_id = input_encounter_id
      and private.visible_encounter_card(caller, input_encounter_id) is not null;
    if not found then perform private.raise_error('not_found'); end if;
    return pg_catalog.jsonb_build_object('encounter_id', input_encounter_id, 'favorite', input_favorite);
exception when foreign_key_violation then
    perform private.link_write_race(caller);
    return null;
end;
$$;

-- Saving requires a currently authorized link. Unsaving also permits the
-- caller to drop an existing reference while still a participant.
-- Materialize authorization before INSERT/DELETE, so removing an expired
-- encounter's last reference succeeds, and an idempotent insert still gates.
create function private.set_saved_link(input_encounter_id uuid, input_link_id uuid, input_saved boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    caller uuid := private.require_caller();
    fields text[] := '{}'::text[];
    authorized boolean;
begin
    if input_encounter_id is null then fields := pg_catalog.array_append(fields, 'encounter_id'); end if;
    if input_link_id is null then fields := pg_catalog.array_append(fields, 'link_id'); end if;
    if pg_catalog.cardinality(fields) > 0 then perform private.raise_error('invalid_input', fields); end if;
    perform pg_catalog.pg_advisory_xact_lock(31001, pg_catalog.hashtext(caller::text));
    perform private.require_caller();
    if input_saved then
        with visible as materialized (
            select private.visible_encounter_card(caller, input_encounter_id) as card
        ), eligible as materialized (
            select 1 from visible as g
            cross join lateral pg_catalog.jsonb_array_elements(coalesce(g.card->'links', '[]'::jsonb)) as l(value)
            where l.value->>'link_id' = input_link_id::text
        ), inserted as (
            insert into private.saved_links (viewer_id, encounter_id, link_id)
            select caller, input_encounter_id, input_link_id from eligible
            on conflict (viewer_id, encounter_id, link_id) do nothing returning 1
        )
        select exists (select 1 from eligible) into authorized;
    else
        with visible as materialized (
            select private.visible_encounter_card(caller, input_encounter_id) as card
        ), eligible as materialized (
            select 1 from visible as g
            cross join lateral pg_catalog.jsonb_array_elements(coalesce(g.card->'links', '[]'::jsonb)) as l(value)
            where l.value->>'link_id' = input_link_id::text
            union all
            select 1 from private.saved_links as s
            join private.encounters as e on e.encounter_id = s.encounter_id
            where s.viewer_id = caller and s.encounter_id = input_encounter_id and s.link_id = input_link_id
              and caller in (e.user_a, e.user_b)
        ), removed as (
            delete from private.saved_links as s
            where s.viewer_id = caller and s.encounter_id = input_encounter_id and s.link_id = input_link_id
              and exists (select 1 from eligible) returning 1
        )
        select exists (select 1 from eligible) into authorized;
    end if;
    if not authorized then perform private.raise_error('not_found'); end if;
    return pg_catalog.jsonb_build_object('encounter_id', input_encounter_id, 'link_id', input_link_id, 'saved', input_saved);
exception when foreign_key_violation then
    perform private.link_write_race(caller);
    return null;
end;
$$;

create function private.list_saved_links()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    caller uuid := private.require_caller();
    result jsonb;
begin
    with visible as materialized (
        -- One gate call for distinct encounters, not one call per reference.
        select g.* from private.visible_encounter_cards(caller, array(
            select distinct s.encounter_id from private.saved_links as s where s.viewer_id = caller
        ), false) as g
    ), limited as (
        select g.encounter_id, s.link_id, g.day, g.kind, l.value as link, l.position as link_order
        from visible as g
        join private.saved_links as s on s.viewer_id = caller and s.encounter_id = g.encounter_id
        cross join lateral pg_catalog.jsonb_array_elements(coalesce(g.card->'links', '[]'::jsonb))
            with ordinality as l(value, position)
        where l.value->>'link_id' = s.link_id::text
        order by g.day desc, g.encounter_id, l.position, s.link_id limit 201
    ), numbered as (
        select g.*, pg_catalog.row_number() over (
            order by g.day desc, g.encounter_id, g.link_order, g.link_id
        ) as position from limited as g
    )
    select pg_catalog.jsonb_build_object('links', coalesce(pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object('encounter_id', g.encounter_id, 'day', g.day, 'kind', g.kind, 'link', g.link)
        order by g.position) filter (where g.position <= 200), '[]'::jsonb),
        'truncated', pg_catalog.count(*) > 200) into result
    from numbered as g;
    return result;
end;
$$;

-- Keep exact PostgREST names on the public SQL wrappers.
create or replace function public.get_encounter_card(encounter_id uuid)
returns jsonb language sql security definer set search_path = '' as $$
    select private.get_encounter_card($1);
$$;
create function public.get_encounter_feed()
returns jsonb language sql security definer set search_path = '' as $$
    select private.get_encounter_feed();
$$;
create function public.list_encounter_favorites()
returns jsonb language sql security definer set search_path = '' as $$
    select private.list_encounter_favorites();
$$;
create function public.set_encounter_favorite(encounter_id uuid, favorite boolean)
returns jsonb language sql security definer set search_path = '' as $$
    select private.set_encounter_favorite($1, $2);
$$;
create function public.save_link(encounter_id uuid, link_id uuid)
returns jsonb language sql security definer set search_path = '' as $$
    select private.set_saved_link($1, $2, true);
$$;
create function public.unsave_link(encounter_id uuid, link_id uuid)
returns jsonb language sql security definer set search_path = '' as $$
    select private.set_saved_link($1, $2, false);
$$;
create function public.list_saved_links()
returns jsonb language sql security definer set search_path = '' as $$
    select private.list_saved_links();
$$;

revoke all on all functions in schema private from public, anon, authenticated, service_role;
revoke all on function public.get_encounter_card(uuid) from public, anon, authenticated, service_role;
grant execute on function public.get_encounter_card(uuid) to authenticated;
revoke all on function public.get_encounter_feed() from public, anon, authenticated, service_role;
grant execute on function public.get_encounter_feed() to authenticated;
revoke all on function public.list_encounter_favorites() from public, anon, authenticated, service_role;
grant execute on function public.list_encounter_favorites() to authenticated;
revoke all on function public.set_encounter_favorite(uuid, boolean) from public, anon, authenticated, service_role;
grant execute on function public.set_encounter_favorite(uuid, boolean) to authenticated;
revoke all on function public.save_link(uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.save_link(uuid, uuid) to authenticated;
revoke all on function public.unsave_link(uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.unsave_link(uuid, uuid) to authenticated;
revoke all on function public.list_saved_links() from public, anon, authenticated, service_role;
grant execute on function public.list_saved_links() to authenticated;
