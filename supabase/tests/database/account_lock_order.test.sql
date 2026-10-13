begin;
create extension if not exists pgtap with schema extensions;
-- Sorted shared helper 1 + four callers x 2 + actual pg_locks 4 = 13.
select extensions.plan(13);
select extensions.ok(pg_catalog.strpos(p.prosrc,'select distinct a.id')>0
    and pg_catalog.strpos(p.prosrc,'order by a.id loop')>0,
    'all two-account locks use distinct ascending account UUIDs')
from pg_catalog.pg_proc as p where p.oid='private.lock_account_pair(uuid,uuid)'::regprocedure;
select extensions.ok(pg_catalog.strpos(p.prosrc,'perform private.lock_account_pair(')>0,
    t.signature || ' uses the shared ordered account lock helper')
from (values ('private.sync_github_identity(uuid,text,text,text[])'),
    ('private.report_encounter_person(uuid,text,uuid)'),('private.resolve_report(uuid,uuid,text)'),
    ('private.review_account(uuid,uuid,text)')) as t(signature)
join pg_catalog.pg_proc as p on p.oid=t.signature::regprocedure;
select extensions.ok(pg_catalog.strpos(p.prosrc,'pg_advisory_xact_lock(31001')=0,
    t.signature || ' cannot acquire a caller account lock before the sorted pair')
from (values ('private.sync_github_identity(uuid,text,text,text[])'),
    ('private.report_encounter_person(uuid,text,uuid)'),('private.resolve_report(uuid,uuid,text)'),
    ('private.review_account(uuid,uuid,text)')) as t(signature)
join pg_catalog.pg_proc as p on p.oid=t.signature::regprocedure;
-- Supply IDs in reverse order, inspect the actual advisory namespace/keys,
-- then call with duplicate IDs to pin the helper's one-account case too.
select private.lock_account_pair('dddddddd-0000-0000-0000-000000000002','dddddddd-0000-0000-0000-000000000001');
select extensions.is((select pg_catalog.count(*) from pg_catalog.pg_locks as l
    where l.pid=pg_catalog.pg_backend_pid() and l.locktype='advisory' and l.classid=31001 and l.objsubid=2),
    2::bigint,'reversed arguments take exactly the two account advisory locks');
select extensions.ok(exists(select 1 from pg_catalog.pg_locks as l
    where l.pid=pg_catalog.pg_backend_pid() and l.locktype='advisory' and l.classid=31001 and l.objsubid=2
      and l.objid::bigint=(pg_catalog.hashtext(t.id::text)::bigint & 4294967295)
      and l.mode='ExclusiveLock' and l.granted),t.id::text || ' account key is held')
from (values ('dddddddd-0000-0000-0000-000000000001'::uuid),
    ('dddddddd-0000-0000-0000-000000000002'::uuid)) as t(id);
select private.lock_account_pair('dddddddd-0000-0000-0000-000000000001','dddddddd-0000-0000-0000-000000000001');
select extensions.is((select pg_catalog.count(*) from pg_catalog.pg_locks as l
    where l.pid=pg_catalog.pg_backend_pid() and l.locktype='advisory' and l.classid=31001 and l.objsubid=2),
    2::bigint,'duplicate account IDs add no lock or alternate namespace');
select * from extensions.finish();
rollback;
