begin;
create extension if not exists pgtap with schema extensions;
create schema deletion_review_test;
grant usage on schema deletion_review_test to authenticated;

create function deletion_review_test.id(n integer)
returns uuid language sql immutable set search_path = '' as $$
    select ('b4b4b4b4-0000-0000-0000-' || pg_catalog.lpad(n::text, 12, '0'))::uuid;
$$;
create function deletion_review_test.digest(n integer)
returns bytea language sql immutable set search_path = '' as $$
    select pg_catalog.sha256(pg_catalog.convert_to('deletion-review:' || n, 'UTF8'));
$$;
create function deletion_review_test.call(n integer, statement text)
returns jsonb language plpgsql set search_path = '' as $$
declare result jsonb;
begin
    begin
        set local role authenticated;
        perform pg_catalog.set_config('request.jwt.claim.sub', '', true);
        perform pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object(
            'sub', deletion_review_test.id(n), 'role', 'authenticated')::text, true);
        execute statement into result;
    exception when others then reset role; raise; end;
    reset role;
    return result;
end;
$$;
create function deletion_review_test.declare_account(n integer)
returns void language plpgsql set search_path = '' as $$
begin
    begin
        set local role authenticated;
        perform pg_catalog.set_config('request.jwt.claim.sub', '', true);
        perform pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object(
            'sub', deletion_review_test.id(n), 'role', 'authenticated')::text, true);
        perform public.accept_declarations(true, 'draft', 'draft');
    exception when others then reset role; raise; end;
    reset role;
end;
$$;
create function deletion_review_test.error(statement text, code text, detail text, description text)
returns text language plpgsql set search_path = pg_catalog, extensions as $$
declare actual_state text; actual_code text; actual_detail text;
begin
    begin execute statement;
    exception when others then
        get stacked diagnostics actual_state = returned_sqlstate, actual_code = message_text, actual_detail = pg_exception_detail;
        return extensions.is(pg_catalog.jsonb_build_array(actual_state, actual_code, coalesce(actual_detail, '')),
            pg_catalog.jsonb_build_array('P0001'::text, code, detail), description);
    end;
    return extensions.fail(description || ': expected exception');
end;
$$;
grant execute on all functions in schema deletion_review_test to authenticated;
create temporary table review_results (label text primary key, value jsonb, hash bytea);

insert into auth.users (id) select deletion_review_test.id(n) from pg_catalog.generate_series(1, 20) as n;
insert into private.profiles (user_id, age_18_declared, terms_version, privacy_version, discovery_on)
select deletion_review_test.id(n), true, 'draft', 'draft', true from pg_catalog.generate_series(1, 20) as n;
insert into private.notification_preferences (user_id, time_zone)
select deletion_review_test.id(n), case when n = 19 then 'Unknown/Zone' else 'UTC' end
from pg_catalog.generate_series(1, 20) as n where n <> 18;
insert into auth.identities (id, user_id, provider, provider_id, identity_data, created_at, updated_at)
select deletion_review_test.id(2000+n), deletion_review_test.id(n), 'apple', 'review-fixture-' || n,
    pg_catalog.jsonb_build_object('sub', 'review-fixture-' || n), pg_catalog.now(), pg_catalog.now()
from (values (1), (3), (9), (10), (11), (12), (13), (15)) as f(n);
delete from vault.secrets where name = 'deletion_safety_hmac_key_v1';
do $$ begin perform vault.create_secret('review-fixture-key', 'deletion_safety_hmac_key_v1'); end; $$;
insert into review_results (label, hash)
select 'apple-' || n, private.apple_safety_hash(deletion_review_test.id(n))
from (values (1), (3), (9), (10), (11), (12), (13), (15)) as f(n);

-- Binding/error contract 5 + unlink and lock witnesses 11 + repeat/merge 16
-- + expired replacement 5 + expired/empty deletion 6 + restore binding/locks 5
-- + immutable binding 1 + unblock 6 + calendar/cleanup locks 8
-- + live Apple exclusivity/race 10 + unusable zone cleanup 3 = 76.
select extensions.plan(76);

