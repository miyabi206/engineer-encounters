create extension if not exists pg_cron with schema pg_catalog;

-- The optional clock makes exact retention boundaries testable without changing
-- the database clock. The scheduled call always uses transaction time.
create or replace function private.cleanup_expired_data(cleanup_at timestamptz default pg_catalog.now())
returns void
language sql
security definer
set search_path = ''
as $$
    -- Keep the expired response through the full 300-second skew grace.
    delete from private.encounter_candidates as c
    where c.expires_at < cleanup_at - interval '300 seconds';

    delete from private.temporary_tokens as t
    where t.delete_after <= extract(epoch from cleanup_at);

    -- A date deadline is UTC midnight, regardless of the cron session zone.
    delete from private.consumed_nonces as n
    where n.delete_after <= (cleanup_at at time zone 'UTC')::date;

    -- This bucket name must match private.register_time_zone's limiter call.
    delete from private.account_limit_events as e
    where e.occurred_at < cleanup_at - case when e.bucket = 'register_time_zone'
        then interval '1 day' else interval '1 hour' end;
$$;

revoke all on function private.cleanup_expired_data(timestamptz)
    from public, anon, authenticated, service_role;

-- pg_cron's named schedule updates the same owner's existing job on reapply.
do $$
begin
    perform cron.schedule('encounters-expiry-cleanup', '*/15 * * * *',
        'select private.cleanup_expired_data();');
end;
$$;
