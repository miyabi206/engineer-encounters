-- Service RPCs require explicit grants. PostgreSQL's global PUBLIC function
-- default cannot be removed by a schema-local REVOKE, so remove it globally
-- for the migration owner as well as removing schema-local Data API defaults.
create schema service;
revoke all on schema service from public, anon, authenticated, service_role;
grant usage on schema service to service_role;
alter default privileges revoke execute on functions from public, anon, authenticated, service_role;
alter default privileges in schema public, private, service
    revoke all on functions from public, anon, authenticated, service_role;
alter default privileges in schema public, private, service
    revoke all on tables from public, anon, authenticated, service_role;
alter default privileges in schema public, private, service
    revoke all on sequences from public, anon, authenticated, service_role;

create function private.github_decimal_id(value text)
returns boolean language sql immutable set search_path = '' as $$
    select coalesce(value ~ '^[1-9][0-9]{0,18}$' and
        (pg_catalog.char_length(value) < 19 or value collate pg_catalog."C" <= '9223372036854775807' collate pg_catalog."C"), false);
$$;

create function private.link_text_array_valid(values_array text[], item_limit integer, text_limit integer, nonempty boolean)
returns boolean language sql immutable set search_path = '' as $$
    select values_array is not null
        and (pg_catalog.cardinality(values_array) = 0 or pg_catalog.array_ndims(values_array) = 1)
        and pg_catalog.cardinality(values_array) <= item_limit
        and not exists (select 1 from pg_catalog.unnest(values_array) as v(value)
            where v.value is null or pg_catalog.char_length(private.trim_input(v.value)) > text_limit
                or (nonempty and private.trim_input(v.value) = ''));
$$;

create function private.normalized_link_tags(input_tags text[])
returns text[] language sql immutable set search_path = '' as $$
    select coalesce(pg_catalog.array_agg(t.value order by t.first_position), '{}'::text[])
    from (select private.trim_input(v.value) as value, pg_catalog.min(v.position) as first_position
        from pg_catalog.unnest(input_tags) with ordinality as v(value, position)
        group by private.trim_input(v.value)) as t;
$$;

create function private.github_repository_url(value text)
returns boolean language sql immutable set search_path = '' as $$
    select coalesce(pg_catalog.char_length(value) <= 2048
        and value ~ '^https://github[.]com/[A-Za-z0-9-]{1,39}/[A-Za-z0-9._-]{1,100}$'
        and pg_catalog.split_part(value, '/', 5) not in ('.', '..'), false);
$$;

create table private.linked_identities (
    user_id uuid not null references auth.users (id) on delete cascade,
    provider text not null check (provider = 'github'),
    provider_user_id text not null check (private.github_decimal_id(provider_user_id)),
    handle text not null check (handle ~ '^[A-Za-z0-9-]{1,39}$'),
    verified_addresses text[] not null default '{}'::text[]
        check (private.link_text_array_valid(verified_addresses, 32, 2048, false)),
    primary key (user_id, provider),
    unique (provider, provider_user_id)
);
alter table private.linked_identities enable row level security;
revoke all on table private.linked_identities from public, anon, authenticated, service_role;

create unique index external_links_owner_source_item_idx
    on private.external_links (owner_id, source, source_item_id) where source_item_id is not null;
alter table private.external_links
    add constraint external_links_metadata_bounds check (
        pg_catalog.char_length(private.trim_input(title)) <= 100
        and pg_catalog.char_length(private.trim_input(description)) <= 200
        and (main_language is null or pg_catalog.char_length(private.trim_input(main_language)) <= 30)
        and private.link_text_array_valid(tags, 10, 30, true)
        and pg_catalog.char_length(private.trim_input(opening_text)) <= 200),
    add constraint external_links_url_bound check (pg_catalog.char_length(url) <= 2048),
    add constraint external_links_display_order_nonnegative check (display_order >= 0),
    add constraint external_links_github_source check (source <> 'github' or (
        source_item_id is not null and private.github_decimal_id(source_item_id)
        and private.github_repository_url(url) and private.trim_input(title) <> ''
        and verification_state = 'verified'));

