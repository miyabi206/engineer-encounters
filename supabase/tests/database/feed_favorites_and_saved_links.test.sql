begin;
create extension if not exists pgtap with schema extensions;
create schema feed_test;
grant usage on schema feed_test to anon, authenticated, service_role;

create function feed_test.id(n integer)
returns uuid language sql immutable set search_path = '' as $$
    select ('eeeeeeee-0000-0000-0000-' || pg_catalog.lpad(n::text, 12, '0'))::uuid;
$$;
create function feed_test.day()
returns date language sql stable set search_path = '' as $$
    select (pg_catalog.now() at time zone 'UTC')::date;
$$;
create function feed_test.link_id(owner_number integer, link_number integer default 1)
returns uuid language sql immutable set search_path = '' as $$
    select feed_test.id(10000 + 10 * owner_number + link_number);
$$;

insert into auth.users (id) select feed_test.id(n) from pg_catalog.generate_series(1, 230) as n;
insert into private.interests (interest_id, label_ja, label_en)
values ('feed-a', 'a', 'a'), ('feed-m', 'm', 'm'), ('feed-z', 'z', 'z');
insert into private.profiles (user_id, age_18_declared, terms_version, privacy_version,
    discovery_on, display_name, introduction, contact_detail)
select feed_test.id(n), true, 'draft', 'draft', true, 'Owner' || n, 'Intro' || n, 'Contact' || n
from pg_catalog.generate_series(1, 230) as n;
insert into private.notification_preferences (user_id, time_zone)
select feed_test.id(n), 'UTC' from pg_catalog.generate_series(1, 230) as n;
insert into private.matching_preferences (user_id, minimum_shared_interests)
select feed_test.id(n), 2 from pg_catalog.generate_series(1, 230) as n;
insert into private.user_purposes (user_id, purpose)
select feed_test.id(n), 'discovery' from pg_catalog.generate_series(1, 230) as n;
insert into private.user_interests (user_id, interest_id)
select feed_test.id(n), i from pg_catalog.generate_series(1, 230) as n
cross join pg_catalog.unnest(array['feed-a', 'feed-z']) as i;
insert into private.user_interests values (feed_test.id(2), 'feed-m');
insert into private.field_visibility (owner_id, field, level)
select feed_test.id(n), f, 'everyone_eligible' from pg_catalog.generate_series(1, 230) as n
cross join pg_catalog.unnest(array['display_name', 'introduction', 'contact_detail', 'interests', 'purposes']) as f;
insert into private.external_links (link_id, owner_id, source, source_item_id, url, title,
    description, tags, opening_text, visibility, display_order)
select feed_test.link_id(n, l), feed_test.id(n), 'other', 'secret-' || l,
    'https://example.invalid/' || n || '/' || l, 'Link' || l, 'Description' || l,
    array['tag'], 'Opening' || l, case when l = 1 then 'everyone_eligible' else 'private' end, l
from pg_catalog.generate_series(1, 230) as n cross join pg_catalog.generate_series(1, 2) as l;

-- Expected objects use fixture constants, never a card or an owner-row query.
create function feed_test.expected_link(owner_number integer, link_number integer default 1)
returns jsonb language sql immutable set search_path = '' as $$
    select pg_catalog.jsonb_build_object('link_id', feed_test.link_id(owner_number, link_number),
        'source', 'other', 'url', 'https://example.invalid/' || owner_number || '/' || link_number,
        'title', 'Link' || link_number, 'description', 'Description' || link_number,
        'main_language', null, 'tags', array['tag'], 'opening_text', 'Opening' || link_number,
        'verification_state', 'unverified');
$$;
create function feed_test.expected_card(viewer_number integer, card_day date)
returns jsonb language sql immutable set search_path = '' as $$
    select pg_catalog.jsonb_build_object('encounter_id', feed_test.id(100), 'kind', 'session', 'day', card_day,
        'display_name', 'Owner' || (3 - viewer_number), 'introduction', 'Intro' || (3 - viewer_number),
        'contact_detail', 'Contact' || (3 - viewer_number),
        'interests', case when viewer_number = 1 then array['feed-a', 'feed-m', 'feed-z']
            else array['feed-a', 'feed-z'] end, 'purposes', array['discovery'],
        'links', pg_catalog.jsonb_build_array(feed_test.expected_link(3 - viewer_number)));
$$;

create function feed_test.as_caller(viewer uuid, operation text, encounter uuid default null,
    link uuid default null, favorite_value boolean default true)
returns jsonb language plpgsql set search_path = '' as $$
declare result jsonb;
begin
    begin
        set local role authenticated;
        perform pg_catalog.set_config('request.jwt.claim.sub', '', true);
        perform pg_catalog.set_config('request.jwt.claims',
            pg_catalog.jsonb_build_object('sub', viewer, 'role', 'authenticated')::text, true);
        case operation
            when 'card' then result := public.get_encounter_card(encounter);
            when 'feed' then result := public.get_encounter_feed();
            when 'favorites' then result := public.list_encounter_favorites();
            when 'saved' then result := public.list_saved_links();
            when 'favorite' then result := public.set_encounter_favorite(encounter, favorite_value);
            when 'save' then result := public.save_link(encounter, link);
            when 'unsave' then result := public.unsave_link(encounter, link);
        end case;
    exception when others then
        reset role;
        raise;
    end;
    reset role;
    return result;
end;
$$;
create function feed_test.expect_error(statement text, code text, detail text, description text)
returns text language plpgsql set search_path = pg_catalog, extensions as $$
declare actual_state text; actual_code text; actual_detail text;
begin
    begin
        execute statement;
    exception when others then
        get stacked diagnostics actual_state = returned_sqlstate, actual_code = message_text,
            actual_detail = pg_exception_detail;
        return extensions.is(pg_catalog.jsonb_build_array(actual_state, actual_code, coalesce(actual_detail, '')),
            pg_catalog.jsonb_build_array('P0001', code, detail), description);
    end;
    return extensions.fail(description || ': expected exception');
end;
$$;
create function feed_test.error_call(viewer_number integer, operation text, encounter uuid, link uuid,
    favorite_value boolean, code text, detail text, description text)
returns text language sql set search_path = pg_catalog, extensions as $$
    select feed_test.expect_error(pg_catalog.format(
        'select feed_test.as_caller(%L::uuid, %L, %L::uuid, %L::uuid, %L::boolean)',
        feed_test.id(viewer_number), operation, encounter, link, favorite_value), code, detail, description);
$$;

