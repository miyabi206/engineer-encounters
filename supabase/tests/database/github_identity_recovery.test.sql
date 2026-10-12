begin;
create extension if not exists pgtap with schema extensions;
create schema github_recovery_test;
grant usage on schema github_recovery_test to authenticated, service_role;
grant execute on all functions in schema extensions to authenticated, service_role;

create function github_recovery_test.id(n integer)
returns uuid language sql immutable set search_path = '' as $$
    select ('dddddddd-0000-0000-0000-' || pg_catalog.lpad(n::text, 12, '0'))::uuid;
$$;
create function github_recovery_test.call(role_name text, caller integer, statement text)
returns jsonb language plpgsql set search_path = '' as $$
declare result jsonb;
begin
    begin
        execute pg_catalog.format('set local role %I', role_name);
        perform pg_catalog.set_config('request.jwt.claim.sub', '', true);
        perform pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object(
            'sub', github_recovery_test.id(caller), 'role', role_name)::text, true);
        execute 'select ' || statement into result;
    exception when others then
        reset role;
        raise;
    end;
    reset role;
    return result;
end;
$$;
create function github_recovery_test.declare_account(caller integer)
returns void language plpgsql set search_path = '' as $$
begin
    begin
        set local role authenticated;
        perform pg_catalog.set_config('request.jwt.claim.sub', '', true);
        perform pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object(
            'sub', github_recovery_test.id(caller), 'role', 'authenticated')::text, true);
        perform public.accept_declarations(true, 'renewed', 'renewed');
    exception when others then
        reset role;
        raise;
    end;
    reset role;
end;
$$;
create function github_recovery_test.sync(caller integer, provider_id text)
returns jsonb language sql set search_path = '' as $$
    select github_recovery_test.call('service_role', caller, pg_catalog.format(
        'service.sync_github_identity(%L::uuid,%L,''owner'',''{}''::text[])',
        github_recovery_test.id(caller), provider_id));
$$;
create function github_recovery_test.save(caller integer, provider_id text)
returns jsonb language sql set search_path = '' as $$
    select github_recovery_test.call('service_role', caller, pg_catalog.format(
        'service.save_github_link(%L::uuid,''220'',%L,''https://github.com/owner/repo'',''Repo'','''',null,''{}''::text[],'''',''private'',false)',
        github_recovery_test.id(caller), provider_id));
$$;
create function github_recovery_test.identity(caller integer)
returns jsonb language sql set search_path = '' as $$
    select github_recovery_test.call('service_role', caller, pg_catalog.format(
        'service.get_github_identity(%L::uuid)', github_recovery_test.id(caller)));
$$;
create function github_recovery_test.connection(caller integer)
returns jsonb language sql set search_path = '' as $$
    select github_recovery_test.call('authenticated', caller, 'public.get_github_connection()');
$$;
create function github_recovery_test.expect_error(statement text, code text, description text)
returns text language plpgsql set search_path = pg_catalog, extensions as $$
declare actual_state text; actual_message text; actual_detail text;
begin
    begin execute statement;
    exception when others then
        get stacked diagnostics actual_state = returned_sqlstate,
            actual_message = message_text, actual_detail = pg_exception_detail;
        return extensions.is(pg_catalog.jsonb_build_array(actual_state, actual_message, coalesce(actual_detail, '')),
            pg_catalog.jsonb_build_array('P0001'::text, code, ''::text), description);
    end;
    return extensions.fail(description || ': expected exception');
end;
$$;
create function github_recovery_test.snapshot()
returns jsonb language sql stable set search_path = '' as $$
    select pg_catalog.jsonb_build_object(
        'cache', (select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(c) order by c.user_id) from private.linked_identities as c),
        'links', (select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(l) order by l.link_id) from private.external_links as l),
        'profiles', (select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(p) order by p.user_id) from private.profiles as p),
        'sessions', (select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(s) order by s.session_id) from private.sessions as s),
        'qr', (select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(q) order by q.issuer_id) from private.qr_codes as q),
        'saved', (select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(s) order by s.viewer_id, s.encounter_id, s.link_id) from private.saved_links as s));
$$;
create function github_recovery_test.auth_snapshot()
returns jsonb language sql stable set search_path = '' as $$
    select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(i) order by i.id) from auth.identities as i
    where i.user_id in (github_recovery_test.id(4), github_recovery_test.id(5));
$$;
-- Inject competing writes at the cache insertion boundary, after stale-owner
-- cleanup, to verify real constraint errors are normalized and roll it all back.
create function github_recovery_test.cache_race()
returns trigger language plpgsql set search_path = '' as $$
begin
    if tg_argv[0] = 'unique' then
        insert into private.linked_identities (user_id, provider, provider_user_id, handle)
        values (github_recovery_test.id(6), 'github', new.provider_user_id, 'competitor');
    else
        delete from auth.users as u where u.id = new.user_id;
    end if;
    return new;
