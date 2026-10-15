begin;
create extension if not exists pgtap with schema extensions;
create schema sessions_qr_test;
grant usage on schema sessions_qr_test to anon, authenticated, service_role;
grant execute on all functions in schema extensions to anon, authenticated, service_role;

create function sessions_qr_test.id(n integer)
returns uuid language sql immutable set search_path = '' as $$
    select ('ffffffff-0000-0000-0000-' || pg_catalog.lpad(n::text, 12, '0'))::uuid;
$$;
create function sessions_qr_test.as_caller(caller uuid, statement text)
returns jsonb language plpgsql set search_path = '' as $$
declare result jsonb;
begin
    begin
        set local role authenticated;
        perform pg_catalog.set_config('request.jwt.claim.sub', '', true);
        perform pg_catalog.set_config('request.jwt.claims',
            pg_catalog.jsonb_build_object('sub', caller, 'role', 'authenticated')::text, true);
        execute 'select ' || statement into result;
    exception when others then
        reset role;
        raise;
    end;
    reset role;
    return result;
end;
$$;
create function sessions_qr_test.as_caller_void(caller uuid, statement text)
returns void language plpgsql set search_path = '' as $$
begin
    begin
        set local role authenticated;
        perform pg_catalog.set_config('request.jwt.claim.sub', '', true);
        perform pg_catalog.set_config('request.jwt.claims',
            pg_catalog.jsonb_build_object('sub', caller, 'role', 'authenticated')::text, true);
        execute 'select ' || statement;
    exception when others then
        reset role;
        raise;
    end;
    reset role;
end;
$$;
create function sessions_qr_test.expect_error(statement text, code text, fields text, description text)
returns text language plpgsql set search_path = pg_catalog, extensions as $$
declare actual_state text; actual_message text; actual_detail text;
begin
    begin execute statement;
    exception when others then
        get stacked diagnostics actual_state = returned_sqlstate,
            actual_message = message_text, actual_detail = pg_exception_detail;
        return extensions.is(pg_catalog.jsonb_build_array(actual_state, actual_message, coalesce(actual_detail, '')),
            pg_catalog.jsonb_build_array('P0001'::text, code, fields), description);
    end;
    return extensions.fail(description || ': expected exception');
end;
$$;
create table sessions_qr_test.results (label text primary key, value jsonb not null);
create table sessions_qr_test.clock (seconds bigint not null);
insert into sessions_qr_test.clock select pg_catalog.floor(extract(epoch from pg_catalog.now()))::bigint;
create table sessions_qr_test.rpc (signature text primary key, call text not null, argument_names text[]);
insert into sessions_qr_test.rpc values
    ('public.start_session()', 'public.start_session()', null),
    ('public.stop_session()', 'public.stop_session()', null),
    ('public.get_own_session()', 'public.get_own_session()', null),
    ('public.issue_qr_code()', 'public.issue_qr_code()', null),
    ('public.cancel_qr_code()', 'public.cancel_qr_code()', null),
    ('public.redeem_qr_code(text)', 'public.redeem_qr_code(''bad'')', array['code']);
create function sessions_qr_test.issue(n integer, label text)
returns void language sql set search_path = '' as $$
    insert into sessions_qr_test.results values ($2,
        sessions_qr_test.as_caller(sessions_qr_test.id($1), 'public.issue_qr_code()'));
$$;
create function sessions_qr_test.redeem(n integer, label text)
returns jsonb language sql set search_path = '' as $$
    select sessions_qr_test.as_caller(sessions_qr_test.id(n), pg_catalog.format('public.redeem_qr_code(%L)',
        (select r.value->>'code' from sessions_qr_test.results as r where r.label = $2)));
$$;
create function sessions_qr_test.unavailable(n integer, label text, description text)
returns text language plpgsql set search_path = '' as $$
begin
    return sessions_qr_test.expect_error(pg_catalog.format('select sessions_qr_test.redeem(%s, %L)', n, label),
        'not_found', '', description);
end;
$$;
create function sessions_qr_test.receipt(side integer)
returns jsonb language sql stable set search_path = '' as $$
    select pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
        'id', sessions_qr_test.id(100 + side), 'protocol_version', 1,
        'role', case when side = 1 then 'central' else 'peripheral' end,
        'exchange_nonce', pg_catalog.repeat('ab', 16),
        'start', pg_catalog.jsonb_build_object(
            'own_token', (select r.value->'windows'->0->>'token' from sessions_qr_test.results as r where r.label = 'tokens-' || side),
            'peer_token', (select r.value->'windows'->0->>'token' from sessions_qr_test.results as r where r.label = 'tokens-' || (3 - side)),
            'observed_at', greatest(
                (select (r.value->>'starts_at')::bigint from sessions_qr_test.results as r where r.label = 'new-start'),
                (select (r.value->>'starts_at')::bigint from sessions_qr_test.results as r where r.label = 'peer-start'))),
        'observed_duration', 0, 'session_flag', true, 'is_final_evidence', true));
$$;

insert into auth.users (id, aud, role, email)
select sessions_qr_test.id(n), 'authenticated', 'authenticated', 'session-qr-' || n || '@example.invalid'
from pg_catalog.generate_series(1, 12) as g(n);
insert into private.profiles (user_id, display_name, introduction, age_18_declared, terms_version, privacy_version, discovery_on, moderation_state)
select sessions_qr_test.id(n), 'Name', 'Introduction', true, 'draft', 'draft', n <> 7,
    case n when 5 then 'suspended' when 6 then 'hidden' else 'active' end
from pg_catalog.generate_series(1, 11) as g(n) where n <> 3;
insert into private.notification_preferences (user_id, time_zone)
select sessions_qr_test.id(n), case n when 1 then 'Pacific/Kiritimati' when 2 then 'Etc/GMT+12' else 'UTC' end
from pg_catalog.generate_series(1, 11) as g(n) where n not in (3, 4);
insert into private.interests values ('sessions-qr-fixture', '試験', 'Test', 9999);
insert into private.user_interests (user_id, interest_id)
select sessions_qr_test.id(n), 'sessions-qr-fixture' from pg_catalog.generate_series(1, 11) as g(n) where n <> 3;
insert into private.external_links (owner_id, source, url, title, visibility)
select sessions_qr_test.id(n), 'website', 'https://example.invalid/', 'Fixture', 'private'
from pg_catalog.generate_series(1, 11) as g(n) where n <> 3;
delete from auth.users where id = sessions_qr_test.id(12);