-- All account mutations take this lock before looking at live Auth or locking
-- the profile. The profile lock also serializes with Unit 3 set_discovery.
create function private.lock_link_account(account_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
    perform pg_catalog.pg_advisory_xact_lock(31001, pg_catalog.hashtext(account_id::text));
    if not exists (select 1 from auth.users as u where u.id = account_id) then
        perform private.raise_error('not_authenticated');
    end if;
    perform 1 from private.profiles as p where p.user_id = account_id for update;
end;
$$;

create function private.link_write_race(account_id uuid)
returns void language plpgsql set search_path = '' as $$
begin
    if not exists (select 1 from auth.users as u where u.id = account_id) then
        perform private.raise_error('not_authenticated');
    end if;
    perform private.raise_error('not_found');
end;
$$;

-- Callers already hold the account and profile locks. Unit 4 extends this
-- shared discovery-off operation to cancel outstanding QR codes as well.
create function private.turn_discovery_off(account_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare server_time timestamptz := pg_catalog.clock_timestamp();
begin
    update private.profiles as p set discovery_on = false where p.user_id = account_id;
    update private.sessions as s set stopped_at = server_time
    where s.user_id = account_id and s.stopped_at is null and s.expires_at > server_time;
end;
$$;

-- GitHub sign-in may create an Auth account, but must never bootstrap an app
-- profile. Renewing declarations on an existing linked account remains valid.
create or replace function private.accept_declarations(input_age_18 boolean, input_terms_version text, input_privacy_version text)
returns void language plpgsql security definer set search_path = '' as $$
declare
    caller uuid := private.require_caller();
    invalid_fields text[] := '{}'::text[];
begin
    perform private.lock_link_account(caller);
    if not exists (select 1 from private.profiles as p where p.user_id = caller)
        and exists (select 1 from auth.identities as i where i.user_id = caller and i.provider = 'github') then
        perform private.raise_error('account_not_ready');
    end if;
    if input_age_18 is distinct from true then
        perform private.raise_error('declaration_required');
    end if;
    if input_terms_version is null or private.trim_input(input_terms_version) = '' or pg_catalog.char_length(private.trim_input(input_terms_version)) > 32 then
        invalid_fields := pg_catalog.array_append(invalid_fields, 'terms_version');
    end if;
    if input_privacy_version is null or private.trim_input(input_privacy_version) = '' or pg_catalog.char_length(private.trim_input(input_privacy_version)) > 32 then
        invalid_fields := pg_catalog.array_append(invalid_fields, 'privacy_version');
    end if;
    if pg_catalog.cardinality(invalid_fields) > 0 then
        perform private.raise_error('invalid_input', invalid_fields);
    end if;
    insert into private.profiles as p (user_id, age_18_declared, terms_version, privacy_version)
    values (caller, true, private.trim_input(input_terms_version), private.trim_input(input_privacy_version))
    on conflict (user_id) do update set age_18_declared = true,
        terms_version = excluded.terms_version, privacy_version = excluded.privacy_version;
    insert into private.matching_preferences (user_id) values (caller)
    on conflict (user_id) do nothing;
    insert into private.field_visibility (owner_id, field, level)
    values (caller, 'display_name', 'everyone_eligible'), (caller, 'introduction', 'everyone_eligible'),
        (caller, 'interests', 'everyone_eligible'), (caller, 'purposes', 'everyone_eligible'),
        (caller, 'contact_detail', 'private')
    on conflict (owner_id, field) do nothing;
exception when foreign_key_violation then
    perform private.link_write_race(caller);
end;
$$;

create function private.own_link_json(link private.external_links)
returns jsonb language sql stable set search_path = '' as $$
    select pg_catalog.jsonb_build_object(
        'link_id', (link).link_id, 'source', (link).source, 'source_item_id', (link).source_item_id,
        'url', (link).url, 'title', (link).title, 'description', (link).description,
        'main_language', (link).main_language, 'tags', (link).tags, 'opening_text', (link).opening_text,
        'visibility', (link).visibility, 'verification_state', (link).verification_state,
        'display_order', (link).display_order);
$$;

create function private.own_links_json(account_id uuid)
returns jsonb language sql stable set search_path = '' as $$
    select coalesce(pg_catalog.jsonb_agg(private.own_link_json(l) order by l.display_order, l.link_id), '[]'::jsonb)
    from (select e.* from private.external_links as e where e.owner_id = account_id
        order by e.display_order, e.link_id limit 10) as l;
$$;

create function private.github_identity_json(account_id uuid)
returns jsonb language sql stable set search_path = '' as $$
    select coalesce((select pg_catalog.jsonb_build_object(
        'connected', true, 'provider_user_id', i.provider_id, 'handle', c.handle,
        'verified_addresses', coalesce(c.verified_addresses, '{}'::text[]),
        'repository_links', (select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'link_id', l.link_id, 'source_item_id', l.source_item_id, 'url', l.url)
            order by l.display_order, l.link_id), '[]'::jsonb)
            from (select e.* from private.external_links as e
                where e.owner_id = account_id and e.source = 'github'
                order by e.display_order, e.link_id limit 10) as l))
        from auth.identities as i left join private.linked_identities as c
            on c.user_id = i.user_id and c.provider = 'github' and c.provider_user_id = i.provider_id
        where i.user_id = account_id and i.provider = 'github'
        order by (c.user_id is not null) desc, i.created_at, i.id limit 1),
        pg_catalog.jsonb_build_object('connected', false, 'provider_user_id', null, 'handle', null,
            'verified_addresses', '[]'::jsonb, 'repository_links', '[]'::jsonb));
