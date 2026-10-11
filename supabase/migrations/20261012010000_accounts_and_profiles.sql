create schema private;

revoke all on schema private from public, anon, authenticated;

create table private.profiles (
    user_id uuid primary key references auth.users (id) on delete cascade,
    display_name text not null default '' check (pg_catalog.char_length(display_name) <= 30),
    introduction text not null default '' check (pg_catalog.char_length(introduction) <= 200),
    contact_detail text not null default '' check (pg_catalog.char_length(contact_detail) <= 100),
    discovery_on boolean not null default false,
    age_18_declared boolean not null check (age_18_declared),
    terms_version text not null check (pg_catalog.btrim(terms_version) <> '' and pg_catalog.char_length(terms_version) <= 32),
    privacy_version text not null check (pg_catalog.btrim(privacy_version) <> '' and pg_catalog.char_length(privacy_version) <= 32),
    moderation_state text not null default 'active' check (moderation_state in ('active', 'hidden', 'suspended'))
);

create table private.interests (
    interest_id text primary key check (pg_catalog.btrim(interest_id) <> ''),
    label_ja text not null,
    label_en text not null,
    display_order integer not null default 0
);

create table private.user_interests (
    user_id uuid not null references auth.users (id) on delete cascade,
    interest_id text not null references private.interests (interest_id),
    primary key (user_id, interest_id)
);

create table private.user_purposes (
    user_id uuid not null references auth.users (id) on delete cascade,
    purpose text not null check (purpose in ('discovery', 'collaboration')),
    primary key (user_id, purpose)
);

create table private.matching_preferences (
    user_id uuid primary key references auth.users (id) on delete cascade,
    minimum_shared_interests integer not null default 1 check (minimum_shared_interests between 1 and 10)
);

create table private.field_visibility (
    owner_id uuid not null references auth.users (id) on delete cascade,
    field text not null check (field in ('display_name', 'introduction', 'interests', 'purposes', 'contact_detail')),
    level text not null check (level in ('everyone_eligible', 'compatible_only', 'private')),
    primary key (owner_id, field)
);

create table private.notification_preferences (
    user_id uuid primary key references auth.users (id) on delete cascade,
    report_hour smallint not null default 21 check (report_hour between 0 and 23),
    report_minute smallint not null default 0 check (report_minute between 0 and 59),
    time_zone text not null,
    notifications_enabled boolean not null default true
);

create table private.external_links (
    link_id uuid primary key default pg_catalog.gen_random_uuid(),
    owner_id uuid not null references auth.users (id) on delete cascade,
    source text not null,
    source_item_id text,
    url text not null,
    title text not null default '',
    description text not null default '',
    main_language text,
    tags text[] not null default '{}'::text[],
    opening_text text not null default '',
    visibility text not null check (visibility in ('everyone_eligible', 'compatible_only', 'private')),
    verification_state text not null default 'unverified',
    display_order integer not null default 0
);

create index external_links_owner_id_idx on private.external_links (owner_id);

create table private.blocks (
    blocker_id uuid not null references auth.users (id) on delete cascade,
    blocked_id uuid not null references auth.users (id) on delete cascade,
    primary key (blocker_id, blocked_id),
    check (blocker_id <> blocked_id)
);

create index blocks_blocked_id_idx on private.blocks (blocked_id);

alter table private.profiles enable row level security;
alter table private.interests enable row level security;
alter table private.user_interests enable row level security;
alter table private.user_purposes enable row level security;
alter table private.matching_preferences enable row level security;
alter table private.field_visibility enable row level security;
alter table private.notification_preferences enable row level security;
alter table private.external_links enable row level security;
alter table private.blocks enable row level security;

revoke all on all tables in schema private from public, anon, authenticated;

create function private.raise_error(code text, fields text[] default '{}'::text[])
returns void
language plpgsql
set search_path = ''
as $$
begin
    if pg_catalog.cardinality(fields) > 0 then
        raise exception using errcode = 'P0001', message = code,
            detail = pg_catalog.array_to_string(fields, ',');
    end if;
    raise exception using errcode = 'P0001', message = code;
end;
$$;

