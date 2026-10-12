begin;
create extension if not exists pgtap with schema extensions;
create schema safety_test;
grant usage on schema safety_test to anon, authenticated, service_role;

create function safety_test.id(n integer)
returns uuid language sql immutable set search_path = '' as $$
    select ('ffffffff-0000-0000-0000-' || pg_catalog.lpad(n::text, 12, '0'))::uuid;
$$;
create function safety_test.day()
returns date language sql stable set search_path = '' as $$ select (pg_catalog.now() at time zone 'UTC')::date; $$;
create function safety_test.link_id(n integer, item integer default 1)
returns uuid language sql immutable set search_path = '' as $$ select safety_test.id(10000 + n * 10 + item); $$;
create function safety_test.nonce(n integer)
returns text language sql immutable set search_path = '' as $$ select pg_catalog.md5('safety-nonce:' || n); $$;
create function safety_test.token(n integer)
returns text language sql immutable set search_path = '' as $$ select pg_catalog.md5('safety-token:' || n); $$;
create function safety_test.observed()
returns bigint language sql stable set search_path = '' as $$
    select (pg_catalog.floor(extract(epoch from pg_catalog.now()) / 900) * 900)::bigint - 300;
$$;
create function safety_test.receipt(n integer, side integer, peer integer, prior integer default null)
returns jsonb language sql stable set search_path = '' as $$
    select pg_catalog.jsonb_build_object('id', safety_test.id(40000 + n * 10 + side),
        'protocol_version', 1, 'role', case when side < peer then 'central' else 'peripheral' end,
        'exchange_nonce', safety_test.nonce(n), 'prior_exchange_nonce', safety_test.nonce(prior),
        'start', pg_catalog.jsonb_build_object('own_token', safety_test.token(side),
            'peer_token', safety_test.token(peer), 'observed_at', safety_test.observed()),
        'checkpoint', pg_catalog.jsonb_build_object('own_token', safety_test.token(side),
            'peer_token', safety_test.token(peer), 'observed_at', safety_test.observed() + 120),
        'observed_duration', 120, 'session_flag', false, 'is_final_evidence', true);
$$;
create function safety_test.exchange(n integer, side integer, peer integer)
returns bytea language sql immutable set search_path = '' as $$
    select private.receipt_exchange_digest(pg_catalog.sha256(pg_catalog.decode(safety_test.nonce(n), 'hex')),
        pg_catalog.sha256(pg_catalog.decode(safety_test.token(side), 'hex')),
        pg_catalog.sha256(pg_catalog.decode(safety_test.token(peer), 'hex')));
$$;
create function safety_test.make_encounter(n integer, side integer, peer integer, age integer default 0)
returns void language plpgsql set search_path = '' as $$
begin
    insert into private.encounters (encounter_id, user_a, user_b, kind, day_a, day_b)
    values (safety_test.id(n), least(safety_test.id(side), safety_test.id(peer)),
        greatest(safety_test.id(side), safety_test.id(peer)), 'session', safety_test.day() - age, safety_test.day() - age);
    insert into private.encounter_views (encounter_id, viewer_id, revealed, reveal_report_day, favorite)
    values (safety_test.id(n), safety_test.id(side), true, safety_test.day(), true),
        (safety_test.id(n), safety_test.id(peer), true, safety_test.day(), true);
    insert into private.saved_links (viewer_id, encounter_id, link_id)
    values (safety_test.id(side), safety_test.id(n), safety_test.link_id(peer)),
        (safety_test.id(peer), safety_test.id(n), safety_test.link_id(side));
end;
$$;
create function safety_test.seed_candidates(n integer, side integer, peer integer, prior integer default null)
returns void language plpgsql set search_path = '' as $$
begin
    insert into private.encounter_candidates (nonce_digest, uploader_id, receipt_id, peer_id, protocol_version,
        role, prior_nonce_digest, start_own_token_digest, start_peer_token_digest, start_observed_at,
        checkpoint_own_token_digest, checkpoint_peer_token_digest, checkpoint_observed_at,
        observed_duration, session_flag, is_final_evidence, first_uploaded_at, expires_at)
    select pg_catalog.sha256(pg_catalog.decode(safety_test.nonce(n), 'hex')), safety_test.id(a.side),
        safety_test.id(40000 + n * 10 + a.side), safety_test.id(a.peer), 1,
        case when a.side < a.peer then 'central' else 'peripheral' end,
        pg_catalog.sha256(pg_catalog.decode(safety_test.nonce(prior), 'hex')),
        pg_catalog.sha256(pg_catalog.decode(safety_test.token(a.side), 'hex')),
        pg_catalog.sha256(pg_catalog.decode(safety_test.token(a.peer), 'hex')), safety_test.observed(),
        pg_catalog.sha256(pg_catalog.decode(safety_test.token(a.side), 'hex')),
        pg_catalog.sha256(pg_catalog.decode(safety_test.token(a.peer), 'hex')), safety_test.observed() + 120,
        120, false, true, pg_catalog.now(), pg_catalog.to_timestamp(safety_test.observed()::double precision) + interval '48 hours'
    from (values (side, peer), (peer, side)) as a(side, peer);
end;
$$;
create function safety_test.call(n integer, operation text, resource uuid default null,
    reason_value text default null, link uuid default null, outcome_value text default null)
returns jsonb language plpgsql set search_path = '' as $$
declare result jsonb;
begin
    begin
        if operation in ('queue', 'resolve') then set local role service_role;
        else set local role authenticated; end if;
        perform pg_catalog.set_config('request.jwt.claim.sub', '', true);
        perform pg_catalog.set_config('request.jwt.claims',
            pg_catalog.jsonb_build_object('sub', safety_test.id(n), 'role', 'authenticated')::text, true);
        case operation
            when 'block' then result := public.block_encounter_person(resource);
            when 'blocks' then result := public.list_blocks();
            when 'unblock' then result := public.unblock(resource);
            when 'report' then result := public.report_encounter_person(resource, reason_value, link);
            when 'delete' then result := public.delete_encounter(resource);
            when 'queue' then result := service.list_open_reports(safety_test.id(n));
            when 'resolve' then result := service.resolve_report(safety_test.id(n), resource, outcome_value);
            when 'card' then result := public.get_encounter_card(resource);
            when 'feed' then result := public.get_encounter_feed();
            when 'favorites' then result := public.list_encounter_favorites();
            when 'saved' then result := public.list_saved_links();
            when 'favorite' then result := public.set_encounter_favorite(resource, false);
            when 'save' then result := public.save_link(resource, link);
            when 'unsave' then result := public.unsave_link(resource, link);
        end case;
    exception when others then reset role; raise; end;
    reset role;
    return result;
