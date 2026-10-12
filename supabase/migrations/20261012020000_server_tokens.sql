create extension if not exists pgcrypto with schema extensions;

create table private.temporary_tokens (
    token_digest bytea primary key check (pg_catalog.octet_length(token_digest) = 32),
    user_id uuid not null references auth.users (id) on delete cascade,
    batch_id uuid not null,
    valid_from bigint not null check (valid_from % 900 = 0),
    valid_until bigint not null check (valid_until = valid_from + 900),
    delete_after bigint not null check (delete_after = valid_until + 172800)
);

create index temporary_tokens_owner_window_idx on private.temporary_tokens (user_id, valid_from, valid_until);
create index temporary_tokens_valid_until_idx on private.temporary_tokens (valid_until);
create index temporary_tokens_delete_after_idx on private.temporary_tokens (delete_after);

-- Keep only the rolling span for each account and bucket when its limiter runs.
create table private.account_limit_events (
    user_id uuid not null references auth.users (id) on delete cascade,
    bucket text not null check (private.trim_input(bucket) <> ''),
    occurred_at timestamptz not null
);

create index account_limit_events_owner_bucket_time_idx on private.account_limit_events (user_id, bucket, occurred_at);
create index account_limit_events_occurred_at_idx on private.account_limit_events (occurred_at);

alter table private.temporary_tokens enable row level security;
alter table private.account_limit_events enable row level security;

revoke all on table private.temporary_tokens, private.account_limit_events from public, anon, authenticated;

create function private.record_account_event(account_id uuid, event_bucket text, event_limit integer, time_span interval)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
    event_count bigint;
begin
    if account_id is null or event_bucket is null or private.trim_input(event_bucket) = ''
       or event_limit is null or event_limit < 1 or time_span is null or time_span <= interval '0 seconds' then
        perform private.raise_error('invalid_input');
    end if;

    -- Global order: account namespace 31001, sorted nonce namespace (bigint),
    -- then sorted pair namespace 31003. Re-entering this account lock is safe.
    -- The two-integer account key space is disjoint from bigint nonce locks.
    perform pg_catalog.pg_advisory_xact_lock(31001, pg_catalog.hashtext(account_id::text));
    if not exists (select 1 from auth.users as u where u.id = account_id) then
        perform private.raise_error('not_authenticated');
    end if;

    delete from private.account_limit_events as e
    where e.user_id = account_id and e.bucket = event_bucket
      and e.occurred_at <= pg_catalog.now() - time_span;

    select pg_catalog.count(*) into event_count
    from private.account_limit_events as e
    where e.user_id = account_id
      and e.bucket = event_bucket
      and e.occurred_at > pg_catalog.now() - time_span;
    -- Count later transaction timestamps too: a waiter can have an older now().
    if event_count >= event_limit then
        return true;
    end if;
    insert into private.account_limit_events (user_id, bucket, occurred_at)
    values (account_id, event_bucket, pg_catalog.now());
    return false;
end;
$$;

revoke all on function private.record_account_event(uuid, text, integer, interval) from public, anon, authenticated;

create function public.issue_token_batch(covered_until bigint default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    caller uuid := private.require_caller();
    server_seconds numeric := extract(epoch from pg_catalog.now());
    start_window bigint := (pg_catalog.floor(server_seconds / 900) * 900)::bigint;
    horizon bigint := (pg_catalog.ceil((server_seconds + 43200) / 900) * 900)::bigint;
    new_batch_id uuid := pg_catalog.gen_random_uuid();
    window_start bigint;
    token_bytes bytea;
    windows jsonb := '[]'::jsonb;
begin
    if not private.account_is_ready(caller) then
        perform private.raise_error('account_not_ready');
    end if;
    if covered_until is not null and covered_until % 900 <> 0 then
        perform private.raise_error('invalid_input', array['covered_until']);
    end if;

    if private.record_account_event(caller, 'issue_token_batch', 20, interval '1 hour') then
        perform private.raise_error('rate_limited');
    end if;

    if covered_until is not null and covered_until > start_window then
        start_window := covered_until;
    end if;

    -- Check the whole requested batch before generating any secrets. The
    -- helper's account lock prevents another issue call passing concurrently.
    if exists (
        select 1 from private.temporary_tokens as t
        where t.user_id = caller
          and t.valid_from >= start_window and t.valid_from < horizon
          and t.valid_until > server_seconds
        group by t.valid_from
        having pg_catalog.count(*) >= 4
    ) then
        perform private.raise_error('rate_limited');
    end if;

    window_start := start_window;
    while window_start < horizon loop
        token_bytes := extensions.gen_random_bytes(16);
        insert into private.temporary_tokens (token_digest, user_id, batch_id, valid_from, valid_until, delete_after)
        values (pg_catalog.sha256(token_bytes), caller, new_batch_id, window_start, window_start + 900, window_start + 900 + 172800);
        windows := windows || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
            'token', pg_catalog.encode(token_bytes, 'hex'),
            'valid_from', window_start,
            'valid_until', window_start + 900
        ));
        window_start := window_start + 900;
    end loop;

    return pg_catalog.jsonb_build_object('batch_id', new_batch_id, 'windows', windows);
end;
$$;

revoke all on function public.issue_token_batch(bigint) from public, anon, service_role;
grant execute on function public.issue_token_batch(bigint) to authenticated;
