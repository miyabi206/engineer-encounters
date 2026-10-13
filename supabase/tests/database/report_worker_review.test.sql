begin;
create extension if not exists pgtap with schema extensions;
create schema report_worker_test;
grant usage on schema report_worker_test to authenticated;
create function report_worker_test.id(n integer)
returns uuid language sql immutable set search_path = '' as $$
    select ('eeeeeeee-0000-0000-0000-' || pg_catalog.lpad(n::text, 12, '0'))::uuid;
$$;
create function report_worker_test.call(n integer, statement text)
returns jsonb language plpgsql set search_path = '' as $$
declare result jsonb;
begin
    begin
        set local role authenticated;
        perform pg_catalog.set_config('request.jwt.claim.sub', '', true);
        perform pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object(
            'sub', report_worker_test.id(n), 'role', 'authenticated')::text, true);
        execute statement into result;
    exception when others then reset role; raise; end;
    reset role;
    return result;
end;
$$;
create function report_worker_test.zone(n integer, zone_name text)
returns void language plpgsql set search_path = '' as $$
begin
    begin
        set local role authenticated;
        perform pg_catalog.set_config('request.jwt.claim.sub', '', true);
        perform pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object(
            'sub', report_worker_test.id(n), 'role', 'authenticated')::text, true);
        perform public.register_time_zone(zone_name);
    exception when others then reset role; raise; end;
    reset role;
end;
$$;
grant execute on all functions in schema report_worker_test to authenticated;
insert into auth.users (id) select report_worker_test.id(n) from pg_catalog.generate_series(1,7) as n;
insert into private.profiles (user_id, age_18_declared, terms_version, privacy_version, discovery_on)
select report_worker_test.id(n), true, 'draft', 'draft', true from pg_catalog.generate_series(1,6) as n;
insert into private.notification_preferences (user_id, time_zone, report_hour, report_minute)
select report_worker_test.id(n), case when n=4 then 'No/SuchZone' else 'UTC' end, 0, 0
from pg_catalog.generate_series(1,5) as n;
update private.profiles set moderation_state='hidden' where user_id=report_worker_test.id(5);
insert into private.report_deliveries (user_id,report_day,status) values
    (report_worker_test.id(1),(pg_catalog.now() at time zone 'UTC')::date,'closed'),
    (report_worker_test.id(3),(pg_catalog.now() at time zone 'UTC')::date,'open');
insert into private.encounters (encounter_id,user_a,user_b,kind,day_a,day_b)
values (report_worker_test.id(101),report_worker_test.id(1),report_worker_test.id(2),'qr',
    (pg_catalog.now() at time zone 'UTC')::date,(pg_catalog.now() at time zone 'UTC')::date),
    (report_worker_test.id(103),report_worker_test.id(2),report_worker_test.id(3),'ambient',
    (pg_catalog.now() at time zone 'UTC')::date,(pg_catalog.now() at time zone 'UTC')::date);
insert into private.encounter_views (encounter_id,viewer_id,revealed,reveal_report_day)
values (report_worker_test.id(101),report_worker_test.id(1),true,(pg_catalog.now() at time zone 'UTC')::date),
    (report_worker_test.id(103),report_worker_test.id(3),false,(pg_catalog.now() at time zone 'UTC')::date);
create temporary table worker_results (label text primary key, value jsonb);
insert into worker_results values ('before', (select pg_catalog.jsonb_build_array(d.ctid::text,d.xmin::text,d.xmax::text,d.status)
    from private.report_deliveries as d where d.user_id=report_worker_test.id(1)));

-- Procedure/ACL 9 + due predicate 5 + fast path 8 + isolation 5 + zone source 9
-- + transition selection 5 = 41. No CALL: pgTAP runs in one transaction.
select extensions.plan(41);
select extensions.ok(p.prokind='p' and not p.prosecdef and p.proconfig is null,
    'worker is an invoker procedure without SET, so top-level CALL can commit')
from pg_catalog.pg_proc as p where p.oid='private.run_due_reports(timestamptz)'::regprocedure;
select extensions.ok(pg_catalog.strpos(p.prosrc,'from private.due_report_accounts(report_at)')>0,
    'worker visits only read-only due selection') from pg_catalog.pg_proc as p
where p.oid='private.run_due_reports(timestamptz)'::regprocedure;
select extensions.ok(p.prosrc ~ 'end;[[:space:]]*--[^\n]*[[:space:]]*commit;[[:space:]]*end loop;',
    'each step commits outside its exception block, before the next account')
from pg_catalog.pg_proc as p where p.oid='private.run_due_reports(timestamptz)'::regprocedure;
select extensions.ok(pg_catalog.strpos(p.prosrc,'exception when others then')>0,
    'one failed account is rolled back inside its own exception subtransaction')