-- Every row-producing assertion below has a fixed cardinality. The plan is
-- 24 RPC metadata + 5 schema + 18 Live + 12 Ready + 3 Discovery +
-- 114 existing behavior + 6 lock/clock predicates + 17 waiter regressions + 9 QR wall-clock checks.
select extensions.plan(208);

select extensions.ok(p.prosecdef and 'search_path=""' = any(p.proconfig), f.signature || ' has the definer boundary')
from sessions_qr_test.rpc as f join pg_catalog.pg_proc as p on p.oid = f.signature::regprocedure;
select extensions.is(p.proargnames, f.argument_names, f.signature || ' has exact parameter names')
from sessions_qr_test.rpc as f join pg_catalog.pg_proc as p on p.oid = f.signature::regprocedure;
select extensions.is(pg_catalog.format_type(p.prorettype, null), 'jsonb', f.signature || ' returns JSON')
from sessions_qr_test.rpc as f join pg_catalog.pg_proc as p on p.oid = f.signature::regprocedure;
select extensions.ok(pg_catalog.has_function_privilege('authenticated', f.signature, 'execute'), f.signature || ' permits authenticated')
from sessions_qr_test.rpc as f;
select extensions.ok(c.relrowsecurity, 'QR has RLS') from pg_catalog.pg_class as c where c.oid = 'private.qr_codes'::regclass;
select extensions.is((select pg_catalog.count(*) from pg_catalog.pg_policy where polrelid = 'private.qr_codes'::regclass),
    0::bigint, 'QR has no client policies');
select extensions.is((select pg_catalog.array_agg(a.attname::text order by a.attnum) from pg_catalog.pg_attribute as a
    where a.attrelid = 'private.qr_codes'::regclass and a.attnum > 0 and not a.attisdropped),
    array['code_digest', 'issuer_id', 'expires_at'], 'QR stores only digest, issuer and expiry');
select extensions.ok(exists (select 1 from pg_catalog.pg_index as i where i.indexrelid = 'private.sessions_end_idx'::regclass
    and pg_catalog.pg_get_expr(i.indexprs, i.indrelid) = 'LEAST(expires_at, stopped_at)'), 'session cleanup indexes the earlier end');
select extensions.ok(pg_catalog.to_regclass('private.qr_codes_expiry_idx') is not null, 'QR expiry is indexed');

select sessions_qr_test.expect_error(pg_catalog.format('select sessions_qr_test.as_caller(%L::uuid, %L)', caller, f.call),
    'not_authenticated', '', f.signature || ' rejects ' || label)
from sessions_qr_test.rpc as f cross join (values
    (null::uuid, 'missing caller'), (sessions_qr_test.id(99), 'unknown caller'), (sessions_qr_test.id(12), 'deleted caller')) as c(caller, label);
select sessions_qr_test.expect_error(pg_catalog.format('select sessions_qr_test.as_caller(%L::uuid, %L)', sessions_qr_test.id(n), f.call),
    'account_not_ready', '', f.signature || ' requires readiness for fixture ' || n)
from sessions_qr_test.rpc as f cross join pg_catalog.generate_series(3, 6) as g(n)
where f.signature in ('public.start_session()', 'public.issue_qr_code()', 'public.redeem_qr_code(text)');
select sessions_qr_test.expect_error(pg_catalog.format('select sessions_qr_test.as_caller(%L::uuid, %L)', sessions_qr_test.id(7), f.call),
    'prerequisite_missing', 'discovery', f.signature || ' requires discovery after readiness')
from sessions_qr_test.rpc as f where f.signature in ('public.start_session()', 'public.issue_qr_code()', 'public.redeem_qr_code(text)');

select extensions.is(sessions_qr_test.as_caller(sessions_qr_test.id(1), 'public.get_own_session()'), 'null'::jsonb, 'no session is JSON null');
select extensions.is(sessions_qr_test.as_caller(sessions_qr_test.id(1), 'public.stop_session()'), 'null'::jsonb, 'stop without session is JSON null');
insert into sessions_qr_test.results values ('start', sessions_qr_test.as_caller(sessions_qr_test.id(1), 'public.start_session()')),
    ('start-again', sessions_qr_test.as_caller(sessions_qr_test.id(1), 'public.start_session()'));
select extensions.is((select pg_catalog.array_agg(k order by k) from sessions_qr_test.results as r,
    lateral pg_catalog.jsonb_object_keys(r.value) as k where r.label = 'start'),
    array['expires_at', 'server_time', 'session_id', 'starts_at'], 'Session has exactly the four required keys');
select extensions.ok((select r.value - 'server_time' = s.value - 'server_time' from sessions_qr_test.results as r, sessions_qr_test.results as s
    where r.label = 'start' and s.label = 'start-again'), 'start returns the same active Session');
select extensions.is((select (value->>'expires_at')::bigint - (value->>'starts_at')::bigint from sessions_qr_test.results where label = 'start'),
    7200::bigint, 'new session lasts 7200 seconds');
select extensions.ok((select pg_catalog.bool_and(pg_catalog.jsonb_typeof(r.value->k) = 'number' and (r.value->>k) ~ '^[0-9]+$')
    from sessions_qr_test.results as r cross join (values ('starts_at'), ('expires_at'), ('server_time')) as f(k) where r.label = 'start'),
    'all Session times are whole JSON seconds');
select extensions.ok((select s.starts_at = pg_catalog.date_trunc('second', s.starts_at)
    and s.expires_at = s.starts_at + interval '7200 seconds' from private.sessions as s where s.user_id = sessions_qr_test.id(1)),
    'session ledger starts and expires at whole seconds');
select extensions.ok(sessions_qr_test.as_caller(sessions_qr_test.id(1), 'public.get_own_session()') - 'server_time' =
    (select value - 'server_time' from sessions_qr_test.results where label = 'start'), 'get returns the active Session');
do $$ begin
    for n in 1..18 loop perform sessions_qr_test.as_caller(sessions_qr_test.id(1), 'public.start_session()'); end loop;
end; $$;
select extensions.is((select pg_catalog.count(*) from private.sessions where user_id = sessions_qr_test.id(1)), 1::bigint, 'twenty starts create one active row');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events where user_id = sessions_qr_test.id(1) and bucket = 'start_session'),
    20::bigint, 'idempotent starts spend all twenty calls');
