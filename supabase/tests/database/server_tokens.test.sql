begin;

create extension if not exists pgtap with schema extensions;

create schema server_tokens_test;
grant usage on schema server_tokens_test to anon, authenticated;

create table server_tokens_test.tables (name text primary key);
insert into server_tokens_test.tables values ('temporary_tokens'), ('account_limit_events');

create table server_tokens_test.clock (
    current_window bigint not null,
    horizon bigint not null,
    server_seconds numeric not null
);
insert into server_tokens_test.clock
select (pg_catalog.floor(extract(epoch from pg_catalog.now()) / 900) * 900)::bigint,
       (pg_catalog.ceil((extract(epoch from pg_catalog.now()) + 43200) / 900) * 900)::bigint,
       extract(epoch from pg_catalog.now());

-- Capture only digests and validation flags. Raw results stay in local variables
-- and never reach tables or pgTAP diagnostics, even when an assertion fails.
create table server_tokens_test.batches (
    label text primary key,
    batch_id uuid not null,
    window_count integer not null,
    keys_ok boolean not null,
    token_format_ok boolean not null,
    unique_tokens boolean not null,
    integer_times boolean not null,
    ordered_windows boolean not null
);
create table server_tokens_test.windows (
    label text not null references server_tokens_test.batches (label),
    ordinal bigint not null,
    token_digest bytea not null,
    valid_from bigint not null,
    valid_until bigint not null,
    primary key (label, ordinal)
);

grant select on all tables in schema server_tokens_test to anon, authenticated;
grant insert on server_tokens_test.batches, server_tokens_test.windows to authenticated;

create function server_tokens_test.capture(label text, covered_until bigint default null)
returns void
language plpgsql
set search_path = ''
as $$
declare
    result jsonb := public.issue_token_batch(covered_until);
begin
    insert into server_tokens_test.batches
    select label, (result->>'batch_id')::uuid, pg_catalog.jsonb_array_length(result->'windows'),
        (select pg_catalog.array_agg(k order by k) = array['batch_id', 'windows']
         from pg_catalog.jsonb_object_keys(result) as k)
        and pg_catalog.jsonb_typeof(result->'batch_id') = 'string'
        and pg_catalog.jsonb_typeof(result->'windows') = 'array'
        and coalesce((select pg_catalog.bool_and(
            (select pg_catalog.array_agg(k order by k) = array['token', 'valid_from', 'valid_until']
             from pg_catalog.jsonb_object_keys(w) as k)
        ) from pg_catalog.jsonb_array_elements(result->'windows') as w), true),
        coalesce((select pg_catalog.bool_and(pg_catalog.jsonb_typeof(w->'token') = 'string'
            and w->>'token' ~ '^[0-9a-f]{32}$')
            from pg_catalog.jsonb_array_elements(result->'windows') as w), true),
        (select pg_catalog.count(distinct w->>'token') = pg_catalog.count(*)
         from pg_catalog.jsonb_array_elements(result->'windows') as w),
        coalesce((select pg_catalog.bool_and(
            pg_catalog.jsonb_typeof(w->'valid_from') = 'number' and w->>'valid_from' ~ '^-?[0-9]+$'
            and pg_catalog.jsonb_typeof(w->'valid_until') = 'number' and w->>'valid_until' ~ '^-?[0-9]+$'
        ) from pg_catalog.jsonb_array_elements(result->'windows') as w), true),
        coalesce((select pg_catalog.bool_and(previous_end is null or previous_end = valid_from)
            from (
                select (w->>'valid_from')::bigint as valid_from,
                    pg_catalog.lag((w->>'valid_until')::bigint) over (order by ordinal) as previous_end
                from pg_catalog.jsonb_array_elements(result->'windows') with ordinality as j(w, ordinal)
            ) as ordered), true);

    insert into server_tokens_test.windows (label, ordinal, token_digest, valid_from, valid_until)
    select label, ordinal, pg_catalog.sha256(pg_catalog.decode(w->>'token', 'hex')),
           (w->>'valid_from')::bigint, (w->>'valid_until')::bigint
    from pg_catalog.jsonb_array_elements(result->'windows') with ordinality as j(w, ordinal);
end;
$$;

create function server_tokens_test.expect_error(statement text, code text, fields text, description text)
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

select extensions.plan(142);