select extensions.is((select pg_catalog.array_agg(a.attname::text order by a.attnum)
    from pg_catalog.pg_attribute as a where a.attrelid = 'private.apple_identity_bindings'::regclass
      and a.attnum > 0 and not a.attisdropped), array['account_id', 'apple_id_hash'], 'binding contains only live account and private hash');
select extensions.is((select c.confdeltype::text from pg_catalog.pg_constraint as c
    where c.conrelid = 'private.apple_identity_bindings'::regclass and c.contype = 'f'), 'c', 'binding cascades with its live Auth account');
select deletion_review_test.error('select private.bind_apple_identity(null)', 'invalid_input', 'account_id', 'binding rejects a null account');
select deletion_review_test.error('select private.bind_apple_identity(deletion_review_test.id(999))', 'not_authenticated', '', 'binding rejects a missing live account');
select private.bind_apple_identity(deletion_review_test.id(2));
select extensions.ok(not exists (select 1 from private.apple_identity_bindings where account_id = deletion_review_test.id(2)), 'non-Apple account creates no binding');

-- A declaration binds verified evidence before an Auth unlink can remove it.
update private.profiles set moderation_state = 'suspended', operator_outcome = 'suspended' where user_id = deletion_review_test.id(1);
select extensions.lives_ok('select deletion_review_test.declare_account(1)', 'accepting declarations binds the verified Apple account');
select extensions.is((select apple_id_hash from private.apple_identity_bindings where account_id = deletion_review_test.id(1)),
    (select hash from review_results where label = 'apple-1'), 'declarations bind the server-computed hash');
delete from auth.identities where user_id = deletion_review_test.id(1) and provider = 'apple';
select extensions.ok(private.apple_safety_hash(deletion_review_test.id(1)) is null, 'the Auth identity is actually unlinked');
select private.bind_apple_identity(deletion_review_test.id(1));
select extensions.is((select apple_id_hash from private.apple_identity_bindings where account_id = deletion_review_test.id(1)),
    (select hash from review_results where label = 'apple-1'), 'binding survives a repeat call after unlink');
-- The first live account retains its binding after an independent Auth unlink.
-- Another account may now hold the managed identity, but cannot bind that hash.
insert into auth.identities (id,user_id,provider,provider_id,identity_data)
values (deletion_review_test.id(2014),deletion_review_test.id(14),'apple','review-fixture-1','{"sub":"review-fixture-1"}');
select extensions.ok(exists(select 1 from pg_catalog.pg_constraint as c
    where c.conrelid='private.apple_identity_bindings'::regclass and c.contype='u'
      and pg_catalog.pg_get_constraintdef(c.oid)='UNIQUE (apple_id_hash)'), 'one live binding per Apple hash is enforced by a unique constraint');
select deletion_review_test.error('select private.bind_apple_identity(deletion_review_test.id(14))','account_not_ready','',
    'second live account cannot bind an Apple hash and receives no identifier detail');
select deletion_review_test.error('select deletion_review_test.declare_account(14)','account_not_ready','',
    'declarations refuse the already bound Apple identity');
select deletion_review_test.error('select deletion_review_test.call(14,''select public.delete_own_account()'')','account_not_ready','',
    'public deletion refuses the already bound Apple identity without leaking a hash');
select deletion_review_test.error('select private.restore_deletion_safety(deletion_review_test.id(14))','account_not_ready','',
    'restoration cannot consume safety records through an identity bound to another account');
select extensions.ok(not exists(select 1 from private.apple_identity_bindings where account_id=deletion_review_test.id(14))
    and exists(select 1 from auth.users where id=deletion_review_test.id(14)), 'refused binding/deletion leaves the second account intact and unbound');
select extensions.is((select apple_id_hash from private.apple_identity_bindings where account_id=deletion_review_test.id(1)),
    (select hash from review_results where label='apple-1'),'second-account refusals preserve the first binding');
