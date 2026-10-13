begin;
create extension if not exists pgtap with schema extensions;
create schema deletion_test;
grant usage on schema deletion_test to authenticated;

create function deletion_test.id(n integer)
returns uuid language sql immutable set search_path = '' as $$
    select ('a4a4a4a4-0000-0000-0000-' || pg_catalog.lpad(n::text, 12, '0'))::uuid;
$$;
create function deletion_test.digest(n integer)
returns bytea language sql immutable set search_path = '' as $$
    select pg_catalog.sha256(pg_catalog.convert_to('deletion-fixture:' || n, 'UTF8'));
$$;
create function deletion_test.call(n integer, statement text)
returns jsonb language plpgsql set search_path = '' as $$
declare result jsonb;
begin
    begin
        set local role authenticated;
        perform pg_catalog.set_config('request.jwt.claim.sub', '', true);
        perform pg_catalog.set_config('request.jwt.claims',
            pg_catalog.jsonb_build_object('sub', deletion_test.id(n), 'role', 'authenticated')::text, true);
        execute statement into result;
    exception when others then reset role; raise; end;
    reset role;
    return result;
end;
$$;
create function deletion_test.error(statement text, code text, detail text, description text, expected_state text default 'P0001')
returns text language plpgsql set search_path = pg_catalog, extensions as $$
declare actual_state text; actual_code text; actual_detail text;
begin
    begin execute statement;
    exception when others then
        get stacked diagnostics actual_state = returned_sqlstate, actual_code = message_text, actual_detail = pg_exception_detail;
        return extensions.is(pg_catalog.jsonb_build_array(actual_state, actual_code, coalesce(actual_detail, '')),
            pg_catalog.jsonb_build_array(expected_state, code, detail), description);
    end;
    return extensions.fail(description || ': expected exception');
end;
$$;
create function deletion_test.snapshot()
returns jsonb language plpgsql set search_path = '' as $$
declare relation record; rows jsonb; result jsonb := '{}'::jsonb;
begin
    for relation in select c.relname from pg_catalog.pg_class as c
        where c.relnamespace = 'private'::regnamespace and c.relkind = 'r' order by c.relname
    loop
        execute pg_catalog.format('select coalesce(jsonb_agg(to_jsonb(r) order by to_jsonb(r)::text), ''[]''::jsonb) from private.%I as r', relation.relname) into rows;
        result := result || pg_catalog.jsonb_build_object(relation.relname, rows);
    end loop;
    return result;
end;
$$;
create function deletion_test.has_reference(n integer)
returns boolean language plpgsql set search_path = '' as $$
declare relation record; present boolean;
begin
    for relation in select c.relname from pg_catalog.pg_class as c
        where c.relnamespace = 'private'::regnamespace and c.relkind = 'r'
    loop
        execute pg_catalog.format('select exists (select 1 from private.%I as r where strpos(to_jsonb(r)::text, $1) > 0)', relation.relname)
            into present using deletion_test.id(n)::text;
        if present then return true; end if;
    end loop;
    return false;
end;
$$;
create function deletion_test.owned_count(table_name text, column_name text, n integer)
returns bigint language plpgsql set search_path = '' as $$
declare result bigint;
begin
    execute pg_catalog.format('select count(*) from private.%I where %I = $1', table_name, column_name)
        into result using deletion_test.id(n);
    return result;
end;
$$;
create function deletion_test.fail_delete()
returns trigger language plpgsql set search_path = '' as $$
begin
    raise exception using errcode = 'XX000', message = 'simulated Auth deletion failure';
end;
$$;
create function deletion_test.fail_fk()
returns trigger language plpgsql set search_path = '' as $$
begin
    raise exception using errcode = '23503', message = 'database-only identifier must not escape';
end;
$$;
grant execute on all functions in schema deletion_test to authenticated;

create temporary table results (label text primary key, value jsonb, hash bytea);
insert into auth.users (id, raw_user_meta_data)
select deletion_test.id(n), case when n = 3 then '{"provider":"apple","provider_id":"client-forgery"}'::jsonb else '{}'::jsonb end
from pg_catalog.generate_series(1, 30) as n;
update auth.users set is_anonymous=true where id=deletion_test.id(1);
update auth.users set raw_user_meta_data='{"build":"Development","provider_id":"client-forgery"}'::jsonb where id=deletion_test.id(2);
insert into private.profiles (user_id, age_18_declared, terms_version, privacy_version, display_name, introduction, contact_detail, discovery_on)
select deletion_test.id(n), true, 'draft', 'draft', 'Name to erase', 'Profile to erase', 'Contact to erase', true
from pg_catalog.generate_series(2, 30) as n where n <> 20;
insert into private.notification_preferences (user_id, time_zone)
select p.user_id, 'UTC' from private.profiles as p where p.user_id::text like 'a4a4a4a4-%';
insert into private.interests (interest_id, label_ja, label_en) values ('deletion-interest', 'test', 'test');
insert into private.user_interests (user_id, interest_id)
select p.user_id, 'deletion-interest' from private.profiles as p where p.user_id::text like 'a4a4a4a4-%';
insert into private.user_purposes (user_id, purpose) values (deletion_test.id(2), 'discovery');
insert into private.matching_preferences (user_id) values (deletion_test.id(2));
insert into private.field_visibility (owner_id, field, level)
select p.user_id, 'display_name', 'everyone_eligible' from private.profiles as p where p.user_id::text like 'a4a4a4a4-%';
insert into private.external_links (link_id, owner_id, source, url, title, visibility)
select deletion_test.id(1000+n), deletion_test.id(n), 'other', 'https://example.invalid/to-erase', 'Link to erase', 'everyone_eligible'
from (values (2), (7), (22)) as f(n);
insert into auth.identities (id, user_id, provider, provider_id, identity_data, created_at, updated_at)
select deletion_test.id(2000+n), deletion_test.id(n), 'apple', 'verified-fixture-' || n,
    pg_catalog.jsonb_build_object('sub', 'verified-fixture-' || n), pg_catalog.now(), pg_catalog.now()