end;
$$;
create function safety_test.upload(n integer, exchange_number integer, peer integer, prior integer default null)
returns jsonb language plpgsql set search_path = '' as $$
declare result jsonb;
begin
    begin
        set local role authenticated;
        perform pg_catalog.set_config('request.jwt.claim.sub', '', true);
        perform pg_catalog.set_config('request.jwt.claims',
            pg_catalog.jsonb_build_object('sub', safety_test.id(n), 'role', 'authenticated')::text, true);
        result := public.submit_receipts(pg_catalog.jsonb_build_array(safety_test.receipt(exchange_number, n, peer, prior)));
    exception when others then reset role; raise; end;
    reset role;
    return result;
end;
$$;
create function safety_test.execute_role(role_name text, statement text)
returns void language plpgsql set search_path = '' as $$
begin
    begin
        execute pg_catalog.format('set local role %I', role_name);
        execute statement;
    exception when others then reset role; raise; end;
    reset role;
end;
$$;
create function safety_test.expect_error(statement text, code text, detail text, description text)
returns text language plpgsql set search_path = pg_catalog, extensions as $$
declare actual_state text; actual_code text; actual_detail text;
begin
    begin execute statement;
    exception when others then
        get stacked diagnostics actual_state = returned_sqlstate, actual_code = message_text, actual_detail = pg_exception_detail;
        return extensions.is(pg_catalog.jsonb_build_array(actual_state, actual_code, coalesce(actual_detail, '')),
            pg_catalog.jsonb_build_array('P0001', code, detail), description);
    end;
    return extensions.fail(description || ': expected exception');
end;
$$;

insert into auth.users (id) select safety_test.id(n) from pg_catalog.generate_series(1, 235) as n;
insert into private.interests (interest_id, label_ja, label_en) values ('safety-interest', 'safety', 'safety');
insert into private.profiles (user_id, age_18_declared, terms_version, privacy_version, discovery_on, display_name)
select safety_test.id(n), true, 'draft', 'draft', true, 'Person' || n from pg_catalog.generate_series(1, 233) as n;
insert into private.notification_preferences (user_id, time_zone)
select safety_test.id(n), 'UTC' from pg_catalog.generate_series(1, 233) as n;
insert into private.field_visibility (owner_id, field, level)
select safety_test.id(n), 'display_name', 'everyone_eligible' from pg_catalog.generate_series(1, 233) as n;
insert into private.user_interests (user_id, interest_id)
select safety_test.id(n), 'safety-interest' from pg_catalog.generate_series(1, 233) as n;
insert into private.user_purposes (user_id, purpose)
select safety_test.id(n), 'discovery' from pg_catalog.generate_series(1, 233) as n;
insert into private.external_links (link_id, owner_id, source, url, visibility, title)
select safety_test.link_id(n, item), safety_test.id(n), 'other', 'https://example.invalid/' || n || '/' || item,
    case when item = 1 then 'everyone_eligible' else 'private' end, 'Link' || n
from pg_catalog.generate_series(1, 233) as n cross join pg_catalog.generate_series(1, 2) as item;
insert into private.temporary_tokens (token_digest, user_id, batch_id, valid_from, valid_until, delete_after)
select pg_catalog.sha256(pg_catalog.decode(safety_test.token(n), 'hex')), safety_test.id(n), safety_test.id(n),
    w, w + 900, w + 173700 from pg_catalog.generate_series(1, 6) as n
cross join (select (pg_catalog.floor(safety_test.observed()::numeric / 900) * 900)::bigint as w) as bounds;

create function safety_test.prepare()
returns void language plpgsql set search_path = '' as $$
begin
    delete from private.reports;
    delete from private.encounters;
    delete from private.blocks;
    delete from private.encounter_candidates;
    delete from private.consumed_nonces;
    delete from private.account_limit_events;
    update private.profiles set discovery_on = true, moderation_state = 'active', operator_outcome = null;
    update private.notification_preferences set time_zone = 'UTC';
    update private.server_settings set operator_account_id = safety_test.id(235);
    perform safety_test.make_encounter(101, 1, 2);
    perform safety_test.make_encounter(102, 1, 2, 1);
    perform safety_test.make_encounter(103, 3, 2);
    perform safety_test.make_encounter(104, 4, 2);
    perform safety_test.make_encounter(105, 5, 2);
    perform safety_test.make_encounter(106, 1, 6);
    perform safety_test.make_encounter(107, 3, 6);
end;
$$;
grant execute on all functions in schema safety_test to anon, authenticated, service_role;
grant execute on all functions in schema extensions to anon, authenticated, service_role;
create temporary table results (label text primary key, value jsonb);

-- Fixed row cardinalities are counted by section below.
-- 30 + 21 + 17 + 16 + 56 + 20 + 32 + 29 + 16 + 12 + 17 + 14 + 9 = 289.
select extensions.plan(289);

-- Catalog: 30 assertions (7 signatures x 3, default 1, columns 1, RLS 2,
-- policies 2, FK actions 1, indexes 1, operator column 1).
create temporary table safety_rpcs (signature text, names text[], statement text, schema_name text);
insert into safety_rpcs values
    ('public.block_encounter_person(uuid)', array['encounter_id'], 'select public.block_encounter_person(null)', 'public'),
    ('public.list_blocks()', null, 'select public.list_blocks()', 'public'),
    ('public.unblock(uuid)', array['block_id'], 'select public.unblock(null)', 'public'),
    ('public.report_encounter_person(uuid,text,uuid)', array['encounter_id','reason','link_id'], 'select public.report_encounter_person(null,null,null)', 'public'),
    ('public.delete_encounter(uuid)', array['encounter_id'], 'select public.delete_encounter(null)', 'public'),
    ('service.list_open_reports(uuid)', array['account_id'], 'select service.list_open_reports(null)', 'service'),
    ('service.resolve_report(uuid,uuid,text)', array['account_id','report_id','outcome'], 'select service.resolve_report(null,null,null)', 'service');