delete from auth.identities where user_id=deletion_review_test.id(14);
insert into private.blocks (blocker_id, blocked_id, block_id, placed_day)
values (deletion_review_test.id(2), deletion_review_test.id(1), deletion_review_test.id(1001), date '2026-10-10');
insert into private.encounters (encounter_id, user_a, user_b, kind, day_a, day_b)
values (deletion_review_test.id(8001), deletion_review_test.id(1), deletion_review_test.id(2), 'session', current_date, current_date);
insert into private.encounter_candidates (nonce_digest, uploader_id, receipt_id, peer_id, protocol_version, role,
    start_own_token_digest, start_peer_token_digest, start_observed_at, observed_duration, session_flag,
    is_final_evidence, first_uploaded_at, expires_at)
values (deletion_review_test.digest(501), deletion_review_test.id(1), deletion_review_test.id(5001), deletion_review_test.id(2), 1, 'central',
    deletion_review_test.digest(1), deletion_review_test.digest(2), pg_catalog.floor(extract(epoch from pg_catalog.now()))::bigint,
    120, true, true, pg_catalog.now(), pg_catalog.now() + interval '1 hour');

-- Uncontended tuple locks are stored in the tuple, not enumerated in pg_locks.
-- Observe relation modes/advisory keys at the profile write, and separately pin
-- the statement order and FOR UPDATE strength in the function definition.
create function deletion_review_test.observe_profile_locks()
returns trigger language plpgsql set search_path = '' as $$
declare nonce_key bigint := pg_catalog.hashtextextended(pg_catalog.encode(deletion_review_test.digest(501), 'hex'), 0);
begin
    insert into pg_temp.review_results (label, value)
    select 'profile-locks', pg_catalog.jsonb_build_array(
        exists (select 1 from pg_catalog.pg_locks as l where l.pid = pg_catalog.pg_backend_pid() and l.granted
            and l.locktype = 'advisory' and l.classid = 31001 and l.objsubid = 2
            and l.objid::bigint = (pg_catalog.hashtext(new.user_id::text)::bigint & 4294967295)),
        exists (select 1 from pg_catalog.pg_locks as l where l.pid = pg_catalog.pg_backend_pid() and l.granted
            and l.locktype = 'advisory' and l.classid = 31003 and l.objsubid = 2
            and l.objid::bigint = (pg_catalog.hashtext(new.user_id::text || ':' || deletion_review_test.id(2)::text)::bigint & 4294967295)),
        exists (select 1 from pg_catalog.pg_locks as l where l.pid = pg_catalog.pg_backend_pid() and l.granted
            and l.locktype = 'advisory' and l.objsubid = 1
            and l.classid::bigint = ((nonce_key >> 32) & 4294967295) and l.objid::bigint = (nonce_key & 4294967295)),
        exists (select 1 from pg_catalog.pg_locks as l where l.pid = pg_catalog.pg_backend_pid() and l.granted
            and l.locktype = 'relation' and l.relation = 'auth.users'::regclass and l.mode = 'RowShareLock'));
    return new;
end;
$$;
create trigger observe_deletion_profile_locks before update on private.profiles
for each row when (old.user_id = deletion_review_test.id(1)) execute function deletion_review_test.observe_profile_locks();
select extensions.is(deletion_review_test.call(1, 'select public.delete_own_account()'), '{"deleted":true}'::jsonb, 'unlinked Apple account deletes successfully');
drop trigger observe_deletion_profile_locks on private.profiles;
select extensions.is((select operator_outcome from private.deletion_safety_records where apple_id_hash = (select hash from review_results where label = 'apple-1')),
    'suspended', 'unlinked Apple deletion retains the bound outcome');
select extensions.ok(exists (select 1 from private.deletion_safety_blocks where apple_id_hash = (select hash from review_results where label = 'apple-1')
    and block_id = deletion_review_test.id(1001)), 'unlinked Apple deletion transfers its incoming block');
