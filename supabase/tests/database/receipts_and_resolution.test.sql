begin;

create extension if not exists pgtap with schema extensions;
create schema receipts_test;
grant usage on schema receipts_test to anon, authenticated, service_role;

create table receipts_test.clock (start_seconds bigint not null, current_seconds bigint not null);
insert into receipts_test.clock select
    extract(epoch from ((pg_catalog.now() at time zone 'UTC')::date::timestamp at time zone 'UTC'))::bigint - 60,
    pg_catalog.floor(extract(epoch from pg_catalog.now()))::bigint;
create table receipts_test.results (label text primary key, statuses text[] not null, safe_shape boolean not null);
create table receipts_test.tables (name text primary key);
insert into receipts_test.tables values ('sessions'), ('encounter_candidates'), ('consumed_nonces'), ('encounters'), ('encounter_views');
grant select on all tables in schema receipts_test to anon, authenticated, service_role;
grant insert on receipts_test.results to authenticated;

create function receipts_test.user_id(n integer) returns uuid language sql immutable set search_path = '' as $$
    select ('cccccccc-0000-0000-0000-' || pg_catalog.lpad(n::text, 12, '0'))::uuid;
$$;
create function receipts_test.hex(n integer) returns text language sql immutable set search_path = '' as $$
    select pg_catalog.lpad(pg_catalog.to_hex(n), 32, '0');
$$;
create function receipts_test.digest(n integer) returns bytea language sql immutable set search_path = '' as $$
    select pg_catalog.sha256(pg_catalog.decode(receipts_test.hex(n), 'hex'));
$$;
create function receipts_test.token(n integer, observed bigint, variant integer default 0)
returns text language sql immutable set search_path = '' as $$
    select pg_catalog.md5('receipt-fixture:' || n || ':' || (pg_catalog.floor(observed::numeric / 900) * 900)::bigint || ':' || variant);
$$;
create function receipts_test.exchange_digest(n integer, side integer default 1,
    peer_number integer default 2, observed bigint default null)
returns bytea language sql stable security definer set search_path = '' as $$
    select private.receipt_exchange_digest(receipts_test.digest(n),
        pg_catalog.sha256(pg_catalog.decode(receipts_test.token(side, coalesce(observed,
            (select c.start_seconds from receipts_test.clock as c))), 'hex')),
        pg_catalog.sha256(pg_catalog.decode(receipts_test.token(peer_number, coalesce(observed,
            (select c.start_seconds from receipts_test.clock as c))), 'hex')));
$$;
create function receipts_test.receipt(n integer, side integer, observed bigint default null,
    duration bigint default 0, checkpoint bigint default null, prior integer default null,
    session boolean default false, final boolean default false, peer integer default null, variant integer default 0)
returns jsonb language plpgsql set search_path = '' as $$
declare
    at_seconds bigint := coalesce(observed, (select c.start_seconds from receipts_test.clock as c));
    other integer := coalesce(peer, case when side = 1 then 2 else 1 end);
    result jsonb;
begin
    result := pg_catalog.jsonb_build_object(
        'id', receipts_test.user_id(n * 10 + side), 'protocol_version', 1,
        'role', case when side = 1 then 'central' else 'peripheral' end,
        'exchange_nonce', receipts_test.hex(n),
        'start', pg_catalog.jsonb_build_object('own_token', receipts_test.token(side, at_seconds, variant),
            'peer_token', receipts_test.token(other, at_seconds), 'observed_at', at_seconds),
        'observed_duration', duration, 'session_flag', session, 'is_final_evidence', final);
    if prior is not null then result := result || pg_catalog.jsonb_build_object('prior_exchange_nonce', receipts_test.hex(prior)); end if;
    if checkpoint is not null then result := result || pg_catalog.jsonb_build_object('checkpoint',
        pg_catalog.jsonb_build_object('own_token', receipts_test.token(side, checkpoint, variant),
            'peer_token', receipts_test.token(other, checkpoint), 'observed_at', checkpoint)); end if;
    return result;
end;
$$;

-- Synthetic fixtures only. No generated token or upload payload reaches TAP diagnostics.
create function receipts_test.seed_token(side integer, observed bigint, variant integer default 0)
returns void language sql set search_path = '' as $$
    insert into private.temporary_tokens (token_digest, user_id, batch_id, valid_from, valid_until, delete_after)
    select pg_catalog.sha256(pg_catalog.decode(receipts_test.token(side, observed, variant), 'hex')),
        receipts_test.user_id(side), receipts_test.user_id(side), w, w + 900, w + 173700
    from (select (pg_catalog.floor(observed::numeric / 900) * 900)::bigint as w) as window_bounds
    on conflict (token_digest) do nothing;
$$;
create function receipts_test.reset_evidence() returns void language plpgsql set search_path = '' as $$
begin
    delete from private.encounter_candidates;
    delete from private.consumed_nonces;
    delete from private.encounters;
    delete from private.sessions;
    delete from private.blocks;
    delete from private.account_limit_events where user_id in (select receipts_test.user_id(n) from pg_catalog.generate_series(1, 8) as n);
end;
$$;
create function receipts_test.expect(test_label text, payload jsonb, expected text[])
returns text language plpgsql set search_path = pg_catalog, extensions as $$
declare
    result jsonb := public.submit_receipts(payload);
    actual_statuses text[];
    safe boolean;
begin
    select pg_catalog.array_agg(j.value->>'status' order by j.ordinal) into actual_statuses
    from pg_catalog.jsonb_array_elements(result) with ordinality as j(value, ordinal);
    safe := pg_catalog.jsonb_typeof(result) = 'array'
        and pg_catalog.jsonb_array_length(result) = pg_catalog.jsonb_array_length(payload)
        and not exists (
            select 1 from pg_catalog.jsonb_array_elements(result) with ordinality as j(value, ordinal)
            join pg_catalog.jsonb_array_elements(payload) with ordinality as p(value, ordinal) using (ordinal)
            where (select pg_catalog.array_agg(k order by k) from pg_catalog.jsonb_object_keys(j.value) as k) <> array['id', 'status']
                or j.value->>'id' <> p.value->>'id'
                or j.value->>'status' not in ('candidate', 'resolved', 'consumed', 'rejected', 'expired')
        );
    insert into receipts_test.results values (test_label, actual_statuses, safe);
    return extensions.is(actual_statuses, expected, test_label);
end;
$$;
create function receipts_test.expect_error(statement text, code text, fields text, description text)
returns text language plpgsql set search_path = pg_catalog, extensions as $$
declare actual_state text; actual_message text; actual_detail text;
begin
    begin execute statement;
    exception when others then
        get stacked diagnostics actual_state = returned_sqlstate, actual_message = message_text, actual_detail = pg_exception_detail;
        return extensions.is(pg_catalog.jsonb_build_array(actual_state, actual_message, coalesce(actual_detail, '')),
            pg_catalog.jsonb_build_array('P0001'::text, code, fields), description);
    end;
    return extensions.fail(description || ': expected exception');
end;
$$;

-- Twelve assertions per real upload flow, with and without token rotation and
-- server-backed sessions. No manually manufactured prior tombstone is used.
create function receipts_test.consumed_original_flow(test_label text, rotates boolean, in_session boolean)
returns setof text language plpgsql set search_path = pg_catalog, extensions as $$
declare
    original_seconds bigint := (select c.start_seconds from receipts_test.clock as c)
        - case when rotates then 0 else 120 end;
    joined_seconds bigint := original_seconds + 120;
begin
    perform receipts_test.reset_evidence();
    perform pg_catalog.set_config('request.jwt.claims',
        pg_catalog.jsonb_build_object('sub', receipts_test.user_id(1), 'role', 'authenticated')::text, true);
    return next receipts_test.expect(test_label || ' original central',
        pg_catalog.jsonb_build_array(receipts_test.receipt(603, 1, original_seconds, 120, joined_seconds)), array['candidate']);
    perform pg_catalog.set_config('request.jwt.claims',
        pg_catalog.jsonb_build_object('sub', receipts_test.user_id(2), 'role', 'authenticated')::text, true);
    return next receipts_test.expect(test_label || ' original resolves',
        pg_catalog.jsonb_build_array(receipts_test.receipt(603, 2, original_seconds, 120, joined_seconds)), array['resolved']);
    return next extensions.is((select pg_catalog.count(*) from private.encounter_candidates), 0::bigint,
        test_label || ' originals removed');
    return next extensions.ok(exists (select 1 from private.consumed_nonces as n
        where n.exchange_digest = receipts_test.exchange_digest(603, 1, 2, original_seconds)),
        test_label || ' original exchange tombstone exists');
    return next receipts_test.expect(test_label || ' original replay',
        pg_catalog.jsonb_build_array(receipts_test.receipt(603, 2, original_seconds, 120, joined_seconds)), array['consumed']);
    return next extensions.is(receipts_test.token(1, original_seconds) <> receipts_test.token(1, joined_seconds),
        rotates, test_label || ' uses the intended token windows');
    if in_session then
        insert into private.sessions (user_id, starts_at, expires_at)
        select receipts_test.user_id(side), pg_catalog.to_timestamp(joined_seconds::double precision) - interval '1 minute',
            pg_catalog.to_timestamp(joined_seconds::double precision) + interval '1 minute'
        from pg_catalog.generate_series(1, 2) as sides(side);
    end if;
    perform pg_catalog.set_config('request.jwt.claims',
        pg_catalog.jsonb_build_object('sub', receipts_test.user_id(1), 'role', 'authenticated')::text, true);
    return next receipts_test.expect(test_label || ' joined central',
        pg_catalog.jsonb_build_array(receipts_test.receipt(604, 1, joined_seconds, 120, null, 603, in_session)), array['candidate']);
    perform pg_catalog.set_config('request.jwt.claims',
        pg_catalog.jsonb_build_object('sub', receipts_test.user_id(2), 'role', 'authenticated')::text, true);
    return next receipts_test.expect(test_label || ' joined peripheral',
        pg_catalog.jsonb_build_array(receipts_test.receipt(604, 2, joined_seconds, 120, null, 603, in_session)),
        array[case when in_session then 'resolved' else 'candidate' end]);
    return next extensions.is((select pg_catalog.count(*) from private.encounters as e where e.kind = 'ambient'),
        1::bigint, test_label || ' missing originals cannot produce another ambient encounter');
    return next extensions.is((select pg_catalog.count(*) from private.encounters as e where e.kind = 'session'),
        case when in_session then 1::bigint else 0::bigint end, test_label || ' server sessions qualify independently');
    return next extensions.is((select pg_catalog.count(*) from private.encounter_candidates),
        case when in_session then 0::bigint else 2::bigint end, test_label || ' joined storage follows qualification');
    return next receipts_test.expect(test_label || ' joined retry',
        pg_catalog.jsonb_build_array(receipts_test.receipt(604, 2, joined_seconds, 120, null, 603, in_session)),
        array[case when in_session then 'consumed' else 'candidate' end]);
end;
$$;

insert into auth.users (id, aud, role, email)
select receipts_test.user_id(n), 'authenticated', 'authenticated', 'receipt-fixture-' || n || '@example.invalid'
from pg_catalog.generate_series(1, 8) as n;
insert into private.profiles (user_id, age_18_declared, terms_version, privacy_version)
select receipts_test.user_id(n), true, 'draft', 'draft' from pg_catalog.generate_series(1, 6) as n;
insert into private.notification_preferences (user_id, time_zone)
select receipts_test.user_id(n), case when n = 1 then 'Asia/Tokyo' when n = 2 then 'America/Los_Angeles' else 'UTC' end
from pg_catalog.generate_series(1, 6) as n;
select receipts_test.seed_token(n, t, v)
from receipts_test.clock as c cross join pg_catalog.generate_series(1, 6) as n
cross join pg_catalog.generate_series(0, 1) as v
cross join lateral (values (c.start_seconds), (c.start_seconds + 120), (c.start_seconds - 120),
    (c.current_seconds), (c.current_seconds + 300), (c.current_seconds + 301),
    (c.current_seconds - 172800), (c.current_seconds - 172799)) as times(t);

-- Test helpers use explicit grants under the hardened function defaults.
grant execute on all functions in schema receipts_test to anon, authenticated, service_role;
grant execute on all functions in schema extensions to anon, authenticated, service_role;