create function feed_test.reset_pair(viewer_number integer default 1, scenario text default 'visible')
returns void language plpgsql set search_path = '' as $$
declare viewer uuid := feed_test.id(viewer_number); owner uuid := feed_test.id(3 - viewer_number);
begin
    delete from private.encounters where encounter_id in (feed_test.id(100), feed_test.id(101));
    delete from private.blocks where blocker_id in (feed_test.id(1), feed_test.id(2), feed_test.id(3));
    update private.profiles set discovery_on = true, moderation_state = 'active'
    where user_id in (feed_test.id(1), feed_test.id(2), feed_test.id(3));
    insert into private.notification_preferences (user_id, time_zone)
    select feed_test.id(n), 'UTC' from pg_catalog.generate_series(1, 3) as n
    on conflict (user_id) do update set time_zone = excluded.time_zone;
    update private.field_visibility set level = 'everyone_eligible'
    where owner_id in (feed_test.id(1), feed_test.id(2));
    update private.external_links set visibility = case when link_id in (feed_test.link_id(1), feed_test.link_id(2))
        then 'everyone_eligible' else 'private' end
    where owner_id in (feed_test.id(1), feed_test.id(2));
    update private.matching_preferences set minimum_shared_interests = 2
    where user_id in (feed_test.id(1), feed_test.id(2));
    insert into private.encounters (encounter_id, user_a, user_b, kind, day_a, day_b)
    values (feed_test.id(100), feed_test.id(1), feed_test.id(2), 'session', feed_test.day(), feed_test.day());
    insert into private.encounter_views (encounter_id, viewer_id, revealed, reveal_report_day, favorite)
    select feed_test.id(100), feed_test.id(n), true, feed_test.day(), true from pg_catalog.generate_series(1, 2) as n;
    insert into private.saved_links (viewer_id, encounter_id, link_id)
    select feed_test.id(n), feed_test.id(100), feed_test.link_id(3 - n) from pg_catalog.generate_series(1, 2) as n;
    if scenario in ('expired', 'favorite_retained', 'saved_retained', 'both_retained', 'other_favorite', 'other_saved') then
        update private.encounters set day_a = feed_test.day() - 40, day_b = feed_test.day() - 40
        where encounter_id = feed_test.id(100);
    end if;
    if scenario in ('expired', 'saved_retained', 'other_favorite', 'other_saved', 'missing_zone', 'invalid_zone') then
        update private.encounter_views set favorite = false where viewer_id = viewer;
    end if;
    if scenario in ('expired', 'favorite_retained', 'other_favorite', 'other_saved', 'missing_zone', 'invalid_zone') then
        delete from private.saved_links where viewer_id = viewer;
    end if;
    case scenario
        when 'missing_view' then delete from private.encounter_views where viewer_id = viewer;
        when 'nonparticipant' then
            insert into private.encounter_views values (feed_test.id(100), feed_test.id(3), true, feed_test.day(), true);
            insert into private.saved_links values (feed_test.id(3), feed_test.id(100), feed_test.link_id(3 - viewer_number));
        when 'other_favorite' then delete from private.saved_links where encounter_id = feed_test.id(100);
        when 'other_saved' then update private.encounter_views set favorite = false where encounter_id = feed_test.id(100);
        when 'unrevealed' then update private.encounter_views set revealed = false where viewer_id = viewer;
        when 'viewer_off' then update private.profiles set discovery_on = false where user_id = viewer;
        when 'owner_off' then update private.profiles set discovery_on = false where user_id = owner;
        when 'viewer_block' then insert into private.blocks (blocker_id, blocked_id, placed_day) values (viewer, owner, (pg_catalog.now() at time zone 'UTC')::date);
        when 'owner_block' then insert into private.blocks (blocker_id, blocked_id, placed_day) values (owner, viewer, (pg_catalog.now() at time zone 'UTC')::date);
        when 'hidden_owner' then update private.profiles set moderation_state = 'hidden' where user_id = owner;
        when 'suspended_owner' then update private.profiles set moderation_state = 'suspended' where user_id = owner;
        when 'missing_zone' then delete from private.notification_preferences where user_id = viewer;
        when 'invalid_zone' then update private.notification_preferences set time_zone = 'invalid-zone' where user_id = viewer;
        else null;
    end case;
end;
$$;

-- 18 gate cases, both directions: gate + 8 independent public operations = 324.
-- Recreate the fixture for each write; no previous removal can mask a failure.
create function feed_test.gate_matrix()
returns setof text language plpgsql set search_path = pg_catalog, extensions as $$
declare
    v integer; actor integer; scenario text; operation text; label text;
    visible boolean; fav boolean; has_saved boolean; card_day date; card jsonb; expected jsonb;
    operations text[] := array['card','feed','favorites','saved','favorite_on','favorite_off','save','unsave'];
begin
    for v in 1..2 loop
        foreach scenario in array array['visible','missing_view','nonparticipant','unrevealed','expired',
            'favorite_retained','saved_retained','both_retained','other_favorite','other_saved',
            'viewer_off','owner_off','viewer_block','owner_block','hidden_owner','suspended_owner','missing_zone','invalid_zone'] loop
            actor := case when scenario = 'nonparticipant' then 3 else v end;
            visible := scenario in ('visible','favorite_retained','saved_retained','both_retained');
            fav := scenario <> 'saved_retained';
            has_saved := scenario <> 'favorite_retained';
            card_day := feed_test.day() - case when scenario = 'visible' then 0 else 40 end;
            card := feed_test.expected_card(v, card_day);
            label := 'viewer ' || v || ', ' || scenario;
            perform feed_test.reset_pair(v, scenario);
            return next extensions.is(private.visible_encounter_card(feed_test.id(actor), feed_test.id(100)),
                case when visible then card else null end, label || ': plain gate');
            foreach operation in array operations loop
                perform feed_test.reset_pair(v, scenario);
                if operation = 'feed' and scenario in ('viewer_off', 'missing_zone') then
                    return next feed_test.error_call(actor, operation, null, null, true,
                        case when scenario = 'missing_zone' then 'account_not_ready' else 'prerequisite_missing' end,
                        case when scenario = 'missing_zone' then '' else 'discovery' end, label || ': feed prerequisite');
                elsif not visible and operation not in ('feed','favorites','saved') then
                    return next feed_test.error_call(actor,
                        case when operation in ('favorite_on', 'favorite_off') then 'favorite' else operation end,
                        feed_test.id(100), feed_test.link_id(3 - v), operation <> 'favorite_off',
                        'not_found', '', label || ': ' || operation || ' gate refusal');
                else
                    expected := case operation
                        when 'card' then card || pg_catalog.jsonb_build_object('favorite', fav, 'saved_link_ids',
                            case when has_saved then pg_catalog.jsonb_build_array(feed_test.link_id(3 - v)) else '[]'::jsonb end)
                        when 'feed' then pg_catalog.jsonb_build_object('cards', case when visible then
                            pg_catalog.jsonb_build_array(card || pg_catalog.jsonb_build_object('favorite', fav,
                                'shared_interest_ids', array['feed-a','feed-z'])) else '[]'::jsonb end, 'truncated', false)
                        when 'favorites' then pg_catalog.jsonb_build_object('cards', case when visible and fav then
                            pg_catalog.jsonb_build_array(card || pg_catalog.jsonb_build_object('favorite', fav,
                                'shared_interest_ids', array['feed-a','feed-z'])) else '[]'::jsonb end, 'truncated', false)
                        when 'saved' then pg_catalog.jsonb_build_object('links', case when visible and has_saved then
                            pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('encounter_id', feed_test.id(100),
                                'day', card_day, 'kind', 'session', 'link', feed_test.expected_link(3 - v)))
                            else '[]'::jsonb end, 'truncated', false)
                        when 'favorite_on' then pg_catalog.jsonb_build_object('encounter_id', feed_test.id(100), 'favorite', true)
                        when 'favorite_off' then pg_catalog.jsonb_build_object('encounter_id', feed_test.id(100), 'favorite', false)
                        when 'save' then pg_catalog.jsonb_build_object('encounter_id', feed_test.id(100), 'link_id', feed_test.link_id(3 - v), 'saved', true)
                        when 'unsave' then pg_catalog.jsonb_build_object('encounter_id', feed_test.id(100), 'link_id', feed_test.link_id(3 - v), 'saved', false)
                    end;
                    return next extensions.is(feed_test.as_caller(feed_test.id(actor),
                        case when operation in ('favorite_on', 'favorite_off') then 'favorite' else operation end,
                        feed_test.id(100), feed_test.link_id(3 - v), operation <> 'favorite_off'),
                        expected, label || ': ' || operation || ' exact response');
                end if;
            end loop;
        end loop;
    end loop;
end;
$$;

grant execute on all functions in schema feed_test to anon, authenticated, service_role;
revoke all on function feed_test.reset_pair(integer,text), feed_test.gate_matrix() from public, anon, authenticated, service_role;
grant execute on all functions in schema extensions to anon, authenticated, service_role;

-- Hand-counted: catalog 42, null gate 4, matrix 324, errors/roles 42,
-- wire 20, references/retention 38, batch 8, ordering/dedup 14, caps 27, scalar timings 4, extras 31 = 554.
select extensions.plan(554);

create temporary table reading_rpcs (signature text, names text[], statement text);
insert into reading_rpcs values
    ('public.get_encounter_card(uuid)', array['encounter_id'], 'select public.get_encounter_card(null)'),
    ('public.get_encounter_feed()', null, 'select public.get_encounter_feed()'),
    ('public.list_encounter_favorites()', null, 'select public.list_encounter_favorites()'),
    ('public.set_encounter_favorite(uuid,boolean)', array['encounter_id','favorite'], 'select public.set_encounter_favorite(null,null)'),
    ('public.save_link(uuid,uuid)', array['encounter_id','link_id'], 'select public.save_link(null,null)'),
    ('public.unsave_link(uuid,uuid)', array['encounter_id','link_id'], 'select public.unsave_link(null,null)'),
    ('public.list_saved_links()', null, 'select public.list_saved_links()');