-- Catalog and grants: 32 assertions.
select extensions.ok(c.relrowsecurity, t.name || ' has RLS enabled')
from server_tokens_test.tables as t
join pg_catalog.pg_class as c on c.oid = ('private.' || t.name)::regclass;
select extensions.is((select pg_catalog.count(*) from pg_catalog.pg_policy as p
    where p.polrelid = ('private.' || t.name)::regclass), 0::bigint, t.name || ' has no policies')
from server_tokens_test.tables as t;
select extensions.ok(not pg_catalog.has_table_privilege(r.name, 'private.' || t.name,
    'select, insert, update, delete, truncate, references, trigger, maintain'), r.name || ' has no grants on ' || t.name)
from server_tokens_test.tables as t cross join (values ('anon'), ('authenticated')) as r(name);
select extensions.ok(not exists (
    select 1 from pg_catalog.aclexplode(coalesce(c.relacl, pg_catalog.acldefault('r', c.relowner))) as a
    where a.grantee = 0
), t.name || ' has no public grants')
from server_tokens_test.tables as t
join pg_catalog.pg_class as c on c.oid = ('private.' || t.name)::regclass;
select extensions.ok(not pg_catalog.has_schema_privilege(r.name, 'private', 'usage, create'),
    r.name || ' cannot access the private schema')
from (values ('anon'), ('authenticated')) as r(name);
select extensions.ok(not pg_catalog.has_function_privilege(r.name,
    'private.record_account_event(uuid,text,integer,interval)', 'execute'), r.name || ' cannot execute the limiter helper')
from (values ('anon'), ('authenticated')) as r(name);
select extensions.ok(not exists (
    select 1 from pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) as a
    where a.grantee = 0 and a.privilege_type = 'EXECUTE'
), 'the limiter helper has no public execute grant')
from pg_catalog.pg_proc as p where p.oid = 'private.record_account_event(uuid,text,integer,interval)'::regprocedure;
select extensions.ok('search_path=""' = any(p.proconfig), 'the limiter helper has an empty search path')
from pg_catalog.pg_proc as p where p.oid = 'private.record_account_event(uuid,text,integer,interval)'::regprocedure;
select extensions.ok(p.prosecdef, 'token issue is security definer')
from pg_catalog.pg_proc as p where p.oid = 'public.issue_token_batch(bigint)'::regprocedure;
select extensions.ok('search_path=""' = any(p.proconfig), 'token issue has an empty search path')
from pg_catalog.pg_proc as p where p.oid = 'public.issue_token_batch(bigint)'::regprocedure;
select extensions.is(p.proargnames, array['covered_until'], 'token issue exposes only covered_until')
from pg_catalog.pg_proc as p where p.oid = 'public.issue_token_batch(bigint)'::regprocedure;
select extensions.is(pg_catalog.pg_get_expr(p.proargdefaults, 0), 'NULL::bigint', 'covered_until defaults to null')
from pg_catalog.pg_proc as p where p.oid = 'public.issue_token_batch(bigint)'::regprocedure;
select extensions.is(pg_catalog.format_type(p.prorettype, null), 'jsonb', 'token issue returns jsonb')
from pg_catalog.pg_proc as p where p.oid = 'public.issue_token_batch(bigint)'::regprocedure;
select extensions.ok(pg_catalog.has_function_privilege('authenticated', 'public.issue_token_batch(bigint)', 'execute'),
    'authenticated can execute token issue');
select extensions.ok(not pg_catalog.has_function_privilege('anon', 'public.issue_token_batch(bigint)', 'execute'),
    'anon cannot execute token issue');
select extensions.ok(not exists (
    select 1 from pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) as a
    where a.grantee = 0 and a.privilege_type = 'EXECUTE'
), 'public cannot execute token issue')
from pg_catalog.pg_proc as p where p.oid = 'public.issue_token_batch(bigint)'::regprocedure;
select extensions.ok(i.indisvalid and i.indisready, v.name || ' is a usable lookup index')
from (values ('temporary_tokens_owner_window_idx'), ('temporary_tokens_valid_until_idx'),
    ('temporary_tokens_delete_after_idx'), ('account_limit_events_owner_bucket_time_idx'),
    ('account_limit_events_occurred_at_idx')) as v(name)
join pg_catalog.pg_index as i on i.indexrelid = ('private.' || v.name)::regclass;
select extensions.is((select pg_catalog.array_agg(a.attname::text order by a.attnum)
    from pg_catalog.pg_attribute as a where a.attrelid = 'private.temporary_tokens'::regclass
    and a.attnum > 0 and not a.attisdropped),
    array['token_digest', 'user_id', 'batch_id', 'valid_from', 'valid_until', 'delete_after'],
    'token storage has exactly the digest and permitted metadata columns');