select extensions.plan(472);
-- Catalog, default denial, date-only confirmed storage and RPC privileges.
select extensions.ok(pg_catalog.to_regclass('private.' || name) is not null, name || ' exists') from receipts_test.tables;
select extensions.ok(c.relrowsecurity, t.name || ' enables RLS') from receipts_test.tables as t join pg_catalog.pg_class as c on c.oid = ('private.' || t.name)::regclass;
select extensions.is((select pg_catalog.count(*) from pg_catalog.pg_policy as p where p.polrelid = ('private.' || t.name)::regclass), 0::bigint, t.name || ' has no policies') from receipts_test.tables as t;
select extensions.ok(not pg_catalog.has_table_privilege(r.name, 'private.' || t.name, 'select, insert, update, delete, truncate, references, trigger, maintain'), r.name || ' has no table privileges on ' || t.name) from receipts_test.tables as t cross join (values ('anon'), ('authenticated')) as r(name);
select extensions.ok(not exists (select 1 from pg_catalog.aclexplode(coalesce(c.relacl, pg_catalog.acldefault('r', c.relowner))) as a where a.grantee = 0), t.name || ' has no public grants') from receipts_test.tables as t join pg_catalog.pg_class as c on c.oid = ('private.' || t.name)::regclass;
select extensions.ok(not pg_catalog.has_schema_privilege(r.name, 'private', 'usage, create'), r.name || ' cannot access private') from (values ('anon'), ('authenticated')) as r(name);
select extensions.ok(not pg_catalog.has_function_privilege('anon', 'public.submit_receipts(jsonb)', 'execute'), 'anon cannot execute submit_receipts');
select extensions.ok(not pg_catalog.has_function_privilege('service_role', 'public.submit_receipts(jsonb)', 'execute'), 'service_role cannot execute submit_receipts');
select extensions.ok(pg_catalog.has_function_privilege('authenticated', 'public.submit_receipts(jsonb)', 'execute'), 'authenticated can execute submit_receipts');
select extensions.ok(not exists (select 1 from pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) as a where a.grantee = 0 and a.privilege_type = 'EXECUTE'), 'public cannot execute submit_receipts') from pg_catalog.pg_proc as p where p.oid = 'public.submit_receipts(jsonb)'::regprocedure;
select extensions.ok(p.prosecdef and 'search_path=""' = any(p.proconfig), 'RPC is security definer with empty search path') from pg_catalog.pg_proc as p where p.oid = 'public.submit_receipts(jsonb)'::regprocedure;
select extensions.is(p.proargnames, array['receipts'], 'RPC accepts receipts and no client account') from pg_catalog.pg_proc as p where p.oid = 'public.submit_receipts(jsonb)'::regprocedure;
select extensions.is(pg_catalog.format_type(p.prorettype, null), 'jsonb', 'RPC returns jsonb') from pg_catalog.pg_proc as p where p.oid = 'public.submit_receipts(jsonb)'::regprocedure;
select extensions.is((select pg_catalog.array_agg(a.attname::text order by a.attnum) from pg_catalog.pg_attribute as a where a.attrelid = 'private.sessions'::regclass and a.attnum > 0 and not a.attisdropped), array['session_id', 'user_id', 'starts_at', 'expires_at', 'stopped_at'], 'sessions has only allocated columns');
select extensions.is((select pg_catalog.array_agg(a.attname::text order by a.attnum) from pg_catalog.pg_attribute as a where a.attrelid = 'private.consumed_nonces'::regclass and a.attnum > 0 and not a.attisdropped), array['exchange_digest', 'delete_after'], 'consumed_nonces has only allocated columns');
select extensions.is((select pg_catalog.array_agg(a.attname::text order by a.attnum) from pg_catalog.pg_attribute as a where a.attrelid = 'private.encounters'::regclass and a.attnum > 0 and not a.attisdropped), array['encounter_id', 'user_a', 'user_b', 'kind', 'day_a', 'day_b'], 'encounters has only allocated columns');
select extensions.is((select pg_catalog.array_agg(a.attname::text order by a.attnum) from pg_catalog.pg_attribute as a where a.attrelid = 'private.encounter_views'::regclass and a.attnum > 0 and not a.attisdropped), array['encounter_id', 'viewer_id', 'revealed', 'reveal_report_day', 'favorite', 'revealed_report_day'], 'encounter_views has only allocated columns');
select extensions.ok(not exists (select 1 from pg_catalog.pg_attribute as a where a.attrelid = ('private.' || t.name)::regclass and a.attnum > 0 and not a.attisdropped and a.atttypid in ('timestamp'::regtype, 'timestamptz'::regtype, 'time'::regtype, 'timetz'::regtype)), t.name || ' has no precise encounter time') from (values ('encounters'), ('encounter_views'), ('consumed_nonces')) as t(name);
select extensions.is((select a.atttypid::regtype::text from pg_catalog.pg_attribute as a where a.attrelid = 'private.consumed_nonces'::regclass and a.attname = 'delete_after'), 'date', 'nonce deletion is day granular');
set local "request.jwt.claim.sub" = '';
set local "request.jwt.claims" = '{}';
set local role anon;
select extensions.throws_ok('select public.submit_receipts(''[]''::jsonb)', '42501', 'permission denied for function submit_receipts', 'anon RPC execution is denied');
select extensions.throws_ok('select * from private.encounters', '42501', 'permission denied for schema private', 'anon table access is denied');
reset role;
set local role service_role;
select extensions.throws_ok('select public.submit_receipts(''[]''::jsonb)', '42501', 'permission denied for function submit_receipts', 'service role RPC execution is denied');
reset role;
set local role authenticated;
select receipts_test.expect_error('select public.submit_receipts(''[]''::jsonb)', 'not_authenticated', '', 'missing caller is refused');
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000007","role":"authenticated"}';
select receipts_test.expect_error('select public.submit_receipts(''[]''::jsonb)', 'account_not_ready', '', 'undeclared account is refused');
reset role;
delete from auth.users where id = receipts_test.user_id(8);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000008","role":"authenticated"}';
select receipts_test.expect_error('select public.submit_receipts(''[]''::jsonb)', 'not_authenticated', '', 'deleted caller is refused');
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select extensions.throws_ok('select * from private.encounter_candidates', '42501', 'permission denied for schema private', 'authenticated cannot read candidates');
select extensions.throws_ok('insert into private.consumed_nonces default values', '42501', 'permission denied for schema private', 'authenticated cannot write nonce tombstones');
select receipts_test.expect_error('select public.submit_receipts(null)', 'invalid_input', 'receipts', 'SQL null is invalid input');
select receipts_test.expect_error('select public.submit_receipts(''null''::jsonb)', 'invalid_input', 'receipts', 'JSON null is invalid input');
select receipts_test.expect_error('select public.submit_receipts(''{}''::jsonb)', 'invalid_input', 'receipts', 'object is invalid input');
select receipts_test.expect_error('select public.submit_receipts(''[]''::jsonb)', 'invalid_input', 'receipts', 'empty array is invalid input');
select receipts_test.expect_error('select public.submit_receipts(''[1]''::jsonb)', 'invalid_input', 'receipts', 'nonobject member is invalid input');
select receipts_test.expect_error('select public.submit_receipts(''[{}]''::jsonb)', 'invalid_input', 'receipts', 'missing identity is invalid input');
select receipts_test.expect_error('select public.submit_receipts(''[{"id":"bad"}]''::jsonb)', 'invalid_input', 'receipts', 'invalid identity is invalid input');
select receipts_test.expect_error('select public.submit_receipts((select pg_catalog.jsonb_agg(receipts_test.receipt(10, 1, null, 0, null, null, false, false, null, 0)) from pg_catalog.generate_series(1,51)))', 'invalid_input', 'receipts', '51 receipt array is invalid input');
reset role;
update private.profiles set moderation_state = 'hidden' where user_id = receipts_test.user_id(1);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect_error('select public.submit_receipts(pg_catalog.jsonb_build_array(receipts_test.receipt(10, 1, null, 0, null, null, false, false, null, 0)))', 'account_not_ready', '', 'hidden caller cannot upload');
reset role;
update private.profiles set moderation_state = 'suspended' where user_id = receipts_test.user_id(1);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect_error('select public.submit_receipts(pg_catalog.jsonb_build_array(receipts_test.receipt(10, 1, null, 0, null, null, false, false, null, 0)))', 'account_not_ready', '', 'suspended caller cannot upload');
reset role;
update private.profiles set moderation_state = 'active' where user_id = receipts_test.user_id(1);
-- The first successful call must hold exactly account, both named nonces, and
-- pair locks. Earlier errors roll their locks back with their subtransactions.
set local role authenticated;
select receipts_test.expect('one call locks its own and prior exchange',
    pg_catalog.jsonb_build_array(receipts_test.receipt(9, 1, null, 0, null, 8)), array['candidate']);
reset role;
select extensions.ok(exists (select 1 from pg_catalog.pg_locks as l
    where l.pid = pg_catalog.pg_backend_pid() and l.locktype = 'advisory' and l.granted
      and l.mode = 'ExclusiveLock' and l.objsubid = 2 and l.classid = 31001::oid
      and l.objid = (pg_catalog.hashtext(receipts_test.user_id(1)::text)::bigint & 4294967295::bigint)::oid),
    'submit holds the account lock');
select extensions.is((select pg_catalog.count(*) from pg_catalog.pg_locks as l
    join (select pg_catalog.hashtextextended(pg_catalog.encode(receipts_test.digest(n), 'hex'), 0) as key
        from (values (8), (9)) as nonces(n)) as keys
      on l.classid = ((keys.key >> 32) & 4294967295::bigint)::oid
     and l.objid = (keys.key & 4294967295::bigint)::oid
    where l.pid = pg_catalog.pg_backend_pid() and l.locktype = 'advisory'
      and l.granted and l.mode = 'ExclusiveLock' and l.objsubid = 1),
    2::bigint, 'submit holds own and prior nonce locks in the bigint key space');
select extensions.ok(exists (select 1 from pg_catalog.pg_locks as l
    where l.pid = pg_catalog.pg_backend_pid() and l.locktype = 'advisory' and l.granted
      and l.mode = 'ExclusiveLock' and l.objsubid = 2 and l.classid = 31003::oid
      and l.objid = (pg_catalog.hashtext(receipts_test.user_id(1)::text || ':'
          || receipts_test.user_id(2)::text)::bigint & 4294967295::bigint)::oid),
    'submit holds the pair lock in its separate namespace');
select extensions.is((select pg_catalog.count(*) from pg_catalog.pg_locks as l
    where l.pid = pg_catalog.pg_backend_pid() and l.locktype = 'advisory' and l.granted),
    4::bigint, 'one submit takes exactly the account, two nonce and pair locks');
