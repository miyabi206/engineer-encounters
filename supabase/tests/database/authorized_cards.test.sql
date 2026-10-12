begin;

create extension if not exists pgtap with schema extensions;

create schema authorized_cards_test;
grant usage on schema authorized_cards_test to anon, authenticated, service_role;

create function authorized_cards_test.id(n integer)
returns uuid language sql immutable set search_path = '' as $$
    select ('dddddddd-0000-0000-0000-' || pg_catalog.lpad(n::text, 12, '0'))::uuid;
$$;

insert into auth.users (id)
select authorized_cards_test.id(n) from pg_catalog.generate_series(1, 3) as n;
insert into private.interests (interest_id, label_ja, label_en)
values ('card-test-a', 'a', 'a'), ('card-test-m', 'm', 'm'), ('card-test-z', 'z', 'z');
insert into private.profiles (user_id, age_18_declared, terms_version, privacy_version)
select authorized_cards_test.id(n), true, 'draft', 'draft' from pg_catalog.generate_series(1, 3) as n;
insert into private.notification_preferences (user_id, time_zone)
values (authorized_cards_test.id(1), 'UTC'), (authorized_cards_test.id(2), 'Asia/Tokyo'),
    (authorized_cards_test.id(3), 'UTC');
insert into private.matching_preferences (user_id)
select authorized_cards_test.id(n) from pg_catalog.generate_series(1, 3) as n;
insert into private.field_visibility (owner_id, field, level)
select authorized_cards_test.id(n), f, 'everyone_eligible'
from pg_catalog.generate_series(1, 2) as n
cross join pg_catalog.unnest(array['display_name', 'introduction', 'interests', 'purposes', 'contact_detail']) as f;

-- The expected wire objects come from known fixture values, never from a card
-- or a query of the owner's rows. Insertion order differs from display order.
create function authorized_cards_test.expected_link(owner_number integer, link_number integer)
returns jsonb language sql immutable set search_path = '' as $$
    select pg_catalog.jsonb_build_object(
        'link_id', authorized_cards_test.id(200 + 10 * (owner_number - 1) + link_number),
        'source', 'other', 'url', 'https://example.invalid/' || owner_number || '/' || link_number,
        'title', 'Link ' || link_number, 'description', 'Description ' || link_number,
        'main_language', case when link_number = 4 then null else 'en' end,
        'tags', array['tag-b', 'tag-a'], 'opening_text', 'Opening ' || link_number,
        'verification_state', 'unverified'
    );
$$;

insert into private.external_links (link_id, owner_id, source, source_item_id, url, title,
    description, main_language, tags, opening_text, verification_state, visibility, display_order)
select authorized_cards_test.id(200 + 10 * (o - 1) + l), authorized_cards_test.id(o),
    'other', 'must-not-leak', 'https://example.invalid/' || o || '/' || l,
    'Link ' || l, 'Description ' || l, case when l = 4 then null else 'en' end,
    array['tag-b', 'tag-a'], 'Opening ' || l, 'unverified', 'everyone_eligible',
    case when l in (2, 3) then 10 when l = 1 then 20 else 30 end
from pg_catalog.generate_series(1, 2) as o cross join pg_catalog.generate_series(1, 4) as l;

create function authorized_cards_test.expected_links(owner_number integer)
returns jsonb language sql immutable set search_path = '' as $$
    select pg_catalog.jsonb_build_array(
        authorized_cards_test.expected_link(owner_number, 2),
        authorized_cards_test.expected_link(owner_number, 3),
        authorized_cards_test.expected_link(owner_number, 1),
        authorized_cards_test.expected_link(owner_number, 4)
    );
$$;

create function authorized_cards_test.expected_fields(owner_number integer,
    purpose_names text[] default array['collaboration', 'discovery'])
returns jsonb language sql immutable set search_path = '' as $$
    select pg_catalog.jsonb_build_object(
        'display_name', 'Owner' || owner_number, 'introduction', 'Intro' || owner_number,
        'contact_detail', 'Contact' || owner_number,
        'interests', case when owner_number = 1 then array['card-test-a', 'card-test-z']
            else array['card-test-a', 'card-test-m', 'card-test-z'] end,
        'purposes', purpose_names
    );
$$;

create function authorized_cards_test.base_card(viewer_number integer)
returns jsonb language sql stable set search_path = '' as $$
    select pg_catalog.jsonb_build_object('encounter_id', authorized_cards_test.id(100),
        'kind', 'ambient', 'day', (pg_catalog.now() at time zone 'UTC')::date
            - case when viewer_number = 1 then 0 else 1 end);
$$;