select sessions_qr_test.expect_error('select sessions_qr_test.as_caller(sessions_qr_test.id(1), ''public.start_session()'')',
    'rate_limited', '', 'the twenty-first start is rate limited');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events where user_id = sessions_qr_test.id(1) and bucket = 'start_session'),
    20::bigint, 'rejected start adds no event');
update private.account_limit_events set occurred_at = pg_catalog.now() - interval '1 hour'
where ctid = (select ctid from private.account_limit_events where user_id = sessions_qr_test.id(1) and bucket = 'start_session' limit 1);
select extensions.lives_ok('select sessions_qr_test.as_caller(sessions_qr_test.id(1), ''public.start_session()'')', 'start budget renews at the exact rolling-hour boundary');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events where user_id = sessions_qr_test.id(1) and bucket = 'start_session'),
    20::bigint, 'renewed start prunes the boundary event');
update private.profiles set moderation_state = 'hidden' where user_id = sessions_qr_test.id(1);
select extensions.ok(sessions_qr_test.as_caller(sessions_qr_test.id(1), 'public.get_own_session()') - 'server_time' =
    (select value - 'server_time' from sessions_qr_test.results where label = 'start'), 'get needs only a live account');
insert into sessions_qr_test.results values ('stop', sessions_qr_test.as_caller(sessions_qr_test.id(1), 'public.stop_session()'));
select extensions.ok((select r.value - 'server_time' = s.value - 'server_time' from sessions_qr_test.results as r, sessions_qr_test.results as s
    where r.label = 'start' and s.label = 'stop'), 'unready stop returns original ID, start and expiry');
select extensions.ok((select stopped_at is not null from private.sessions where user_id = sessions_qr_test.id(1)), 'stop stamps the ledger end');
select extensions.is(sessions_qr_test.as_caller(sessions_qr_test.id(1), 'public.stop_session()'), 'null'::jsonb, 'repeated stop is JSON null');
select extensions.is(sessions_qr_test.as_caller(sessions_qr_test.id(1), 'public.get_own_session()'), 'null'::jsonb, 'stopped session is inactive');
select extensions.is(sessions_qr_test.as_caller(sessions_qr_test.id(3), 'public.stop_session()'), 'null'::jsonb, 'stop succeeds without declarations');
select extensions.is(sessions_qr_test.as_caller(sessions_qr_test.id(3), 'public.get_own_session()'), 'null'::jsonb, 'get succeeds without declarations');
update private.profiles set moderation_state = 'active' where user_id = sessions_qr_test.id(1);
delete from private.account_limit_events where user_id = sessions_qr_test.id(1) and bucket = 'start_session';
insert into private.sessions (session_id, user_id, starts_at, expires_at)
select sessions_qr_test.id(400), sessions_qr_test.id(1), pg_catalog.to_timestamp(seconds::double precision) - interval '7200 seconds',
    pg_catalog.to_timestamp(seconds::double precision) from sessions_qr_test.clock;
select extensions.is(sessions_qr_test.as_caller(sessions_qr_test.id(1), 'public.get_own_session()'), 'null'::jsonb, 'expiry is exclusive even before cleanup');
insert into sessions_qr_test.results values ('new-start', sessions_qr_test.as_caller(sessions_qr_test.id(1), 'public.start_session()'));
select extensions.ok((select value->>'session_id' from sessions_qr_test.results where label = 'new-start') <>
    (select value->>'session_id' from sessions_qr_test.results where label = 'start'), 'ended session permits a new ID');

-- Actual RPC-created sessions qualify through the unchanged receipt classifier.
insert into sessions_qr_test.results values ('peer-start', sessions_qr_test.as_caller(sessions_qr_test.id(2), 'public.start_session()'));
insert into sessions_qr_test.results select 'tokens-' || n,
    sessions_qr_test.as_caller(sessions_qr_test.id(n), 'public.issue_token_batch()') from pg_catalog.generate_series(1, 2) as g(n);
select extensions.is(sessions_qr_test.as_caller(sessions_qr_test.id(1), pg_catalog.format('public.submit_receipts(%L::jsonb)',
    sessions_qr_test.receipt(1)))->0->>'status', 'candidate', 'session reciprocal first half waits');
select extensions.is(sessions_qr_test.as_caller(sessions_qr_test.id(2), pg_catalog.format('public.submit_receipts(%L::jsonb)',
    sessions_qr_test.receipt(2)))->0->>'status', 'resolved', 'server sessions resolve zero-duration reciprocal evidence');
select extensions.is((select kind from private.encounters where user_a = sessions_qr_test.id(1) and user_b = sessions_qr_test.id(2)),
    'session', 'RPC session ledger supplies authoritative kind');
select extensions.is((select pg_catalog.count(*) from private.encounter_views as v join private.encounters as e using (encounter_id)
    where e.user_a = sessions_qr_test.id(1) and e.user_b = sessions_qr_test.id(2) and v.revealed), 2::bigint, 'session confirmation reveals both views');

-- pgTAP uses one transaction/session. Assert the lock/clock order as well as
-- ledger rows whose starts follow transaction now, representing a lock waiter.
select extensions.ok(pg_catalog.strpos(p.prosrc, 'server_time := pg_catalog.clock_timestamp()') >
    pg_catalog.strpos(p.prosrc, 'for update;') and pg_catalog.strpos(p.prosrc, 'for update;') >
    pg_catalog.strpos(p.prosrc, 'pg_catalog.pg_advisory_xact_lock'), f.signature || ' samples wall time after account/profile locks')
from (values ('private.start_session()'), ('private.stop_session()')) as f(signature)
join pg_catalog.pg_proc as p on p.oid = f.signature::regprocedure;
select extensions.ok(p.prosrc ~ 's[.]stopped_at is null and s[.]expires_at > server_time'
    and p.prosrc !~ 's[.]starts_at <=', f.signature || ' matches every unstopped unexpired session without a stale start bound')
from (values ('private.start_session()'), ('private.stop_session()'), ('private.turn_discovery_off(uuid)')) as f(signature)
join pg_catalog.pg_proc as p on p.oid = f.signature::regprocedure;
select extensions.ok(pg_catalog.strpos(p.prosrc, 'private.turn_discovery_off(caller)') >
    pg_catalog.strpos(p.prosrc, 'for update;') and pg_catalog.strpos(p.prosrc, 'for update;') >
    pg_catalog.strpos(p.prosrc, 'pg_catalog.pg_advisory_xact_lock')
    and (select h.prosrc ~ 'server_time timestamptz := pg_catalog.clock_timestamp[(][)]'
        from pg_catalog.pg_proc as h where h.oid = 'private.turn_discovery_off(uuid)'::regprocedure),
    'discovery off samples wall time in its helper after account/profile locks')
