begin;
create extension if not exists pgtap with schema extensions;
create schema links_github_test;
grant usage on schema links_github_test to anon, authenticated, service_role;
grant execute on all functions in schema extensions to anon, authenticated, service_role;

create function links_github_test.id(n integer)
returns uuid language sql immutable set search_path = '' as $$
    select ('eeeeeeee-0000-0000-0000-' || pg_catalog.lpad(n::text, 12, '0'))::uuid;
$$;

-- Invoker helpers restore the owner role even when the RPC raises.
create function links_github_test.as_role(role_name text, statement text, caller uuid default null)
returns jsonb language plpgsql set search_path = '' as $$
declare result jsonb;
begin
    begin
        execute pg_catalog.format('set local role %I', role_name);
        perform pg_catalog.set_config('request.jwt.claim.sub', '', true);
        perform pg_catalog.set_config('request.jwt.claims',
            pg_catalog.jsonb_build_object('sub', caller, 'role', role_name)::text, true);
        execute 'select ' || statement into result;
    exception when others then
        reset role;
        raise;
    end;
    reset role;
    return result;
end;
$$;
create function links_github_test.as_caller(caller uuid, statement text)
returns jsonb language sql set search_path = '' as $$
    select links_github_test.as_role('authenticated', statement, caller);
$$;
create function links_github_test.as_service(statement text)
returns jsonb language sql set search_path = '' as $$
    select links_github_test.as_role('service_role', statement);
$$;
-- Unit 3's void RPCs cannot be assigned to the JSON-returning helper.
create function links_github_test.as_caller_void(caller uuid, statement text)
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
create function links_github_test.expect_error(statement text, code text, fields text, description text)
returns text language plpgsql set search_path = pg_catalog, extensions as $$
declare actual_state text; actual_message text; actual_detail text;
begin
    begin
        execute statement;
    exception when others then
        get stacked diagnostics actual_state = returned_sqlstate,
            actual_message = message_text, actual_detail = pg_exception_detail;
        return extensions.is(pg_catalog.jsonb_build_array(actual_state, actual_message, coalesce(actual_detail, '')),
            pg_catalog.jsonb_build_array('P0001'::text, code, fields), description);
    end;
    return extensions.fail(description || ': expected exception');
end;
$$;

-- Expected objects use known fixture constants.
create function links_github_test.expected_link(n integer, expected_order integer, level text default 'private')
returns jsonb language sql immutable set search_path = '' as $$
    select pg_catalog.jsonb_build_object('link_id', links_github_test.id(n), 'source', 'github',
        'source_item_id', n::text, 'url', 'https://github.com/owner-1/repo-' || n,
        'title', 'Title ' || n, 'description', 'Description ' || n, 'main_language', 'Swift',
        'tags', array['a', 'b'], 'opening_text', 'Opening ' || n,
        'visibility', level, 'verification_state', 'verified', 'display_order', expected_order);
$$;
create table links_github_test.results (label text primary key, value jsonb not null);
-- Exercise Unit 4's future saved_links ON DELETE CASCADE boundary without
-- creating a Unit 4 application table or RPC.
create table links_github_test.saved_references (
    reference_id integer primary key,
    link_id uuid not null references private.external_links (link_id) on delete cascade
);
create function links_github_test.removal_snapshot()
returns jsonb language sql stable set search_path = '' as $$
    select pg_catalog.jsonb_build_object(
        'links', (select coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(l) order by l.link_id), '[]'::jsonb)
            from private.external_links as l),
        'cache', (select coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(c) order by c.user_id), '[]'::jsonb)
            from private.linked_identities as c),
        'identities', (select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'id', i.id, 'user_id', i.user_id, 'provider', i.provider, 'provider_id', i.provider_id) order by i.id), '[]'::jsonb)
            from auth.identities as i where i.user_id in (links_github_test.id(1), links_github_test.id(2), links_github_test.id(3))),
        'references', (select coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r) order by r.reference_id), '[]'::jsonb)
            from links_github_test.saved_references as r));
$$;
create function links_github_test.auth_snapshot()
returns jsonb language sql stable set search_path = '' as $$
    select pg_catalog.jsonb_build_object(
        'users', (select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(u) order by u.id) from auth.users as u
            where u.id in (links_github_test.id(1), links_github_test.id(2), links_github_test.id(3))),
        'identities', (select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(i) order by i.id) from auth.identities as i
            where i.user_id in (links_github_test.id(1), links_github_test.id(2), links_github_test.id(3))));