create function authorized_cards_test.reset_pair()
returns void language plpgsql set search_path = '' as $$
begin
    update private.profiles as p set discovery_on = true, moderation_state = 'active',
        display_name = 'Owner' || n, introduction = 'Intro' || n, contact_detail = 'Contact' || n
    from pg_catalog.generate_series(1, 2) as n where p.user_id = authorized_cards_test.id(n);
    update private.notification_preferences set time_zone = case when user_id = authorized_cards_test.id(1)
        then 'UTC' else 'Asia/Tokyo' end
    where user_id in (authorized_cards_test.id(1), authorized_cards_test.id(2));
    update private.matching_preferences set minimum_shared_interests = 2
    where user_id in (authorized_cards_test.id(1), authorized_cards_test.id(2));
    delete from private.blocks where blocker_id in (authorized_cards_test.id(1), authorized_cards_test.id(2));
    delete from private.user_interests where user_id in (authorized_cards_test.id(1), authorized_cards_test.id(2));
    insert into private.user_interests (user_id, interest_id) values
        (authorized_cards_test.id(1), 'card-test-z'), (authorized_cards_test.id(1), 'card-test-a'),
        (authorized_cards_test.id(2), 'card-test-z'), (authorized_cards_test.id(2), 'card-test-m'),
        (authorized_cards_test.id(2), 'card-test-a');
    delete from private.user_purposes where user_id in (authorized_cards_test.id(1), authorized_cards_test.id(2));
    insert into private.user_purposes (user_id, purpose)
    select authorized_cards_test.id(n), p from pg_catalog.generate_series(1, 2) as n
    cross join pg_catalog.unnest(array['discovery', 'collaboration']) as p;
    update private.field_visibility set level = 'everyone_eligible'
    where owner_id in (authorized_cards_test.id(1), authorized_cards_test.id(2));
    update private.external_links as links set source = 'other', source_item_id = 'must-not-leak',
        url = 'https://example.invalid/' || o || '/' || l,
        title = 'Link ' || l, description = 'Description ' || l,
        main_language = case when l = 4 then null else 'en' end,
        tags = array['tag-b', 'tag-a'], opening_text = 'Opening ' || l,
        verification_state = 'unverified', visibility = 'everyone_eligible',
        display_order = case when l in (2, 3) then 10 when l = 1 then 20 else 30 end
    from pg_catalog.generate_series(1, 2) as o cross join pg_catalog.generate_series(1, 4) as l
    where links.link_id = authorized_cards_test.id(200 + 10 * (o - 1) + l);
    delete from private.encounters where encounter_id = authorized_cards_test.id(100);
    insert into private.encounters (encounter_id, user_a, user_b, kind, day_a, day_b)
    values (authorized_cards_test.id(100), authorized_cards_test.id(1), authorized_cards_test.id(2),
        'ambient', (pg_catalog.now() at time zone 'UTC')::date, (pg_catalog.now() at time zone 'UTC')::date - 1);
    insert into private.encounter_views (encounter_id, viewer_id, revealed, reveal_report_day)
    select authorized_cards_test.id(100), authorized_cards_test.id(n), true,
        (pg_catalog.now() at time zone 'UTC')::date + 100
    from pg_catalog.generate_series(1, 2) as n;
end;
$$;
revoke all on function authorized_cards_test.reset_pair() from public, anon, authenticated, service_role;