from (values (2), (4), (5), (6), (11)) as f(n);
insert into private.linked_identities (user_id, provider, provider_user_id, handle, verified_addresses)
values (deletion_test.id(2), 'github', '902', 'EraseHandle', array['https://example.invalid/address']);
insert into private.sessions (user_id, starts_at, expires_at)
values (deletion_test.id(2), pg_catalog.now() - interval '1 minute', pg_catalog.now() + interval '1 hour');
insert into private.qr_codes (code_digest, issuer_id, expires_at)
values (deletion_test.digest(2), deletion_test.id(2), pg_catalog.floor(extract(epoch from pg_catalog.now()))::bigint+120);
insert into auth.sessions (id, user_id, created_at, updated_at)
values (deletion_test.id(3002), deletion_test.id(2), pg_catalog.now(), pg_catalog.now());
insert into auth.refresh_tokens (token, user_id, session_id, revoked)
values ('deletion-test-refresh', deletion_test.id(2)::text, deletion_test.id(3002), false);
insert into private.temporary_tokens (token_digest, user_id, batch_id, valid_from, valid_until, delete_after)
select deletion_test.digest(n), deletion_test.id(n), deletion_test.id(n), w, w+900, w+173700
from (values (2),(7)) as f(n) cross join (select (pg_catalog.floor(extract(epoch from pg_catalog.now())/900)*900)::bigint as w) as bounds;
insert into private.account_limit_events (user_id, bucket, occurred_at)
values (deletion_test.id(2), 'issue_token_batch', pg_catalog.now());
insert into private.report_deliveries (user_id, report_day, status)
values (deletion_test.id(2), (pg_catalog.now() at time zone 'UTC')::date, 'closed');
insert into private.encounters (encounter_id, user_a, user_b, kind, day_a, day_b)
values (deletion_test.id(100), deletion_test.id(2), deletion_test.id(7), 'session',
    (pg_catalog.now() at time zone 'UTC')::date, (pg_catalog.now() at time zone 'UTC')::date);
insert into private.encounter_views (encounter_id, viewer_id, revealed, reveal_report_day, favorite)
select deletion_test.id(100), deletion_test.id(n), true, (pg_catalog.now() at time zone 'UTC')::date, true from (values (2),(7)) as f(n);
insert into private.saved_links (viewer_id, encounter_id, link_id)
values (deletion_test.id(2), deletion_test.id(100), deletion_test.id(1007)),
    (deletion_test.id(7), deletion_test.id(100), deletion_test.id(1002));
insert into private.reports (reporter_id, subject_id, encounter_id, link_id, reason, review_due_at, status, outcome, resolved_day)
values (deletion_test.id(2), deletion_test.id(7), deletion_test.id(100), deletion_test.id(1007), 'impersonation', 1, 'open', null, null),
    (deletion_test.id(7), deletion_test.id(2), deletion_test.id(100), null, 'spam', 1, 'resolved', 'dismissed', (pg_catalog.now() at time zone 'UTC')::date);
update private.profiles set moderation_state = 'suspended', operator_outcome = 'suspended' where user_id = deletion_test.id(2);
update private.profiles set moderation_state = 'hidden' where user_id = deletion_test.id(4);
insert into private.blocks (blocker_id, blocked_id, block_id, placed_day)
select deletion_test.id(n), deletion_test.id(2), deletion_test.id(4000+n), date '2026-10-10'
from (values (8),(9),(13)) as f(n);
insert into private.blocks (blocker_id, blocked_id, block_id, placed_day)
values (deletion_test.id(2), deletion_test.id(6), deletion_test.id(4002), date '2026-10-09'),
    (deletion_test.id(2), deletion_test.id(4), deletion_test.id(4004), date '2026-10-08');
insert into private.encounter_candidates (nonce_digest, uploader_id, receipt_id, peer_id, protocol_version, role,
    prior_nonce_digest, start_own_token_digest, start_peer_token_digest, start_observed_at,
    observed_duration, session_flag, is_final_evidence, first_uploaded_at, expires_at)
select deletion_test.digest(nonce), deletion_test.id(owner), deletion_test.id(5000+owner), deletion_test.id(peer), 1, 'central',
    case when nonce = 201 then deletion_test.digest(202) end, deletion_test.digest(owner), deletion_test.digest(peer),
    pg_catalog.floor(extract(epoch from pg_catalog.now()))::bigint, 120, false, true, pg_catalog.now(), pg_catalog.now()+interval '1 hour'
from (values (201,2,7),(202,7,2),(201,14,15)) as f(nonce,owner,peer);

-- 54 + 22 + 10 + 37 + 42 + 20 + 10 + 14 + 7 + 9 = 225 assertions.
select extensions.plan(225);

-- Catalog and scheduling: 54 assertions.
create temporary table deletion_functions (signature text, argument_names text[], return_type text);
insert into deletion_functions values
    ('public.delete_own_account()', null, 'jsonb'),
    ('private.apple_safety_hash(uuid)', array['account_id'], 'bytea'),
    ('private.bind_apple_identity(uuid)', array['account_id'], 'void'),
    ('private.restore_deletion_safety(uuid)', array['account_id'], 'jsonb'),
    ('private.cleanup_retained_data(timestamptz)', array['cleanup_at'], 'void');
select extensions.is(p.proargnames, f.argument_names, f.signature || ': exact argument names')
from deletion_functions as f join pg_catalog.pg_proc as p on p.oid = f.signature::regprocedure;
select extensions.is(pg_catalog.format_type(p.prorettype, null), f.return_type, f.signature || ': exact return type')
from deletion_functions as f join pg_catalog.pg_proc as p on p.oid = f.signature::regprocedure;
select extensions.ok(p.prosecdef and 'search_path=""' = any(p.proconfig), f.signature || ': definer with empty search path')
from deletion_functions as f join pg_catalog.pg_proc as p on p.oid = f.signature::regprocedure;
select extensions.is((select pg_catalog.array_agg(a.attname::text order by a.attnum) from pg_catalog.pg_attribute as a
    where a.attrelid = ('private.' || f.table_name)::regclass and a.attnum > 0 and not a.attisdropped), f.columns,
    f.table_name || ': only the allocated safety columns')