from pg_catalog.pg_proc as p where p.oid = 'public.set_discovery(boolean)'::regprocedure;

insert into private.sessions (session_id, user_id, starts_at, expires_at)
values (sessions_qr_test.id(450), sessions_qr_test.id(8), pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp() + interval '1 hour');
select extensions.ok((select starts_at > pg_catalog.now() from private.sessions where session_id = sessions_qr_test.id(450)),
    'waiter fixture begins after transaction now');
insert into sessions_qr_test.results values ('waiter-start', sessions_qr_test.as_caller(sessions_qr_test.id(8), 'public.start_session()'));
select extensions.is((select value->>'session_id' from sessions_qr_test.results where label = 'waiter-start'),
    sessions_qr_test.id(450)::text, 'start reuses the row committed while a waiter was blocked');
select extensions.is((select pg_catalog.count(*) from private.sessions where user_id = sessions_qr_test.id(8)),
    1::bigint, 'waiting start does not create a second active row');
select extensions.ok((select (r.value->>'server_time')::bigint >= pg_catalog.floor(extract(epoch from s.starts_at))::bigint
    and (r.value->>'server_time')::bigint <= pg_catalog.floor(extract(epoch from pg_catalog.clock_timestamp()))::bigint
    from sessions_qr_test.results as r join private.sessions as s on s.session_id = sessions_qr_test.id(450)
    where r.label = 'waiter-start'), 'waiter response uses the current wall clock');
insert into sessions_qr_test.results values ('waiter-stop', sessions_qr_test.as_caller(sessions_qr_test.id(8), 'public.stop_session()'));
select extensions.is((select value->>'session_id' from sessions_qr_test.results where label = 'waiter-stop'),
    sessions_qr_test.id(450)::text, 'stop finds a session begun after transaction now');
select extensions.ok((select stopped_at >= starts_at and stopped_at <= pg_catalog.clock_timestamp()
    from private.sessions where session_id = sessions_qr_test.id(450)), 'stop stamps a wall time after the new start');
select extensions.is(sessions_qr_test.as_caller(sessions_qr_test.id(8), 'public.stop_session()'), 'null'::jsonb, 'waiter stop is idempotent');

with clock as materialized (select pg_catalog.clock_timestamp() - interval '1 millisecond' as t)
insert into private.sessions (session_id, user_id, starts_at, expires_at)
select sessions_qr_test.id(450 + n), sessions_qr_test.id(8), t + n * interval '1 microsecond', t + interval '1 hour'
from clock cross join pg_catalog.generate_series(1, 2) as g(n);
insert into sessions_qr_test.results values ('duplicate-stop', sessions_qr_test.as_caller(sessions_qr_test.id(8), 'public.stop_session()'));
select extensions.is((select value->>'session_id' from sessions_qr_test.results where label = 'duplicate-stop'),
    sessions_qr_test.id(452)::text, 'stop returns the latest of two active ledgers without a cardinality error');
select extensions.is((select pg_catalog.count(*) from private.sessions where session_id in (sessions_qr_test.id(451), sessions_qr_test.id(452))
    and stopped_at >= starts_at), 2::bigint, 'stop stamps both active ledgers');
select extensions.is((select pg_catalog.count(*) from private.sessions where user_id = sessions_qr_test.id(8)
    and stopped_at is null and expires_at > pg_catalog.clock_timestamp()), 0::bigint, 'duplicate stop leaves no running ledger');
select extensions.is(sessions_qr_test.as_caller(sessions_qr_test.id(8), 'public.stop_session()'), 'null'::jsonb, 'duplicate stop remains idempotent');

with clock as materialized (select pg_catalog.clock_timestamp() as t)
insert into private.sessions (session_id, user_id, starts_at, expires_at)
select sessions_qr_test.id(452 + n), sessions_qr_test.id(8), t, t + interval '1 hour'
from clock cross join pg_catalog.generate_series(1, 2) as g(n);
select sessions_qr_test.issue(8, 'waiter-off');
select sessions_qr_test.as_caller_void(sessions_qr_test.id(8), 'public.set_discovery(false)');
select extensions.is((select pg_catalog.count(*) from private.sessions where session_id in (sessions_qr_test.id(453), sessions_qr_test.id(454))
    and stopped_at >= starts_at), 2::bigint, 'discovery off stops both ledgers begun after transaction now');
select extensions.is((select pg_catalog.count(*) from private.sessions where user_id = sessions_qr_test.id(8)
    and stopped_at is null and expires_at > pg_catalog.clock_timestamp()), 0::bigint, 'waiting discovery off leaves no running session');
select extensions.is((select pg_catalog.count(*) from private.qr_codes where issuer_id = sessions_qr_test.id(8)), 0::bigint, 'waiting discovery off cancels QR atomically');
select extensions.is((select discovery_on from private.profiles where user_id = sessions_qr_test.id(8)), false, 'waiting discovery off persists the flag');
with clock as materialized (select pg_catalog.clock_timestamp() as t)
insert into private.sessions (session_id, user_id, starts_at, expires_at)
select sessions_qr_test.id(455), sessions_qr_test.id(8), t - interval '1 hour', t from clock;
select extensions.is(sessions_qr_test.as_caller(sessions_qr_test.id(8), 'public.stop_session()'), 'null'::jsonb, 'stop excludes an already expired unstopped ledger');
select extensions.ok((select stopped_at is null from private.sessions where session_id = sessions_qr_test.id(455)), 'stop preserves an expired ledger unchanged');
select sessions_qr_test.as_caller_void(sessions_qr_test.id(8), 'public.set_discovery(true)');
delete from private.account_limit_events where user_id = sessions_qr_test.id(8) and bucket in ('start_session', 'issue_qr_code');

-- Early stop, natural expiry and a stop after expiry all use the earlier end.
insert into private.sessions (session_id, user_id, starts_at, expires_at, stopped_at)
select sessions_qr_test.id(410 + n), sessions_qr_test.id(11), t - interval '50 hours',
    case when n = 2 then t - interval '47 hours' else t - interval '48 hours' end,
    case n when 1 then null when 2 then t - interval '48 hours' else t - interval '47 hours' end