select extensions.is(p.proargnames, r.names, r.signature || ': exact argument names')
from reading_rpcs as r join pg_catalog.pg_proc as p on p.oid = r.signature::regprocedure;
select extensions.is(pg_catalog.format_type(p.prorettype, null), 'jsonb', r.signature || ': returns jsonb')
from reading_rpcs as r join pg_catalog.pg_proc as p on p.oid = r.signature::regprocedure;
select extensions.ok(p.prosecdef, r.signature || ': security definer')
from reading_rpcs as r join pg_catalog.pg_proc as p on p.oid = r.signature::regprocedure;
select extensions.ok('search_path=""' = any(p.proconfig), r.signature || ': empty search path')
from reading_rpcs as r join pg_catalog.pg_proc as p on p.oid = r.signature::regprocedure;
select extensions.is(p.proargnames, array['viewer_id','encounter_id'], 'gate argument names')
from pg_catalog.pg_proc as p where p.oid = 'private.visible_encounter_card(uuid,uuid)'::regprocedure;
select extensions.is(pg_catalog.format_type(p.prorettype, null), 'jsonb', 'gate returns jsonb')
from pg_catalog.pg_proc as p where p.oid = 'private.visible_encounter_card(uuid,uuid)'::regprocedure;
select extensions.is(p.provolatile::text, 's', 'gate reads its caller statement snapshot')
from pg_catalog.pg_proc as p where p.oid = 'private.visible_encounter_card(uuid,uuid)'::regprocedure;
select extensions.ok(p.prosecdef and 'search_path=""' = any(p.proconfig), 'gate definer has empty search path')
from pg_catalog.pg_proc as p where p.oid = 'private.visible_encounter_card(uuid,uuid)'::regprocedure;
select extensions.ok(not pg_catalog.has_function_privilege(r.name, 'private.visible_encounter_card(uuid,uuid)', 'execute'),
    r.name || ' cannot execute gate') from (values ('anon'),('authenticated'),('service_role')) as r(name);
select extensions.ok(not exists (select 1 from pg_catalog.pg_proc as p
    cross join lateral pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f',p.proowner))) as a
    where p.oid = 'private.visible_encounter_card(uuid,uuid)'::regprocedure and a.grantee = 0), 'no PUBLIC gate grant');
select extensions.is((select pg_catalog.array_agg(a.attname::text order by a.attnum) from pg_catalog.pg_attribute as a
    where a.attrelid = 'private.saved_links'::regclass and a.attnum > 0 and not a.attisdropped),
    array['viewer_id','encounter_id','link_id'], 'references have no metadata or timestamps');
select extensions.is((select pg_catalog.pg_get_constraintdef(c.oid) from pg_catalog.pg_constraint as c
    where c.conrelid = 'private.saved_links'::regclass and c.contype = 'p'),
    'PRIMARY KEY (viewer_id, encounter_id, link_id)', 'reference uniqueness');
select extensions.is((select pg_catalog.count(*) from pg_catalog.pg_constraint as c
    where c.conrelid = 'private.saved_links'::regclass and c.contype = 'f' and c.confdeltype = 'c'),
    3::bigint, 'all three reference FKs cascade');
select extensions.ok(c.relrowsecurity, 'saved references have RLS') from pg_catalog.pg_class as c
where c.oid = 'private.saved_links'::regclass;
select extensions.is((select pg_catalog.count(*) from pg_catalog.pg_policy where polrelid = 'private.saved_links'::regclass),
    0::bigint, 'saved references have no client policies');
select extensions.is((select pg_catalog.count(*) from pg_catalog.pg_index as i
    where i.indrelid = 'private.saved_links'::regclass), 3::bigint, 'PK and both cascade/lookup indexes');

select feed_test.reset_pair();
select extensions.is(private.visible_encounter_card(v.viewer, v.encounter), null::jsonb, v.label)
from (values (null::uuid, feed_test.id(100), 'null viewer fails closed'),
    (feed_test.id(1), null::uuid, 'null encounter fails closed'),
    (feed_test.id(999), feed_test.id(100), 'unknown viewer fails closed'),
    (feed_test.id(1), feed_test.id(999), 'unknown encounter fails closed')) as v(viewer,encounter,label);
select * from feed_test.gate_matrix();

-- Stable errors: each of 7 RPCs rejects a missing/deleted Auth caller (14).
select feed_test.error_call(v.viewer, op.operation, null, null, null, 'not_authenticated', '',
    op.operation || ': missing/deleted caller ' || v.viewer)
from (values (999), (null::integer)) as v(viewer)
cross join (values ('card'),('feed'),('favorites'),('saved'),('favorite'),('save'),('unsave')) as op(operation);
select feed_test.reset_pair();
-- Null identifiers/boolean: signature order and only the failing fields (10).
select feed_test.error_call(1, v.operation, v.encounter, v.link, v.favorite_value, 'invalid_input', v.detail,
    v.operation || ': invalid_input(' || v.detail || ')')
from (values
    ('card',null::uuid,null::uuid,true,'encounter_id'),
    ('favorite',null::uuid,null::uuid,null::boolean,'encounter_id,favorite'),
    ('favorite',null::uuid,null::uuid,true,'encounter_id'),
    ('favorite',feed_test.id(100),null::uuid,null::boolean,'favorite'),
    ('save',null::uuid,null::uuid,true,'encounter_id,link_id'),
    ('save',null::uuid,feed_test.link_id(2),true,'encounter_id'),
    ('save',feed_test.id(100),null::uuid,true,'link_id'),
    ('unsave',null::uuid,null::uuid,true,'encounter_id,link_id'),
    ('unsave',null::uuid,feed_test.link_id(2),true,'encounter_id'),
    ('unsave',feed_test.id(100),null::uuid,true,'link_id')) as v(operation,encounter,link,favorite_value,detail);
select feed_test.error_call(1, op.operation, feed_test.id(999), feed_test.link_id(2), true, 'not_found', '',
    op.operation || ': absent encounter') from (values ('card'),('favorite'),('save'),('unsave')) as op(operation);
-- Actual role denials for every public function (14).
grant select on reading_rpcs to anon, service_role;
set local role anon;
select extensions.throws_ok(r.statement, '42501', 'permission denied for function ' ||
    pg_catalog.split_part(pg_catalog.split_part(r.signature, '.', 2), '(', 1), 'anon denial: ' || r.signature)
from reading_rpcs as r;
reset role;
set local role service_role;
select extensions.throws_ok(r.statement, '42501', 'permission denied for function ' ||
    pg_catalog.split_part(pg_catalog.split_part(r.signature, '.', 2), '(', 1), 'service denial: ' || r.signature)
from reading_rpcs as r;
reset role;