from (values ('apple_identity_bindings', array['account_id','apple_id_hash']),
    ('deletion_safety_records', array['apple_id_hash','operator_outcome','delete_after']),
    ('deletion_safety_blocks', array['apple_id_hash','blocker_id','block_id','placed_day'])) as f(table_name,columns);
select extensions.ok(c.relrowsecurity, c.relname || ': RLS') from pg_catalog.pg_class as c
where c.oid in ('private.apple_identity_bindings'::regclass, 'private.deletion_safety_records'::regclass, 'private.deletion_safety_blocks'::regclass);
select extensions.is((select pg_catalog.count(*) from pg_catalog.pg_policy as p where p.polrelid = t.name::regclass),
    0::bigint, t.name || ': no policies') from (values ('private.apple_identity_bindings'),('private.deletion_safety_records'),('private.deletion_safety_blocks')) as t(name);
select extensions.ok(not pg_catalog.has_table_privilege(r.name,t.name,'select,insert,update,delete,truncate,references,trigger,maintain'),
    r.name || ': denied ' || t.name)
from (values ('anon'),('authenticated'),('service_role')) as r(name)
cross join (values ('private.apple_identity_bindings'),('private.deletion_safety_records'),('private.deletion_safety_blocks')) as t(name);
select extensions.ok(not exists (select 1 from pg_catalog.aclexplode(coalesce(c.relacl,pg_catalog.acldefault('r',c.relowner))) as a where a.grantee=0),
    c.relname || ': no PUBLIC grants') from pg_catalog.pg_class as c
where c.oid in ('private.apple_identity_bindings'::regclass, 'private.deletion_safety_records'::regclass, 'private.deletion_safety_blocks'::regclass);
select extensions.ok(exists (select 1 from pg_catalog.pg_index where indexrelid='private.deletion_safety_records_expiry_idx'::regclass)
    and exists (select 1 from pg_catalog.pg_index where indexrelid='private.deletion_safety_blocks_blocker_idx'::regclass)
    and exists (select 1 from pg_catalog.pg_index where indexrelid='private.reports_resolved_day_idx'::regclass), 'safety/report expiry and blocker FKs are indexed');
select extensions.is((select pg_catalog.array_agg(c.confdeltype::text order by c.conname) from pg_catalog.pg_constraint as c
    where c.conrelid='private.deletion_safety_blocks'::regclass and c.contype='f'), array['c','c'], 'safety record and live blocker cascades');
-- supabase_admin grants service_role access to Vault. postgres cannot revoke
-- that platform grant, and vault is not exposed through the Data API.
select extensions.ok(not pg_catalog.has_table_privilege(r.name,t.name,'select,insert,update,delete,truncate,references,trigger,maintain')
    and not pg_catalog.has_any_column_privilege(r.name,t.name,'select,insert,update,references'), r.name || ': denied ' || t.name)
from (values ('anon'),('authenticated')) as r(name)
cross join (values ('vault.secrets'),('vault.decrypted_secrets')) as t(name);
select extensions.ok(not exists (select 1 from pg_catalog.pg_class as c
    cross join lateral pg_catalog.aclexplode(coalesce(c.relacl,pg_catalog.acldefault('r',c.relowner))) as a
    where c.oid='vault.decrypted_secrets'::regclass and a.grantee=0 and a.privilege_type='SELECT'), 'PUBLIC cannot decrypt Vault');
select extensions.ok(pg_catalog.has_table_privilege((select p.proowner from pg_catalog.pg_proc as p
    where p.oid='private.apple_safety_hash(uuid)'::regprocedure),'vault.decrypted_secrets','select'), 'the private definer can read the configured key');
select extensions.ok(not pg_catalog.has_function_privilege(r.name,'private.apple_safety_hash(uuid)','execute'),
    r.name || ': cannot execute the private Apple safety hash')
from (values ('anon'),('authenticated'),('service_role')) as r(name);
select extensions.ok(not exists (select 1 from pg_catalog.pg_proc as p
    where p.pronamespace in ('public'::regnamespace,'service'::regnamespace)
      and (p.prorettype='bytea'::regtype or pg_catalog.strpos(p.prosrc,'vault.')>0
        or pg_catalog.strpos(p.prosrc,'apple_safety_hash')>0 or pg_catalog.strpos(p.prosrc,'apple_id_hash')>0
        or pg_catalog.strpos(p.prosrc,'deletion_safety_hmac_key_v1')>0)), 'public and service functions expose neither the key nor the Apple safety hash');
select extensions.is((select pg_catalog.count(*) from cron.job where jobname='encounters-retention-cleanup'),1::bigint,'one hourly retention job');
select extensions.is((select schedule from cron.job where jobname='encounters-retention-cleanup'),'0 * * * *','retention runs hourly');
select extensions.is((select command from cron.job where jobname='encounters-retention-cleanup'),'select private.cleanup_retained_data();','retention uses the default clock');
select extensions.ok((select active and username=current_user::text and database=pg_catalog.current_database()::text
    from cron.job where jobname='encounters-retention-cleanup'),'retention job is active in this database as the migration owner');
do $$ begin
    perform cron.schedule('encounters-retention-cleanup','0 * * * *','select private.cleanup_retained_data();');
    perform cron.schedule('encounters-retention-cleanup','0 * * * *','select private.cleanup_retained_data();');
end; $$;
select extensions.is((select pg_catalog.count(*) from cron.job where jobname='encounters-retention-cleanup'),1::bigint,'rescheduling is idempotent');
select extensions.ok(not exists (select 1 from pg_catalog.pg_trigger as t join pg_catalog.pg_proc as p on p.oid=t.tgfoid
    where t.tgrelid='auth.users'::regclass and pg_catalog.strpos(p.prosrc,'restore_deletion_safety')>0), 'restoration is not wired to sign-up');