select extensions.ok(not exists (select 1 from private.apple_identity_bindings where account_id = deletion_review_test.id(1)), 'binding is erased after safety transfer');
select extensions.ok(not exists (select 1 from auth.users where id = deletion_review_test.id(1)), 'unlinked account is hard deleted');
select extensions.is((select value from review_results where label = 'profile-locks'), '[true,true,true,true]'::jsonb,
    'profile write observes account, nonce, pair and Auth row-lock relation modes');
select extensions.ok(pg_catalog.strpos(p.prosrc, 'loop perform pg_catalog.pg_advisory_xact_lock(31003, pair_key); end loop;')
        < pg_catalog.strpos(p.prosrc, 'perform 1 from auth.users as u where u.id = caller for update;')
    and pg_catalog.strpos(p.prosrc, 'perform 1 from auth.users as u where u.id = caller for update;') > 0
    and pg_catalog.strpos(p.prosrc, 'perform 1 from auth.users as u where u.id = caller for update;')
        < pg_catalog.strpos(p.prosrc, 'perform private.turn_discovery_off(caller);'), 'deletion locks Auth FOR UPDATE after pairs and before the profile write')
from pg_catalog.pg_proc as p where p.oid = 'private.delete_own_account()'::regprocedure;

-- Returning before the Unit 7 restoration hook cannot launder a retained decision.
update private.profiles set moderation_state = 'suspended', operator_outcome = 'suspended' where user_id = deletion_review_test.id(3);
insert into private.blocks (blocker_id, blocked_id, block_id, placed_day)
values (deletion_review_test.id(2), deletion_review_test.id(3), deletion_review_test.id(1003), date '2026-10-10');
select extensions.is(deletion_review_test.call(3, 'select public.delete_own_account()'), '{"deleted":true}'::jsonb, 'first suspended deletion creates retained content');
update private.deletion_safety_records set delete_after = pg_catalog.floor(extract(epoch from pg_catalog.now()))::bigint + 86400
where apple_id_hash = (select hash from review_results where label = 'apple-3');
insert into review_results (label, value) select 'repeat-expiry', pg_catalog.to_jsonb(delete_after) from private.deletion_safety_records
where apple_id_hash = (select hash from review_results where label = 'apple-3');
insert into auth.identities (id, user_id, provider, provider_id, identity_data)
values (deletion_review_test.id(2004), deletion_review_test.id(4), 'apple', 'review-fixture-3', '{"sub":"review-fixture-3"}');
select extensions.lives_ok('select deletion_review_test.declare_account(4)', 'returning account binds the same verified Apple identity');
select extensions.is(deletion_review_test.call(4, 'select public.delete_own_account()'), '{"deleted":true}'::jsonb, 'returning account can delete again before restoration');
select extensions.is((select operator_outcome from private.deletion_safety_records where apple_id_hash = (select hash from review_results where label = 'apple-3')),
    'suspended', 'null new outcome preserves the retained suspension');
select extensions.is((select pg_catalog.to_jsonb(delete_after) from private.deletion_safety_records where apple_id_hash = (select hash from review_results where label = 'apple-3')),
    (select value from review_results where label = 'repeat-expiry'), 'empty repeat deletion does not extend expiry');
select extensions.ok(exists (select 1 from private.deletion_safety_blocks where block_id = deletion_review_test.id(1003)), 'empty repeat deletion preserves retained blocks');

insert into auth.identities (id, user_id, provider, provider_id, identity_data)
values (deletion_review_test.id(2005), deletion_review_test.id(5), 'apple', 'review-fixture-3', '{"sub":"review-fixture-3"}');
insert into private.blocks (blocker_id, blocked_id, block_id, placed_day)
values (deletion_review_test.id(6), deletion_review_test.id(5), deletion_review_test.id(1005), date '2026-10-11');
select extensions.is(deletion_review_test.call(5, 'select public.delete_own_account()'), '{"deleted":true}'::jsonb, 'new incoming block merges with an unexpired record');
select extensions.is((select operator_outcome from private.deletion_safety_records where apple_id_hash = (select hash from review_results where label = 'apple-3')),
    'suspended', 'block-only merge preserves the operator decision');