from (select pg_catalog.to_timestamp(seconds::double precision) as t from sessions_qr_test.clock) as c,
    pg_catalog.generate_series(1, 3) as g(n);
insert into private.sessions (session_id, user_id, starts_at, expires_at)
select sessions_qr_test.id(414), sessions_qr_test.id(11), pg_catalog.to_timestamp(seconds::double precision) - interval '50 hours',
    pg_catalog.to_timestamp(seconds::double precision) - interval '48 hours' + interval '1 microsecond' from sessions_qr_test.clock;
select private.cleanup_expired_data((select pg_catalog.to_timestamp(seconds::double precision) - interval '1 microsecond' from sessions_qr_test.clock));
select extensions.is((select pg_catalog.count(*) from private.sessions where user_id = sessions_qr_test.id(11)), 4::bigint, 'ended ledgers survive just before 48 hours');
select private.cleanup_expired_data((select pg_catalog.to_timestamp(seconds::double precision) from sessions_qr_test.clock));
select extensions.is((select pg_catalog.count(*) from private.sessions where user_id = sessions_qr_test.id(11)), 1::bigint, 'all three end forms are deleted at 48 hours');
select extensions.ok(exists (select 1 from private.sessions where session_id = sessions_qr_test.id(414)), 'cleanup preserves a ledger inside 48 hours');
select private.cleanup_expired_data((select pg_catalog.to_timestamp(seconds::double precision) + interval '1 microsecond' from sessions_qr_test.clock));
select extensions.is((select pg_catalog.count(*) from private.sessions where user_id = sessions_qr_test.id(11)), 0::bigint, 'fractional historical end is honored exactly');
select sessions_qr_test.expect_error('select private.cleanup_expired_data(null)', 'invalid_input', 'cleanup_at', 'cleanup rejects a null clock');

select sessions_qr_test.issue(1, 'first');
select extensions.ok((select value->>'code' ~ '^[0-9a-f]{32}$' from sessions_qr_test.results where label = 'first'), 'issue returns sixteen bytes of lowercase hex');
select extensions.is((select pg_catalog.array_agg(k order by k) from sessions_qr_test.results as r,
    lateral pg_catalog.jsonb_object_keys(r.value) as k where r.label = 'first'), array['code', 'expires_at'], 'issue has exact wire keys');
select extensions.is((select (value->>'expires_at')::bigint from sessions_qr_test.results where label = 'first'),
    (select seconds + 120 from sessions_qr_test.clock), 'QR lasts 120 whole seconds');
select extensions.ok((select pg_catalog.jsonb_typeof(value->'expires_at') = 'number' and value->>'expires_at' ~ '^[0-9]+$'
    from sessions_qr_test.results where label = 'first'), 'QR expiry is a whole JSON second');
select extensions.ok((select q.code_digest = pg_catalog.sha256(pg_catalog.decode(r.value->>'code', 'hex'))
    and pg_catalog.octet_length(q.code_digest) = 32 and q.expires_at = (r.value->>'expires_at')::bigint
    from private.qr_codes as q, sessions_qr_test.results as r where q.issuer_id = sessions_qr_test.id(1) and r.label = 'first'),
    'storage is SHA-256 of decoded bytes with the same expiry');
select sessions_qr_test.issue(1, 'replacement');
select extensions.ok((select r.value->>'code' <> s.value->>'code' from sessions_qr_test.results as r, sessions_qr_test.results as s
    where r.label = 'first' and s.label = 'replacement'), 'replacement generates a fresh code');
select extensions.is((select pg_catalog.count(*) from private.qr_codes where issuer_id = sessions_qr_test.id(1)), 1::bigint, 'replacement leaves one outstanding code');
select sessions_qr_test.unavailable(2, 'first', 'replaced code is indistinguishable not_found');
select extensions.is(sessions_qr_test.as_caller(sessions_qr_test.id(1), 'public.cancel_qr_code()'), '{"cancelled":true}'::jsonb, 'cancel has exact JSON');
select extensions.is(sessions_qr_test.as_caller(sessions_qr_test.id(1), 'public.cancel_qr_code()'), '{"cancelled":true}'::jsonb, 'cancel is idempotent');
select sessions_qr_test.unavailable(2, 'replacement', 'cancelled code is indistinguishable not_found');
insert into private.qr_codes (code_digest, issuer_id, expires_at)
select pg_catalog.sha256(pg_catalog.decode(pg_catalog.repeat('cc', 16), 'hex')), sessions_qr_test.id(3), seconds + 120
from sessions_qr_test.clock;
select extensions.is(sessions_qr_test.as_caller(sessions_qr_test.id(3), 'public.cancel_qr_code()'), '{"cancelled":true}'::jsonb, 'cancel needs no ready profile');
select extensions.ok(not exists (select 1 from private.qr_codes where issuer_id = sessions_qr_test.id(3)), 'unready cancel removes the outstanding code');

-- Discovery-off changes all three resources atomically and preserves void API.
select sessions_qr_test.issue(1, 'off');
select sessions_qr_test.as_caller_void(sessions_qr_test.id(1), 'public.set_discovery(false)');
select extensions.ok((select not discovery_on from private.profiles where user_id = sessions_qr_test.id(1)), 'discovery off persists');
select extensions.is(sessions_qr_test.as_caller(sessions_qr_test.id(1), 'public.get_own_session()'), 'null'::jsonb, 'discovery off stops the active session');
select extensions.is(sessions_qr_test.as_caller(sessions_qr_test.id(1), 'public.stop_session()'), 'null'::jsonb, 'stop remains available with discovery off');
select extensions.ok((select stopped_at is not null from private.sessions
    where session_id = (select (value->>'session_id')::uuid from sessions_qr_test.results where label = 'new-start')), 'discovery off preserves the stopped ledger');
select extensions.is((select pg_catalog.count(*) from private.qr_codes where issuer_id = sessions_qr_test.id(1)), 0::bigint, 'discovery off deletes outstanding QR');
select sessions_qr_test.unavailable(2, 'off', 'discovery-off code is indistinguishable not_found');
select extensions.is(pg_catalog.format_type(p.prorettype, null), 'void', 'set_discovery keeps its void return')
from pg_catalog.pg_proc as p where p.oid = 'public.set_discovery(boolean)'::regprocedure;
select sessions_qr_test.as_caller_void(sessions_qr_test.id(1), 'public.set_discovery(true)');