-- Exact errors and anonymous deletion: 22 assertions.
delete from vault.secrets where name='deletion_safety_hmac_key_v1';
select deletion_test.error($q$select deletion_test.call(null,'select public.delete_own_account()')$q$,'not_authenticated','','missing JWT is refused');
select deletion_test.error($q$select deletion_test.call(999,'select public.delete_own_account()')$q$,'not_authenticated','','missing Auth caller is refused');
select deletion_test.error('select private.apple_safety_hash(null)','invalid_input','account_id','hash: null ID');
select deletion_test.error('select private.apple_safety_hash(deletion_test.id(999))','not_authenticated','','hash: deleted Auth account');
select deletion_test.error('select private.restore_deletion_safety(null)','invalid_input','account_id','restore: null ID');
select deletion_test.error('select private.restore_deletion_safety(deletion_test.id(999))','not_authenticated','','restore: missing Auth account');
select deletion_test.error('select private.restore_deletion_safety(deletion_test.id(20))','account_not_ready','','restore: profile is required');
select deletion_test.error('select private.cleanup_expired_data(null)','invalid_input','cleanup_at','transient cleanup: null clock');
select deletion_test.error('select private.cleanup_retained_data(null)','invalid_input','cleanup_at','retained cleanup: null clock');
select extensions.ok(private.apple_safety_hash(deletion_test.id(1)) is null,'anonymous account needs no safety key');
select extensions.is(deletion_test.call(1,'select public.delete_own_account()'),'{"deleted":true}'::jsonb,'profile-less anonymous account is deleted');
select extensions.ok(not exists(select 1 from auth.users where id=deletion_test.id(1)),'anonymous Auth row is gone');
select extensions.is((select pg_catalog.count(*) from private.deletion_safety_records),0::bigint,'anonymous deletion leaves no safety record');
select extensions.is(deletion_test.call(3,'select public.delete_own_account()'),'{"deleted":true}'::jsonb,'client metadata cannot create an Apple identity');
select extensions.is((select pg_catalog.count(*) from private.deletion_safety_records),0::bigint,'forged metadata leaves no safety record');
insert into results (label,value) values ('before-key',deletion_test.snapshot());
select deletion_test.error('select private.apple_safety_hash(deletion_test.id(2))','prerequisite_missing','deletion_safety_key','Apple hash needs the configured server key');
select deletion_test.error('select private.bind_apple_identity(deletion_test.id(2))','prerequisite_missing','deletion_safety_key','Apple binding needs the configured server key');
select deletion_test.error($q$select deletion_test.call(2,'select public.accept_declarations(true,''draft'',''draft'')')$q$,'prerequisite_missing','deletion_safety_key','Apple declarations cannot skip binding when its key is missing');
select deletion_test.error($q$select deletion_test.call(2,'select public.delete_own_account()')$q$,'prerequisite_missing','deletion_safety_key','Apple deletion names the missing prerequisite');
select deletion_test.error('select private.restore_deletion_safety(deletion_test.id(2))','prerequisite_missing','deletion_safety_key','Apple restoration needs the same server key');
select extensions.ok(deletion_test.snapshot()=(select value from results where label='before-key'),'key preflight leaves every application row unchanged');
select extensions.ok(exists(select 1 from auth.users where id=deletion_test.id(2)) and exists(select 1 from auth.sessions where user_id=deletion_test.id(2)), 'key preflight leaves Auth and credentials intact');

-- Test-only Vault provisioning is rolled back with this transaction.
do $$ begin perform vault.create_secret('unit4-fixture-key','deletion_safety_hmac_key_v1'); end; $$;
insert into results (label,hash) values ('apple-2',private.apple_safety_hash(deletion_test.id(2))), ('apple-4',private.apple_safety_hash(deletion_test.id(4)));

-- Exact HMAC, automatic hiding and atomic failure: 10 assertions.
select extensions.ok(private.apple_safety_hash(deletion_test.id(2))=extensions.hmac(
    pg_catalog.convert_to('EEAPPLE1:apple:verified-fixture-2','UTF8'),pg_catalog.convert_to('unit4-fixture-key','UTF8'),'sha256'), 'HMAC uses the versioned UTF-8 provider input');
select extensions.ok(pg_catalog.octet_length(private.apple_safety_hash(deletion_test.id(2)))=32,'HMAC has exactly 32 bytes');
select extensions.is(deletion_test.call(4,'select public.delete_own_account()'),'{"deleted":true}'::jsonb,'automatically hidden Apple account can delete');
select extensions.ok((select operator_outcome is null from private.deletion_safety_records where apple_id_hash=(select hash from results where label='apple-4')), 'automatic hiding is never transferred as an operator sanction');
select extensions.is((select pg_catalog.count(*) from private.deletion_safety_blocks where blocker_id=deletion_test.id(2)),1::bigint,'incoming block transfers before later blocker deletion');
insert into results (label,value) values ('before-auth-failure',deletion_test.snapshot());
create trigger fail_account_deletion before delete on auth.users for each row when (old.id=deletion_test.id(2)) execute function deletion_test.fail_delete();
select deletion_test.error($q$select deletion_test.call(2,'select public.delete_own_account()')$q$,'simulated Auth deletion failure','','Auth deletion failure is never claimed as success','XX000');
select extensions.ok(deletion_test.snapshot()=(select value from results where label='before-auth-failure'),'late Auth failure rolls back profile, session, QR, safety transfer and all erasure');
select extensions.ok(exists(select 1 from auth.users where id=deletion_test.id(2)),'late failure leaves Auth intact');
select extensions.ok(exists(select 1 from auth.identities where user_id=deletion_test.id(2)),'late failure leaves verified identity intact');
select extensions.ok(exists(select 1 from auth.refresh_tokens where user_id=deletion_test.id(2)::text),'late failure leaves refresh credentials intact');
drop trigger fail_account_deletion on auth.users;