from pg_catalog.pg_proc as p where p.oid='private.run_due_reports(timestamptz)'::regprocedure;
select extensions.is((select command from cron.job where jobname='encounters-daily-reports'),
    'call private.run_due_reports();','Cron command is a plain top-level CALL');
select extensions.ok(not pg_catalog.has_function_privilege(r.name,p.oid,'execute'),
    r.name || ' cannot execute the committing worker')
from pg_catalog.pg_proc as p cross join (values ('anon'),('authenticated'),('service_role')) as r(name)
where p.oid='private.run_due_reports(timestamptz)'::regprocedure;
select extensions.ok(not exists (select 1 from pg_catalog.aclexplode(p.proacl) as a
    where a.grantee=0 and a.privilege_type='EXECUTE'), 'PUBLIC cannot execute the worker')
from pg_catalog.pg_proc as p where p.oid='private.run_due_reports(timestamptz)'::regprocedure;

select extensions.is(array(select d.account_id from private.due_report_accounts(pg_catalog.now()) as d
    order by d.account_id), array[report_worker_test.id(2),report_worker_test.id(3)],
    'only ready valid-zone accounts with an unclosed due day are selected');
select extensions.ok(not exists(select 1 from pg_catalog.pg_locks as l
    where l.pid=pg_catalog.pg_backend_pid() and l.locktype='advisory' and l.classid=31001),
    'due selection takes no advisory account locks');
select extensions.is((select pg_catalog.count(*) from private.report_deliveries),2::bigint,
    'due selection writes no delivery');
select extensions.ok((select not revealed from private.encounter_views where viewer_id=report_worker_test.id(3)),
    'due selection does not run a report step');
select extensions.ok(not exists(select 1 from private.due_report_accounts(null)),
    'null predicate clock selects nothing');

-- A statement trigger rejects even an attempted INSERT ON CONFLICT or empty
-- UPDATE. The caught-up step and both readers must skip the write path entirely.
create function report_worker_test.reject_write()
returns trigger language plpgsql set search_path = '' as $$
begin raise exception 'unexpected_report_write'; end;
$$;
create trigger reject_delivery_write before insert or update or delete on private.report_deliveries
for each statement execute function report_worker_test.reject_write();
create trigger reject_view_write before update on private.encounter_views
for each statement execute function report_worker_test.reject_write();
select extensions.lives_ok($q$insert into worker_results values ('step',private.run_account_report(report_worker_test.id(1)))$q$,
    'caught-up account step attempts no writes');
select extensions.lives_ok($q$insert into worker_results values ('feed',report_worker_test.call(1,'select public.get_encounter_feed()'))$q$,
    'caught-up feed attempts no report writes');
select extensions.lives_ok($q$insert into worker_results values ('daily',report_worker_test.call(1,'select public.get_daily_report()'))$q$,
    'caught-up daily report attempts no writes');
select extensions.is((select value from worker_results where label='step'),pg_catalog.jsonb_build_object(
    'report_day',(pg_catalog.now() at time zone 'UTC')::date,'newly_revealed_encounter_ids','[]'::jsonb,'closed',false),
    'fast path preserves the report step wire result');
select extensions.is(pg_catalog.jsonb_array_length((select value->'cards' from worker_results where label='feed')),1,
    'fast feed still assembles the visible card');
select extensions.ok(not exists(select 1 from pg_catalog.pg_locks as l
    where l.pid=pg_catalog.pg_backend_pid() and l.locktype='advisory' and l.classid=31001),
    'step/feed/daily fast paths take no account lock');
select extensions.ok(not exists(select 1 from pg_catalog.pg_locks as l
    where l.pid=pg_catalog.pg_backend_pid() and l.mode='RowShareLock'
      and l.relation in ('private.report_deliveries'::regclass,'private.encounter_views'::regclass)),
    'fast paths take no SELECT FOR UPDATE row-lock relation mode');
select extensions.is((select pg_catalog.jsonb_build_array(d.ctid::text,d.xmin::text,d.xmax::text,d.status)
    from private.report_deliveries as d where d.user_id=report_worker_test.id(1)),
    (select value from worker_results where label='before'),'delivery tuple and row-lock metadata are unchanged');
drop trigger reject_delivery_write on private.report_deliveries;
drop trigger reject_view_write on private.encounter_views;

select extensions.is(private.run_account_report(report_worker_test.id(2))->'closed','true'::jsonb,
    'one account step succeeds independently');