-- Impersonation is security invoker and always restores the table-owner role,
-- including for expected errors. No assumption about require_caller's locks.
create function authorized_cards_test.as_caller(v_viewer uuid, v_encounter uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare
    v_card jsonb;
begin
    begin
        set local role authenticated;
        perform pg_catalog.set_config('request.jwt.claim.sub', '', true);
        perform pg_catalog.set_config('request.jwt.claims',
            pg_catalog.jsonb_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
        v_card := public.get_encounter_card(v_encounter);
    exception when others then
        reset role;
        raise;
    end;
    reset role;
    return v_card;
end;
$$;

create function authorized_cards_test.expect_error(v_statement text, v_code text, v_description text)
returns text language plpgsql set search_path = pg_catalog, extensions as $$
declare
    v_actual_state text;
    v_actual_message text;
    v_actual_detail text;
begin
    begin
        execute v_statement;
    exception when others then
        get stacked diagnostics v_actual_state = returned_sqlstate,
            v_actual_message = message_text, v_actual_detail = pg_exception_detail;
        return extensions.is(pg_catalog.jsonb_build_array(v_actual_state, v_actual_message, coalesce(v_actual_detail, '')),
            pg_catalog.jsonb_build_array('P0001'::text, v_code, ''::text), v_description);
    end;
    return extensions.fail(v_description || ': expected exception');
end;
$$;

create function authorized_cards_test.refused(viewer_number integer, description text, encounter_number integer default 100)
returns text language sql set search_path = pg_catalog, extensions as $$
    select authorized_cards_test.expect_error(pg_catalog.format(
        'select authorized_cards_test.as_caller(%L::uuid, %L::uuid)',
        authorized_cards_test.id(viewer_number), authorized_cards_test.id(encounter_number)), 'not_found', description);
$$;

-- All 256 assignments of C,Dv,Do,Bv,Bo,P,Tv,To, read in both directions.
-- The helper's confirmed-encounter precondition is tested only when C = 1;
-- cards enforce C = 0 themselves. Threshold pass uses equality (2), fail uses 3.
create function authorized_cards_test.truth_table()
returns setof text language plpgsql set search_path = pg_catalog, extensions as $$
declare
    v_flags integer;
    v_viewer_number integer;
    v_owner_number integer;
    v_confirmed boolean;
    v_pair_eligible boolean;
    v_pair_compatible boolean;
    v_visibility text;
    v_expected jsonb;
    v_label text;
begin
    for v_flags in 0..255 loop
        perform authorized_cards_test.reset_pair();
        v_confirmed := (v_flags & 128) <> 0;
        update private.profiles set discovery_on = (v_flags & 64) <> 0 where user_id = authorized_cards_test.id(1);
        update private.profiles set discovery_on = (v_flags & 32) <> 0 where user_id = authorized_cards_test.id(2);
        if (v_flags & 16) <> 0 then
            insert into private.blocks values (authorized_cards_test.id(1), authorized_cards_test.id(2));
        end if;
        if (v_flags & 8) <> 0 then
            insert into private.blocks values (authorized_cards_test.id(2), authorized_cards_test.id(1));
        end if;
        delete from private.user_purposes where user_id in (authorized_cards_test.id(1), authorized_cards_test.id(2));
        insert into private.user_purposes values (authorized_cards_test.id(1), 'discovery'),
            (authorized_cards_test.id(2), case when (v_flags & 4) <> 0 then 'discovery' else 'collaboration' end);
        update private.matching_preferences set minimum_shared_interests = case when (v_flags & 2) <> 0 then 2 else 3 end
        where user_id = authorized_cards_test.id(1);
        update private.matching_preferences set minimum_shared_interests = case when (v_flags & 1) <> 0 then 2 else 3 end
        where user_id = authorized_cards_test.id(2);
        if not v_confirmed then
            delete from private.encounters where encounter_id = authorized_cards_test.id(100);
        end if;
        v_pair_eligible := (v_flags & 64) <> 0 and (v_flags & 32) <> 0 and (v_flags & 24) = 0;
        v_pair_compatible := v_pair_eligible and (v_flags & 7) = 7;
        for v_viewer_number in 1..2 loop
            v_owner_number := 3 - v_viewer_number;
            v_label := 'truth assignment ' || v_flags || ', viewer ' || v_viewer_number;
            if v_confirmed then
                return next extensions.is((select pg_catalog.jsonb_build_array(a.eligible, a.compatible, a.shared_interest_count)
                    from private.encounter_authorization(authorized_cards_test.id(v_viewer_number),
                        authorized_cards_test.id(v_owner_number)) as a),
                    pg_catalog.jsonb_build_array(v_pair_eligible, v_pair_compatible, 2), v_label || ': helper');
            end if;
            foreach v_visibility in array array['everyone_eligible', 'compatible_only', 'private'] loop
                update private.field_visibility set level = v_visibility
                where owner_id = authorized_cards_test.id(v_owner_number);
                update private.external_links set visibility = v_visibility
                where owner_id = authorized_cards_test.id(v_owner_number);
                if not v_confirmed or not v_pair_eligible then
                    return next authorized_cards_test.refused(v_viewer_number, v_label || ', ' || v_visibility || ': refused');
                else
                    v_expected := authorized_cards_test.base_card(v_viewer_number);
                    if v_visibility = 'everyone_eligible' or (v_visibility = 'compatible_only' and v_pair_compatible) then
                        v_expected := v_expected || authorized_cards_test.expected_fields(v_owner_number,
                            array[case when v_owner_number = 1 or (v_flags & 4) <> 0 then 'discovery' else 'collaboration' end])
                            || pg_catalog.jsonb_build_object('links', authorized_cards_test.expected_links(v_owner_number));
                    else
                        v_expected := v_expected || '{"shell":true}'::jsonb;
                    end if;
                    return next extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(v_viewer_number),
                        authorized_cards_test.id(100)), v_expected, v_label || ', ' || v_visibility || ': exact card');
                end if;
            end loop;
        end loop;
    end loop;
end;
$$;
revoke all on function authorized_cards_test.truth_table() from public, anon, authenticated, service_role;

-- Isolate each field and a single link: no permission for one item can authorize
-- a sibling item. Exercise each level with compatible and incompatible pairs.
create function authorized_cards_test.item_levels()
returns setof text language plpgsql set search_path = pg_catalog, extensions as $$
declare
    v_viewer_number integer;
    v_owner_number integer;
    v_matching boolean;
    v_field_name text;
    v_visibility text;
    v_expected jsonb;
    v_label text;
begin
    perform authorized_cards_test.reset_pair();
    update private.external_links set visibility = 'private'
    where owner_id in (authorized_cards_test.id(1), authorized_cards_test.id(2));
    for v_viewer_number in 1..2 loop
        v_owner_number := 3 - v_viewer_number;
        foreach v_matching in array array[true, false] loop
            update private.matching_preferences set minimum_shared_interests = case when v_matching then 2 else 3 end
            where user_id = authorized_cards_test.id(1);
            foreach v_field_name in array array['display_name', 'introduction', 'interests', 'purposes', 'contact_detail', 'links'] loop
                foreach v_visibility in array array['everyone_eligible', 'compatible_only', 'private'] loop
                    update private.field_visibility set level = 'private'
                    where owner_id = authorized_cards_test.id(v_owner_number);
                    update private.external_links set visibility = 'private'
                    where owner_id = authorized_cards_test.id(v_owner_number);
                    if v_field_name = 'links' then
                        update private.external_links set visibility = v_visibility
                        where link_id = authorized_cards_test.id(200 + 10 * (v_owner_number - 1) + 2);
                    else
                        update private.field_visibility set level = v_visibility
                        where owner_id = authorized_cards_test.id(v_owner_number) and field = v_field_name;
                    end if;
                    v_expected := authorized_cards_test.base_card(v_viewer_number);
                    if v_visibility = 'everyone_eligible' or (v_visibility = 'compatible_only' and v_matching) then
                        v_expected := v_expected || case when v_field_name = 'links' then pg_catalog.jsonb_build_object('links',
                            pg_catalog.jsonb_build_array(authorized_cards_test.expected_link(v_owner_number, 2)))
                            else pg_catalog.jsonb_build_object(v_field_name,
                                authorized_cards_test.expected_fields(v_owner_number)->v_field_name) end;
                    else
                        v_expected := v_expected || '{"shell":true}'::jsonb;
                    end if;
                    v_label := 'viewer ' || v_viewer_number || ', compatible ' || v_matching || ', ' || v_field_name || ', ' || v_visibility;
                    return next extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(v_viewer_number),
                        authorized_cards_test.id(100)), v_expected, v_label || ': exact independent keys and values');
                end loop;
            end loop;
        end loop;
    end loop;