create function private.require_caller()
returns uuid
language plpgsql
set search_path = ''
as $$
declare
    caller uuid := auth.uid();
begin
    if caller is null then
        perform private.raise_error('not_authenticated');
    end if;
    -- Account deletion cannot race a write after the live-caller check.
    perform 1 from auth.users as u where u.id = caller for key share;
    if not found then
        perform private.raise_error('not_authenticated');
    end if;
    return caller;
end;
$$;

create function private.account_is_ready(account_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
    select exists (
        select 1
        from private.profiles as p
        join private.notification_preferences as n on n.user_id = p.user_id
        join pg_catalog.pg_timezone_names as z on z.name = n.time_zone
        where p.user_id = account_id
          and p.age_18_declared
          and pg_catalog.btrim(p.terms_version) <> ''
          and pg_catalog.btrim(p.privacy_version) <> ''
          and p.moderation_state = 'active'
    );
$$;

revoke all on all functions in schema private from public, anon, authenticated;

create function public.accept_declarations(age_18 boolean, terms_version text, privacy_version text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    caller uuid := private.require_caller();
    invalid_fields text[] := '{}'::text[];
begin
    if age_18 is distinct from true then
        perform private.raise_error('declaration_required');
    end if;
    if terms_version is null or pg_catalog.btrim(terms_version) = '' or pg_catalog.char_length(terms_version) > 32 then
        invalid_fields := pg_catalog.array_append(invalid_fields, 'terms_version');
    end if;
    if privacy_version is null or pg_catalog.btrim(privacy_version) = '' or pg_catalog.char_length(privacy_version) > 32 then
        invalid_fields := pg_catalog.array_append(invalid_fields, 'privacy_version');
    end if;
    if pg_catalog.cardinality(invalid_fields) > 0 then
        perform private.raise_error('invalid_input', invalid_fields);
    end if;

    insert into private.profiles as p (user_id, age_18_declared, terms_version, privacy_version)
    values (caller, true, accept_declarations.terms_version, accept_declarations.privacy_version)
    on conflict (user_id) do update set
        age_18_declared = true,
        terms_version = excluded.terms_version,
        privacy_version = excluded.privacy_version;

    insert into private.matching_preferences (user_id) values (caller)
    on conflict (user_id) do nothing;

    insert into private.field_visibility (owner_id, field, level)
    values (caller, 'display_name', 'everyone_eligible'),
           (caller, 'introduction', 'everyone_eligible'),
           (caller, 'interests', 'everyone_eligible'),
           (caller, 'purposes', 'everyone_eligible'),
           (caller, 'contact_detail', 'private')
    on conflict (owner_id, field) do nothing;
end;
$$;

create function public.register_time_zone(time_zone text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    caller uuid := private.require_caller();
begin
    perform 1 from private.profiles as p where p.user_id = caller for update;
    if not found then
        perform private.raise_error('declaration_required');
    end if;
    if time_zone is null or not exists (
        select 1 from pg_catalog.pg_timezone_names as z where z.name = register_time_zone.time_zone
    ) then
        perform private.raise_error('invalid_input', array['time_zone']);
    end if;

    insert into private.notification_preferences as n (user_id, time_zone)
    values (caller, register_time_zone.time_zone)
    on conflict (user_id) do update set time_zone = excluded.time_zone;
end;
$$;

create function public.get_own_profile()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    caller uuid := private.require_caller();
    result jsonb;
begin
    select pg_catalog.jsonb_build_object(
        'display_name', coalesce(p.display_name, ''),
        'introduction', coalesce(p.introduction, ''),
        'contact_detail', coalesce(p.contact_detail, ''),
        'interests', coalesce((
            select pg_catalog.jsonb_agg(i.interest_id order by i.interest_id)
            from private.user_interests as i where i.user_id = p.user_id
        ), '[]'::jsonb),
        'purposes', coalesce((
            select pg_catalog.jsonb_agg(u.purpose order by u.purpose)
            from private.user_purposes as u where u.user_id = p.user_id
        ), '[]'::jsonb),
        'minimum_shared_interests', coalesce(m.minimum_shared_interests, 1),
        'field_visibility', coalesce((
            select pg_catalog.jsonb_object_agg(v.field, v.level)
            from private.field_visibility as v where v.owner_id = p.user_id
        ), '{"display_name":"everyone_eligible","introduction":"everyone_eligible","interests":"everyone_eligible","purposes":"everyone_eligible","contact_detail":"private"}'::jsonb),
        'discovery_on', coalesce(p.discovery_on, false),
        'link_count', (select pg_catalog.count(*) from private.external_links as l where l.owner_id = p.user_id),
        'prerequisites', pg_catalog.jsonb_build_object(
            'display_name', coalesce(pg_catalog.btrim(p.display_name) <> '', false),
            'introduction', coalesce(pg_catalog.btrim(p.introduction) <> '', false),
            'interest', exists (select 1 from private.user_interests as i where i.user_id = p.user_id),
            'link', exists (select 1 from private.external_links as l where l.owner_id = p.user_id)
        ),
        'declarations_recorded', coalesce(p.age_18_declared and pg_catalog.btrim(p.terms_version) <> '' and pg_catalog.btrim(p.privacy_version) <> '', false),
        'time_zone', n.time_zone,
        'moderation_state', p.moderation_state
    ) into result
    from (select caller as user_id) as a
    left join private.profiles as p on p.user_id = a.user_id
    left join private.matching_preferences as m on m.user_id = p.user_id
    left join private.notification_preferences as n on n.user_id = p.user_id;

    return result;
end;
$$;

create function public.update_own_profile(display_name text, introduction text, contact_detail text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    caller uuid := private.require_caller();
    discovering boolean;
    new_name text := pg_catalog.btrim(coalesce(display_name, ''));
    new_introduction text := pg_catalog.btrim(coalesce(introduction, ''));
    new_contact text := pg_catalog.btrim(coalesce(contact_detail, ''));
    invalid_fields text[] := '{}'::text[];
    missing_fields text[] := '{}'::text[];
begin
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
end;
$$;

create function public.set_own_interests(interest_ids text[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    caller uuid := private.require_caller();
    discovering boolean;
begin
    select p.discovery_on into discovering from private.profiles as p where p.user_id = caller for update;
    if not found then
        perform private.raise_error('declaration_required');
    end if;
    if interest_ids is null or coalesce(pg_catalog.array_ndims(interest_ids), 1) <> 1
        or pg_catalog.cardinality(interest_ids) > 10
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
end;
$$;

create function public.set_own_purposes(purposes text[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    caller uuid := private.require_caller();
begin
    perform 1 from private.profiles as p where p.user_id = caller for update;
    if not found then
        perform private.raise_error('declaration_required');
    end if;
    if purposes is null or coalesce(pg_catalog.array_ndims(purposes), 1) <> 1 or exists (
        select 1 from pg_catalog.unnest(purposes) as selected(purpose)
        where selected.purpose is null or selected.purpose not in ('discovery', 'collaboration')
    ) then
        perform private.raise_error('invalid_input', array['purposes']);
    end if;

    delete from private.user_purposes as u where u.user_id = caller;
    insert into private.user_purposes (user_id, purpose)
    select distinct caller, selected.purpose from pg_catalog.unnest(purposes) as selected(purpose);
end;
$$;

create function public.set_minimum_shared_interests(value integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    caller uuid := private.require_caller();
begin
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
end;
$$;

create function public.set_field_visibility(field text, level text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    caller uuid := private.require_caller();
    invalid_fields text[] := '{}'::text[];
begin
    perform 1 from private.profiles as p where p.user_id = caller for update;
    if not found then
        perform private.raise_error('declaration_required');
    end if;
    if field is null or field not in ('display_name', 'introduction', 'interests', 'purposes', 'contact_detail') then
        invalid_fields := pg_catalog.array_append(invalid_fields, 'field');
    end if;
    if level is null or level not in ('everyone_eligible', 'compatible_only', 'private') then
        invalid_fields := pg_catalog.array_append(invalid_fields, 'level');
    end if;
    if pg_catalog.cardinality(invalid_fields) > 0 then
        perform private.raise_error('invalid_input', invalid_fields);
    end if;

    insert into private.field_visibility as v (owner_id, field, level)
    values (caller, set_field_visibility.field, set_field_visibility.level)
    on conflict on constraint field_visibility_pkey do update set level = excluded.level;
end;
$$;

create function public.set_discovery(enabled boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    caller uuid := private.require_caller();
    profile private.profiles%rowtype;
    missing_fields text[] := '{}'::text[];
begin
    if enabled is null then
        perform private.raise_error('invalid_input', array['enabled']);
    end if;
    select p.* into profile from private.profiles as p where p.user_id = caller for update;
    if not enabled then
        update private.profiles as p set discovery_on = false where p.user_id = caller;
        return;
    end if;

    if not private.account_is_ready(caller) then
        if profile.age_18_declared is distinct from true then
            missing_fields := pg_catalog.array_append(missing_fields, 'age_18');
        end if;
        if coalesce(pg_catalog.btrim(profile.terms_version), '') = '' then
            missing_fields := pg_catalog.array_append(missing_fields, 'terms_version');
        end if;
        if coalesce(pg_catalog.btrim(profile.privacy_version), '') = '' then
            missing_fields := pg_catalog.array_append(missing_fields, 'privacy_version');
        end if;
        if not exists (
            select 1 from private.notification_preferences as n
            join pg_catalog.pg_timezone_names as z on z.name = n.time_zone
            where n.user_id = caller
        ) then
            missing_fields := pg_catalog.array_append(missing_fields, 'time_zone');
        end if;
        if profile.moderation_state is distinct from 'active' then
            missing_fields := pg_catalog.array_append(missing_fields, 'moderation_state');
        end if;
    end if;
    if coalesce(pg_catalog.btrim(profile.display_name), '') = '' then
        missing_fields := pg_catalog.array_append(missing_fields, 'display_name');
    end if;
    if coalesce(pg_catalog.btrim(profile.introduction), '') = '' then
        missing_fields := pg_catalog.array_append(missing_fields, 'introduction');
    end if;
    if not exists (select 1 from private.user_interests as i where i.user_id = caller) then
        missing_fields := pg_catalog.array_append(missing_fields, 'interest');
    end if;
    if not exists (select 1 from private.external_links as l where l.owner_id = caller) then
        missing_fields := pg_catalog.array_append(missing_fields, 'link');
    end if;
    if pg_catalog.cardinality(missing_fields) > 0 then
        perform private.raise_error('prerequisite_missing', missing_fields);
    end if;

    update private.profiles as p set discovery_on = true where p.user_id = caller;
end;
$$;

create function public.list_interests()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform private.require_caller();
    return (
        select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'interest_id', i.interest_id, 'label_ja', i.label_ja,
            'label_en', i.label_en, 'display_order', i.display_order
        ) order by i.display_order, i.interest_id), '[]'::jsonb)
        from private.interests as i
    );
end;
$$;

revoke all on function public.accept_declarations(boolean, text, text) from public, anon;
revoke all on function public.register_time_zone(text) from public, anon;
revoke all on function public.get_own_profile() from public, anon;
revoke all on function public.update_own_profile(text, text, text) from public, anon;
revoke all on function public.set_own_interests(text[]) from public, anon;
revoke all on function public.set_own_purposes(text[]) from public, anon;
revoke all on function public.set_minimum_shared_interests(integer) from public, anon;
revoke all on function public.set_field_visibility(text, text) from public, anon;
revoke all on function public.set_discovery(boolean) from public, anon;
revoke all on function public.list_interests() from public, anon;

grant execute on function public.accept_declarations(boolean, text, text) to authenticated;
grant execute on function public.register_time_zone(text) to authenticated;
grant execute on function public.get_own_profile() to authenticated;
grant execute on function public.update_own_profile(text, text, text) to authenticated;
grant execute on function public.set_own_interests(text[]) to authenticated;
grant execute on function public.set_own_purposes(text[]) to authenticated;
grant execute on function public.set_minimum_shared_interests(integer) to authenticated;
grant execute on function public.set_field_visibility(text, text) to authenticated;
grant execute on function public.set_discovery(boolean) to authenticated;
grant execute on function public.list_interests() to authenticated;