-- Apple deletion, erased references and both viewers: 37 assertions.
insert into results (label,value) values ('before-deletion-clock',pg_catalog.to_jsonb(pg_catalog.floor(extract(epoch from pg_catalog.clock_timestamp()))::bigint));
select extensions.is(deletion_test.call(2,'select public.delete_own_account()'),'{"deleted":true}'::jsonb,'successful deletion returns only deleted true');
select extensions.ok(not exists(select 1 from auth.users where id=deletion_test.id(2)),'success means the hard Auth row is gone');
select extensions.ok(not exists(select 1 from auth.identities where user_id=deletion_test.id(2)),'managed identities cascade');
select extensions.ok(not exists(select 1 from auth.sessions where user_id=deletion_test.id(2)),'managed sessions cascade');
select extensions.ok(not exists(select 1 from auth.refresh_tokens where user_id=deletion_test.id(2)::text),'managed refresh tokens cascade');
select extensions.is((select pg_catalog.count(*) from private.deletion_safety_records where apple_id_hash=(select hash from results where label='apple-2')),1::bigint,'one safety record for the verified Apple identity');
select extensions.is((select operator_outcome from private.deletion_safety_records where apple_id_hash=(select hash from results where label='apple-2')),'suspended','last operative decision survives instead of older dismissed report history');
select extensions.ok((select delete_after between (select value::text::bigint from results where label='before-deletion-clock')+31536000
    and pg_catalog.floor(extract(epoch from pg_catalog.clock_timestamp()))::bigint+31536000
    from private.deletion_safety_records where apple_id_hash=(select hash from results where label='apple-2')), 'deadline is exactly 31536000 seconds after the deletion clock');
select extensions.is((select pg_catalog.count(*) from private.deletion_safety_blocks where apple_id_hash=(select hash from results where label='apple-2')),3::bigint,'only three incoming blocks survive');
select extensions.is((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('blocker_id',blocker_id,'block_id',block_id,'placed_day',placed_day) order by blocker_id)
    from private.deletion_safety_blocks where apple_id_hash=(select hash from results where label='apple-2')),
    (select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('blocker_id',deletion_test.id(n),'block_id',deletion_test.id(4000+n),'placed_day',date '2026-10-10') order by n)
    from (values (8),(9),(13)) as f(n)), 'incoming block IDs and placement days are preserved');
select extensions.ok(not deletion_test.has_reference(2),'no application row, including safety data, contains the deleted Auth ID');
select extensions.ok(not exists(select 1 from private.deletion_safety_blocks where blocker_id=deletion_test.id(2)),'safety blocks placed on earlier deletions are erased');
select extensions.ok(not exists(select 1 from private.blocks where blocker_id=deletion_test.id(2)),'outgoing active blocks are erased');
select extensions.is(deletion_test.owned_count(t.name,t.owner_column,2),0::bigint,'owned ' || t.name || ' is erased')
from (values ('profiles','user_id'),('linked_identities','user_id'),('sessions','user_id'),('qr_codes','issuer_id'),
    ('temporary_tokens','user_id'),('account_limit_events','user_id'),('user_purposes','user_id'),('matching_preferences','user_id'),
    ('report_deliveries','user_id'),('user_interests','user_id'),('notification_preferences','user_id'),
    ('field_visibility','owner_id'),('external_links','owner_id')) as t(name,owner_column);
select extensions.ok(not exists(select 1 from private.encounters where encounter_id=deletion_test.id(100)),'shared encounter is erased');
select extensions.is((select pg_catalog.count(*) from private.encounter_views where encounter_id=deletion_test.id(100)),0::bigint,'both views and favorites are erased');
select extensions.is((select pg_catalog.count(*) from private.saved_links where encounter_id=deletion_test.id(100)),0::bigint,'both saved reference sets are erased');
select extensions.is((select pg_catalog.count(*) from private.reports where reporter_id=deletion_test.id(2) or subject_id=deletion_test.id(2)),0::bigint,'both sides of reports are erased');
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates where uploader_id=deletion_test.id(2) or peer_id=deletion_test.id(2)),0::bigint,'both sides of pending receipts are erased');
select extensions.is((select pg_catalog.count(*) from private.consumed_nonces where exchange_digest in (
    private.receipt_exchange_digest(deletion_test.digest(201),deletion_test.digest(2),deletion_test.digest(7)),
    private.receipt_exchange_digest(deletion_test.digest(202),deletion_test.digest(2),deletion_test.digest(7)))),2::bigint,'removed current and prior scoped exchanges are consumed');
select extensions.ok(exists(select 1 from private.encounter_candidates where uploader_id=deletion_test.id(14)),'same nonce in an unrelated token scope survives');
select deletion_test.error($q$select deletion_test.call(7,'select public.get_encounter_card(deletion_test.id(100))')$q$,'not_found','','other viewer loses the deleted account card');
select extensions.is(deletion_test.call(7,q.statement),q.expected,'other viewer loses ' || q.label)
from (values ('favorites','select public.list_encounter_favorites()','{"cards":[],"truncated":false}'::jsonb),
    ('saved links','select public.list_saved_links()','{"links":[],"truncated":false}'::jsonb),
    ('feed','select public.get_encounter_feed()','{"cards":[],"truncated":false}'::jsonb)) as q(label,statement,expected);

-- Every public RPC rejects the deleted account's old credentials: 42 assertions.
create temporary table old_credential_calls (statement text);
insert into old_credential_calls values
    ('select public.delete_own_account()'), ('select public.accept_declarations(true,''draft'',''draft'')'),
    ('select public.register_time_zone(''UTC'')'), ('select public.get_own_profile()'),
    ('select public.update_own_profile(''a'',''b'',''c'')'), ('select public.set_own_interests(array[''deletion-interest''])'),
    ('select public.set_own_purposes(array[''discovery''])'), ('select public.set_minimum_shared_interests(1)'),
    ('select public.set_field_visibility(''display_name'',''private'')'), ('select public.set_discovery(false)'),
    ('select public.list_interests()'), ('select public.issue_token_batch()'), ('select public.submit_receipts(''[]''::jsonb)'),
    ('select public.get_encounter_card(null)'), ('select public.get_encounter_feed()'), ('select public.list_encounter_favorites()'),
    ('select public.set_encounter_favorite(null,true)'), ('select public.save_link(null,null)'), ('select public.unsave_link(null,null)'),
    ('select public.list_saved_links()'), ('select public.block_encounter_person(null)'), ('select public.list_blocks()'),
    ('select public.unblock(null)'), ('select public.report_encounter_person(null,null,null)'), ('select public.delete_encounter(null)'),
    ('select public.get_report_settings()'), ('select public.set_report_time(21,0)'), ('select public.set_notifications_enabled(true)'),
    ('select public.get_daily_report()'), ('select public.reveal_ambient_now()'), ('select public.list_own_links()'),
    ('select public.update_own_link(null,null,null,null,null,null,null)'), ('select public.delete_own_link(null)'),
    ('select public.reorder_own_links(''{}''::uuid[])'), ('select public.get_github_connection()'), ('select public.disconnect_github()'),
    ('select public.start_session()'), ('select public.stop_session()'), ('select public.get_own_session()'),
    ('select public.issue_qr_code()'), ('select public.cancel_qr_code()'), ('select public.redeem_qr_code(null)');