$$;

create function private.list_own_links()
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
    return private.own_links_json(private.require_caller());
end;
$$;

-- Returns only failing metadata names, already in their signature order.
create function private.link_metadata_errors(input_title text, input_description text, input_main_language text,
    input_tags text[], input_opening_text text, input_visibility text)
returns text[] language plpgsql immutable set search_path = '' as $$
declare
    fields text[] := '{}'::text[];
begin
    if input_title is null or private.trim_input(input_title) = ''
        or pg_catalog.char_length(private.trim_input(input_title)) > 100 then
        fields := pg_catalog.array_append(fields, 'title');
    end if;
    if input_description is null or pg_catalog.char_length(private.trim_input(input_description)) > 200 then
        fields := pg_catalog.array_append(fields, 'description');
    end if;
    if input_main_language is not null and pg_catalog.char_length(private.trim_input(input_main_language)) > 30 then
        fields := pg_catalog.array_append(fields, 'main_language');
    end if;
    if not private.link_text_array_valid(input_tags, 10, 30, true) then
        fields := pg_catalog.array_append(fields, 'tags');
    end if;
    if input_opening_text is null or pg_catalog.char_length(private.trim_input(input_opening_text)) > 200 then
        fields := pg_catalog.array_append(fields, 'opening_text');
    end if;
    if input_visibility is null or input_visibility not in ('everyone_eligible', 'compatible_only', 'private') then
        fields := pg_catalog.array_append(fields, 'visibility');
    end if;
    return fields;
end;
$$;