end;
$$;
revoke all on function authorized_cards_test.item_levels() from public, anon, authenticated, service_role;

-- Catalog/privileges: 18; actual role checks: 14; exhaustive truth table: 1792;
-- individual levels: 72; wire values: 9; mixed levels: 4; current settings: 19;
-- helper edge cases: 6; additional read gates: 31.
select extensions.plan(1965);

select extensions.ok(p.prosecdef, 'card is security definer')
from pg_catalog.pg_proc as p where p.oid = 'public.get_encounter_card(uuid)'::regprocedure;
select extensions.ok('search_path=""' = any(p.proconfig), 'card has an empty search path')
from pg_catalog.pg_proc as p where p.oid = 'public.get_encounter_card(uuid)'::regprocedure;
select extensions.ok(not pg_catalog.has_function_privilege(r.name, 'private.get_encounter_card(uuid)', 'execute'),
    r.name || ' cannot bypass the named card RPC wrapper')
from (values ('anon'), ('authenticated'), ('service_role')) as r(name);
select extensions.is(p.proargnames, array['encounter_id'], 'card exposes only encounter_id')
from pg_catalog.pg_proc as p where p.oid = 'public.get_encounter_card(uuid)'::regprocedure;
select extensions.is(pg_catalog.format_type(p.prorettype, null), 'jsonb', 'card returns jsonb')
from pg_catalog.pg_proc as p where p.oid = 'public.get_encounter_card(uuid)'::regprocedure;
select extensions.is(pg_catalog.has_function_privilege(r.name, 'public.get_encounter_card(uuid)', 'execute'),
    r.name = 'authenticated', r.name || ' has the correct card privilege')
from (values ('anon'), ('authenticated'), ('service_role')) as r(name);
select extensions.ok(not exists (
    select 1 from pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) as a
    where a.grantee = 0 and a.privilege_type = 'EXECUTE'
), 'card has no public execute grant')
from pg_catalog.pg_proc as p where p.oid = 'public.get_encounter_card(uuid)'::regprocedure;
select extensions.is(p.provolatile::text, 's', 'authorization helper reads one statement snapshot')
from pg_catalog.pg_proc as p where p.oid = 'private.encounter_authorization(uuid,uuid)'::regprocedure;
select extensions.ok('search_path=""' = any(p.proconfig), 'authorization helper has an empty search path')
from pg_catalog.pg_proc as p where p.oid = 'private.encounter_authorization(uuid,uuid)'::regprocedure;
select extensions.ok(not pg_catalog.has_function_privilege(r.name, 'private.encounter_authorization(uuid,uuid)', 'execute'),
    r.name || ' cannot execute the private helper')
from (values ('anon'), ('authenticated'), ('service_role')) as r(name);
select extensions.ok(not exists (
    select 1 from pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) as a
    where a.grantee = 0 and a.privilege_type = 'EXECUTE'
), 'authorization helper has no public execute grant')
from pg_catalog.pg_proc as p where p.oid = 'private.encounter_authorization(uuid,uuid)'::regprocedure;
select extensions.is((select pg_catalog.jsonb_build_array(a.eligible, a.compatible, a.shared_interest_count)
    from private.encounter_authorization(authorized_cards_test.id(900), authorized_cards_test.id(901)) as a),
    '[false,false,0]'::jsonb, 'missing profiles yield one fail-closed helper row');

set local "request.jwt.claim.sub" = '';
set local "request.jwt.claims" = '{}';
set local role anon;
select extensions.throws_ok('select public.get_encounter_card(null)', '42501',
    'permission denied for function get_encounter_card', 'anon cannot invoke the card');
select extensions.throws_ok('select * from private.' || t.name, '42501', 'permission denied for schema private',
    'anon cannot read ' || t.name)
from (values ('encounters'), ('encounter_views'), ('profiles'), ('external_links')) as t(name);
select extensions.throws_ok('select * from private.encounter_authorization(null, null)', '42501',
    'permission denied for schema private', 'anon cannot invoke the helper');
reset role;
set local role service_role;
select extensions.throws_ok('select public.get_encounter_card(null)', '42501',
    'permission denied for function get_encounter_card', 'service_role cannot invoke the card');
reset role;
set local role authenticated;
select authorized_cards_test.expect_error('select public.get_encounter_card(null)', 'not_authenticated', 'missing caller is rejected');
select extensions.throws_ok('select * from private.' || t.name, '42501', 'permission denied for schema private',
    'authenticated cannot read ' || t.name)
from (values ('encounters'), ('encounter_views'), ('profiles'), ('external_links')) as t(name);
select extensions.throws_ok('select * from private.encounter_authorization(null, null)', '42501',
    'permission denied for schema private', 'authenticated cannot invoke the helper');
set local "request.jwt.claims" = '{"sub":"dddddddd-0000-0000-0000-000000000999","role":"authenticated"}';
select authorized_cards_test.expect_error('select public.get_encounter_card(null)', 'not_authenticated', 'deleted or nonexistent caller is rejected');
reset role;

select * from authorized_cards_test.truth_table();
select * from authorized_cards_test.item_levels();