select deletion_test.error(pg_catalog.format('select deletion_test.call(2,%L)',q.statement),'not_authenticated','','old credentials: ' || q.statement)
from old_credential_calls as q;

-- Retained block management and private restoration: 20 assertions.
select extensions.is(deletion_test.call(9,'select public.list_blocks()'),'{"blocks":[{"block_id":"a4a4a4a4-0000-0000-0000-000000004009","placed_day":"2026-10-10"}],"truncated":false}'::jsonb,'safety block listing exposes only its preserved reference and day');
select deletion_test.error($q$select deletion_test.call(7,'select public.unblock(deletion_test.id(4009))')$q$,'not_found','','foreign safety block cannot be removed');
select deletion_test.error($q$select deletion_test.call(9,'select public.unblock(null)')$q$,'invalid_input','block_id','unblock has exact null detail');
select extensions.is(deletion_test.call(9,'select public.unblock(deletion_test.id(4009))'),'{"unblocked":true}'::jsonb,'blocker can remove a retained safety block');
select deletion_test.error($q$select deletion_test.call(9,'select public.unblock(deletion_test.id(4009))')$q$,'not_found','','repeat safety unblock is not found');
select extensions.is(deletion_test.call(8,'select public.delete_own_account()'),'{"deleted":true}'::jsonb,'deleting another blocker removes its retained block');
select extensions.is((select pg_catalog.count(*) from private.deletion_safety_blocks where apple_id_hash=(select hash from results where label='apple-2')),1::bigint,'unblocking and blocker deletion leave only one incoming block');
select extensions.is(private.restore_deletion_safety(deletion_test.id(11)),'{"applied":false,"moderation_state":"active","restored_block_count":0}'::jsonb,'different Apple identity inherits nothing');
select extensions.ok(exists(select 1 from private.deletion_safety_records where apple_id_hash=(select hash from results where label='apple-2')),'different identity does not consume the record');
insert into auth.identities (id,user_id,provider,provider_id,identity_data,created_at,updated_at)
values (deletion_test.id(2010),deletion_test.id(10),'apple','verified-fixture-2','{"sub":"verified-fixture-2"}',pg_catalog.now(),pg_catalog.now()),
    (deletion_test.id(2012),deletion_test.id(12),'apple','verified-fixture-4','{"sub":"verified-fixture-4"}',pg_catalog.now(),pg_catalog.now());
select extensions.is(private.restore_deletion_safety(deletion_test.id(10)),'{"applied":true,"moderation_state":"suspended","restored_block_count":1}'::jsonb,'same verified Apple identity reapplies the last outcome and live block');
select extensions.is((select operator_outcome from private.profiles where user_id=deletion_test.id(10)),'suspended','restoration records the operative outcome');
select extensions.ok(exists(select 1 from private.blocks where blocker_id=deletion_test.id(13) and blocked_id=deletion_test.id(10)
    and block_id=deletion_test.id(4013) and placed_day=date '2026-10-10'),'restoration preserves original block ID and placement day');
select extensions.ok(not exists(select 1 from private.deletion_safety_records where apple_id_hash=(select hash from results where label='apple-2')),'restoration consumes the safety record');
select extensions.ok(not exists(select 1 from private.deletion_safety_blocks where apple_id_hash=(select hash from results where label='apple-2')),'restoration consumes its safety blocks');
select extensions.ok(not exists(select 1 from private.encounters where user_a=deletion_test.id(10) or user_b=deletion_test.id(10)),'restoration recreates no encounter');
select extensions.is(private.restore_deletion_safety(deletion_test.id(10)),'{"applied":false,"moderation_state":"suspended","restored_block_count":0}'::jsonb,'consumed restoration is a false/current-state repeat');
select extensions.is(private.restore_deletion_safety(deletion_test.id(12)),'{"applied":true,"moderation_state":"active","restored_block_count":0}'::jsonb,'automatic hide and deleted blocker do not restore a sanction or block');
select extensions.is(private.restore_deletion_safety(deletion_test.id(7)),'{"applied":false,"moderation_state":"active","restored_block_count":0}'::jsonb,'no Apple identity returns false and current state');
update private.profiles set moderation_state='suspended' where user_id=deletion_test.id(11);
insert into private.deletion_safety_records (apple_id_hash,operator_outcome,delete_after)
values (private.apple_safety_hash(deletion_test.id(11)),'dismissed',pg_catalog.floor(extract(epoch from pg_catalog.now()))::bigint+31536000);
select extensions.is(private.restore_deletion_safety(deletion_test.id(11)),'{"applied":true,"moderation_state":"active","restored_block_count":0}'::jsonb,'dismissed operator outcome restores active state');
insert into private.deletion_safety_records (apple_id_hash,operator_outcome,delete_after)
values (private.apple_safety_hash(deletion_test.id(11)),'hidden',pg_catalog.floor(extract(epoch from pg_catalog.now()))::bigint+31536000);
select extensions.is(private.restore_deletion_safety(deletion_test.id(11)),'{"applied":true,"moderation_state":"hidden","restored_block_count":0}'::jsonb,'hidden operator outcome restores hidden state');

-- Inject real foreign-key SQLSTATEs at the writes, checking sanitized errors.
-- Seven write paths, shared live/deleted mapping and a no-write fast path: 10.
-- Account 7 still has UTC's default 21:00 report time. Seed the latest due
-- date explicitly; the transaction clock fixes it even across real midnight.
delete from private.report_deliveries where user_id=deletion_test.id(7);
insert into private.report_deliveries (user_id,report_day,status)
select deletion_test.id(7),(pg_catalog.now() at time zone 'UTC')::date
    - case when (pg_catalog.now() at time zone 'UTC')::time < time '21:00' then 1 else 0 end,'closed';