-- Wire/privacy: 2 directions x 10 exact assertions = 20.
create function feed_test.wire()
returns setof text language plpgsql set search_path = pg_catalog, extensions as $$
declare v integer; base jsonb; shell jsonb; linked jsonb; saved jsonb;
begin
    for v in 1..2 loop
        perform feed_test.reset_pair(v);
        update private.field_visibility set level = 'private' where owner_id = feed_test.id(3 - v);
        update private.external_links set visibility = 'private' where owner_id = feed_test.id(3 - v);
        base := pg_catalog.jsonb_build_object('encounter_id', feed_test.id(100), 'day', feed_test.day(), 'kind', 'session');
        shell := base || '{"shell":true}'::jsonb;
        return next extensions.is(private.visible_encounter_card(feed_test.id(v), feed_test.id(100)), shell, 'plain shell ' || v);
        return next extensions.is(feed_test.as_caller(feed_test.id(v), 'card', feed_test.id(100)),
            shell || '{"favorite":true,"saved_link_ids":[]}'::jsonb, 'detail shell and private saved ids ' || v);
        return next extensions.is(feed_test.as_caller(feed_test.id(v), 'feed'),
            pg_catalog.jsonb_build_object('cards', pg_catalog.jsonb_build_array(shell || '{"favorite":true}'::jsonb), 'truncated', false),
            'feed shell has no protected fields/shared ids/count or own saved ids ' || v);
        return next extensions.is(feed_test.as_caller(feed_test.id(v), 'favorites'),
            pg_catalog.jsonb_build_object('cards', pg_catalog.jsonb_build_array(shell || '{"favorite":true}'::jsonb), 'truncated', false),
            'favorite shell has no protected fields/shared ids/count ' || v);
        return next extensions.is(feed_test.as_caller(feed_test.id(v), 'saved'), '{"links":[],"truncated":false}'::jsonb,
            'private links absent from saved reads ' || v);
        update private.external_links set visibility = 'everyone_eligible' where link_id = feed_test.link_id(3 - v);
        linked := base || pg_catalog.jsonb_build_object('links', pg_catalog.jsonb_build_array(feed_test.expected_link(3 - v)));
        return next extensions.is(feed_test.as_caller(feed_test.id(v), 'card', feed_test.id(100)),
            linked || pg_catalog.jsonb_build_object('favorite', true, 'saved_link_ids', array[feed_test.link_id(3 - v)]),
            'visible link has link_id/null language but no owner/source-item/visibility/order ' || v);
        return next extensions.is(feed_test.as_caller(feed_test.id(v), 'feed'),
            pg_catalog.jsonb_build_object('cards', pg_catalog.jsonb_build_array(linked || '{"favorite":true}'::jsonb), 'truncated', false),
            'link-only feed omits shell and forbidden shared ids ' || v);
        return next extensions.is(feed_test.as_caller(feed_test.id(v), 'favorites'),
            pg_catalog.jsonb_build_object('cards', pg_catalog.jsonb_build_array(linked || '{"favorite":true}'::jsonb), 'truncated', false),
            'link-only favorites omit shell and forbidden shared ids ' || v);
        saved := pg_catalog.jsonb_build_object('links', pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
            'encounter_id', feed_test.id(100), 'day', feed_test.day(), 'kind', 'session', 'link', feed_test.expected_link(3 - v))),
            'truncated', false);
        return next extensions.is(feed_test.as_caller(feed_test.id(v), 'saved'), saved, 'saved link has exact VisibleLink keys ' || v);
        update private.field_visibility set level = 'compatible_only' where owner_id = feed_test.id(3 - v) and field = 'interests';
        update private.matching_preferences set minimum_shared_interests = 10 where user_id = feed_test.id(v);
        return next extensions.is(feed_test.as_caller(feed_test.id(v), 'feed'),
            pg_catalog.jsonb_build_object('cards', pg_catalog.jsonb_build_array(linked || '{"favorite":true}'::jsonb), 'truncated', false),
            'failed threshold never exposes protected interest ids ' || v);
    end loop;
end;
$$;
select * from feed_test.wire();

-- Reference writes/retention: 38 assertions, including both last-reason orders.
select feed_test.reset_pair();
update private.encounters set day_a = feed_test.day() - 40, day_b = feed_test.day() - 40 where encounter_id = feed_test.id(100);
select extensions.is(feed_test.as_caller(feed_test.id(1), 'favorite', feed_test.id(100), null, false),
    pg_catalog.jsonb_build_object('encounter_id', feed_test.id(100), 'favorite', false), 'remove favorite after ordinary expiry');
select extensions.is(feed_test.as_caller(feed_test.id(1), 'card', feed_test.id(100))->'favorite', 'false'::jsonb,
    'saved reference still retains access');
select extensions.is(feed_test.as_caller(feed_test.id(1), 'unsave', feed_test.id(100), feed_test.link_id(2))->'saved',
    'false'::jsonb, 'last saved reason removal succeeds after ordinary expiry');
select feed_test.error_call(1, 'card', feed_test.id(100), null, true, 'not_found', '', 'last reason removal immediately removes access');
select extensions.is(feed_test.as_caller(feed_test.id(2), 'card', feed_test.id(100))->>'day',
    (feed_test.day() - 40)::text, 'other viewer retention reasons survive');
select extensions.is(feed_test.as_caller(feed_test.id(2), 'unsave', feed_test.id(100), feed_test.link_id(1))->'saved',
    'false'::jsonb, 'remove saved reason while favorite remains');
select extensions.is(feed_test.as_caller(feed_test.id(2), 'card', feed_test.id(100))->'favorite', 'true'::jsonb,
    'favorite still retains the other viewer');
select extensions.is(feed_test.as_caller(feed_test.id(2), 'favorite', feed_test.id(100), null, false)->'favorite',
    'false'::jsonb, 'last favorite reason removal succeeds');
select feed_test.error_call(2, 'card', feed_test.id(100), null, true, 'not_found', '', 'second viewer independently loses access');

select feed_test.reset_pair();
select extensions.is(pg_catalog.jsonb_build_array(
    feed_test.as_caller(feed_test.id(1), 'favorite', feed_test.id(100)),
    feed_test.as_caller(feed_test.id(1), 'favorite', feed_test.id(100))),
    pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('encounter_id', feed_test.id(100), 'favorite', true),
        pg_catalog.jsonb_build_object('encounter_id', feed_test.id(100), 'favorite', true)), 'favorite repeats are exact idempotent success');
select extensions.is(pg_catalog.jsonb_build_array(
    feed_test.as_caller(feed_test.id(1), 'save', feed_test.id(100), feed_test.link_id(2)),
    feed_test.as_caller(feed_test.id(1), 'save', feed_test.id(100), feed_test.link_id(2))),
    pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('encounter_id', feed_test.id(100), 'link_id', feed_test.link_id(2), 'saved', true),
        pg_catalog.jsonb_build_object('encounter_id', feed_test.id(100), 'link_id', feed_test.link_id(2), 'saved', true)), 'save repeats are exact idempotent success');
select extensions.is((select pg_catalog.count(*) from private.saved_links where viewer_id = feed_test.id(1)), 1::bigint,
    'one reference per viewer/encounter/link');
select extensions.is(pg_catalog.jsonb_build_array(
    feed_test.as_caller(feed_test.id(1), 'unsave', feed_test.id(100), feed_test.link_id(2)),
    feed_test.as_caller(feed_test.id(1), 'unsave', feed_test.id(100), feed_test.link_id(2))),
    pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('encounter_id', feed_test.id(100), 'link_id', feed_test.link_id(2), 'saved', false),
        pg_catalog.jsonb_build_object('encounter_id', feed_test.id(100), 'link_id', feed_test.link_id(2), 'saved', false)), 'missing reference succeeds while card/link authorized');
select extensions.is((select pg_catalog.count(*) from private.saved_links where viewer_id = feed_test.id(1)), 0::bigint,
    'unsave removes caller reference only');
select extensions.is(feed_test.as_caller(feed_test.id(2), 'card', feed_test.id(100))->'saved_link_ids',
    pg_catalog.jsonb_build_array(feed_test.link_id(1)), 'other viewer saved state unaffected');

select feed_test.reset_pair();
update private.encounters set day_a = feed_test.day() - 40 where encounter_id = feed_test.id(100);
update private.encounter_views set favorite = false where viewer_id = feed_test.id(1);
update private.external_links set visibility = 'private' where link_id = feed_test.link_id(2);
select extensions.is(feed_test.as_caller(feed_test.id(1), 'card', feed_test.id(100))->'saved_link_ids', '[]'::jsonb,
    'private reference retains expired card without leaking its id');
select extensions.is(feed_test.as_caller(feed_test.id(1), 'saved'), '{"links":[],"truncated":false}'::jsonb,
    'private reference has no authorized saved metadata');
select extensions.is((select pg_catalog.count(*) from private.saved_links where viewer_id = feed_test.id(1)), 1::bigint,
    'private saved reference remains stored');