$$;
create table links_github_test.rpcs (
    schema_name text, name text, signature text, argument_names text[], arguments text[], call text
);
insert into links_github_test.rpcs (schema_name, name, signature, argument_names, arguments) values
    ('public', 'list_own_links', 'public.list_own_links()', null, '{}'::text[]),
    ('public', 'update_own_link', 'public.update_own_link(uuid,text,text,text,text[],text,text)',
        array['link_id','title','description','main_language','tags','opening_text','visibility'],
        array['links_github_test.id(201)', '''Title''', '''''', 'null', '''{}''::text[]', '''''', '''private''']),
    ('public', 'delete_own_link', 'public.delete_own_link(uuid)', array['link_id'], array['links_github_test.id(201)']),
    ('public', 'reorder_own_links', 'public.reorder_own_links(uuid[])', array['link_ids'],
        array['array[links_github_test.id(201),links_github_test.id(202)]']),
    ('public', 'get_github_connection', 'public.get_github_connection()', null, '{}'::text[]),
    ('public', 'disconnect_github', 'public.disconnect_github()', null, '{}'::text[]),
    ('service', 'get_github_identity', 'service.get_github_identity(uuid)', array['account_id'], array['links_github_test.id(1)']),
    ('service', 'sync_github_identity', 'service.sync_github_identity(uuid,text,text,text[])',
        array['account_id','provider_user_id','handle','verified_addresses'],
        array['links_github_test.id(1)', '''101''', '''owner-1''', '''{}''::text[]']),
    ('service', 'save_github_link', 'service.save_github_link(uuid,text,text,text,text,text,text,text[],text,text,boolean)',
        array['account_id','repository_id','repository_owner_id','url','title','description','main_language','tags','opening_text','visibility','replace_existing'],
        array['links_github_test.id(1)', '''204''', '''101''', '''https://github.com/owner-1/repo-204''',
            '''Title''', '''''', 'null', '''{}''::text[]', '''''', '''private''', 'false']),
    ('service', 'record_github_fetch', 'service.record_github_fetch(uuid)', array['account_id'], array['links_github_test.id(1)']);
update links_github_test.rpcs set call = schema_name || '.' || name || '(' || pg_catalog.array_to_string(arguments, ',') || ')';

insert into auth.users (id) select links_github_test.id(n) from pg_catalog.generate_series(1, 5) as n;
insert into auth.identities (id, user_id, provider, provider_id, identity_data, created_at, updated_at)
select links_github_test.id(800+n), links_github_test.id(n), 'github', (100+n)::text,
    pg_catalog.jsonb_build_object('sub', (100+n)::text), pg_catalog.now(), pg_catalog.now()
from pg_catalog.generate_series(1, 3) as n;
insert into auth.identities (id, user_id, provider, provider_id, identity_data, created_at, updated_at)
values (links_github_test.id(900), links_github_test.id(1), 'apple', 'apple-1', '{"sub":"apple-1"}', pg_catalog.now(), pg_catalog.now());
insert into private.profiles (user_id, display_name, introduction, age_18_declared, terms_version, privacy_version)
select links_github_test.id(n), 'Owner', 'Introduction', true, 'draft', 'draft' from (values (1), (2), (4)) as v(n);
insert into private.notification_preferences (user_id, time_zone)
select links_github_test.id(n), 'UTC' from (values (1), (2), (4)) as v(n);
insert into private.interests (interest_id, label_ja, label_en) values ('link-test', 'link', 'link');
insert into private.user_interests (user_id, interest_id) values (links_github_test.id(1), 'link-test');
insert into private.external_links (link_id, owner_id, source, source_item_id, url, title, description,
    main_language, tags, opening_text, visibility, verification_state, display_order)
select links_github_test.id(n), links_github_test.id(case when n = 203 then 2 else 1 end),
    'github', n::text, 'https://github.com/owner-1/repo-' || n, 'Title ' || n, 'Description ' || n,
    'Swift', array['a','b'], 'Opening ' || n, 'private', 'verified', 4
from pg_catalog.generate_series(201, 203) as n;
insert into links_github_test.saved_references values (1, links_github_test.id(201)), (2, links_github_test.id(202));
delete from auth.users where id = links_github_test.id(5);
grant execute on all functions in schema links_github_test to anon, authenticated, service_role;

-- Catalog/roles: 67; Live errors: 20; invalid inputs: 101;
-- reads/sync: 17; resources: 4; update/reorder/bounds: 9; save: 12;
-- inclusive sync/ID bounds: 3; link cap: 7; fetch budget: 8;
-- delete/disconnect/cache/cascade: 38. Total: 286.
select extensions.plan(286);

select extensions.ok((select relrowsecurity from pg_catalog.pg_class
    where oid = 'private.linked_identities'::regclass), 'linked identity cache has RLS');

-- 50 contract checks: 5 per exact signature.
select extensions.ok(p.prosecdef, r.signature || ' is security definer')
from links_github_test.rpcs as r join pg_catalog.pg_proc as p on p.oid = pg_catalog.to_regprocedure(r.signature);
select extensions.ok('search_path=""' = any(p.proconfig), r.signature || ' has an empty search path')
from links_github_test.rpcs as r join pg_catalog.pg_proc as p on p.oid = pg_catalog.to_regprocedure(r.signature);
select extensions.is(p.proargnames, r.argument_names, r.signature || ' preserves wire names and order')
from links_github_test.rpcs as r join pg_catalog.pg_proc as p on p.oid = pg_catalog.to_regprocedure(r.signature);
select extensions.is(pg_catalog.format_type(p.prorettype, null), 'jsonb', r.signature || ' returns jsonb')
from links_github_test.rpcs as r join pg_catalog.pg_proc as p on p.oid = pg_catalog.to_regprocedure(r.signature);
select extensions.ok(pg_catalog.has_function_privilege(case when r.schema_name = 'public' then 'authenticated' else 'service_role' end,
    r.signature, 'execute'), r.signature || ' grants its intended caller') from links_github_test.rpcs as r;

-- 2 schema denials, 8 service call denials, 6 public call denials.
select extensions.ok(not pg_catalog.has_schema_privilege(r.name, 'service', 'usage, create'), r.name || ' cannot use service')
from (values ('anon'), ('authenticated')) as r(name);
select extensions.throws_ok(pg_catalog.format('select links_github_test.as_role(%L,%L)', role.name, r.call),
    '42501', 'permission denied for schema service', role.name || ' denied ' || r.signature)
from links_github_test.rpcs as r cross join (values ('anon'), ('authenticated')) as role(name) where r.schema_name = 'service';
select extensions.throws_ok(pg_catalog.format('select links_github_test.as_role(''service_role'',%L)', r.call),
    '42501', 'permission denied for function ' || r.name, 'service_role denied ' || r.signature)
from links_github_test.rpcs as r where r.schema_name = 'public';

-- 12 public Live errors, 8 service missing/deleted accounts.
select links_github_test.expect_error(pg_catalog.format('select links_github_test.as_caller(%L::uuid,%L)', caller.id, r.call),
    'not_authenticated', '', r.signature || ' rejects absent/deleted caller')
from links_github_test.rpcs as r cross join (values (null::uuid), (links_github_test.id(5))) as caller(id)
where r.schema_name = 'public';
select links_github_test.expect_error(pg_catalog.format('select links_github_test.as_service(%L)',
    pg_catalog.replace(r.call, 'links_github_test.id(1)', 'links_github_test.id(' || caller.n || ')')),
    'not_authenticated', '', r.signature || ' rejects absent/deleted account')
from links_github_test.rpcs as r cross join (values (5), (6)) as caller(n) where r.schema_name = 'service';

-- 98 single-parameter cases: metadata 19 x 2 RPCs, decimal IDs 8 x 3
-- parameters, and 36 identifier/array/handle/address/URL/boolean cases.
create table links_github_test.invalid_cases (rpc_name text, field text, expression text, label text);
insert into links_github_test.invalid_cases
select rpc.name, cases.field, cases.expression, cases.label
from (values ('update_own_link'), ('save_github_link')) as rpc(name)
cross join (values
    ('title', 'null', 'null title'),
    ('title', $arg$''$arg$, 'empty title'),
    ('title', $arg$U&'\200B\FEFF'$arg$, 'invisible-only title'),
    ('title', $arg$pg_catalog.repeat('😀',101)$arg$, '101 code-point title'),
    ('title', $arg$pg_catalog.repeat(U&'e\0301',51)$arg$, 'combining marks count as code points'),
    ('description', 'null', 'null description'),
    ('description', $arg$pg_catalog.repeat('😀',201)$arg$, '201 code-point description'),
    ('main_language', $arg$pg_catalog.repeat('😀',31)$arg$, '31 code-point language'),
    ('tags', 'null::text[]', 'null tags'),
    ('tags', $arg$array[['a'],['b']]$arg$, 'multidimensional tags'),
    ('tags', $arg$array['a',null]$arg$, 'null tag'),
    ('tags', $arg$array['']$arg$, 'empty tag'),
    ('tags', $arg$array[U&'\200B']$arg$, 'invisible-only tag'),
    ('tags', $arg$array[pg_catalog.repeat('😀',31)]$arg$, '31 code-point tag'),
    ('tags', $arg$pg_catalog.array_fill('a'::text,array[11])$arg$, 'eleven tags before deduplication'),
    ('opening_text', 'null', 'null opening text'),
    ('opening_text', $arg$pg_catalog.repeat('😀',201)$arg$, '201 code-point opening text'),
    ('visibility', 'null', 'null visibility'),
    ('visibility', $arg$'unknown'$arg$, 'unknown visibility')
) as cases(field, expression, label);
insert into links_github_test.invalid_cases
select rpc.name, rpc.field, cases.expression, cases.label
from (values ('sync_github_identity','provider_user_id'), ('save_github_link','repository_id'),
    ('save_github_link','repository_owner_id')) as rpc(name, field)
cross join (values
    ('null', 'null decimal ID'), ($arg$''$arg$, 'empty decimal ID'),
    ($arg$'0'$arg$, 'zero decimal ID'), ($arg$'-1'$arg$, 'negative decimal ID'),
    ($arg$'01'$arg$, 'noncanonical decimal ID'), ($arg$'1.0'$arg$, 'fractional decimal ID'),
    ($arg$'9223372036854775808'$arg$, 'decimal ID over signed bigint'),
    ($arg$'10000000000000000000'$arg$, 'twenty-digit decimal ID')
) as cases(expression, label);
insert into links_github_test.invalid_cases values
    ('get_github_identity','account_id','null','null identity account'),
    ('sync_github_identity','account_id','null','null sync account'),
    ('save_github_link','account_id','null','null save account'),
    ('record_github_fetch','account_id','null','null fetch account'),
    ('update_own_link','link_id','null','null update link'),
    ('delete_own_link','link_id','null','null delete link'),
    ('reorder_own_links','link_ids','null::uuid[]','null reorder array'),
    ('reorder_own_links','link_ids','array[[links_github_test.id(201)],[links_github_test.id(202)]]','multidimensional reorder'),
    ('reorder_own_links','link_ids','array[links_github_test.id(201),null]','null reorder element'),
    ('reorder_own_links','link_ids','array[links_github_test.id(201),links_github_test.id(201)]','duplicate reorder ID'),
    ('reorder_own_links','link_ids','array[links_github_test.id(201),links_github_test.id(203)]','foreign reorder ID'),
    ('reorder_own_links','link_ids','array[links_github_test.id(201),links_github_test.id(999)]','missing reorder ID'),
    ('reorder_own_links','link_ids','array[links_github_test.id(201)]','incomplete reorder permutation'),
    ('reorder_own_links','link_ids',$arg$'{}'::uuid[]$arg$,'empty reorder with links'),
    ('reorder_own_links','link_ids','pg_catalog.array_fill(links_github_test.id(201),array[11])','eleven reorder IDs'),
    ('sync_github_identity','handle','null','null handle'),
    ('sync_github_identity','handle',$arg$''$arg$,'empty handle'),
    ('sync_github_identity','handle',$arg$'bad_handle'$arg$,'invalid handle characters'),
    ('sync_github_identity','handle',$arg$pg_catalog.repeat('a',40)$arg$,'forty-character handle'),
    ('sync_github_identity','verified_addresses','null::text[]','null addresses'),
    ('sync_github_identity','verified_addresses',$arg$array[['a'],['b']]$arg$,'multidimensional addresses'),
    ('sync_github_identity','verified_addresses',$arg$array['a',null]$arg$,'null address'),
    ('sync_github_identity','verified_addresses',$arg$pg_catalog.array_fill('a'::text,array[33])$arg$,'33 addresses before deduplication'),
    ('sync_github_identity','verified_addresses',$arg$array[pg_catalog.repeat('a',2049)]$arg$,'2049-character address'),
    ('save_github_link','url','null','null URL'),
    ('save_github_link','url',$arg$''$arg$,'empty URL'),
    ('save_github_link','url',$arg$'http://github.com/owner/repo'$arg$,'HTTP URL'),
    ('save_github_link','url',$arg$'https://example.invalid/owner/repo'$arg$,'foreign URL host'),
    ('save_github_link','url',$arg$'https://user:pass@github.com/owner/repo'$arg$,'URL credentials'),
    ('save_github_link','url',$arg$'https://github.com/owner/repo#fragment'$arg$,'noncanonical fragment'),
    ('save_github_link','url',$arg$'https://github.com/owner/repo?query'$arg$,'noncanonical query'),
    ('save_github_link','url',$arg$'https://github.com/owner/repo/'$arg$,'noncanonical trailing slash'),
    ('save_github_link','url',$arg$'https://github.com/owner/.'$arg$,'dot repository'),
    ('save_github_link','url',$arg$'https://github.com/owner/..'$arg$,'dot-dot repository'),
    ('save_github_link','url',$arg$'https://github.com/owner/' || pg_catalog.repeat('a',2049)$arg$,'oversized URL'),
    ('save_github_link','replace_existing','null','null refresh confirmation');

select links_github_test.expect_error(pg_catalog.format('select links_github_test.as_role(%L,%L,links_github_test.id(1))',
    case when r.schema_name = 'public' then 'authenticated' else 'service_role' end,
    r.schema_name || '.' || r.name || '(' || (
        select pg_catalog.string_agg(case when r.argument_names[a.position] = c.field then c.expression else a.expression end, ',' order by a.position)
        from pg_catalog.unnest(r.arguments) with ordinality as a(expression, position)) || ')'),
    'invalid_input', c.field, r.name || ': ' || c.label)
from links_github_test.invalid_cases as c join links_github_test.rpcs as r on r.name = c.rpc_name;

-- Three simultaneous failures verify only invalid fields, in signature order.
select links_github_test.expect_error($stmt$select links_github_test.as_caller(links_github_test.id(1),
    'public.update_own_link(null,null,null,pg_catalog.repeat(''a'',31),null,null,null)')$stmt$,
    'invalid_input','link_id,title,description,main_language,tags,opening_text,visibility','update detail signature order');
select links_github_test.expect_error($stmt$select links_github_test.as_service(
    'service.sync_github_identity(null,null,null,null)')$stmt$,
    'invalid_input','account_id,provider_user_id,handle,verified_addresses','sync detail signature order');
select links_github_test.expect_error($stmt$select links_github_test.as_service(
    'service.save_github_link(null,null,null,null,null,null,pg_catalog.repeat(''a'',31),null,null,null,null)')$stmt$,
    'invalid_input','account_id,repository_id,repository_owner_id,url,title,description,main_language,tags,opening_text,visibility,replace_existing',
    'save detail signature order');

-- Read shapes, private visibility, no profile, and display-order ties.
select extensions.is(links_github_test.as_caller(links_github_test.id(1), 'public.list_own_links()'),
    pg_catalog.jsonb_build_array(links_github_test.expected_link(201,4), links_github_test.expected_link(202,4)), 'own list includes private links and UUID tie order');
select extensions.is(links_github_test.as_caller(links_github_test.id(3), 'public.list_own_links()'), '[]'::jsonb, 'no profile returns empty links');
select extensions.is(links_github_test.as_caller(links_github_test.id(1), 'public.get_github_connection()'),
    '{"connected":false,"handle":null}'::jsonb, 'live unsynced identity needs a cache to connect');
select extensions.is(links_github_test.as_caller(links_github_test.id(4), 'public.get_github_connection()'),
    '{"connected":false,"handle":null}'::jsonb, 'absent Auth identity is disconnected');
select extensions.is(links_github_test.as_service('service.get_github_identity(links_github_test.id(4))'),
    '{"connected":false,"provider_user_id":null,"handle":null,"verified_addresses":[],"repository_links":[]}'::jsonb, 'disconnected identity exact shape');
select extensions.is(links_github_test.as_service('service.get_github_identity(links_github_test.id(1))'),
    pg_catalog.jsonb_build_object('connected',true,'provider_user_id','101','handle',null,'verified_addresses','[]'::jsonb,
        'repository_links', pg_catalog.jsonb_build_array(
            pg_catalog.jsonb_build_object('link_id',links_github_test.id(201),'source_item_id','201','url','https://github.com/owner-1/repo-201'),
            pg_catalog.jsonb_build_object('link_id',links_github_test.id(202),'source_item_id','202','url','https://github.com/owner-1/repo-202'))),
    'identity exact shape exposes references without credentials');

select extensions.is(links_github_test.as_service($call$service.sync_github_identity(links_github_test.id(1), '101', ' owner-1 ', array['https://example.invalid/'])$call$),
    '{"connected":true,"handle":"owner-1"}'::jsonb, 'sync inserts matching cache and trims handle');
select extensions.is(links_github_test.as_caller(links_github_test.id(1), 'public.get_github_connection()'),
    '{"connected":true,"handle":"owner-1"}'::jsonb, 'connection exposes matching cache');
select extensions.is(links_github_test.as_service('service.get_github_identity(links_github_test.id(1))')->'verified_addresses',
    '["https://example.invalid/"]'::jsonb, 'identity exposes matching verified addresses');
select extensions.is(links_github_test.as_service($call$service.sync_github_identity(links_github_test.id(1), '101', 'new-owner', '{}'::text[])$call$),
    '{"connected":true,"handle":"new-owner"}'::jsonb, 'sync updates matching cache');
select links_github_test.as_caller_void(links_github_test.id(1),'public.set_discovery(true)');
update private.linked_identities set provider_user_id = '999' where user_id = links_github_test.id(1);
select extensions.is(links_github_test.as_caller(links_github_test.id(1), 'public.get_github_connection()'),
    '{"connected":false,"handle":null}'::jsonb, 'mismatched cache does not prove connection');
select extensions.is(links_github_test.as_service('service.get_github_identity(links_github_test.id(1))')->'verified_addresses',
    '[]'::jsonb, 'mismatched cache addresses ignored');
select links_github_test.expect_error($stmt$select links_github_test.as_service('service.sync_github_identity(links_github_test.id(1),''999'',''owner'',''{}''::text[])')$stmt$,
    'not_found','','provider mismatch cannot sync');
select links_github_test.expect_error($stmt$select links_github_test.as_service('service.sync_github_identity(links_github_test.id(4),''104'',''owner'',''{}''::text[])')$stmt$,
    'not_found','','absent live identity cannot sync');
insert into links_github_test.results values ('resync',links_github_test.as_service($call$service.sync_github_identity(links_github_test.id(1),'101','owner-1','{}'::text[])$call$));
select extensions.is(links_github_test.as_service('service.get_github_identity(links_github_test.id(1))')->'repository_links',
    '[]'::jsonb,'identity switch removes repository links read through the old identity');
select extensions.is((select pg_catalog.count(*) from links_github_test.saved_references),0::bigint,
    'identity switch cascades the old repository saved references');
select extensions.is((select discovery_on from private.profiles where user_id=links_github_test.id(1)),false,
    'identity switch turns discovery off when it removes every link');

-- Fresh repository evidence for the current identity keeps the following
-- metadata, reorder, refresh and removal assertions independent of cleanup.
insert into private.external_links (link_id, owner_id, source, source_item_id, url, title, description,
    main_language, tags, opening_text, visibility, verification_state, display_order)
select links_github_test.id(n), links_github_test.id(1), 'github', n::text,
    'https://github.com/owner-1/repo-' || n, 'Title ' || n, 'Description ' || n,
    'Swift', array['a','b'], 'Opening ' || n, 'private', 'verified', 4
from pg_catalog.generate_series(201,202) as n;
insert into links_github_test.saved_references values (1,links_github_test.id(201)),(2,links_github_test.id(202));

-- Four resource errors: foreign and absent IDs are indistinguishable.
select links_github_test.expect_error(pg_catalog.format('select links_github_test.as_caller(links_github_test.id(1),%L)',
    'public.update_own_link(links_github_test.id(' || n || '),''Title'','''',null,''{}''::text[],'''',''private'')'),
    'not_found','','update foreign/missing link') from (values (203),(999)) as v(n);
select links_github_test.expect_error(pg_catalog.format('select links_github_test.as_caller(links_github_test.id(1),%L)',
    'public.delete_own_link(links_github_test.id(' || n || '))'), 'not_found','','delete foreign/missing link') from (values (203),(999)) as v(n);

insert into links_github_test.results values ('update',links_github_test.as_caller(links_github_test.id(1),
    $call$public.update_own_link(links_github_test.id(201),'  Edited  ',' Description ','  ',array[' b ','a','b'],' Opening ','compatible_only')$call$));
select extensions.is((select value from links_github_test.results where label='update'),
    links_github_test.expected_link(201,4,'compatible_only') || '{"title":"Edited","description":"Description","main_language":null,"tags":["b","a"],"opening_text":"Opening"}'::jsonb,
    'update changes only metadata and trims/deduplicates in first-occurrence order');
select extensions.is(links_github_test.as_caller(links_github_test.id(3),'public.reorder_own_links(''{}''::uuid[])'),
    '[]'::jsonb,'empty reorder on empty account');
select extensions.is(links_github_test.as_caller(links_github_test.id(1),
    'public.reorder_own_links(array[links_github_test.id(202),links_github_test.id(201)])'),
    pg_catalog.jsonb_build_array(links_github_test.expected_link(202,0),
        links_github_test.expected_link(201,1,'compatible_only') || '{"title":"Edited","description":"Description","main_language":null,"tags":["b","a"],"opening_text":"Opening"}'::jsonb),
    'reorder returns exact Links with consecutive zero-based order');

-- Inclusive code-point boundaries, including supplementary characters.
insert into links_github_test.results values ('bounds',links_github_test.as_caller(links_github_test.id(1),
    $call$public.update_own_link(links_github_test.id(201),pg_catalog.repeat('😀',100),pg_catalog.repeat('😀',200),pg_catalog.repeat('😀',30),
        array[pg_catalog.repeat('😀',30),'a','b','c','d','e','f','g','h','i'],pg_catalog.repeat('😀',200),'everyone_eligible')$call$));
select extensions.is((select value->>'title' from links_github_test.results where label='bounds'),pg_catalog.repeat('😀',100),'100 code-point title accepted intact');
select extensions.is((select value->>'description' from links_github_test.results where label='bounds'),pg_catalog.repeat('😀',200),'200 code-point description accepted intact');
select extensions.is((select value->>'main_language' from links_github_test.results where label='bounds'),pg_catalog.repeat('😀',30),'30 code-point language accepted intact');
select extensions.is((select value->>'opening_text' from links_github_test.results where label='bounds'),pg_catalog.repeat('😀',200),'200 code-point opening accepted intact');
select extensions.is((select pg_catalog.jsonb_array_length(value->'tags') from links_github_test.results where label='bounds'),10,'ten tags accepted');
select extensions.is((select value->'tags'->>0 from links_github_test.results where label='bounds'),pg_catalog.repeat('😀',30),'30 code-point tag accepted intact');

select links_github_test.expect_error($stmt$select links_github_test.as_service('service.save_github_link(links_github_test.id(1),''201'',''101'',''https://github.com/owner-1/renamed'',''Replacement'','''',null,''{}''::text[],'''',''private'',false)')$stmt$,
    'prerequisite_missing','refresh_confirmation','existing save requires refresh acceptance');
select extensions.is((select title from private.external_links where link_id=links_github_test.id(201)),pg_catalog.repeat('😀',100),'unaccepted replacement preserves approved metadata');
select extensions.is(links_github_test.as_service(
    $call$service.save_github_link(links_github_test.id(1),'201','101','https://github.com/owner-1/renamed',' Replacement ',' Description ',null,array[' a ','a','b'],' Opening ','private',true)$call$),
    links_github_test.expected_link(201,1) || '{"url":"https://github.com/owner-1/renamed","title":"Replacement","description":"Description","main_language":null,"opening_text":"Opening"}'::jsonb,
    'accepted replacement preserves ID/order and explicitly replaces visibility');
select extensions.is((select pg_catalog.count(*) from links_github_test.saved_references),2::bigint,'replacement preserves saved references');
select links_github_test.expect_error($stmt$select links_github_test.as_service('service.save_github_link(links_github_test.id(1),''204'',''102'',''https://github.com/owner-1/repo'',''Title'','''',null,''{}''::text[],'''',''private'',false)')$stmt$,
    'not_found','','repository owner must match live Auth provider ID');
select links_github_test.expect_error($stmt$select links_github_test.as_service('service.save_github_link(links_github_test.id(4),''204'',''104'',''https://github.com/owner-4/repo'',''Title'','''',null,''{}''::text[],'''',''private'',false)')$stmt$,
    'not_found','','save requires live identity');
select links_github_test.expect_error($stmt$select links_github_test.as_service('service.save_github_link(links_github_test.id(3),''204'',''103'',''https://github.com/owner-3/repo'',''Title'','''',null,''{}''::text[],'''',''private'',false)')$stmt$,
    'account_not_ready','','save requires ready account');

update auth.identities set provider_id='777',identity_data='{"sub":"777"}' where user_id=links_github_test.id(1) and provider='github';
select links_github_test.expect_error($stmt$select links_github_test.as_service('service.save_github_link(links_github_test.id(1),''204'',''101'',''https://github.com/owner-1/repo'',''Title'','''',null,''{}''::text[],'''',''private'',false)')$stmt$,
    'not_found','','changed live identity refuses stale owner save');
select extensions.is(links_github_test.as_caller(links_github_test.id(1),'public.get_github_connection()'),'{"connected":false,"handle":null}'::jsonb,'changed Auth identity invalidates stale cache');
update auth.identities set provider_id='101',identity_data='{"sub":"101"}' where user_id=links_github_test.id(1) and provider='github';

insert into links_github_test.results values ('new',links_github_test.as_service(
    $call$service.save_github_link(links_github_test.id(1),'204','101','https://github.com/owner-1/repo-204','New','',null,'{}'::text[],'','everyone_eligible',false)$call$));
select extensions.is((select value-'link_id' from links_github_test.results where label='new'),
    (links_github_test.expected_link(204,2,'everyone_eligible')-'link_id') || '{"title":"New","description":"","main_language":null,"tags":[],"opening_text":""}'::jsonb,
    'new save returns exact Link fields and appends order');
select extensions.ok((select (value->>'link_id') ~ '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' from links_github_test.results where label='new'),'new link has lowercase UUID');
select extensions.is(links_github_test.as_service($call$service.save_github_link(links_github_test.id(1),'205','101','https://github.com/owner-1/repo-205','New','',null,'{}'::text[],'','private',true)$call$)->>'display_order',
    '3','true also permits initial creation');

-- Inclusive sync/decimal bounds; no numeric rounding.
update auth.identities set provider_id='9223372036854775807' where user_id=links_github_test.id(3) and provider='github';
select extensions.is(links_github_test.as_service($call$service.sync_github_identity(links_github_test.id(3),'9223372036854775807',pg_catalog.repeat('a',39),pg_catalog.array_fill(pg_catalog.repeat('a',2048),array[32]))$call$),
    pg_catalog.jsonb_build_object('connected',true,'handle',pg_catalog.repeat('a',39)),'sync accepts inclusive bounds without profile readiness');
select extensions.is(links_github_test.as_service('service.get_github_identity(links_github_test.id(3))')->>'provider_user_id','9223372036854775807','provider ID stays lossless decimal text');
select extensions.is(links_github_test.as_service($call$service.save_github_link(links_github_test.id(1),'9223372036854775807','101','https://github.com/owner-1/max','Max','',null,'{}'::text[],'','private',false)$call$)->>'source_item_id',
    '9223372036854775807','maximum repository ID stays lossless decimal text');

-- Account 2 starts with one link; nine inserts fill it.
insert into links_github_test.results
select 'cap-' || n,links_github_test.as_service(pg_catalog.format(
    'service.save_github_link(links_github_test.id(2),%L,''102'',%L,''Title'','''',null,''{}''::text[],'''',''private'',false)',
    n::text,'https://github.com/owner-2/repo-' || n)) from pg_catalog.generate_series(301,309) as n;
select extensions.is((select pg_catalog.count(*) from private.external_links where owner_id=links_github_test.id(2)),10::bigint,'ten links accepted');
select links_github_test.expect_error($stmt$select links_github_test.as_service('service.save_github_link(links_github_test.id(2),''310'',''102'',''https://github.com/owner-2/repo-310'',''Title'','''',null,''{}''::text[],'''',''private'',false)')$stmt$,
    'rate_limited','','eleventh link rejected');
select extensions.is((select pg_catalog.count(*) from private.external_links where owner_id=links_github_test.id(2)),10::bigint,'eleventh rejection preserves all ten');
select extensions.is(pg_catalog.jsonb_array_length(links_github_test.as_caller(links_github_test.id(2),'public.list_own_links()')),10,'own list at cap');
select extensions.is(pg_catalog.jsonb_array_length(links_github_test.as_service('service.get_github_identity(links_github_test.id(2))')->'repository_links'),10,'identity references at cap');
select extensions.is(links_github_test.as_service($call$service.save_github_link(links_github_test.id(2),'203','102','https://github.com/owner-2/updated','Updated','',null,'{}'::text[],'','compatible_only',true)$call$)->>'link_id',
    links_github_test.id(203)::text,'accepted replacement works at cap');
insert into links_github_test.results values ('reorder-at-cap',links_github_test.as_caller(links_github_test.id(2),
    pg_catalog.format('public.reorder_own_links(%L::uuid[])',
        (select pg_catalog.array_agg(link_id order by display_order desc,link_id desc)
            from private.external_links where owner_id=links_github_test.id(2))::text)));
select extensions.is((select pg_catalog.array_agg((l.value->>'display_order')::integer order by l.position)
    from links_github_test.results as r cross join lateral pg_catalog.jsonb_array_elements(r.value) with ordinality as l(value,position)
    where r.label='reorder-at-cap'),array[0,1,2,3,4,5,6,7,8,9],'ten-ID reorder writes every zero-based order');

-- Sixty reservations persist whether or not subsequent upstream work succeeds.
insert into links_github_test.results
select 'fetch-' || n,links_github_test.as_service('service.record_github_fetch(links_github_test.id(1))')
from pg_catalog.generate_series(1,60) as n;
select extensions.is((select pg_catalog.count(*) from links_github_test.results where label like 'fetch-%' and value='{"allowed":true}'::jsonb),
    60::bigint,'sixty fetch calls return exact success shape');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events where user_id=links_github_test.id(1) and bucket='github_fetch'),60::bigint,'sixty reservations recorded without upstream success/refund');
select links_github_test.expect_error('select links_github_test.as_service(''service.record_github_fetch(links_github_test.id(1))'')',
    'rate_limited','','sixty-first fetch rejected');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events where user_id=links_github_test.id(1) and bucket='github_fetch'),60::bigint,'rejected reservation preserves events');
update private.account_limit_events set occurred_at=pg_catalog.now()-interval '3600 seconds'
where ctid=(select ctid from private.account_limit_events where user_id=links_github_test.id(1) and bucket='github_fetch' limit 1);
select extensions.is(links_github_test.as_service('service.record_github_fetch(links_github_test.id(1))'),'{"allowed":true}'::jsonb,'rolling-hour event expires exactly at 3600 seconds');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events where user_id=links_github_test.id(1) and bucket='github_fetch'),60::bigint,'expired reservation replaced by one event');
select extensions.is(links_github_test.as_service('service.record_github_fetch(links_github_test.id(2))'),
    '{"allowed":true}'::jsonb,'fetch budget is independent per account');
insert into private.account_limit_events (user_id, bucket, occurred_at)
select links_github_test.id(4),'github_fetch',pg_catalog.now()+interval '1 minute'
from pg_catalog.generate_series(1,60);
select links_github_test.expect_error('select links_github_test.as_service(''service.record_github_fetch(links_github_test.id(4))'')',
    'rate_limited','','later transaction timestamps count toward the fetch budget');

select extensions.is(links_github_test.as_caller(links_github_test.id(1),'public.delete_own_link(links_github_test.id(202))'),'{"deleted":true}'::jsonb,'delete success shape');
select extensions.is((select pg_catalog.count(*) from links_github_test.saved_references where reference_id=2),0::bigint,'delete cascades saved references');
delete from private.external_links where owner_id=links_github_test.id(1) and link_id<>links_github_test.id(201);
select extensions.lives_ok('select links_github_test.as_caller_void(links_github_test.id(1),''public.set_discovery(true)'')',
    'one real link permits discovery');
insert into links_github_test.results values ('before-removal', links_github_test.removal_snapshot());
select links_github_test.expect_error('select links_github_test.as_caller(links_github_test.id(1),''public.delete_own_link(links_github_test.id(201))'')',
    'prerequisite_missing','link','last-link deletion refused during discovery');
select extensions.is(links_github_test.removal_snapshot(),
    (select value from links_github_test.results where label='before-removal'), 'refused deletion preserves every link/cache/Auth identity/reference');
select links_github_test.expect_error('select links_github_test.as_caller(links_github_test.id(1),''public.disconnect_github()'')',
    'prerequisite_missing','link','disconnect refused when discovery would lose every link');
select extensions.is(links_github_test.removal_snapshot(),
    (select value from links_github_test.results where label='before-removal'), 'refused disconnect preserves every link/cache/Auth identity/reference');
select extensions.is((select discovery_on from private.profiles where user_id=links_github_test.id(1)),true,
    'rejected removals preserve discovery');
select extensions.lives_ok('select links_github_test.as_caller_void(links_github_test.id(1),''public.set_discovery(false)'')',
    'discovery can be turned off before removal');
select extensions.is(links_github_test.as_caller(links_github_test.id(1),'public.delete_own_link(links_github_test.id(201))'),
    '{"deleted":true}'::jsonb,'last link deletes with discovery off');
select extensions.is((select pg_catalog.count(*) from links_github_test.saved_references),0::bigint,'last-link deletion cascades its reference');
select links_github_test.expect_error('select links_github_test.as_caller_void(links_github_test.id(1),''public.set_discovery(true)'')',
    'prerequisite_missing','link','identity/cache alone never satisfies the link prerequisite');

-- Disconnect removes repository references/cache and leaves all managed Auth
-- rows intact for the client's subsequent Auth unlink request.
insert into links_github_test.results values ('disconnect-link',links_github_test.as_service(
    $call$service.save_github_link(links_github_test.id(1),'601','101','https://github.com/owner-1/repo-601','Disconnect','',null,'{}'::text[],'','private',false)$call$));
insert into links_github_test.saved_references values (3,
    (select (value->>'link_id')::uuid from links_github_test.results where label='disconnect-link'));
insert into links_github_test.results values ('auth-before-disconnect', links_github_test.auth_snapshot());
select extensions.is(links_github_test.as_caller(links_github_test.id(1),'public.disconnect_github()'),
    '{"connected":false,"handle":null}'::jsonb,'disconnect exact success shape');
select extensions.is((select pg_catalog.count(*) from private.external_links where owner_id=links_github_test.id(1)),0::bigint,'disconnect removes own repository links');
select extensions.is((select pg_catalog.count(*) from private.linked_identities where user_id=links_github_test.id(1)),0::bigint,'disconnect removes identity cache');
select extensions.is((select pg_catalog.count(*) from auth.identities where user_id=links_github_test.id(1) and provider='github'),1::bigint,'disconnect leaves Auth GitHub identity');
select extensions.is(links_github_test.auth_snapshot(),
    (select value from links_github_test.results where label='auth-before-disconnect'), 'disconnect leaves auth.users and auth.identities entirely unchanged');
select extensions.is((select pg_catalog.count(*) from auth.identities where user_id=links_github_test.id(1) and provider='apple' and provider_id='apple-1'),1::bigint,'disconnect leaves the Apple identity');
select extensions.is((select pg_catalog.count(*) from auth.users where id=links_github_test.id(1)),1::bigint,'disconnect leaves the Auth account');
select extensions.is((select pg_catalog.count(*) from links_github_test.saved_references),0::bigint,'disconnect cascades repository saved references');
select extensions.is((select pg_catalog.count(*) from private.external_links where owner_id=links_github_test.id(2)),10::bigint,'disconnect preserves another account links');
select extensions.is((select pg_catalog.count(*) from private.linked_identities where user_id=links_github_test.id(3)),1::bigint,'disconnect preserves another account cache');
select extensions.is(links_github_test.as_caller(links_github_test.id(1),'public.disconnect_github()'),
    '{"connected":false,"handle":null}'::jsonb,'disconnect is idempotent');
select extensions.is(links_github_test.as_caller(links_github_test.id(1),'public.get_github_connection()'),
    '{"connected":false,"handle":null}'::jsonb,'disconnect remains disconnected while Auth unlink is pending');
select extensions.is(links_github_test.as_service('service.get_github_identity(links_github_test.id(1))'),
    '{"connected":true,"provider_user_id":"101","handle":null,"verified_addresses":[],"repository_links":[]}'::jsonb,
    'service still sees the live identity after cache removal');
select extensions.is(links_github_test.as_service($call$service.sync_github_identity(links_github_test.id(1),'101','owner-1','{}'::text[])$call$),
    '{"connected":true,"handle":"owner-1"}'::jsonb,'sync reconnects without another authorization');
select extensions.is(links_github_test.as_caller(links_github_test.id(1),'public.get_github_connection()'),
    '{"connected":true,"handle":"owner-1"}'::jsonb,'resynced connection is visible');
select extensions.is(links_github_test.auth_snapshot(),
    (select value from links_github_test.results where label='auth-before-disconnect'), 'reconnect reuses the same untouched Auth identity');
insert into links_github_test.results values ('disconnect-again',links_github_test.as_caller(links_github_test.id(1),'public.disconnect_github()'));
-- Simulate the client's Auth unlink before a later authorization fixture.
delete from auth.identities where user_id=links_github_test.id(1) and provider='github';

-- An independently removed Auth identity makes even a populated cache inert.
delete from auth.identities where user_id=links_github_test.id(3) and provider='github';
select extensions.is(links_github_test.as_caller(links_github_test.id(3),'public.get_github_connection()'),
    '{"connected":false,"handle":null}'::jsonb,'stale cache never proves connection');
select extensions.is(links_github_test.as_service('service.get_github_identity(links_github_test.id(3))'),
    '{"connected":false,"provider_user_id":null,"handle":null,"verified_addresses":[],"repository_links":[]}'::jsonb,'disconnected identity ignores populated cache');
select links_github_test.expect_error($stmt$select links_github_test.as_service(
    'service.sync_github_identity(links_github_test.id(3),''9223372036854775807'',''owner'',''{}''::text[])')$stmt$,
    'not_found','','sync rejects independently removed identity');
select extensions.is(links_github_test.as_caller(links_github_test.id(3),'public.disconnect_github()'),
    '{"connected":false,"handle":null}'::jsonb,'disconnect clears stale cache without profile');
select extensions.is((select pg_catalog.count(*) from private.linked_identities where user_id=links_github_test.id(3)),0::bigint,'stale cache removed');

-- A later-source link can keep discovery valid when GitHub is disconnected.
insert into private.external_links (link_id, owner_id, source, url, title, visibility)
values (links_github_test.id(701),links_github_test.id(1),'other','https://example.invalid/','Other','private');
insert into auth.identities (id, user_id, provider, provider_id, identity_data)
values (links_github_test.id(801),links_github_test.id(1),'github','101','{"sub":"101"}');
insert into private.linked_identities (user_id, provider, provider_user_id, handle)
values (links_github_test.id(1),'github','101','owner-1');
insert into links_github_test.results values ('other-source-save',links_github_test.as_service(
    $call$service.save_github_link(links_github_test.id(1),'602','101','https://github.com/owner-1/repo-602','Disconnect','',null,'{}'::text[],'','private',false)$call$));
select extensions.lives_ok('select links_github_test.as_caller_void(links_github_test.id(1),''public.set_discovery(true)'')','discovery with GitHub and later-source link');
select extensions.is(links_github_test.as_caller(links_github_test.id(1),'public.disconnect_github()'),
    '{"connected":false,"handle":null}'::jsonb,'disconnect succeeds during discovery with a remaining link');
select extensions.is((select pg_catalog.array_agg(source order by source) from private.external_links where owner_id=links_github_test.id(1)),
    array['other'],'disconnect preserves the later-source link');
select extensions.is((select discovery_on from private.profiles where user_id=links_github_test.id(1)),true,'successful disconnect preserves discovery with remaining link');

-- The cache's live-account FK cascades independently of disconnect.
insert into private.linked_identities (user_id, provider, provider_user_id, handle)
values (links_github_test.id(2),'github','102','owner-2');
delete from auth.users where id=links_github_test.id(2);
select extensions.is((select pg_catalog.count(*) from private.linked_identities where user_id=links_github_test.id(2)),0::bigint,'Auth deletion cascades cached identity');

select * from extensions.finish();
rollback;