select extensions.is((select pg_catalog.array_agg(block_id order by blocker_id) from private.deletion_safety_blocks
    where apple_id_hash = (select hash from review_results where label = 'apple-3')), array[deletion_review_test.id(1003), deletion_review_test.id(1005)], 'incoming blocks merge without replacing earlier references');
select extensions.ok((select delete_after > (select value::text::bigint from review_results where label = 'repeat-expiry')
    and delete_after <= pg_catalog.floor(extract(epoch from pg_catalog.clock_timestamp()))::bigint + 31536000
    from private.deletion_safety_records where apple_id_hash = (select hash from review_results where label = 'apple-3')), 'new retained block extends expiry from the deletion clock');

-- Force a distinguishable deadline even when both deletes finish in one second.
update private.deletion_safety_records set delete_after = pg_catalog.floor(extract(epoch from pg_catalog.now()))::bigint + 86400
where apple_id_hash = (select hash from review_results where label = 'apple-3');
insert into review_results (label, value) select 'duplicate-expiry', pg_catalog.to_jsonb(delete_after) from private.deletion_safety_records
where apple_id_hash = (select hash from review_results where label = 'apple-3');
insert into auth.identities (id, user_id, provider, provider_id, identity_data)
values (deletion_review_test.id(2007), deletion_review_test.id(7), 'apple', 'review-fixture-3', '{"sub":"review-fixture-3"}');
insert into private.blocks (blocker_id, blocked_id, block_id, placed_day)
values (deletion_review_test.id(2), deletion_review_test.id(7), deletion_review_test.id(1007), date '2026-10-12');
select extensions.is(deletion_review_test.call(7, 'select public.delete_own_account()'), '{"deleted":true}'::jsonb, 'duplicate incoming blocker can delete again');
select extensions.is((select block_id from private.deletion_safety_blocks where blocker_id = deletion_review_test.id(2)
    and apple_id_hash = (select hash from review_results where label = 'apple-3')), deletion_review_test.id(1003), 'duplicate blocker keeps the existing block reference');
select extensions.is((select pg_catalog.to_jsonb(delete_after) from private.deletion_safety_records where apple_id_hash = (select hash from review_results where label = 'apple-3')),
    (select value from review_results where label = 'duplicate-expiry'), 'duplicate-only merge writes no content and does not extend expiry');

insert into auth.identities (id, user_id, provider, provider_id, identity_data)
values (deletion_review_test.id(2008), deletion_review_test.id(8), 'apple', 'review-fixture-3', '{"sub":"review-fixture-3"}');
update private.profiles set moderation_state = 'hidden', operator_outcome = 'hidden' where user_id = deletion_review_test.id(8);
select extensions.is(deletion_review_test.call(8, 'select public.delete_own_account()'), '{"deleted":true}'::jsonb, 'new operative decision is retained on repeat deletion');
select extensions.is((select operator_outcome from private.deletion_safety_records where apple_id_hash = (select hash from review_results where label = 'apple-3')),
    'hidden', 'non-null new outcome replaces the retained outcome');
select extensions.is((select pg_catalog.count(*) from private.deletion_safety_blocks where apple_id_hash = (select hash from review_results where label = 'apple-3')),
    2::bigint, 'replacement decision preserves incoming blocks');

-- Expired records must be deleted together with their children before writing.
insert into private.deletion_safety_records (apple_id_hash, operator_outcome, delete_after)
select hash, 'suspended', pg_catalog.floor(extract(epoch from pg_catalog.now()))::bigint - 1
from review_results where label in ('apple-9', 'apple-10');
insert into private.deletion_safety_blocks (apple_id_hash, blocker_id, block_id, placed_day)
select hash, deletion_review_test.id(2), deletion_review_test.id(1000+n), date '2026-10-10'
from (values (9), (10)) as f(n) join review_results as r on r.label = 'apple-' || n;
insert into private.blocks (blocker_id, blocked_id, block_id, placed_day)
values (deletion_review_test.id(6), deletion_review_test.id(9), deletion_review_test.id(6009), date '2026-10-12');
select extensions.is(deletion_review_test.call(9, 'select public.delete_own_account()'), '{"deleted":true}'::jsonb, 'expired record is replaced when new content exists');
select extensions.ok((select operator_outcome is null from private.deletion_safety_records where apple_id_hash = (select hash from review_results where label = 'apple-9')),
    'expired suspension is not revived by the new block-only record');