create trigger fail_interest_fk before insert on private.user_interests for each row execute function deletion_test.fail_fk();
create trigger fail_purpose_fk before insert on private.user_purposes for each row execute function deletion_test.fail_fk();
create trigger fail_matching_fk before insert on private.matching_preferences for each row execute function deletion_test.fail_fk();
create trigger fail_visibility_fk before insert on private.field_visibility for each row execute function deletion_test.fail_fk();
create trigger fail_profile_fk before update on private.profiles for each row execute function deletion_test.fail_fk();
create trigger fail_token_fk before insert on private.temporary_tokens for each row execute function deletion_test.fail_fk();
create trigger fail_report_fk before insert on private.report_deliveries for each row execute function deletion_test.fail_fk();
-- Statement triggers reject even an attempted conflict insert or empty update.
create trigger fail_report_fast_path_write before insert or update or delete on private.report_deliveries
for each statement execute function deletion_test.fail_fk();
create trigger fail_view_fast_path_write before update on private.encounter_views
for each statement execute function deletion_test.fail_fk();
select extensions.lives_ok($q$select deletion_test.call(7,'select public.get_daily_report()')$q$,
    'closed report fast path answers normally without writing deliveries or views');
drop trigger fail_report_fast_path_write on private.report_deliveries;
drop trigger fail_view_fast_path_write on private.encounter_views;

-- Now require a write: remove the due delivery and retain a waiting ambient
-- view assigned to it, so the row-level FK race trigger cannot be bypassed.
delete from private.report_deliveries where user_id=deletion_test.id(7);
insert into private.encounters (encounter_id,user_a,user_b,kind,day_a,day_b)
values (deletion_test.id(109),deletion_test.id(7),deletion_test.id(15),'ambient',
    (pg_catalog.now() at time zone 'UTC')::date,(pg_catalog.now() at time zone 'UTC')::date);
insert into private.encounter_views (encounter_id,viewer_id,revealed,reveal_report_day)
select deletion_test.id(109),deletion_test.id(7),false,(pg_catalog.now() at time zone 'UTC')::date
    - case when (pg_catalog.now() at time zone 'UTC')::time < time '21:00' then 1 else 0 end;