select extensions.is((select pg_catalog.pg_get_constraintdef(c.oid) from pg_catalog.pg_constraint as c
    where c.conrelid = 'private.temporary_tokens'::regclass and c.contype = 'p'),
    'PRIMARY KEY (token_digest)', 'the digest is the token primary key');
select extensions.is(pg_catalog.format_type(p.prorettype, null), 'boolean', 'the limiter returns whether the limit is exceeded')
from pg_catalog.pg_proc as p where p.oid = 'private.record_account_event(uuid,text,integer,interval)'::regprocedure;

-- Exercise actual role checks: 23 assertions.
set local "request.jwt.claim.sub" = '';
set local "request.jwt.claims" = '{}';
set local role anon;
select extensions.throws_ok('select public.issue_token_batch()', '42501',
    'permission denied for function issue_token_batch', 'anon execution is refused');
select extensions.throws_ok('select private.record_account_event(null, ''test'', 1, interval ''1 minute'')',
    '42501', 'permission denied for schema private', 'anon cannot call the helper');
select extensions.throws_ok(pg_catalog.format(s.command, t.name), '42501', 'permission denied for schema private',
    'anon cannot ' || s.operation || ' ' || t.name)
from server_tokens_test.tables as t cross join (values
    ('read', 'select * from private.%I'), ('insert', 'insert into private.%I default values'),
    ('update', 'update private.%I set user_id = user_id'), ('delete', 'delete from private.%I'),
    ('truncate', 'truncate private.%I')
) as s(operation, command);
reset role;
set local role authenticated;
select extensions.throws_ok('select private.record_account_event(null, ''test'', 1, interval ''1 minute'')',
    '42501', 'permission denied for schema private', 'authenticated cannot call the helper directly');
select extensions.throws_ok(pg_catalog.format(s.command, t.name), '42501', 'permission denied for schema private',
    'authenticated cannot ' || s.operation || ' ' || t.name)
from server_tokens_test.tables as t cross join (values
    ('read', 'select * from private.%I'), ('insert', 'insert into private.%I default values'),
    ('update', 'update private.%I set user_id = user_id'), ('delete', 'delete from private.%I'),
    ('truncate', 'truncate private.%I')
) as s(operation, command);