select extensions.ok(not exists (select 1 from private.deletion_safety_blocks where block_id = deletion_review_test.id(1009)), 'expired incoming block is erased before replacement');
select extensions.is((select pg_catalog.array_agg(block_id) from private.deletion_safety_blocks where apple_id_hash = (select hash from review_results where label = 'apple-9')),
    array[deletion_review_test.id(6009)], 'replacement record contains only the new block');
select extensions.ok((select delete_after > pg_catalog.floor(extract(epoch from pg_catalog.now()))::bigint + 31535999
    from private.deletion_safety_records where apple_id_hash = (select hash from review_results where label = 'apple-9')), 'replacement gets a new whole-second retention deadline');
select extensions.is(deletion_review_test.call(10, 'select public.delete_own_account()'), '{"deleted":true}'::jsonb, 'expired record with no new content can delete');
select extensions.ok(not exists (select 1 from private.deletion_safety_records where apple_id_hash = (select hash from review_results where label = 'apple-10')), 'empty deletion never revives an expired record');
select extensions.ok(not exists (select 1 from private.deletion_safety_blocks where block_id = deletion_review_test.id(1010)), 'empty deletion still erases the expired child block');
update private.profiles set moderation_state = 'hidden' where user_id = deletion_review_test.id(11);
select extensions.is(deletion_review_test.call(11, 'select public.delete_own_account()'), '{"deleted":true}'::jsonb, 'automatically hidden Apple account with nothing to retain deletes');
select extensions.ok(not exists (select 1 from private.deletion_safety_records where apple_id_hash = (select hash from review_results where label = 'apple-11')), 'empty Apple deletion writes no safety record');
select extensions.ok(not exists (select 1 from private.apple_identity_bindings where account_id = deletion_review_test.id(11)), 'empty Apple deletion erases its temporary binding too');

insert into private.deletion_safety_records (apple_id_hash, operator_outcome, delete_after)
select hash, 'suspended', pg_catalog.floor(extract(epoch from pg_catalog.now()))::bigint + 31536000 from review_results where label = 'apple-12';
select extensions.is(private.restore_deletion_safety(deletion_review_test.id(12)), '{"applied":true,"moderation_state":"suspended","restored_block_count":0}'::jsonb, 'restoration applies the retained decision');
select extensions.is((select apple_id_hash from private.apple_identity_bindings where account_id = deletion_review_test.id(12)),
    (select hash from review_results where label = 'apple-12'), 'restoration also binds verified Apple evidence');
delete from auth.identities where user_id = deletion_review_test.id(12) and provider = 'apple';
select extensions.is(deletion_review_test.call(12, 'select public.delete_own_account()'), '{"deleted":true}'::jsonb, 'restored account can unlink and delete again');
select extensions.is((select operator_outcome from private.deletion_safety_records where apple_id_hash = (select hash from review_results where label = 'apple-12')),
    'suspended', 'restoration binding protects a later deletion after unlink');
select extensions.ok(pg_catalog.strpos(p.prosrc, 'order by u.id for key share;') > 0
    and pg_catalog.strpos(p.prosrc, 'order by u.id for key share;') < pg_catalog.strpos(p.prosrc, 'order by b.blocker_id for update;')
    and pg_catalog.strpos(p.prosrc, 'order by u.id for key share;') < pg_catalog.strpos(p.prosrc, 'where p.user_id = account_id for update;'),
    'restoration locks Auth in account order before retained blocks and profile')
from pg_catalog.pg_proc as p where p.oid = 'private.restore_deletion_safety(uuid)'::regprocedure;

