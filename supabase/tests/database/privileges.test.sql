begin;

create extension if not exists pgtap with schema extensions;

-- 4 roles x 3 schemas x 3 object kinds = 36 catalog scans;
-- 7 schema ACLs + 12 default ACLs + 3 RPC inventory checks + 3 public
-- function denial scans + 1 service overload check = 62 assertions.
select extensions.plan(62);

create temporary table protected_schemas (name text primary key);
insert into protected_schemas values ('public'), ('private'), ('service');

-- Extension members in public keep their platform ACLs. Every application
-- object/overload is checked, including columns and objects added later.
select extensions.ok(not exists (
    select 1 from pg_catalog.pg_class as c
    where c.relnamespace = s.name::regnamespace and c.relkind in ('r', 'p', 'v', 'm', 'f')
      and not exists (select 1 from pg_catalog.pg_depend as d
          where d.classid = 'pg_catalog.pg_class'::regclass and d.objid = c.oid
            and d.refclassid = 'pg_catalog.pg_extension'::regclass and d.deptype = 'e')
      and case when r.role_name = 'PUBLIC' then exists (
          select 1 from pg_catalog.aclexplode(coalesce(c.relacl, pg_catalog.acldefault('r', c.relowner))) as a
          where a.grantee = 0
      ) or exists (
          select 1 from pg_catalog.pg_attribute as att
          cross join lateral pg_catalog.aclexplode(att.attacl) as a
          where att.attrelid = c.oid and att.attnum > 0 and not att.attisdropped and a.grantee = 0
      ) else pg_catalog.has_table_privilege(r.role_name, c.oid,
          'select, insert, update, delete, truncate, references, trigger, maintain')
          or pg_catalog.has_any_column_privilege(r.role_name, c.oid, 'select, insert, update, references') end
), r.role_name || ' has no ' || s.name || ' application table/column privileges')
from protected_schemas as s cross join (values ('PUBLIC'), ('anon'), ('authenticated'), ('service_role')) as r(role_name);

select extensions.ok(not exists (
    select 1 from pg_catalog.pg_class as c
    where c.relnamespace = s.name::regnamespace and c.relkind = 'S'
      and not exists (select 1 from pg_catalog.pg_depend as d
          where d.classid = 'pg_catalog.pg_class'::regclass and d.objid = c.oid
            and d.refclassid = 'pg_catalog.pg_extension'::regclass and d.deptype = 'e')
      and case when r.role_name = 'PUBLIC' then exists (
          select 1 from pg_catalog.aclexplode(coalesce(c.relacl, pg_catalog.acldefault('s', c.relowner))) as a where a.grantee = 0
      ) else pg_catalog.has_sequence_privilege(r.role_name, c.oid, 'usage, select, update') end
), r.role_name || ' has no ' || s.name || ' application sequence privileges')
from protected_schemas as s cross join (values ('PUBLIC'), ('anon'), ('authenticated'), ('service_role')) as r(role_name);

-- Public authenticated functions and service service_role functions are the
-- only deliberate function grants; all private helpers remain inaccessible.
select extensions.ok(not exists (
    select 1 from pg_catalog.pg_proc as p
    where p.pronamespace = s.name::regnamespace
      and not (s.name = 'public' and r.role_name = 'authenticated')
      and not (s.name = 'service' and r.role_name = 'service_role')
      and not exists (select 1 from pg_catalog.pg_depend as d
          where d.classid = 'pg_catalog.pg_proc'::regclass and d.objid = p.oid
            and d.refclassid = 'pg_catalog.pg_extension'::regclass and d.deptype = 'e')
      and case when r.role_name = 'PUBLIC' then exists (
          select 1 from pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) as a where a.grantee = 0
      ) else pg_catalog.has_function_privilege(r.role_name, p.oid, 'execute') end
), r.role_name || ' has only intended ' || s.name || ' function privileges')
from protected_schemas as s cross join (values ('PUBLIC'), ('anon'), ('authenticated'), ('service_role')) as r(role_name);

select extensions.ok(not exists (
    select 1 from pg_catalog.aclexplode(coalesce(n.nspacl, pg_catalog.acldefault('n', n.nspowner))) as a
    where a.grantee = 0
), s.name || ' has no PUBLIC schema privileges')
from protected_schemas as s join pg_catalog.pg_namespace as n on n.nspname = s.name
where s.name in ('private', 'service');
select extensions.ok(not pg_catalog.has_schema_privilege(r.name, 'private', 'usage, create'), r.name || ' cannot use private')
from (values ('anon'), ('authenticated'), ('service_role')) as r(name);
select extensions.ok(not pg_catalog.has_schema_privilege(r.name, 'service', 'usage, create'), r.name || ' cannot use service')
from (values ('anon'), ('authenticated')) as r(name);