-- Authentication and every readiness predicate: 12 assertions.
select server_tokens_test.expect_error('select public.issue_token_batch()', 'not_authenticated', '', 'a missing caller is refused');
set local "request.jwt.claims" = '{"sub":"aaaaaaaa-0000-0000-0000-000000000099","role":"authenticated"}';
select server_tokens_test.expect_error('select public.issue_token_batch()', 'not_authenticated', '', 'a deleted or unknown caller is refused');
reset role;
insert into auth.users (id) values
    ('aaaaaaaa-0000-0000-0000-000000000001'), ('aaaaaaaa-0000-0000-0000-000000000002'),
    ('aaaaaaaa-0000-0000-0000-000000000003'), ('aaaaaaaa-0000-0000-0000-000000000004');
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"aaaaaaaa-0000-0000-0000-000000000001","role":"authenticated"}';
select server_tokens_test.expect_error('select public.issue_token_batch()', 'account_not_ready', '', 'no profile is not ready');
select public.accept_declarations(true, 'draft', 'draft');
select server_tokens_test.expect_error('select public.issue_token_batch()', 'account_not_ready', '', 'no registered zone is not ready');
reset role;
insert into private.notification_preferences (user_id, time_zone) values ('aaaaaaaa-0000-0000-0000-000000000001', 'invalid/zone');
set local role authenticated;
select server_tokens_test.expect_error('select public.issue_token_batch()', 'account_not_ready', '', 'an invalid stored zone is not ready');
select public.register_time_zone('UTC');
reset role;
update private.profiles set moderation_state = 'hidden' where user_id = 'aaaaaaaa-0000-0000-0000-000000000001';
set local role authenticated;
select server_tokens_test.expect_error('select public.issue_token_batch()', 'account_not_ready', '', 'hidden accounts are not ready');
reset role;
update private.profiles set moderation_state = 'suspended' where user_id = 'aaaaaaaa-0000-0000-0000-000000000001';
set local role authenticated;
select server_tokens_test.expect_error('select public.issue_token_batch()', 'account_not_ready', '', 'suspended accounts are not ready');
reset role;
-- These values cannot be written through the API or normally stored. Remove
-- checks only within this rolled-back test to exercise defensive readiness.
alter table private.profiles drop constraint profiles_age_18_declared_check;
alter table private.profiles drop constraint profiles_terms_version_check;
alter table private.profiles drop constraint profiles_privacy_version_check;
update private.profiles set moderation_state = 'active', age_18_declared = false
where user_id = 'aaaaaaaa-0000-0000-0000-000000000001';
set local role authenticated;
select server_tokens_test.expect_error('select public.issue_token_batch()', 'account_not_ready', '', 'a false age declaration is not ready');
reset role;
update private.profiles set age_18_declared = true, terms_version = ' '
where user_id = 'aaaaaaaa-0000-0000-0000-000000000001';
set local role authenticated;
select server_tokens_test.expect_error('select public.issue_token_batch()', 'account_not_ready', '', 'empty terms acceptance is not ready');
reset role;
update private.profiles set terms_version = 'draft', privacy_version = ' '
where user_id = 'aaaaaaaa-0000-0000-0000-000000000001';
set local role authenticated;
select server_tokens_test.expect_error('select public.issue_token_batch()', 'account_not_ready', '', 'empty privacy acceptance is not ready');
reset role;
update private.profiles set privacy_version = 'draft' where user_id = 'aaaaaaaa-0000-0000-0000-000000000001';
alter table private.profiles add constraint profiles_age_18_declared_check check (age_18_declared);
alter table private.profiles add constraint profiles_terms_version_check check (pg_catalog.btrim(terms_version) <> '' and pg_catalog.char_length(terms_version) <= 32);
alter table private.profiles add constraint profiles_privacy_version_check check (pg_catalog.btrim(privacy_version) <> '' and pg_catalog.char_length(privacy_version) <= 32);
select extensions.is((select pg_catalog.count(*) from private.account_limit_events
    where user_id = 'aaaaaaaa-0000-0000-0000-000000000001'), 0::bigint, 'readiness errors record no limiter events');
select extensions.is((select pg_catalog.count(*) from private.temporary_tokens
    where user_id = 'aaaaaaaa-0000-0000-0000-000000000001'), 0::bigint, 'readiness errors store no tokens');

-- Scratch batch, wire shape, cryptography and retention: 18 assertions.
set local role authenticated;
select server_tokens_test.capture('scratch');
reset role;
select extensions.ok((select batch_id is not null from server_tokens_test.batches where label = 'scratch'), 'a scratch batch has a UUID');
select extensions.is((select window_count::bigint from server_tokens_test.batches where label = 'scratch'),
    (select (horizon - current_window) / 900 from server_tokens_test.clock), 'scratch has exactly the horizon window count');
select extensions.is((select valid_from from server_tokens_test.windows where label = 'scratch' and ordinal = 1),
    (select current_window from server_tokens_test.clock), 'scratch starts in the window containing server time');
select extensions.is((select pg_catalog.max(valid_until) from server_tokens_test.windows where label = 'scratch'),
    (select horizon from server_tokens_test.clock), 'scratch ends at the first boundary at or after twelve hours');
select extensions.ok((select pg_catalog.bool_and(valid_until - valid_from = 900) from server_tokens_test.windows where label = 'scratch'), 'every window lasts 900 seconds');
select extensions.ok((select pg_catalog.bool_and(valid_from % 900 = 0 and valid_until % 900 = 0)
    from server_tokens_test.windows where label = 'scratch'), 'every boundary is aligned to Unix quarter hours');
select extensions.ok((select w.valid_from <= c.server_seconds and c.server_seconds < w.valid_until
    from server_tokens_test.windows as w cross join server_tokens_test.clock as c where w.label = 'scratch' and w.ordinal = 1),
    'the first window includes transaction time');