-- Force a competing binding after the precheck to exercise the uniqueness
-- handler and its subtransaction rollback, without a second test session.
create function deletion_review_test.binding_race()
returns trigger language plpgsql set search_path = '' as $$
begin
    insert into private.apple_identity_bindings(account_id,apple_id_hash)
    values (deletion_review_test.id(14),new.apple_id_hash);
    return new;
end;
$$;
create trigger binding_race before insert on private.apple_identity_bindings
for each row when (new.account_id=deletion_review_test.id(13)) execute function deletion_review_test.binding_race();
select deletion_review_test.error('select deletion_review_test.declare_account(13)','account_not_ready','',
    'a concurrent binding uniqueness failure exposes only account_not_ready');
select extensions.ok(not exists(select 1 from private.apple_identity_bindings where account_id=deletion_review_test.id(13)),
    'failed binding race leaves the caller unbound');
select extensions.ok(not exists(select 1 from private.apple_identity_bindings where account_id=deletion_review_test.id(14)),
    'failed binding race rolls back the injected competitor');
drop trigger binding_race on private.apple_identity_bindings;
select private.bind_apple_identity(deletion_review_test.id(13));
update auth.identities set provider_id = 'changed-review-13', identity_data = '{"sub":"changed-review-13"}'
where user_id = deletion_review_test.id(13) and provider = 'apple';
select private.bind_apple_identity(deletion_review_test.id(13));
select extensions.is((select apple_id_hash from private.apple_identity_bindings where account_id = deletion_review_test.id(13)),
    (select hash from review_results where label = 'apple-13'), 'a later identity cannot replace the first bound identity');

insert into private.blocks (blocker_id, blocked_id, block_id, placed_day)
values (deletion_review_test.id(16), deletion_review_test.id(15), deletion_review_test.id(1615), date '2026-10-10');
select extensions.is(deletion_review_test.call(15, 'select public.delete_own_account()'), '{"deleted":true}'::jsonb, 'blocked account transfers its block on self deletion');
select extensions.is(pg_catalog.jsonb_array_length(deletion_review_test.call(16, 'select public.list_blocks()')->'blocks'), 1, 'block remains listed after the blocked account deletes itself');
select extensions.is(deletion_review_test.call(16, 'select public.unblock(deletion_review_test.id(1615))'), '{"unblocked":true}'::jsonb, 'unblock succeeds after the blocked account deletes itself');
select extensions.is(deletion_review_test.call(16, 'select public.list_blocks()'), '{"blocks":[],"truncated":false}'::jsonb, 'unblock removes the retained block from the list');
select extensions.ok(not exists (select 1 from private.deletion_safety_blocks where block_id = deletion_review_test.id(1615)), 'unblock physically removes the retained block');
select extensions.ok(pg_catalog.strpos(s.after_pair, 'from private.deletion_safety_records as r') > 0
    and pg_catalog.strpos(s.after_pair, 'from private.deletion_safety_records as r') < pg_catalog.strpos(s.after_pair, 'delete from private.blocks as b'),
    'unblock rechecks the safety record after waiting on its pair lock')
from pg_catalog.pg_proc as p cross join lateral (
    select pg_catalog.substr(p.prosrc, pg_catalog.strpos(p.prosrc, 'pg_advisory_xact_lock(31003,')) as after_pair
) as s where p.oid = 'private.unblock(uuid)'::regprocedure;

-- Missing preferences and invalid zone names both leave expiry unknown.
insert into private.iana_time_zones(name) values ('Unknown/Zone');
insert into private.report_deliveries(user_id,report_day,status) values
    (deletion_review_test.id(19),date '2026-01-01','closed'),
    (deletion_review_test.id(20),date '2026-01-01','closed');