create function private.update_own_link(input_link_id uuid, input_title text, input_description text,
    input_main_language text, input_tags text[], input_opening_text text, input_visibility text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    caller uuid := private.require_caller();
    fields text[] := '{}'::text[];
    saved private.external_links%rowtype;
begin
    if input_link_id is null then fields := array['link_id']; end if;
    fields := fields || private.link_metadata_errors(input_title, input_description, input_main_language,
        input_tags, input_opening_text, input_visibility);
    if pg_catalog.cardinality(fields) > 0 then perform private.raise_error('invalid_input', fields); end if;
    perform private.lock_link_account(caller);
    update private.external_links as l set title = private.trim_input(input_title),
        description = private.trim_input(input_description),
        main_language = nullif(private.trim_input(input_main_language), ''),
        tags = private.normalized_link_tags(input_tags), opening_text = private.trim_input(input_opening_text),
        visibility = input_visibility
    where l.link_id = input_link_id and l.owner_id = caller returning l.* into saved;
    if not found then perform private.raise_error('not_found'); end if;
    return private.own_link_json(saved);
exception when foreign_key_violation then
    perform private.link_write_race(caller);
    return null;
end;
$$;

create function private.delete_own_link(input_link_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    caller uuid := private.require_caller();
begin
    if input_link_id is null then perform private.raise_error('invalid_input', array['link_id']); end if;
    perform private.lock_link_account(caller);
    if not exists (select 1 from private.external_links as l where l.link_id = input_link_id and l.owner_id = caller) then
        perform private.raise_error('not_found');
    end if;
    if exists (select 1 from private.profiles as p where p.user_id = caller and p.discovery_on)
        and (select pg_catalog.count(*) from private.external_links as l where l.owner_id = caller) = 1 then
        perform private.raise_error('prerequisite_missing', array['link']);
    end if;
    -- Unit 4 saved_links references this PK with ON DELETE CASCADE.
    delete from private.external_links as l where l.link_id = input_link_id and l.owner_id = caller;
    return pg_catalog.jsonb_build_object('deleted', true);
exception when foreign_key_violation then
    perform private.link_write_race(caller);
    return null;
end;
$$;

create function private.reorder_own_links(input_link_ids uuid[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    caller uuid := private.require_caller();
begin
    if input_link_ids is null or pg_catalog.cardinality(input_link_ids) > 10
        or (pg_catalog.cardinality(input_link_ids) > 0 and pg_catalog.array_ndims(input_link_ids) <> 1)
        or exists (select 1 from pg_catalog.unnest(input_link_ids) as i(id) where i.id is null)
        or (select pg_catalog.count(distinct i.id) from pg_catalog.unnest(input_link_ids) as i(id))
            <> pg_catalog.cardinality(input_link_ids) then
        perform private.raise_error('invalid_input', array['link_ids']);
    end if;
    perform private.lock_link_account(caller);
    if pg_catalog.cardinality(input_link_ids) <> (select pg_catalog.count(*) from private.external_links as l where l.owner_id = caller)
        or exists (select 1 from pg_catalog.unnest(input_link_ids) as i(id)
            where not exists (select 1 from private.external_links as l where l.owner_id = caller and l.link_id = i.id)) then
        perform private.raise_error('invalid_input', array['link_ids']);
    end if;
    update private.external_links as l set display_order = (i.position - 1)::integer
    from pg_catalog.unnest(input_link_ids) with ordinality as i(id, position)
    where l.link_id = i.id and l.owner_id = caller;
    return private.own_links_json(caller);
exception when foreign_key_violation then
    perform private.link_write_race(caller);
    return null;
end;
$$;

create function private.get_github_connection()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    identity_value jsonb := private.github_identity_json(private.require_caller());
begin
    -- The service identity remains live without a cache, so sync can reconnect.
    -- A public connection additionally needs a matching cache (handle NOT NULL).
    return pg_catalog.jsonb_build_object('connected', identity_value->>'handle' is not null,
        'handle', identity_value->'handle');
end;
$$;

create function private.disconnect_github()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    caller uuid := private.require_caller();
begin
    perform private.lock_link_account(caller);
    if exists (select 1 from private.profiles as p where p.user_id = caller and p.discovery_on)
        and not exists (select 1 from private.external_links as l where l.owner_id = caller and l.source <> 'github') then
        perform private.raise_error('prerequisite_missing', array['link']);
    end if;
    -- Delete repository cards/cache even if Auth was independently unlinked.
    delete from private.external_links as l where l.owner_id = caller and l.source = 'github';
    delete from private.linked_identities as i where i.user_id = caller and i.provider = 'github';
    -- The client unlinks the managed Auth identity through Auth after this RPC.
    return pg_catalog.jsonb_build_object('connected', false, 'handle', null);
exception when foreign_key_violation then
    perform private.link_write_race(caller);
    return null;
end;
$$;

create function private.get_github_identity(account_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
    if account_id is null then perform private.raise_error('invalid_input', array['account_id']); end if;
    if not exists (select 1 from auth.users as u where u.id = account_id) then
        perform private.raise_error('not_authenticated');
    end if;
    return private.github_identity_json(account_id);
end;
$$;

create function private.sync_github_identity(account_id uuid, provider_user_id text, handle text, verified_addresses text[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    fields text[] := '{}'::text[];
    live_provider_id text;
    new_handle text := private.trim_input(handle);
    cached_account_id uuid;
    current_cached_account_id uuid;
begin
    if account_id is null then fields := pg_catalog.array_append(fields, 'account_id'); end if;
    if not private.github_decimal_id(provider_user_id) then fields := pg_catalog.array_append(fields, 'provider_user_id'); end if;
    if handle is null or new_handle !~ '^[A-Za-z0-9-]{1,39}$' then fields := pg_catalog.array_append(fields, 'handle'); end if;
    if not private.link_text_array_valid(verified_addresses, 32, 2048, false) then
        fields := pg_catalog.array_append(fields, 'verified_addresses');
    end if;
    if pg_catalog.cardinality(fields) > 0 then perform private.raise_error('invalid_input', fields); end if;
    -- Discover a possible stale owner before taking any account/profile lock.
    select c.user_id into cached_account_id from private.linked_identities as c
    where c.provider = 'github' and c.provider_user_id = sync_github_identity.provider_user_id
        and c.user_id <> account_id;
    if cached_account_id is not null then
        perform pg_catalog.pg_advisory_xact_lock(31001, pg_catalog.hashtext(least(account_id, cached_account_id)::text));
        perform pg_catalog.pg_advisory_xact_lock(31001, pg_catalog.hashtext(greatest(account_id, cached_account_id)::text));
    else
        perform pg_catalog.pg_advisory_xact_lock(31001, pg_catalog.hashtext(account_id::text));
    end if;
    if not exists (select 1 from auth.users as u where u.id = account_id) then
        perform private.raise_error('not_authenticated');
    end if;
    -- A changed owner needs a fresh call, never an additional out-of-order lock.
    select c.user_id into current_cached_account_id from private.linked_identities as c
    where c.provider = 'github' and c.provider_user_id = sync_github_identity.provider_user_id
        and c.user_id <> account_id;
    if current_cached_account_id is not null and current_cached_account_id is distinct from cached_account_id then
        perform private.raise_error('not_found');
    end if;
    perform p.user_id from private.profiles as p where p.user_id in (account_id, cached_account_id)
        order by p.user_id for update;
    select i.provider_id into live_provider_id from auth.identities as i
        left join private.linked_identities as c on c.user_id = i.user_id and c.provider = 'github'
            and c.provider_user_id = i.provider_id
        where i.user_id = account_id and i.provider = 'github'
        order by (c.user_id is not null) desc, i.created_at, i.id limit 1 for share of i;
    if not found or live_provider_id is distinct from provider_user_id then perform private.raise_error('not_found'); end if;
    if current_cached_account_id is not null then
        perform 1 from auth.identities as i where i.user_id = current_cached_account_id
            and i.provider = 'github' and i.provider_id = sync_github_identity.provider_user_id for share;
        if found then perform private.raise_error('not_found'); end if;
        delete from private.external_links as l where l.owner_id = current_cached_account_id and l.source = 'github';
        delete from private.linked_identities as c where c.user_id = current_cached_account_id and c.provider = 'github';
        if exists (select 1 from private.profiles as p where p.user_id = current_cached_account_id and p.discovery_on)
            and not exists (select 1 from private.external_links as l where l.owner_id = current_cached_account_id) then
            perform private.turn_discovery_off(current_cached_account_id);
        end if;
    end if;
    insert into private.linked_identities as c (user_id, provider, provider_user_id, handle, verified_addresses)
    values (account_id, 'github', provider_user_id, new_handle, private.normalized_link_tags(verified_addresses))
    on conflict (user_id, provider) do update set provider_user_id = excluded.provider_user_id,
        handle = excluded.handle, verified_addresses = excluded.verified_addresses;
    return pg_catalog.jsonb_build_object('connected', true, 'handle', new_handle);
exception when unique_violation or foreign_key_violation then
    perform private.link_write_race(account_id);
    return null;
end;
$$;

create function private.save_github_link(account_id uuid, repository_id text, repository_owner_id text, url text,
    title text, description text, main_language text, tags text[], opening_text text, visibility text, replace_existing boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    fields text[] := '{}'::text[];
    live_provider_id text;
    saved private.external_links%rowtype;
    next_order integer;
begin
    if account_id is null then fields := pg_catalog.array_append(fields, 'account_id'); end if;
    if not private.github_decimal_id(repository_id) then fields := pg_catalog.array_append(fields, 'repository_id'); end if;
    if not private.github_decimal_id(repository_owner_id) then fields := pg_catalog.array_append(fields, 'repository_owner_id'); end if;
    if url is null or not private.github_repository_url(private.trim_input(url)) then fields := pg_catalog.array_append(fields, 'url'); end if;
    fields := fields || private.link_metadata_errors(title, description, main_language, tags, opening_text, visibility);
    if replace_existing is null then fields := pg_catalog.array_append(fields, 'replace_existing'); end if;
    if pg_catalog.cardinality(fields) > 0 then perform private.raise_error('invalid_input', fields); end if;
    perform private.lock_link_account(account_id);
    if not private.account_is_ready(account_id) then perform private.raise_error('account_not_ready'); end if;
    select i.provider_id into live_provider_id from auth.identities as i
        left join private.linked_identities as c on c.user_id = i.user_id and c.provider = 'github'
            and c.provider_user_id = i.provider_id
        where i.user_id = account_id and i.provider = 'github'
        order by (c.user_id is not null) desc, i.created_at, i.id limit 1 for share of i;
    if not found or live_provider_id is distinct from repository_owner_id then perform private.raise_error('not_found'); end if;
    select l.* into saved from private.external_links as l
        where l.owner_id = account_id and l.source = 'github' and l.source_item_id = repository_id for update;
    if found then
        if not replace_existing then perform private.raise_error('prerequisite_missing', array['refresh_confirmation']); end if;
        update private.external_links as l set url = private.trim_input(save_github_link.url),
            title = private.trim_input(save_github_link.title), description = private.trim_input(save_github_link.description),
            main_language = nullif(private.trim_input(save_github_link.main_language), ''),
            tags = private.normalized_link_tags(save_github_link.tags), opening_text = private.trim_input(save_github_link.opening_text),
            visibility = save_github_link.visibility
        where l.link_id = saved.link_id returning l.* into saved;
    else
        if (select pg_catalog.count(*) from private.external_links as l where l.owner_id = account_id) >= 10 then
            perform private.raise_error('rate_limited');
        end if;
        select coalesce(pg_catalog.max(l.display_order), -1) + 1 into next_order
            from private.external_links as l where l.owner_id = account_id;
        insert into private.external_links (owner_id, source, source_item_id, url, title, description,
            main_language, tags, opening_text, visibility, verification_state, display_order)
        values (account_id, 'github', repository_id, private.trim_input(url), private.trim_input(title),
            private.trim_input(description), nullif(private.trim_input(main_language), ''),
            private.normalized_link_tags(tags), private.trim_input(opening_text), visibility, 'verified', next_order)
        returning * into saved;
    end if;
    return private.own_link_json(saved);
exception when unique_violation or foreign_key_violation then
    perform private.link_write_race(account_id);
    return null;
end;
$$;

create function private.record_github_fetch(account_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
    if account_id is null then perform private.raise_error('invalid_input', array['account_id']); end if;
    perform private.lock_link_account(account_id);
    if private.record_account_event(account_id, 'github_fetch', 60, interval '3600 seconds') then
        perform private.raise_error('rate_limited');
    end if;
    return pg_catalog.jsonb_build_object('allowed', true);
exception when foreign_key_violation then
    perform private.link_write_race(account_id);
    return null;
end;
$$;

create function public.list_own_links()
returns jsonb language sql security definer set search_path = '' as $$
    select private.list_own_links();
$$;

create function public.update_own_link(link_id uuid, title text, description text, main_language text, tags text[], opening_text text, visibility text)
returns jsonb language sql security definer set search_path = '' as $$
    select private.update_own_link($1, $2, $3, $4, $5, $6, $7);
$$;

create function public.delete_own_link(link_id uuid)
returns jsonb language sql security definer set search_path = '' as $$
    select private.delete_own_link($1);
$$;

create function public.reorder_own_links(link_ids uuid[])
returns jsonb language sql security definer set search_path = '' as $$
    select private.reorder_own_links($1);
$$;

create function public.get_github_connection()
returns jsonb language sql security definer set search_path = '' as $$
    select private.get_github_connection();
$$;

create function public.disconnect_github()
returns jsonb language sql security definer set search_path = '' as $$
    select private.disconnect_github();
$$;

create function service.get_github_identity(account_id uuid)
returns jsonb language sql security definer set search_path = '' as $$
    select private.get_github_identity($1);
$$;

create function service.sync_github_identity(account_id uuid, provider_user_id text, handle text, verified_addresses text[])
returns jsonb language sql security definer set search_path = '' as $$
    select private.sync_github_identity($1, $2, $3, $4);
$$;

create function service.save_github_link(account_id uuid, repository_id text, repository_owner_id text, url text, title text, description text, main_language text, tags text[], opening_text text, visibility text, replace_existing boolean)
returns jsonb language sql security definer set search_path = '' as $$
    select private.save_github_link($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11);
$$;

create function service.record_github_fetch(account_id uuid)
returns jsonb language sql security definer set search_path = '' as $$
    select private.record_github_fetch($1);
$$;

revoke all on all functions in schema private from public, anon, authenticated, service_role;
revoke all on all functions in schema service from public, anon, authenticated, service_role;
revoke all on function public.accept_declarations(boolean, text, text) from public, anon, authenticated, service_role;
grant execute on function public.accept_declarations(boolean, text, text) to authenticated;
revoke all on function public.list_own_links() from public, anon, authenticated, service_role;
grant execute on function public.list_own_links() to authenticated;
revoke all on function public.update_own_link(uuid, text, text, text, text[], text, text) from public, anon, authenticated, service_role;
grant execute on function public.update_own_link(uuid, text, text, text, text[], text, text) to authenticated;
revoke all on function public.delete_own_link(uuid) from public, anon, authenticated, service_role;
grant execute on function public.delete_own_link(uuid) to authenticated;
revoke all on function public.reorder_own_links(uuid[]) from public, anon, authenticated, service_role;
grant execute on function public.reorder_own_links(uuid[]) to authenticated;
revoke all on function public.get_github_connection() from public, anon, authenticated, service_role;
grant execute on function public.get_github_connection() to authenticated;
revoke all on function public.disconnect_github() from public, anon, authenticated, service_role;
grant execute on function public.disconnect_github() to authenticated;
revoke all on function service.get_github_identity(uuid) from public, anon, authenticated, service_role;
grant execute on function service.get_github_identity(uuid) to service_role;
revoke all on function service.sync_github_identity(uuid, text, text, text[]) from public, anon, authenticated, service_role;
grant execute on function service.sync_github_identity(uuid, text, text, text[]) to service_role;
revoke all on function service.save_github_link(uuid, text, text, text, text, text, text, text[], text, text, boolean) from public, anon, authenticated, service_role;
grant execute on function service.save_github_link(uuid, text, text, text, text, text, text, text[], text, text, boolean) to service_role;
revoke all on function service.record_github_fetch(uuid) from public, anon, authenticated, service_role;
grant execute on function service.record_github_fetch(uuid) to service_role;
