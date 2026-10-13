create table private.report_deliveries (
    user_id uuid not null references auth.users (id) on delete cascade,
    report_day date not null,
    status text not null check (status in ('open', 'closed')),
    primary key (user_id, report_day)
);
create index report_deliveries_open_idx on private.report_deliveries (report_day, user_id) where status = 'open';

create table private.server_settings (
    singleton boolean primary key default true check (singleton),
    environment text not null default 'production' check (environment in ('local', 'non_production', 'production')),
    demo_reveal_enabled boolean not null default false,
    operator_account_id uuid references auth.users (id) on delete set null,
    check (environment <> 'production' or not demo_reveal_enabled)
);
create index server_settings_operator_idx on private.server_settings (operator_account_id);
insert into private.server_settings (singleton) values (true);

alter table private.report_deliveries enable row level security;
alter table private.server_settings enable row level security;
revoke all on table private.report_deliveries, private.server_settings from public, anon, authenticated, service_role;
alter table private.encounter_views add column revealed_report_day date;
create index encounter_views_revealed_report_idx on private.encounter_views (viewer_id, revealed_report_day);
create index encounter_views_waiting_report_idx on private.encounter_views (viewer_id, reveal_report_day)
    where not revealed;

-- PostgreSQL's direct local-to-UTC conversion chooses the later repeat and
-- preserves the minutes inside a gap. Instead, round-trip the offsets on both
-- sides of the transition, select the earliest real instant, and advance an
-- invalid wall minute until it exists. Offset arithmetic also preserves the
-- seconds in historical IANA offsets and handles a whole skipped local date.
create function private.report_instant_in_zone(local_day date, report_hour integer, report_minute integer, zone_name text)
returns timestamptz language plpgsql stable security definer set search_path = '' as $$
declare
    wall_minute timestamp := local_day::timestamp + pg_catalog.make_interval(hours => report_hour, mins => report_minute);
    conventional timestamptz := pg_catalog.timezone(zone_name, wall_minute);
    offsets interval[];
    scheduled timestamptz;
begin
    select pg_catalog.array_agg(distinct pg_catalog.timezone(zone_name, s.instant)
        - pg_catalog.timezone('UTC', s.instant)) into offsets
    from pg_catalog.generate_series(conventional - interval '48 hours', conventional + interval '48 hours',
        interval '1 hour') as s(instant);
    loop
        select pg_catalog.min(c.instant) into scheduled
        from pg_catalog.unnest(offsets) as o(value)
        cross join lateral (select pg_catalog.timezone('UTC', wall_minute - o.value) as instant) as c
        where pg_catalog.timezone(zone_name, c.instant) = wall_minute;
        exit when scheduled is not null;
        wall_minute := wall_minute + interval '1 minute';
    end loop;
    return scheduled;
end;
$$;

create function private.local_report_instant(account_id uuid, report_day date)
returns timestamptz language plpgsql volatile security definer set search_path = '' as $$
declare
    fields text[] := '{}'::text[];
    preferences private.notification_preferences%rowtype;
begin
    if account_id is null then fields := pg_catalog.array_append(fields, 'account_id'); end if;
    if report_day is null then fields := pg_catalog.array_append(fields, 'report_day'); end if;
    if pg_catalog.cardinality(fields) > 0 then perform private.raise_error('invalid_input', fields); end if;
    select n.* into preferences from private.notification_preferences as n where n.user_id = account_id;
    if not found or not exists (select 1 from private.iana_time_zones as z
        where z.name = preferences.time_zone) then perform private.raise_error('account_not_ready'); end if;
    return private.report_instant_in_zone(report_day, preferences.report_hour, preferences.report_minute, preferences.time_zone);
end;
$$;

-- Confirmation retains Unit 3's 21:00 UTC fallback for a peer whose preferences
-- disappeared. Receipt confirmation holds only the uploader's account lock;
-- settings use the same helper under the account lock of their caller.
create function private.next_report_day(account_id uuid, report_at timestamptz)
returns date language plpgsql stable security definer set search_path = '' as $$
declare
    preferences private.notification_preferences%rowtype;
    next_day date;
