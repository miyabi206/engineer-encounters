begin;
create extension if not exists pgtap with schema extensions;
create schema daily_test;
grant usage on schema daily_test to anon, authenticated, service_role;

create function daily_test.id(n integer)
returns uuid language sql immutable set search_path = '' as $$
    select ('ffffffff-0000-0000-0000-' || pg_catalog.lpad(n::text, 12, '0'))::uuid;
$$;
create function daily_test.day()
returns date language sql stable set search_path = '' as $$ select (pg_catalog.now() at time zone 'UTC')::date; $$;
create function daily_test.due_day()
returns date language sql stable set search_path = '' as $$
    select daily_test.day() - case when (pg_catalog.now() at time zone 'UTC')::time < time '21:00' then 1 else 0 end;
$$;

insert into auth.users (id) select daily_test.id(n) from pg_catalog.generate_series(1, 230) as n;
insert into private.profiles (user_id, age_18_declared, terms_version, privacy_version, discovery_on, display_name)
select daily_test.id(n), true, 'draft', 'draft', true, 'Owner' || n from pg_catalog.generate_series(1, 230) as n;
insert into private.notification_preferences (user_id, time_zone)
select daily_test.id(n), 'UTC' from pg_catalog.generate_series(1, 229) as n;
insert into private.interests (interest_id, label_ja, label_en) values ('daily-a', 'a', 'a');
insert into private.user_interests (user_id, interest_id)
select daily_test.id(n), 'daily-a' from pg_catalog.generate_series(1, 230) as n;
insert into private.user_purposes (user_id, purpose)
select daily_test.id(n), 'discovery' from pg_catalog.generate_series(1, 230) as n;
insert into private.field_visibility (owner_id, field, level)
select daily_test.id(n), f, 'everyone_eligible' from pg_catalog.generate_series(1, 230) as n
cross join pg_catalog.unnest(array['display_name', 'interests']) as f;

create function daily_test.as_caller(viewer uuid, statement text)
returns jsonb language plpgsql set search_path = '' as $$
declare result jsonb;
begin
    begin
        set local role authenticated;
        perform pg_catalog.set_config('request.jwt.claim.sub', '', true);
        perform pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object('sub', viewer, 'role', 'authenticated')::text, true);
        execute statement into result;
    exception when others then reset role; raise;
    end;
    reset role;
    return result;
end;
$$;
create function daily_test.as_operator(viewer uuid, enabled boolean)
returns jsonb language plpgsql set search_path = '' as $$
declare result jsonb;
begin
    begin
        set local role service_role;
        result := service.set_demo_reveal_enabled(viewer, enabled);
    exception when others then reset role; raise;
    end;
    reset role;
    return result;
end;
$$;
-- SQL void is converted to JSON null by the RPC transport. Exercise the void
-- RPC with PERFORM (to_jsonb(void) would serialize PostgreSQL's empty text).
create function daily_test.zone_as_caller(viewer uuid, zone_name text)
returns jsonb language plpgsql set search_path = '' as $$
begin
    begin
        set local role authenticated;
        perform pg_catalog.set_config('request.jwt.claim.sub', '', true);
        perform pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object('sub', viewer, 'role', 'authenticated')::text, true);
        perform public.register_time_zone(zone_name);
    exception when others then reset role; raise;
    end;
    reset role;
    return null;
end;
$$;
create function daily_test.expect_error(statement text, code text, detail text, description text)
returns text language plpgsql set search_path = pg_catalog, extensions as $$
declare actual_state text; actual_code text; actual_detail text;
begin
    begin execute statement;
    exception when others then
        get stacked diagnostics actual_state = returned_sqlstate, actual_code = message_text, actual_detail = pg_exception_detail;
        return extensions.is(pg_catalog.jsonb_build_array(actual_state, actual_code, coalesce(actual_detail, '')),
            pg_catalog.jsonb_build_array('P0001', code, detail), description);
    end;
    return extensions.fail(description || ': expected exception');
end;
$$;
create function daily_test.error_call(viewer_number integer, statement text, code text, detail text, description text)
returns text language sql set search_path = '' as $$
    select daily_test.expect_error(pg_catalog.format('select daily_test.as_caller(%L::uuid, %L)',
        daily_test.id(viewer_number), statement), code, detail, description);
$$;
create function daily_test.reset()
returns void language plpgsql set search_path = '' as $$
begin
    delete from private.encounters where user_a = daily_test.id(1);
    delete from private.report_deliveries where user_id between daily_test.id(1) and daily_test.id(230);
    delete from private.blocks where blocker_id between daily_test.id(1) and daily_test.id(230);
    delete from private.account_limit_events where user_id between daily_test.id(1) and daily_test.id(230);
    update private.notification_preferences set time_zone = 'UTC', report_hour = 21, report_minute = 0, notifications_enabled = true
    where user_id between daily_test.id(1) and daily_test.id(230);
    update private.profiles set discovery_on = true, moderation_state = 'active'
    where user_id between daily_test.id(1) and daily_test.id(230);
    update private.field_visibility set level = 'everyone_eligible'
    where owner_id between daily_test.id(1) and daily_test.id(230);
    update private.server_settings set environment = 'local', demo_reveal_enabled = true, operator_account_id = daily_test.id(229) where singleton;
end;
$$;
create function daily_test.waiting(n integer, owner_number integer default 2, encounter_day date default daily_test.day(),
    assigned_day date default daily_test.due_day(), peer_day date default null)
returns void language sql set search_path = '' as $$
    insert into private.encounters (encounter_id, user_a, user_b, kind, day_a, day_b)
    values (daily_test.id(1000 + n), daily_test.id(1), daily_test.id(owner_number), 'ambient', encounter_day, coalesce(peer_day, encounter_day));
    insert into private.encounter_views (encounter_id, viewer_id, revealed, reveal_report_day)
    values (daily_test.id(1000 + n), daily_test.id(1), false, assigned_day);
$$;
create function daily_test.card(n integer, owner_number integer default 2, encounter_day date default daily_test.day(), favorite boolean default false)
returns jsonb language sql immutable set search_path = '' as $$
    select pg_catalog.jsonb_build_object('encounter_id', daily_test.id(1000 + n), 'kind', 'ambient', 'day', encounter_day,
        'display_name', 'Owner' || owner_number, 'interests', array['daily-a'], 'favorite', favorite, 'shared_interest_ids', array['daily-a']);
$$;