select extensions.ok((select keys_ok from server_tokens_test.batches where label = 'scratch'), 'the batch and window objects have exactly the contract keys');
select extensions.ok((select token_format_ok from server_tokens_test.batches where label = 'scratch'), 'tokens are sixteen bytes encoded as 32 lowercase hex characters');
select extensions.ok((select unique_tokens from server_tokens_test.batches where label = 'scratch'), 'each window has a distinct token');
select extensions.ok((select integer_times from server_tokens_test.batches where label = 'scratch'), 'wire times are JSON integer numbers');
select extensions.ok((select ordered_windows from server_tokens_test.batches where label = 'scratch'), 'windows are ordered and contiguous');
select extensions.is((select pg_catalog.count(*) from server_tokens_test.windows as w
    join private.temporary_tokens as t on t.token_digest = w.token_digest
    where w.label = 'scratch' and t.valid_from = w.valid_from and t.valid_until = w.valid_until),
    (select window_count::bigint from server_tokens_test.batches where label = 'scratch'), 'every stored digest equals SHA-256 of the returned bytes');
select extensions.ok((select pg_catalog.bool_and(pg_catalog.octet_length(t.token_digest) = 32)
    from private.temporary_tokens as t join server_tokens_test.windows as w using (token_digest) where w.label = 'scratch'),
    'storage contains full 32-byte digests, never raw 16-byte tokens');
select extensions.ok((select pg_catalog.bool_and(t.delete_after = w.valid_until + 172800)
    from private.temporary_tokens as t join server_tokens_test.windows as w using (token_digest) where w.label = 'scratch'),
    'digest retention ends exactly 48 hours after the window');
select extensions.ok((select pg_catalog.bool_and(t.batch_id = b.batch_id)
    from private.temporary_tokens as t join server_tokens_test.windows as w using (token_digest)
    join server_tokens_test.batches as b using (label) where w.label = 'scratch'), 'the returned batch ID labels all stored tokens');
select extensions.ok((select pg_catalog.bool_and(t.user_id = 'aaaaaaaa-0000-0000-0000-000000000001'::uuid)
    from private.temporary_tokens as t join server_tokens_test.windows as w using (token_digest) where w.label = 'scratch'),
    'tokens belong to the authenticated caller despite discovery off and an empty profile');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events
    where user_id = 'aaaaaaaa-0000-0000-0000-000000000001' and bucket = 'issue_token_batch'), 1::bigint, 'scratch issue records one event');

-- Null, past, invalid, future and already-covered requests: 24 assertions.
set local role authenticated;
select server_tokens_test.capture('null', null);
select server_tokens_test.capture('past', (select current_window - 900 from server_tokens_test.clock));
reset role;
select extensions.is((select valid_from from server_tokens_test.windows where label = b.label and ordinal = 1),
    (select current_window from server_tokens_test.clock), b.label || ' starts in the current window')
from (values ('null'), ('past')) as b(label);
select extensions.is((select window_count::bigint from server_tokens_test.batches where label = b.label),
    (select (horizon - current_window) / 900 from server_tokens_test.clock), b.label || ' returns the full window count')
from (values ('null'), ('past')) as b(label);
select extensions.is((select pg_catalog.max(valid_until) from server_tokens_test.windows where label = b.label),
    (select horizon from server_tokens_test.clock), b.label || ' ends at the horizon')
from (values ('null'), ('past')) as b(label);
set local role authenticated;
select server_tokens_test.expect_error(pg_catalog.format('select public.issue_token_batch(%s)', v.value),
    'invalid_input', 'covered_until', 'nonaligned coverage is refused ' || v.description)
from server_tokens_test.clock as c cross join lateral (values
    (c.current_window - 1, 'in the past'), (c.current_window + 1, 'in the future'), (c.horizon + 1, 'beyond the horizon')
) as v(value, description);
reset role;
select extensions.is((select pg_catalog.count(*) from private.account_limit_events
    where user_id = 'aaaaaaaa-0000-0000-0000-000000000001'), 3::bigint, 'invalid coverage records no events');