-- Failed redemptions must leave the successful-transaction budget untouched.
delete from private.account_limit_events where bucket = 'redeem_qr_code';
select sessions_qr_test.expect_error(pg_catalog.format('select sessions_qr_test.as_caller(%L::uuid, %L)', sessions_qr_test.id(2),
    pg_catalog.format('public.redeem_qr_code(%L)', value)), 'invalid_input', 'code', label)
from (values (null::text, 'null code'), ('', 'empty code'), (pg_catalog.repeat('a', 31), 'short code'),
    (pg_catalog.repeat('a', 33), 'long code'), (pg_catalog.repeat('A', 32), 'uppercase code'),
    (pg_catalog.repeat('g', 32), 'nonhex code'), (' ' || pg_catalog.repeat('a', 32), 'leading space'),
    (pg_catalog.repeat('a', 32) || ' ', 'trailing space'), ('EEQR1:' || pg_catalog.repeat('a', 32), 'payload rather than suffix'),
    (pg_catalog.repeat('a', 32) || chr(10), 'extra newline')) as f(value, label);
select sessions_qr_test.expect_error('select sessions_qr_test.as_caller(sessions_qr_test.id(2), ''public.redeem_qr_code(''''ffffffffffffffffffffffffffffffff'''')'')',
    'not_found', '', 'unknown well-formed code is indistinguishable not_found');
select sessions_qr_test.issue(1, 'self');
select sessions_qr_test.expect_error('select sessions_qr_test.redeem(1, ''self'')', 'invalid_input', 'code', 'live self-code names code');
select extensions.ok(exists (select 1 from private.qr_codes where issuer_id = sessions_qr_test.id(1)), 'self-scan leaves the code available');
update private.qr_codes set expires_at = (select seconds from sessions_qr_test.clock) where issuer_id = sessions_qr_test.id(1);
select sessions_qr_test.unavailable(2, 'self', 'QR is expired at exactly now equals expiry');
select sessions_qr_test.unavailable(1, 'self', 'expired self-code is unavailable rather than invalid');

select sessions_qr_test.issue(1, 'blocked');
insert into private.blocks (blocker_id, blocked_id, placed_day) values (sessions_qr_test.id(1), sessions_qr_test.id(2), (pg_catalog.now() at time zone 'UTC')::date);
select sessions_qr_test.unavailable(2, 'blocked', 'issuer-to-scanner block is indistinguishable not_found');
delete from private.blocks;
insert into private.blocks (blocker_id, blocked_id, placed_day) values (sessions_qr_test.id(2), sessions_qr_test.id(1), (pg_catalog.now() at time zone 'UTC')::date);
select sessions_qr_test.unavailable(2, 'blocked', 'scanner-to-issuer block is indistinguishable not_found');
delete from private.blocks;
update private.profiles set moderation_state = 'hidden' where user_id = sessions_qr_test.id(1);
select sessions_qr_test.unavailable(2, 'blocked', 'hidden issuer is indistinguishable not_found');
update private.profiles set moderation_state = 'suspended' where user_id = sessions_qr_test.id(1);
select sessions_qr_test.unavailable(2, 'blocked', 'suspended issuer is indistinguishable not_found');
update private.profiles set moderation_state = 'active', discovery_on = false where user_id = sessions_qr_test.id(1);
select sessions_qr_test.unavailable(2, 'blocked', 'issuer discovery gate applies even to an outstanding code');
update private.profiles set discovery_on = true where user_id = sessions_qr_test.id(1);
delete from private.notification_preferences where user_id = sessions_qr_test.id(1);
select sessions_qr_test.unavailable(2, 'blocked', 'unregistered issuer is indistinguishable not_found');
insert into private.notification_preferences (user_id, time_zone) values (sessions_qr_test.id(1), 'Pacific/Kiritimati');
delete from private.profiles where user_id = sessions_qr_test.id(1);
select sessions_qr_test.unavailable(2, 'blocked', 'undeclared issuer is indistinguishable not_found');
insert into private.profiles (user_id, display_name, introduction, age_18_declared, terms_version, privacy_version, discovery_on)
values (sessions_qr_test.id(1), 'Name', 'Introduction', true, 'draft', 'draft', true);
select extensions.is((select pg_catalog.count(*) from private.account_limit_events where bucket = 'redeem_qr_code'), 0::bigint,
    'malformed, self and every unavailable redemption spend no budget');
select extensions.is((select pg_catalog.count(*) from private.encounters where kind = 'qr'), 0::bigint, 'failed redemptions create no encounters');

-- A live code just inside its expiry is accepted, using each viewer's zone.
update private.qr_codes set expires_at = pg_catalog.floor(extract(epoch from pg_catalog.clock_timestamp()))::bigint + 2 where issuer_id = sessions_qr_test.id(1);
insert into sessions_qr_test.results values ('redemption', sessions_qr_test.redeem(2, 'blocked'));
select extensions.is((select pg_catalog.array_agg(k order by k) from sessions_qr_test.results as r,
    lateral pg_catalog.jsonb_object_keys(r.value) as k where r.label = 'redemption'), array['encounter_id'], 'redemption has exact wire keys');
select extensions.ok((select pg_catalog.jsonb_typeof(value->'encounter_id') = 'string'
    and value->>'encounter_id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    from sessions_qr_test.results where label = 'redemption'), 'redemption returns a lowercase UUID');
select extensions.is((select kind from private.encounters where encounter_id =
    (select (value->>'encounter_id')::uuid from sessions_qr_test.results where label = 'redemption')), 'qr', 'redemption creates QR kind');
select extensions.is((select pg_catalog.count(*) from private.encounter_views where encounter_id =
    (select (value->>'encounter_id')::uuid from sessions_qr_test.results where label = 'redemption') and revealed), 2::bigint, 'QR reveals both views');
select extensions.ok((select day_a = (pg_catalog.now() at time zone 'Pacific/Kiritimati')::date
    and day_b = (pg_catalog.now() at time zone 'Etc/GMT+12')::date and day_a <> day_b from private.encounters where kind = 'qr'),
    'each registered zone gives its own different redemption date');
select extensions.is((select pg_catalog.count(*) from private.qr_codes where issuer_id = sessions_qr_test.id(1)), 0::bigint, 'successful redemption consumes the code');
select sessions_qr_test.unavailable(2, 'blocked', 'used code is indistinguishable not_found');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events where user_id = sessions_qr_test.id(2) and bucket = 'redeem_qr_code'),
    1::bigint, 'only successful redemption spends a call');