grant execute on all functions in schema daily_test to anon, authenticated, service_role;
revoke all on function daily_test.reset(), daily_test.waiting(integer, integer, date, date, date) from public, anon, authenticated, service_role;
grant execute on all functions in schema extensions to anon, authenticated, service_role;

-- Hand-counted sections: catalog 66; settings/errors 41; scheduling 32;
-- DST/travel/settings changes 27; daily/feed 30; demo/operator 25 = 221.
select extensions.plan(221);

-- Catalog: 6 RPCs x 4 signature properties, 3 helpers x 5 = 39;
-- 2 tables x 5 = 10; columns 3, Cron 7, deployment defaults 3,
-- service grants 3, local instant volatility 1 = 66.
create temporary table daily_rpcs (signature text, names text[]);
insert into daily_rpcs values
    ('public.get_report_settings()', null), ('public.set_report_time(integer,integer)', array['hour','minute']),
    ('public.set_notifications_enabled(boolean)', array['enabled']), ('public.get_daily_report()', null),
    ('public.reveal_ambient_now()', null), ('service.set_demo_reveal_enabled(uuid,boolean)', array['account_id','enabled']);
select extensions.is(p.proargnames, r.names, r.signature || ' exact parameters')
from daily_rpcs as r join pg_catalog.pg_proc as p on p.oid = r.signature::regprocedure;
select extensions.is(pg_catalog.format_type(p.prorettype, null), 'jsonb', r.signature || ' JSON return')
from daily_rpcs as r join pg_catalog.pg_proc as p on p.oid = r.signature::regprocedure;
select extensions.ok(p.prosecdef, r.signature || ' security definer')
from daily_rpcs as r join pg_catalog.pg_proc as p on p.oid = r.signature::regprocedure;
select extensions.ok('search_path=""' = any(p.proconfig), r.signature || ' empty search path')
from daily_rpcs as r join pg_catalog.pg_proc as p on p.oid = r.signature::regprocedure;
create temporary table report_helpers (signature text, names text[], result_type text);
insert into report_helpers values
    ('private.local_report_instant(uuid,date)', array['account_id','report_day'], 'timestamp with time zone'),
    ('private.run_account_report(uuid,timestamptz)', array['account_id','report_at'], 'jsonb'),
    ('private.run_due_reports(timestamptz)', array['report_at'], 'void');
select extensions.is(p.proargnames, r.names, r.signature || ' exact parameters')
from report_helpers as r join pg_catalog.pg_proc as p on p.oid = r.signature::regprocedure;
select extensions.is(pg_catalog.format_type(p.prorettype, null), r.result_type, r.signature || ' return type')
from report_helpers as r join pg_catalog.pg_proc as p on p.oid = r.signature::regprocedure;
select extensions.ok(p.prosecdef and 'search_path=""' = any(p.proconfig), r.signature || ' private definer')
from report_helpers as r join pg_catalog.pg_proc as p on p.oid = r.signature::regprocedure;
select extensions.ok(not pg_catalog.has_function_privilege('authenticated', r.signature, 'execute'), r.signature || ' not client executable') from report_helpers as r;
select extensions.is(p.pronargdefaults, case when r.signature like '%local_report%' then 0 else 1 end::smallint,
    r.signature || ' default clock') from report_helpers as r join pg_catalog.pg_proc as p on p.oid = r.signature::regprocedure;
select extensions.is(p.provolatile::text, 'v', 'local report instant permits its volatile validation error helper')
from pg_catalog.pg_proc as p where p.oid = 'private.local_report_instant(uuid,date)'::regprocedure;
select extensions.ok(c.relrowsecurity, t.name || ' RLS')
from (values ('report_deliveries'), ('server_settings')) as t(name)
join pg_catalog.pg_class as c on c.oid = ('private.' || t.name)::regclass;
select extensions.is((select pg_catalog.count(*) from pg_catalog.pg_policy as p where p.polrelid = ('private.' || t.name)::regclass),
    0::bigint, t.name || ' no policies') from (values ('report_deliveries'), ('server_settings')) as t(name);
select extensions.ok(not pg_catalog.has_table_privilege(r.name, 'private.' || t.name, 'select, insert, update, delete'), r.name || ' denied ' || t.name)
from (values ('report_deliveries'), ('server_settings')) as t(name) cross join (values ('anon'), ('authenticated'), ('service_role')) as r(name);
select extensions.is((select pg_catalog.array_agg(a.attname::text order by a.attnum) from pg_catalog.pg_attribute as a
    where a.attrelid = 'private.report_deliveries'::regclass and a.attnum > 0 and not a.attisdropped),
    array['user_id','report_day','status'], 'delivery row contains dates and references only');
select extensions.is((select pg_catalog.array_agg(a.attname::text order by a.attnum) from pg_catalog.pg_attribute as a
    where a.attrelid = 'private.server_settings'::regclass and a.attnum > 0 and not a.attisdropped),
    array['singleton','environment','demo_reveal_enabled','operator_account_id'], 'server settings allocated columns');
select extensions.is((select a.atttypid::regtype::text from pg_catalog.pg_attribute as a
    where a.attrelid = 'private.encounter_views'::regclass and a.attname = 'revealed_report_day'), 'date', 'report membership is date-only');
select extensions.is((select pg_catalog.count(*) from cron.job where jobname = 'encounters-daily-reports'), 1::bigint, 'one daily-report Cron job');
select extensions.is((select schedule from cron.job where jobname = 'encounters-daily-reports'), '*/5 * * * *', 'five-minute schedule');
select extensions.is((select command from cron.job where jobname = 'encounters-daily-reports'), 'select private.run_due_reports();', 'Cron uses the shared default-clock step');
select extensions.ok((select active from cron.job where jobname = 'encounters-daily-reports'), 'Cron active');
select extensions.is((select database from cron.job where jobname = 'encounters-daily-reports'), pg_catalog.current_database()::text, 'Cron database');
select extensions.is((select username from cron.job where jobname = 'encounters-daily-reports'), current_user::text, 'Cron migration owner');
do $$ begin
    perform cron.schedule('encounters-daily-reports', '*/5 * * * *', 'select private.run_due_reports();');
    perform cron.schedule('encounters-daily-reports', '*/5 * * * *', 'select private.run_due_reports();');