select feed_test.error_call(1, op.operation, feed_test.id(100), feed_test.link_id(2), true, 'not_found', '',
    op.operation || ': private link is indistinguishable from absent') from (values ('save'),('unsave')) as op(operation);
update private.external_links set visibility = 'everyone_eligible', title = 'Updated' where link_id = feed_test.link_id(2);
select extensions.is(feed_test.as_caller(feed_test.id(1), 'saved')#>>'{links,0,link,title}', 'Updated',
    'saved reads resolve current metadata when link returns');
select extensions.is(feed_test.as_caller(feed_test.id(1), 'unsave', feed_test.id(100), feed_test.link_id(2))->'saved', 'false'::jsonb,
    'private reference can be removed when visible again');
select feed_test.error_call(1, 'card', feed_test.id(100), null, true, 'not_found', '', 'unsaving restored last reason ends access');

select feed_test.reset_pair();
update private.encounters set day_a = feed_test.day() - 40 where encounter_id = feed_test.id(100);
update private.encounter_views set favorite = false where viewer_id = feed_test.id(1);
delete from private.external_links where link_id = feed_test.link_id(2);
select extensions.is((select pg_catalog.count(*) from private.saved_links where viewer_id = feed_test.id(1)), 0::bigint,
    'link deletion cascades its reference');
select extensions.is(feed_test.as_caller(feed_test.id(1), 'saved'), '{"links":[],"truncated":false}'::jsonb,
    'deleted link has no saved read');
select feed_test.error_call(1, 'card', feed_test.id(100), null, true, 'not_found', '', 'deleted last reference no longer retains encounter');
select feed_test.error_call(1, op.operation, feed_test.id(100), feed_test.link_id(2), true, 'not_found', '',
    op.operation || ': deleted link') from (values ('save'),('unsave')) as op(operation);
insert into private.external_links (link_id, owner_id, source, source_item_id, url, title, description,
    tags, opening_text, visibility, display_order)
values (feed_test.link_id(2), feed_test.id(2), 'other', 'secret-1', 'https://example.invalid/2/1',
    'Link1', 'Description1', array['tag'], 'Opening1', 'everyone_eligible', 1);
select feed_test.reset_pair();
select feed_test.error_call(1, op.operation, feed_test.id(100), l.link, true, 'not_found', '',
    op.operation || ': ' || l.label)
from (values (feed_test.link_id(1), 'own link'), (feed_test.link_id(3), 'unrelated owner'),
    (feed_test.link_id(2,2), 'private counterpart link'), (feed_test.id(99999), 'unknown link')) as l(link,label)
cross join (values ('save'),('unsave')) as op(operation);
update private.external_links set visibility = 'compatible_only' where link_id = feed_test.link_id(2);
update private.matching_preferences set minimum_shared_interests = 10 where user_id = feed_test.id(1);
select feed_test.error_call(1, op.operation, feed_test.id(100), feed_test.link_id(2), true, 'not_found', '',
    op.operation || ': compatibility-protected counterpart link') from (values ('save'),('unsave')) as op(operation);

-- Multi-owner batch: 8 assertions. Each owner's payload/state remains separate;
-- an owner-side discovery denial sits beside two differently authorized owners.
select feed_test.reset_pair();
insert into private.encounters (encounter_id,user_a,user_b,kind,day_a,day_b)
select feed_test.id(4000+n),feed_test.id(1),feed_test.id(n),'session',feed_test.day(),feed_test.day()
from pg_catalog.generate_series(4,6) as n;
insert into private.encounter_views (encounter_id,viewer_id,revealed,reveal_report_day,favorite)
select feed_test.id(4000+n),feed_test.id(1),true,feed_test.day(),n<>4 from pg_catalog.generate_series(4,6) as n;
insert into private.saved_links (viewer_id,encounter_id,link_id)
select feed_test.id(1),feed_test.id(4000+n),feed_test.link_id(n) from pg_catalog.generate_series(4,6) as n;
update private.field_visibility set level=case field when 'introduction' then 'private' when 'purposes' then 'private'
    when 'contact_detail' then 'compatible_only' else 'everyone_eligible' end where owner_id=feed_test.id(4);
update private.field_visibility set level=case field when 'display_name' then 'private' when 'contact_detail' then 'private'
    when 'interests' then 'compatible_only' else 'everyone_eligible' end where owner_id=feed_test.id(5);
insert into private.user_interests values (feed_test.id(5),'feed-m');
update private.user_purposes set purpose='collaboration' where user_id=feed_test.id(5);
update private.external_links set visibility='compatible_only' where link_id=feed_test.link_id(5,2);
update private.profiles set discovery_on=false where user_id=feed_test.id(6);
select extensions.is(feed_test.as_caller(feed_test.id(1),'feed'),pg_catalog.jsonb_build_object('cards',pg_catalog.jsonb_build_array(
    feed_test.expected_card(1,feed_test.day()) || pg_catalog.jsonb_build_object('favorite',true,'shared_interest_ids',array['feed-a','feed-z']),
    pg_catalog.jsonb_build_object('encounter_id',feed_test.id(4004),'kind','session','day',feed_test.day(),
        'display_name','Owner4','contact_detail','Contact4','interests',array['feed-a','feed-z'],
        'links',pg_catalog.jsonb_build_array(feed_test.expected_link(4)),'favorite',false,'shared_interest_ids',array['feed-a','feed-z']),
    pg_catalog.jsonb_build_object('encounter_id',feed_test.id(4005),'kind','session','day',feed_test.day(),
        'introduction','Intro5','purposes',array['collaboration'],
        'links',pg_catalog.jsonb_build_array(feed_test.expected_link(5)),'favorite',true)
), 'truncated',false), 'batch keeps each owner fields, links, purposes and protected intersection separate');
select extensions.is((select pg_catalog.jsonb_agg(c.value->'encounter_id' order by c.position)
    from pg_catalog.jsonb_array_elements(feed_test.as_caller(feed_test.id(1),'favorites')->'cards') with ordinality as c(value,position)),
    pg_catalog.jsonb_build_array(feed_test.id(100),feed_test.id(4005)),'batch favorite state belongs to each encounter');
select extensions.is((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_array(l.value->'encounter_id',l.value#>'{link,link_id}') order by l.position)
    from pg_catalog.jsonb_array_elements(feed_test.as_caller(feed_test.id(1),'saved')->'links') with ordinality as l(value,position)),
    pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_array(feed_test.id(100),feed_test.link_id(2)),
        pg_catalog.jsonb_build_array(feed_test.id(4004),feed_test.link_id(4)),
        pg_catalog.jsonb_build_array(feed_test.id(4005),feed_test.link_id(5))), 'batch saved links retain per-owner references and omit denied owner');
select extensions.is(pg_catalog.jsonb_build_array(
    feed_test.as_caller(feed_test.id(1),'card',feed_test.id(4004))->'favorite',
    feed_test.as_caller(feed_test.id(1),'card',feed_test.id(4004))->'saved_link_ids'),
    pg_catalog.jsonb_build_array(false,pg_catalog.jsonb_build_array(feed_test.link_id(4))),'owner 4 scalar state agrees with batch');
select extensions.is(pg_catalog.jsonb_build_array(
    feed_test.as_caller(feed_test.id(1),'card',feed_test.id(4005))->'favorite',
    feed_test.as_caller(feed_test.id(1),'card',feed_test.id(4005))->'saved_link_ids'),
    pg_catalog.jsonb_build_array(true,pg_catalog.jsonb_build_array(feed_test.link_id(5))),'owner 5 scalar state agrees with batch');
select feed_test.error_call(1,'card',feed_test.id(4006),null,true,'not_found','','batch owner-side denial also hides scalar card');
select feed_test.error_call(1,'save',feed_test.id(4006),feed_test.link_id(6),true,'not_found','','batch owner-side denial also prevents save');
select extensions.is((select pg_catalog.count(*) from private.saved_links where encounter_id=feed_test.id(4006)),1::bigint,
    'denied batch reference stays stored without exposing a snapshot');