-- Wire values: 9 assertions, including sorting, empty authorized values, shell
-- omission on populated cards, omitted links, and the exact nine link keys.
select authorized_cards_test.reset_pair();
select extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(n), authorized_cards_test.id(100)),
    authorized_cards_test.base_card(n) || authorized_cards_test.expected_fields(3 - n)
        || pg_catalog.jsonb_build_object('links', authorized_cards_test.expected_links(3 - n)),
    'viewer ' || n || ': caller date, sorted interests/purposes/links and no shell')
from pg_catalog.generate_series(1, 2) as n;
select extensions.ok((select pg_catalog.bool_and(
    (select pg_catalog.array_agg(k order by k) from pg_catalog.jsonb_object_keys(l) as k)
        = array['description', 'link_id', 'main_language', 'opening_text', 'source', 'tags', 'title', 'url', 'verification_state']
) from pg_catalog.jsonb_array_elements(authorized_cards_test.as_caller(
    authorized_cards_test.id(n), authorized_cards_test.id(100))->'links') as l),
    'viewer ' || n || ': every link has exactly the authorized keys')
from pg_catalog.generate_series(1, 2) as n;
update private.field_visibility set level = 'private'
where owner_id in (authorized_cards_test.id(1), authorized_cards_test.id(2));
update private.external_links set visibility = 'private'
where owner_id in (authorized_cards_test.id(1), authorized_cards_test.id(2));
select extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(n), authorized_cards_test.id(100)),
    authorized_cards_test.base_card(n) || '{"shell":true}'::jsonb,
    'viewer ' || n || ': all-private shell has no unauthorized keys or links')
from pg_catalog.generate_series(1, 2) as n;
update private.field_visibility set level = 'everyone_eligible' where owner_id = authorized_cards_test.id(2);
update private.profiles set display_name = '', introduction = '', contact_detail = '' where user_id = authorized_cards_test.id(2);
delete from private.user_interests where user_id = authorized_cards_test.id(2);
delete from private.user_purposes where user_id = authorized_cards_test.id(2);
select extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(1), authorized_cards_test.id(100)),
    authorized_cards_test.base_card(1) || '{"display_name":"","introduction":"","contact_detail":"","interests":[],"purposes":[]}'::jsonb,
    'authorized empty strings and arrays stay present, with no shell or unauthorized links');
select extensions.is((select pg_catalog.jsonb_build_array(a.eligible, a.compatible, a.shared_interest_count)
    from private.encounter_authorization(authorized_cards_test.id(1), authorized_cards_test.id(2)) as a),
    '[true,false,0]'::jsonb, 'no shared interests or purposes keeps eligibility but removes compatibility');
update private.field_visibility set level = 'private' where owner_id = authorized_cards_test.id(2);
update private.external_links set visibility = 'everyone_eligible', title = '', description = '',
    opening_text = '', tags = '{}'::text[] where link_id = authorized_cards_test.id(214);
select extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(1), authorized_cards_test.id(100)),
    authorized_cards_test.base_card(1) || pg_catalog.jsonb_build_object('links', pg_catalog.jsonb_build_array(
        authorized_cards_test.expected_link(2, 4) || '{"title":"","description":"","opening_text":"","tags":[]}'::jsonb)),
    'authorized link keeps empty values and null language, and prevents a shell');

-- Mixed levels: 4 assertions. The array omits private links while keeping the
-- surviving links in display order; each profile field uses its own selector.
select authorized_cards_test.reset_pair();
update private.field_visibility set level = case field
    when 'display_name' then 'everyone_eligible' when 'introduction' then 'compatible_only'
    when 'purposes' then 'compatible_only' else 'private' end
where owner_id in (authorized_cards_test.id(1), authorized_cards_test.id(2));
update private.external_links set visibility = case
    when link_id in (authorized_cards_test.id(201), authorized_cards_test.id(211)) then 'everyone_eligible'
    when link_id in (authorized_cards_test.id(203), authorized_cards_test.id(213)) then 'private'
    else 'compatible_only' end
where owner_id in (authorized_cards_test.id(1), authorized_cards_test.id(2));
select extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(n), authorized_cards_test.id(100)),
    authorized_cards_test.base_card(n) || pg_catalog.jsonb_build_object('display_name', 'Owner' || (3 - n),
        'introduction', 'Intro' || (3 - n), 'purposes', array['collaboration', 'discovery'],
        'links', pg_catalog.jsonb_build_array(authorized_cards_test.expected_link(3 - n, 2),
            authorized_cards_test.expected_link(3 - n, 1), authorized_cards_test.expected_link(3 - n, 4))),
    'viewer ' || n || ': mixed compatible card excludes private siblings')
from pg_catalog.generate_series(1, 2) as n;
update private.matching_preferences set minimum_shared_interests = 3 where user_id = authorized_cards_test.id(1);
select extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(n), authorized_cards_test.id(100)),
    authorized_cards_test.base_card(n) || pg_catalog.jsonb_build_object('display_name', 'Owner' || (3 - n),
        'links', pg_catalog.jsonb_build_array(authorized_cards_test.expected_link(3 - n, 1))),
    'viewer ' || n || ': incompatible mixed card retains only everyone-eligible items')
from pg_catalog.generate_series(1, 2) as n;