begin
    select n.* into preferences from private.notification_preferences as n where n.user_id = account_id;
    if not found then
        preferences.time_zone := 'UTC'; preferences.report_hour := 21; preferences.report_minute := 0;
    end if;
    next_day := (report_at at time zone preferences.time_zone)::date;
    while private.report_instant_in_zone(next_day, preferences.report_hour, preferences.report_minute,
        preferences.time_zone) <= report_at or exists (
            select 1 from private.report_deliveries as d
            where d.user_id = account_id and d.report_day = next_day and d.status = 'closed'
        ) loop
        next_day := next_day + 1;
    end loop;
    return next_day;
end;
$$;

-- Retention is independent of current visibility/discovery. No authorization
-- gate is used to advance flags; the shared card gate is applied on response.
create function private.waiting_ambient_views(account_id uuid, report_at timestamptz)
returns table (encounter_id uuid, reveal_report_day date)
language sql stable security definer set search_path = '' as $$
    with viewer_zone as materialized (
        select z.name from private.notification_preferences as n
        join private.iana_time_zones as z on z.name = n.time_zone where n.user_id = $1
    )
    select v.encounter_id, v.reveal_report_day
    from private.encounter_views as v join private.encounters as e on e.encounter_id = v.encounter_id
    left join viewer_zone as z on true
    where v.viewer_id = $1 and not v.revealed and e.kind = 'ambient' and $1 in (e.user_a, e.user_b)
      and (v.favorite or exists (select 1 from private.saved_links as s
            where s.viewer_id = $1 and s.encounter_id = v.encounter_id)
        or $2 < pg_catalog.timezone(z.name, ((case when e.user_a = $1 then e.day_a else e.day_b end) + 30)::timestamp));
$$;

-- Ordinary days need only local-clock/offset arithmetic. Near a transition,
-- use the exact gap/repeat rule, including historical offsets/skipped dates.
create function private.latest_due_report_day(zone_name text, report_hour integer,
    report_minute integer, report_at timestamptz)
returns date language plpgsql stable security definer set search_path = '' as $$
declare
    local_clock timestamp;
    current_offset interval;
    due_day date;
begin
    if report_at is null or not exists (select 1 from private.iana_time_zones as z
        where z.name = zone_name) then return null; end if;
    local_clock := pg_catalog.timezone(zone_name, report_at);
    current_offset := local_clock - pg_catalog.timezone('UTC', report_at);
    due_day := local_clock::date;
    if current_offset = pg_catalog.timezone(zone_name, report_at - interval '48 hours')
            - pg_catalog.timezone('UTC', report_at - interval '48 hours')
        and current_offset = pg_catalog.timezone(zone_name, report_at + interval '48 hours')
            - pg_catalog.timezone('UTC', report_at + interval '48 hours') then
        return due_day - case when local_clock::time < pg_catalog.make_time(report_hour, report_minute, 0)
            then 1 else 0 end;
    end if;
    while private.report_instant_in_zone(due_day, report_hour, report_minute, zone_name) > report_at loop
        due_day := due_day - 1;
    end loop;
    return due_day;
end;
$$;

-- Read-only, set-based selection: no account/row locks, report step or writes.
-- PK delivery probes eliminate closed accounts without running a report step.
-- A late view assigned to a closed date waits for the next later delivery key.
create function private.due_report_accounts(report_at timestamptz)
returns table (account_id uuid)
language sql stable security definer set search_path = '' as $$
    with schedules as materialized (
        select n.user_id, private.latest_due_report_day(z.name, n.report_hour, n.report_minute, $1) as due_day
        from private.notification_preferences as n
        join private.iana_time_zones as z on z.name = n.time_zone
        join auth.users as u on u.id = n.user_id
        join private.profiles as p on p.user_id = n.user_id
        where $1 is not null and p.moderation_state = 'active' and p.age_18_declared
          and private.trim_input(p.terms_version) <> '' and private.trim_input(p.privacy_version) <> ''
    )
    select s.user_id from schedules as s
    where s.due_day is not null and (
        not exists (select 1 from private.report_deliveries as d
            where d.user_id = s.user_id and d.report_day = s.due_day and d.status = 'closed')
        or exists (select 1 from private.report_deliveries as d
            where d.user_id = s.user_id and d.status = 'open' and d.report_day < s.due_day)
    );