delete from private.encounters where encounter_id in (feed_test.id(4004),feed_test.id(4005),feed_test.id(4006));
delete from private.user_interests where user_id=feed_test.id(5) and interest_id='feed-m';
update private.field_visibility set level='everyone_eligible' where owner_id in (feed_test.id(4),feed_test.id(5));
update private.user_purposes set purpose='discovery' where user_id=feed_test.id(5);
update private.external_links set visibility='private' where link_id=feed_test.link_id(5,2);
update private.profiles set discovery_on=true where user_id=feed_test.id(6);

-- Ordering/dedup: 14 assertions. Deliberately permute UUID, count, match and day.
select feed_test.reset_pair();
update private.encounters set day_a = feed_test.day() - 1 where encounter_id = feed_test.id(100);
insert into private.user_interests values (feed_test.id(1),'feed-m'), (feed_test.id(5),'feed-m'), (feed_test.id(6),'feed-m');
delete from private.user_interests where user_id = feed_test.id(7) and interest_id = 'feed-z';
update private.user_purposes set purpose = 'collaboration' where user_id = feed_test.id(6);
insert into private.encounters (encounter_id,user_a,user_b,kind,day_a,day_b)
select feed_test.id(1000+n),feed_test.id(1),feed_test.id(n),'session',feed_test.day(),feed_test.day()
from pg_catalog.generate_series(4,7) as n;
insert into private.encounter_views (encounter_id,viewer_id,revealed,reveal_report_day,favorite)
select feed_test.id(1000+n),feed_test.id(1),true,feed_test.day(),true from pg_catalog.generate_series(4,7) as n;
select extensions.is((select pg_catalog.jsonb_agg(c.value->'encounter_id' order by c.position)
    from pg_catalog.jsonb_array_elements(feed_test.as_caller(feed_test.id(1),'feed')->'cards') with ordinality as c(value,position)),
    pg_catalog.jsonb_build_array(feed_test.id(1005),feed_test.id(1004),feed_test.id(1006),feed_test.id(1007),feed_test.id(100)),
    'feed sorts day, compatibility, shared count, then UUID');
select extensions.is((select pg_catalog.jsonb_agg(c.value->'encounter_id' order by c.position)
    from pg_catalog.jsonb_array_elements(feed_test.as_caller(feed_test.id(1),'favorites')->'cards') with ordinality as c(value,position)),
    pg_catalog.jsonb_build_array(feed_test.id(1005),feed_test.id(1004),feed_test.id(1006),feed_test.id(1007),feed_test.id(100)),
    'favorites use the same full ordering');
-- Simulate a later encounter after only the counterpart changes registered zone.
update private.notification_preferences set time_zone = 'Etc/GMT-14' where user_id = feed_test.id(5);
insert into private.encounters values (feed_test.id(1505),feed_test.id(1),feed_test.id(5),'session',feed_test.day(),feed_test.day()+1);
insert into private.encounter_views values (feed_test.id(1505),feed_test.id(1),true,feed_test.day(),true);
update private.encounter_views set favorite = false where encounter_id = feed_test.id(1005);
insert into private.saved_links values (feed_test.id(1),feed_test.id(1005),feed_test.link_id(5));
select extensions.is(feed_test.as_caller(feed_test.id(1),'feed')#>>'{cards,0,encounter_id}',feed_test.id(1505)::text,
    'favorite wins same counterpart/kind/viewer day after counterpart zone change');
select extensions.is(feed_test.as_caller(feed_test.id(1),'favorites')#>>'{cards,0,encounter_id}',feed_test.id(1505)::text,
    'favorites filter before dedup');
select extensions.is((select pg_catalog.count(*) from private.encounters where user_b = feed_test.id(5)),2::bigint,
    'dedup preserves both underlying date-pair rows');
select extensions.ok(exists (select 1 from private.saved_links where encounter_id = feed_test.id(1005)),
    'dedup never moves saved references to its winner');
select extensions.is(feed_test.as_caller(feed_test.id(1),'card',feed_test.id(1005))->'saved_link_ids',
    pg_catalog.jsonb_build_array(feed_test.link_id(5)), 'dedup loser detail remains independently authorized');
do $$ begin
    perform feed_test.as_caller(feed_test.id(1),'favorite',feed_test.id(1505),null,false);
end; $$;
select extensions.is(feed_test.as_caller(feed_test.id(1),'feed')#>>'{cards,0,encounter_id}',feed_test.id(1005)::text,
    'without a favorite the smallest encounter UUID wins');
select extensions.is((select pg_catalog.jsonb_agg(c.value->'encounter_id' order by c.position)
    from pg_catalog.jsonb_array_elements(feed_test.as_caller(feed_test.id(1),'favorites')->'cards') with ordinality as c(value,position)),
    pg_catalog.jsonb_build_array(feed_test.id(1004),feed_test.id(1006),feed_test.id(1007),feed_test.id(100)),
    'unfavorite removes only that encounter from favorite selection');
update private.external_links set visibility = 'everyone_eligible',display_order = 0 where link_id = feed_test.link_id(5,2);
insert into private.saved_links values (feed_test.id(1),feed_test.id(1005),feed_test.link_id(5,2)),
    (feed_test.id(1),feed_test.id(1505),feed_test.link_id(5));
select extensions.is((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_array(l.value->'encounter_id',l.value#>'{link,link_id}') order by l.position)
    from pg_catalog.jsonb_array_elements(feed_test.as_caller(feed_test.id(1),'saved')->'links') with ordinality as l(value,position)),
    pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_array(feed_test.id(1005),feed_test.link_id(5,2)),
        pg_catalog.jsonb_build_array(feed_test.id(1005),feed_test.link_id(5)),
        pg_catalog.jsonb_build_array(feed_test.id(1505),feed_test.link_id(5)),
        pg_catalog.jsonb_build_array(feed_test.id(100),feed_test.link_id(2))), 'saved order is day, encounter UUID, current link order/UUID');
select extensions.is(pg_catalog.jsonb_array_length(feed_test.as_caller(feed_test.id(1),'saved')->'links'),4,
    'saved list retains individual references from both dedup rows');
select extensions.is((select pg_catalog.count(*) from private.saved_links where viewer_id = feed_test.id(1)
    and encounter_id in (feed_test.id(1005),feed_test.id(1505))),3::bigint,'multiple references are not merged by feed dedup');
insert into private.encounters values (feed_test.id(1605),feed_test.id(1),feed_test.id(5),'qr',feed_test.day(),feed_test.day());
insert into private.encounter_views values (feed_test.id(1605),feed_test.id(1),true,feed_test.day(),false);
select extensions.is(pg_catalog.jsonb_array_length(feed_test.as_caller(feed_test.id(1),'feed')->'cards'),6,
    'different kind survives same-day dedup');
insert into private.encounters values (feed_test.id(1705),feed_test.id(1),feed_test.id(5),'session',feed_test.day()-2,feed_test.day()+4);
insert into private.encounter_views values (feed_test.id(1705),feed_test.id(1),true,feed_test.day(),false);
select extensions.is(pg_catalog.jsonb_array_length(feed_test.as_caller(feed_test.id(1),'feed')->'cards'),7,
    'different viewer-local day survives dedup');