select extensions.is(p.proargnames, r.names, r.signature || ': exact argument names')
from safety_rpcs as r join pg_catalog.pg_proc as p on p.oid = r.signature::regprocedure;
select extensions.is(pg_catalog.format_type(p.prorettype, null), 'jsonb', r.signature || ': JSON return')
from safety_rpcs as r join pg_catalog.pg_proc as p on p.oid = r.signature::regprocedure;
select extensions.ok(p.prosecdef and 'search_path=""' = any(p.proconfig), r.signature || ': definer and empty search path')
from safety_rpcs as r join pg_catalog.pg_proc as p on p.oid = r.signature::regprocedure;
select extensions.is((select pronargdefaults from pg_catalog.pg_proc
    where oid = 'public.report_encounter_person(uuid,text,uuid)'::regprocedure), 1::smallint, 'only report link context defaults');
select extensions.is((select pg_catalog.array_agg(a.attname::text order by a.attnum) from pg_catalog.pg_attribute as a
    where a.attrelid = 'private.reports'::regclass and a.attnum > 0 and not a.attisdropped),
    array['report_id','reporter_id','subject_id','encounter_id','link_id','reason','status','review_due_at','outcome','resolved_day'],
    'reports contain only references, reason and review state');
select extensions.ok(c.relrowsecurity, t.name || ': RLS') from (values ('reports'), ('iana_time_zones')) as t(name)
join pg_catalog.pg_class as c on c.oid = ('private.' || t.name)::regclass;
select extensions.is((select pg_catalog.count(*) from pg_catalog.pg_policy as p
    where p.polrelid = ('private.' || t.name)::regclass), 0::bigint, t.name || ': no policies')
from (values ('reports'), ('iana_time_zones')) as t(name);
select extensions.is((select pg_catalog.array_agg(c.confdeltype::text order by c.conname) from pg_catalog.pg_constraint as c
    where c.conrelid = 'private.reports'::regclass and c.contype = 'f'), array['n','n','c','c'], 'report references SET NULL, accounts cascade');
select extensions.is((select pg_catalog.count(*) from pg_catalog.pg_index where indrelid = 'private.reports'::regclass),
    6::bigint, 'report uniqueness, queue and all FK lookups indexed');
select extensions.ok((select not attnotnull from pg_catalog.pg_attribute
    where attrelid = 'private.profiles'::regclass and attname = 'operator_outcome'), 'operator outcome is nullable');

-- Role boundary: 21 assertions (10 public denials, 4 service denials,
-- 5 missing callers, 2 missing service accounts).
select extensions.throws_ok(pg_catalog.format('select safety_test.execute_role(%L,%L)', role.name, r.statement),
    '42501', null, role.name || ': ' || r.signature || ' denied')
from safety_rpcs as r cross join (values ('anon'), ('service_role')) as role(name) where r.schema_name = 'public';
select extensions.throws_ok(pg_catalog.format('select safety_test.execute_role(%L,%L)', role.name, r.statement),
    '42501', null, role.name || ': ' || r.signature || ' denied')
from safety_rpcs as r cross join (values ('anon'), ('authenticated')) as role(name) where r.schema_name = 'service';
select safety_test.expect_error(pg_catalog.format('select safety_test.call(null,%L)', op.name),
    'not_authenticated', '', op.name || ': missing caller')
from (values ('block'), ('blocks'), ('unblock'), ('report'), ('delete')) as op(name);
select safety_test.expect_error($q$select safety_test.call(999,'queue')$q$, 'not_authenticated', '', 'queue: missing live operator');
select safety_test.expect_error($q$select safety_test.call(999,'resolve',safety_test.id(999),null,null,'dismissed')$q$,
    'not_authenticated', '', 'resolve: missing live operator');

-- Input validation: 17 assertions.
select safety_test.prepare();
select safety_test.expect_error(pg_catalog.format('select safety_test.call(1,%L,null)', op.name),
    'invalid_input', 'encounter_id', op.name || ': null encounter') from (values ('block'), ('delete')) as op(name);
select safety_test.expect_error($q$select safety_test.call(1,'unblock',null)$q$, 'invalid_input', 'block_id', 'unblock: null block');
select safety_test.expect_error(pg_catalog.format('select safety_test.call(1,''report'',%s,%L,%s)', r.encounter, r.reason, r.link),
    'invalid_input', r.detail, r.description)
from (values
    ('null', 'spam', 'null', 'encounter_id', 'report: null encounter'),
    ('safety_test.id(101)', null, 'null', 'reason', 'report: null reason'),
    ('safety_test.id(101)', 'unknown', 'null', 'reason', 'report: bad reason'),
    ('safety_test.id(101)', 'impersonation', 'null', 'link_id', 'impersonation needs link'),
    ('safety_test.id(101)', 'spam', 'safety_test.link_id(2)', 'link_id', 'spam forbids link'),
    ('safety_test.id(101)', 'harassment', 'safety_test.link_id(2)', 'link_id', 'harassment forbids link'),
    ('safety_test.id(101)', 'other', 'safety_test.link_id(2)', 'link_id', 'other forbids link'),
    ('null', 'other', 'safety_test.link_id(2)', 'encounter_id,link_id', 'invalid report fields in signature order')
) as r(encounter, reason, link, detail, description);
select safety_test.expect_error($q$select safety_test.call(null,'queue')$q$, 'invalid_input', 'account_id', 'queue: null account');
select safety_test.expect_error(pg_catalog.format('select safety_test.call(%s,''resolve'',%s,null,null,%L)', r.account, r.report, r.outcome),
    'invalid_input', r.detail, r.description)
from (values
    ('null', 'null', null, 'account_id,report_id,outcome', 'resolve: all null'),
    ('null', 'safety_test.id(999)', 'dismissed', 'account_id', 'resolve: null account'),
    ('235', 'null', 'dismissed', 'report_id', 'resolve: null report'),
    ('235', 'safety_test.id(999)', null, 'outcome', 'resolve: null outcome'),
    ('235', 'safety_test.id(999)', 'active', 'outcome', 'resolve: invalid outcome')
) as r(account, report, outcome, detail, description);