create function report_worker_test.deadlock_step()
returns trigger language plpgsql set search_path = '' as $$
begin
    if new.user_id=report_worker_test.id(3) and new.status='closed' then
        raise exception using errcode='40P01', message='injected_report_deadlock';
    end if;
    return new;
end;
$$;
create trigger deadlock_step before update on private.report_deliveries
for each row execute function report_worker_test.deadlock_step();
select extensions.throws_ok('select private.run_account_report(report_worker_test.id(3))',
    '40P01','injected_report_deadlock','deadlock fails only that step');
select extensions.is((select status from private.report_deliveries where user_id=report_worker_test.id(2)),
    'closed','earlier successful account survives a later failure');
select extensions.ok((select not v.revealed and d.status='open' from private.encounter_views as v
    join private.report_deliveries as d on d.user_id=v.viewer_id
    where v.viewer_id=report_worker_test.id(3)), 'failed step rolls back its reveal and delivery together');
select extensions.is(array(select d.account_id from private.due_report_accounts(pg_catalog.now()) as d),
    array[report_worker_test.id(3)],'failed account remains due; successful account is excluded');
drop trigger deadlock_step on private.report_deliveries;

select extensions.ok(not exists (select 1 from pg_catalog.pg_proc as p
    where p.pronamespace in ('public'::regnamespace,'private'::regnamespace,'service'::regnamespace)
      and pg_catalog.strpos(p.prosrc,'pg_timezone_names')>0), 'no installed application routine enumerates time zones');
select extensions.lives_ok($q$select report_worker_test.zone(1,'Asia/Tokyo')$q$,
    'registration accepts an installed shared zone');
select extensions.ok(private.local_report_instant(report_worker_test.id(1),date '2026-10-13') is not null,
    'local report instant accepts the registered zone');
select extensions.ok(private.run_account_report(report_worker_test.id(1))->>'report_day' is not null,
    'account step accepts that same registered zone');
select extensions.is(pg_catalog.jsonb_array_length(report_worker_test.call(1,'select public.get_encounter_feed()')->'cards'),1,
    'visibility accepts the same registered zone');
-- Removing an installed name simulates a lookup not yet refreshed for tzdata.
-- Every consumer must reject it consistently, even though PostgreSQL knows it.
delete from private.iana_time_zones where name='Asia/Tokyo';
select extensions.throws_ok($q$select report_worker_test.zone(1,'Asia/Tokyo')$q$,
    'P0001','invalid_input','registration rejects a name absent from the shared source');
select extensions.throws_ok($q$select private.local_report_instant(report_worker_test.id(1),date '2026-10-13')$q$,
    'P0001','account_not_ready','local instant fails closed for an invalid stored zone');
select extensions.is(private.run_account_report(report_worker_test.id(1)),
    '{"report_day":null,"newly_revealed_encounter_ids":[],"closed":false}'::jsonb,'report step fails closed for that same zone');
select extensions.is(report_worker_test.call(1,'select public.get_encounter_feed()')->'cards','[]'::jsonb,
    'ordinary retention gate fails closed for that same zone');
insert into private.iana_time_zones(name) values ('Asia/Tokyo');

update private.notification_preferences set time_zone='America/New_York',report_hour=1,report_minute=30
where user_id=report_worker_test.id(2);
delete from private.report_deliveries where user_id=report_worker_test.id(2);
insert into private.report_deliveries values (report_worker_test.id(2),date '2026-10-31','closed');
select extensions.ok(not exists(select 1 from private.due_report_accounts(timestamptz '2026-11-01 05:29:59.999999+00')
    where account_id=report_worker_test.id(2)), 'due predicate waits before first repeated cutoff');
select extensions.ok(exists(select 1 from private.due_report_accounts(timestamptz '2026-11-01 05:30+00')
    where account_id=report_worker_test.id(2)), 'due predicate selects first repeated cutoff');
select extensions.ok(exists(select 1 from private.due_report_accounts(timestamptz '2026-11-01 06:10+00')
    where account_id=report_worker_test.id(2)), 'repeated clock moving backward does not lose a due report');
update private.notification_preferences set report_hour=2,report_minute=30 where user_id=report_worker_test.id(2);
insert into private.report_deliveries values (report_worker_test.id(2),date '2026-03-07','closed');
select extensions.ok(not exists(select 1 from private.due_report_accounts(timestamptz '2026-03-08 06:59:59.999999+00')
    where account_id=report_worker_test.id(2)), 'due predicate waits before advanced gap minute');
select extensions.ok(exists(select 1 from private.due_report_accounts(timestamptz '2026-03-08 07:00+00')
    where account_id=report_worker_test.id(2)), 'due predicate selects the first real gap minute');
select * from extensions.finish();
rollback;
