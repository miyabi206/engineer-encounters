begin;

create extension if not exists pgtap with schema extensions;

grant execute on all functions in schema extensions to anon, authenticated;

select extensions.plan(43);

select extensions.ok(exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron'),
    'pg_cron is installed');
select extensions.ok(p.prosecdef, 'cleanup runs as its owner')
from pg_catalog.pg_proc as p where p.oid = 'private.cleanup_expired_data(timestamptz)'::regprocedure;
select extensions.ok('search_path=""' = any(p.proconfig), 'cleanup has an empty search path')
from pg_catalog.pg_proc as p where p.oid = 'private.cleanup_expired_data(timestamptz)'::regprocedure;
select extensions.ok(not exists (
    select 1 from pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) as a
    where a.grantee = 0 and a.privilege_type = 'EXECUTE'
), 'public cannot execute cleanup')
from pg_catalog.pg_proc as p where p.oid = 'private.cleanup_expired_data(timestamptz)'::regprocedure;
select extensions.ok(not pg_catalog.has_function_privilege(r.role_name,
    'private.cleanup_expired_data(timestamptz)', 'execute'), r.role_name || ' cannot execute cleanup')
from (values ('anon'), ('authenticated'), ('service_role')) as r(role_name);

select extensions.is((select pg_catalog.count(*) from cron.job
    where jobname = 'encounters-expiry-cleanup'), 1::bigint, 'the migration leaves one cleanup job');
select extensions.is(j.schedule, '*/15 * * * *', 'cleanup runs every fifteen minutes')
from cron.job as j where j.jobname = 'encounters-expiry-cleanup';
select extensions.is(j.command, 'select private.cleanup_expired_data();', 'cron calls cleanup with the default clock')
from cron.job as j where j.jobname = 'encounters-expiry-cleanup';
select extensions.ok(j.active, 'cleanup job is active')
from cron.job as j where j.jobname = 'encounters-expiry-cleanup';
select extensions.is(j.database, pg_catalog.current_database()::text, 'cleanup targets this database')
from cron.job as j where j.jobname = 'encounters-expiry-cleanup';
select extensions.is(j.username, current_user::text, 'cleanup is scheduled as the migration owner')
from cron.job as j where j.jobname = 'encounters-expiry-cleanup';

-- Repeat the migration's named scheduling operation without relying on files
-- outside this test being mounted in the database test runner.
do $$
begin
    perform cron.schedule('encounters-expiry-cleanup', '*/15 * * * *',
        'select private.cleanup_expired_data();');
    perform cron.schedule('encounters-expiry-cleanup', '*/15 * * * *',
        'select private.cleanup_expired_data();');
end;
$$;
select extensions.is((select pg_catalog.count(*) from cron.job
    where jobname = 'encounters-expiry-cleanup'), 1::bigint, 'scheduling twice still leaves one cleanup job');

insert into auth.users (id, aud, role, email) values
    ('dddddddd-0000-0000-0000-000000000001', 'authenticated', 'authenticated', 'cleanup-one@example.invalid'),
    ('dddddddd-0000-0000-0000-000000000002', 'authenticated', 'authenticated', 'cleanup-two@example.invalid');

-- Expiry just outside grace, at grace, just inside grace, and still live.
insert into private.encounter_candidates (
    nonce_digest, uploader_id, receipt_id, peer_id, protocol_version, role,
    start_own_token_digest, start_peer_token_digest, start_observed_at,
    observed_duration, session_flag, is_final_evidence, first_uploaded_at, expires_at
)
select pg_catalog.decode(pg_catalog.lpad(pg_catalog.to_hex(f.n), 64, '0'), 'hex'),
    'dddddddd-0000-0000-0000-000000000001'::uuid,
    ('dddddddd-0000-0000-0000-' || pg_catalog.lpad(f.n::text, 12, '0'))::uuid,
    'dddddddd-0000-0000-0000-000000000002'::uuid, 1, 'central',
    pg_catalog.decode(pg_catalog.repeat('aa', 32), 'hex'),
    pg_catalog.decode(pg_catalog.repeat('bb', 32), 'hex'),
    extract(epoch from timestamptz '2026-10-11 23:00:00+00')::bigint,
    120, false, true, timestamptz '2026-10-11 23:00:00+00', f.deadline
from (values
    (1, timestamptz '2026-10-11 23:54:59.999999+00'),
    (2, timestamptz '2026-10-11 23:55:00+00'),
    (3, timestamptz '2026-10-11 23:55:00.000001+00'),
    (4, timestamptz '2026-10-12 12:00:00+00')
) as f(n, deadline);

-- Token deadlines are whole seconds aligned to their 900-second windows.
insert into private.temporary_tokens (token_digest, user_id, batch_id, valid_from, valid_until, delete_after)
select pg_catalog.decode(pg_catalog.lpad(pg_catalog.to_hex(f.n + 100), 64, '0'), 'hex'),
    'dddddddd-0000-0000-0000-000000000001'::uuid,
    'dddddddd-0000-0000-0000-000000000001'::uuid,
    f.deadline - 173700, f.deadline - 172800, f.deadline