-- Current settings: 19 assertions against the same old, favorited encounter.
-- Nothing recreates the encounter or stores a profile/permission snapshot.
select authorized_cards_test.reset_pair();
update private.encounters set day_a = (pg_catalog.now() at time zone 'UTC')::date - 40
where encounter_id = authorized_cards_test.id(100);
update private.encounter_views set favorite = true
where encounter_id = authorized_cards_test.id(100) and viewer_id = authorized_cards_test.id(1);
update private.field_visibility set level = 'compatible_only' where owner_id = authorized_cards_test.id(2);
update private.external_links set visibility = 'compatible_only' where owner_id = authorized_cards_test.id(2);
select extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(1), authorized_cards_test.id(100)),
    authorized_cards_test.base_card(1) || pg_catalog.jsonb_build_object('day', (pg_catalog.now() at time zone 'UTC')::date - 40)
        || authorized_cards_test.expected_fields(2) || pg_catalog.jsonb_build_object('links', authorized_cards_test.expected_links(2)),
    'old favorite initially reads the current compatible card');
update private.profiles set display_name = 'Changed' where user_id = authorized_cards_test.id(2);
select extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(1), authorized_cards_test.id(100))->>'display_name',
    'Changed', 'profile edit applies to an existing favorite');
update private.field_visibility set level = 'private'
where owner_id = authorized_cards_test.id(2) and field = 'introduction';
select extensions.ok(not (authorized_cards_test.as_caller(authorized_cards_test.id(1), authorized_cards_test.id(100)) ? 'introduction'),
    'visibility edit removes the key instead of returning null');
update private.external_links set visibility = 'private' where link_id = authorized_cards_test.id(212);
select extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(1), authorized_cards_test.id(100))->'links',
    pg_catalog.jsonb_build_array(authorized_cards_test.expected_link(2, 3),
        authorized_cards_test.expected_link(2, 1), authorized_cards_test.expected_link(2, 4)),
    'link visibility edit filters the existing favorite immediately');
update private.external_links set title = 'Changed link' where link_id = authorized_cards_test.id(211);
select extensions.is((select l->>'title' from pg_catalog.jsonb_array_elements(
    authorized_cards_test.as_caller(authorized_cards_test.id(1), authorized_cards_test.id(100))->'links') as l
    where l->>'link_id' = authorized_cards_test.id(211)::text), 'Changed link', 'link edits use current metadata');
update private.matching_preferences set minimum_shared_interests = 3 where user_id = authorized_cards_test.id(2);
select extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(1), authorized_cards_test.id(100))->'shell',
    'true'::jsonb, 'owner threshold change hides all compatible-only items');
select extensions.is((select pg_catalog.jsonb_build_array(a.eligible, a.compatible, a.shared_interest_count)
    from private.encounter_authorization(authorized_cards_test.id(1), authorized_cards_test.id(2)) as a),
    '[true,false,2]'::jsonb, 'shared count remains accurate when a threshold fails');
update private.matching_preferences set minimum_shared_interests = 2 where user_id = authorized_cards_test.id(2);
update private.matching_preferences set minimum_shared_interests = 3 where user_id = authorized_cards_test.id(1);
select extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(1), authorized_cards_test.id(100))->'shell',
    'true'::jsonb, 'viewer threshold change also hides compatible-only items');
update private.matching_preferences set minimum_shared_interests = 2 where user_id = authorized_cards_test.id(1);
delete from private.user_purposes where user_id = authorized_cards_test.id(2);
select extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(1), authorized_cards_test.id(100))->'shell',
    'true'::jsonb, 'empty current purposes remove compatibility');
insert into private.user_purposes values (authorized_cards_test.id(2), 'discovery');
select extensions.ok(authorized_cards_test.as_caller(authorized_cards_test.id(1), authorized_cards_test.id(100)) ? 'display_name',
    'restoring purpose overlap restores authorized fields');
delete from private.user_interests where user_id = authorized_cards_test.id(2) and interest_id = 'card-test-a';
select extensions.is((select pg_catalog.jsonb_build_array(a.eligible, a.compatible, a.shared_interest_count)
    from private.encounter_authorization(authorized_cards_test.id(1), authorized_cards_test.id(2)) as a),
    '[true,false,1]'::jsonb, 'interest removal recomputes the intersection');
select extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(1), authorized_cards_test.id(100))->'shell',
    'true'::jsonb, 'interest removal applies to the existing card');
insert into private.user_interests values (authorized_cards_test.id(2), 'card-test-a'), (authorized_cards_test.id(1), 'card-test-m');
select extensions.is((select pg_catalog.jsonb_build_array(a.eligible, a.compatible, a.shared_interest_count)
    from private.encounter_authorization(authorized_cards_test.id(1), authorized_cards_test.id(2)) as a),
    '[true,true,3]'::jsonb, 'interest additions recompute count and compatibility');
select extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(1), authorized_cards_test.id(100))->'interests',
    '["card-test-a","card-test-m","card-test-z"]'::jsonb, 'restored field has the current sorted interests');
update private.profiles set discovery_on = false where user_id = authorized_cards_test.id(1);
select authorized_cards_test.refused(1, 'viewer discovery off refuses an existing favorite');
update private.profiles set discovery_on = true where user_id = authorized_cards_test.id(1);
update private.profiles set discovery_on = false where user_id = authorized_cards_test.id(2);
select authorized_cards_test.refused(1, 'owner discovery off refuses an existing favorite');
update private.profiles set discovery_on = true where user_id = authorized_cards_test.id(2);
insert into private.blocks values (authorized_cards_test.id(1), authorized_cards_test.id(2));
select authorized_cards_test.refused(1, 'viewer block refuses an existing favorite');
delete from private.blocks where blocker_id = authorized_cards_test.id(1);
insert into private.blocks values (authorized_cards_test.id(2), authorized_cards_test.id(1));
select authorized_cards_test.refused(1, 'owner block refuses an existing favorite');
delete from private.blocks where blocker_id = authorized_cards_test.id(2);
select extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(1), authorized_cards_test.id(100))->>'display_name',
    'Changed', 'restoring eligibility restores the current card within favorite retention');