select receipts_test.reset_evidence();
-- Shape, ownership, window and freshness order. All diagnostics contain statuses only.
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('invalid shapes are rejected', pg_catalog.jsonb_build_array(pg_catalog.jsonb_set(receipts_test.receipt(20, 1, null, 0, null, null, false, false, null, 0), '{protocol_version}', '2'::jsonb),
    pg_catalog.jsonb_set(receipts_test.receipt(21, 1, null, 0, null, null, false, false, null, 0), '{role}', '"other"'::jsonb),
    pg_catalog.jsonb_set(receipts_test.receipt(22, 1, null, 0, null, null, false, false, null, 0), '{exchange_nonce}', '"ABCDEFABCDEFABCDEFABCDEFABCDEFABCD"'::jsonb),
    pg_catalog.jsonb_set(receipts_test.receipt(23, 1, null, 0, null, null, false, false, null, 0), '{start,own_token}', '"00"'::jsonb),
    pg_catalog.jsonb_set(receipts_test.receipt(24, 1, null, 0, null, null, false, false, null, 0), '{start}', '{}'::jsonb),
    pg_catalog.jsonb_set(receipts_test.receipt(25, 1, null, 0, null, null, false, false, null, 0), '{checkpoint}', '{"own_token":"00"}'::jsonb),
    pg_catalog.jsonb_set(receipts_test.receipt(26, 1, null, 0, null, null, false, false, null, 0), '{observed_duration}', '-1'::jsonb),
    pg_catalog.jsonb_set(receipts_test.receipt(27, 1, null, 0, null, null, false, false, null, 0), '{observed_duration}', '1.5'::jsonb),
    pg_catalog.jsonb_set(receipts_test.receipt(28, 1, null, 0, null, null, false, false, null, 0), '{observed_duration}', '9007199254740992'::jsonb),
    pg_catalog.jsonb_set(receipts_test.receipt(29, 1, null, 0, null, null, false, false, null, 0), '{session_flag}', '"true"'::jsonb),
    pg_catalog.jsonb_set(receipts_test.receipt(30, 1, null, 0, null, null, false, false, null, 0), '{is_final_evidence}', 'null'::jsonb),
    pg_catalog.jsonb_set(receipts_test.receipt(31, 1, null, 0, null, null, false, false, null, 0), '{start,observed_at}', '"1"'::jsonb),
    pg_catalog.jsonb_set(receipts_test.receipt(32, 1, null, 0, null, null, false, false, null, 0), '{start,observed_at}', '1.5'::jsonb),
    pg_catalog.jsonb_set(receipts_test.receipt(33, 1, null, 0, null, null, false, false, null, 0), '{start,observed_at}', '9007199254740992'::jsonb),
    receipts_test.receipt(40, 1, null, 0, null, null, false, false, null, 0) - 'session_flag',
    receipts_test.receipt(41, 1, null, 0, null, null, false, false, null, 0) || '{"unexpected":true}'::jsonb,
    receipts_test.receipt(42, 1, null, 0, null, null, false, false, null, 0) || pg_catalog.jsonb_build_object('prior_exchange_nonce',receipts_test.hex(42))), array['rejected', 'rejected', 'rejected', 'rejected', 'rejected', 'rejected', 'rejected', 'rejected', 'rejected', 'rejected', 'rejected', 'rejected', 'rejected', 'rejected', 'rejected', 'rejected', 'rejected']);
select receipts_test.expect('swapped own and peer tokens', pg_catalog.jsonb_build_array(receipts_test.receipt(50, 2, null, 0, null, null, false, false, null, 0)), array['rejected']);
select receipts_test.expect('foreign own token', pg_catalog.jsonb_build_array(pg_catalog.jsonb_set(receipts_test.receipt(51, 1, null, 0, null, null, false, false, null, 0), '{start,own_token}', pg_catalog.to_jsonb(receipts_test.token(3, (select start_seconds from receipts_test.clock))))), array['rejected']);
select receipts_test.expect('unknown peer token', pg_catalog.jsonb_build_array(pg_catalog.jsonb_set(receipts_test.receipt(52, 1, null, 0, null, null, false, false, null, 0), '{start,peer_token}', pg_catalog.to_jsonb(receipts_test.hex(999999)))), array['rejected']);
select receipts_test.expect('self pair', pg_catalog.jsonb_build_array(receipts_test.receipt(53, 1, null, 0, null, null, false, false, 1, 0)), array['rejected']);
select receipts_test.expect('checkpoint foreign own token', pg_catalog.jsonb_build_array(pg_catalog.jsonb_set(receipts_test.receipt(54, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0), '{checkpoint,own_token}', pg_catalog.to_jsonb(receipts_test.token(3, (select start_seconds from receipts_test.clock) + 120)))), array['rejected']);
select receipts_test.expect('checkpoint changes peer owner without a status oracle', pg_catalog.jsonb_build_array(pg_catalog.jsonb_set(receipts_test.receipt(55, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0), '{checkpoint,peer_token}', pg_catalog.to_jsonb(receipts_test.token(3, (select start_seconds from receipts_test.clock) + 120)))), array['candidate']);
select receipts_test.expect('same receipt with same-owner checkpoint also stays candidate', pg_catalog.jsonb_build_array(
    receipts_test.receipt(55, 1, null, 120, (select start_seconds from receipts_test.clock)+120)), array['candidate']);
select receipts_test.expect('different-owner checkpoint still needs a valid token window', pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_set(receipts_test.receipt(56, 1, null, 120, (select start_seconds from receipts_test.clock)+120),
        '{checkpoint,peer_token}', pg_catalog.to_jsonb(receipts_test.token(3, (select start_seconds from receipts_test.clock))))),
    array['rejected']);