select extensions.is((select pg_catalog.count(*) from private.temporary_tokens
    where user_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
    (select 3 * (horizon - current_window) / 900 from server_tokens_test.clock), 'invalid coverage stores no tokens');
set local role authenticated;
select server_tokens_test.capture('future', (select current_window + 900 from server_tokens_test.clock));
reset role;
select extensions.is((select valid_from from server_tokens_test.windows where label = 'future' and ordinal = 1),
    (select current_window + 900 from server_tokens_test.clock), 'future coverage starts at that boundary');
select extensions.is((select pg_catalog.max(valid_until) from server_tokens_test.windows where label = 'future'),
    (select horizon from server_tokens_test.clock), 'future coverage keeps the server horizon');
select extensions.is((select window_count::bigint from server_tokens_test.batches where label = 'future'),
    (select (horizon - current_window) / 900 - 1 from server_tokens_test.clock), 'future coverage omits the covered window');
select extensions.is((select pg_catalog.count(*) from private.temporary_tokens as t cross join server_tokens_test.clock as c
    where t.user_id = 'aaaaaaaa-0000-0000-0000-000000000001' and t.valid_from = c.current_window), 3::bigint,
    'replenishment does not reissue the covered window');
set local role authenticated;
select server_tokens_test.expect_error('select public.issue_token_batch()', 'rate_limited', '', 'a fifth token in a later window refuses the entire batch');
reset role;
select extensions.is((select pg_catalog.count(*) from private.temporary_tokens
    where user_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
    (select 4 * (horizon - current_window) / 900 - 1 from server_tokens_test.clock), 'a refused batch leaves all windows unchanged');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events
    where user_id = 'aaaaaaaa-0000-0000-0000-000000000001'), 4::bigint, 'a refused token batch rolls back its event');
select extensions.is((select pg_catalog.count(*) from private.temporary_tokens as t cross join server_tokens_test.clock as c
    where t.user_id = 'aaaaaaaa-0000-0000-0000-000000000001' and t.valid_from = c.current_window), 3::bigint,
    'no fourth token is partially issued in the available first window');
set local role authenticated;
select server_tokens_test.capture('horizon', (select horizon from server_tokens_test.clock));
select server_tokens_test.capture('beyond', (select horizon + 900 from server_tokens_test.clock));
reset role;
select extensions.is((select window_count from server_tokens_test.batches where label = b.label), 0, b.label || ' returns an empty windows array')
from (values ('horizon'), ('beyond')) as b(label);
select extensions.is((select pg_catalog.count(distinct batch_id) from server_tokens_test.batches
    where label in ('scratch', 'null', 'past', 'future', 'horizon', 'beyond')), 6::bigint, 'every call has a fresh batch ID, including empty batches');
select extensions.is((select pg_catalog.count(*) from private.temporary_tokens
    where user_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
    (select 4 * (horizon - current_window) / 900 - 1 from server_tokens_test.clock), 'already covered requests store no tokens');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events
    where user_id = 'aaaaaaaa-0000-0000-0000-000000000001'), 6::bigint, 'already covered calls still count toward the hourly limit');

-- Independent accounts and exactly four tokens per window: 6 assertions.
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"aaaaaaaa-0000-0000-0000-000000000002","role":"authenticated"}';
select public.accept_declarations(true, 'draft', 'draft');
select public.register_time_zone('Asia/Tokyo');
do $$
begin
    for n in 1..4 loop
        perform server_tokens_test.capture('account-b-' || n);
    end loop;
end;
$$;
reset role;
select extensions.ok((select pg_catalog.bool_and(t.user_id = 'aaaaaaaa-0000-0000-0000-000000000002'::uuid)
    from private.temporary_tokens as t join server_tokens_test.windows as w using (token_digest) where w.label = 'account-b-1'),
    'a different caller receives only its own tokens even when the first caller is capped');
select extensions.ok((select pg_catalog.bool_and(n = 4) from (
    select pg_catalog.count(*) as n from private.temporary_tokens
    where user_id = 'aaaaaaaa-0000-0000-0000-000000000002' group by valid_from
) as counts), 'exactly four unexpired tokens per window are allowed');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events
    where user_id = 'aaaaaaaa-0000-0000-0000-000000000002'), 4::bigint, 'the fourth full batch succeeds');
set local role authenticated;
select server_tokens_test.expect_error('select public.issue_token_batch()', 'rate_limited', '', 'a fifth full batch exceeds the window limit');
reset role;
select extensions.is((select pg_catalog.count(*) from private.temporary_tokens
    where user_id = 'aaaaaaaa-0000-0000-0000-000000000002'),
    (select 4 * (horizon - current_window) / 900 from server_tokens_test.clock), 'the fifth batch stores nothing');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events
    where user_id = 'aaaaaaaa-0000-0000-0000-000000000002'), 4::bigint, 'the fifth batch leaves the successful call count unchanged');

-- Expired windows and the hourly boundary: 9 assertions.
insert into private.temporary_tokens (token_digest, user_id, batch_id, valid_from, valid_until, delete_after)
select pg_catalog.sha256(pg_catalog.convert_to('expired-fixture-' || n, 'UTF8')),
    'aaaaaaaa-0000-0000-0000-000000000003', pg_catalog.gen_random_uuid(),
    c.current_window - 900, c.current_window, c.current_window + 172800