-- Helper edge cases: 6 assertions. Missing selectors never authorize a field;
-- missing matching preferences use the contract's initial threshold of one.
select authorized_cards_test.reset_pair();
select extensions.is((select pg_catalog.jsonb_build_array(a.eligible, a.compatible, a.shared_interest_count)
    from private.encounter_authorization(authorized_cards_test.id(1), authorized_cards_test.id(1)) as a),
    '[false,false,2]'::jsonb, 'self-pairs are ineligible');
select extensions.is((select pg_catalog.jsonb_build_array(a.eligible, a.compatible, a.shared_interest_count)
    from private.encounter_authorization(null, authorized_cards_test.id(2)) as a),
    '[false,false,0]'::jsonb, 'null viewer returns false facts and a zero intersection');
delete from private.matching_preferences where user_id = authorized_cards_test.id(2);
update private.matching_preferences set minimum_shared_interests = 1 where user_id = authorized_cards_test.id(1);
delete from private.user_interests where user_id = authorized_cards_test.id(2) and interest_id = 'card-test-a';
select extensions.is((select pg_catalog.jsonb_build_array(a.eligible, a.compatible, a.shared_interest_count)
    from private.encounter_authorization(authorized_cards_test.id(n), authorized_cards_test.id(3 - n)) as a),
    '[true,true,1]'::jsonb, 'viewer ' || n || ': absent preferences use initial threshold one')
from pg_catalog.generate_series(1, 2) as n;
insert into private.matching_preferences (user_id) values (authorized_cards_test.id(2));
select authorized_cards_test.reset_pair();
delete from private.field_visibility where owner_id = authorized_cards_test.id(2) and field = 'contact_detail';
select extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(1), authorized_cards_test.id(100)),
    authorized_cards_test.base_card(1) || (authorized_cards_test.expected_fields(2) - 'contact_detail')
        || pg_catalog.jsonb_build_object('links', authorized_cards_test.expected_links(2)),
    'a missing selector omits only that field');
delete from private.field_visibility where owner_id = authorized_cards_test.id(2);
update private.external_links set visibility = 'private' where owner_id = authorized_cards_test.id(2);
select extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(1), authorized_cards_test.id(100)),
    authorized_cards_test.base_card(1) || '{"shell":true}'::jsonb, 'missing selectors authorize nothing');
insert into private.field_visibility (owner_id, field, level)
select authorized_cards_test.id(2), f, 'everyone_eligible'
from pg_catalog.unnest(array['display_name', 'introduction', 'interests', 'purposes', 'contact_detail']) as f;

-- Additional read gates: 31 assertions. All refusal tests check the same state,
-- message and empty detail, including a nonparticipant with a forged view row.
select authorized_cards_test.reset_pair();
select authorized_cards_test.refused(1, 'unknown encounter returns only not_found', 999);
select authorized_cards_test.expect_error(pg_catalog.format('select authorized_cards_test.as_caller(%L::uuid, null)',
    authorized_cards_test.id(1)), 'not_found', 'null encounter returns only not_found');
select authorized_cards_test.refused(3, 'nonparticipant returns only not_found');
insert into private.encounter_views (encounter_id, viewer_id, revealed, reveal_report_day, favorite)
values (authorized_cards_test.id(100), authorized_cards_test.id(3), true, (pg_catalog.now() at time zone 'UTC')::date, true);
select authorized_cards_test.refused(3, 'a forged revealed favorite view cannot make a nonparticipant eligible');
update private.encounter_views set revealed = false
where encounter_id = authorized_cards_test.id(100) and viewer_id = authorized_cards_test.id(1);
select authorized_cards_test.refused(1, 'unrevealed ambient view returns only not_found');
update private.encounter_views set favorite = true
where encounter_id = authorized_cards_test.id(100) and viewer_id = authorized_cards_test.id(1);
select authorized_cards_test.refused(1, 'favorite cannot bypass the reveal gate');
select extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(2), authorized_cards_test.id(100))->>'day',
    ((pg_catalog.now() at time zone 'UTC')::date - 1)::text, 'the other revealed view remains readable');
delete from private.encounter_views where encounter_id = authorized_cards_test.id(100) and viewer_id = authorized_cards_test.id(1);
select authorized_cards_test.refused(1, 'missing participant view returns only not_found');

-- Six moderation reads: active succeeds, hidden and suspended refuse, in both
-- directions, even while favorite. Moderation is separate from compatibility.
create function authorized_cards_test.moderation_states()
returns setof text language plpgsql set search_path = pg_catalog, extensions as $$
declare
    v_viewer_number integer;
    v_state text;