from (select n, extract(epoch from timestamptz '2026-10-12 00:00:00+00')::bigint + (n - 2) * 900 as deadline
    from pg_catalog.generate_series(1, 3) as g(n)) as f;

insert into private.consumed_nonces (exchange_digest, delete_after)
select pg_catalog.decode(pg_catalog.lpad(pg_catalog.to_hex(f.n + 200), 64, '0'), 'hex'), f.deadline
from (values (1, date '2026-10-11'), (2, date '2026-10-12'), (3, date '2026-10-13')) as f(n, deadline);

insert into private.account_limit_events (user_id, bucket, occurred_at)
select 'dddddddd-0000-0000-0000-000000000001'::uuid, f.bucket, f.event_time
from (values
    ('cleanup-old', timestamptz '2026-10-11 22:59:59.999999+00'),
    ('cleanup-boundary', timestamptz '2026-10-11 23:00:00+00'),
    ('cleanup-recent', timestamptz '2026-10-11 23:00:00.000001+00'),
    ('cleanup-live', timestamptz '2026-10-12 00:00:00+00')
) as f(bucket, event_time);

-- The registration bucket needs its full daily span, including events older
-- than the hourly retention applied to all other buckets.
insert into private.account_limit_events (user_id, bucket, occurred_at)
select 'dddddddd-0000-0000-0000-000000000001'::uuid, 'register_time_zone', f.event_time
from (values
    (timestamptz '2026-10-10 23:59:59.999999+00'),
    (timestamptz '2026-10-11 00:00:00+00'),
    (timestamptz '2026-10-11 00:00:00.000001+00'),
    (timestamptz '2026-10-11 12:00:00+00')
) as f(event_time);

-- This zone is on the previous calendar date at the UTC deadline.
set local time zone 'America/Los_Angeles';
select private.cleanup_expired_data(timestamptz '2026-10-11 23:59:59.999999+00');
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates
    where uploader_id = 'dddddddd-0000-0000-0000-000000000001'), 4::bigint,
    'candidates survive through exactly 300 seconds after expiry');
select extensions.ok(exists (select 1 from private.temporary_tokens
    where token_digest = pg_catalog.decode(pg_catalog.lpad('66', 64, '0'), 'hex')),
    'token survives one microsecond before its deadline');
select extensions.ok(exists (select 1 from private.consumed_nonces where exchange_digest =
    pg_catalog.decode(pg_catalog.lpad('ca', 64, '0'), 'hex')), 'tombstone survives until UTC midnight');
select extensions.ok(exists (select 1 from private.account_limit_events where bucket = 'cleanup-old'
    and user_id = 'dddddddd-0000-0000-0000-000000000001'), 'limiter survives at exactly one hour');
select extensions.ok(exists (select 1 from private.account_limit_events
    where user_id = 'dddddddd-0000-0000-0000-000000000001' and bucket = 'register_time_zone'
      and occurred_at = timestamptz '2026-10-10 23:59:59.999999+00'), 'registration event survives at exactly one day');

select private.cleanup_expired_data(timestamptz '2026-10-12 00:00:00+00');
select extensions.ok(not exists (select 1 from private.encounter_candidates where nonce_digest =
    pg_catalog.decode(pg_catalog.lpad('1', 64, '0'), 'hex')
    and uploader_id = 'dddddddd-0000-0000-0000-000000000001'), 'candidate more than 300 seconds expired is deleted');
select extensions.ok(exists (select 1 from private.encounter_candidates where nonce_digest =
    pg_catalog.decode(pg_catalog.lpad('2', 64, '0'), 'hex')
    and uploader_id = 'dddddddd-0000-0000-0000-000000000001'), 'candidate at the 300-second boundary survives');
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates
    where uploader_id = 'dddddddd-0000-0000-0000-000000000001' and nonce_digest in (
        pg_catalog.decode(pg_catalog.lpad('3', 64, '0'), 'hex'),
        pg_catalog.decode(pg_catalog.lpad('4', 64, '0'), 'hex'))), 2::bigint, 'inside-grace and live candidates survive');
select extensions.is((select pg_catalog.count(*) from private.temporary_tokens
    where user_id = 'dddddddd-0000-0000-0000-000000000001' and token_digest in (
        pg_catalog.decode(pg_catalog.lpad('65', 64, '0'), 'hex'),
        pg_catalog.decode(pg_catalog.lpad('66', 64, '0'), 'hex'))), 0::bigint, 'past-deadline and boundary tokens are deleted');
select extensions.ok(exists (select 1 from private.temporary_tokens where token_digest =
    pg_catalog.decode(pg_catalog.lpad('67', 64, '0'), 'hex')), 'live token survives');
select extensions.is((select pg_catalog.count(*) from private.consumed_nonces where exchange_digest in (
    pg_catalog.decode(pg_catalog.lpad('c9', 64, '0'), 'hex'),
    pg_catalog.decode(pg_catalog.lpad('ca', 64, '0'), 'hex'))), 0::bigint, 'past and boundary UTC tombstones are deleted');