from server_tokens_test.clock as c cross join pg_catalog.generate_series(1, 4) as n;
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"aaaaaaaa-0000-0000-0000-000000000003","role":"authenticated"}';
select public.accept_declarations(true, 'draft', 'draft');
select public.register_time_zone('UTC');
select server_tokens_test.capture('expired-ignored', (select current_window - 900 from server_tokens_test.clock));
reset role;
select extensions.is((select valid_from from server_tokens_test.windows where label = 'expired-ignored' and ordinal = 1),
    (select current_window from server_tokens_test.clock), 'expired coverage starts at the current window');
select extensions.is((select window_count::bigint from server_tokens_test.batches where label = 'expired-ignored'),
    (select (horizon - current_window) / 900 from server_tokens_test.clock), 'expired tokens and other owners at the cap do not block issue');
select extensions.is((select pg_catalog.count(*) from private.temporary_tokens as t cross join server_tokens_test.clock as c
    where t.user_id = 'aaaaaaaa-0000-0000-0000-000000000003' and t.valid_until <= c.server_seconds),
    4::bigint, 'expired digests remain available until their deletion deadline');
set local role authenticated;
do $$
declare
    horizon bigint := (select c.horizon from server_tokens_test.clock as c);
begin
    for n in 2..19 loop
        perform server_tokens_test.capture('hour-' || n, horizon);
    end loop;
end;
$$;
reset role;
select extensions.is((select pg_catalog.count(*) from private.account_limit_events
    where user_id = 'aaaaaaaa-0000-0000-0000-000000000003'), 19::bigint, 'nineteen hourly calls succeed');
set local role authenticated;
select server_tokens_test.capture('hour-20', (select horizon from server_tokens_test.clock));
reset role;
select extensions.is((select pg_catalog.count(*) from private.account_limit_events
    where user_id = 'aaaaaaaa-0000-0000-0000-000000000003'), 20::bigint, 'exactly twenty hourly calls succeed');
select extensions.is((select window_count from server_tokens_test.batches where label = 'hour-20'), 0, 'the twentieth already covered request succeeds');
set local role authenticated;
select server_tokens_test.expect_error(pg_catalog.format('select public.issue_token_batch(%s)', (select horizon from server_tokens_test.clock)),
    'rate_limited', '', 'the twenty-first hourly call is refused even when already covered');
reset role;
select extensions.is((select pg_catalog.count(*) from private.account_limit_events
    where user_id = 'aaaaaaaa-0000-0000-0000-000000000003'), 20::bigint, 'the rejected hourly call rolls back its event');
select extensions.is((select pg_catalog.count(*) from private.temporary_tokens
    where user_id = 'aaaaaaaa-0000-0000-0000-000000000003'),
    (select (horizon - current_window) / 900 + 4 from server_tokens_test.clock), 'the hourly limit does not alter stored digests');

-- Reusable helper, separate buckets/accounts, rolling minute cutoff: 10 assertions.
select extensions.ok(not private.record_account_event('aaaaaaaa-0000-0000-0000-000000000004', 'receipt-test', 2, interval '1 minute'), 'the helper accepts its first minute event');
select extensions.ok(not private.record_account_event('aaaaaaaa-0000-0000-0000-000000000004', 'receipt-test', 2, interval '1 minute'), 'the helper accepts the event exactly at its limit');
select extensions.ok(private.record_account_event('aaaaaaaa-0000-0000-0000-000000000004', 'receipt-test', 2, interval '1 minute'), 'the helper reports the event beyond its limit');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events
    where user_id = 'aaaaaaaa-0000-0000-0000-000000000004' and bucket = 'receipt-test'), 3::bigint,
    'the helper records the event even when it returns exceeded');