update private.encounter_views set revealed = false, favorite = true where viewer_id = sessions_qr_test.id(1) and encounter_id =
    (select (value->>'encounter_id')::uuid from sessions_qr_test.results where label = 'redemption');
delete from private.encounter_views where viewer_id = sessions_qr_test.id(2) and encounter_id =
    (select (value->>'encounter_id')::uuid from sessions_qr_test.results where label = 'redemption');
select sessions_qr_test.issue(2, 'reverse');
insert into sessions_qr_test.results values ('redemption-again', sessions_qr_test.redeem(1, 'reverse'));
select extensions.ok((select r.value = s.value from sessions_qr_test.results as r, sessions_qr_test.results as s
    where r.label = 'redemption' and s.label = 'redemption-again'), 'same pair and day in reverse order returns the same encounter');
select extensions.is((select pg_catalog.count(*) from private.encounters where kind = 'qr'), 1::bigint, 'same-day redemption deduplicates');
select extensions.is((select pg_catalog.count(*) from private.encounter_views where revealed and encounter_id =
    (select (value->>'encounter_id')::uuid from sessions_qr_test.results where label = 'redemption')), 2::bigint, 'duplicate QR repairs and reveals both views');
select extensions.ok((select favorite from private.encounter_views where viewer_id = sessions_qr_test.id(1) and encounter_id =
    (select (value->>'encounter_id')::uuid from sessions_qr_test.results where label = 'redemption')), 'duplicate QR preserves favorite state');
select extensions.is((select pg_catalog.count(*) from private.encounters where kind = 'session'), 1::bigint, 'QR leaves the session encounter intact');

-- QR cleanup observes the same inclusive bigint expiry, independent of zone.
select sessions_qr_test.issue(1, 'cleanup');
set local time zone 'America/Los_Angeles';
select private.cleanup_expired_data((select pg_catalog.to_timestamp((value->>'expires_at')::double precision) - interval '1 microsecond'
    from sessions_qr_test.results where label = 'cleanup'));
select extensions.ok(exists (select 1 from private.qr_codes where issuer_id = sessions_qr_test.id(1)), 'QR survives just before expiry cleanup');
select private.cleanup_expired_data((select pg_catalog.to_timestamp((value->>'expires_at')::double precision)
    from sessions_qr_test.results where label = 'cleanup'));
select extensions.ok(not exists (select 1 from private.qr_codes where issuer_id = sessions_qr_test.id(1)), 'QR is removed exactly at expiry cleanup');
select sessions_qr_test.unavailable(2, 'cleanup', 'cleaned-up code is indistinguishable not_found');
set local time zone 'UTC';

do $$ begin
    for n in 1..30 loop perform sessions_qr_test.as_caller(sessions_qr_test.id(8), 'public.issue_qr_code()'); end loop;
end; $$;
select extensions.is((select pg_catalog.count(*) from private.account_limit_events where user_id = sessions_qr_test.id(8) and bucket = 'issue_qr_code'),
    30::bigint, 'thirty replacements spend the issue budget');
select extensions.is((select pg_catalog.count(*) from private.qr_codes where issuer_id = sessions_qr_test.id(8)), 1::bigint, 'thirty issues still leave one code');
insert into sessions_qr_test.results select 'rate-code', pg_catalog.jsonb_build_object('digest', pg_catalog.encode(code_digest, 'hex'), 'expires_at', expires_at)
from private.qr_codes where issuer_id = sessions_qr_test.id(8);
select sessions_qr_test.expect_error('select sessions_qr_test.as_caller(sessions_qr_test.id(8), ''public.issue_qr_code()'')',
    'rate_limited', '', 'the thirty-first issue is rate limited');
select extensions.ok((select r.value = pg_catalog.jsonb_build_object('digest', pg_catalog.encode(q.code_digest, 'hex'), 'expires_at', q.expires_at)
    from sessions_qr_test.results as r, private.qr_codes as q where r.label = 'rate-code' and q.issuer_id = sessions_qr_test.id(8)),
    'rejected replacement preserves the outstanding code');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events where user_id = sessions_qr_test.id(8) and bucket = 'issue_qr_code'),
    30::bigint, 'rejected issue adds no event');
update private.account_limit_events set occurred_at = pg_catalog.now() - interval '1 hour'
where ctid = (select ctid from private.account_limit_events where user_id = sessions_qr_test.id(8) and bucket = 'issue_qr_code' limit 1);
select extensions.lives_ok('select sessions_qr_test.as_caller(sessions_qr_test.id(8), ''public.issue_qr_code()'')', 'issue budget renews at the exact rolling-hour boundary');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events where user_id = sessions_qr_test.id(8) and bucket = 'issue_qr_code'),
    30::bigint, 'renewed issue prunes the boundary event');

do $$ declare issued jsonb; begin
    for n in 1..30 loop
        issued := sessions_qr_test.as_caller(sessions_qr_test.id(10), 'public.issue_qr_code()');
        perform sessions_qr_test.as_caller(sessions_qr_test.id(9), pg_catalog.format('public.redeem_qr_code(%L)', issued->>'code'));
    end loop;
end; $$;
select extensions.is((select pg_catalog.count(*) from private.account_limit_events where user_id = sessions_qr_test.id(9) and bucket = 'redeem_qr_code'),
    30::bigint, 'thirty successful redemptions spend the redeem budget');
select extensions.is((select pg_catalog.count(*) from private.encounters where kind = 'qr' and user_a = sessions_qr_test.id(9) and user_b = sessions_qr_test.id(10)),
    1::bigint, 'idempotent encounter returns still spend redeem calls');
select sessions_qr_test.issue(11, 'rate-redemption');
select sessions_qr_test.expect_error('select sessions_qr_test.redeem(9, ''rate-redemption'')', 'rate_limited', '', 'the thirty-first redeem is rate limited');
select extensions.ok(exists (select 1 from private.qr_codes where issuer_id = sessions_qr_test.id(11)), 'rate-limited redeem preserves the code');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events where user_id = sessions_qr_test.id(9) and bucket = 'redeem_qr_code'),
    30::bigint, 'rate-limited redeem adds no event');