begin
    for v_viewer_number in 1..2 loop
        foreach v_state in array array['active', 'hidden', 'suspended'] loop
            perform authorized_cards_test.reset_pair();
            update private.encounter_views set favorite = true where encounter_id = authorized_cards_test.id(100);
            update private.profiles set moderation_state = v_state where user_id = authorized_cards_test.id(3 - v_viewer_number);
            if v_state = 'active' then
                return next extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(v_viewer_number),
                    authorized_cards_test.id(100))->>'display_name', 'Owner' || (3 - v_viewer_number),
                    'viewer ' || v_viewer_number || ': active owner is readable');
            else
                return next authorized_cards_test.refused(v_viewer_number,
                    'viewer ' || v_viewer_number || ': ' || v_state || ' owner returns only not_found');
            end if;
        end loop;
    end loop;
end;
$$;
revoke all on function authorized_cards_test.moderation_states() from public, anon, authenticated, service_role;
select * from authorized_cards_test.moderation_states();
select authorized_cards_test.reset_pair();
update private.profiles set moderation_state = 'hidden' where user_id = authorized_cards_test.id(1);
select extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(1), authorized_cards_test.id(100))->>'display_name',
    'Owner2', 'the moderation gate applies to the other account, not the viewer');
update private.profiles set moderation_state = 'suspended' where user_id = authorized_cards_test.id(1);
select extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(1), authorized_cards_test.id(100))->>'display_name',
    'Owner2', 'viewer suspension does not change the defined owner moderation gate');

select authorized_cards_test.reset_pair();
update private.encounters set day_a = (pg_catalog.now() at time zone 'UTC')::date - 29,
    day_b = (pg_catalog.now() at time zone 'Asia/Tokyo')::date - 31 where encounter_id = authorized_cards_test.id(100);
select extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(1), authorized_cards_test.id(100))->>'day',
    ((pg_catalog.now() at time zone 'UTC')::date - 29)::text, 'day 29 is within retention');
update private.encounters set day_a = (pg_catalog.now() at time zone 'UTC')::date - 30 where encounter_id = authorized_cards_test.id(100);
select authorized_cards_test.refused(1, 'retention expires at the start of local day 30');
update private.encounters set day_a = (pg_catalog.now() at time zone 'UTC')::date - 400 where encounter_id = authorized_cards_test.id(100);
update private.encounter_views set favorite = true
where encounter_id = authorized_cards_test.id(100) and viewer_id = authorized_cards_test.id(1);
select extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(1), authorized_cards_test.id(100))->>'day',
    ((pg_catalog.now() at time zone 'UTC')::date - 400)::text, 'favorite has unlimited retention');
select authorized_cards_test.refused(2, 'one viewer favorite does not extend the other viewer retention');
update private.encounter_views set favorite = viewer_id = authorized_cards_test.id(2)
where encounter_id = authorized_cards_test.id(100);
select authorized_cards_test.refused(1, 'removing favorite immediately restores expiry');
select extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(2), authorized_cards_test.id(100))->>'day',
    ((pg_catalog.now() at time zone 'Asia/Tokyo')::date - 31)::text, 'the second viewer uses its own date and favorite');

-- These registered zones differ by 26 hours. The same local midnight is always
-- past in UTC+14 and future in UTC-12, whatever time the tester runs this file.
select authorized_cards_test.reset_pair();
update private.encounters set day_a = (pg_catalog.now() at time zone 'Etc/GMT-14')::date - 30
where encounter_id = authorized_cards_test.id(100);
update private.notification_preferences set time_zone = 'Etc/GMT-14' where user_id = authorized_cards_test.id(1);
select authorized_cards_test.refused(1, 'retention uses midnight in the registered UTC+14 zone');
update private.notification_preferences set time_zone = 'Etc/GMT+12' where user_id = authorized_cards_test.id(1);
select extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(1), authorized_cards_test.id(100))->>'day',
    ((pg_catalog.now() at time zone 'Etc/GMT-14')::date - 30)::text,
    'changing the current registered zone changes retention of the existing encounter');
set local time zone 'Pacific/Honolulu';
select extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(1), authorized_cards_test.id(100))->>'day',
    ((pg_catalog.now() at time zone 'Etc/GMT-14')::date - 30)::text, 'session time zone does not affect retention or the stored day');
set local time zone 'UTC';
delete from private.notification_preferences where user_id = authorized_cards_test.id(1);
select authorized_cards_test.refused(1, 'missing registered zone fails closed');
insert into private.notification_preferences (user_id, time_zone) values (authorized_cards_test.id(1), 'not-a-zone');
select authorized_cards_test.refused(1, 'invalid registered zone fails closed without revealing an internal error');
update private.encounter_views set favorite = true
where encounter_id = authorized_cards_test.id(100) and viewer_id = authorized_cards_test.id(1);
select extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(1), authorized_cards_test.id(100))->>'display_name',
    'Owner2', 'favorite bypasses retention without needing a zone calculation');
delete from private.notification_preferences where user_id = authorized_cards_test.id(1);
select extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(1), authorized_cards_test.id(100))->>'display_name',
    'Owner2', 'favorite also bypasses retention when registration is missing');
insert into private.notification_preferences (user_id, time_zone) values (authorized_cards_test.id(1), 'UTC');
select authorized_cards_test.reset_pair();
update private.encounters set kind = 'session' where encounter_id = authorized_cards_test.id(100);
select extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(1), authorized_cards_test.id(100))->>'kind',
    'session', 'revealed session returns the stored kind');
update private.encounters set kind = 'qr' where encounter_id = authorized_cards_test.id(100);
select extensions.is(authorized_cards_test.as_caller(authorized_cards_test.id(2), authorized_cards_test.id(100))->>'kind',
    'qr', 'revealed qr returns the stored kind');

select * from extensions.finish();

rollback;