select extensions.ok(exists (select 1 from private.consumed_nonces where exchange_digest =
    pg_catalog.decode(pg_catalog.lpad('cb', 64, '0'), 'hex')), 'live tombstone survives');
select extensions.ok(not exists (select 1 from private.account_limit_events where bucket = 'cleanup-old'
    and user_id = 'dddddddd-0000-0000-0000-000000000001'), 'limiter older than an hour is deleted');
select extensions.ok(exists (select 1 from private.account_limit_events where bucket = 'cleanup-boundary'
    and user_id = 'dddddddd-0000-0000-0000-000000000001'), 'limiter at exactly an hour survives');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events
    where user_id = 'dddddddd-0000-0000-0000-000000000001' and bucket in ('cleanup-recent', 'cleanup-live')),
    2::bigint, 'recent limiter events survive');
select extensions.ok(not exists (select 1 from private.account_limit_events
    where user_id = 'dddddddd-0000-0000-0000-000000000001' and bucket = 'register_time_zone'
      and occurred_at = timestamptz '2026-10-10 23:59:59.999999+00'), 'registration event older than one day is deleted');
select extensions.ok(exists (select 1 from private.account_limit_events
    where user_id = 'dddddddd-0000-0000-0000-000000000001' and bucket = 'register_time_zone'
      and occurred_at = timestamptz '2026-10-11 00:00:00+00'), 'registration event at the one-day boundary survives');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events
    where user_id = 'dddddddd-0000-0000-0000-000000000001' and bucket = 'register_time_zone'
      and occurred_at in (timestamptz '2026-10-11 00:00:00.000001+00', timestamptz '2026-10-11 12:00:00+00')),
    2::bigint, 'registration events inside the daily span survive');
select extensions.ok(exists (select 1 from private.account_limit_events
    where user_id = 'dddddddd-0000-0000-0000-000000000001' and bucket = 'register_time_zone'
      and occurred_at = timestamptz '2026-10-11 12:00:00+00'), 'registration event older than one hour but younger than one day survives cleanup');

select private.cleanup_expired_data(timestamptz '2026-10-12 00:00:00.000001+00');
select extensions.ok(not exists (select 1 from private.encounter_candidates where nonce_digest =
    pg_catalog.decode(pg_catalog.lpad('2', 64, '0'), 'hex')
    and uploader_id = 'dddddddd-0000-0000-0000-000000000001'), 'candidate is deleted immediately beyond grace');
select extensions.ok(not exists (select 1 from private.account_limit_events where bucket = 'cleanup-boundary'
    and user_id = 'dddddddd-0000-0000-0000-000000000001'), 'limiter is deleted immediately beyond one hour');
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates
    where uploader_id = 'dddddddd-0000-0000-0000-000000000001'), 2::bigint, 'remaining candidates survive another cleanup');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events
    where user_id = 'dddddddd-0000-0000-0000-000000000001'), 4::bigint, 'remaining hourly and daily limiter events survive another cleanup');
select extensions.ok(not exists (select 1 from private.account_limit_events
    where user_id = 'dddddddd-0000-0000-0000-000000000001' and bucket = 'register_time_zone'
      and occurred_at = timestamptz '2026-10-11 00:00:00+00'), 'registration event is deleted immediately beyond one day');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events
    where user_id = 'dddddddd-0000-0000-0000-000000000001' and bucket = 'register_time_zone'),
    2::bigint, 'remaining registration events survive another cleanup');

-- Repeating the same cleanup must be harmless.
select private.cleanup_expired_data(timestamptz '2026-10-12 00:00:00.000001+00');
select extensions.is((select pg_catalog.count(*) from private.temporary_tokens
    where user_id = 'dddddddd-0000-0000-0000-000000000001'), 1::bigint, 'repeated cleanup retains the live token');

-- Real registrations retain their daily budget across the default cleanup call.
set local "request.jwt.claim.sub" = '';
set local "request.jwt.claims" = '{"sub":"dddddddd-0000-0000-0000-000000000002","role":"authenticated"}';
set local role authenticated;
select public.accept_declarations(true, 'draft', 'draft');
do $$
begin
    for registration_number in 1..10 loop
        perform public.register_time_zone('UTC');
    end loop;
end;
$$;
reset role;
update private.account_limit_events set occurred_at = pg_catalog.now() - interval '2 hours'
where user_id = 'dddddddd-0000-0000-0000-000000000002' and bucket = 'register_time_zone';
select extensions.is((select pg_catalog.count(*) from private.account_limit_events
    where user_id = 'dddddddd-0000-0000-0000-000000000002' and bucket = 'register_time_zone'),
    10::bigint, 'ten real registrations have spent the daily budget');
select private.cleanup_expired_data();
select extensions.is((select pg_catalog.count(*) from private.account_limit_events
    where user_id = 'dddddddd-0000-0000-0000-000000000002' and bucket = 'register_time_zone'),
    10::bigint, 'cleanup preserves all two-hour-old registration events');
set local role authenticated;
select extensions.throws_ok('select public.register_time_zone(''Asia/Tokyo'')', 'P0001', 'rate_limited',
    'cleanup cannot allow an eleventh registration in the day');
reset role;

select * from extensions.finish();
rollback;
