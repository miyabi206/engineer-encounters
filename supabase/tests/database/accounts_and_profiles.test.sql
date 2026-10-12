begin;

create extension if not exists pgtap with schema extensions;

create schema accounts_profiles_test;
grant usage on schema accounts_profiles_test to anon, authenticated;

create table accounts_profiles_test.tables (name text primary key, key_column text not null);
insert into accounts_profiles_test.tables (name, key_column) values
    ('profiles', 'user_id'), ('interests', 'interest_id'), ('user_interests', 'user_id'), ('user_purposes', 'user_id'),
    ('matching_preferences', 'user_id'), ('field_visibility', 'owner_id'), ('notification_preferences', 'user_id'),
    ('external_links', 'owner_id'), ('blocks', 'blocker_id');

create table accounts_profiles_test.functions (
    signature text primary key,
    call text not null,
    argument_names text[],
    result_type text not null
);
insert into accounts_profiles_test.functions values
    ('public.accept_declarations(boolean,text,text)', 'public.accept_declarations(true, ''draft'', ''draft'')', array['age_18', 'terms_version', 'privacy_version'], 'void'),
    ('public.register_time_zone(text)', 'public.register_time_zone(''UTC'')', array['time_zone'], 'void'),
    ('public.get_own_profile()', 'public.get_own_profile()', null, 'jsonb'),
    ('public.update_own_profile(text,text,text)', 'public.update_own_profile(''名'', ''紹介'', '''')', array['display_name', 'introduction', 'contact_detail'], 'void'),
    ('public.set_own_interests(text[])', 'public.set_own_interests(array[]::text[])', array['interest_ids'], 'void'),
    ('public.set_own_purposes(text[])', 'public.set_own_purposes(array[]::text[])', array['purposes'], 'void'),
    ('public.set_minimum_shared_interests(integer)', 'public.set_minimum_shared_interests(1)', array['value'], 'void'),
    ('public.set_field_visibility(text,text)', 'public.set_field_visibility(''display_name'', ''private'')', array['field', 'level'], 'void'),
    ('public.set_discovery(boolean)', 'public.set_discovery(false)', array['enabled'], 'void'),
    ('public.list_interests()', 'public.list_interests()', null, 'jsonb');

create table accounts_profiles_test.helpers (call text not null);
insert into accounts_profiles_test.helpers values
    ('private.require_caller()'),
    ('private.account_is_ready(''11111111-1111-1111-1111-111111111111''::uuid)'),
    ('private.raise_error(''invalid_input'', array[''field''])');

create table accounts_profiles_test.invisible_inputs (code_point text primary key, value text not null);
insert into accounts_profiles_test.invisible_inputs values
    ('U+200B', U&'\200B'), ('U+200C', U&'\200C'), ('U+200D', U&'\200D'),
    ('U+2060', U&'\2060'), ('U+FEFF', U&'\FEFF'), ('U+3164', U&'\3164'),
    ('U+115F', U&'\115F'), ('U+1160', U&'\1160'), ('U+FFA0', U&'\FFA0');

grant select on all tables in schema accounts_profiles_test to anon, authenticated;

-- Check the detail as well as the stable message, without exposing submitted values.
create function accounts_profiles_test.expect_error(statement text, code text, fields text, description text)
returns text
language plpgsql
set search_path = pg_catalog, extensions
as $$
declare
    actual_state text;
    actual_message text;
    actual_detail text;
begin
    begin
        execute statement;
    exception when others then
        get stacked diagnostics actual_state = returned_sqlstate,
            actual_message = message_text, actual_detail = pg_exception_detail;
        return extensions.is(
            pg_catalog.jsonb_build_array(actual_state, actual_message, coalesce(actual_detail, '')),
            pg_catalog.jsonb_build_array('P0001'::text, code, fields), description
        );
    end;
    return extensions.fail(description || ': expected exception');
end;
$$;

select extensions.plan(546);

select extensions.ok(c.relrowsecurity, t.name || ' has RLS enabled')
from accounts_profiles_test.tables as t
join pg_catalog.pg_class as c on c.oid = ('private.' || t.name)::regclass;

select extensions.is(
    (select pg_catalog.count(*) from pg_catalog.pg_policy as p where p.polrelid = ('private.' || t.name)::regclass),
    0::bigint, t.name || ' has no policies'
)
from accounts_profiles_test.tables as t;

select extensions.ok(
    not pg_catalog.has_schema_privilege(r.name, 'private', 'usage, create'),
    r.name || ' cannot use or create in private'
)
from (values ('anon'), ('authenticated')) as r(name);

select extensions.ok(
    not pg_catalog.has_table_privilege(r.name, 'private.' || t.name, 'select, insert, update, delete, truncate, references, trigger, maintain'),
    r.name || ' has no privileges on ' || t.name
)
from accounts_profiles_test.tables as t
cross join (values ('anon'), ('authenticated')) as r(name);

select extensions.ok(not exists (
    select 1 from pg_catalog.aclexplode(coalesce(c.relacl, pg_catalog.acldefault('r', c.relowner))) as a
    where a.grantee = 0
), t.name || ' has no public grants')
from accounts_profiles_test.tables as t
join pg_catalog.pg_class as c on c.oid = ('private.' || t.name)::regclass;

select extensions.ok(p.prosecdef, f.signature || ' is security definer')
from accounts_profiles_test.functions as f
join pg_catalog.pg_proc as p on p.oid = f.signature::regprocedure;

select extensions.ok('search_path=""' = any(p.proconfig), f.signature || ' has an empty search path')
from accounts_profiles_test.functions as f
join pg_catalog.pg_proc as p on p.oid = f.signature::regprocedure;

select extensions.is(p.proargnames, f.argument_names, f.signature || ' has the wire argument names')
from accounts_profiles_test.functions as f
join pg_catalog.pg_proc as p on p.oid = f.signature::regprocedure;

select extensions.is(pg_catalog.format_type(p.prorettype, null), f.result_type, f.signature || ' has the expected return type')
from accounts_profiles_test.functions as f
join pg_catalog.pg_proc as p on p.oid = f.signature::regprocedure;

select extensions.ok(pg_catalog.has_function_privilege('authenticated', f.signature, 'execute'), f.signature || ' is executable by authenticated')
from accounts_profiles_test.functions as f;

select extensions.ok(not pg_catalog.has_function_privilege('anon', f.signature, 'execute'), f.signature || ' is not executable by anon')
from accounts_profiles_test.functions as f;

select extensions.ok(not exists (
    select 1 from pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) as a
    where a.grantee = 0 and a.privilege_type = 'EXECUTE'
), f.signature || ' is not executable by public')
from accounts_profiles_test.functions as f
join pg_catalog.pg_proc as p on p.oid = f.signature::regprocedure;

select extensions.is((select pg_catalog.count(*) from pg_catalog.pg_proc as p
    where p.pronamespace = 'private'::regnamespace
      and p.proname in ('require_caller', 'account_is_ready', 'raise_error')),
    3::bigint, 'the three shared private helpers exist');

select extensions.ok(not exists (
    select 1 from pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) as a
    where a.grantee = 0 and a.privilege_type = 'EXECUTE'
), p.proname || ' has no public execute grant')
from pg_catalog.pg_proc as p where p.pronamespace = 'private'::regnamespace
    and p.proname in ('require_caller', 'account_is_ready', 'raise_error');

select extensions.ok(not pg_catalog.has_function_privilege(r.name, p.oid, 'execute'),
    r.name || ' has no execute grant on ' || p.proname)
from pg_catalog.pg_proc as p
cross join (values ('anon'), ('authenticated')) as r(name)
where p.pronamespace = 'private'::regnamespace
    and p.proname in ('require_caller', 'account_is_ready', 'raise_error');

insert into auth.users (id) values
    ('11111111-1111-1111-1111-111111111111'),
    ('22222222-2222-2222-2222-222222222222'),
    ('33333333-3333-3333-3333-333333333333');

-- Remove local seed interests inside this transaction so catalog tests are self-contained.
delete from private.user_interests;
delete from private.interests;

set local "request.jwt.claim.sub" = '';
set local "request.jwt.claims" = '{}';
set local role anon;

select extensions.throws_ok('select ' || f.call, '42501',
    'permission denied for function ' || pg_catalog.split_part(pg_catalog.split_part(f.signature, '.', 2), '(', 1),
    f.signature || ' rejects anon execution')
from accounts_profiles_test.functions as f;

select extensions.throws_ok(case when s.operation = 'update' then
    pg_catalog.format(s.command, t.name, t.key_column, t.key_column) else pg_catalog.format(s.command, t.name) end,
    '42501', 'permission denied for schema private',
    'anon cannot ' || s.operation || ' ' || t.name)
from accounts_profiles_test.tables as t
cross join (values
    ('read', 'select * from private.%I'),
    ('insert', 'insert into private.%I default values'),
    ('update', 'update private.%I set %I = %I'),
    ('delete', 'delete from private.%I'),
    ('truncate', 'truncate private.%I')
) as s(operation, command);

select extensions.throws_ok('select ' || h.call, '42501', 'permission denied for schema private', 'anon cannot execute ' || h.call)
from accounts_profiles_test.helpers as h;

reset role;
set local role authenticated;

select extensions.throws_ok(case when s.operation = 'update' then
    pg_catalog.format(s.command, t.name, t.key_column, t.key_column) else pg_catalog.format(s.command, t.name) end,
    '42501', 'permission denied for schema private',
    'authenticated cannot ' || s.operation || ' ' || t.name)
from accounts_profiles_test.tables as t
cross join (values
    ('read', 'select * from private.%I'),
    ('insert', 'insert into private.%I default values'),
    ('update', 'update private.%I set %I = %I'),
    ('delete', 'delete from private.%I'),
    ('truncate', 'truncate private.%I')
) as s(operation, command);

select extensions.throws_ok('select ' || h.call, '42501', 'permission denied for schema private', 'authenticated cannot execute ' || h.call)
from accounts_profiles_test.helpers as h;

select accounts_profiles_test.expect_error('select ' || f.call, 'not_authenticated', '', f.signature || ' requires a JWT caller')
from accounts_profiles_test.functions as f;

set local "request.jwt.claims" = '{"sub":"ffffffff-ffff-ffff-ffff-ffffffffffff","role":"authenticated"}';
select accounts_profiles_test.expect_error('select ' || f.call, 'not_authenticated', '', f.signature || ' rejects a missing live Auth account')
from accounts_profiles_test.functions as f;

set local "request.jwt.claims" = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

select extensions.is(public.get_own_profile(), '{
    "display_name":"", "introduction":"", "contact_detail":"", "interests":[], "purposes":[],
    "minimum_shared_interests":1,
    "field_visibility":{"display_name":"everyone_eligible","introduction":"everyone_eligible","interests":"everyone_eligible","purposes":"everyone_eligible","contact_detail":"private"},
    "discovery_on":false, "link_count":0,
    "prerequisites":{"display_name":false,"introduction":false,"interest":false,"link":false},
    "declarations_recorded":false, "time_zone":null, "moderation_state":null
}'::jsonb, 'get_own_profile returns the entire empty object before declarations');
select extensions.is(public.list_interests(), '[]'::jsonb, 'list_interests returns an empty array without declarations');
select extensions.lives_ok('select public.set_discovery(false)', 'discovery off succeeds before declarations');

select accounts_profiles_test.expect_error('select ' || f.call, 'declaration_required', '', f.signature || ' requires a profile row')
from accounts_profiles_test.functions as f
where f.signature in ('public.register_time_zone(text)', 'public.update_own_profile(text,text,text)',
    'public.set_own_interests(text[])', 'public.set_own_purposes(text[])',
    'public.set_minimum_shared_interests(integer)', 'public.set_field_visibility(text,text)');

select accounts_profiles_test.expect_error('select public.set_discovery(true)', 'account_not_ready', '',
    'discovery on requires readiness before listing profile prerequisites');
select accounts_profiles_test.expect_error('select public.set_discovery(null)', 'invalid_input', 'enabled', 'discovery rejects a null switch');
select accounts_profiles_test.expect_error('select public.accept_declarations(false, ''draft'', ''draft'')', 'declaration_required', '', 'age declaration must be true');
select accounts_profiles_test.expect_error('select public.accept_declarations(null, ''draft'', ''draft'')', 'declaration_required', '', 'age declaration cannot be null');

select accounts_profiles_test.expect_error(pg_catalog.format('select public.accept_declarations(true, %L, ''draft'')', v.value),
    'invalid_input', 'terms_version', 'reject invalid terms version: ' || v.name)
from (values ('empty', ''::text), ('spaces', '   '), ('null', null), ('33 characters', pg_catalog.repeat('規', 33))) as v(name, value);

select accounts_profiles_test.expect_error(pg_catalog.format('select public.accept_declarations(true, ''draft'', %L)', v.value),
    'invalid_input', 'privacy_version', 'reject invalid privacy version: ' || v.name)
from (values ('empty', ''::text), ('spaces', '   '), ('null', null), ('33 characters', pg_catalog.repeat('規', 33))) as v(name, value);

select accounts_profiles_test.expect_error('select public.accept_declarations(true, repeat(''規'', 33), repeat(''規'', 33))',
    'invalid_input', 'terms_version,privacy_version', 'invalid declaration fields are named together');

select extensions.lives_ok('select public.accept_declarations(true, ''draft'', ''draft'')', 'accept_declarations creates a profile');
select extensions.is(public.get_own_profile(), '{
    "display_name":"", "introduction":"", "contact_detail":"", "interests":[], "purposes":[],
    "minimum_shared_interests":1,
    "field_visibility":{"display_name":"everyone_eligible","introduction":"everyone_eligible","interests":"everyone_eligible","purposes":"everyone_eligible","contact_detail":"private"},
    "discovery_on":false, "link_count":0,
    "prerequisites":{"display_name":false,"introduction":false,"interest":false,"link":false},
    "declarations_recorded":true, "time_zone":null, "moderation_state":"active"
}'::jsonb, 'first declarations initialize the exact own-profile object and visibility levels');

reset role;
select extensions.is((select pg_catalog.count(*) from private.field_visibility
    where owner_id = '11111111-1111-1111-1111-111111111111'), 5::bigint, 'all five visibility rows are stored');
select extensions.ok(not private.account_is_ready('11111111-1111-1111-1111-111111111111'), 'declarations alone do not make the account ready');
select extensions.is((select pg_catalog.count(*) from private.profiles
    where user_id = '22222222-2222-2222-2222-222222222222'), 0::bigint, 'no Auth trigger creates another profile');
set local role authenticated;

select extensions.lives_ok(pg_catalog.format('select public.accept_declarations(true, %L, %L)',
    pg_catalog.repeat('規', v.size), pg_catalog.repeat('約', v.size)), 'declaration versions accept ' || v.size || ' multibyte characters')
from (values (1), (31), (32)) as v(size)
order by v.size;

reset role;
select extensions.is((select pg_catalog.jsonb_build_array(pg_catalog.char_length(terms_version), pg_catalog.char_length(privacy_version))
    from private.profiles where user_id = '11111111-1111-1111-1111-111111111111'), '[32,32]'::jsonb,
    'maximum declaration versions retain characters rather than byte lengths');
set local role authenticated;
select extensions.lives_ok('select public.accept_declarations(true, '' 規 '', '' 約 '')', 'version values accept surrounding whitespace');
reset role;
select extensions.is((select pg_catalog.jsonb_build_array(terms_version, privacy_version)
    from private.profiles where user_id = '11111111-1111-1111-1111-111111111111'), '["規","約"]'::jsonb, 'versions are stored after trimming');
set local role authenticated;

select accounts_profiles_test.expect_error(pg_catalog.format('select public.register_time_zone(%L)', v.value),
    'invalid_input', 'time_zone', 'reject invalid time zone: ' || v.name)
from (values ('empty', ''::text), ('null', null), ('unknown multibyte name', '無効な地域'), ('padded name', ' UTC ')) as v(name, value);
select extensions.lives_ok('select public.register_time_zone(''UTC'')', 'register_time_zone creates notification preferences');
select extensions.lives_ok('select public.register_time_zone(''Asia/Tokyo'')', 'latest time zone registration wins');
select extensions.is(public.get_own_profile()->>'time_zone', 'Asia/Tokyo', 'the latest registered zone is returned');

reset role;
select extensions.is((select pg_catalog.jsonb_build_array(report_hour, report_minute, notifications_enabled)
    from private.notification_preferences where user_id = '11111111-1111-1111-1111-111111111111'), '[21,0,true]'::jsonb,
    'initial notification preferences use the binding report time and enabled notifications');
select extensions.ok(private.account_is_ready('11111111-1111-1111-1111-111111111111'), 'a ready account can have discovery off and no profile prerequisites');
update private.notification_preferences set notifications_enabled = false where user_id = '11111111-1111-1111-1111-111111111111';
set local role authenticated;
select extensions.lives_ok('select public.register_time_zone(''UTC'')', 'zone updates preserve existing notification settings');
reset role;
select extensions.is((select pg_catalog.jsonb_build_array(report_hour, report_minute, notifications_enabled, time_zone)
    from private.notification_preferences where user_id = '11111111-1111-1111-1111-111111111111'), '[21,0,false,"UTC"]'::jsonb,
    're-registration only replaces the zone');
set local role authenticated;

select extensions.lives_ok(pg_catalog.format('select public.update_own_profile(%L, %L, %L)',
    case when v.field = 'display_name' then pg_catalog.repeat('名', v.size) else '' end,
    case when v.field = 'introduction' then pg_catalog.repeat('紹', v.size) else '' end,
    case when v.field = 'contact_detail' then pg_catalog.repeat('連', v.size) else '' end),
    v.field || ' accepts ' || v.size || ' multibyte characters')
from (values ('display_name', 1), ('display_name', 29), ('display_name', 30),
    ('introduction', 1), ('introduction', 199), ('introduction', 200),
    ('contact_detail', 1), ('contact_detail', 99), ('contact_detail', 100)) as v(field, size);

select accounts_profiles_test.expect_error(pg_catalog.format('select public.update_own_profile(%L, %L, %L)',
    case when v.field = 'display_name' then pg_catalog.repeat('名', 31) else '' end,
    case when v.field = 'introduction' then pg_catalog.repeat('紹', 201) else '' end,
    case when v.field = 'contact_detail' then pg_catalog.repeat('連', 101) else '' end),
    'invalid_input', v.field, v.field || ' rejects the first multibyte character over its limit')
from (values ('display_name'), ('introduction'), ('contact_detail')) as v(field);

select accounts_profiles_test.expect_error('select public.update_own_profile(repeat(''名'',31), repeat(''紹'',201), repeat(''連'',101))',
    'invalid_input', 'display_name,introduction,contact_detail', 'all overlength profile fields are named');
select extensions.lives_ok('select public.update_own_profile('' '' || repeat(''名'',30) || '' '', '' '' || repeat(''紹'',200) || '' '', '' '' || repeat(''連'',100) || '' '')',
    'profile values are trimmed before length validation');
select extensions.is(pg_catalog.jsonb_build_array(
    pg_catalog.char_length(public.get_own_profile()->>'display_name'),
    pg_catalog.char_length(public.get_own_profile()->>'introduction'),
    pg_catalog.char_length(public.get_own_profile()->>'contact_detail')), '[30,200,100]'::jsonb,
    'maximum profile values are stored with character lengths');
select extensions.lives_ok('select public.update_own_profile(null, null, null)', 'null profile values represent absence');
select extensions.is(pg_catalog.jsonb_build_array(public.get_own_profile()->>'display_name', public.get_own_profile()->>'introduction',
    public.get_own_profile()->>'contact_detail'), '["","",""]'::jsonb, 'absent profile values are empty strings');
select extensions.lives_ok('select public.update_own_profile(''   '', ''   '', ''   '')', 'empty trimmed values are allowed while discovery is off');

reset role;
insert into private.interests (interest_id, label_ja, label_en, display_order)
select '関心' || pg_catalog.lpad(n::text, 2, '0'), '日本語' || n::text, 'English ' || n::text, (n - 1) / 2
from pg_catalog.generate_series(1, 11) as s(n);
set local role authenticated;

select extensions.is(public.list_interests(), (
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'interest_id', '関心' || pg_catalog.lpad(n::text, 2, '0'), 'label_ja', '日本語' || n::text,
        'label_en', 'English ' || n::text, 'display_order', (n - 1) / 2
    ) order by (n - 1) / 2, '関心' || pg_catalog.lpad(n::text, 2, '0'))
    from pg_catalog.generate_series(1, 11) as s(n)
), 'list_interests returns precisely the four keys in display order with deterministic ties');

select extensions.lives_ok(pg_catalog.format('select public.set_own_interests(%L::text[])',
    array(select '関心' || pg_catalog.lpad(n::text, 2, '0') from pg_catalog.generate_series(1, v.size) as s(n))),
    'interest selection accepts ' || v.size || ' multibyte identifiers')
from (values (1), (9), (10)) as v(size)
order by v.size;
select extensions.is(pg_catalog.jsonb_array_length(public.get_own_profile()->'interests'), 10, 'ten selected interests are returned');
select accounts_profiles_test.expect_error(pg_catalog.format('select public.set_own_interests(%L::text[])',
    array(select '関心' || pg_catalog.lpad(n::text, 2, '0') from pg_catalog.generate_series(1, 11) as s(n))),
    'invalid_input', 'interest_ids', 'eleven multibyte interest identifiers are rejected');
select accounts_profiles_test.expect_error('select public.set_own_interests(array[''未登録''])', 'invalid_input', 'interest_ids', 'unknown interests are rejected');
select accounts_profiles_test.expect_error('select public.set_own_interests(null)', 'invalid_input', 'interest_ids', 'a null interest array is rejected');
select accounts_profiles_test.expect_error('select public.set_own_interests(array[''関心01'', null])', 'invalid_input', 'interest_ids', 'null interest elements are rejected');
select accounts_profiles_test.expect_error('select public.set_own_interests(array[[''関心01'']])', 'invalid_input', 'interest_ids', 'multidimensional interest arrays are rejected');
select extensions.is(pg_catalog.jsonb_array_length(public.get_own_profile()->'interests'), 10, 'rejected selections do not remove existing interests');
select extensions.lives_ok('select public.set_own_interests(array[''関心02'', ''関心01'', ''関心01''])', 'duplicate interests are normalized as a set');
select extensions.is(public.get_own_profile()->'interests', '["関心01","関心02"]'::jsonb, 'selected interests are unique and deterministically ordered');
select extensions.lives_ok('select public.set_own_interests(array[]::text[])', 'an empty interest set is allowed with discovery off');
select extensions.is(public.get_own_profile()->'interests', '[]'::jsonb, 'an empty selection replaces the interest set');

select extensions.lives_ok('select public.set_own_purposes(array[]::text[])', 'no purposes are allowed');
select extensions.lives_ok('select public.set_own_purposes(array[''discovery''])', 'one discovery purpose is allowed');
select extensions.is(public.get_own_profile()->'purposes', '["discovery"]'::jsonb, 'one purpose is returned');
select extensions.lives_ok('select public.set_own_purposes(array[''collaboration''])', 'one collaboration purpose replaces the selection');
select extensions.is(public.get_own_profile()->'purposes', '["collaboration"]'::jsonb, 'purposes are replaced rather than appended');
select extensions.lives_ok('select public.set_own_purposes(array[''discovery'', ''collaboration''])', 'both allowed purposes can be chosen');
select extensions.lives_ok('select public.set_own_purposes(array[''discovery'', ''collaboration'', ''discovery''])', 'duplicate purposes are normalized');
select extensions.is(public.get_own_profile()->'purposes', '["collaboration","discovery"]'::jsonb, 'purposes form an ordered unique set');
select accounts_profiles_test.expect_error('select public.set_own_purposes(array[''未知''])', 'invalid_input', 'purposes', 'unknown multibyte purposes are rejected');
select accounts_profiles_test.expect_error('select public.set_own_purposes(null)', 'invalid_input', 'purposes', 'a null purpose array is rejected');
select accounts_profiles_test.expect_error('select public.set_own_purposes(array[null]::text[])', 'invalid_input', 'purposes', 'null purpose elements are rejected');
select accounts_profiles_test.expect_error('select public.set_own_purposes(array[[''discovery'']])', 'invalid_input', 'purposes', 'multidimensional purpose arrays are rejected');
select extensions.is(public.get_own_profile()->'purposes', '["collaboration","discovery"]'::jsonb, 'invalid purposes preserve the existing set');

select extensions.lives_ok('select public.set_minimum_shared_interests(' || v.value || ')', 'threshold accepts ' || v.value)
from (values (1), (2), (9), (10)) as v(value)
order by v.value;
select accounts_profiles_test.expect_error(pg_catalog.format('select public.set_minimum_shared_interests(%L)', v.value),
    'invalid_input', 'value', 'threshold rejects ' || coalesce(v.value::text, 'null'))
from (values (0), (11), (null::integer)) as v(value);
select extensions.is((public.get_own_profile()->>'minimum_shared_interests')::integer, 10, 'invalid thresholds preserve the current value');

select extensions.lives_ok(pg_catalog.format('select public.set_field_visibility(%L, %L)', f.field, l.level),
    'visibility accepts ' || f.field || ' at ' || l.level)
from (values ('display_name'), ('introduction'), ('interests'), ('purposes'), ('contact_detail')) as f(field)
cross join (values ('everyone_eligible'), ('compatible_only'), ('private')) as l(level);
select accounts_profiles_test.expect_error('select public.set_field_visibility(''未知'', ''private'')', 'invalid_input', 'field', 'unknown multibyte fields are rejected');
select accounts_profiles_test.expect_error('select public.set_field_visibility(''display_name'', ''未知'')', 'invalid_input', 'level', 'unknown multibyte levels are rejected');
select accounts_profiles_test.expect_error('select public.set_field_visibility(null, ''private'')', 'invalid_input', 'field', 'null fields are rejected');
select accounts_profiles_test.expect_error('select public.set_field_visibility(''display_name'', null)', 'invalid_input', 'level', 'null visibility levels are rejected');
select accounts_profiles_test.expect_error('select public.set_field_visibility(''未知'', ''未知'')', 'invalid_input', 'field,level', 'both invalid visibility arguments are named');
select extensions.lives_ok('select public.set_field_visibility(''purposes'', ''compatible_only'')', 'purpose visibility can be changed independently');
select extensions.is(public.get_own_profile()->'field_visibility'->>'purposes', 'compatible_only', 'updated purpose visibility is returned');
select extensions.lives_ok('select public.set_field_visibility(''display_name'', ''private'')', 'a display name may be private');

select extensions.lives_ok('select public.accept_declarations(true, ''new-draft'', ''new-draft'')', 'repeat declarations succeed');
select extensions.is((public.get_own_profile()->>'minimum_shared_interests')::integer, 10, 'repeat declarations preserve the personalized threshold');
select extensions.is(public.get_own_profile()->'field_visibility'->>'purposes', 'compatible_only', 'repeat declarations preserve purpose visibility');
select extensions.is(public.get_own_profile()->'field_visibility'->>'display_name', 'private', 'repeat declarations preserve name visibility');
select extensions.is(public.get_own_profile()->>'time_zone', 'UTC', 'repeat declarations preserve the registered zone');

select accounts_profiles_test.expect_error('select public.set_discovery(true)', 'prerequisite_missing', 'display_name,introduction,interest,link',
    'a ready account still needs the four discovery prerequisites');
select extensions.lives_ok('select public.update_own_profile('' 名 '', '' 紹介 '', '' 連絡 '')', 'trimmed profile fields can be populated before discovery');
select extensions.is(pg_catalog.jsonb_build_array(public.get_own_profile()->>'display_name', public.get_own_profile()->>'introduction',
    public.get_own_profile()->>'contact_detail'), '["名","紹介","連絡"]'::jsonb, 'get_own_profile returns trimmed values');
select accounts_profiles_test.expect_error('select public.set_discovery(true)', 'prerequisite_missing', 'interest,link', 'remaining interest and link prerequisites are reported');
select extensions.lives_ok('select public.set_own_interests(array[''関心01''])', 'one interest satisfies the interest prerequisite');
select accounts_profiles_test.expect_error('select public.set_discovery(true)', 'prerequisite_missing', 'link', 'the last missing link prerequisite is reported');

reset role;
insert into private.external_links (owner_id, source, url, visibility)
values ('11111111-1111-1111-1111-111111111111', 'other', 'https://example.invalid/unit-3', 'private');
set local role authenticated;
select extensions.is(public.get_own_profile()->'prerequisites', '{"display_name":true,"introduction":true,"interest":true,"link":true}'::jsonb,
    'all four prerequisites are reported accurately');
select extensions.is((public.get_own_profile()->>'link_count')::integer, 1, 'private links count as discovery prerequisites');
select extensions.lives_ok('select public.set_own_purposes(array[]::text[])', 'purposes may be empty before discovery');
select extensions.lives_ok('select public.set_discovery(true)', 'discovery enables with a private link and no purposes');
select extensions.is(public.get_own_profile()->'discovery_on', 'true'::jsonb, 'discovery on is returned');
select accounts_profiles_test.expect_error('select public.update_own_profile(''   '', ''紹介'', ''連絡'')', 'prerequisite_missing', 'display_name', 'discovery prevents removing the display name');
select accounts_profiles_test.expect_error('select public.update_own_profile(''名'', '''', ''連絡'')', 'prerequisite_missing', 'introduction', 'discovery prevents removing the introduction');
select accounts_profiles_test.expect_error('select public.update_own_profile(null, null, '''')', 'prerequisite_missing', 'display_name,introduction', 'discovery reports both removed profile prerequisites');
select accounts_profiles_test.expect_error('select public.set_own_interests(array[]::text[])', 'prerequisite_missing', 'interest', 'discovery prevents removing the last interest');
select extensions.is(public.get_own_profile()->'prerequisites', '{"display_name":true,"introduction":true,"interest":true,"link":true}'::jsonb,
    'refused removals preserve all prerequisites');
select extensions.is(public.get_own_profile()->>'contact_detail', '連絡', 'refused profile changes are atomic');
select extensions.lives_ok('select public.update_own_profile(''名'', ''紹介'', '''')', 'contact detail may be removed with discovery on');
select extensions.lives_ok('select public.set_own_purposes(array[]::text[])', 'empty purposes remain allowed with discovery on');
select extensions.lives_ok('select public.accept_declarations(true, ''draft'', ''draft'')', 'declarations may be renewed with discovery on');
select extensions.is(public.get_own_profile()->'discovery_on', 'true'::jsonb, 'renewing declarations does not turn discovery off');
select extensions.lives_ok('select public.set_discovery(false)', 'discovery can be disabled');
select extensions.lives_ok('select public.update_own_profile('''', ''紹介'', '''')', 'a prerequisite can be removed after discovery is disabled');
select accounts_profiles_test.expect_error('select public.set_discovery(true)', 'prerequisite_missing', 'display_name', 'missing display name blocks enabling discovery');
select extensions.lives_ok('select public.update_own_profile(''名'', '''', '''')', 'introduction may be removed with discovery off');
select accounts_profiles_test.expect_error('select public.set_discovery(true)', 'prerequisite_missing', 'introduction', 'missing introduction blocks enabling discovery');
select extensions.lives_ok('select public.update_own_profile(''名'', ''紹介'', '''')', 'restore the introduction');
select extensions.lives_ok('select public.set_own_interests(array[]::text[])', 'the last interest can be removed with discovery off');
select accounts_profiles_test.expect_error('select public.set_discovery(true)', 'prerequisite_missing', 'interest', 'missing interests block enabling discovery');
select extensions.lives_ok('select public.set_own_interests(array[''関心01''])', 'restore the interest');

reset role;
delete from private.notification_preferences where user_id = '11111111-1111-1111-1111-111111111111';
set local role authenticated;
select accounts_profiles_test.expect_error('select public.set_discovery(true)', 'account_not_ready', '', 'discovery requires a registered time zone');
reset role;
insert into private.notification_preferences (user_id, time_zone) values ('11111111-1111-1111-1111-111111111111', '無効な地域');
select extensions.ok(private.account_is_ready('11111111-1111-1111-1111-111111111111'), 'readiness trusts previously registered zones without catalog validation');
set local role authenticated;
select extensions.lives_ok('select public.set_discovery(true)', 'discovery readiness does not revalidate the stored zone');
select extensions.lives_ok('select public.register_time_zone(''UTC'')', 'registration restores a valid zone');

reset role;
update private.profiles set moderation_state = 'hidden' where user_id = '11111111-1111-1111-1111-111111111111';
select extensions.ok(not private.account_is_ready('11111111-1111-1111-1111-111111111111'), 'hidden accounts are not ready');
set local role authenticated;
select accounts_profiles_test.expect_error('select public.set_discovery(true)', 'account_not_ready', '', 'hidden accounts cannot enable discovery');
select extensions.is(public.get_own_profile()->>'moderation_state', 'hidden', 'own profile returns the live moderation state');
select extensions.lives_ok('select public.set_discovery(false)', 'hidden accounts can always disable discovery');

reset role;
update private.profiles set moderation_state = 'suspended', discovery_on = true where user_id = '11111111-1111-1111-1111-111111111111';
select extensions.ok(not private.account_is_ready('11111111-1111-1111-1111-111111111111'), 'suspended accounts are not ready');
set local role authenticated;
select accounts_profiles_test.expect_error('select public.set_discovery(true)', 'account_not_ready', '', 'suspended accounts cannot enable discovery');
select extensions.lives_ok('select public.set_discovery(false)', 'a suspended account can disable existing discovery');
select extensions.is(public.get_own_profile()->'discovery_on', 'false'::jsonb, 'discovery is disabled even when readiness was lost');

reset role;
update private.profiles set moderation_state = 'active' where user_id = '11111111-1111-1111-1111-111111111111';
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
select extensions.lives_ok('select public.accept_declarations(true, ''other-draft'', ''other-draft'')', 'a second caller creates only its own profile');
select extensions.lives_ok('select public.register_time_zone(''Asia/Tokyo'')', 'a second caller registers its own zone');
select extensions.lives_ok('select public.update_own_profile(''別'', ''別の紹介'', ''別の連絡'')', 'a second caller changes its own fields');
select extensions.lives_ok('select public.set_own_interests(array[''関心02''])', 'a second caller chooses its own interests');
select extensions.lives_ok('select public.set_own_purposes(array[''collaboration''])', 'a second caller chooses its own purposes');
select extensions.lives_ok('select public.set_minimum_shared_interests(2)', 'a second caller chooses its own threshold');
select extensions.lives_ok('select public.set_field_visibility(''contact_detail'', ''compatible_only'')', 'a second caller chooses its own visibility');
select extensions.is(public.get_own_profile(), '{
    "display_name":"別", "introduction":"別の紹介", "contact_detail":"別の連絡", "interests":["関心02"], "purposes":["collaboration"],
    "minimum_shared_interests":2,
    "field_visibility":{"display_name":"everyone_eligible","introduction":"everyone_eligible","interests":"everyone_eligible","purposes":"everyone_eligible","contact_detail":"compatible_only"},
    "discovery_on":false, "link_count":0,
    "prerequisites":{"display_name":true,"introduction":true,"interest":true,"link":false},
    "declarations_recorded":true, "time_zone":"Asia/Tokyo", "moderation_state":"active"
}'::jsonb, 'own-profile fields and link counts belong only to the current caller');
select accounts_profiles_test.expect_error('select public.set_discovery(true)', 'prerequisite_missing', 'link', 'another caller cannot use the first callers link');

set local "request.jwt.claims" = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
select extensions.is(pg_catalog.jsonb_build_array(
    public.get_own_profile()->>'display_name', public.get_own_profile()->'interests', public.get_own_profile()->'purposes',
    public.get_own_profile()->'minimum_shared_interests', public.get_own_profile()->'field_visibility'->>'purposes',
    public.get_own_profile()->>'time_zone', public.get_own_profile()->'discovery_on'
), '["名",["関心01"],[],10,"compatible_only","UTC",false]'::jsonb, 'second-caller mutations do not change the first caller');

reset role;
select extensions.is((select terms_version from private.profiles where user_id = '11111111-1111-1111-1111-111111111111'),
    'draft', 'declaration versions also remain isolated by caller');
select extensions.throws_ok('insert into private.blocks (blocker_id, blocked_id) values (''11111111-1111-1111-1111-111111111111'', ''11111111-1111-1111-1111-111111111111'')',
    '23514', null, 'blocks reject self-blocks');
insert into private.blocks (blocker_id, blocked_id) values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222');
select extensions.throws_ok('insert into private.blocks (blocker_id, blocked_id) values (''11111111-1111-1111-1111-111111111111'', ''22222222-2222-2222-2222-222222222222'')',
    '23505', null, 'the block pair is a primary key');
select extensions.throws_ok('insert into private.external_links (owner_id, source, url, visibility) values (''11111111-1111-1111-1111-111111111111'', ''other'', ''https://example.invalid/unit-3'', null)',
    '23502', null, 'a link requires an explicit non-null visibility');
select extensions.throws_ok('insert into private.external_links (owner_id, source, url, visibility) values (''11111111-1111-1111-1111-111111111111'', ''other'', ''https://example.invalid/unit-3'', ''未知'')',
    '23514', null, 'link visibility rejects values outside the three levels');
select extensions.lives_ok(pg_catalog.format('insert into private.external_links (owner_id, source, url, visibility) values (%L, ''other'', ''https://example.invalid/unit-3'', %L)',
    '33333333-3333-3333-3333-333333333333', v.level), 'link visibility accepts ' || v.level)
from (values ('everyone_eligible'), ('compatible_only'), ('private')) as v(level);

insert into private.profiles (user_id, age_18_declared, terms_version, privacy_version)
values ('33333333-3333-3333-3333-333333333333', true, 'draft', 'draft');
insert into private.user_interests (user_id, interest_id) values ('33333333-3333-3333-3333-333333333333', '関心01');
insert into private.user_purposes (user_id, purpose) values ('33333333-3333-3333-3333-333333333333', 'discovery');
insert into private.matching_preferences (user_id) values ('33333333-3333-3333-3333-333333333333');
insert into private.field_visibility (owner_id, field, level) values ('33333333-3333-3333-3333-333333333333', 'display_name', 'private');
insert into private.notification_preferences (user_id, time_zone) values ('33333333-3333-3333-3333-333333333333', 'UTC');
insert into private.blocks (blocker_id, blocked_id) values
    ('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111'),
    ('22222222-2222-2222-2222-222222222222', '33333333-3333-3333-3333-333333333333');
delete from auth.users where id = '33333333-3333-3333-3333-333333333333';

select extensions.is((select pg_catalog.count(*) from private.profiles where user_id = '33333333-3333-3333-3333-333333333333'), 0::bigint, 'Auth deletion cascades to profiles');
select extensions.is((select pg_catalog.count(*) from private.user_interests where user_id = '33333333-3333-3333-3333-333333333333'), 0::bigint, 'Auth deletion cascades to interests');
select extensions.is((select pg_catalog.count(*) from private.user_purposes where user_id = '33333333-3333-3333-3333-333333333333'), 0::bigint, 'Auth deletion cascades to purposes');
select extensions.is((select pg_catalog.count(*) from private.matching_preferences where user_id = '33333333-3333-3333-3333-333333333333'), 0::bigint, 'Auth deletion cascades to matching preferences');
select extensions.is((select pg_catalog.count(*) from private.field_visibility where owner_id = '33333333-3333-3333-3333-333333333333'), 0::bigint, 'Auth deletion cascades to visibility');
select extensions.is((select pg_catalog.count(*) from private.notification_preferences where user_id = '33333333-3333-3333-3333-333333333333'), 0::bigint, 'Auth deletion cascades to notification preferences');
select extensions.is((select pg_catalog.count(*) from private.external_links where owner_id = '33333333-3333-3333-3333-333333333333'), 0::bigint, 'Auth deletion cascades to links');
select extensions.is((select pg_catalog.count(*) from private.blocks where blocker_id = '33333333-3333-3333-3333-333333333333'
    or blocked_id = '33333333-3333-3333-3333-333333333333'), 0::bigint, 'Auth deletion cascades to both incoming and outgoing blocks');
select extensions.is((select pg_catalog.count(*) from private.interests), 11::bigint, 'account deletion preserves the curated interest catalog');


-- Unicode whitespace and scalar counts use the same normalizer everywhere.
reset role;
select extensions.ok(pg_catalog.pg_get_functiondef('private.require_caller()'::regprocedure)
    !~* 'for[[:space:]]+(key[[:space:]]+share|share|update|no[[:space:]]+key[[:space:]]+update)',
    'caller existence check takes no row lock');
select extensions.ok(pg_catalog.pg_get_functiondef('private.account_is_ready(uuid)'::regprocedure)
    !~ 'pg_timezone_names', 'readiness does not scan the time zone catalog');
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
select public.set_discovery(false);
select accounts_profiles_test.expect_error(pg_catalog.format('select public.accept_declarations(true, %L, %L)',
    case when v.field = 'terms_version' then w.value else 'draft' end,
    case when v.field = 'privacy_version' then w.value else 'draft' end),
    'invalid_input', v.field, v.field || ' rejects Unicode whitespace ' || w.name)
from (values ('terms_version'), ('privacy_version')) as v(field)
cross join (values ('space', ' '), ('tab', E'\t'), ('line feed', E'\n'), ('carriage return', E'\r'),
    ('no-break space', U&'\00A0'), ('ideographic space', U&'\3000')) as w(name, value);
select extensions.lives_ok($test$select public.accept_declarations(true,
    U&'\3000' || repeat(U&'e\0301',16) || E'\t', E'\r\n' || repeat(U&'e\0301',16) || U&'\00A0')$test$,
    'padded multi-scalar declaration versions accept exactly 32 characters');
reset role;
select extensions.is((select pg_catalog.jsonb_build_array(terms_version, privacy_version)
    from private.profiles where user_id = '11111111-1111-1111-1111-111111111111'),
    pg_catalog.jsonb_build_array(pg_catalog.repeat(U&'e\0301',16), pg_catalog.repeat(U&'e\0301',16)),
    'declaration versions retain all 32 scalars and no surrounding whitespace');
set local role authenticated;
select accounts_profiles_test.expect_error($test$select public.accept_declarations(true,
    repeat(U&'e\0301',16) || 'x', repeat(U&'e\0301',16) || 'x')$test$,
    'invalid_input', 'terms_version,privacy_version', '33-scalar versions are rejected');
select extensions.lives_ok(pg_catalog.format('select public.update_own_profile(%L, %L, %L)', w.value, w.value, w.value),
    'profile accepts absent Unicode whitespace ' || w.name)
from (values ('space', ' '), ('tab', E'\t'), ('line feed', E'\n'), ('carriage return', E'\r'),
    ('no-break space', U&'\00A0'), ('ideographic space', U&'\3000')) as w(name, value);
select extensions.is(pg_catalog.jsonb_build_array(public.get_own_profile()->>'display_name',
    public.get_own_profile()->>'introduction', public.get_own_profile()->>'contact_detail'),
    '["","",""]'::jsonb, 'all whitespace-only profile fields normalize to absent');
select extensions.lives_ok($test$select public.update_own_profile(
    U&'\3000' || repeat(U&'e\0301',15) || E'\t',
    E'\n' || repeat(U&'e\0301',100) || U&'\00A0',
    E'\r' || repeat(U&'e\0301',50) || U&'\3000')$test$,
    'Unicode padding is excluded from multi-scalar profile limits');
select extensions.is(pg_catalog.jsonb_build_array(public.get_own_profile()->>'display_name',
    public.get_own_profile()->>'introduction', public.get_own_profile()->>'contact_detail'),
    pg_catalog.jsonb_build_array(pg_catalog.repeat(U&'e\0301',15), pg_catalog.repeat(U&'e\0301',100),
        pg_catalog.repeat(U&'e\0301',50)), 'profile stores exactly the permitted scalars');
select accounts_profiles_test.expect_error(pg_catalog.format('select public.update_own_profile(%L, %L, %L)',
    case when v.field = 'display_name' then pg_catalog.repeat(U&'e\0301',15) || 'x' else '' end,
    case when v.field = 'introduction' then pg_catalog.repeat(U&'e\0301',100) || 'x' else '' end,
    case when v.field = 'contact_detail' then pg_catalog.repeat(U&'e\0301',50) || 'x' else '' end),
    'invalid_input', v.field, v.field || ' refuses one scalar beyond the limit')
from (values ('display_name'), ('introduction'), ('contact_detail')) as v(field);
select extensions.lives_ok('select public.set_own_purposes(array_fill(''discovery''::text, array[10]))',
    'a ten-element purposes array may repeat its identifier');
select accounts_profiles_test.expect_error('select public.set_own_purposes(array_fill(''discovery''::text, array[11]))',
    'invalid_input', 'purposes', 'even repeated purposes cannot exceed ten input elements');
select extensions.lives_ok('select public.set_own_interests(array_fill(''関心01''::text, array[10]))',
    'ten duplicate interests count as one distinct selection');
select extensions.is(public.get_own_profile()->'interests', '["関心01"]'::jsonb, 'the interest set stores distinct identifiers');
select accounts_profiles_test.expect_error('select public.set_own_interests(array_fill(''関心01''::text, array[11]))',
    'invalid_input', 'interest_ids', 'even duplicate interests cannot exceed ten input elements');
select public.set_discovery(true);
select accounts_profiles_test.expect_error($test$select public.update_own_profile(U&'\00A0\3000' || E'\t\n\r', 'intro', '')$test$,
    'prerequisite_missing', 'display_name', 'Unicode whitespace cannot remove a discovering name');
select accounts_profiles_test.expect_error($test$select public.update_own_profile('name', U&'\00A0\3000' || E'\t\n\r', '')$test$,
    'prerequisite_missing', 'introduction', 'Unicode whitespace cannot remove a discovering introduction');
select public.set_discovery(false);
reset role;
update private.profiles set display_name = U&'\00A0\3000', introduction = E'\t\n\r'
where user_id = '11111111-1111-1111-1111-111111111111';
set local role authenticated;
select extensions.is(public.get_own_profile()->'prerequisites',
    '{"display_name":false,"introduction":false,"interest":true,"link":true}'::jsonb,
    'own-profile emptiness handles unnormalized Unicode whitespace too');
select accounts_profiles_test.expect_error('select public.set_discovery(true)', 'prerequisite_missing',
    'display_name,introduction', 'only the four discovery fields are named for a ready account');
reset role;

-- Invisible code points affect absence only, including unnormalized stored values.
select extensions.is(private.trim_input(U&'\3000' || v.value || E'\t \n' || v.value), '',
    v.code_point || ' mixed with whitespace is absent') from accounts_profiles_test.invisible_inputs as v;
select extensions.is(private.trim_input(v.value || 'A' || v.value || 'B' || v.value),
    v.value || 'A' || v.value || 'B' || v.value, v.code_point || ' around and inside visible text is preserved')
from accounts_profiles_test.invisible_inputs as v;
set local role authenticated;
select extensions.lives_ok($test$select public.update_own_profile(
    U&'\200B\200C\200D\2060\FEFF\3164\115F\1160\FFA0',
    U&'\3000\200B\2060\FEFF', U&'\115F\1160\FFA0')$test$,
    'invisible-only profile values may be cleared while discovery is off');
select extensions.is(pg_catalog.jsonb_build_array(public.get_own_profile()->>'display_name',
    public.get_own_profile()->>'introduction', public.get_own_profile()->>'contact_detail'),
    '["","",""]'::jsonb, 'invisible-only profile input is stored as absent');
select accounts_profiles_test.expect_error($test$select public.accept_declarations(true,
    U&'\200B\2060\FEFF', U&'\3164\115F\1160\FFA0')$test$,
    'invalid_input', 'terms_version,privacy_version', 'invisible-only declarations are invalid');
select public.update_own_profile('name', 'intro', '');
select public.set_discovery(true);
select accounts_profiles_test.expect_error(pg_catalog.format('select public.update_own_profile(%L, ''intro'', '''')', v.value),
    'prerequisite_missing', 'display_name', v.code_point || ' cannot replace a discovering name')