-- Resource denials and all four accepted reasons: 16 assertions.
select safety_test.expect_error(pg_catalog.format('select safety_test.call(1,%L,safety_test.id(999),''spam'')', op.name),
    'not_found', '', op.name || ': absent resource') from (values ('block'), ('delete'), ('report'), ('unblock')) as op(name);
select safety_test.expect_error(pg_catalog.format('select safety_test.call(1,%L,safety_test.id(103),''spam'')', op.name),
    'not_found', '', op.name || ': nonparticipant') from (values ('block'), ('delete'), ('report')) as op(name);
select safety_test.expect_error(pg_catalog.format('select safety_test.call(1,''report'',safety_test.id(101),''impersonation'',%s)', l.id),
    'not_found', '', 'impersonation: ' || l.description)
from (values ('safety_test.link_id(1)', 'own link'), ('safety_test.link_id(6)', 'unrelated link'),
    ('safety_test.link_id(2,2)', 'private link'), ('safety_test.id(999)', 'absent link')) as l(id, description);
select extensions.is((select pg_catalog.count(*) from private.account_limit_events where bucket = 'report_encounter_person'),
    0::bigint, 'rejected input/context spends no report event');
-- Each acceptance gets a fresh pair because a retained report suppresses repeats.
create function safety_test.reason_cases()
returns setof text language plpgsql set search_path = pg_catalog, extensions as $$
declare reason_value text;
begin
    foreach reason_value in array array['spam','harassment','impersonation','other'] loop
        perform safety_test.prepare();
        return next extensions.is(safety_test.call(1, 'report', safety_test.id(101), reason_value,
            case when reason_value = 'impersonation' then safety_test.link_id(2) else null end)->>'status',
            'open', reason_value || ': accepted');
    end loop;
end;
$$;
select * from safety_test.reason_cases();

