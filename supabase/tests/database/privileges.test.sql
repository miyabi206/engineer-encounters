begin;

create extension if not exists pgtap with schema extensions;

select extensions.plan(13);

-- Inspect the whole private catalog, including future objects and default ACLs.
select extensions.ok(not exists (
    select 1 from pg_catalog.pg_class as c
    where c.relnamespace = 'private'::regnamespace and c.relkind in ('r', 'p', 'v', 'm', 'f')
      and case when r.role_name = 'PUBLIC' then exists (
          select 1 from pg_catalog.aclexplode(coalesce(c.relacl, pg_catalog.acldefault('r', c.relowner))) as a
          where a.grantee = 0
      ) or exists (
          select 1 from pg_catalog.pg_attribute as att
          cross join lateral pg_catalog.aclexplode(att.attacl) as a
          where att.attrelid = c.oid and att.attnum > 0 and not att.attisdropped
            and a.grantee = 0
      ) else pg_catalog.has_table_privilege(r.role_name, c.oid,
          'select, insert, update, delete, truncate, references, trigger, maintain')
          or pg_catalog.has_any_column_privilege(r.role_name, c.oid, 'select, insert, update, references') end
), r.role_name || ' has no private table privileges')
from (values ('PUBLIC'), ('anon'), ('authenticated')) as r(role_name);

select extensions.ok(not exists (
    select 1 from pg_catalog.pg_class as c
    where c.relnamespace = 'private'::regnamespace and c.relkind = 'S'
      and case when r.role_name = 'PUBLIC' then exists (
          select 1 from pg_catalog.aclexplode(coalesce(c.relacl, pg_catalog.acldefault('s', c.relowner))) as a
          where a.grantee = 0
      ) else pg_catalog.has_sequence_privilege(r.role_name, c.oid, 'usage, select, update') end
), r.role_name || ' has no private sequence privileges')
from (values ('PUBLIC'), ('anon'), ('authenticated')) as r(role_name);

select extensions.ok(not exists (
    select 1 from pg_catalog.pg_proc as p
    where p.pronamespace = 'private'::regnamespace
      and case when r.role_name = 'PUBLIC' then exists (
          select 1 from pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) as a
          where a.grantee = 0
      ) else pg_catalog.has_function_privilege(r.role_name, p.oid, 'execute') end
), r.role_name || ' has no private function privileges')
from (values ('PUBLIC'), ('anon'), ('authenticated')) as r(role_name);

-- Resolve signatures, so overloads cannot accidentally stand in for the RPCs.
create temporary table unit3_rpc_signatures (signature text primary key);
insert into unit3_rpc_signatures values
    ('public.accept_declarations(boolean,text,text)'),
    ('public.register_time_zone(text)'),
    ('public.get_own_profile()'),
    ('public.update_own_profile(text,text,text)'),
    ('public.set_own_interests(text[])'),
    ('public.set_own_purposes(text[])'),
    ('public.set_minimum_shared_interests(integer)'),
    ('public.set_field_visibility(text,text)'),
    ('public.set_discovery(boolean)'),
    ('public.list_interests()'),
    ('public.issue_token_batch(bigint)'),
    ('public.submit_receipts(jsonb)'),
    ('public.get_encounter_card(uuid)');

select extensions.is((select pg_catalog.count(*) from unit3_rpc_signatures as f
    join pg_catalog.pg_proc as p on p.oid = pg_catalog.to_regprocedure(f.signature)
    where p.pronamespace = 'public'::regnamespace), 13::bigint, 'all thirteen Unit 3 public RPCs exist');

select extensions.ok(not exists (
    select 1 from pg_catalog.pg_proc as p
    join unit3_rpc_signatures as f on p.oid = pg_catalog.to_regprocedure(f.signature)
    where case when r.role_name = 'PUBLIC' then exists (
        select 1 from pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) as a
        where a.grantee = 0 and a.privilege_type = 'EXECUTE'
    ) else pg_catalog.has_function_privilege(r.role_name, p.oid, 'execute') end
), r.role_name || ' cannot execute any Unit 3 public RPC')
from (values ('PUBLIC'), ('anon'), ('service_role')) as r(role_name);

select * from extensions.finish();

rollback;