$$;

create function private.run_account_report(account_id uuid, report_at timestamptz default pg_catalog.now())
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    fields text[] := '{}'::text[];
    due_day date;
    delivery_status text;
    newly_revealed uuid[];
begin
    if account_id is null then fields := pg_catalog.array_append(fields, 'account_id'); end if;
    if report_at is null then fields := pg_catalog.array_append(fields, 'report_at'); end if;
    if pg_catalog.cardinality(fields) > 0 then perform private.raise_error('invalid_input', fields); end if;
    if private.account_is_ready(account_id) then
        select private.latest_due_report_day(z.name, n.report_hour, n.report_minute, report_at)
        into due_day from private.notification_preferences as n
        join private.iana_time_zones as z on z.name = n.time_zone
        join auth.users as u on u.id = n.user_id where n.user_id = account_id;
    end if;
    if due_day is null then
        return pg_catalog.jsonb_build_object('report_day', null, 'newly_revealed_encounter_ids', '[]'::jsonb, 'closed', false);
    end if;
    -- A closed, caught-up read does not serialize or attempt any row write.
    if exists (select 1 from private.report_deliveries as d
        where d.user_id = account_id and d.report_day = due_day and d.status = 'closed')
        and not exists (select 1 from private.report_deliveries as d
            where d.user_id = account_id and d.status = 'open' and d.report_day < due_day)
        and not exists (select 1 from private.waiting_ambient_views(account_id, report_at) as w
            where w.reveal_report_day <= due_day) then
        return pg_catalog.jsonb_build_object('report_day', due_day, 'newly_revealed_encounter_ids', '[]'::jsonb, 'closed', false);
    end if;
    perform pg_catalog.pg_advisory_xact_lock(31001, pg_catalog.hashtext(account_id::text));
    -- Recheck live Auth, readiness and the schedule after serialization.
    due_day := null;
    if private.account_is_ready(account_id) then
        select private.latest_due_report_day(z.name, n.report_hour, n.report_minute, report_at)
        into due_day from private.notification_preferences as n
        join private.iana_time_zones as z on z.name = n.time_zone
        join auth.users as u on u.id = n.user_id where n.user_id = account_id;
    end if;
    if due_day is null then
        return pg_catalog.jsonb_build_object('report_day', null, 'newly_revealed_encounter_ids', '[]'::jsonb, 'closed', false);
    end if;
    insert into private.report_deliveries (user_id, report_day, status) values (account_id, due_day, 'open')
    on conflict (user_id, report_day) do nothing;
    select d.status into delivery_status from private.report_deliveries as d
    where d.user_id = account_id and d.report_day = due_day for update;
    -- Older dates are due too. Close their open keys even on a latest-key replay.
    update private.report_deliveries as d set status = 'closed'
    where d.user_id = account_id and d.status = 'open' and d.report_day < due_day;
    if delivery_status = 'closed' then
        return pg_catalog.jsonb_build_object('report_day', due_day, 'newly_revealed_encounter_ids', '[]'::jsonb, 'closed', false);
    end if;
    -- Confirmation takes no peer account locks. Views arriving behind a closed
    -- assigned date wait for the next later report and get that delivery's date.
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
    raise;
end;
$$;