select extensions.is((select pg_catalog.count(*) from private.encounters where user_a = sessions_qr_test.id(9) and user_b = sessions_qr_test.id(11)),
    0::bigint, 'rate-limited redeem creates no encounter');
select sessions_qr_test.expect_error('select sessions_qr_test.as_caller(sessions_qr_test.id(9), ''public.redeem_qr_code(''''ffffffffffffffffffffffffffffffff'''')'')',
    'not_found', '', 'unknown code remains not_found with an exhausted budget');
select extensions.lives_ok('select sessions_qr_test.redeem(2, ''rate-redemption'')', 'another scanner can redeem after a rate-limited failure');
select extensions.ok(not exists (select 1 from private.qr_codes where issuer_id = sessions_qr_test.id(11)), 'successful retry consumes code');
update private.account_limit_events set occurred_at = pg_catalog.now() - interval '1 hour'
where ctid = (select ctid from private.account_limit_events where user_id = sessions_qr_test.id(9) and bucket = 'redeem_qr_code' limit 1);
select sessions_qr_test.issue(11, 'renewed-redemption');
select extensions.lives_ok('select sessions_qr_test.redeem(9, ''renewed-redemption'')', 'redeem budget renews at the exact rolling-hour boundary');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events where user_id = sessions_qr_test.id(9) and bucket = 'redeem_qr_code'),
    30::bigint, 'renewed redemption prunes the boundary event');

select sessions_qr_test.issue(11, 'deleted');
insert into sessions_qr_test.results values ('deleted-start', sessions_qr_test.as_caller(sessions_qr_test.id(11), 'public.start_session()'));
delete from auth.users where id = sessions_qr_test.id(11);
select extensions.ok(not exists (select 1 from private.qr_codes where issuer_id = sessions_qr_test.id(11)), 'Auth deletion cascades QR');
select extensions.ok(not exists (select 1 from private.sessions where user_id = sessions_qr_test.id(11)), 'Auth deletion cascades sessions');
select sessions_qr_test.unavailable(2, 'deleted', 'deleted issuer code is indistinguishable not_found');
select extensions.ok(not exists (select 1 from private.account_limit_events where bucket in ('get_own_session', 'stop_session', 'cancel_qr_code', 'set_discovery')),
    'get, stop, cancel and discovery introduce no budgets');

-- One session cannot wait behind another session's row lock. Advance the
-- wall clock past a code that was live at transaction now, then verify the
-- post-lock clock path and that a failed redemption rolls back every write.
insert into private.qr_codes(code_digest,issuer_id,expires_at)
values (pg_catalog.sha256(pg_catalog.decode(pg_catalog.repeat('ce',16),'hex')),sessions_qr_test.id(1),
    pg_catalog.ceil(extract(epoch from pg_catalog.clock_timestamp()))::bigint + 1);
select extensions.ok((select expires_at > extract(epoch from pg_catalog.now()) from private.qr_codes
    where issuer_id=sessions_qr_test.id(1)), 'waiting QR was live at transaction now');
insert into sessions_qr_test.results values ('before-expiry-wait',pg_catalog.jsonb_build_array(
    (select pg_catalog.count(*) from private.encounters),
    (select pg_catalog.count(*) from private.account_limit_events where bucket='redeem_qr_code')));
select pg_catalog.pg_sleep(greatest(0,(select expires_at::numeric-extract(epoch from pg_catalog.clock_timestamp())+0.05
    from private.qr_codes where issuer_id=sessions_qr_test.id(1)))::double precision);
select sessions_qr_test.expect_error($q$select sessions_qr_test.as_caller(sessions_qr_test.id(2),
    'public.redeem_qr_code(''cececececececececececececececece'')')$q$,
    'not_found','','QR that expires while time advances is rejected by fresh wall time');
select extensions.ok(exists(select 1 from private.qr_codes where issuer_id=sessions_qr_test.id(1)),
    'expired redemption leaves the code for cleanup');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events where bucket='redeem_qr_code'),
    (select (value->>1)::bigint from sessions_qr_test.results where label='before-expiry-wait'), 'expired waiting QR spends no budget');
select extensions.is((select pg_catalog.count(*) from private.encounters),
    (select (value->>0)::bigint from sessions_qr_test.results where label='before-expiry-wait'), 'expired waiting QR creates no encounter');
select extensions.ok(pg_catalog.strpos(p.prosrc,'server_time := pg_catalog.clock_timestamp()')
        > pg_catalog.strpos(p.prosrc,'where q.code_digest = code_hash and q.issuer_id = issuer for update;')
    and pg_catalog.strpos(p.prosrc,'code_deadline <= server_seconds')>0
    and pg_catalog.strpos(p.prosrc,'pg_catalog.now()')=0,
    'redemption reads the wall clock after all locks and the code row, including expiry equality')
from pg_catalog.pg_proc as p where p.oid='private.redeem_qr_code(text)'::regprocedure;
select extensions.ok(pg_catalog.strpos(p.prosrc,'server_seconds, server_seconds, server_time')>0,
    'redemption passes the same fresh clock to both encounter dates and scheduling')
from pg_catalog.pg_proc as p where p.oid='private.redeem_qr_code(text)'::regprocedure;
-- Passing a clock across a date boundary pins the shared confirmation helper's
-- date/scheduling behavior independently of this transaction's frozen now.
delete from private.encounters where user_a=sessions_qr_test.id(1) and user_b=sessions_qr_test.id(2) and kind='qr';
insert into sessions_qr_test.results values ('dated-confirmation',pg_catalog.to_jsonb(private.confirm_encounter(
    sessions_qr_test.id(1),sessions_qr_test.id(2),'qr',1791937800,1791937800,timestamptz '2026-10-14 00:30:00+00')));
select extensions.ok((select day_a=date '2026-10-14' and day_b=date '2026-10-13'
    from private.encounters where encounter_id=(select (value #>> '{}')::uuid
        from sessions_qr_test.results where label='dated-confirmation')),
    'confirmation uses the supplied redemption clock for both local encounter dates');
select extensions.ok((select pg_catalog.bool_and(v.reveal_report_day=private.next_report_day(v.viewer_id,
        timestamptz '2026-10-14 00:30:00+00'))
    from private.encounter_views as v where v.encounter_id=(select (value #>> '{}')::uuid
        from sessions_qr_test.results where label='dated-confirmation')),
    'the same supplied redemption clock assigns both report dates');
select * from extensions.finish();
rollback;