select receipts_test.expect('start before token window', pg_catalog.jsonb_build_array(pg_catalog.jsonb_set(receipts_test.receipt(60, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0), '{start,observed_at}', pg_catalog.to_jsonb((pg_catalog.floor(((select start_seconds from receipts_test.clock))::numeric / 900) * 900)::bigint - 1))), array['rejected']);
select receipts_test.expect('start at exclusive token end', pg_catalog.jsonb_build_array(pg_catalog.jsonb_set(receipts_test.receipt(60, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0), '{start,observed_at}', pg_catalog.to_jsonb((pg_catalog.floor(((select start_seconds from receipts_test.clock))::numeric / 900) * 900)::bigint + 900))), array['rejected']);
select receipts_test.expect('checkpoint before token window', pg_catalog.jsonb_build_array(pg_catalog.jsonb_set(receipts_test.receipt(61, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0), '{checkpoint,observed_at}', pg_catalog.to_jsonb((pg_catalog.floor(((select start_seconds from receipts_test.clock) + 120)::numeric / 900) * 900)::bigint - 1))), array['rejected']);
select receipts_test.expect('checkpoint at exclusive token end', pg_catalog.jsonb_build_array(pg_catalog.jsonb_set(receipts_test.receipt(61, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0), '{checkpoint,observed_at}', pg_catalog.to_jsonb((pg_catalog.floor(((select start_seconds from receipts_test.clock) + 120)::numeric / 900) * 900)::bigint + 900))), array['rejected']);
select receipts_test.expect('start at inclusive token start', pg_catalog.jsonb_build_array(receipts_test.receipt(62, 1, (pg_catalog.floor(((select start_seconds from receipts_test.clock))::numeric / 900) * 900)::bigint, 0, null, null, false, false, null, 0)), array['candidate']);
select receipts_test.expect('start own_token alone is outside its window', pg_catalog.jsonb_build_array(pg_catalog.jsonb_set(receipts_test.receipt(69, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0), '{start,own_token}', pg_catalog.to_jsonb(receipts_test.token(1, (select start_seconds from receipts_test.clock) + 120)))), array['rejected']);
select receipts_test.expect('start peer_token alone is outside its window', pg_catalog.jsonb_build_array(pg_catalog.jsonb_set(receipts_test.receipt(69, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0), '{start,peer_token}', pg_catalog.to_jsonb(receipts_test.token(2, (select start_seconds from receipts_test.clock) + 120)))), array['rejected']);
select receipts_test.expect('checkpoint own_token alone is outside its window', pg_catalog.jsonb_build_array(pg_catalog.jsonb_set(receipts_test.receipt(69, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0), '{checkpoint,own_token}', pg_catalog.to_jsonb(receipts_test.token(1, (select start_seconds from receipts_test.clock))))), array['rejected']);
select receipts_test.expect('checkpoint peer_token alone is outside its window', pg_catalog.jsonb_build_array(pg_catalog.jsonb_set(receipts_test.receipt(69, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0), '{checkpoint,peer_token}', pg_catalog.to_jsonb(receipts_test.token(2, (select start_seconds from receipts_test.clock))))), array['rejected']);
select receipts_test.expect('future 300 seconds accepted', pg_catalog.jsonb_build_array(receipts_test.receipt(63, 1, (select current_seconds from receipts_test.clock) + 300, 0, null, null, false, false, null, 0)), array['candidate']);
select receipts_test.expect('future 301 seconds rejected', pg_catalog.jsonb_build_array(receipts_test.receipt(64, 1, (select current_seconds from receipts_test.clock) + 301, 0, null, null, false, false, null, 0)), array['rejected']);
select receipts_test.expect('observation exactly 48 hours old expires', pg_catalog.jsonb_build_array(receipts_test.receipt(65, 1, (select current_seconds from receipts_test.clock) - 172800, 0, null, null, false, false, null, 0)), array['expired']);
select receipts_test.expect('observation just inside 48 hours accepted', pg_catalog.jsonb_build_array(receipts_test.receipt(66, 1, (select current_seconds from receipts_test.clock) - 172799, 0, null, null, false, false, null, 0)), array['candidate']);
select receipts_test.expect('ownership is checked before stale status', pg_catalog.jsonb_build_array(receipts_test.receipt(67, 2, (select current_seconds from receipts_test.clock) - 172800, 0, null, null, false, false, null, 0)), array['rejected']);
select receipts_test.expect('window is checked before stale status', pg_catalog.jsonb_build_array(pg_catalog.jsonb_set(receipts_test.receipt(68, 1, (select current_seconds from receipts_test.clock) - 172800, 0, null, null, false, false, null, 0), '{start,observed_at}', pg_catalog.to_jsonb((select current_seconds from receipts_test.clock) - 173700))), array['rejected']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 0::bigint, 'one sided and invalid uploads create no encounter');
-- Idempotence, immutable identity/evidence, permitted mutable updates and fixed expiry.
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('one sided upload remains candidate', pg_catalog.jsonb_build_array(receipts_test.receipt(100, 1, null, 0, null, null, false, false, null, 0)), array['candidate']);
select receipts_test.expect('identical resubmission remains candidate', pg_catalog.jsonb_build_array(receipts_test.receipt(100, 1, null, 0, null, null, false, false, null, 0)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates), 1::bigint, 'idempotence stores one candidate');
select extensions.is((select expires_at from private.encounter_candidates), pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock))::double precision) + interval '48 hours', 'expiry follows earlier observation');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events where bucket = 'resolve_receipts'), 0::bigint, 'one sided upload does not attempt reciprocal resolution');
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('changed immutable role', pg_catalog.jsonb_build_array(pg_catalog.jsonb_set(receipts_test.receipt(100, 1, null, 0, null, null, false, false, null, 0), '{role}', '"peripheral"'::jsonb)), array['rejected']);
select receipts_test.expect('changed immutable prior nonce', pg_catalog.jsonb_build_array(pg_catalog.jsonb_set(receipts_test.receipt(100, 1, null, 0, null, null, false, false, null, 0), '{prior_exchange_nonce}', pg_catalog.to_jsonb(receipts_test.hex(99)))), array['rejected']);
select receipts_test.expect('changed immutable identity', pg_catalog.jsonb_build_array(pg_catalog.jsonb_set(receipts_test.receipt(100, 1, null, 0, null, null, false, false, null, 0), '{id}', pg_catalog.to_jsonb(receipts_test.user_id(999)))), array['rejected']);
select receipts_test.expect('changed start observation', pg_catalog.jsonb_build_array(pg_catalog.jsonb_set(receipts_test.receipt(100, 1, null, 0, null, null, false, false, null, 0), '{start,observed_at}', pg_catalog.to_jsonb((select start_seconds from receipts_test.clock)+1))), array['rejected']);
select receipts_test.expect('changed start token with same owner', pg_catalog.jsonb_build_array(receipts_test.receipt(100, 1, null, 0, null, null, false, false, null, 1)), array['rejected']);
select receipts_test.expect('changed peer token with same owner', pg_catalog.jsonb_build_array(pg_catalog.jsonb_set(receipts_test.receipt(100, 1, null, 0, null, null, false, false, null, 0), '{start,peer_token}', pg_catalog.to_jsonb(receipts_test.token(2, (select start_seconds from receipts_test.clock), 1)))), array['rejected']);
select receipts_test.expect('identity reused under different exchange nonce', pg_catalog.jsonb_build_array(pg_catalog.jsonb_set(receipts_test.receipt(100, 1, null, 0, null, null, false, false, null, 0), '{exchange_nonce}', pg_catalog.to_jsonb(receipts_test.hex(101)))), array['rejected']);
select receipts_test.expect('checkpoint duration session and final flags may update', pg_catalog.jsonb_build_array(receipts_test.receipt(100, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, true, true, null, 0)), array['candidate']);
reset role;
select extensions.ok((select checkpoint_observed_at is not null and observed_duration = 120 and session_flag and is_final_evidence from private.encounter_candidates), 'mutable evidence persisted');
select extensions.is((select first_uploaded_at from private.encounter_candidates), pg_catalog.now(), 'updates preserve first upload time');
select extensions.is((select expires_at from private.encounter_candidates), pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock))::double precision) + interval '48 hours', 'updates never extend expiry');
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('mutable evidence can be cleared or reduced', pg_catalog.jsonb_build_array(receipts_test.receipt(100, 1, null, 1, null, null, false, false, null, 0)), array['candidate']);
select receipts_test.expect('duplicate identities preserve response order', pg_catalog.jsonb_build_array(receipts_test.receipt(100, 1, null, 1, null, null, false, false, null, 0), receipts_test.receipt(100, 1, null, 1, null, null, false, false, null, 0)), array['candidate', 'candidate']);
reset role;
select extensions.ok((select checkpoint_observed_at is null and observed_duration = 1 and not session_flag and not is_final_evidence from private.encounter_candidates), 'mutable fields are replaced by the submitted values');
update private.encounter_candidates set expires_at = pg_catalog.now();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('candidate expiry is enforced despite fresh observation', pg_catalog.jsonb_build_array(receipts_test.receipt(100, 1, null, 0, null, null, false, false, null, 0)), array['expired']);
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('future start expiry uses first upload', pg_catalog.jsonb_build_array(receipts_test.receipt(102, 1, (select current_seconds from receipts_test.clock)+300, 0, null, null, false, false, null, 0)), array['candidate']);
reset role;
select extensions.is((select expires_at from private.encounter_candidates), pg_catalog.now() + interval '48 hours', 'future observation cannot extend beyond first upload horizon');
-- Held connection resolves in either upload order; final marker is not a gate.
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('held 200 first half', pg_catalog.jsonb_build_array(receipts_test.receipt(200, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('held 200 reciprocal half', pg_catalog.jsonb_build_array(receipts_test.receipt(200, 2, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['resolved']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 1::bigint, 'held 200 creates one encounter');
select extensions.is((select kind from private.encounters), 'ambient', 'held 200 is ambient');
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates), 0::bigint, 'held 200 discards precise observations');
select extensions.is((select pg_catalog.count(*) from private.encounter_views where not revealed and not favorite), 2::bigint, 'held 200 creates unrevealed default views');
select extensions.is((select pg_catalog.count(*) from private.consumed_nonces where exchange_digest = receipts_test.exchange_digest(200)), 1::bigint, 'held 200 consumes one nonce');
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('held 200 replay consumed', pg_catalog.jsonb_build_array(receipts_test.receipt(200, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['consumed']);
reset role;
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('held 201 first half', pg_catalog.jsonb_build_array(receipts_test.receipt(201, 2, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('held 201 reciprocal half', pg_catalog.jsonb_build_array(receipts_test.receipt(201, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['resolved']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 1::bigint, 'held 201 creates one encounter');
select extensions.is((select kind from private.encounters), 'ambient', 'held 201 is ambient');
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates), 0::bigint, 'held 201 discards precise observations');
select extensions.is((select pg_catalog.count(*) from private.encounter_views where not revealed and not favorite), 2::bigint, 'held 201 creates unrevealed default views');
select extensions.is((select pg_catalog.count(*) from private.consumed_nonces where exchange_digest = receipts_test.exchange_digest(201)), 1::bigint, 'held 201 consumes one nonce');
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('held 201 replay consumed', pg_catalog.jsonb_build_array(receipts_test.receipt(201, 2, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['consumed']);
reset role;
select extensions.ok((select pg_catalog.bool_and(not discovery_on) from private.profiles), 'discovery off does not prevent confirmation');
select extensions.ok((select user_a = receipts_test.user_id(1) and user_b = receipts_test.user_id(2) from private.encounters), 'participants are ordered independently of upload order');
select extensions.is((select day_a from private.encounters), (pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock))::double precision) at time zone 'Asia/Tokyo')::date, 'Tokyo viewer gets own first observation date');
select extensions.is((select day_b from private.encounters), (pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock))::double precision) at time zone 'America/Los_Angeles')::date, 'Los Angeles viewer gets own first observation date');
select extensions.ok((select day_a <> day_b from private.encounters), 'viewers on opposite sides of midnight get different dates');
update private.encounter_views set revealed = true, favorite = true, reveal_report_day = date '2000-01-01';
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('dedup first half', pg_catalog.jsonb_build_array(receipts_test.receipt(202, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('dedup resolving half', pg_catalog.jsonb_build_array(receipts_test.receipt(202, 2, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['resolved']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 1::bigint, 'new nonce with same pair kind and dates deduplicates');
select extensions.ok((select pg_catalog.bool_and(revealed and favorite and reveal_report_day = date '2000-01-01') from private.encounter_views), 'dedup preserves reveal favorite and report day');
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('other candidate of same pair', pg_catalog.jsonb_build_array(receipts_test.receipt(203, 1, null, 0, null, null, false, false, null, 0)), array['candidate']);
select receipts_test.expect('other pair remains independent', pg_catalog.jsonb_build_array(receipts_test.receipt(204, 1, null, 0, null, null, false, false, 3, 0)), array['candidate']);
select receipts_test.expect('resolving pair first half', pg_catalog.jsonb_build_array(receipts_test.receipt(205, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('pair cleanup reciprocal half', pg_catalog.jsonb_build_array(receipts_test.receipt(205, 2, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['resolved']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates), 2::bigint, 'unmatched same-pair and other-pair candidates are retained');
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('unmatched same-pair candidate remains pending', pg_catalog.jsonb_build_array(receipts_test.receipt(203, 1, null, 0, null, null, false, false, null, 0)), array['candidate']);
reset role;
select extensions.ok((select pg_catalog.bool_and(pg_catalog.octet_length(exchange_digest) = 32) from private.consumed_nonces), 'nonce tombstones contain only full digests');
select extensions.is((select delete_after from private.consumed_nonces where exchange_digest = receipts_test.exchange_digest(205)), ((pg_catalog.now() at time zone 'UTC') + interval '48 hours 300 seconds')::date + case when ((pg_catalog.now() at time zone 'UTC') + interval '48 hours 300 seconds')::time = time '00:00:00' then 0 else 1 end, 'tombstone deadline is first UTC midnight at least 48 hours plus 300 seconds later');
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('shape check precedes consumed', pg_catalog.jsonb_build_array(pg_catalog.jsonb_set(receipts_test.receipt(205, 1, null, 0, null, null, false, false, null, 0), '{protocol_version}', '2'::jsonb)), array['rejected']);
select receipts_test.expect('ownership check precedes consumed', pg_catalog.jsonb_build_array(receipts_test.receipt(205, 2, null, 0, null, null, false, false, null, 0)), array['rejected']);
select receipts_test.expect('freshness check precedes consumed', pg_catalog.jsonb_build_array(receipts_test.receipt(205, 1, (select current_seconds from receipts_test.clock)-172800, 0, null, null, false, false, null, 0)), array['expired']);
-- Held-connection negative gates, token rotation and exact duration boundary.
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('119 seconds on central first', pg_catalog.jsonb_build_array(receipts_test.receipt(210, 1, null, 119, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('119 seconds on central second', pg_catalog.jsonb_build_array(receipts_test.receipt(210, 2, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 0::bigint, '119 seconds on central cannot confirm');
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('119 seconds on peripheral first', pg_catalog.jsonb_build_array(receipts_test.receipt(211, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('119 seconds on peripheral second', pg_catalog.jsonb_build_array(receipts_test.receipt(211, 2, null, 119, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 0::bigint, '119 seconds on peripheral cannot confirm');
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('missing checkpoint first', pg_catalog.jsonb_build_array(receipts_test.receipt(212, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('missing checkpoint second', pg_catalog.jsonb_build_array(receipts_test.receipt(212, 2, null, 120, null, null, false, false, null, 0)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 0::bigint, 'missing checkpoint cannot confirm');
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('same roles first', pg_catalog.jsonb_build_array(receipts_test.receipt(213, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('same roles second', pg_catalog.jsonb_build_array(pg_catalog.jsonb_set(receipts_test.receipt(213, 2, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0), '{role}', '"central"'::jsonb)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 0::bigint, 'same roles cannot confirm');
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('nonreciprocal start first', pg_catalog.jsonb_build_array(receipts_test.receipt(214, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('nonreciprocal start second', pg_catalog.jsonb_build_array(receipts_test.receipt(214, 2, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 1)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 0::bigint, 'nonreciprocal start cannot confirm');
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('nonreciprocal checkpoint first', pg_catalog.jsonb_build_array(receipts_test.receipt(215, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('nonreciprocal checkpoint second', pg_catalog.jsonb_build_array(pg_catalog.jsonb_set(receipts_test.receipt(215, 2, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0), '{checkpoint,own_token}', pg_catalog.to_jsonb(receipts_test.token(2, (select start_seconds from receipts_test.clock) + 120, 1)))), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 0::bigint, 'nonreciprocal checkpoint cannot confirm');
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('duration update first starts at 119', pg_catalog.jsonb_build_array(receipts_test.receipt(216, 1, null, 119, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('duration update counterpart', pg_catalog.jsonb_build_array(receipts_test.receipt(216, 2, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('duration update to exactly 120 resolves', pg_catalog.jsonb_build_array(receipts_test.receipt(216, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['resolved']);
reset role;
select extensions.ok((select pg_catalog.count(*) = 0 from private.encounter_candidates), 'rotated checkpoint tokens confirm and observations disappear');
-- Second exchange: both orders inside one call and late originals across calls.
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('second exchange 300 first call', pg_catalog.jsonb_build_array(receipts_test.receipt(300, 1, null, 0, null, null, false, true, null, 0), receipts_test.receipt(301, 1, (select start_seconds from receipts_test.clock) + 120, 120, null, 300, false, true, null, 0)), array['candidate', 'candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('second exchange 300 reciprocal call', pg_catalog.jsonb_build_array(receipts_test.receipt(301, 2, (select start_seconds from receipts_test.clock) + 120, 120, null, 300, false, true, null, 0), receipts_test.receipt(300, 2, null, 0, null, null, false, true, null, 0)), array['resolved', 'resolved']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 1::bigint, 'second exchange 300 confirms one encounter');
select extensions.is((select pg_catalog.count(*) from private.consumed_nonces), 2::bigint, 'second exchange 300 consumes original and joined nonce');
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates), 0::bigint, 'second exchange 300 removes originals and joins');
select extensions.is((select day_a from private.encounters), (pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock))::double precision) at time zone 'Asia/Tokyo')::date, 'second exchange 300 date uses original rather than joined time');
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('second exchange 300 original replay', pg_catalog.jsonb_build_array(receipts_test.receipt(300, 1, null, 0, null, null, false, true, null, 0)), array['consumed']);
select receipts_test.expect('second exchange 300 joined replay', pg_catalog.jsonb_build_array(receipts_test.receipt(301, 1, (select start_seconds from receipts_test.clock) + 120, 120, null, 300, false, true, null, 0)), array['consumed']);
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('second exchange 310 first call', pg_catalog.jsonb_build_array(receipts_test.receipt(311, 2, (select start_seconds from receipts_test.clock) + 120, 120, null, 310, false, true, null, 0), receipts_test.receipt(310, 2, null, 0, null, null, false, true, null, 0)), array['candidate', 'candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('second exchange 310 reciprocal call', pg_catalog.jsonb_build_array(receipts_test.receipt(310, 1, null, 0, null, null, false, true, null, 0), receipts_test.receipt(311, 1, (select start_seconds from receipts_test.clock) + 120, 120, null, 310, false, true, null, 0)), array['resolved', 'resolved']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 1::bigint, 'second exchange 310 confirms one encounter');
select extensions.is((select pg_catalog.count(*) from private.consumed_nonces), 2::bigint, 'second exchange 310 consumes original and joined nonce');
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates), 0::bigint, 'second exchange 310 removes originals and joins');
select extensions.is((select day_a from private.encounters), (pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock))::double precision) at time zone 'Asia/Tokyo')::date, 'second exchange 310 date uses original rather than joined time');
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('second exchange 310 original replay', pg_catalog.jsonb_build_array(receipts_test.receipt(310, 2, null, 0, null, null, false, true, null, 0)), array['consumed']);
select receipts_test.expect('second exchange 310 joined replay', pg_catalog.jsonb_build_array(receipts_test.receipt(311, 2, (select start_seconds from receipts_test.clock) + 120, 120, null, 310, false, true, null, 0)), array['consumed']);
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('withheld originals joined central', pg_catalog.jsonb_build_array(receipts_test.receipt(321, 1, (select start_seconds from receipts_test.clock) + 120, 120, null, 320, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('withheld originals joined peripheral', pg_catalog.jsonb_build_array(receipts_test.receipt(321, 2, (select start_seconds from receipts_test.clock) + 120, 120, null, 320, false, false, null, 0)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 0::bigint, 'joined evidence with both originals withheld cannot confirm');
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('late original central', pg_catalog.jsonb_build_array(receipts_test.receipt(320, 1, null, 0, null, null, false, false, null, 0)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 0::bigint, 'one original withheld still cannot confirm');
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('last original defers joined row without its nonce lock in this call', pg_catalog.jsonb_build_array(receipts_test.receipt(320, 2, null, 0, null, null, false, false, null, 0)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.consumed_nonces), 0::bigint, 'unlocked joined row consumes no nonce');
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates), 4::bigint,
    'unlocked joined row and its originals remain stored');
set local role authenticated;
select receipts_test.expect('joined retry takes both nonce locks and resolves',
    pg_catalog.jsonb_build_array(receipts_test.receipt(321, 2,
        (select start_seconds from receipts_test.clock) + 120, 120, null, 320)), array['resolved']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.consumed_nonces), 2::bigint, 'locked retry consumes both nonces');
-- A stored joined session row may be visited through another pair's original.
-- Name both nonces in this call, but derive only the different pair lock.
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('pair guard joined central before sessions', pg_catalog.jsonb_build_array(
    receipts_test.receipt(986, 1, (select start_seconds from receipts_test.clock) + 120, 0, null, 985, true)),
    array['candidate']);
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('pair guard joined peripheral before sessions', pg_catalog.jsonb_build_array(
    receipts_test.receipt(986, 2, (select start_seconds from receipts_test.clock) + 120, 0, null, 985, true)),
    array['candidate']);
reset role;
insert into private.sessions (user_id, starts_at, expires_at)
select receipts_test.user_id(side), pg_catalog.to_timestamp(c.start_seconds::double precision),
    pg_catalog.to_timestamp((c.start_seconds + 300)::double precision)
from receipts_test.clock as c cross join pg_catalog.generate_series(1, 2) as sides(side);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('different pair cannot resolve a stored row even with both nonce locks',
    pg_catalog.jsonb_build_array(receipts_test.receipt(985, 1, null, 0, null, null, false, false, 3),
        pg_catalog.jsonb_build_object('id', receipts_test.user_id(9861), 'exchange_nonce', receipts_test.hex(986))),
    array['candidate', 'rejected']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 0::bigint,
    'missing pair lock defers an otherwise qualifying session');
select extensions.is((select pg_catalog.count(*) from private.consumed_nonces), 0::bigint,
    'missing pair lock creates no tombstone');
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates), 3::bigint,
    'missing pair lock preserves both joined rows and the different original');
set local role authenticated;
select receipts_test.expect('retry with the stored pair lock resolves the session', pg_catalog.jsonb_build_array(
    receipts_test.receipt(986, 1, (select start_seconds from receipts_test.clock) + 120, 0, null, 985, true)),
    array['resolved']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates), 1::bigint,
    'session resolution preserves the original belonging to another pair');
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('split original peripheral', pg_catalog.jsonb_build_array(receipts_test.receipt(330, 2, null, 0, null, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('split original central', pg_catalog.jsonb_build_array(receipts_test.receipt(330, 1, null, 0, null, null, false, false, null, 0)), array['candidate']);
select receipts_test.expect('split joined central', pg_catalog.jsonb_build_array(receipts_test.receipt(331, 1, (select start_seconds from receipts_test.clock) + 120, 120, null, 330, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('split joined peripheral', pg_catalog.jsonb_build_array(receipts_test.receipt(331, 2, (select start_seconds from receipts_test.clock) + 120, 120, null, 330, false, false, null, 0)), array['resolved']);
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('joined central duration 119 original central', pg_catalog.jsonb_build_array(receipts_test.receipt(350, 1, null, 0, null, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('joined central duration 119 original counterpart', pg_catalog.jsonb_build_array(receipts_test.receipt(350, 2, null, 0, null, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('joined central duration 119 joined central', pg_catalog.jsonb_build_array(receipts_test.receipt(351, 1, (select start_seconds from receipts_test.clock)+120, 119, null, 350, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('joined central duration 119 joined peripheral', pg_catalog.jsonb_build_array(receipts_test.receipt(351, 2, (select start_seconds from receipts_test.clock)+120, 120, null, 350, false, false, null, 0)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 0::bigint, 'joined central duration 119 stays unresolved');
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('joined peripheral duration 119 original central', pg_catalog.jsonb_build_array(receipts_test.receipt(353, 1, null, 0, null, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('joined peripheral duration 119 original counterpart', pg_catalog.jsonb_build_array(receipts_test.receipt(353, 2, null, 0, null, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('joined peripheral duration 119 joined central', pg_catalog.jsonb_build_array(receipts_test.receipt(354, 1, (select start_seconds from receipts_test.clock)+120, 120, null, 353, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('joined peripheral duration 119 joined peripheral', pg_catalog.jsonb_build_array(receipts_test.receipt(354, 2, (select start_seconds from receipts_test.clock)+120, 119, null, 353, false, false, null, 0)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 0::bigint, 'joined peripheral duration 119 stays unresolved');
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('central observation gap 119 original central', pg_catalog.jsonb_build_array(receipts_test.receipt(356, 1, null, 0, null, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('central observation gap 119 original counterpart', pg_catalog.jsonb_build_array(receipts_test.receipt(356, 2, null, 0, null, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('central observation gap 119 joined central', pg_catalog.jsonb_build_array(receipts_test.receipt(357, 1, (select start_seconds from receipts_test.clock)+119, 120, null, 356, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('central observation gap 119 joined peripheral', pg_catalog.jsonb_build_array(receipts_test.receipt(357, 2, (select start_seconds from receipts_test.clock)+120, 120, null, 356, false, false, null, 0)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 0::bigint, 'central observation gap 119 stays unresolved');
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('peripheral observation gap 119 original central', pg_catalog.jsonb_build_array(receipts_test.receipt(359, 1, null, 0, null, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('peripheral observation gap 119 original counterpart', pg_catalog.jsonb_build_array(receipts_test.receipt(359, 2, null, 0, null, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('peripheral observation gap 119 joined central', pg_catalog.jsonb_build_array(receipts_test.receipt(360, 1, (select start_seconds from receipts_test.clock)+120, 120, null, 359, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('peripheral observation gap 119 joined peripheral', pg_catalog.jsonb_build_array(receipts_test.receipt(360, 2, (select start_seconds from receipts_test.clock)+119, 120, null, 359, false, false, null, 0)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 0::bigint, 'peripheral observation gap 119 stays unresolved');
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('mismatched prior nonce original central', pg_catalog.jsonb_build_array(receipts_test.receipt(362, 1, null, 0, null, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('mismatched prior nonce original counterpart', pg_catalog.jsonb_build_array(receipts_test.receipt(362, 2, null, 0, null, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('mismatched prior nonce joined central', pg_catalog.jsonb_build_array(receipts_test.receipt(363, 1, (select start_seconds from receipts_test.clock)+120, 120, null, 362, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('mismatched prior nonce joined peripheral', pg_catalog.jsonb_build_array(receipts_test.receipt(363, 2, (select start_seconds from receipts_test.clock)+120, 120, null, 364, false, false, null, 0)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 0::bigint, 'mismatched prior nonce stays unresolved');
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('different owners in original exchange original central', pg_catalog.jsonb_build_array(receipts_test.receipt(365, 1, null, 0, null, null, false, false, 3, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000003","role":"authenticated"}';
select receipts_test.expect('different owners in original exchange original counterpart', pg_catalog.jsonb_build_array(receipts_test.receipt(365, 3, null, 0, null, null, false, false, 1, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('different owners in original exchange joined central', pg_catalog.jsonb_build_array(receipts_test.receipt(366, 1, (select start_seconds from receipts_test.clock)+120, 120, null, 365, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('different owners in original exchange joined peripheral', pg_catalog.jsonb_build_array(receipts_test.receipt(366, 2, (select start_seconds from receipts_test.clock)+120, 120, null, 365, false, false, null, 0)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 0::bigint, 'different owners in original exchange stays unresolved');
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('original role differs from joined original central', pg_catalog.jsonb_build_array(pg_catalog.jsonb_set(receipts_test.receipt(368, 1, null, 0, null, null, false, false, null, 0), '{role}', '"peripheral"'::jsonb)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('original role differs from joined original counterpart', pg_catalog.jsonb_build_array(receipts_test.receipt(368, 2, null, 0, null, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('original role differs from joined joined central', pg_catalog.jsonb_build_array(receipts_test.receipt(369, 1, (select start_seconds from receipts_test.clock)+120, 120, null, 368, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('original role differs from joined joined peripheral', pg_catalog.jsonb_build_array(receipts_test.receipt(369, 2, (select start_seconds from receipts_test.clock)+120, 120, null, 368, false, false, null, 0)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 0::bigint, 'original role differs from joined stays unresolved');
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('original itself references prior original central', pg_catalog.jsonb_build_array(receipts_test.receipt(371, 1, null, 0, null, 370, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('original itself references prior original counterpart', pg_catalog.jsonb_build_array(receipts_test.receipt(371, 2, null, 0, null, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('original itself references prior joined central', pg_catalog.jsonb_build_array(receipts_test.receipt(372, 1, (select start_seconds from receipts_test.clock)+120, 120, null, 371, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('original itself references prior joined peripheral', pg_catalog.jsonb_build_array(receipts_test.receipt(372, 2, (select start_seconds from receipts_test.clock)+120, 120, null, 371, false, false, null, 0)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 0::bigint, 'original itself references prior stays unresolved');
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('original start pairs not reciprocal original central', pg_catalog.jsonb_build_array(receipts_test.receipt(374, 1, null, 0, null, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('original start pairs not reciprocal original counterpart', pg_catalog.jsonb_build_array(receipts_test.receipt(374, 2, null, 0, null, null, false, false, null, 1)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('original start pairs not reciprocal joined central', pg_catalog.jsonb_build_array(receipts_test.receipt(375, 1, (select start_seconds from receipts_test.clock)+120, 120, null, 374, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('original start pairs not reciprocal joined peripheral', pg_catalog.jsonb_build_array(receipts_test.receipt(375, 2, (select start_seconds from receipts_test.clock)+120, 120, null, 374, false, false, null, 0)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 0::bigint, 'original start pairs not reciprocal stays unresolved');
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('expired original cannot qualify original central', pg_catalog.jsonb_build_array(receipts_test.receipt(377, 1, null, 0, null, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('expired original cannot qualify original counterpart', pg_catalog.jsonb_build_array(receipts_test.receipt(377, 2, null, 0, null, null, false, false, null, 0)), array['candidate']);
reset role;
update private.encounter_candidates set expires_at = pg_catalog.now();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('expired original cannot qualify joined central', pg_catalog.jsonb_build_array(receipts_test.receipt(378, 1, (select start_seconds from receipts_test.clock)+120, 120, null, 377, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('expired original cannot qualify joined peripheral', pg_catalog.jsonb_build_array(receipts_test.receipt(378, 2, (select start_seconds from receipts_test.clock)+120, 120, null, 377, false, false, null, 0)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 0::bigint, 'expired original cannot qualify stays unresolved');
-- Authoritative sessions at each observation, including historical expired/stopped ledgers.
reset role;
select receipts_test.reset_evidence();
reset role;
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('none session first half', pg_catalog.jsonb_build_array(receipts_test.receipt(400, 1, null, 0, null, null, true, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('none session second half', pg_catalog.jsonb_build_array(receipts_test.receipt(400, 2, null, 0, null, null, true, false, null, 0)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 0::bigint, 'none server session classification');
reset role;
select receipts_test.reset_evidence();
reset role;
insert into private.sessions (user_id, starts_at, expires_at, stopped_at)
select receipts_test.user_id(side), pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock)-1)::double precision),
    pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock)+3600)::double precision), null
from pg_catalog.unnest(array[1]) as side;
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('one session first half', pg_catalog.jsonb_build_array(receipts_test.receipt(401, 1, null, 0, null, null, true, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('one session second half', pg_catalog.jsonb_build_array(receipts_test.receipt(401, 2, null, 0, null, null, true, false, null, 0)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 0::bigint, 'one server session classification');
reset role;
select receipts_test.reset_evidence();
reset role;
insert into private.sessions (user_id, starts_at, expires_at, stopped_at)
select receipts_test.user_id(side), pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock)-1)::double precision),
    pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock))::double precision), null
from pg_catalog.unnest(array[1, 2]) as side;
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('expired session first half', pg_catalog.jsonb_build_array(receipts_test.receipt(402, 1, null, 0, null, null, true, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('expired session second half', pg_catalog.jsonb_build_array(receipts_test.receipt(402, 2, null, 0, null, null, true, false, null, 0)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 0::bigint, 'expired server session classification');
reset role;
select receipts_test.reset_evidence();
reset role;
insert into private.sessions (user_id, starts_at, expires_at, stopped_at)
select receipts_test.user_id(side), pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock)-1)::double precision),
    pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock)+3600)::double precision), pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock))::double precision)
from pg_catalog.unnest(array[1, 2]) as side;
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('stopped session first half', pg_catalog.jsonb_build_array(receipts_test.receipt(403, 1, null, 0, null, null, true, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('stopped session second half', pg_catalog.jsonb_build_array(receipts_test.receipt(403, 2, null, 0, null, null, true, false, null, 0)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 0::bigint, 'stopped server session classification');
reset role;
select receipts_test.reset_evidence();
reset role;
insert into private.sessions (user_id, starts_at, expires_at, stopped_at)
select receipts_test.user_id(side), pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock)+1)::double precision),
    pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock)+3600)::double precision), null
from pg_catalog.unnest(array[1, 2]) as side;
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('not-started session first half', pg_catalog.jsonb_build_array(receipts_test.receipt(404, 1, null, 0, null, null, true, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('not-started session second half', pg_catalog.jsonb_build_array(receipts_test.receipt(404, 2, null, 0, null, null, true, false, null, 0)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 0::bigint, 'not-started server session classification');
reset role;
select receipts_test.reset_evidence();
reset role;
insert into private.sessions (user_id, starts_at, expires_at, stopped_at)
select receipts_test.user_id(side), pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock)-1)::double precision),
    pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock)+3600)::double precision), null
from pg_catalog.unnest(array[1, 2]) as side;
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('active session first half', pg_catalog.jsonb_build_array(receipts_test.receipt(405, 1, null, 0, null, null, true, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('active session second half', pg_catalog.jsonb_build_array(receipts_test.receipt(405, 2, null, 0, null, null, true, false, null, 0)), array['resolved']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 1::bigint, 'active server session classification');
select extensions.is((select kind from private.encounters), 'session', 'active zero duration qualifies only as session');
select extensions.is((select pg_catalog.count(*) from private.encounter_views where revealed), 2::bigint, 'active session reveals both viewers immediately');
reset role;
select receipts_test.reset_evidence();
reset role;
insert into private.sessions (user_id, starts_at, expires_at, stopped_at)
select receipts_test.user_id(side), pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock))::double precision),
    pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock)+3600)::double precision), null
from pg_catalog.unnest(array[1, 2]) as side;
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('inclusive session first half', pg_catalog.jsonb_build_array(receipts_test.receipt(406, 1, null, 0, null, null, true, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('inclusive session second half', pg_catalog.jsonb_build_array(receipts_test.receipt(406, 2, null, 0, null, null, true, false, null, 0)), array['resolved']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 1::bigint, 'inclusive server session classification');
select extensions.is((select kind from private.encounters), 'session', 'inclusive zero duration qualifies only as session');
select extensions.is((select pg_catalog.count(*) from private.encounter_views where revealed), 2::bigint, 'inclusive session reveals both viewers immediately');
reset role;
select receipts_test.reset_evidence();
reset role;
insert into private.sessions (user_id, starts_at, expires_at, stopped_at)
select receipts_test.user_id(side), pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock)-1)::double precision),
    pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock)+2)::double precision), pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock)+1)::double precision)
from pg_catalog.unnest(array[1, 2]) as side;
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('later-stop session first half', pg_catalog.jsonb_build_array(receipts_test.receipt(407, 1, null, 0, null, null, true, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('later-stop session second half', pg_catalog.jsonb_build_array(receipts_test.receipt(407, 2, null, 0, null, null, true, false, null, 0)), array['resolved']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 1::bigint, 'later-stop server session classification');
select extensions.is((select kind from private.encounters), 'session', 'later-stop zero duration qualifies only as session');
select extensions.is((select pg_catalog.count(*) from private.encounter_views where revealed), 2::bigint, 'later-stop session reveals both viewers immediately');
reset role;
select receipts_test.reset_evidence();
reset role;
insert into private.sessions (user_id, starts_at, expires_at, stopped_at)
select receipts_test.user_id(side), pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock)-1)::double precision),
    pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock)+3600)::double precision), null
from pg_catalog.unnest(array[1, 2]) as side;
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('one session flag false central', pg_catalog.jsonb_build_array(receipts_test.receipt(420, 1, null, 0, null, null, true, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('one session flag false peripheral', pg_catalog.jsonb_build_array(receipts_test.receipt(420, 2, null, 0, null, null, false, false, null, 0)), array['candidate']);
select receipts_test.expect('session flag update enables classification', pg_catalog.jsonb_build_array(receipts_test.receipt(420, 2, null, 0, null, null, true, false, null, 0)), array['resolved']);
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('forged flags with ambient evidence central', pg_catalog.jsonb_build_array(receipts_test.receipt(421, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, true, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('forged flags with ambient evidence peripheral', pg_catalog.jsonb_build_array(receipts_test.receipt(421, 2, null, 120, (select start_seconds from receipts_test.clock) + 120, null, true, false, null, 0)), array['resolved']);
reset role;
select extensions.is((select kind from private.encounters), 'ambient', 'forged flags do not grant session kind or immediate reveal');
reset role;
insert into private.sessions (user_id, starts_at, expires_at, stopped_at)
select receipts_test.user_id(side), pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock)-1)::double precision),
    pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock)+3600)::double precision), null
from pg_catalog.unnest(array[1, 2]) as side;
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('same date session first', pg_catalog.jsonb_build_array(receipts_test.receipt(422, 1, null, 0, null, null, true, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('same date session second', pg_catalog.jsonb_build_array(receipts_test.receipt(422, 2, null, 0, null, null, true, false, null, 0)), array['resolved']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 2::bigint, 'different kinds on the same dates do not deduplicate');
-- Joined receipts can also qualify as sessions; known originals supply the first dates.
reset role;
select receipts_test.reset_evidence();
reset role;
insert into private.sessions (user_id, starts_at, expires_at, stopped_at)
select receipts_test.user_id(side), pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock)-1)::double precision),
    pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock)+3600)::double precision), null
from pg_catalog.unnest(array[1, 2]) as side;
update private.notification_preferences set time_zone = 'UTC' where user_id = receipts_test.user_id(1);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('joined session central with original', pg_catalog.jsonb_build_array(receipts_test.receipt(430, 1, null, 0, null, null, false, false, null, 0), receipts_test.receipt(431, 1, (select start_seconds from receipts_test.clock) + 120, 0, null, 430, true, false, null, 0)), array['candidate', 'candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('joined session peripheral with original', pg_catalog.jsonb_build_array(receipts_test.receipt(431, 2, (select start_seconds from receipts_test.clock) + 120, 0, null, 430, true, false, null, 0), receipts_test.receipt(430, 2, null, 0, null, null, false, false, null, 0)), array['resolved', 'resolved']);
reset role;
select extensions.is((select kind from private.encounters), 'session', 'joined session needs no 120 second duration');
select extensions.is((select day_a from private.encounters), (pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock))::double precision) at time zone 'UTC')::date, 'joined session uses known first exchange date across midnight');
select extensions.is((select pg_catalog.count(*) from private.consumed_nonces), 2::bigint, 'joined session consumes both nonces');
reset role;
select receipts_test.reset_evidence();
reset role;
insert into private.sessions (user_id, starts_at, expires_at, stopped_at)
select receipts_test.user_id(side), pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock)-1)::double precision),
    pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock)+3600)::double precision), null
from pg_catalog.unnest(array[1, 2]) as side;
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('joined session without originals central', pg_catalog.jsonb_build_array(receipts_test.receipt(433, 1, (select start_seconds from receipts_test.clock) + 120, 0, null, 432, true, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('joined session without originals peripheral', pg_catalog.jsonb_build_array(receipts_test.receipt(433, 2, (select start_seconds from receipts_test.clock) + 120, 0, null, 432, true, false, null, 0)), array['resolved']);
reset role;
select extensions.is((select day_a from private.encounters), (pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock) + 120)::double precision) at time zone 'UTC')::date, 'session with withheld originals uses available matched start date');
update private.notification_preferences set time_zone = 'Asia/Tokyo' where user_id = receipts_test.user_id(1);
-- Either-direction blocks conceal suppression while consuming and erasing both receipt shapes.
reset role;
select receipts_test.reset_evidence();
insert into private.blocks (blocker_id, blocked_id, placed_day) values (receipts_test.user_id(1), receipts_test.user_id(2), (pg_catalog.now() at time zone 'UTC')::date);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('block 1 first half', pg_catalog.jsonb_build_array(receipts_test.receipt(450, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0), receipts_test.receipt(449, 1)), array['candidate','candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('block 1 resolving half', pg_catalog.jsonb_build_array(receipts_test.receipt(450, 2, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['resolved']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 0::bigint, 'block 1 prevents encounter');
select extensions.is((select pg_catalog.count(*) from private.encounter_views), 0::bigint, 'block 1 prevents views');
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates), 1::bigint, 'block 1 removes only matched evidence and retains the other exchange');
select extensions.is((select pg_catalog.count(*) from private.consumed_nonces), 1::bigint, 'block 1 consumes qualifying nonces');
reset role;
select receipts_test.reset_evidence();
insert into private.blocks (blocker_id, blocked_id, placed_day) values (receipts_test.user_id(2), receipts_test.user_id(1), (pg_catalog.now() at time zone 'UTC')::date);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('block 2 first joined call', pg_catalog.jsonb_build_array(receipts_test.receipt(460, 1, null, 0, null, null, false, false, null, 0), receipts_test.receipt(461, 1, (select start_seconds from receipts_test.clock) + 120, 120, null, 460, false, false, null, 0), receipts_test.receipt(462, 1)), array['candidate', 'candidate', 'candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('block 2 second joined call', pg_catalog.jsonb_build_array(receipts_test.receipt(461, 2, (select start_seconds from receipts_test.clock) + 120, 120, null, 460, false, false, null, 0), receipts_test.receipt(460, 2, null, 0, null, null, false, false, null, 0)), array['resolved', 'resolved']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 0::bigint, 'block 2 prevents encounter');
select extensions.is((select pg_catalog.count(*) from private.encounter_views), 0::bigint, 'block 2 prevents views');
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates), 1::bigint, 'block 2 removes only joined evidence and originals');
select extensions.is((select pg_catalog.count(*) from private.consumed_nonces), 2::bigint, 'block 2 consumes qualifying nonces');
-- Per-viewer report day uses transaction time and report minute, not observation day.
reset role;
select receipts_test.reset_evidence();
update private.notification_preferences set time_zone = case when extract(hour from pg_catalog.now() at time zone 'UTC') = 23 then 'Asia/Tokyo' else 'UTC' end
where user_id in (receipts_test.user_id(1), receipts_test.user_id(2));
update private.notification_preferences set
    report_hour = extract(hour from pg_catalog.now() at time zone time_zone)::integer + case when user_id = receipts_test.user_id(1) then 1 else 0 end,
    report_minute = case when user_id = receipts_test.user_id(1) then 0 else extract(minute from pg_catalog.now() at time zone time_zone)::integer end
where user_id in (receipts_test.user_id(1), receipts_test.user_id(2));
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('report timing first half', pg_catalog.jsonb_build_array(receipts_test.receipt(500, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('report timing second half', pg_catalog.jsonb_build_array(receipts_test.receipt(500, 2, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['resolved']);
reset role;
select extensions.is((select v.reveal_report_day from private.encounter_views as v where v.viewer_id = receipts_test.user_id(1)), (select (pg_catalog.now() at time zone n.time_zone)::date from private.notification_preferences as n where n.user_id = receipts_test.user_id(1)), 'before local report time reveals on today report');
select extensions.is((select v.reveal_report_day from private.encounter_views as v where v.viewer_id = receipts_test.user_id(2)), (select (pg_catalog.now() at time zone n.time_zone)::date + 1 from private.notification_preferences as n where n.user_id = receipts_test.user_id(2)), 'at or after report minute schedules next local day');
select extensions.ok((select pg_catalog.bool_and(not revealed) from private.encounter_views), 'ambient views remain unrevealed independent of report schedule');
reset role;
select receipts_test.reset_evidence();
update private.notification_preferences set time_zone = 'Asia/Tokyo', report_hour = 21, report_minute = 0 where user_id = receipts_test.user_id(1);
update private.notification_preferences set time_zone = 'America/Los_Angeles', report_hour = 21, report_minute = 0 where user_id = receipts_test.user_id(2);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('fallback peer uploads while ready', pg_catalog.jsonb_build_array(receipts_test.receipt(501, 2, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['candidate']);
reset role;
delete from private.notification_preferences where user_id = receipts_test.user_id(2);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('fallback missing preferences peer resolves', pg_catalog.jsonb_build_array(receipts_test.receipt(501, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['resolved']);
reset role;
select extensions.is((select day_b from private.encounters), (pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock))::double precision) at time zone 'UTC')::date, 'missing preferences peer date falls back to UTC');
select extensions.is((select reveal_report_day from private.encounter_views where viewer_id = receipts_test.user_id(2)), (pg_catalog.now() at time zone 'UTC')::date + case when (pg_catalog.now() at time zone 'UTC')::time >= time '21:00:00' then 1 else 0 end, 'missing preferences report falls back to 21:00 UTC');
insert into private.notification_preferences (user_id, time_zone) values (receipts_test.user_id(2), 'America/Los_Angeles');
-- Expiry applies on reads even before cleanup, including tokens, priors and counterparts.
reset role;
select receipts_test.reset_evidence();
select receipts_test.seed_token(1, (select start_seconds from receipts_test.clock), 2);
update private.temporary_tokens set delete_after = valid_until + 172800 where token_digest = pg_catalog.sha256(pg_catalog.decode(receipts_test.token(1, (select start_seconds from receipts_test.clock), 2), 'hex'));
insert into private.temporary_tokens (token_digest, user_id, batch_id, valid_from, valid_until, delete_after)
select receipts_test.digest(600000), receipts_test.user_id(1), receipts_test.user_id(1),
    (pg_catalog.floor(((select current_seconds from receipts_test.clock))::numeric / 900) * 900)::bigint - 173700,
    (pg_catalog.floor(((select current_seconds from receipts_test.clock))::numeric / 900) * 900)::bigint - 172800,
    (pg_catalog.floor(((select current_seconds from receipts_test.clock))::numeric / 900) * 900)::bigint;
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('expired token digest cannot validate ownership', pg_catalog.jsonb_build_array(pg_catalog.jsonb_set(receipts_test.receipt(600, 1, null, 0, null, null, false, false, null, 0), '{start,own_token}', pg_catalog.to_jsonb(receipts_test.hex(600000)))), array['rejected']);
reset role;
insert into private.consumed_nonces values (receipts_test.exchange_digest(601), (pg_catalog.now() at time zone 'UTC')::date), (receipts_test.exchange_digest(602), (pg_catalog.now() at time zone 'UTC')::date + 1);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('expired tombstone ignored at its UTC date', pg_catalog.jsonb_build_array(receipts_test.receipt(601, 1, null, 0, null, null, false, false, null, 0)), array['candidate']);
select receipts_test.expect('unexpired tombstone rejects replay', pg_catalog.jsonb_build_array(receipts_test.receipt(602, 1, null, 0, null, null, false, false, null, 0)), array['consumed']);
reset role;
select receipts_test.consumed_original_flow(v.label, v.rotates, v.in_session)
from (values ('rotated ambient', true, false), ('rotated session', true, true),
    ('same-window ambient', false, false), ('same-window session', false, true)) as v(label, rotates, in_session);
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('expiring counterpart starts candidate', pg_catalog.jsonb_build_array(receipts_test.receipt(605, 2, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['candidate']);
reset role;
update private.encounter_candidates set expires_at = pg_catalog.now();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('expired counterpart cannot resolve', pg_catalog.jsonb_build_array(receipts_test.receipt(605, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 0::bigint, 'expired reciprocal row never confirms');
-- 1 and 50 receipts are accepted; 60 calls/minute includes idempotent requests.
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('50 receipt boundary', (select pg_catalog.jsonb_agg(receipts_test.receipt(n, 1) order by n) from pg_catalog.generate_series(700, 749) as n), array['candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate', 'candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates), 50::bigint, '50 acceptable receipts are stored before resolution');
reset role;
select receipts_test.reset_evidence();
insert into private.account_limit_events (user_id, bucket, occurred_at) select receipts_test.user_id(1), 'submit_receipts', pg_catalog.now() from pg_catalog.generate_series(1,59);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('60th submit call succeeds', pg_catalog.jsonb_build_array(receipts_test.receipt(750, 1, null, 0, null, null, false, false, null, 0)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.account_limit_events where user_id = receipts_test.user_id(1) and bucket = 'submit_receipts'), 60::bigint, 'exactly 60 successful submit calls recorded');
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect_error('select public.submit_receipts(pg_catalog.jsonb_build_array(receipts_test.receipt(750, 1, null, 0, null, null, false, false, null, 0)))', 'rate_limited', '', '61st idempotent call rate limited');
reset role;
select extensions.is((select pg_catalog.count(*) from private.account_limit_events where user_id = receipts_test.user_id(1) and bucket = 'submit_receipts'), 60::bigint, 'refused submit call rolls back atomically');
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('another account can upload while caller one is capped', pg_catalog.jsonb_build_array(receipts_test.receipt(751, 2, null, 0, null, null, false, false, null, 0)), array['candidate']);
reset role;
update private.account_limit_events set occurred_at = pg_catalog.now() - interval '1 minute';
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('events at minute cutoff excluded', pg_catalog.jsonb_build_array(receipts_test.receipt(750, 1, null, 0, null, null, false, false, null, 0)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.account_limit_events
    where user_id = receipts_test.user_id(1) and bucket = 'submit_receipts'), 1::bigint,
    'submit limiter deletes its old minute events');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events
    where user_id = receipts_test.user_id(2) and bucket = 'submit_receipts'), 1::bigint,
    'submit limiter preserves another account old events');
-- 30 qualifying resolutions/minute: over-limit evidence remains candidate without a new event.
reset role;
select receipts_test.reset_evidence();
insert into private.account_limit_events (user_id, bucket, occurred_at) select receipts_test.user_id(1), 'resolve_receipts', pg_catalog.now() from pg_catalog.generate_series(1,29);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('resolution limit reciprocal first half', pg_catalog.jsonb_build_array(receipts_test.receipt(760, 2, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('30th resolution succeeds', pg_catalog.jsonb_build_array(receipts_test.receipt(760, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['resolved']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.account_limit_events where user_id = receipts_test.user_id(1) and bucket = 'resolve_receipts'), 30::bigint, '30 successful attempts are recorded');
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('resolution limit next counterpart', pg_catalog.jsonb_build_array(receipts_test.receipt(761, 2, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('31st attempt stays candidate', pg_catalog.jsonb_build_array(receipts_test.receipt(761, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 1::bigint, 'over-limit attempt creates no new encounter');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events where user_id = receipts_test.user_id(1) and bucket = 'resolve_receipts'), 30::bigint, 'refused resolution adds no limiter event');
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates), 2::bigint, 'over-limit reciprocal evidence retained');
select extensions.is((select pg_catalog.count(*) from private.consumed_nonces where exchange_digest = receipts_test.exchange_digest(761)), 0::bigint, 'over-limit nonce is not consumed');
update private.account_limit_events set occurred_at = pg_catalog.now() - interval '1 minute' where bucket = 'resolve_receipts';
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('later call resolves deferred evidence', pg_catalog.jsonb_build_array(receipts_test.receipt(761, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['resolved']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.account_limit_events where user_id = receipts_test.user_id(1) and bucket = 'resolve_receipts'), 1::bigint, 'resolution limiter deletes all previous minute instants');
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('matched short central', pg_catalog.jsonb_build_array(receipts_test.receipt(762, 1, null, 0, null, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('matched short peripheral', pg_catalog.jsonb_build_array(receipts_test.receipt(762, 2, null, 0, null, null, false, false, null, 0)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.account_limit_events where bucket = 'resolve_receipts'), 0::bigint, 'nonqualifying reciprocal pair spends no resolution event');
-- 2000 live candidates/account, updates at cap, nonterminal cap refusal and expiry exclusion.
reset role;
select receipts_test.reset_evidence();
insert into private.encounter_candidates (nonce_digest, uploader_id, receipt_id, peer_id, protocol_version, role,
    start_own_token_digest, start_peer_token_digest, start_observed_at, observed_duration, session_flag,
    is_final_evidence, first_uploaded_at, expires_at)
select receipts_test.digest(n), receipts_test.user_id(5), receipts_test.user_id(n*10+5), receipts_test.user_id(6), 1, 'peripheral',
    pg_catalog.sha256(pg_catalog.decode(receipts_test.token(5, (select start_seconds from receipts_test.clock)), 'hex')),
    pg_catalog.sha256(pg_catalog.decode(receipts_test.token(6, (select start_seconds from receipts_test.clock)), 'hex')), (select start_seconds from receipts_test.clock), 0, false, false,
    pg_catalog.now(), pg_catalog.to_timestamp(((select start_seconds from receipts_test.clock))::double precision) + interval '48 hours'
from pg_catalog.generate_series(20000, 21998) as n;
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000005","role":"authenticated"}';
select receipts_test.expect('2000th candidate succeeds', pg_catalog.jsonb_build_array(receipts_test.receipt(22000, 5, null, 0, null, null, false, false, 6, 0)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates where uploader_id = receipts_test.user_id(5)), 2000::bigint, 'candidate boundary exactly 2000');
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000005","role":"authenticated"}';
select receipts_test.expect('existing candidate update at cap succeeds', pg_catalog.jsonb_build_array(receipts_test.receipt(22000, 5, null, 1, null, null, false, false, 6, 0)), array['candidate']);
select receipts_test.expect('2001st candidate is deferred without an exception', pg_catalog.jsonb_build_array(receipts_test.receipt(22001, 5, null, 0, null, null, false, false, 6, 0)), array['candidate']);
select receipts_test.expect('cap refusal preserves an existing candidate update in the batch', pg_catalog.jsonb_build_array(receipts_test.receipt(22000, 5, null, 2, null, null, false, false, 6, 0), receipts_test.receipt(22002, 5, null, 0, null, null, false, false, 6, 0)), array['candidate','candidate']);
reset role;
select extensions.is((select observed_duration from private.encounter_candidates where nonce_digest = receipts_test.digest(22000)), 2::bigint, 'cap refusal does not roll back the earlier mutable update');
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates where uploader_id = receipts_test.user_id(5)), 2000::bigint, 'refused insert leaves cap unchanged');
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates where uploader_id = receipts_test.user_id(5) and nonce_digest in (receipts_test.digest(22001), receipts_test.digest(22002))), 0::bigint, 'new receipts beyond the candidate cap are not stored');
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('different account has independent candidate capacity', pg_catalog.jsonb_build_array(receipts_test.receipt(22003, 1, null, 0, null, null, false, false, null, 0)), array['candidate']);
reset role;
update private.encounter_candidates set expires_at = pg_catalog.now() where nonce_digest = receipts_test.digest(20000);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000005","role":"authenticated"}';
select receipts_test.expect('expired candidate excluded from cap', pg_catalog.jsonb_build_array(receipts_test.receipt(22004, 5, null, 0, null, null, false, false, 6, 0)), array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates where uploader_id = receipts_test.user_id(5) and expires_at > pg_catalog.now()), 2000::bigint, 'expired slot reclaimed without extending live candidates');
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates where uploader_id = receipts_test.user_id(5) and nonce_digest = receipts_test.digest(20000)), 1::bigint, 'expired candidates remain through the skew grace at the cap');
-- Resolution acknowledgements cover every candidate removed in this call, then leave only dates/digests.
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('same call cleanup counterpart', pg_catalog.jsonb_build_array(receipts_test.receipt(800, 2, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0)), array['candidate']);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('only matched receipts of a resolved pair report resolved', pg_catalog.jsonb_build_array(receipts_test.receipt(801, 1, null, 0, null, null, false, false, null, 0), receipts_test.receipt(800, 1, null, 120, (select start_seconds from receipts_test.clock) + 120, null, false, false, null, 0), receipts_test.receipt(802, 1, null, 0, null, null, false, false, 3, 0)), array['candidate', 'resolved', 'candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates), 2::bigint, 'unmatched exchanges retain pending evidence');
select extensions.ok((select pg_catalog.bool_and(pg_catalog.octet_length(nonce_digest) = 32 and pg_catalog.octet_length(start_own_token_digest) = 32 and pg_catalog.octet_length(start_peer_token_digest) = 32) from private.encounter_candidates), 'unresolved storage also uses only token and nonce digests');
select extensions.ok(not exists (select 1 from pg_catalog.pg_attribute as a where a.attrelid in ('private.encounters'::regclass, 'private.encounter_views'::regclass, 'private.consumed_nonces'::regclass) and a.attnum > 0 and not a.attisdropped and a.attname::text ~ '(token|observed|uploaded|created|location|latitude|longitude)' ), 'confirmed and consumed rows have no tokens observation times or location');

-- A confirmed third-party exchange using the same nonce cannot consume another pair.
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('victim exchange pending', pg_catalog.jsonb_build_array(receipts_test.receipt(900, 1,
    null, 120, (select start_seconds from receipts_test.clock)+120)), array['candidate']);
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000003","role":"authenticated"}';
select receipts_test.expect('third account reuses pending exchange nonce', pg_catalog.jsonb_build_array(pg_catalog.jsonb_set(
    receipts_test.receipt(900, 3, null, 120, (select start_seconds from receipts_test.clock)+120, null, false, false, 4),
    '{role}', '"central"'::jsonb)), array['candidate']);
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000004","role":"authenticated"}';
select receipts_test.expect('third-party reuse can confirm its own exchange', pg_catalog.jsonb_build_array(
    receipts_test.receipt(900, 4, null, 120, (select start_seconds from receipts_test.clock)+120, null, false, false, 3)),
    array['resolved']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates
    where uploader_id = receipts_test.user_id(1) and nonce_digest = receipts_test.digest(900)), 1::bigint,
    'third-party resolution leaves victim evidence pending');
select extensions.is((select pg_catalog.count(*) from private.consumed_nonces
    where exchange_digest = receipts_test.exchange_digest(900)), 0::bigint, 'victim token pair has no tombstone');
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('victim still confirms after third-party nonce consumption', pg_catalog.jsonb_build_array(
    receipts_test.receipt(900, 2, null, 120, (select start_seconds from receipts_test.clock)+120)), array['resolved']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 2::bigint, 'both independent exchanges confirm');
select extensions.is((select pg_catalog.count(*) from private.consumed_nonces), 2::bigint,
    'same nonce has separate token-bound tombstones');
select extensions.is(receipts_test.exchange_digest(900, 1, 2), receipts_test.exchange_digest(900, 2, 1),
    'sorting the start digests makes both reciprocal tombstone keys identical');
select extensions.is(receipts_test.exchange_digest(900), pg_catalog.sha256(receipts_test.digest(900)
    || least(pg_catalog.sha256(pg_catalog.decode(receipts_test.token(1, (select start_seconds from receipts_test.clock)), 'hex')),
             pg_catalog.sha256(pg_catalog.decode(receipts_test.token(2, (select start_seconds from receipts_test.clock)), 'hex')))
    || greatest(pg_catalog.sha256(pg_catalog.decode(receipts_test.token(1, (select start_seconds from receipts_test.clock)), 'hex')),
                pg_catalog.sha256(pg_catalog.decode(receipts_test.token(2, (select start_seconds from receipts_test.clock)), 'hex')))),
    'tombstone key includes the nonce hash and both sorted start hashes');

-- Reusing another pair's prior nonce cannot remove its originals or joined evidence.
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('victim prior central and joined pending', pg_catalog.jsonb_build_array(
    receipts_test.receipt(910, 1), receipts_test.receipt(911, 1, (select start_seconds from receipts_test.clock)+120,
        120, null, 910)), array['candidate','candidate']);
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('victim prior peripheral pending', pg_catalog.jsonb_build_array(receipts_test.receipt(910, 2)),
    array['candidate']);
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000003","role":"authenticated"}';
select receipts_test.expect('third account attempts unrelated prior reference', pg_catalog.jsonb_build_array(
    receipts_test.receipt(912, 3, (select start_seconds from receipts_test.clock)+120, 120, null, 910, false, false, 1)),
    array['candidate']);
select receipts_test.expect('third account reuses victim prior as its own nonce', pg_catalog.jsonb_build_array(pg_catalog.jsonb_set(
    receipts_test.receipt(910, 3, null, 120, (select start_seconds from receipts_test.clock)+120, null, false, false, 4),
    '{role}', '"central"'::jsonb)), array['candidate']);
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000004","role":"authenticated"}';
select receipts_test.expect('unrelated prior nonce reuse resolves only third-party receipts', pg_catalog.jsonb_build_array(
    receipts_test.receipt(910, 4, null, 120, (select start_seconds from receipts_test.clock)+120, null, false, false, 3)),
    array['resolved']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates
    where uploader_id in (receipts_test.user_id(1), receipts_test.user_id(2))), 3::bigint,
    'victim originals and joined half survive prior nonce reuse');
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('victim second exchange confirms after prior nonce reuse', pg_catalog.jsonb_build_array(
    receipts_test.receipt(911, 2, (select start_seconds from receipts_test.clock)+120, 120, null, 910)), array['resolved']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 2::bigint, 'victim second exchange is retained');
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates), 1::bigint,
    'resolution retains the unrelated prior-reference receipt');
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000003","role":"authenticated"}';
select receipts_test.expect('unrelated prior reference stays candidate after victim consumption', pg_catalog.jsonb_build_array(
    receipts_test.receipt(912, 3, (select start_seconds from receipts_test.clock)+120, 120, null, 910, false, false, 1)),
    array['candidate']);
reset role;

-- Both pending dates of one pair confirm in one call, regardless of digest order.
select receipts_test.reset_evidence();
select receipts_test.seed_token(side, (select current_seconds from receipts_test.clock) - age_seconds + gap)
from pg_catalog.generate_series(1,2) as side
cross join (values (90000), (3600)) as ages(age_seconds)
cross join (values (0), (120)) as gaps(gap);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('two dates central halves pending', pg_catalog.jsonb_build_array(
    receipts_test.receipt(940, 1, (select current_seconds from receipts_test.clock)-90000, 120,
        (select current_seconds from receipts_test.clock)-89880),
    receipts_test.receipt(941, 1, (select current_seconds from receipts_test.clock)-3600, 120,
        (select current_seconds from receipts_test.clock)-3480)), array['candidate','candidate']);
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('both dates peripheral halves resolve', pg_catalog.jsonb_build_array(
    receipts_test.receipt(941, 2, (select current_seconds from receipts_test.clock)-3600, 120,
        (select current_seconds from receipts_test.clock)-3480),
    receipts_test.receipt(940, 2, (select current_seconds from receipts_test.clock)-90000, 120,
        (select current_seconds from receipts_test.clock)-89880)), array['resolved','resolved']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 2::bigint, 'both pending encounters survive');
select extensions.is((select pg_catalog.count(distinct day_a) from private.encounters), 2::bigint,
    'the two encounters retain different first-viewer dates');
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates), 0::bigint,
    'only the two matched exchanges are erased');

-- The exact same receipts produce the same per-receipt statuses in either batch order.
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('order A counterpart', pg_catalog.jsonb_build_array(receipts_test.receipt(950, 2,
    null, 120, (select start_seconds from receipts_test.clock)+120)), array['candidate']);
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('order A receipts', pg_catalog.jsonb_build_array(receipts_test.receipt(951, 1),
    receipts_test.receipt(950, 1, null, 120, (select start_seconds from receipts_test.clock)+120),
    receipts_test.receipt(952, 1, null, 0, null, null, false, false, 3)), array['candidate','resolved','candidate']);
reset role;
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('order B counterpart', pg_catalog.jsonb_build_array(receipts_test.receipt(950, 2,
    null, 120, (select start_seconds from receipts_test.clock)+120)), array['candidate']);
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('order B receipts', pg_catalog.jsonb_build_array(
    receipts_test.receipt(952, 1, null, 0, null, null, false, false, 3),
    receipts_test.receipt(950, 1, null, 120, (select start_seconds from receipts_test.clock)+120),
    receipts_test.receipt(951, 1)), array['candidate','resolved','candidate']);
reset role;
select extensions.is((select statuses from receipts_test.results where label = 'order A receipts'),
    (select array[statuses[3], statuses[2], statuses[1]] from receipts_test.results where label = 'order B receipts'),
    'normalizing batch order leaves identical receipt statuses');
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates), 2::bigint,
    'both orders leave the unmatched receipts pending');

-- Keep expired candidates for 300 seconds so a skewed retry cannot recreate them.
select receipts_test.reset_evidence();
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('expiry grace initial receipt', pg_catalog.jsonb_build_array(receipts_test.receipt(970, 1)),
    array['candidate']);
reset role;
update private.encounter_candidates set expires_at = pg_catalog.now() - interval '299 seconds';
set local role authenticated;
select receipts_test.expect('fresh insertion within expiry grace', pg_catalog.jsonb_build_array(receipts_test.receipt(971, 1)),
    array['candidate']);
select receipts_test.expect('skewed retry remains expired within grace', pg_catalog.jsonb_build_array(receipts_test.receipt(970, 1)),
    array['expired']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates
    where nonce_digest = receipts_test.digest(970)), 1::bigint, 'expired row is kept through the grace period');
update private.encounter_candidates set expires_at = pg_catalog.now() - interval '300 seconds'
where nonce_digest = receipts_test.digest(970);
set local role authenticated;
select receipts_test.expect('fresh insertion at expiry grace boundary', pg_catalog.jsonb_build_array(receipts_test.receipt(972, 1)),
    array['candidate']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates
    where nonce_digest = receipts_test.digest(970)), 0::bigint, 'expired row is removable at the 300-second boundary');
select extensions.is((select pg_catalog.count(*) from private.encounters), 0::bigint,
    'grace-retained evidence never authorizes a resolution');
-- Keep a confirmed encounter as well as pending evidence for deletion cascades.
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000002","role":"authenticated"}';
select receipts_test.expect('deletion cascade counterpart', pg_catalog.jsonb_build_array(receipts_test.receipt(980, 2,
    null, 120, (select start_seconds from receipts_test.clock)+120)), array['candidate']);
set local "request.jwt.claims" = '{"sub":"cccccccc-0000-0000-0000-000000000001","role":"authenticated"}';
select receipts_test.expect('deletion cascade resolution', pg_catalog.jsonb_build_array(receipts_test.receipt(980, 1,
    null, 120, (select start_seconds from receipts_test.clock)+120)), array['resolved']);
reset role;
select extensions.is((select pg_catalog.count(*) from private.encounters), 1::bigint, 'confirmed encounter exists before deletion');
select extensions.is((select pg_catalog.count(*) from private.encounter_views), 2::bigint, 'both views exist before deletion');
select extensions.ok((select pg_catalog.bool_and(safe_shape) from receipts_test.results), 'every response has only caller receipt identity and status in input order');

delete from auth.users where id = receipts_test.user_id(1);
select extensions.is((select pg_catalog.count(*) from private.encounters), 0::bigint, 'account deletion cascades mutual encounters');
select extensions.is((select pg_catalog.count(*) from private.encounter_views), 0::bigint, 'account deletion cascades mutual views');
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates), 0::bigint, 'account deletion cascades unresolved pair evidence');
select * from extensions.finish();

rollback;