end;
$$;
create table github_recovery_test.results (label text primary key, value jsonb not null);
grant execute on all functions in schema github_recovery_test to authenticated, service_role;

insert into auth.users (id) select github_recovery_test.id(n) from pg_catalog.generate_series(1, 8) as g(n);
insert into auth.identities (id, user_id, provider, provider_id, identity_data, created_at, updated_at)
select github_recovery_test.id(800 + n), github_recovery_test.id(owner), 'github', provider_id,
    pg_catalog.jsonb_build_object('sub', provider_id), pg_catalog.now() - age, pg_catalog.now()
from (values (1, 1, '101', interval '0 days'), (2, 2, '201', interval '1 day'),
    (3, 2, '202', interval '0 days'), (4, 4, '401', interval '1 day'),
    (5, 4, '402', interval '0 days'), (6, 5, '501', interval '0 days'),
    (7, 7, '701', interval '0 days'), (8, 8, '801', interval '0 days')) as f(n, owner, provider_id, age);
insert into private.profiles (user_id, age_18_declared, terms_version, privacy_version, discovery_on)
select github_recovery_test.id(n), true, 'draft', 'draft', n in (4, 8)
from (values (2), (4), (5), (6), (7), (8)) as f(n);
insert into private.notification_preferences (user_id, time_zone)
select github_recovery_test.id(n), 'UTC' from (values (2), (4), (5), (6), (7), (8)) as f(n);
insert into private.linked_identities (user_id, provider, provider_user_id, handle)
values (github_recovery_test.id(4), 'github', '401', 'old-owner'), (github_recovery_test.id(8), 'github', '801', 'old-owner');
insert into private.external_links (link_id, owner_id, source, source_item_id, url, title, visibility, verification_state)
values (github_recovery_test.id(404), github_recovery_test.id(4), 'github', '404', 'https://github.com/owner/old-4', 'Old', 'private', 'verified'),
    (github_recovery_test.id(808), github_recovery_test.id(8), 'github', '808', 'https://github.com/owner/old-8', 'Old', 'private', 'verified'),
    (github_recovery_test.id(809), github_recovery_test.id(8), 'other', null, 'https://example.invalid/', 'Other', 'private', 'unverified');
insert into private.encounters (encounter_id, user_a, user_b, kind, day_a, day_b)
values (github_recovery_test.id(904), github_recovery_test.id(4), github_recovery_test.id(6), 'qr', current_date, current_date),
    (github_recovery_test.id(908), github_recovery_test.id(6), github_recovery_test.id(8), 'qr', current_date, current_date);
insert into private.saved_links (viewer_id, encounter_id, link_id)
values (github_recovery_test.id(6), github_recovery_test.id(904), github_recovery_test.id(404)),
    (github_recovery_test.id(6), github_recovery_test.id(908), github_recovery_test.id(808)),
    (github_recovery_test.id(6), github_recovery_test.id(908), github_recovery_test.id(809));
-- These starts are later than transaction now, like a concurrent start that a
-- waiter sees only after its account lock becomes available.
insert into private.sessions (session_id, user_id, starts_at, expires_at)
select github_recovery_test.id(1000 + n), github_recovery_test.id(owner),
    pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp() + interval '2 hours'
from (values (1, 4), (2, 4), (3, 8)) as f(n, owner);
insert into private.qr_codes (code_digest, issuer_id, expires_at)
select pg_catalog.sha256(pg_catalog.decode(pg_catalog.repeat(case n when 4 then '44' else '88' end, 16), 'hex')),
    github_recovery_test.id(n), pg_catalog.floor(extract(epoch from pg_catalog.clock_timestamp()))::bigint + 120
from (values (4), (8)) as f(n);

-- 10 declarations + 18 deterministic identity + 13 empty-owner recovery +
-- 4 constraint-race rollback + 11 remaining-link recovery + 3 privileges = 59.
select extensions.plan(59);

select github_recovery_test.expect_error('select github_recovery_test.declare_account(1)', 'account_not_ready',
    'GitHub-only sign-in cannot accept declarations and exposes no detail');
select extensions.ok(not exists (select 1 from private.profiles where user_id = github_recovery_test.id(1)), 'GitHub-only account has no profile');
select extensions.ok(not exists (select 1 from private.matching_preferences where user_id = github_recovery_test.id(1)), 'refused declaration creates no matching preferences');
select extensions.ok(not exists (select 1 from private.field_visibility where owner_id = github_recovery_test.id(1)), 'refused declaration creates no field visibility');
select extensions.ok(not private.account_is_ready(github_recovery_test.id(1)), 'GitHub-only account remains unusable');
select github_recovery_test.expect_error('select github_recovery_test.save(1,''101'')', 'account_not_ready', 'GitHub-only account cannot save links');
select extensions.lives_ok('select github_recovery_test.declare_account(2)', 'existing profile with GitHub can renew declarations');
select extensions.is((select terms_version from private.profiles where user_id = github_recovery_test.id(2)), 'renewed', 'existing declarations are updated');
select extensions.lives_ok('select github_recovery_test.declare_account(3)', 'account without GitHub can create a profile');
select extensions.ok(exists (select 1 from private.profiles where user_id = github_recovery_test.id(3)), 'normal declaration creates its profile');