select extensions.ok(not private.record_account_event('aaaaaaaa-0000-0000-0000-000000000004', 'resolution-test', 1, interval '1 minute'), 'a named bucket has an independent limit');
select extensions.ok(not private.record_account_event('aaaaaaaa-0000-0000-0000-000000000001', 'receipt-test', 1, interval '1 minute'), 'another account has an independent limit');
select extensions.ok(private.record_account_event('aaaaaaaa-0000-0000-0000-000000000004', 'resolution-test', 1, interval '1 minute'), 'the second bucket enforces its own boundary');
delete from private.account_limit_events where user_id = 'aaaaaaaa-0000-0000-0000-000000000004' and bucket = 'receipt-test';
insert into private.account_limit_events (user_id, bucket, occurred_at) values
    ('aaaaaaaa-0000-0000-0000-000000000004', 'receipt-test', pg_catalog.now() - interval '1 minute'),
    ('aaaaaaaa-0000-0000-0000-000000000004', 'receipt-test', pg_catalog.now() - interval '1 minute 1 microsecond'),
    ('aaaaaaaa-0000-0000-0000-000000000004', 'receipt-test', pg_catalog.now() - interval '1 minute' + interval '1 microsecond');
select extensions.ok(private.record_account_event('aaaaaaaa-0000-0000-0000-000000000004', 'receipt-test', 1, interval '1 minute'),
    'the event just inside the rolling span plus the new event exceeds one');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events
    where user_id = 'aaaaaaaa-0000-0000-0000-000000000004' and bucket = 'receipt-test'
    and occurred_at > pg_catalog.now() - interval '1 minute'), 2::bigint, 'events exactly at or before the minute cutoff are excluded');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events
    where user_id = 'aaaaaaaa-0000-0000-0000-000000000004' and bucket = 'receipt-test'), 4::bigint,
    'the helper preserves older events for other spans and later cleanup');

-- Hourly cutoff applies at the API as well: 6 assertions.
insert into private.account_limit_events (user_id, bucket, occurred_at)
select 'aaaaaaaa-0000-0000-0000-000000000004', 'issue_token_batch', pg_catalog.now() - interval '1 hour'
from pg_catalog.generate_series(1, 20);
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"aaaaaaaa-0000-0000-0000-000000000004","role":"authenticated"}';
select public.accept_declarations(true, 'draft', 'draft');
select public.register_time_zone('UTC');
select server_tokens_test.capture('hour-cutoff', (select horizon - 900 from server_tokens_test.clock));
reset role;
select extensions.is((select window_count from server_tokens_test.batches where label = 'hour-cutoff'), 1,
    'twenty calls exactly an hour old do not prevent new issue');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events
    where user_id = 'aaaaaaaa-0000-0000-0000-000000000004' and bucket = 'issue_token_batch'
    and occurred_at > pg_catalog.now() - interval '1 hour'), 1::bigint, 'only the new event counts after the hour cutoff');
insert into private.account_limit_events (user_id, bucket, occurred_at)
select 'aaaaaaaa-0000-0000-0000-000000000004', 'issue_token_batch', pg_catalog.now() - interval '1 hour' + interval '1 microsecond'
from pg_catalog.generate_series(1, 18);
set local role authenticated;
select server_tokens_test.capture('hour-cutoff-20', (select horizon from server_tokens_test.clock));
reset role;
select extensions.is((select pg_catalog.count(*) from private.account_limit_events
    where user_id = 'aaaaaaaa-0000-0000-0000-000000000004' and bucket = 'issue_token_batch'
    and occurred_at > pg_catalog.now() - interval '1 hour'), 20::bigint, 'events just inside the hour count toward the twentieth call');
select extensions.is((select window_count from server_tokens_test.batches where label = 'hour-cutoff-20'), 0, 'exactly twenty current events allow the empty batch');
set local role authenticated;
select server_tokens_test.expect_error(pg_catalog.format('select public.issue_token_batch(%s)', (select horizon from server_tokens_test.clock)),
    'rate_limited', '', 'events just inside the hour prevent a twenty-first call');
reset role;
select extensions.is((select pg_catalog.count(*) from private.account_limit_events
    where user_id = 'aaaaaaaa-0000-0000-0000-000000000004' and bucket = 'issue_token_batch'
    and occurred_at > pg_catalog.now() - interval '1 hour'), 20::bigint, 'the hourly cutoff refusal is atomic');

-- Auth deletion removes token and limiter data: 2 assertions.
delete from auth.users where id = 'aaaaaaaa-0000-0000-0000-000000000004';
select extensions.is((select pg_catalog.count(*) from private.temporary_tokens
    where user_id = 'aaaaaaaa-0000-0000-0000-000000000004'), 0::bigint, 'Auth deletion cascades to token digests');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events
    where user_id = 'aaaaaaaa-0000-0000-0000-000000000004'), 0::bigint, 'Auth deletion cascades to all limiter buckets');

select * from extensions.finish();

rollback;