end; $$;
select extensions.is((select pg_catalog.count(*) from cron.job where jobname = 'encounters-daily-reports'), 1::bigint, 'rescheduling is idempotent');
select extensions.is((select pg_catalog.count(*) from private.server_settings), 1::bigint, 'exactly one deployment row');
select extensions.is((select pg_catalog.jsonb_build_array(environment, demo_reveal_enabled) from private.server_settings), '["local",true]'::jsonb, 'local seed enables demo');
select extensions.ok((select pg_catalog.bool_and(pg_catalog.pg_get_expr(d.adbin, d.adrelid) in ('''production''::text', 'false'))
    from pg_catalog.pg_attrdef as d join pg_catalog.pg_attribute as a on a.attrelid = d.adrelid and a.attnum = d.adnum
    where d.adrelid = 'private.server_settings'::regclass and a.attname in ('environment','demo_reveal_enabled')), 'column defaults are production and off');
select extensions.ok(pg_catalog.has_function_privilege('service_role', 'service.set_demo_reveal_enabled(uuid,boolean)', 'execute'), 'operator deployment service executable');
select extensions.ok(not pg_catalog.has_function_privilege(r.name, 'service.set_demo_reveal_enabled(uuid,boolean)', 'execute'), r.name || ' denied deployment service')
from (values ('anon'), ('authenticated')) as r(name);

-- Settings/error wire: 41, including every failing detail subset in order.
select daily_test.reset();
select extensions.is(daily_test.as_caller(daily_test.id(1), 'select public.get_report_settings()'),
    '{"report_hour":21,"report_minute":0,"time_zone":"UTC","notifications_enabled":true}'::jsonb, 'default report settings exact JSON');
select extensions.is(daily_test.as_caller(daily_test.id(1), 'select public.set_report_time(7, 45)'),
    '{"report_hour":7,"report_minute":45,"time_zone":"UTC","notifications_enabled":true}'::jsonb, 'custom report time exact JSON');
select extensions.is(daily_test.as_caller(daily_test.id(1), 'select public.set_notifications_enabled(false)'),
    '{"report_hour":7,"report_minute":45,"time_zone":"UTC","notifications_enabled":false}'::jsonb, 'notification preference exact JSON');
select daily_test.error_call(230, r.statement, 'account_not_ready', '', r.statement || ' missing preferences')
from (values ('select public.get_report_settings()'), ('select public.set_report_time(21,0)'),
    ('select public.set_notifications_enabled(true)'), ('select public.get_daily_report()'), ('select public.reveal_ambient_now()')) as r(statement);
select daily_test.error_call(1, pg_catalog.format('select public.set_report_time(%L, %L)', h, m), 'invalid_input', detail, description)
from (values (null::integer,null::integer,'hour,minute','null report time'), (-1,60,'hour,minute','both bounds invalid'),
    (24,0,'hour','high hour'), (-1,0,'hour','low hour'), (null,0,'hour','null hour'),
    (0,60,'minute','high minute'), (0,-1,'minute','low minute'), (0,null,'minute','null minute')) as t(h,m,detail,description);
select daily_test.error_call(1, 'select public.set_notifications_enabled(null)', 'invalid_input', 'enabled', 'null notification preference');
select extensions.is(daily_test.as_caller(daily_test.id(1), 'select public.set_report_time(0,0)')->'report_hour', '0'::jsonb, 'minimum report time accepted');
select extensions.is(daily_test.as_caller(daily_test.id(1), 'select public.set_report_time(23,59)')->'report_minute', '59'::jsonb, 'maximum report time accepted');
select daily_test.expect_error(pg_catalog.format('select private.local_report_instant(%L::uuid,%L::date)', account, day),
    'invalid_input', detail, description)
from (values (null::uuid,null::date,'account_id,report_day','local instant both null'),
    (null,date '2026-10-13','account_id','local instant null account'),
    (daily_test.id(1),null,'report_day','local instant null day')) as t(account,day,detail,description);
select daily_test.expect_error(pg_catalog.format('select private.local_report_instant(%L::uuid,date ''2026-10-13'')', daily_test.id(230)),
    'account_not_ready', '', 'local instant requires preferences');
select daily_test.expect_error(pg_catalog.format('select private.run_account_report(%L::uuid,%L::timestamptz)', account, at_time),
    'invalid_input', detail, description)
from (values (null::uuid,null::timestamptz,'account_id,report_at','step both null'),
    (null,timestamptz '2026-10-13 21:00+00','account_id','step null account'),
    (daily_test.id(1),null,'report_at','step null clock')) as t(account,at_time,detail,description);
select daily_test.expect_error('select private.run_due_reports(null)', 'invalid_input', 'report_at', 'worker null clock');
select extensions.is(private.run_account_report(daily_test.id(230), timestamptz '2026-10-13 21:00+00'),
    '{"report_day":null,"newly_revealed_encounter_ids":[],"closed":false}'::jsonb, 'worker skips unready account');
select extensions.is(private.run_account_report(daily_test.id(999), timestamptz '2026-10-13 21:00+00'),
    '{"report_day":null,"newly_revealed_encounter_ids":[],"closed":false}'::jsonb, 'worker skips missing account');
select daily_test.expect_error(pg_catalog.format('select daily_test.as_caller(null, %L)', r.statement), 'not_authenticated', '', r.statement || ' requires live caller')
from (values ('select public.get_report_settings()'), ('select public.set_report_time(21,0)'),
    ('select public.set_notifications_enabled(true)'), ('select public.get_daily_report()'), ('select public.reveal_ambient_now()')) as r(statement);
select daily_test.error_call(999, 'select public.get_report_settings()', 'not_authenticated', '', 'deleted Auth caller is denied');
select daily_test.error_call(1, 'select public.register_time_zone(null)', 'invalid_input', 'time_zone', 'zone null detail');
select daily_test.error_call(1, 'select public.register_time_zone(''No/SuchZone'')', 'invalid_input', 'time_zone', 'unknown zone detail');
select extensions.is(daily_test.as_caller(daily_test.id(1), 'select public.get_report_settings()'),
    '{"report_hour":23,"report_minute":59,"time_zone":"UTC","notifications_enabled":false}'::jsonb, 'settings getter returns latest values');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events where user_id=daily_test.id(1)), 0::bigint, 'report settings and failed zone calls add no budget events');
delete from private.profiles where user_id=daily_test.id(228);
select daily_test.error_call(228, 'select public.register_time_zone(''UTC'')', 'declaration_required', '', 'zone registration requires profile declarations');
insert into private.account_limit_events (user_id,bucket,occurred_at)
select daily_test.id(1),'register_time_zone',pg_catalog.now() from pg_catalog.generate_series(1,10);
select daily_test.error_call(1, 'select public.register_time_zone(''UTC'')', 'rate_limited', '', 'zone registration keeps ten-call rolling daily budget');

-- Scheduling: 32. Drive all boundaries with the private report clock.
select daily_test.reset();
select extensions.is(private.next_report_day(daily_test.id(1), timestamptz '2026-10-13 20:59:59.999999+00'), date '2026-10-13', 'confirmation before cutoff assigns today');
select extensions.is(private.next_report_day(daily_test.id(1), timestamptz '2026-10-13 21:00+00'), date '2026-10-14', 'confirmation at exact cutoff assigns strictly future tomorrow');
select extensions.is(private.next_report_day(daily_test.id(1), timestamptz '2026-10-13 21:00:00.000001+00'), date '2026-10-14', 'confirmation after cutoff assigns tomorrow');
select daily_test.waiting(1, 2, date '2026-10-13', date '2026-10-13');
select extensions.is(private.local_report_instant(daily_test.id(1), date '2026-10-13'), timestamptz '2026-10-13 21:00+00', 'default cutoff instant');
select extensions.is(private.run_account_report(daily_test.id(1), timestamptz '2026-10-13 20:59:59.999999+00'),
    '{"report_day":"2026-10-12","newly_revealed_encounter_ids":[],"closed":true}'::jsonb, 'one microsecond before cutoff closes previous empty date');
select extensions.ok(not (select revealed from private.encounter_views where encounter_id = daily_test.id(1001)), 'today waits before exact cutoff');
select extensions.is(private.run_account_report(daily_test.id(1), timestamptz '2026-10-13 21:00+00'),
    pg_catalog.jsonb_build_object('report_day', '2026-10-13', 'newly_revealed_encounter_ids', array[daily_test.id(1001)], 'closed', true), 'exact cutoff reveals');
select extensions.is((select revealed_report_day from private.encounter_views where encounter_id = daily_test.id(1001)), date '2026-10-13', 'normal reveal stamps delivery date');
insert into private.report_deliveries values (daily_test.id(1),date '2026-10-11','open');
select extensions.is(private.run_account_report(daily_test.id(1), timestamptz '2026-10-13 21:00+00'),
    '{"report_day":"2026-10-13","newly_revealed_encounter_ids":[],"closed":false}'::jsonb, 'caller step replay is idempotent');
select extensions.is((select status from private.report_deliveries where user_id=daily_test.id(1) and report_day=date '2026-10-11'), 'closed', 'replay also closes any older open due key');
select private.run_due_reports(timestamptz '2026-10-13 21:00+00');
select private.run_due_reports(timestamptz '2026-10-13 21:00+00');
select extensions.is((select pg_catalog.count(*) from private.report_deliveries where user_id = daily_test.id(1)), 3::bigint, 'Cron replays add no caller delivery key');
select extensions.is((select revealed_report_day from private.encounter_views where encounter_id = daily_test.id(1001)), date '2026-10-13', 'Cron replays preserve membership');
select extensions.is(private.run_account_report(daily_test.id(1), timestamptz '2026-10-14 21:00+00'),
    '{"report_day":"2026-10-14","newly_revealed_encounter_ids":[],"closed":true}'::jsonb, 'empty day closes once');
select extensions.is(private.run_account_report(daily_test.id(1), timestamptz '2026-10-14 21:01+00'),
    '{"report_day":"2026-10-14","newly_revealed_encounter_ids":[],"closed":false}'::jsonb, 'empty closed day replay');
select daily_test.reset();
update private.notification_preferences set report_hour = 7, report_minute = 45 where user_id = daily_test.id(1);
select daily_test.waiting(1, 2, date '2026-10-13', date '2026-10-13');
select extensions.is(private.local_report_instant(daily_test.id(1), date '2026-10-13'), timestamptz '2026-10-13 07:45+00', 'custom time uses minute');
select extensions.is(private.run_account_report(daily_test.id(1), timestamptz '2026-10-13 07:44:59.999999+00')->'newly_revealed_encounter_ids', '[]'::jsonb, 'custom time before cutoff waits');
select extensions.is(private.run_account_report(daily_test.id(1), timestamptz '2026-10-13 07:45+00')->'newly_revealed_encounter_ids',
    pg_catalog.to_jsonb(array[daily_test.id(1001)]), 'custom time exact cutoff');
select daily_test.reset();
update private.notification_preferences set time_zone = 'Asia/Tokyo', report_hour = 8, report_minute = 15 where user_id = daily_test.id(1);
update private.notification_preferences set time_zone = 'America/Los_Angeles', report_hour = 20, report_minute = 30 where user_id = daily_test.id(2);
create temporary table confirmed (encounter_id uuid);
insert into confirmed select private.confirm_encounter(daily_test.id(1), daily_test.id(2), 'ambient',
    extract(epoch from timestamptz '2026-10-12 23:00+00')::bigint, extract(epoch from timestamptz '2026-10-12 23:00+00')::bigint,
    timestamptz '2026-10-13 00:00+00');
select extensions.is((select pg_catalog.jsonb_build_array(day_a,day_b) from private.encounters where encounter_id = (select encounter_id from confirmed)),
    '["2026-10-13","2026-10-12"]'::jsonb, 'late receipts keep independent observation dates');
select extensions.is((select reveal_report_day from private.encounter_views where viewer_id = daily_test.id(1)), date '2026-10-14', 'Tokyo report already passed on confirmation');
select extensions.is((select reveal_report_day from private.encounter_views where viewer_id = daily_test.id(2)), date '2026-10-12', 'LA custom report is still future');
select extensions.is(private.run_account_report(daily_test.id(1), timestamptz '2026-10-13 03:30+00')->'newly_revealed_encounter_ids', '[]'::jsonb, 'late Tokyo receipt waits despite old encounter date');
select extensions.is(private.run_account_report(daily_test.id(2), timestamptz '2026-10-13 03:30+00')->'newly_revealed_encounter_ids',
    (select pg_catalog.to_jsonb(array[encounter_id]) from confirmed), 'other viewer reveals at independent LA cutoff');
select extensions.ok(not (select revealed from private.encounter_views where viewer_id = daily_test.id(1)), 'one viewer reveal does not reveal other');
select extensions.is(private.run_account_report(daily_test.id(1), timestamptz '2026-10-13 23:15+00')->'newly_revealed_encounter_ids',
    (select pg_catalog.to_jsonb(array[encounter_id]) from confirmed), 'late receipt eventually reveals at assigned Tokyo report');
select daily_test.reset();
select daily_test.waiting(3, 3, date '2026-10-13', date '2026-10-11');
select daily_test.waiting(2, 2, date '2026-10-13', date '2026-10-12');
insert into private.report_deliveries values (daily_test.id(1), date '2026-10-11', 'open'), (daily_test.id(1), date '2026-10-12', 'open');
select extensions.is(private.run_account_report(daily_test.id(1), timestamptz '2026-10-13 21:00+00')->'newly_revealed_encounter_ids',
    pg_catalog.to_jsonb(array[daily_test.id(1002),daily_test.id(1003)]), 'missed older due dates reveal together in UUID order');
select extensions.is((select pg_catalog.count(*) from private.report_deliveries where user_id = daily_test.id(1) and status = 'open'), 0::bigint, 'older open due keys close');
select extensions.ok((select pg_catalog.bool_and(revealed_report_day = date '2026-10-13') from private.encounter_views), 'catchup membership uses current delivery, not assigned day');
select daily_test.reset();
select daily_test.waiting(1, 2, date '2026-09-13', date '2026-10-13');
select daily_test.waiting(2, 3, date '2026-09-13', date '2026-10-13');
update private.encounter_views set favorite = true where encounter_id = daily_test.id(1002);
select extensions.is(private.run_account_report(daily_test.id(1), timestamptz '2026-10-13 21:00+00')->'newly_revealed_encounter_ids',
    pg_catalog.to_jsonb(array[daily_test.id(1002)]), 'expired ordinary view excluded, favorite retained');
select extensions.ok(not (select revealed from private.encounter_views where encounter_id = daily_test.id(1001)), 'expired unretained flag never advances');
select extensions.is(private.next_report_day(daily_test.id(1), timestamptz '2026-10-13 20:00+00'), date '2026-10-14', 'confirmation skips closed future date');
select daily_test.reset();
select daily_test.waiting(1,2,date '2026-10-13',date '2026-10-13');
update private.notification_preferences set notifications_enabled=false where user_id=daily_test.id(1);
update private.profiles set discovery_on=false where user_id in (daily_test.id(1),daily_test.id(2));
select private.run_due_reports(timestamptz '2026-10-13 21:00+00');
select extensions.is((select revealed_report_day from private.encounter_views where encounter_id=daily_test.id(1001)), date '2026-10-13', 'Cron first reveal ignores discovery and notification preference');
select extensions.is(private.run_account_report(daily_test.id(1),timestamptz '2026-10-13 21:00+00'),
    '{"report_day":"2026-10-13","newly_revealed_encounter_ids":[],"closed":false}'::jsonb, 'caller replay after Cron first reveal is idempotent');

-- DST and settings/travel: 27. Public writes use transaction time, while
-- precise DST report boundaries use explicit clocks, never pg_sleep.
select daily_test.reset();
update private.notification_preferences set time_zone = 'America/New_York', report_hour = 2, report_minute = 30 where user_id = daily_test.id(1);
select extensions.is(private.local_report_instant(daily_test.id(1), date '2026-03-08'), timestamptz '2026-03-08 07:00+00', 'DST gap advances to first real minute 03:00');
select daily_test.waiting(1, 2, date '2026-03-08', date '2026-03-08');
select extensions.is(private.run_account_report(daily_test.id(1), timestamptz '2026-03-08 06:59:59.999999+00')->'newly_revealed_encounter_ids', '[]'::jsonb, 'gap before advanced cutoff waits');
select extensions.is(private.run_account_report(daily_test.id(1), timestamptz '2026-03-08 07:00+00')->'newly_revealed_encounter_ids', pg_catalog.to_jsonb(array[daily_test.id(1001)]), 'gap reveals at advanced cutoff');
update private.notification_preferences set time_zone='Australia/Lord_Howe', report_hour=2, report_minute=15 where user_id=daily_test.id(1);
select extensions.is(private.local_report_instant(daily_test.id(1), date '2026-10-04'), timestamptz '2026-10-03 15:30+00', 'half-hour DST gap advances to 02:30, not 02:45');
select daily_test.reset();
update private.notification_preferences set time_zone = 'America/New_York', report_hour = 1, report_minute = 30 where user_id = daily_test.id(1);
select extensions.is(private.local_report_instant(daily_test.id(1), date '2026-11-01'), timestamptz '2026-11-01 05:30+00', 'repeat selects first 01:30 occurrence');
select daily_test.waiting(1, 2, date '2026-11-01', date '2026-11-01');
select extensions.is(private.run_account_report(daily_test.id(1), timestamptz '2026-11-01 05:29:59.999999+00')->'newly_revealed_encounter_ids', '[]'::jsonb, 'repeat before first occurrence waits');
select extensions.is(private.run_account_report(daily_test.id(1), timestamptz '2026-11-01 05:30+00')->'newly_revealed_encounter_ids', pg_catalog.to_jsonb(array[daily_test.id(1001)]), 'repeat first occurrence reveals');
select extensions.is(private.run_account_report(daily_test.id(1), timestamptz '2026-11-01 06:30+00')->'closed', 'false'::jsonb, 'repeat second occurrence cannot replay');
select extensions.is(private.next_report_day(daily_test.id(1), timestamptz '2026-11-01 06:00+00'), date '2026-11-02', 'between repeats confirmation waits for next day');
select daily_test.reset();
select daily_test.waiting(1, 2, daily_test.day(), daily_test.day() - 1);
select daily_test.waiting(2, 3, daily_test.day() - 1, daily_test.day() - 1);
select daily_test.waiting(3, 4, daily_test.day() - 2, daily_test.day() - 7);
update private.encounter_views set revealed = true, revealed_report_day = daily_test.day() - 1 where encounter_id = daily_test.id(1002);
select extensions.is(daily_test.as_caller(daily_test.id(1), 'select public.set_report_time(0,0)'),
    '{"report_hour":0,"report_minute":0,"time_zone":"UTC","notifications_enabled":true}'::jsonb, 'moving time earlier updates settings');
select extensions.ok((select pg_catalog.bool_and(reveal_report_day = daily_test.day() + 1) from private.encounter_views
    where viewer_id=daily_test.id(1) and not revealed), 'earlier elapsed time reassigns every waiting view to strictly future report');
select extensions.ok((select pg_catalog.bool_and(not revealed) from private.encounter_views
    where encounter_id in (daily_test.id(1001),daily_test.id(1003))), 'time change does not reveal any waiting view');
select extensions.is((select revealed_report_day from private.encounter_views where encounter_id = daily_test.id(1002)), daily_test.day() - 1, 'revealed membership unchanged by time write');
select extensions.is((select pg_catalog.count(*) from private.report_deliveries where user_id = daily_test.id(1)), 0::bigint, 'settings close no date');
update private.encounter_views set reveal_report_day = daily_test.day() - 1 where encounter_id = daily_test.id(1001);
select daily_test.as_caller(daily_test.id(1), 'select public.set_report_time(0,0)');
select extensions.is((select reveal_report_day from private.encounter_views where encounter_id = daily_test.id(1001)), daily_test.day() - 1, 'same time write does not postpone waiting views');
select daily_test.as_caller(daily_test.id(1), 'select public.set_notifications_enabled(false)');
select extensions.is((select pg_catalog.jsonb_build_array(revealed,reveal_report_day) from private.encounter_views where encounter_id = daily_test.id(1001)),
    pg_catalog.jsonb_build_array(false,daily_test.day()-1), 'notifications write changes neither assignment nor flag');
-- Travel across the date line guarantees backward/forward local dates at any
-- transaction time. Closed dates are inserted before travel, not reopened.
update private.notification_preferences set time_zone = 'Pacific/Kiritimati', report_hour = 0, report_minute = 0 where user_id = daily_test.id(1);
insert into private.report_deliveries select daily_test.id(1), (pg_catalog.now() at time zone 'Etc/GMT+12')::date + n, 'closed'
from pg_catalog.generate_series(0,2) as n;
select daily_test.zone_as_caller(daily_test.id(1), 'Etc/GMT+12');
select extensions.ok((select pg_catalog.bool_and(reveal_report_day = (pg_catalog.now() at time zone 'Etc/GMT+12')::date + 3)
    from private.encounter_views where viewer_id=daily_test.id(1) and not revealed), 'backward travel skips all closed local dates for every waiting view');
select extensions.ok((select pg_catalog.bool_and(not revealed) from private.encounter_views
    where encounter_id in (daily_test.id(1001),daily_test.id(1003))), 'backward travel reveals nothing');
select extensions.is((select pg_catalog.count(*) from private.report_deliveries where user_id = daily_test.id(1) and status = 'closed'), 3::bigint, 'backward travel never reopens key');
update private.encounter_views set reveal_report_day = daily_test.day() - 1 where encounter_id = daily_test.id(1001);
select daily_test.zone_as_caller(daily_test.id(1), 'Etc/GMT+12');
select extensions.is((select reveal_report_day from private.encounter_views where encounter_id = daily_test.id(1001)), daily_test.day() - 1, 'same zone does not postpone');
delete from private.report_deliveries where user_id = daily_test.id(1);
select daily_test.zone_as_caller(daily_test.id(1), 'Pacific/Kiritimati');
select extensions.ok((select pg_catalog.bool_and(reveal_report_day = (pg_catalog.now() at time zone 'Pacific/Kiritimati')::date + 1)
    from private.encounter_views where viewer_id=daily_test.id(1) and not revealed), 'forward travel recalculates next local report for every waiting view');
select extensions.ok((select pg_catalog.bool_and(not revealed) from private.encounter_views
    where encounter_id in (daily_test.id(1001),daily_test.id(1003))), 'forward travel reveals nothing');
select extensions.is(daily_test.as_caller(daily_test.id(1), 'select public.get_report_settings()'),
    '{"report_hour":0,"report_minute":0,"time_zone":"Pacific/Kiritimati","notifications_enabled":false}'::jsonb, 'zone changes preserve custom time and notification setting');
select extensions.is(daily_test.zone_as_caller(daily_test.id(1), 'UTC'), null::jsonb, 'zone RPC stays SQL void/JSON null');
select extensions.is((select revealed_report_day from private.encounter_views where encounter_id = daily_test.id(1002)), daily_test.day() - 1, 'travel preserves already revealed report day');
update private.notification_preferences set time_zone = 'UTC', report_hour = 21, report_minute = 0 where user_id = daily_test.id(1);
select daily_test.as_caller(daily_test.id(1), 'select public.set_report_time(23,59)');
select extensions.is((select reveal_report_day from private.encounter_views where encounter_id = daily_test.id(1001)),
    daily_test.day() + case when (pg_catalog.now() at time zone 'UTC')::time >= time '23:59' then 1 else 0 end, 'later time chooses next strictly future minute');
select extensions.ok(not (select revealed from private.encounter_views where encounter_id = daily_test.id(1001)), 'later time still reveals nothing');

-- Daily/feed membership, shared gate, dedup/cap and preferences: 30.
select daily_test.reset();
-- Model a peer confirmation committing just after its delivery was closed.
-- The next later delivery catches it up without taking peer account locks.
select extensions.is(private.run_account_report(daily_test.id(1),
    pg_catalog.timezone('UTC', (daily_test.due_day()-1)::timestamp) + interval '21 hours'),
    pg_catalog.jsonb_build_object('report_day',daily_test.due_day()-1,'newly_revealed_encounter_ids','[]'::jsonb,'closed',true),
    'older assigned delivery is closed before the racing view arrives');
select daily_test.waiting(1,2,daily_test.day(),daily_test.due_day()-1);
select extensions.ok((select not v.revealed and d.status='closed' from private.encounter_views as v
    join private.report_deliveries as d on d.user_id=v.viewer_id and d.report_day=v.reveal_report_day
    where v.encounter_id=daily_test.id(1001)), 'retained waiting view can arrive behind an already closed date');
select extensions.is(private.run_account_report(daily_test.id(1),pg_catalog.now()),
    pg_catalog.jsonb_build_object('report_day',daily_test.due_day(),'newly_revealed_encounter_ids',array[daily_test.id(1001)],'closed',true),
    'next later report catches up the view assigned to an already closed date');
select extensions.is((select revealed_report_day from private.encounter_views where encounter_id=daily_test.id(1001)),
    daily_test.due_day(), 'racing view is stamped with the later delivery date');
select extensions.is(daily_test.as_caller(daily_test.id(1), 'select public.get_daily_report()'),
    pg_catalog.jsonb_build_object('report_day',daily_test.due_day(),'cards',pg_catalog.jsonb_build_array(daily_test.card(1)),'truncated',false),
    'daily report lists the racing view under its later delivery, not the closed assigned date');
select daily_test.reset();
select extensions.is(daily_test.as_caller(daily_test.id(1), 'select public.get_daily_report()'),
    pg_catalog.jsonb_build_object('report_day',daily_test.due_day(),'cards','[]'::jsonb,'truncated',false), 'ready caller closes an empty latest report');
select extensions.is((select pg_catalog.count(*) from private.report_deliveries where user_id = daily_test.id(1)), 1::bigint, 'daily caller runs report step');
select daily_test.reset();
update private.notification_preferences set time_zone = 'No/SuchZone' where user_id = daily_test.id(1);
select extensions.is(daily_test.as_caller(daily_test.id(1), 'select public.get_daily_report()'),
    '{"report_day":null,"cards":[],"truncated":false}'::jsonb, 'no schedulable delivery fails closed to null report');
select daily_test.reset();
select daily_test.waiting(1, 2);
select daily_test.waiting(2, 3, daily_test.day(), daily_test.due_day() + 1);
select daily_test.waiting(3, 4);
select daily_test.waiting(4, 5);
update private.encounter_views set revealed = true, revealed_report_day = daily_test.due_day() - 1 where encounter_id = daily_test.id(1003);
update private.encounter_views set revealed = true, revealed_report_day = null where encounter_id = daily_test.id(1004);
select extensions.is(daily_test.as_caller(daily_test.id(1), 'select public.get_daily_report()'),
    pg_catalog.jsonb_build_object('report_day',daily_test.due_day(),'cards',pg_catalog.jsonb_build_array(daily_test.card(1)),'truncated',false),
    'daily report contains only latest delivery ambient views, not older/demo/future views');
select extensions.ok(not (select revealed from private.encounter_views where encounter_id = daily_test.id(1002)), 'future assigned report still waits on caller read');
select extensions.is(daily_test.as_caller(daily_test.id(1), 'select public.get_daily_report()')->'cards',
    pg_catalog.jsonb_build_array(daily_test.card(1)), 'daily replay preserves exact membership');
update private.profiles set discovery_on = false where user_id = daily_test.id(2);
select extensions.is(daily_test.as_caller(daily_test.id(1), 'select public.get_daily_report()')->'cards', '[]'::jsonb, 'report rechecks owner discovery');
update private.profiles set discovery_on = true where user_id = daily_test.id(2);
insert into private.blocks values (daily_test.id(2),daily_test.id(1));
select extensions.is(daily_test.as_caller(daily_test.id(1), 'select public.get_daily_report()')->'cards', '[]'::jsonb, 'report rechecks reverse block');
delete from private.blocks where blocker_id = daily_test.id(2);
update private.profiles set moderation_state = 'hidden' where user_id = daily_test.id(2);
select extensions.is(daily_test.as_caller(daily_test.id(1), 'select public.get_daily_report()')->'cards', '[]'::jsonb, 'report rechecks owner moderation');
update private.profiles set moderation_state = 'active' where user_id = daily_test.id(2);
update private.field_visibility set level = 'private' where owner_id = daily_test.id(2) and field = 'interests';
select extensions.is(daily_test.as_caller(daily_test.id(1), 'select public.get_daily_report()')#>'{cards,0}',
    daily_test.card(1) - 'interests' - 'shared_interest_ids', 'report omits protected shared interests');
update private.profiles set discovery_on = false where user_id = daily_test.id(1);
select extensions.is(daily_test.as_caller(daily_test.id(1), 'select public.get_daily_report()')->'cards', '[]'::jsonb, 'daily read applies shared gate without Discovery error');
select daily_test.reset();
select daily_test.waiting(1, 2);
update private.notification_preferences set notifications_enabled = false where user_id = daily_test.id(1);
select extensions.is(daily_test.as_caller(daily_test.id(1), 'select public.get_encounter_feed()'),
    pg_catalog.jsonb_build_object('cards',pg_catalog.jsonb_build_array(daily_test.card(1)),'truncated',false), 'feed runs due step even with notifications disabled');
select extensions.is((select revealed_report_day from private.encounter_views where encounter_id = daily_test.id(1001)), daily_test.due_day(), 'feed step writes normal membership');
select extensions.is(private.run_account_report(daily_test.id(1), pg_catalog.now())->'closed', 'false'::jsonb, 'worker replay after feed step is idempotent');
select extensions.is(daily_test.as_caller(daily_test.id(1), 'select public.get_encounter_feed()')->'cards', pg_catalog.jsonb_build_array(daily_test.card(1)), 'feed replay does not lose reveal');
select daily_test.reset();
select daily_test.waiting(1, 2);
update private.profiles set discovery_on = false where user_id = daily_test.id(2);
select extensions.is(private.run_account_report(daily_test.id(1))->'newly_revealed_encounter_ids', pg_catalog.to_jsonb(array[daily_test.id(1001)]), 'report flags advance independently of owner eligibility');
select extensions.is(daily_test.as_caller(daily_test.id(1), 'select public.get_daily_report()')->'cards', '[]'::jsonb, 'hidden newly revealed owner yields no card');
select daily_test.reset();
select daily_test.waiting(n, n+1, daily_test.day() - case when n=1 then 0 else 1 end) from pg_catalog.generate_series(1,201) as n;
select daily_test.waiting(300, 2, daily_test.day(), daily_test.due_day(), daily_test.day() + 1);
update private.encounter_views set favorite = true where encounter_id = daily_test.id(1300);
create temporary table responses (label text primary key, result jsonb);
insert into responses values ('daily_cap',daily_test.as_caller(daily_test.id(1), 'select public.get_daily_report()'));
select extensions.is(pg_catalog.jsonb_array_length((select result->'cards' from responses where label='daily_cap')), 200, 'daily cap is 200 dedup winners');
select extensions.is((select result->'truncated' from responses where label='daily_cap'), 'true'::jsonb, '201 daily winners truncate');
select extensions.ok(exists (select 1 from responses as r cross join lateral pg_catalog.jsonb_array_elements(r.result->'cards') as c
    where r.label='daily_cap' and c->>'encounter_id'=daily_test.id(1300)::text), 'favorite duplicate wins before daily cap');
select extensions.ok(not exists (select 1 from responses as r cross join lateral pg_catalog.jsonb_array_elements(r.result->'cards') as c
    where r.label='daily_cap' and c->>'encounter_id'=daily_test.id(1001)::text), 'daily dedup removes nonfavorite winner');
update private.profiles set discovery_on=false where user_id=daily_test.id(202);
select extensions.is(daily_test.as_caller(daily_test.id(1), 'select public.get_daily_report()')->'truncated', 'false'::jsonb, '200 authorized winners with hidden extra do not truncate');
select extensions.is(pg_catalog.jsonb_array_length(daily_test.as_caller(daily_test.id(1), 'select public.get_daily_report()')->'cards'), 200, 'dedup and gate precede exact-cap test');
insert into private.report_deliveries values (daily_test.id(1), daily_test.due_day() + 1, 'closed');
select extensions.is(daily_test.as_caller(daily_test.id(1), 'select public.get_daily_report()'),
    pg_catalog.jsonb_build_object('report_day',daily_test.due_day()+1,'cards','[]'::jsonb,'truncated',false), 'maximum closed date wins even when empty after travel');
select extensions.is((select pg_catalog.count(*) from private.encounter_views where viewer_id=daily_test.id(1)), 202::bigint, 'report dedup never deletes views');

-- Demo/operator: 25, with setting/environment checked before readiness.
select daily_test.reset();
update private.server_settings set demo_reveal_enabled=false where singleton;
select daily_test.error_call(230, 'select public.reveal_ambient_now()', 'not_found', '', 'demo off rejected before unready check');
select daily_test.error_call(1, 'select public.reveal_ambient_now()', 'not_found', '', 'demo off rejected for ready caller');
update private.server_settings set environment='production' where singleton;
select daily_test.error_call(230, 'select public.reveal_ambient_now()', 'not_found', '', 'production rejected before unready check');
select daily_test.error_call(1, 'select public.reveal_ambient_now()', 'not_found', '', 'production rejects ready caller');
select daily_test.expect_error(pg_catalog.format('select daily_test.as_operator(%L::uuid,true)',daily_test.id(229)), 'not_found', '', 'operator cannot enable production demo');
select extensions.is((select demo_reveal_enabled from private.server_settings), false, 'production demo remains off');
select extensions.is(daily_test.as_operator(daily_test.id(229),false), '{"demo_reveal_enabled":false}'::jsonb, 'operator may keep production off');
update private.server_settings set environment='non_production' where singleton;
select daily_test.expect_error(pg_catalog.format('select daily_test.as_operator(%L::uuid,true)',daily_test.id(1)), 'not_found', '', 'non-operator rejected');
update private.server_settings set operator_account_id=null where singleton;
select daily_test.expect_error(pg_catalog.format('select daily_test.as_operator(%L::uuid,true)',daily_test.id(229)), 'not_found', '', 'missing configured operator rejected');
update private.server_settings set operator_account_id=daily_test.id(229) where singleton;
select extensions.is(daily_test.as_operator(daily_test.id(229),true), '{"demo_reveal_enabled":true}'::jsonb, 'verified operator enables non-production demo');
select daily_test.expect_error(pg_catalog.format('select daily_test.as_operator(%L::uuid,true)',daily_test.id(999)), 'not_authenticated', '', 'deployment requires live Auth operator');
select daily_test.expect_error(pg_catalog.format('select daily_test.as_operator(%L::uuid,%L::boolean)',account,enabled), 'invalid_input', detail, description)
from (values (null::uuid,null::boolean,'account_id,enabled','operator both null'),
    (null,true,'account_id','operator null account'), (daily_test.id(229),null,'enabled','operator null enabled')) as t(account,enabled,detail,description);
update private.profiles set discovery_on=false where user_id=daily_test.id(1);
select daily_test.error_call(1, 'select public.reveal_ambient_now()', 'prerequisite_missing', 'discovery', 'enabled demo requires discovery');
select daily_test.reset();
select daily_test.waiting(1, 2);
select daily_test.waiting(2, 3);
select daily_test.waiting(3, 4);
select daily_test.waiting(4, 5, daily_test.day()-30);
update private.encounter_views set revealed=true, revealed_report_day=daily_test.due_day() where encounter_id=daily_test.id(1002);
update private.profiles set discovery_on=false where user_id=daily_test.id(4);
insert into responses values ('demo_new',daily_test.as_caller(daily_test.id(1), 'select public.reveal_ambient_now()'));
select extensions.is((select result from responses where label='demo_new'),
    pg_catalog.jsonb_build_object('cards',pg_catalog.jsonb_build_array(daily_test.card(1)),'truncated',false), 'demo returns newly revealed authorized cards only');
select extensions.ok((select revealed and revealed_report_day is null from private.encounter_views where encounter_id=daily_test.id(1003)), 'demo advances hidden retained view without report membership');
select extensions.ok(not (select revealed from private.encounter_views where encounter_id=daily_test.id(1004)), 'demo leaves expired unretained view unrevealed');
select extensions.is((select pg_catalog.count(*) from private.report_deliveries where user_id=daily_test.id(1)), 0::bigint, 'demo closes no delivery key');
select extensions.is(daily_test.as_caller(daily_test.id(1), 'select public.reveal_ambient_now()'), '{"cards":[],"truncated":false}'::jsonb, 'demo repeat returns no previously revealed cards');
select extensions.is(daily_test.as_caller(daily_test.id(1), 'select public.get_daily_report()')->'cards', pg_catalog.jsonb_build_array(daily_test.card(2,3)), 'later daily report excludes all demo membership');
select daily_test.reset();
select daily_test.waiting(n,n+1,daily_test.day() - case when n=1 then 0 else 1 end) from pg_catalog.generate_series(1,201) as n;
select daily_test.waiting(300,2,daily_test.day(),daily_test.due_day(),daily_test.day()+1);
update private.encounter_views set favorite=true where encounter_id=daily_test.id(1300);
insert into responses values ('demo_cap',daily_test.as_caller(daily_test.id(1), 'select public.reveal_ambient_now()'));
select extensions.is(pg_catalog.jsonb_array_length((select result->'cards' from responses where label='demo_cap')), 200, 'demo cap follows dedup');
select extensions.is((select result->'truncated' from responses where label='demo_cap'), 'true'::jsonb, 'demo truncated iff additional authorized winners');
select extensions.ok(exists (select 1 from responses as r cross join lateral pg_catalog.jsonb_array_elements(r.result->'cards') as c
    where r.label='demo_cap' and c->>'encounter_id'=daily_test.id(1300)::text), 'demo favorite winner before cap');
select extensions.is((select pg_catalog.count(*) from private.encounter_views where viewer_id=daily_test.id(1) and revealed and revealed_report_day is null),
    202::bigint, 'demo reveals beyond response cap, without report membership');

select * from extensions.finish();
rollback;