select extensions.is(github_recovery_test.identity(2)->>'provider_user_id', '201', 'two uncached identities choose the oldest');
select extensions.is(github_recovery_test.connection(2), '{"connected":false,"handle":null}'::jsonb, 'uncached identities are disconnected');
select github_recovery_test.expect_error('select github_recovery_test.sync(2,''202'')', 'not_found', 'sync refuses the unselected newer identity');
select github_recovery_test.expect_error('select github_recovery_test.save(2,''202'')', 'not_found', 'save refuses the unselected newer identity');
select extensions.is(github_recovery_test.sync(2, '201'), '{"connected":true,"handle":"owner"}'::jsonb, 'sync selects oldest identity without a scalar error');
select extensions.is(github_recovery_test.connection(2), '{"connected":true,"handle":"owner"}'::jsonb, 'oldest matching cache connects');
update private.linked_identities set provider_user_id = '202', handle = 'newer' where user_id = github_recovery_test.id(2);
select extensions.is(github_recovery_test.identity(2)->>'provider_user_id', '202', 'matching cache takes priority over oldest identity');
select extensions.is(github_recovery_test.connection(2), '{"connected":true,"handle":"newer"}'::jsonb, 'connection chooses the matching newer identity');
select github_recovery_test.expect_error('select github_recovery_test.sync(2,''201'')', 'not_found', 'sync refuses older identity when newer matches cache');
select extensions.is(github_recovery_test.sync(2, '202'), '{"connected":true,"handle":"owner"}'::jsonb, 'sync keeps the cache-matching identity');
select extensions.is(github_recovery_test.save(2, '202')->>'source_item_id', '220', 'save uses the same cache-matching identity');
select github_recovery_test.expect_error('select github_recovery_test.save(2,''201'')', 'not_found', 'save refuses a different live identity');
update auth.identities set created_at = pg_catalog.now() - interval '1 day' where user_id = github_recovery_test.id(2);
update private.linked_identities set provider_user_id = '999' where user_id = github_recovery_test.id(2);
select extensions.is(github_recovery_test.identity(2)->>'provider_user_id', '201', 'equal identity timestamps break ties by identity id');
select extensions.is(github_recovery_test.connection(2), '{"connected":false,"handle":null}'::jsonb, 'mismatched cache is disconnected with two identities');
select extensions.is(github_recovery_test.sync(2, '201'), '{"connected":true,"handle":"owner"}'::jsonb, 'sync replaces the mismatched cache deterministically');
delete from auth.identities where user_id = github_recovery_test.id(2) and provider_id = '201';
select extensions.is(github_recovery_test.identity(2)->>'provider_user_id', '202', 'removed matching identity falls back to remaining live identity');
select extensions.is(github_recovery_test.connection(2), '{"connected":false,"handle":null}'::jsonb, 'removed Auth identity invalidates the cache');
select extensions.is(github_recovery_test.sync(2, '202'), '{"connected":true,"handle":"owner"}'::jsonb, 'remaining identity can reestablish the cache');