-- Block in both directions: 28 assertions per direction = 56.
create function safety_test.block_cases()
returns setof text language plpgsql set search_path = pg_catalog, extensions as $$
declare actor integer; peer integer; value jsonb; expected_deadline date; side integer;
begin
    expected_deadline := ((pg_catalog.now() at time zone 'UTC') + interval '48 hours 300 seconds')::date
        + case when ((pg_catalog.now() at time zone 'UTC') + interval '48 hours 300 seconds')::time = time '00:00:00' then 0 else 1 end;
    foreach actor in array array[1,2] loop
        peer := 3 - actor;
        perform safety_test.prepare();
        update private.notification_preferences set time_zone = 'Etc/GMT-14' where user_id = safety_test.id(actor);
        perform safety_test.seed_candidates(700, 1, 2);
        perform safety_test.seed_candidates(701, 1, 2, 700);
        perform safety_test.seed_candidates(702, 1, 2);
        update private.encounter_candidates set expires_at = pg_catalog.now() - interval '1 second'
        where nonce_digest = pg_catalog.sha256(pg_catalog.decode(safety_test.nonce(702), 'hex'));
        -- Same nonce, different token scope and uploaders must survive.
        perform safety_test.seed_candidates(700, 3, 6);
        value := safety_test.call(actor, 'block', safety_test.id(101));
        return next extensions.is((select pg_catalog.array_agg(k order by k) from pg_catalog.jsonb_object_keys(value) as k),
            array['block_id','placed_day'], 'block: exact wire keys');
        return next extensions.is(value->>'placed_day', (pg_catalog.now() at time zone 'Etc/GMT-14')::date::text, 'block: blocker-local placement day');
        return next extensions.is((select b.block_id::text from private.blocks as b
            where b.blocker_id = safety_test.id(actor) and b.blocked_id = safety_test.id(peer)), value->>'block_id', 'block: returned opaque ID');
        return next extensions.is((select pg_catalog.count(*) from private.encounters
            where user_a = safety_test.id(1) and user_b = safety_test.id(2)), 0::bigint, 'block: every confirmed pair encounter removed');
        return next extensions.is((select pg_catalog.count(*) from private.encounter_views
            where encounter_id in (safety_test.id(101), safety_test.id(102))), 0::bigint, 'block: both sides views/favorites removed');
        return next extensions.is((select pg_catalog.count(*) from private.saved_links
            where encounter_id in (safety_test.id(101), safety_test.id(102))), 0::bigint, 'block: both sides saves removed');
        return next extensions.is((select pg_catalog.count(*) from private.encounter_candidates
            where uploader_id in (safety_test.id(1),safety_test.id(2)) and peer_id in (safety_test.id(1),safety_test.id(2))),
            0::bigint, 'block: all original, joined and expired candidates removed');
        return next extensions.is((select pg_catalog.count(*) from private.encounter_candidates), 2::bigint, 'block: unrelated candidates preserved');
        return next extensions.is((select pg_catalog.count(*) from private.consumed_nonces), 3::bigint, 'block: reciprocal rows share scoped tombstones');
        return next extensions.ok((select pg_catalog.bool_and(delete_after = expected_deadline) from private.consumed_nonces), 'block: exact Unit 3 midnight deadline');
        return next extensions.ok(not exists (select 1 from private.consumed_nonces
            where exchange_digest = safety_test.exchange(700,3,6)), 'block: unrelated scope with same nonce is unconsumed');
        return next extensions.is(safety_test.call(actor, 'blocks'), pg_catalog.jsonb_build_object('blocks',
            pg_catalog.jsonb_build_array(value), 'truncated', false), 'blocks: only opaque reference/day, no person snapshot');
        return next extensions.is(safety_test.call(peer, 'blocks'), '{"blocks":[],"truncated":false}'::jsonb, 'incoming block is absent from own list');
        foreach side in array array[1,2] loop
            return next extensions.is(safety_test.upload(side,700,3-side)#>>'{0,status}', 'consumed', 'block: original replay consumed');
            return next extensions.is(safety_test.upload(side,701,3-side,700)#>>'{0,status}', 'consumed', 'block: joined replay consumed');
        end loop;
        return next safety_test.expect_error(pg_catalog.format('select safety_test.call(%s,''block'',safety_test.id(101))', actor),
            'not_found', '', 'repeat block on removed encounter changes nothing');
        foreach side in array array[1,2] loop
            return next safety_test.expect_error(pg_catalog.format('select safety_test.call(%s,''card'',safety_test.id(102))', side),
                'not_found', '', 'block: both viewers lose other pair encounters');
        end loop;
        return next safety_test.expect_error(pg_catalog.format('select safety_test.call(%s,''unblock'',%L::uuid)', peer, value->>'block_id'),
            'not_found', '', 'unblock: foreign block ID');
        return next extensions.is(safety_test.call(actor,'unblock',(value->>'block_id')::uuid), '{"unblocked":true}'::jsonb, 'unblock succeeds for placer');
        return next extensions.is(pg_catalog.jsonb_build_array((select pg_catalog.count(*) from private.blocks),
            (select pg_catalog.count(*) from private.encounters where user_a = safety_test.id(1) and user_b = safety_test.id(2)),
            (select pg_catalog.count(*) from private.encounter_candidates where uploader_id in (safety_test.id(1),safety_test.id(2)))),
            '[0,0,0]'::jsonb, 'unblock restores neither encounters nor candidates');
        return next safety_test.expect_error(pg_catalog.format('select safety_test.call(%s,''unblock'',%L::uuid)', actor, value->>'block_id'),
            'not_found', '', 'unblock: already removed');
        return next extensions.is(safety_test.upload(1,700,2)#>>'{0,status}', 'consumed', 'unblock keeps replay tombstones');
        return next extensions.is(safety_test.upload(1,703,2)#>>'{0,status}', 'candidate', 'new exchange after unblock waits for peer');
        return next extensions.is(safety_test.upload(2,703,1)#>>'{0,status}', 'resolved', 'genuinely new exchange after unblock resolves');
        return next extensions.is((select pg_catalog.count(*) from private.encounters
            where user_a = safety_test.id(1) and user_b = safety_test.id(2) and kind = 'ambient'), 1::bigint, 'only the new encounter exists');
    end loop;
end;
$$;
select * from safety_test.block_cases();

-- Encounter deletion: 20 assertions.
select safety_test.prepare();
select safety_test.seed_candidates(700,1,2);
select safety_test.seed_candidates(701,1,2,700);
select safety_test.seed_candidates(700,3,6);
select extensions.is(safety_test.call(1,'delete',safety_test.id(101)), '{"deleted":true}'::jsonb, 'delete: exact response');
select extensions.is((select pg_catalog.count(*) from private.encounters where encounter_id=safety_test.id(101)), 0::bigint, 'named encounter removed');
select extensions.is((select pg_catalog.count(*) from private.encounters where encounter_id=safety_test.id(102)), 1::bigint, 'other confirmed encounter of pair remains');
select extensions.is((select pg_catalog.count(*) from private.encounter_views where encounter_id=safety_test.id(101)), 0::bigint, 'delete: both views and favorites cascade');
select extensions.is((select pg_catalog.count(*) from private.saved_links where encounter_id=safety_test.id(101)), 0::bigint, 'delete: both saved references cascade');
select extensions.is((select pg_catalog.count(*) from private.saved_links where encounter_id=safety_test.id(102)), 2::bigint, 'delete: other encounter retains both saves');
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates
    where uploader_id in (safety_test.id(1),safety_test.id(2))), 0::bigint, 'delete: pending pair candidates purged');
select extensions.is((select pg_catalog.count(*) from private.encounter_candidates), 2::bigint, 'delete: unrelated candidates survive');
select extensions.is((select pg_catalog.count(*) from private.consumed_nonces), 2::bigint, 'delete: both removed exchange scopes consumed');
select extensions.ok((select pg_catalog.bool_and(delete_after::timestamp at time zone 'UTC' >= pg_catalog.now() + interval '48 hours 300 seconds'
    and delete_after::timestamp at time zone 'UTC' < pg_catalog.now() + interval '72 hours 300 seconds') from private.consumed_nonces), 'delete: deadline is first sufficiently late UTC midnight');
select extensions.is(safety_test.call(1,'card',safety_test.id(102))->>'display_name','Person2','other confirmed card remains authorized');
select extensions.is(safety_test.upload(1,700,2)#>>'{0,status}','consumed','delete: first side replay consumed');
select extensions.is(safety_test.upload(2,701,1,700)#>>'{0,status}','consumed','delete: joined peer replay consumed');
select safety_test.expect_error($q$select safety_test.call(1,'delete',safety_test.id(101))$q$,'not_found','','delete: repeat');
select safety_test.expect_error($q$select safety_test.call(2,'card',safety_test.id(101))$q$,'not_found','','delete: counterpart loses named card');
select extensions.is((select pg_catalog.count(*) from private.blocks),0::bigint,'delete creates no block');
select extensions.is(safety_test.upload(1,703,2)#>>'{0,status}','candidate','delete: new exchange waits for peer');
select extensions.is(safety_test.upload(2,703,1)#>>'{0,status}','resolved','delete: genuinely new exchange resolves');
select extensions.is((select pg_catalog.count(*) from private.encounters where user_a=safety_test.id(1) and user_b=safety_test.id(2)),
    2::bigint,'remaining old encounter plus genuinely new encounter');
select extensions.ok(not exists (select 1 from private.consumed_nonces where exchange_digest=safety_test.exchange(700,3,6)), 'delete: scope does not consume unrelated pair');

-- Report suppression and threshold: 32 assertions.
select safety_test.prepare();
insert into results values ('first', safety_test.call(1,'report',safety_test.id(101),'impersonation',safety_test.link_id(2)));
select extensions.is((select pg_catalog.array_agg(k order by k) from results as r
    cross join lateral pg_catalog.jsonb_object_keys(r.value) as k where r.label='first'), array['report_id','status'], 'report: exact response keys');
select extensions.is((select value->>'status' from results where label='first'),'open','report starts open');
select extensions.is((select review_due_at from private.reports),pg_catalog.floor(extract(epoch from pg_catalog.now()))::bigint+259200,'review deadline is now plus 259200 seconds');
select extensions.is((select moderation_state from private.profiles where user_id=safety_test.id(2)),'active','one reporter leaves subject active');
select extensions.ok((select operator_outcome is null from private.profiles where user_id=safety_test.id(2)),'one report records no operator decision');
select safety_test.expect_error(pg_catalog.format('select safety_test.call(1,%L,safety_test.id(102),''spam'',%s)',
    op.name, case when op.name in ('save','unsave') then 'safety_test.link_id(2)' else 'null' end),
    'not_found','','retained report: subject-wide ' || op.name || ' denied')
from (values ('card'),('favorite'),('save'),('unsave'),('block'),('delete'),('report')) as op(name);
select extensions.is(pg_catalog.jsonb_array_length(safety_test.call(1,op.name)->op.collection),1,
    'report hides both subject encounters from ' || op.name || ', unrelated owner remains')
from (values ('feed','cards'),('favorites','cards'),('saved','links')) as op(name,collection);
select extensions.is(safety_test.call(1,'card',safety_test.id(106))->>'display_name','Person6','report does not hide unrelated counterpart');
select extensions.is((select pg_catalog.count(*) from private.reports),1::bigint,'repeat reporter adds no row');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events where bucket='report_encounter_person'),1::bigint,'repeat spends no budget');
select extensions.is((select reason from private.reports),'impersonation','repeat cannot change original reason/context');
insert into results values ('second', safety_test.call(3,'report',safety_test.id(103),'spam'));
select extensions.is((select moderation_state from private.profiles where user_id=safety_test.id(2)),'active','two distinct reporters leave subject active');
select extensions.is((select pg_catalog.count(distinct reporter_id) from private.reports where status='open'),2::bigint,'second distinct open reporter counted');
insert into results values ('third', safety_test.call(4,'report',safety_test.id(104),'other'));
select extensions.is((select moderation_state from private.profiles where user_id=safety_test.id(2)),'hidden','three distinct open reporters hide subject');
select extensions.ok((select operator_outcome is null from private.profiles where user_id=safety_test.id(2)),'automatic hide is never an operator outcome');
select safety_test.expect_error($q$select safety_test.call(5,'card',safety_test.id(105))$q$,'not_found','','threshold hides card from nonreporter');
select extensions.is(pg_catalog.jsonb_array_length(safety_test.call(5,op.name)->op.collection),0,'threshold hides subject from nonreporter ' || op.name)
from (values ('feed','cards'),('favorites','cards'),('saved','links')) as op(name,collection);
select extensions.is((select pg_catalog.count(*) from private.reports where status='open'),3::bigint,'three open rows retained');
select extensions.is((select pg_catalog.count(*) from private.encounters
    where user_a=safety_test.id(2) or user_b=safety_test.id(2)),5::bigint,'report hiding deletes no encounter');
select extensions.is(safety_test.call(234,'blocks'),'{"blocks":[],"truncated":false}'::jsonb,'block listing needs only a live account');
select extensions.is(pg_catalog.jsonb_array_length(safety_test.call(235,'queue')->'reports'),3,'operator queue needs no app profile');
select extensions.is(safety_test.call(235,'queue')->'truncated','false'::jsonb,'three-row operator queue is complete');

-- Operator access, dismissal, retained hides and an older decision replay: 29 assertions.
select extensions.is(safety_test.call(235,'queue'), pg_catalog.jsonb_build_object('reports', (
    select pg_catalog.jsonb_agg(r.value order by r.value->>'report_id') from (
        select pg_catalog.jsonb_build_object('report_id', value->'report_id', 'subject_id', safety_test.id(2),
            'reporter_id', safety_test.id(case label when 'first' then 1 when 'second' then 3 else 4 end),
            'encounter_id', safety_test.id(case label when 'first' then 101 when 'second' then 103 else 104 end),
            'link_id', case when label='first' then safety_test.link_id(2) else null end,
            'reason', case label when 'first' then 'impersonation' when 'second' then 'spam' else 'other' end,
            'status', 'open', 'review_due_at', pg_catalog.floor(extract(epoch from pg_catalog.now()))::bigint+259200) as value
        from results where label in ('first','second','third')
    ) as r), 'truncated', false), 'queue: exact references only, deadline/UUID order');
select safety_test.expect_error($q$select safety_test.call(1,'queue')$q$,'not_found','','queue: other live account is not operator');
select safety_test.expect_error($q$select safety_test.call(1,'resolve',(select (value->>'report_id')::uuid from results where label='first'),null,null,'dismissed')$q$,
    'not_found','','resolve: other live account is not operator');
update private.server_settings set operator_account_id=null;
select safety_test.expect_error($q$select safety_test.call(235,'queue')$q$,'not_found','','queue: operator unconfigured');
select safety_test.expect_error($q$select safety_test.call(235,'resolve',(select (value->>'report_id')::uuid from results where label='first'),null,null,'dismissed')$q$,
    'not_found','','resolve: operator unconfigured');
update private.server_settings set operator_account_id=safety_test.id(235);
select safety_test.expect_error($q$select safety_test.call(235,'resolve',safety_test.id(999),null,null,'dismissed')$q$,'not_found','','resolve: nonexistent report');
insert into results select 'dismissed', safety_test.call(235,'resolve',(value->>'report_id')::uuid,null,null,'dismissed') from results where label='first';
select extensions.is((select value from results where label='dismissed'), pg_catalog.jsonb_build_object(
    'report_id',(select value->'report_id' from results where label='first'), 'status','resolved','outcome','dismissed','moderation_state','active'), 'dismissal: exact resolved response');
select extensions.is((select pg_catalog.jsonb_build_array(moderation_state,operator_outcome) from private.profiles where user_id=safety_test.id(2)),
    '["active","dismissed"]'::jsonb,'only operator dismissal reactivates and records outcome');
select extensions.is((select pg_catalog.count(*) from private.reports where status='resolved' and outcome='dismissed'),3::bigint,'dismissal resolves all subject open reports');
select extensions.ok((select pg_catalog.bool_and(resolved_day=safety_test.day()) from private.reports),'resolved dates are UTC calendar dates');
select extensions.is(safety_test.call(235,'queue'),'{"reports":[],"truncated":false}'::jsonb,'queue excludes resolved reports');
select extensions.is(safety_test.call(235,'resolve',(select (value->>'report_id')::uuid from results where label='first'),null,null,'dismissed'),
    (select value from results where label='dismissed'),'same report/outcome repeat is idempotent');
select safety_test.expect_error($q$select safety_test.call(235,'resolve',(select (value->>'report_id')::uuid from results where label='first'),null,null,'hidden')$q$,
    'invalid_input','outcome','resolved row refuses a conflicting outcome');
select extensions.is((select pg_catalog.jsonb_build_array(moderation_state,operator_outcome) from private.profiles where user_id=safety_test.id(2)),
    '["active","dismissed"]'::jsonb,'conflicting resolution changes no profile state');
select safety_test.expect_error($q$select safety_test.call(1,'card',safety_test.id(101))$q$,'not_found','','resolved report still hides original card from reporter');
select extensions.is(pg_catalog.jsonb_array_length(safety_test.call(1,op.name)->op.collection),1,'resolved report retains subject-wide ' || op.name || ' hide')
from (values ('feed','cards'),('favorites','cards'),('saved','links')) as op(name,collection);
select extensions.is(safety_test.call(5,'card',safety_test.id(105))->>'display_name','Person2','dismissal restores subject to nonreporter card');
select extensions.is(pg_catalog.jsonb_array_length(safety_test.call(5,op.name)->op.collection),1,'dismissal restores nonreporter ' || op.name)
from (values ('feed','cards'),('favorites','cards'),('saved','links')) as op(name,collection);
insert into results values ('new',safety_test.call(5,'report',safety_test.id(105),'harassment'));
select extensions.is((select value->>'status' from results where label='new'),'open','new distinct reporter can report after dismissal');
select extensions.is((select moderation_state from private.profiles where user_id=safety_test.id(2)),'active','three resolved allegations do not count toward open threshold');
select extensions.is(safety_test.call(235,'resolve',(select (value->>'report_id')::uuid from results where label='new'),null,null,'hidden'),
    pg_catalog.jsonb_build_object('report_id',(select value->'report_id' from results where label='new'),
        'status','resolved','outcome','hidden','moderation_state','hidden'),'new operator decision hides subject');
select extensions.is((select operator_outcome from private.profiles where user_id=safety_test.id(2)),'hidden','latest operative decision is recorded separately');
select extensions.is(safety_test.call(235,'resolve',(select (value->>'report_id')::uuid from results where label='first'),null,null,'dismissed')->>'moderation_state',
    'hidden','older same-outcome replay reports current moderation state');
select extensions.is((select pg_catalog.jsonb_build_array(moderation_state,operator_outcome) from private.profiles where user_id=safety_test.id(2)),
    '["hidden","hidden"]'::jsonb,'older idempotent repeat cannot overwrite later operative decision');
select extensions.is(safety_test.call(235,'queue'),'{"reports":[],"truncated":false}'::jsonb,'all reviewed rows remain outside queue');

-- Hidden/suspended review resolves subject-wide: 8 per outcome = 16 assertions.
create function safety_test.outcome_cases()
returns setof text language plpgsql set search_path = pg_catalog, extensions as $$
declare outcome_value text; first_report jsonb; response jsonb;
begin
    foreach outcome_value in array array['hidden','suspended'] loop
        perform safety_test.prepare();
        first_report := safety_test.call(1,'report',safety_test.id(101),'spam');
        perform safety_test.call(3,'report',safety_test.id(103),'harassment');
        response := safety_test.call(235,'resolve',(first_report->>'report_id')::uuid,null,null,outcome_value);
        return next extensions.is(response,pg_catalog.jsonb_build_object('report_id',first_report->'report_id',
            'status','resolved','outcome',outcome_value,'moderation_state',outcome_value),outcome_value || ': exact response');
        return next extensions.is((select operator_outcome from private.profiles where user_id=safety_test.id(2)),outcome_value,outcome_value || ': operative outcome');
        return next extensions.is((select moderation_state from private.profiles where user_id=safety_test.id(2)),outcome_value,outcome_value || ': subject state');
        return next extensions.is((select pg_catalog.count(*) from private.reports where status='resolved' and outcome=outcome_value),2::bigint,outcome_value || ': all subject rows resolved');
        return next extensions.ok((select pg_catalog.bool_and(resolved_day=safety_test.day()) from private.reports),outcome_value || ': UTC resolution date');
        return next extensions.is(safety_test.call(235,'resolve',(first_report->>'report_id')::uuid,null,null,outcome_value),response,outcome_value || ': repeat idempotent');
        return next safety_test.expect_error(pg_catalog.format('select safety_test.call(235,''resolve'',%L::uuid,null,null,''dismissed'')',first_report->>'report_id'),
            'invalid_input','outcome',outcome_value || ': conflicting outcome refused');
        return next safety_test.expect_error($q$select safety_test.call(5,'card',safety_test.id(105))$q$,'not_found','',outcome_value || ': observer denied');
    end loop;
end;
$$;
select * from safety_test.outcome_cases();

-- Every safety write uses the shared gate: 2 viewers x 6 denials = 12 assertions.
select safety_test.prepare();
update private.profiles set discovery_on=false where user_id=safety_test.id(2);
select safety_test.expect_error(pg_catalog.format('select safety_test.call(%s,%L,safety_test.id(101),''spam'')', viewer.n,op.name),
    'not_found','','discovery denial: ' || op.name)
from (values (1),(2)) as viewer(n) cross join (values ('block'),('report'),('delete')) as op(name);
update private.profiles set discovery_on=true where user_id=safety_test.id(2);
insert into private.blocks (blocker_id,blocked_id,placed_day) values (safety_test.id(2),safety_test.id(1),safety_test.day());
select safety_test.expect_error(pg_catalog.format('select safety_test.call(%s,%L,safety_test.id(101),''spam'')', viewer.n,op.name),
    'not_found','','either-direction block denial: ' || op.name)
from (values (1),(2)) as viewer(n) cross join (values ('block'),('report'),('delete')) as op(name);

-- Ten accepted reports in a rolling day: 17 assertions.
select safety_test.prepare();
select safety_test.make_encounter(200+n,1,n) from pg_catalog.generate_series(20,30) as n;
select extensions.is(safety_test.call(1,'report',safety_test.id(200+n),'spam')->>'status','open','daily budget: accepted report ' || n)
from pg_catalog.generate_series(20,29) as n;
select safety_test.expect_error($q$select safety_test.call(1,'report',safety_test.id(230),'other')$q$,'rate_limited','','eleventh accepted report refused');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events where user_id=safety_test.id(1) and bucket='report_encounter_person'),10::bigint,'budget records exactly ten committed events');
select extensions.is((select pg_catalog.count(*) from private.reports where reporter_id=safety_test.id(1)),10::bigint,'rate refusal inserts no report');
select safety_test.expect_error($q$select safety_test.call(1,'report',safety_test.id(220),'other')$q$,'not_found','','repeat is not_found even when budget is exhausted');
update private.account_limit_events set occurred_at=pg_catalog.now()-interval '24 hours'
where user_id=safety_test.id(1) and bucket='report_encounter_person'
  and ctid=(select ctid from private.account_limit_events where user_id=safety_test.id(1) and bucket='report_encounter_person' order by ctid limit 1);
select extensions.is(safety_test.call(1,'report',safety_test.id(230),'other')->>'status','open','event at exact 24-hour boundary frees one slot');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events where bucket='report_encounter_person'),10::bigint,'boundary event replaced by new accepted event');
select private.cleanup_expired_data(pg_catalog.now()+interval '2 hours');
select extensions.is((select pg_catalog.count(*) from private.account_limit_events where bucket='report_encounter_person'),10::bigint,'existing expiry cleanup preserves the daily report budget');

-- Block and operator queues cap only after ownership/status filtering: 14 assertions.
select safety_test.prepare();
insert into private.blocks (blocker_id,blocked_id,block_id,placed_day)
select safety_test.id(1),safety_test.id(n),safety_test.id(20000+n),safety_test.day()-(n-10)/100
from pg_catalog.generate_series(10,210) as n;
select extensions.is(pg_catalog.jsonb_array_length(safety_test.call(1,'blocks')->'blocks'),200,'201 own blocks cap at 200');
select extensions.is(safety_test.call(1,'blocks')->'truncated','true'::jsonb,'201 own blocks truncate');
select extensions.is(safety_test.call(1,'blocks')#>>'{blocks,0,block_id}',safety_test.id(20010)::text,'block order starts with newest day/smallest ID');
select extensions.is(safety_test.call(1,'blocks')#>>'{blocks,199,block_id}',safety_test.id(20209)::text,'block cap preserves placement-day/UUID order');
select extensions.ok(not exists (select 1 from pg_catalog.jsonb_array_elements(safety_test.call(1,'blocks')->'blocks') as b
    where (select pg_catalog.array_agg(k order by k) from pg_catalog.jsonb_object_keys(b) as k) <> array['block_id','placed_day']), 'capped block list contains no names/IDs/links');
delete from private.blocks where block_id=safety_test.id(20210);
select extensions.is(safety_test.call(1,'blocks')->'truncated','false'::jsonb,'exactly 200 blocks are not truncated');
select extensions.is(safety_test.call(2,'blocks'),'{"blocks":[],"truncated":false}'::jsonb,'foreign blocks do not affect caller cap');
insert into private.reports (report_id,reporter_id,subject_id,reason,review_due_at)
select safety_test.id(30000+n),safety_test.id(n),safety_test.id(2),'spam',pg_catalog.floor(extract(epoch from pg_catalog.now()))::bigint+259200+n
from pg_catalog.generate_series(10,210) as n;
select extensions.is(pg_catalog.jsonb_array_length(safety_test.call(235,'queue')->'reports'),200,'201 open reports cap at 200');
select extensions.is(safety_test.call(235,'queue')->'truncated','true'::jsonb,'201 open reports truncate');
select extensions.is(safety_test.call(235,'queue')#>>'{reports,0,report_id}',safety_test.id(30010)::text,'queue starts with earliest deadline');
select extensions.is(safety_test.call(235,'queue')#>>'{reports,199,report_id}',safety_test.id(30209)::text,'queue keeps deadline ordering at cap');
select extensions.ok(not exists (select 1 from pg_catalog.jsonb_array_elements(safety_test.call(235,'queue')->'reports') as r
    where (select pg_catalog.array_agg(k order by k) from pg_catalog.jsonb_object_keys(r) as k)
        <> array['encounter_id','link_id','reason','report_id','reporter_id','review_due_at','status','subject_id']), 'queue contains only contract references and review state');
update private.reports set status='resolved',outcome='dismissed',resolved_day=safety_test.day() where report_id=safety_test.id(30210);
select extensions.is(safety_test.call(235,'queue')->'truncated','false'::jsonb,'resolved sentinel does not truncate 200 open reports');
select extensions.is(pg_catalog.jsonb_array_length(safety_test.call(235,'queue')->'reports'),200,'queue retains all 200 open reports');

-- Link/encounter context loss and automatic reactivation prohibition: 9 assertions.
select safety_test.prepare();
insert into results values ('context',safety_test.call(1,'report',safety_test.id(101),'impersonation',safety_test.link_id(2)));
delete from private.external_links where link_id=safety_test.link_id(2);
select extensions.ok((select link_id is null from private.reports),'removed link context becomes null');
select extensions.is((select pg_catalog.count(*) from private.reports),1::bigint,'link deletion retains report');
select safety_test.expect_error($q$select safety_test.call(1,'card',safety_test.id(102))$q$,'not_found','','link deletion retains reporter hide');
select extensions.is(safety_test.call(2,'delete',safety_test.id(101)),'{"deleted":true}'::jsonb,'subject can delete shared encounter without a reporter-side hide');
select extensions.ok((select encounter_id is null from private.reports),'removed encounter context becomes null');
select extensions.is(safety_test.call(235,'queue')#>'{reports,0}',pg_catalog.jsonb_build_object(
    'report_id',(select value->'report_id' from results where label='context'), 'reporter_id',safety_test.id(1), 'subject_id',safety_test.id(2),
    'encounter_id',null,'link_id',null,'reason','impersonation','status','open',
    'review_due_at',pg_catalog.floor(extract(epoch from pg_catalog.now()))::bigint+259200),'operator reads null references without a snapshot');
select safety_test.expect_error($q$select safety_test.call(1,'delete',safety_test.id(102))$q$,'not_found','','reporter cannot remove a hidden encounter');
select safety_test.call(3,'report',safety_test.id(103),'spam');
select safety_test.call(4,'report',safety_test.id(104),'other');
delete from auth.users where id=safety_test.id(4);
select extensions.is((select moderation_state from private.profiles where user_id=safety_test.id(2)),'hidden','reporter deletion never reactivates subject');
delete from private.reports where subject_id=safety_test.id(2);
select extensions.is((select moderation_state from private.profiles where user_id=safety_test.id(2)),'hidden','removal of all reports never reactivates subject');

select * from extensions.finish();
rollback;