insert into private.encounters (encounter_id, user_a, user_b, kind, day_a, day_b)
select deletion_review_test.id(8000+n), deletion_review_test.id(n), deletion_review_test.id(20), 'ambient', date '2026-01-01', date '2026-01-01'
from (values (18), (19)) as f(n);
insert into private.encounters (encounter_id, user_a, user_b, kind, day_a, day_b)
values (deletion_review_test.id(8020), deletion_review_test.id(17), deletion_review_test.id(20), 'qr', date '2026-01-01', date '2026-01-01');
insert into private.encounter_views (encounter_id, viewer_id, revealed, reveal_report_day)
select deletion_review_test.id(8000+n), deletion_review_test.id(viewer), true, date '2026-01-01'
from (values (18,18), (18,20), (19,19), (19,20)) as f(n,viewer);
create function deletion_review_test.observe_cleanup_locks()
returns trigger language plpgsql set search_path = '' as $$
begin
    insert into pg_temp.review_results as r (label, value)
    select 'cleanup-locks', pg_catalog.to_jsonb(exists (
        select 1 from pg_catalog.pg_locks as l where l.pid = pg_catalog.pg_backend_pid() and l.granted
          and l.locktype = 'relation' and l.relation = 'private.encounters'::regclass and l.mode = 'RowShareLock'))
    on conflict (label) do update set value = pg_catalog.to_jsonb(r.value::text::boolean and excluded.value::text::boolean);
    return old;
end;
$$;
create trigger observe_retention_locks before delete on private.encounter_views
for each row when (old.encounter_id in (deletion_review_test.id(8018), deletion_review_test.id(8019)))
execute function deletion_review_test.observe_cleanup_locks();
select extensions.lives_ok($q$select private.cleanup_retained_data(timestamptz '2026-10-13 00:00:00+00')$q$,
    'cleanup skips an unusable cached zone without aborting known-zone accounts');
select extensions.ok(exists(select 1 from private.report_deliveries where user_id=deletion_review_test.id(19)),
    'unusable zone leaves delivery expiry unknown');
select extensions.ok(not exists(select 1 from private.report_deliveries where user_id=deletion_review_test.id(20)),
    'known-zone delivery expiry still cleans up independently');
select extensions.ok(exists (select 1 from private.encounter_views where viewer_id = deletion_review_test.id(18)), 'cleanup keeps a view with no viewer zone');
select extensions.ok(exists (select 1 from private.encounter_views where viewer_id = deletion_review_test.id(19)), 'cleanup keeps a view with an unrecognized viewer zone');
select extensions.is((select pg_catalog.count(*) from private.encounter_views where viewer_id = deletion_review_test.id(20)), 0::bigint, 'known-zone peers expire independently');
select extensions.is((select pg_catalog.count(*) from private.encounters where encounter_id in (deletion_review_test.id(8018), deletion_review_test.id(8019))), 2::bigint, 'unknown-zone views retain their shared encounters');
select extensions.ok(pg_catalog.strpos(p.prosrc, 'for update of e skip locked') > 0
    and pg_catalog.strpos(p.prosrc, 'for update of e skip locked') < pg_catalog.strpos(p.prosrc, 'delete from private.encounter_views as v'),
    'cleanup locks encounters before deleting child views')
from pg_catalog.pg_proc as p where p.oid = 'private.cleanup_retained_data(timestamptz)'::regprocedure;
select extensions.is((select value from review_results where label = 'cleanup-locks'), 'true'::jsonb, 'view deletion observes the encounter row-lock relation mode');
insert into private.notification_preferences (user_id, time_zone) values (deletion_review_test.id(18), 'UTC');
update private.notification_preferences set time_zone = 'UTC' where user_id = deletion_review_test.id(19);
select private.cleanup_retained_data(timestamptz '2026-10-13 00:00:00+00');
select extensions.is((select pg_catalog.count(*) from private.encounters where encounter_id in (deletion_review_test.id(8018), deletion_review_test.id(8019))), 0::bigint, 'known expiry permits later removal of the remaining views and encounters');
select extensions.ok(not exists (select 1 from private.encounters where encounter_id = deletion_review_test.id(8020)), 'cleanup also removes an encounter with no views');
drop trigger observe_retention_locks on private.encounter_views;

select * from extensions.finish();
rollback;