-- Merge the effective global default with the schema-local additions. Checking
-- only schema-local REVOKEs misses PostgreSQL's global PUBLIC EXECUTE default.
-- In public, scan only postgres, the migration owner. Exclude supabase_admin's
-- platform object defaults and pg_database_owner's built-in PUBLIC EXECUTE
-- default: postgres cannot alter either role's defaults. Private and service
-- still include every owner with schema-local ACLs and the schema owner.
select extensions.ok(not exists (
    select 1
    from (select distinct d.defaclrole as owner_id from pg_catalog.pg_default_acl as d
          where d.defaclnamespace in (0, s.name::regnamespace)
          union select n.nspowner from pg_catalog.pg_namespace as n where n.nspname = s.name) as owners
    cross join (values ('r'::"char"), ('S'::"char"), ('f'::"char")) as k(kind)
    cross join lateral pg_catalog.aclexplode(coalesce((select d.defaclacl from pg_catalog.pg_default_acl as d
        where d.defaclrole = owners.owner_id and d.defaclnamespace = 0 and d.defaclobjtype = k.kind),
        pg_catalog.acldefault(case when k.kind = 'S' then 's'::"char" else k.kind end, owners.owner_id)) ||
        coalesce((select d.defaclacl from pg_catalog.pg_default_acl as d
        where d.defaclrole = owners.owner_id and d.defaclnamespace = s.name::regnamespace and d.defaclobjtype = k.kind),
        '{}'::aclitem[])) as a
    where (s.name <> 'public' or owners.owner_id = 'postgres'::regrole)
      and a.grantee = case when r.role_name = 'PUBLIC' then 0::oid else pg_catalog.to_regrole(r.role_name)::oid end
), r.role_name || ' has no implicit object defaults in ' || s.name)
from protected_schemas as s cross join (values ('PUBLIC'), ('anon'), ('authenticated'), ('service_role')) as r(role_name);

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
    ('public.get_encounter_card(uuid)'),
    ('public.get_encounter_feed()'),
    ('public.list_encounter_favorites()'),
    ('public.set_encounter_favorite(uuid,boolean)'),
    ('public.save_link(uuid,uuid)'),
    ('public.unsave_link(uuid,uuid)'),
    ('public.list_saved_links()'),
    ('public.block_encounter_person(uuid)'),
    ('public.list_blocks()'),
    ('public.unblock(uuid)'),
    ('public.report_encounter_person(uuid,text,uuid)'),
    ('public.delete_encounter(uuid)'),
    ('public.get_report_settings()'),
    ('public.set_report_time(integer,integer)'),
    ('public.set_notifications_enabled(boolean)'),
    ('public.get_daily_report()'),
    ('public.reveal_ambient_now()'),
    ('public.list_own_links()'),
    ('public.update_own_link(uuid,text,text,text,text[],text,text)'),
    ('public.delete_own_link(uuid)'),
    ('public.reorder_own_links(uuid[])'),
    ('public.get_github_connection()'),
    ('public.disconnect_github()'),
    ('public.start_session()'),
    ('public.stop_session()'),
    ('public.get_own_session()'),
    ('public.issue_qr_code()'),
    ('public.cancel_qr_code()'),
    ('public.redeem_qr_code(text)'),
    ('public.delete_own_account()');

select extensions.is((select pg_catalog.count(*) from unit3_rpc_signatures as f
    join pg_catalog.pg_proc as p on p.oid = pg_catalog.to_regprocedure(f.signature)
    where p.pronamespace = 'public'::regnamespace), 42::bigint, 'all forty-two Unit 3, Unit 4 and Unit 5 public RPCs exist');

select extensions.ok(not exists (
    select 1 from pg_catalog.pg_proc as p
    where p.pronamespace = 'public'::regnamespace
      and not exists (
          select 1 from pg_catalog.pg_depend as d
          where d.classid = 'pg_catalog.pg_proc'::regclass and d.objid = p.oid
            and d.refclassid = 'pg_catalog.pg_extension'::regclass and d.deptype = 'e'
      )
      and case when r.role_name = 'PUBLIC' then exists (
        select 1 from pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) as a
        where a.grantee = 0 and a.privilege_type = 'EXECUTE'
    ) else pg_catalog.has_function_privilege(r.role_name, p.oid, 'execute') end
), r.role_name || ' cannot execute any non-extension public function')
from (values ('PUBLIC'), ('anon'), ('service_role')) as r(role_name);

select extensions.is((select pg_catalog.count(*) from pg_catalog.pg_proc as p
    where p.pronamespace = 'public'::regnamespace and not exists (
        select 1 from pg_catalog.pg_depend as d where d.classid = 'pg_catalog.pg_proc'::regclass and d.objid = p.oid
            and d.refclassid = 'pg_catalog.pg_extension'::regclass and d.deptype = 'e')),
    42::bigint, 'no unlisted public functions or overloads');

create temporary table service_rpc_signatures (signature text primary key);
insert into service_rpc_signatures values ('service.get_github_identity(uuid)'),
    ('service.sync_github_identity(uuid,text,text,text[])'),
    ('service.save_github_link(uuid,text,text,text,text,text,text,text[],text,text,boolean)'),
    ('service.record_github_fetch(uuid)'),
    ('service.set_demo_reveal_enabled(uuid,boolean)'),
    ('service.list_open_reports(uuid)'),
    ('service.resolve_report(uuid,uuid,text)');
select extensions.is((select pg_catalog.count(*) from service_rpc_signatures as f
    join pg_catalog.pg_proc as p on p.oid = pg_catalog.to_regprocedure(f.signature)
    where p.pronamespace = 'service'::regnamespace), 7::bigint, 'all seven service RPC signatures exist');
select extensions.is((select pg_catalog.count(*) from pg_catalog.pg_proc as p where p.pronamespace = 'service'::regnamespace),
    7::bigint, 'no unlisted service functions or overloads');

select * from extensions.finish();

rollback;