insert into github_recovery_test.results values ('live-4', github_recovery_test.snapshot());
select github_recovery_test.expect_error('select github_recovery_test.sync(5,''401'')', 'not_found', 'cache held by another live Auth identity is unavailable');
select extensions.is(github_recovery_test.snapshot(), (select value from github_recovery_test.results where label = 'live-4'), 'live-owner refusal preserves every resource');
delete from auth.identities where user_id = github_recovery_test.id(4) and provider_id = '401';
update auth.identities set provider_id = '401', identity_data = '{"sub":"401"}' where user_id = github_recovery_test.id(5);
insert into github_recovery_test.results values ('auth-before-recovery', github_recovery_test.auth_snapshot());
insert into github_recovery_test.results values ('before-race', github_recovery_test.snapshot());
create trigger cache_unique_race before insert on private.linked_identities
for each row when (new.user_id = github_recovery_test.id(5)) execute function github_recovery_test.cache_race('unique');
select github_recovery_test.expect_error('select github_recovery_test.sync(5,''401'')', 'not_found', 'cache unique race exposes only not_found without details');
select extensions.is(github_recovery_test.snapshot(), (select value from github_recovery_test.results where label = 'before-race'), 'unique race rolls back cache, links, saved references and discovery changes');
drop trigger cache_unique_race on private.linked_identities;
create trigger cache_fk_race before insert on private.linked_identities
for each row when (new.user_id = github_recovery_test.id(5)) execute function github_recovery_test.cache_race('foreign_key');
select github_recovery_test.expect_error('select github_recovery_test.sync(5,''401'')', 'not_found', 'cache foreign-key race exposes only not_found without details');
select extensions.is(github_recovery_test.snapshot(), (select value from github_recovery_test.results where label = 'before-race'), 'foreign-key race rolls back every stale-owner cleanup effect');
drop trigger cache_fk_race on private.linked_identities;
select extensions.is(github_recovery_test.sync(5, '401'), '{"connected":true,"handle":"owner"}'::jsonb, 'stale cache transfers from a lower account id without a unique error');
select extensions.is((select pg_catalog.count(*) from private.linked_identities where user_id = github_recovery_test.id(4)), 0::bigint, 'stale owner cache is removed');
select extensions.is((select pg_catalog.count(*) from private.external_links where owner_id = github_recovery_test.id(4)), 0::bigint, 'stale owner repository links are removed');
select extensions.is((select pg_catalog.count(*) from private.saved_links where link_id = github_recovery_test.id(404)), 0::bigint, 'stale owner repository saved references cascade');
select extensions.is((select discovery_on from private.profiles where user_id = github_recovery_test.id(4)), false, 'losing the last link turns discovery off');
select extensions.is((select pg_catalog.count(*) from private.sessions where user_id = github_recovery_test.id(4) and stopped_at >= starts_at), 2::bigint, 'recovery stops both sessions begun after transaction now');
select extensions.is((select pg_catalog.count(*) from private.qr_codes where issuer_id = github_recovery_test.id(4)), 0::bigint, 'recovery cancels outstanding QR just like discovery off');
select extensions.is((select pg_catalog.count(*) from auth.identities where user_id = github_recovery_test.id(4) and provider_id = '402'), 1::bigint, 'recovery leaves a different Auth identity intact');
select extensions.is((select provider_user_id from private.linked_identities where user_id = github_recovery_test.id(5)), '401', 'new owner receives the cache');
select extensions.is(github_recovery_test.sync(5, '401'), '{"connected":true,"handle":"owner"}'::jsonb, 'recovered cache sync is idempotent');
select extensions.is(github_recovery_test.auth_snapshot(), (select value from github_recovery_test.results where label = 'auth-before-recovery'), 'recovery never changes Auth identities');

insert into github_recovery_test.results values ('live-8', github_recovery_test.snapshot());
select github_recovery_test.expect_error('select github_recovery_test.sync(7,''801'')', 'not_found', 'another live owner with a remaining link is unavailable');
select extensions.is(github_recovery_test.snapshot(), (select value from github_recovery_test.results where label = 'live-8'), 'remaining-link live-owner refusal is atomic');
delete from auth.identities where user_id = github_recovery_test.id(8);
update auth.identities set provider_id = '801', identity_data = '{"sub":"801"}' where user_id = github_recovery_test.id(7);
select extensions.is(github_recovery_test.sync(7, '801'), '{"connected":true,"handle":"owner"}'::jsonb, 'stale cache transfers from a higher account id');
select extensions.is((select pg_catalog.count(*) from private.linked_identities where user_id = github_recovery_test.id(8)), 0::bigint, 'higher stale owner cache is removed');
select extensions.is((select pg_catalog.array_agg(source order by source) from private.external_links where owner_id = github_recovery_test.id(8)), array['other'], 'recovery preserves later-source links');
select extensions.is((select pg_catalog.count(*) from private.saved_links where link_id = github_recovery_test.id(808)), 0::bigint, 'recovery cascades the removed repository reference');
select extensions.is((select discovery_on from private.profiles where user_id = github_recovery_test.id(8)), true, 'remaining link keeps discovery on');
select extensions.ok((select stopped_at is null from private.sessions where user_id = github_recovery_test.id(8)), 'remaining link keeps the session running');
select extensions.is((select pg_catalog.count(*) from private.qr_codes where issuer_id = github_recovery_test.id(8)), 1::bigint, 'remaining link preserves outstanding QR');
select extensions.is((select provider_user_id from private.linked_identities where user_id = github_recovery_test.id(7)), '801', 'higher-owner recovery completes sync');
select extensions.is((select pg_catalog.count(*) from private.saved_links where link_id = github_recovery_test.id(809)), 1::bigint, 'later-source saved reference is preserved');

select extensions.ok(not pg_catalog.has_function_privilege(r.name, 'private.turn_discovery_off(uuid)', 'execute'),
    r.name || ' cannot call the shared discovery-off helper') from (values ('anon'), ('authenticated'), ('service_role')) as r(name);

select * from extensions.finish();
rollback;