-- Cap boundaries and timings: 27 assertions. Clean up the sort fixtures first.
delete from private.encounters where user_a = feed_test.id(1);
delete from private.user_interests where user_id in (feed_test.id(1),feed_test.id(5),feed_test.id(6)) and interest_id = 'feed-m';
insert into private.user_interests values (feed_test.id(7),'feed-z');
update private.user_purposes set purpose = 'discovery' where user_id = feed_test.id(6);
insert into private.encounters (encounter_id,user_a,user_b,kind,day_a,day_b)
select feed_test.id(1000+n),feed_test.id(1),feed_test.id(n),'session',feed_test.day(),feed_test.day()
from pg_catalog.generate_series(4,204) as n;
insert into private.encounter_views (encounter_id,viewer_id,revealed,reveal_report_day,favorite)
select feed_test.id(1000+n),feed_test.id(1),true,feed_test.day(),false from pg_catalog.generate_series(4,204) as n;
select extensions.is(pg_catalog.jsonb_array_length(feed_test.as_caller(feed_test.id(1),'feed')->'cards'),200,'201 visible winners cap at 200');
select extensions.is(feed_test.as_caller(feed_test.id(1),'feed')->'truncated','true'::jsonb,'201 visible winners truncate');
select extensions.is(feed_test.as_caller(feed_test.id(1),'feed')#>>'{cards,199,encounter_id}',feed_test.id(1203)::text,'UUID ordering at cap');
update private.encounter_views set revealed = false where encounter_id = feed_test.id(1204);
select extensions.is(feed_test.as_caller(feed_test.id(1),'feed')->'truncated','false'::jsonb,'hidden sentinel does not truncate 200 winners');
select extensions.is(pg_catalog.jsonb_array_length(feed_test.as_caller(feed_test.id(1),'feed')->'cards'),200,'exactly 200 winners retained');
-- 250 extra date-pair rows for one counterpart must dedup before the cap.
insert into private.encounters (encounter_id,user_a,user_b,kind,day_a,day_b)
select feed_test.id(2000+n),feed_test.id(1),feed_test.id(4),'session',feed_test.day(),feed_test.day()+n
from pg_catalog.generate_series(1,250) as n;
insert into private.encounter_views (encounter_id,viewer_id,revealed,reveal_report_day,favorite)
select feed_test.id(2000+n),feed_test.id(1),true,feed_test.day(),n=250 from pg_catalog.generate_series(1,250) as n;
select extensions.is(pg_catalog.jsonb_array_length(feed_test.as_caller(feed_test.id(1),'feed')->'cards'),200,'dedup precedes the 200 cap');
select extensions.is(feed_test.as_caller(feed_test.id(1),'feed')->'truncated','false'::jsonb,'450 rows but 200 winners are not truncated');
select extensions.ok((select pg_catalog.bool_or(c->>'encounter_id'=feed_test.id(2250)::text)
    and not pg_catalog.bool_or(c->>'encounter_id'=feed_test.id(1004)::text)
    from pg_catalog.jsonb_array_elements(feed_test.as_caller(feed_test.id(1),'feed')->'cards') as c),'favorite beyond raw cap wins dedup');
select extensions.is((select pg_catalog.count(*) from private.encounters where user_b=feed_test.id(4)),251::bigint,'dedup does not delete rows');
update private.encounter_views set revealed = true where encounter_id=feed_test.id(1204);
select extensions.is(feed_test.as_caller(feed_test.id(1),'feed')->'truncated','true'::jsonb,'201 dedup winners truncate despite duplicates');
select extensions.is(pg_catalog.jsonb_array_length(feed_test.as_caller(feed_test.id(1),'feed')->'cards'),200,'201 dedup winners return 200');
update private.encounter_views set revealed = false where encounter_id between feed_test.id(2001) and feed_test.id(2250);
select extensions.ok((select pg_catalog.bool_or(c->>'encounter_id'=feed_test.id(1004)::text)
    from pg_catalog.jsonb_array_elements(feed_test.as_caller(feed_test.id(1),'feed')->'cards') as c),'gate filtering precedes favorite winner selection');
-- These 201 older favorite/saved cards all fall outside the ordinary feed cap.
insert into private.encounters (encounter_id,user_a,user_b,kind,day_a,day_b)
select feed_test.id(5000+n),feed_test.id(1),feed_test.id(n),'qr',feed_test.day()-40,feed_test.day()-40
from pg_catalog.generate_series(4,204) as n;
insert into private.encounter_views (encounter_id,viewer_id,revealed,reveal_report_day,favorite)
select feed_test.id(5000+n),feed_test.id(1),true,feed_test.day(),true from pg_catalog.generate_series(4,204) as n;
insert into private.saved_links (viewer_id,encounter_id,link_id)
select feed_test.id(1),feed_test.id(5000+n),feed_test.link_id(n) from pg_catalog.generate_series(4,204) as n;
select extensions.is(feed_test.as_caller(feed_test.id(1),'favorites')#>>'{cards,0,encounter_id}',feed_test.id(5004)::text,'favorites independently include old retained rows');
select extensions.is(pg_catalog.jsonb_array_length(feed_test.as_caller(feed_test.id(1),'favorites')->'cards'),200,'favorites cap at 200');
select extensions.is(feed_test.as_caller(feed_test.id(1),'favorites')->'truncated','true'::jsonb,'201 authorized favorites truncate');
select extensions.ok(not exists (select 1 from pg_catalog.jsonb_array_elements(feed_test.as_caller(feed_test.id(1),'feed')->'cards') as c
    where (c->>'encounter_id')::uuid >= feed_test.id(5004)),'ordinary feed cap excludes older favorites');
select extensions.is(pg_catalog.jsonb_array_length(feed_test.as_caller(feed_test.id(1),'saved')->'links'),200,'saved references independently cap at 200');
select extensions.is(feed_test.as_caller(feed_test.id(1),'saved')->'truncated','true'::jsonb,'201 authorized saved references truncate');
select extensions.is(feed_test.as_caller(feed_test.id(1),'saved')#>>'{links,0,encounter_id}',feed_test.id(5004)::text,'saved list independently includes old retained rows');
-- Both helpers are volatile: materialize each response once before comparing.
with responses as materialized (
    select feed_test.as_caller(feed_test.id(1),'feed') as feed,
        feed_test.as_caller(feed_test.id(1),'saved') as saved
)
select extensions.ok(not exists (
    select 1 from responses as r
    cross join lateral pg_catalog.jsonb_array_elements(r.feed->'cards') as c
    where c->>'encounter_id' = r.saved#>>'{links,0,encounter_id}'
), 'saved first entry lies outside capped feed');
update private.encounter_views set revealed = false where encounter_id=feed_test.id(5204);
select extensions.is(feed_test.as_caller(feed_test.id(1),'favorites')->'truncated','false'::jsonb,'200 authorized favorites plus hidden favorite are not truncated');
select extensions.is(pg_catalog.jsonb_array_length(feed_test.as_caller(feed_test.id(1),'favorites')->'cards'),200,'exactly 200 favorites returned');
select extensions.is(feed_test.as_caller(feed_test.id(1),'saved')->'truncated','false'::jsonb,'200 authorized saved references plus hidden reference are not truncated');
select extensions.is(pg_catalog.jsonb_array_length(feed_test.as_caller(feed_test.id(1),'saved')->'links'),200,'exactly 200 saved references returned');
-- Each endpoint currently returns 200 entries. Allow loaded-laptop overhead,
-- while rejecting the previous multi-second per-card gate implementation.
select extensions.performs_ok(pg_catalog.format('select feed_test.as_caller(%L::uuid, %L)',
    feed_test.id(1), r.operation), 3000::numeric, '200-entry ' || r.operation || ' read completes within 3000 ms')
from (values ('feed'), ('favorites'), ('saved')) as r(operation);

-- Warm plans before timing. The caller still has hundreds of views and
-- references; scalar calls must use PK probes and avoid zone enumeration.
-- Four bounds in milliseconds also cover both saved-reference write branches.
select feed_test.as_caller(feed_test.id(1),'card',feed_test.id(1004));
select feed_test.as_caller(feed_test.id(1),'favorite',feed_test.id(1004),null,true);
select feed_test.as_caller(feed_test.id(1),'save',feed_test.id(1004),feed_test.link_id(4));
select feed_test.as_caller(feed_test.id(1),'unsave',feed_test.id(1004),feed_test.link_id(4));
select extensions.performs_ok(pg_catalog.format('select feed_test.as_caller(%L::uuid,%L,%L::uuid,%L::uuid,true)',
    feed_test.id(1),op.name,feed_test.id(1004),feed_test.link_id(4)),35::numeric,
    'single-card ' || op.name || ' completes within 35 ms')
from (values ('card'),('favorite'),('save'),('unsave')) as op(name);

-- Extra boundaries/Live/cascades: 31 assertions, for a total plan of 554.
delete from private.encounters where user_a=feed_test.id(1);
select feed_test.reset_pair();
delete from private.saved_links where encounter_id=feed_test.id(100);
update private.encounter_views set favorite=false where encounter_id=feed_test.id(100);
update private.encounters set day_a=feed_test.day()-29,day_b=feed_test.day()-30 where encounter_id=feed_test.id(100);
select extensions.is(feed_test.as_caller(feed_test.id(1),'card',feed_test.id(100))->>'day',(feed_test.day()-29)::text,
    'viewer A is retained through local day 29');
select feed_test.error_call(2,'card',feed_test.id(100),null,true,'not_found','','viewer B independently expires at local day 30');
update private.encounters set day_a=feed_test.day()-30 where encounter_id=feed_test.id(100);
update private.encounter_views set favorite=true where viewer_id=feed_test.id(1);
select extensions.is(feed_test.as_caller(feed_test.id(1),'card',feed_test.id(100))->'favorite','true'::jsonb,'only A favorite extends A expiry');
select feed_test.error_call(2,'card',feed_test.id(100),null,true,'not_found','','A favorite never extends B expiry');
update private.encounter_views set favorite=false where viewer_id=feed_test.id(1);
update private.encounters set day_a=(pg_catalog.now() at time zone 'Etc/GMT-14')::date-30 where encounter_id=feed_test.id(100);
update private.notification_preferences set time_zone='Etc/GMT-14' where user_id=feed_test.id(1);
select feed_test.error_call(1,'card',feed_test.id(100),null,true,'not_found','','UTC+14 viewer-local midnight has expired');
update private.notification_preferences set time_zone='Etc/GMT+12' where user_id=feed_test.id(1);
select extensions.is(feed_test.as_caller(feed_test.id(1),'card',feed_test.id(100))->>'day',
    ((pg_catalog.now() at time zone 'Etc/GMT-14')::date-30)::text,'current registered UTC-12 zone independently changes expiry');
select feed_test.error_call(2,'card',feed_test.id(100),null,true,'not_found','','viewer B retains its own zone/expiry');
update private.encounter_views set favorite=true where viewer_id=feed_test.id(1);
update private.notification_preferences set time_zone='invalid-zone' where user_id=feed_test.id(1);
select extensions.is(feed_test.as_caller(feed_test.id(1),'card',feed_test.id(100))->'favorite','true'::jsonb,
    'favorite bypasses invalid-zone retention calculation');
update private.encounter_views set favorite=false where viewer_id=feed_test.id(1);
insert into private.saved_links values (feed_test.id(1),feed_test.id(100),feed_test.link_id(2));
select extensions.is(feed_test.as_caller(feed_test.id(1),'card',feed_test.id(100))->'saved_link_ids',
    pg_catalog.jsonb_build_array(feed_test.link_id(2)),'saved reference also bypasses invalid-zone retention calculation');
delete from private.notification_preferences where user_id=feed_test.id(1);
select extensions.is(feed_test.as_caller(feed_test.id(1),'saved')#>>'{links,0,link,link_id}',feed_test.link_id(2)::text,
    'saved reference bypasses missing-zone retention for Live reads');

-- A hidden caller is refused by the shared gate on every read and write.
select feed_test.reset_pair();
update private.profiles set moderation_state='hidden' where user_id=feed_test.id(1);
select feed_test.error_call(1,'feed',null,null,true,'account_not_ready','','feed requires a ready caller');
select extensions.is(pg_catalog.jsonb_array_length(feed_test.as_caller(feed_test.id(1),'favorites')->'cards'),0,'hidden caller favorite list is empty');
select extensions.is(pg_catalog.jsonb_array_length(feed_test.as_caller(feed_test.id(1),'saved')->'links'),0,'hidden caller saved list is empty');
select feed_test.error_call(1,'favorite',feed_test.id(100),null,false,'not_found','','hidden caller cannot change favorites');
select feed_test.error_call(1,'save',feed_test.id(100),feed_test.link_id(2),true,'not_found','','hidden caller cannot save other peoples links');
select feed_test.error_call(1,'unsave',feed_test.id(100),feed_test.link_id(2),false,'not_found','','hidden caller cannot unsave other peoples links');

-- Authorized interests with no overlap must expose [], rather than omit it.
select feed_test.reset_pair();
delete from private.user_interests where user_id=feed_test.id(1);
select extensions.is(feed_test.as_caller(feed_test.id(1),'feed')#>'{cards,0,shared_interest_ids}','[]'::jsonb,
    'authorized interests expose an empty sorted intersection');
insert into private.user_interests values (feed_test.id(1),'feed-a'),(feed_test.id(1),'feed-z');

-- All ten owner links may be saved on one encounter, with no copied data.
insert into private.external_links (link_id,owner_id,source,url,title,visibility,display_order)
select feed_test.link_id(2,n),feed_test.id(2),'other','https://example.invalid/2/'||n,'Link'||n,'everyone_eligible',n
from pg_catalog.generate_series(3,10) as n;
update private.external_links set visibility='everyone_eligible' where owner_id=feed_test.id(2);
do $$
declare n integer;
begin
    for n in 1..10 loop
        perform feed_test.as_caller(feed_test.id(1),'save',feed_test.id(100),feed_test.link_id(2,n));
    end loop;
end;
$$;
select extensions.is((select pg_catalog.count(*) from private.saved_links where viewer_id=feed_test.id(1)
    and encounter_id=feed_test.id(100)),10::bigint,'one caller can retain all ten owner links');
select extensions.is(pg_catalog.jsonb_array_length(feed_test.as_caller(feed_test.id(1),'card',feed_test.id(100))->'saved_link_ids'),10,
    'detail saved ids include all ten current visible links');
select extensions.is(pg_catalog.jsonb_array_length(feed_test.as_caller(feed_test.id(1),'saved')->'links'),10,'saved list keeps all ten references');

-- Exact link-order tie uses UUID; own IDs must come from the same response.
update private.external_links set display_order=0 where link_id in (feed_test.link_id(2),feed_test.link_id(2,2));
select extensions.is(feed_test.as_caller(feed_test.id(1),'saved')#>>'{links,0,link,link_id}',feed_test.link_id(2)::text,'saved link-order ties use UUID');
update private.external_links set visibility='private' where link_id=feed_test.link_id(2,2);
select extensions.ok(not (feed_test.as_caller(feed_test.id(1),'card',feed_test.id(100))->'saved_link_ids' ? feed_test.link_id(2,2)::text),
    'detail does not disclose a retained private id');
select extensions.is((select pg_catalog.count(*) from private.saved_links where viewer_id=feed_test.id(1)),10::bigint,
    'hiding a link leaves its reference intact');
select extensions.is(pg_catalog.jsonb_array_length(feed_test.as_caller(feed_test.id(1),'saved')->'links'),9,
    'saved reads omit exactly the newly private link');

-- Encounter and live-account FK cascades are table behavior, no deletion API.
delete from private.encounters where encounter_id=feed_test.id(100);
select extensions.is((select pg_catalog.count(*) from private.saved_links where encounter_id=feed_test.id(100)),0::bigint,
    'encounter deletion cascades both viewer references');
select feed_test.reset_pair();
delete from auth.users where id=feed_test.id(2);
select extensions.is((select pg_catalog.count(*) from private.saved_links where encounter_id=feed_test.id(100)),0::bigint,
    'counterpart deletion cascades saved references');
select extensions.is(feed_test.as_caller(feed_test.id(1),'saved'),'{"links":[],"truncated":false}'::jsonb,
    'account deletion leaves no stale saved metadata');
select feed_test.error_call(2,'saved',null,null,true,'not_authenticated','','deleted caller is rejected after actual deletion');

-- Empty-list wire shapes, no new rate budget and no out-of-scope RPC.
select extensions.is(feed_test.as_caller(feed_test.id(1),'favorites'),'{"cards":[],"truncated":false}'::jsonb,
    'empty favorite list has exact wire shape');
select extensions.is(feed_test.as_caller(feed_test.id(1),'feed'),'{"cards":[],"truncated":false}'::jsonb,
    'empty feed has exact wire shape');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events where user_id=feed_test.id(1)),0::bigint,
    'new endpoints introduce no rate budget');

select * from extensions.finish();
rollback;
