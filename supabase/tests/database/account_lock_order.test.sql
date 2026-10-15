begin;
create extension if not exists pgtap with schema extensions;
-- Sorted shared helper 1 + four callers x 2 + actual pg_locks 4 + collision 3 = 16.
select extensions.plan(16);
select extensions.ok(pg_catalog.strpos(p.prosrc,'select distinct pg_catalog.hashtext(a.id::text)')>0
    and pg_catalog.strpos(p.prosrc,'array_agg(k.value order by k.value)')>0
    and pg_catalog.strpos(p.prosrc,'into lock_keys') < pg_catalog.strpos(p.prosrc,'foreach lock_key')
    and pg_catalog.strpos(p.prosrc,'pg_advisory_xact_lock(31001, lock_key)')>0,
    'two-account locks compute distinct actual keys before acquiring in key order')
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
-- Generate a real hashtext collision (32-bit keys) without relying on a
-- particular PostgreSQL build's hard-coded hash values. Both IDs are distinct.
create temporary table collision_ids as
with keys as materialized (
    select ('cccccccc-0000-0000-0000-' || pg_catalog.lpad(n::text,12,'0'))::uuid as id
    from pg_catalog.generate_series(1,300000) as n
), hashed as materialized (
    select id, pg_catalog.hashtext(id::text) as lock_key from keys
)
select pg_catalog.min(id::text)::uuid as account_a, pg_catalog.max(id::text)::uuid as account_b, lock_key
from hashed where lock_key not in (
    pg_catalog.hashtext('dddddddd-0000-0000-0000-000000000001'),
    pg_catalog.hashtext('dddddddd-0000-0000-0000-000000000002'))
group by lock_key having pg_catalog.count(*) > 1 order by lock_key limit 1;
select extensions.is((select pg_catalog.count(*) from collision_ids),1::bigint,'fixture finds distinct UUIDs with colliding actual keys');
select private.lock_account_pair(c.account_b,c.account_a) from collision_ids as c;
select extensions.is((select pg_catalog.count(*) from pg_catalog.pg_locks as l
    where l.pid=pg_catalog.pg_backend_pid() and l.locktype='advisory' and l.classid=31001 and l.objsubid=2),
    3::bigint,'colliding accounts add exactly one advisory lock');
select extensions.ok(exists(select 1 from pg_catalog.pg_locks as l cross join collision_ids as c
    where l.pid=pg_catalog.pg_backend_pid() and l.locktype='advisory' and l.classid=31001 and l.objsubid=2
      and l.objid::bigint=(c.lock_key::bigint & 4294967295) and l.granted),
    'colliding account pair holds its shared actual key');
select * from extensions.finish();
rollback;