select deletion_test.error(pg_catalog.format('select deletion_test.call(7,%L)',q.statement),'not_found','','live foreign-key race: ' || q.statement)
from (values ('select public.set_own_interests(array[''deletion-interest''])'), ('select public.set_own_purposes(array[''discovery''])'),
    ('select public.set_minimum_shared_interests(1)'), ('select public.set_field_visibility(''display_name'',''private'')'),
    ('select public.update_own_profile(''name'',''introduction'','''')'), ('select public.issue_token_batch()'),
    ('select public.get_daily_report()')) as q(statement);
select deletion_test.error('select private.link_write_race(deletion_test.id(7))','not_found','','live race maps to not_found with no database detail');
select deletion_test.error('select private.link_write_race(deletion_test.id(2))','not_authenticated','','deleted caller race maps to not_authenticated with no database detail');
drop trigger fail_interest_fk on private.user_interests;
drop trigger fail_purpose_fk on private.user_purposes;
drop trigger fail_matching_fk on private.matching_preferences;
drop trigger fail_visibility_fk on private.field_visibility;
drop trigger fail_profile_fk on private.profiles;
drop trigger fail_token_fk on private.temporary_tokens;
drop trigger fail_report_fk on private.report_deliveries;

-- Independent viewer calendar retention and favorites/saves: 14 assertions.
update private.notification_preferences set time_zone='Asia/Tokyo' where user_id=deletion_test.id(21);
update private.notification_preferences set time_zone='America/Los_Angeles' where user_id=deletion_test.id(22);
insert into private.encounters (encounter_id,user_a,user_b,kind,day_a,day_b)
select deletion_test.id(100+n),deletion_test.id(21),deletion_test.id(22),kind,date '2026-09-12',date '2026-09-12'
from (values (1,'session'),(2,'qr'),(3,'ambient')) as f(n,kind);
insert into private.encounter_views (encounter_id,viewer_id,revealed,reveal_report_day,favorite)
select deletion_test.id(100+n),deletion_test.id(viewer),true,date '2026-09-12',n=2 and viewer=21
from pg_catalog.generate_series(1,3) as n cross join (values (21),(22)) as f(viewer);
insert into private.saved_links (viewer_id,encounter_id,link_id)
values (deletion_test.id(21),deletion_test.id(103),deletion_test.id(1022));
select private.cleanup_retained_data(timestamptz '2026-10-11 14:59:59.999999+00');
select extensions.is((select pg_catalog.count(*) from private.encounter_views where encounter_id=deletion_test.id(101)),2::bigint,'both views survive just before the first local deadline');
select private.cleanup_retained_data(timestamptz '2026-10-11 15:00:00+00');
select extensions.ok(not exists(select 1 from private.encounter_views where encounter_id=deletion_test.id(101) and viewer_id=deletion_test.id(21)),'Tokyo viewer expires at its thirtieth local midnight');
select extensions.ok(exists(select 1 from private.encounter_views where encounter_id=deletion_test.id(101) and viewer_id=deletion_test.id(22)),'Los Angeles viewer independently retains access');
select extensions.ok(exists(select 1 from private.encounters where encounter_id=deletion_test.id(101)),'one remaining view keeps the shared encounter');
select private.cleanup_retained_data(timestamptz '2026-10-12 06:59:59.999999+00');
select extensions.ok(exists(select 1 from private.encounter_views where encounter_id=deletion_test.id(101)),'second viewer survives just before its own deadline');
select private.cleanup_retained_data(timestamptz '2026-10-12 07:00:00+00');
select extensions.ok(not exists(select 1 from private.encounters where encounter_id=deletion_test.id(101)),'encounter disappears when neither viewer retains access');
select extensions.ok(not exists(select 1 from private.encounter_views where encounter_id=deletion_test.id(101)),'neither expired view remains');
select extensions.ok(exists(select 1 from private.encounter_views where encounter_id=deletion_test.id(102) and viewer_id=deletion_test.id(21)),'favorite retains one viewer indefinitely');
select extensions.ok(not exists(select 1 from private.encounter_views where encounter_id=deletion_test.id(102) and viewer_id=deletion_test.id(22)),'favorite never retains the other viewer');
select extensions.ok(exists(select 1 from private.encounter_views where encounter_id=deletion_test.id(103) and viewer_id=deletion_test.id(21)),'saved reference retains its viewer');
select extensions.ok(not exists(select 1 from private.encounter_views where encounter_id=deletion_test.id(103) and viewer_id=deletion_test.id(22)),'saved reference never retains the other viewer');
update private.encounter_views set favorite=false where encounter_id=deletion_test.id(102);
delete from private.saved_links where encounter_id=deletion_test.id(103);
select private.cleanup_retained_data(timestamptz '2026-10-12 07:00:00+00');
select extensions.ok(not exists(select 1 from private.encounters where encounter_id in (deletion_test.id(102),deletion_test.id(103))),'removing the last retention reason allows physical erasure');
select private.cleanup_retained_data(timestamptz '2026-10-12 07:00:00+00');
select extensions.is((select pg_catalog.count(*) from private.encounter_views where encounter_id in (deletion_test.id(101),deletion_test.id(102),deletion_test.id(103))),0::bigint,'retention replay is idempotent');
select extensions.ok(not exists(select 1 from private.saved_links where encounter_id=deletion_test.id(103)),'saved references do not survive physical erasure');

-- Resolved reports expire after interim 30 UTC days; open reports do not: 7.
insert into private.reports (reporter_id,subject_id,reason,status,review_due_at,outcome,resolved_day)
select deletion_test.id(21),deletion_test.id(subject),'spam','resolved',1,'hidden',day
from (values (22,date '2026-09-12'),(23,date '2026-09-11'),(24,date '2026-09-13')) as f(subject,day);
insert into private.reports (reporter_id,subject_id,reason,status,review_due_at)
values (deletion_test.id(21),deletion_test.id(25),'other','open',1);
update private.profiles set moderation_state='hidden',operator_outcome='hidden' where user_id=deletion_test.id(22);
select private.cleanup_retained_data(timestamptz '2026-10-11 23:59:59.999999+00');
select extensions.ok(exists(select 1 from private.reports where subject_id=deletion_test.id(22)),'resolved report survives before the thirtieth UTC midnight');
select extensions.ok(not exists(select 1 from private.reports where subject_id=deletion_test.id(23)),'older resolved report is erased');
select private.cleanup_retained_data(timestamptz '2026-10-12 00:00:00+00');
select extensions.ok(not exists(select 1 from private.reports where subject_id=deletion_test.id(22)),'resolved report expires at exactly thirty UTC days');
select extensions.ok(exists(select 1 from private.reports where subject_id=deletion_test.id(24)),'younger resolved report survives');
select extensions.ok(exists(select 1 from private.reports where subject_id=deletion_test.id(25) and status='open'),'unresolved report never expires by age');
select extensions.is((select moderation_state from private.profiles where user_id=deletion_test.id(22)),'hidden','report expiry never reactivates a hidden account');
select extensions.is((select operator_outcome from private.profiles where user_id=deletion_test.id(22)),'hidden','report expiry preserves the separate operative decision');

-- Whole-second safety expiry, pre-cleanup reads and restore: 9 assertions.
insert into private.blocks (blocker_id,blocked_id,block_id,placed_day)
values (deletion_test.id(14),deletion_test.id(5),deletion_test.id(4014),date '2026-10-10');
select extensions.is(deletion_test.call(5,'select public.delete_own_account()'),'{"deleted":true}'::jsonb,'a fresh safety record is created for expiry testing');
insert into results (label,hash,value) select 'expiry',apple_id_hash,pg_catalog.to_jsonb(delete_after) from private.deletion_safety_records;
select private.cleanup_retained_data(pg_catalog.to_timestamp((select value::text::bigint from results where label='expiry')::double precision)-interval '1 microsecond');
select extensions.ok(exists(select 1 from private.deletion_safety_records where apple_id_hash=(select hash from results where label='expiry')),'safety record survives one microsecond before its whole-second deadline');
select extensions.ok(exists(select 1 from private.deletion_safety_blocks where block_id=deletion_test.id(4014)),'incoming block survives until its record deadline');
select private.cleanup_retained_data(pg_catalog.to_timestamp((select value::text::bigint from results where label='expiry')::double precision));
select extensions.ok(not exists(select 1 from private.deletion_safety_records where apple_id_hash=(select hash from results where label='expiry')),'safety record expires at the exact 31536000-second deadline');
select extensions.ok(not exists(select 1 from private.deletion_safety_blocks where block_id=deletion_test.id(4014)),'record expiry cascades its safety blocks');
insert into private.deletion_safety_records (apple_id_hash,operator_outcome,delete_after)
values (private.apple_safety_hash(deletion_test.id(11)),'suspended',pg_catalog.floor(extract(epoch from pg_catalog.now()))::bigint);
insert into private.deletion_safety_blocks (apple_id_hash,blocker_id,block_id,placed_day)
values (private.apple_safety_hash(deletion_test.id(11)),deletion_test.id(15),deletion_test.id(4015),date '2026-10-10');
select extensions.is(deletion_test.call(15,'select public.list_blocks()'),'{"blocks":[],"truncated":false}'::jsonb,'expired safety blocks are hidden before cleanup');
select deletion_test.error($q$select deletion_test.call(15,'select public.unblock(deletion_test.id(4015))')$q$,'not_found','','expired safety block is not found before cleanup');
select extensions.is(private.restore_deletion_safety(deletion_test.id(11)),'{"applied":false,"moderation_state":"hidden","restored_block_count":0}'::jsonb,'restore ignores an expired sanction and preserves current state');
select extensions.ok(not exists(select 1 from private.deletion_safety_records),'restore physically consumes an expired record and its blocks');

select * from extensions.finish();
rollback;