-- Cron must issue a top-level CALL outside an explicit transaction. This
-- invoker procedure has no SET clause: both SET and SECURITY DEFINER prohibit
-- transaction control. Only the migration owner can execute it.
create procedure private.run_due_reports(report_at timestamptz default pg_catalog.now())
language plpgsql security invoker as $$
declare account_id uuid;
begin
    if report_at is null then perform private.raise_error('invalid_input', array['report_at']); end if;
    for account_id in select d.account_id from private.due_report_accounts(report_at) as d order by d.account_id loop
        begin
            perform private.run_account_report(account_id, report_at);
        exception when others then
            -- The exception subtransaction rolls back this account only.
            raise warning 'Report step failed for account % (SQLSTATE %)', account_id, sqlstate;
        end;
        -- Outside the exception block; releases all locks before the next step.
        commit;
    end loop;
end;
$$;

create function private.report_settings_json(account_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
    select pg_catalog.jsonb_build_object('report_hour', n.report_hour, 'report_minute', n.report_minute,
        'time_zone', n.time_zone, 'notifications_enabled', n.notifications_enabled)
    from private.notification_preferences as n where n.user_id = $1;
$$;

create function private.get_report_settings()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare result jsonb := private.report_settings_json(private.require_caller());
begin
    if result is null then perform private.raise_error('account_not_ready'); end if;
    return result;
end;
$$;

create function private.set_report_time(input_hour integer, input_minute integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    caller uuid := private.require_caller();
    fields text[] := '{}'::text[];
    preferences private.notification_preferences%rowtype;
    next_day date;
begin
    if input_hour is null or input_hour not between 0 and 23 then fields := pg_catalog.array_append(fields, 'hour'); end if;
    if input_minute is null or input_minute not between 0 and 59 then fields := pg_catalog.array_append(fields, 'minute'); end if;
    if pg_catalog.cardinality(fields) > 0 then perform private.raise_error('invalid_input', fields); end if;
    perform pg_catalog.pg_advisory_xact_lock(31001, pg_catalog.hashtext(caller::text));
    perform private.require_caller();
    select n.* into preferences from private.notification_preferences as n where n.user_id = caller for update;
    if not found then perform private.raise_error('account_not_ready'); end if;
    if preferences.report_hour <> input_hour or preferences.report_minute <> input_minute then
        update private.notification_preferences as n set report_hour = input_hour, report_minute = input_minute where n.user_id = caller;
        next_day := private.next_report_day(caller, pg_catalog.now());
        update private.encounter_views as v set reveal_report_day = next_day
        where v.viewer_id = caller and not v.revealed;
    end if;
    return private.report_settings_json(caller);
exception when foreign_key_violation then
    perform private.link_write_race(caller);
    return null;
end;
$$;

create function private.set_notifications_enabled(input_enabled boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare caller uuid := private.require_caller();
begin
    if input_enabled is null then perform private.raise_error('invalid_input', array['enabled']); end if;
    perform pg_catalog.pg_advisory_xact_lock(31001, pg_catalog.hashtext(caller::text));
    perform private.require_caller();
    update private.notification_preferences as n set notifications_enabled = input_enabled where n.user_id = caller;
    if not found then perform private.raise_error('account_not_ready'); end if;
    return private.report_settings_json(caller);
exception when foreign_key_violation then
    perform private.link_write_race(caller);
    return null;
end;
$$;

create or replace function private.register_time_zone(input_time_zone text)
returns void language plpgsql security definer set search_path = '' as $$
declare
    caller uuid := private.require_caller();
    previous_zone text;
    next_day date;
begin
    perform pg_catalog.pg_advisory_xact_lock(31001, pg_catalog.hashtext(caller::text));
    perform private.require_caller();
    if private.record_account_event(caller, 'register_time_zone', 10, interval '1 day') then
        perform private.raise_error('rate_limited');
    end if;
    perform 1 from private.profiles as p where p.user_id = caller for update;
    if not found then perform private.raise_error('declaration_required'); end if;
    if input_time_zone is null or not exists (select 1 from private.iana_time_zones as z where z.name = input_time_zone) then
        perform private.raise_error('invalid_input', array['time_zone']);
    end if;
    select n.time_zone into previous_zone from private.notification_preferences as n where n.user_id = caller;
    insert into private.notification_preferences as n (user_id, time_zone) values (caller, input_time_zone)
    on conflict (user_id) do update set time_zone = excluded.time_zone;
    if previous_zone is distinct from input_time_zone then
        next_day := private.next_report_day(caller, pg_catalog.now());
        update private.encounter_views as v set reveal_report_day = next_day
        where v.viewer_id = caller and not v.revealed;
    end if;
exception when foreign_key_violation then
    perform private.link_write_race(caller);
end;
$$;

create or replace function private.confirm_encounter(account_a uuid, account_b uuid, encounter_kind text,
    observation_a bigint, observation_b bigint, server_time timestamptz)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
    ordered_a uuid := least(account_a, account_b);
    ordered_b uuid := greatest(account_a, account_b);
    encounter_day_a date;
    encounter_day_b date;
    confirmed_encounter uuid;
    new_encounter boolean;
    viewer uuid;
    viewer_observation bigint;
    viewer_zone text;
begin
    for viewer, viewer_observation in select account_a, observation_a union all select account_b, observation_b loop
        select n.time_zone into viewer_zone from private.notification_preferences as n where n.user_id = viewer;
        viewer_zone := coalesce(viewer_zone, 'UTC');
        if viewer = ordered_a then
            encounter_day_a := (pg_catalog.to_timestamp(viewer_observation::double precision) at time zone viewer_zone)::date;
        else
            encounter_day_b := (pg_catalog.to_timestamp(viewer_observation::double precision) at time zone viewer_zone)::date;
        end if;
    end loop;
    insert into private.encounters (user_a, user_b, kind, day_a, day_b)
    values (ordered_a, ordered_b, encounter_kind, encounter_day_a, encounter_day_b)
    on conflict (user_a, user_b, kind, day_a, day_b) do nothing returning encounter_id into confirmed_encounter;
    new_encounter := confirmed_encounter is not null;
    if not new_encounter then
        select e.encounter_id into confirmed_encounter from private.encounters as e
        where e.user_a = ordered_a and e.user_b = ordered_b and e.kind = encounter_kind
          and e.day_a = encounter_day_a and e.day_b = encounter_day_b;
    end if;
    if new_encounter or encounter_kind = 'qr' then
        for viewer in select account_a union all select account_b loop
            insert into private.encounter_views (encounter_id, viewer_id, revealed, reveal_report_day)
            values (confirmed_encounter, viewer, encounter_kind in ('session', 'qr'), private.next_report_day(viewer, server_time))
            on conflict (encounter_id, viewer_id) do update set revealed = true, revealed_report_day = null;
        end loop;
    end if;
    return confirmed_encounter;
end;
$$;

-- Apply report membership/new-demo IDs before the existing gate, dedup and cap.
create function private.report_card_list(viewer_account uuid, encounter_ids uuid[])
returns jsonb language sql stable security definer set search_path = '' as $$
    with visible as materialized (
        select g.* from private.visible_encounter_cards($1, $2, false) as g
    ), winners as (
        select distinct on (g.counterpart_id, g.kind, g.day) g.* from visible as g
        order by g.counterpart_id, g.kind, g.day, g.favorite desc, g.encounter_id
    ), limited as (
        select g.* from winners as g
        order by g.day desc, g.compatible desc, g.shared_interest_count desc, g.encounter_id limit 201
    ), numbered as (
        select g.*, pg_catalog.row_number() over (
            order by g.day desc, g.compatible desc, g.shared_interest_count desc, g.encounter_id
        ) as position from limited as g
    )
    select pg_catalog.jsonb_build_object('cards', coalesce(pg_catalog.jsonb_agg(
        g.card || pg_catalog.jsonb_build_object('favorite', g.favorite)
        || case when g.card ? 'interests' then pg_catalog.jsonb_build_object('shared_interest_ids', g.shared_interest_ids)
            else '{}'::jsonb end order by g.position) filter (where g.position <= 200), '[]'::jsonb),
        'truncated', pg_catalog.count(*) > 200) from numbered as g;
$$;

create function private.get_daily_report()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    caller uuid := private.require_caller();
    latest_day date;
begin
    if not private.account_is_ready(caller) then perform private.raise_error('account_not_ready'); end if;
    perform private.run_account_report(caller);
    perform private.require_caller();
    select pg_catalog.max(d.report_day) into latest_day from private.report_deliveries as d
    where d.user_id = caller and d.status = 'closed';
    return pg_catalog.jsonb_build_object('report_day', latest_day) || private.report_card_list(caller, array(
        select v.encounter_id from private.encounter_views as v join private.encounters as e on e.encounter_id = v.encounter_id
        where v.viewer_id = caller and v.revealed and v.revealed_report_day = latest_day and e.kind = 'ambient'
    ));
end;
$$;

create function private.reveal_ambient_now()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    caller uuid := private.require_caller();
    newly_revealed uuid[];
begin
    perform pg_catalog.pg_advisory_xact_lock(31001, pg_catalog.hashtext(caller::text));
    perform private.require_caller();
    -- Check deployment configuration before any readiness/discovery check.
    if not exists (select 1 from private.server_settings as s
        where s.singleton and s.environment in ('local', 'non_production') and s.demo_reveal_enabled) then
        perform private.raise_error('not_found');
    end if;
    if not private.account_is_ready(caller) then perform private.raise_error('account_not_ready'); end if;
    if not exists (select 1 from private.profiles as p where p.user_id = caller and p.discovery_on) then
        perform private.raise_error('prerequisite_missing', array['discovery']);
    end if;
    with revealed as (
        update private.encounter_views as v set revealed = true, revealed_report_day = null
        where v.viewer_id = caller and v.encounter_id in (
            select w.encounter_id from private.waiting_ambient_views(caller, pg_catalog.now()) as w
        ) returning v.encounter_id
    ) select coalesce(pg_catalog.array_agg(r.encounter_id order by r.encounter_id), '{}'::uuid[])
    into newly_revealed from revealed as r;
    return private.report_card_list(caller, newly_revealed);
end;
$$;

create function private.set_demo_reveal_enabled(account_id uuid, enabled boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare fields text[] := '{}'::text[]; settings private.server_settings%rowtype;
begin
    if account_id is null then fields := pg_catalog.array_append(fields, 'account_id'); end if;
    if enabled is null then fields := pg_catalog.array_append(fields, 'enabled'); end if;
    if pg_catalog.cardinality(fields) > 0 then perform private.raise_error('invalid_input', fields); end if;
    perform pg_catalog.pg_advisory_xact_lock(31001, pg_catalog.hashtext(account_id::text));
    if not exists (select 1 from auth.users as u where u.id = account_id) then perform private.raise_error('not_authenticated'); end if;
    select s.* into settings from private.server_settings as s where s.singleton for update;
    if not found or settings.operator_account_id is distinct from account_id
        or (enabled and settings.environment = 'production') then perform private.raise_error('not_found'); end if;
    update private.server_settings as s set demo_reveal_enabled = enabled where s.singleton;
    return pg_catalog.jsonb_build_object('demo_reveal_enabled', enabled);
end;
$$;

create or replace function private.get_encounter_feed()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare caller uuid := private.require_caller();
begin
    if not private.account_is_ready(caller) then perform private.raise_error('account_not_ready'); end if;
    if not exists (select 1 from private.profiles as p where p.user_id = caller and p.discovery_on) then
        perform private.raise_error('prerequisite_missing', array['discovery']);
    end if;
    perform private.run_account_report(caller);
    perform private.require_caller();
    return private.encounter_card_list(caller, false);
end;
$$;

-- Only the delivery-key retention belonging to daily reports is added here.
-- Preserve keys if a retained waiting view would still depend on an older key.
create or replace function private.cleanup_expired_data(cleanup_at timestamptz default pg_catalog.now())
returns void language plpgsql security definer set search_path = '' as $$
begin
    if cleanup_at is null then perform private.raise_error('invalid_input', array['cleanup_at']); end if;
    delete from private.encounter_candidates as c where c.expires_at < cleanup_at - interval '300 seconds';
    delete from private.temporary_tokens as t where t.delete_after <= extract(epoch from cleanup_at);
    delete from private.consumed_nonces as n where n.delete_after <= (cleanup_at at time zone 'UTC')::date;
    delete from private.account_limit_events as e
    where e.occurred_at < cleanup_at - case when e.bucket in ('register_time_zone', 'report_encounter_person')
        then interval '1 day' else interval '1 hour' end;
    delete from private.qr_codes as q where q.expires_at <= pg_catalog.floor(extract(epoch from cleanup_at))::bigint;
    delete from private.sessions as s where least(s.expires_at, s.stopped_at) <= cleanup_at - interval '48 hours';
    delete from private.report_deliveries as d using private.notification_preferences as n
    where n.user_id = d.user_id and d.status = 'closed'
      and d.report_day <= (cleanup_at at time zone n.time_zone)::date - 30
      and not exists (select 1 from private.waiting_ambient_views(d.user_id, cleanup_at) as w
          where w.reveal_report_day <= d.report_day);
end;
$$;

-- Quoting the SQL keywords preserves the exact PostgREST names hour/minute.
create function public.get_report_settings()
returns jsonb language sql security definer set search_path = '' as $$ select private.get_report_settings(); $$;
create function public.set_report_time("hour" integer, "minute" integer)
returns jsonb language sql security definer set search_path = '' as $$ select private.set_report_time($1, $2); $$;
create function public.set_notifications_enabled(enabled boolean)
returns jsonb language sql security definer set search_path = '' as $$ select private.set_notifications_enabled($1); $$;
create function public.get_daily_report()
returns jsonb language sql security definer set search_path = '' as $$ select private.get_daily_report(); $$;
create function public.reveal_ambient_now()
returns jsonb language sql security definer set search_path = '' as $$ select private.reveal_ambient_now(); $$;
create function service.set_demo_reveal_enabled(account_id uuid, enabled boolean)
returns jsonb language sql security definer set search_path = '' as $$ select private.set_demo_reveal_enabled($1, $2); $$;

revoke all on all functions in schema private from public, anon, authenticated, service_role;
revoke all on procedure private.run_due_reports(timestamptz) from public, anon, authenticated, service_role;
revoke all on function public.get_report_settings(), public.set_report_time(integer, integer),
    public.set_notifications_enabled(boolean), public.get_daily_report(), public.reveal_ambient_now(),
    public.register_time_zone(text), public.get_encounter_feed() from public, anon, authenticated, service_role;
grant execute on function public.get_report_settings(), public.set_report_time(integer, integer),
    public.set_notifications_enabled(boolean), public.get_daily_report(), public.reveal_ambient_now(),
    public.register_time_zone(text), public.get_encounter_feed() to authenticated;
revoke all on function service.set_demo_reveal_enabled(uuid, boolean) from public, anon, authenticated, service_role;
grant execute on function service.set_demo_reveal_enabled(uuid, boolean) to service_role;

do $$
begin
    perform cron.schedule('encounters-daily-reports', '*/5 * * * *', 'call private.run_due_reports();');
end;
$$;

-- Receipt resolution preserves Unit 3's caller-only account lock, then sorted
-- nonce and pair locks. Confirmation races use later-report catch-up above.
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
    -- Account deletion may race validation once the shared helpers no longer
    -- lock Auth rows. Never return the participant UUID from a foreign-key error.
    perform private.raise_error('not_found');
    return null;
end;
$$;

revoke all on function public.submit_receipts(jsonb) from public, anon, authenticated, service_role;
grant execute on function public.submit_receipts(jsonb) to authenticated;