from accounts_profiles_test.invisible_inputs as v;
select accounts_profiles_test.expect_error(pg_catalog.format('select public.update_own_profile(''name'', %L, '''')', v.value),
    'prerequisite_missing', 'introduction', v.code_point || ' cannot replace a discovering introduction')
from accounts_profiles_test.invisible_inputs as v;
select public.set_discovery(false);
reset role;
update private.profiles set display_name = U&'\200B\2060\FEFF', introduction = U&'\3164\115F\1160\FFA0'
where user_id = '11111111-1111-1111-1111-111111111111';
set local role authenticated;
select extensions.is(public.get_own_profile()->'prerequisites',
    '{"display_name":false,"introduction":false,"interest":true,"link":true}'::jsonb,
    'invisible-only stored profile values are absent in prerequisites');
select accounts_profiles_test.expect_error('select public.set_discovery(true)', 'prerequisite_missing',
    'display_name,introduction', 'invisible-only stored fields cannot enable discovery');
reset role;

-- Ten zone registrations per rolling day, independent from other accounts/buckets.
delete from private.account_limit_events where bucket = 'register_time_zone'
    and user_id in ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222');
set local role authenticated;
select extensions.lives_ok('select public.register_time_zone(''UTC'')', 'zone registration ' || n || ' of ten succeeds')
from pg_catalog.generate_series(1, 10) as calls(n);
select accounts_profiles_test.expect_error('select public.register_time_zone(''Asia/Tokyo'')', 'rate_limited', '',
    'eleventh zone registration in a day is refused');
reset role;
select extensions.is((select pg_catalog.count(*) from private.account_limit_events
    where user_id = '11111111-1111-1111-1111-111111111111' and bucket = 'register_time_zone'),
    10::bigint, 'refused zone registration records no event');
select extensions.is((select n.time_zone from private.notification_preferences as n
    where n.user_id = '11111111-1111-1111-1111-111111111111'), 'UTC', 'refused zone registration preserves the latest zone');
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
select extensions.lives_ok('select public.register_time_zone(''Asia/Tokyo'')', 'another account has its own daily zone limit');
reset role;
update private.account_limit_events set occurred_at = pg_catalog.now() - interval '1 day'
where user_id = '11111111-1111-1111-1111-111111111111' and bucket = 'register_time_zone';
update private.account_limit_events set occurred_at = pg_catalog.now() - interval '2 days'
where user_id = '22222222-2222-2222-2222-222222222222' and bucket = 'register_time_zone';
insert into private.account_limit_events (user_id, bucket, occurred_at)
select '11111111-1111-1111-1111-111111111111', 'register_time_zone', pg_catalog.now() - interval '1 day' + interval '1 microsecond'
from pg_catalog.generate_series(1, 9);
insert into private.account_limit_events (user_id, bucket, occurred_at) values
    ('11111111-1111-1111-1111-111111111111', 'zone-other-bucket', pg_catalog.now() - interval '3 days');
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
select extensions.lives_ok('select public.register_time_zone(''Asia/Tokyo'')', 'zone events exactly a day old are pruned');
select accounts_profiles_test.expect_error('select public.register_time_zone(''UTC'')', 'rate_limited', '',
    'zone events just inside the day still count');
reset role;
select extensions.is((select pg_catalog.count(*) from private.account_limit_events
    where user_id = '11111111-1111-1111-1111-111111111111' and bucket = 'register_time_zone'),
    10::bigint, 'the daily limiter keeps only its current span');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events
    where user_id = '22222222-2222-2222-2222-222222222222' and bucket = 'register_time_zone'),
    1::bigint, 'daily pruning preserves another account old events');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events
    where user_id = '11111111-1111-1111-1111-111111111111' and bucket = 'zone-other-bucket'),
    1::bigint, 'daily pruning preserves another bucket old events');

select * from extensions.finish();

rollback;
