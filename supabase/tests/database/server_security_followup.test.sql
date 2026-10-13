begin;
create extension if not exists pgtap with schema extensions;
create schema followup_test;
grant usage on schema followup_test to authenticated, service_role;

create function followup_test.id(n integer)
returns uuid language sql immutable set search_path = '' as $$
    select ('c5c5c5c5-0000-0000-0000-' || pg_catalog.lpad(n::text,12,'0'))::uuid;
$$;
create function followup_test.code(n integer)
returns text language sql immutable set search_path = '' as $$ select pg_catalog.lpad(n::text,32,'0'); $$;
create function followup_test.call(n integer, statement text, as_service boolean default false)
returns jsonb language plpgsql set search_path = '' as $$
declare result jsonb;
begin
    begin
        if as_service then set local role service_role; else set local role authenticated; end if;
        perform pg_catalog.set_config('request.jwt.claim.sub','',true);
        perform pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object(
            'sub',followup_test.id(n),'role','authenticated')::text,true);
        execute statement into result;
    exception when others then reset role; raise; end;
    reset role;
    return result;
end;
$$;
create function followup_test.error(statement text, code text, detail text, description text)
returns text language plpgsql set search_path = pg_catalog, extensions as $$
declare actual_state text; actual_code text; actual_detail text;
begin
    begin execute statement;
    exception when others then
        get stacked diagnostics actual_state=returned_sqlstate,actual_code=message_text,actual_detail=pg_exception_detail;
        return extensions.is(pg_catalog.jsonb_build_array(actual_state,actual_code,coalesce(actual_detail,'')),
            pg_catalog.jsonb_build_array('P0001'::text,code,detail),description);
    end;
    return extensions.fail(description || ': expected exception');
end;
$$;
create function followup_test.stale(n integer)
returns void language plpgsql set search_path = '' as $$
begin
    update private.external_links set source='github',source_item_id=(8000+n)::text,
        url='https://github.com/fixture/repo',verification_state='verified' where owner_id=followup_test.id(n);
    insert into private.linked_identities(user_id,provider,provider_user_id,handle)
    values (followup_test.id(n),'github',(9000+n)::text,'fixture');
    -- An identity cache without live Auth evidence must never count.
    update private.profiles set discovery_on=true where user_id=followup_test.id(n);
    insert into private.sessions(session_id,user_id,starts_at,expires_at)
    values (followup_test.id(1000+n),followup_test.id(n),pg_catalog.clock_timestamp(),pg_catalog.clock_timestamp()+interval '1 hour');
    insert into private.qr_codes(code_digest,issuer_id,expires_at)
    values (pg_catalog.sha256(pg_catalog.decode(followup_test.code(n),'hex')),followup_test.id(n),
        pg_catalog.floor(extract(epoch from pg_catalog.clock_timestamp()))::bigint+120);
end;
$$;
create function followup_test.state(n integer)
returns jsonb language sql stable set search_path = '' as $$
    select pg_catalog.jsonb_build_object('discovery',(select p.discovery_on from private.profiles as p where p.user_id=followup_test.id(n)),
        'session',(select pg_catalog.to_jsonb(s) from private.sessions as s where s.session_id=followup_test.id(1000+n)),
        'qr',(select pg_catalog.to_jsonb(q) from private.qr_codes as q where q.issuer_id=followup_test.id(n)));
$$;
create function followup_test.observed()
returns bigint language sql stable set search_path = '' as $$
    select (pg_catalog.floor(extract(epoch from pg_catalog.now())/900)*900)::bigint-300;
$$;
create function followup_test.receipt(side integer, peer integer)
returns jsonb language sql stable set search_path = '' as $$
    select pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('id',followup_test.id(2000+side),'protocol_version',1,
        'role',case when side < peer then 'central' else 'peripheral' end,'exchange_nonce',pg_catalog.md5('followup-exchange'),
        'start',pg_catalog.jsonb_build_object('own_token',followup_test.code(side),'peer_token',followup_test.code(peer),
            'observed_at',followup_test.observed()),
        'checkpoint',pg_catalog.jsonb_build_object('own_token',followup_test.code(side),'peer_token',followup_test.code(peer),
            'observed_at',followup_test.observed()+120),
        'observed_duration',120,'session_flag',false,'is_final_evidence',true));
$$;
grant execute on function followup_test.id(integer), followup_test.code(integer), followup_test.receipt(integer,integer),
    followup_test.observed() to authenticated, service_role;

insert into auth.users(id) select followup_test.id(n) from pg_catalog.generate_series(1,10) as n;
insert into private.profiles(user_id,display_name,introduction,age_18_declared,terms_version,privacy_version,discovery_on)
select followup_test.id(n),'Name','Introduction',true,'draft','draft',true from pg_catalog.generate_series(1,10) as n;
insert into private.notification_preferences(user_id,time_zone)
select followup_test.id(n),'UTC' from pg_catalog.generate_series(1,10) as n;
insert into private.external_links(link_id,owner_id,source,url,title,visibility)
select followup_test.id(100+n),followup_test.id(n),'other','https://example.invalid/link','Link','everyone_eligible'
from pg_catalog.generate_series(1,10) as n;
update private.server_settings set environment='local',demo_reveal_enabled=true,operator_account_id=followup_test.id(10);
create temporary table followup_results(label text primary key,value jsonb);

-- Rejected discovery calls/gate 7 + profile cleanup 8 + session cleanup 7
-- + fallible zones 11 + renewed moderation 9 + stale saved references 9 = 51.
select extensions.plan(51);

-- Rejected calls assert their errors only. Exception transactions cannot persist cleanup.
select followup_test.stale(1);
insert into private.qr_codes(code_digest,issuer_id,expires_at)
values (pg_catalog.sha256(pg_catalog.decode(followup_test.code(2),'hex')),followup_test.id(2),
    pg_catalog.floor(extract(epoch from pg_catalog.clock_timestamp()))::bigint+120);
select followup_test.error(pg_catalog.format('select followup_test.call(1,%L)',statement),
    'prerequisite_missing','discovery',label || ': sole stale GitHub link means discovery off')
from (values ('select public.start_session()','start'),('select public.issue_qr_code()','issue'),
    ('select public.redeem_qr_code(followup_test.code(2))','redeemer'),
    ('select public.get_encounter_feed()','feed'),('select public.reveal_ambient_now()','demo')) as t(statement,label);
select followup_test.error('select followup_test.call(2,''select public.redeem_qr_code(followup_test.code(1))'')',
    'not_found','','stale issuer code is unavailable, just like an issuer with discovery off');
insert into private.encounters(encounter_id,user_a,user_b,kind,day_a,day_b)
values (followup_test.id(301),followup_test.id(1),followup_test.id(2),'session',current_date,current_date);
insert into private.encounter_views(encounter_id,viewer_id,revealed,reveal_report_day)
values (followup_test.id(301),followup_test.id(2),true,current_date);
select extensions.is(followup_test.call(2,'select public.get_encounter_feed()'),'{"cards":[],"truncated":false}'::jsonb,
    'feed counterpart gate treats sole stale GitHub evidence as discovery off');

-- Successful own profile read reconciles discovery before computing its fields.
insert into followup_results values ('profile',followup_test.call(1,'select public.get_own_profile()'));
select extensions.is((select value->'discovery_on' from followup_results where label='profile'),'false'::jsonb,'own profile reports effective discovery off');
select extensions.is((select value->'link_count' from followup_results where label='profile'),'0'::jsonb,'own profile excludes stale GitHub links from count');
select extensions.is((select value#>'{prerequisites,link}' from followup_results where label='profile'),'false'::jsonb,'own profile reports unmet link prerequisite');
select extensions.is((select discovery_on from private.profiles where user_id=followup_test.id(1)),false,'profile read persists the switch off');
select extensions.ok((select stopped_at>=starts_at from private.sessions where session_id=followup_test.id(1001)),'profile read stops the active session using wall time');
select extensions.is((select pg_catalog.count(*) from private.qr_codes where issuer_id=followup_test.id(1)),0::bigint,'profile read deletes outstanding QR');
insert into followup_results values ('profile-state',followup_test.state(1));
select extensions.ok(followup_test.call(1,'select public.get_own_profile()')=(select value from followup_results where label='profile')
    and followup_test.state(1)=(select value from followup_results where label='profile-state'),'repeat profile read changes neither answer nor cleanup state');
select extensions.ok(exists(select 1 from pg_catalog.pg_locks where pid=pg_catalog.pg_backend_pid() and locktype='advisory'
    and classid=31001 and objid=(pg_catalog.hashtext(followup_test.id(1)::text)::bigint & 4294967295)::oid and objsubid=2),
    'profile reader holds the caller account advisory lock');

-- Separate fixture proves successful own session reads reconcile without a profile read.
select followup_test.stale(3);
select extensions.is(followup_test.call(3,'select public.get_own_session()'),'null'::jsonb,'own session read returns null after reconciliation');
select extensions.is((select discovery_on from private.profiles where user_id=followup_test.id(3)),false,'session read persists the switch off');
select extensions.ok((select stopped_at>=starts_at from private.sessions where session_id=followup_test.id(1003)),'session read stops the active ledger');
select extensions.is((select pg_catalog.count(*) from private.qr_codes where issuer_id=followup_test.id(3)),0::bigint,'session read deletes outstanding QR');
insert into followup_results values ('session-state',followup_test.state(3));
select extensions.is(followup_test.call(3,'select public.get_own_session()'),'null'::jsonb,'second session read stays null');
select extensions.is(followup_test.state(3),(select value from followup_results where label='session-state'),'second session read changes nothing');
select extensions.ok(exists(select 1 from pg_catalog.pg_locks where pid=pg_catalog.pg_backend_pid() and locktype='advisory'
    and classid=31001 and objid=(pg_catalog.hashtext(followup_test.id(3)::text)::bigint & 4294967295)::oid and objsubid=2),
    'session reader holds the caller account advisory lock');

-- A stale catalogue entry can name a zone unavailable to installed tzdata.
insert into private.iana_time_zones(name) values ('Followup/Unavailable');
insert into private.temporary_tokens(token_digest,user_id,batch_id,valid_from,valid_until,delete_after)
select pg_catalog.sha256(pg_catalog.decode(followup_test.code(n),'hex')),followup_test.id(n),followup_test.id(n),w,w+900,w+173700
from (values (4),(5)) as t(n) cross join (select (pg_catalog.floor(followup_test.observed()::numeric/900)*900)::bigint as w) as b;
select extensions.is(followup_test.call(4,'select public.submit_receipts(followup_test.receipt(4,5))')#>>'{0,status}',
    'candidate','first reciprocal upload waits');
update private.notification_preferences set time_zone='Followup/Unavailable',report_hour=1 where user_id=followup_test.id(4);
select extensions.is(followup_test.call(5,'select public.submit_receipts(followup_test.receipt(5,4))')#>>'{0,status}',
    'resolved','upload resolves even with an unusable counterpart zone');
select extensions.is((select day_a from private.encounters where user_a=followup_test.id(4) and user_b=followup_test.id(5)),
    pg_catalog.timezone('UTC',pg_catalog.to_timestamp(followup_test.observed()::double precision))::date,'upload counterpart day falls back to UTC');
select extensions.is(private.next_report_day(followup_test.id(4),pg_catalog.now()),private.next_report_day(followup_test.id(5),pg_catalog.now()),
    'unusable zone uses the missing-preferences UTC/21:00 next-report fallback');
insert into followup_results values ('zone-code',followup_test.call(4,'select public.issue_qr_code()'));
insert into followup_results select 'zone-qr',followup_test.call(5,pg_catalog.format('select public.redeem_qr_code(%L)',value->>'code'))
from followup_results where label='zone-code';
select extensions.ok((select value ? 'encounter_id' from followup_results where label='zone-qr'),'redemption succeeds with an unusable issuer zone');
select extensions.is((select e.day_a from private.encounters as e join followup_results as r on e.encounter_id=(r.value->>'encounter_id')::uuid
    where r.label='zone-qr'),pg_catalog.timezone('UTC',pg_catalog.now())::date,'QR counterpart day falls back to UTC');
select followup_test.error('select private.local_report_instant(followup_test.id(4),current_date)','account_not_ready','',
    'own report scheduling treats an unusable zone as missing');
select extensions.is(private.latest_due_report_day('Followup/Unavailable',21,0,pg_catalog.now()),null::date,'due-report selector skips an unusable zone');
select extensions.is(private.report_instant_in_zone(current_date,21,0,'Followup/Unavailable'),null::timestamptz,'fallible report conversion never raises a raw zone error');
select followup_test.error('select followup_test.call(4,''select public.register_time_zone(''''Followup/Unavailable'''')'')',
    'invalid_input','time_zone','registration refuses an unusable catalogue entry');
-- Favorite retention makes the pair available even when the caller zone is unusable.
update private.encounter_views set favorite=true where viewer_id=followup_test.id(4) and encounter_id=
    (select (value->>'encounter_id')::uuid from followup_results where label='zone-qr');
select extensions.is(followup_test.call(4,pg_catalog.format('select public.block_encounter_person(%L::uuid)',value->>'encounter_id'))->>'placed_day',
    pg_catalog.timezone('UTC',pg_catalog.now())::date::text,'block placement also falls back to UTC for an unusable stored zone')
from followup_results where label='zone-qr';

-- A second automatic hide supersedes dismissal; open reports also outrank reviewed accounts.
update private.profiles set moderation_state='hidden' where user_id=followup_test.id(8);
select extensions.is(followup_test.call(10,'select service.review_account(followup_test.id(10),followup_test.id(8),''dismissed'')',true)->>'moderation_state',
    'active','operator dismisses subject once');
update private.profiles set moderation_state='suspended',operator_outcome='suspended' where user_id=followup_test.id(2);
insert into private.encounters(encounter_id,user_a,user_b,kind,day_a,day_b)
select followup_test.id(400+n),least(followup_test.id(n),followup_test.id(8)),greatest(followup_test.id(n),followup_test.id(8)),
    'session',current_date,current_date from (values (6),(7),(9)) as t(n);
insert into private.encounter_views(encounter_id,viewer_id,revealed,reveal_report_day)
select followup_test.id(400+n),followup_test.id(n),true,current_date from (values (6),(7),(9)) as t(n);
select extensions.is(followup_test.call(n,pg_catalog.format('select public.report_encounter_person(%L::uuid,''spam'')',followup_test.id(400+n)))->>'status',
    'open','new reporter ' || n || ' is accepted after the dismissal') from (values (6),(7),(9)) as t(n);
select extensions.is((select pg_catalog.jsonb_build_array(moderation_state,operator_outcome) from private.profiles where user_id=followup_test.id(8)),
    '["hidden",null]'::jsonb,'renewed automatic hide clears the obsolete dismissal without recording a sanction');
select extensions.is(followup_test.call(10,'select service.list_moderated_accounts(followup_test.id(10))',true)#>>'{accounts,0,account_id}',
    followup_test.id(8)::text,'newly hidden dismissed account precedes a lower-ID reviewed account');
delete from private.reports where subject_id=followup_test.id(8);
select extensions.is(followup_test.call(10,'select service.list_moderated_accounts(followup_test.id(10))',true)#>>'{accounts,0,account_id}',
    followup_test.id(8)::text,'renewed hide still awaits review after its reporters disappear');
insert into private.reports(reporter_id,subject_id,reason,review_due_at)
values (followup_test.id(6),followup_test.id(2),'spam',1);
select extensions.is(followup_test.call(10,'select service.list_moderated_accounts(followup_test.id(10))',true)#>>'{accounts,0,account_id}',
    followup_test.id(2)::text,'an open report outranks reviewed status even with a non-null operator outcome');
delete from private.reports where subject_id=followup_test.id(2);
select extensions.is((select moderation_state from private.profiles where user_id=followup_test.id(8)),'hidden','automatic report removal never reactivates');

-- A private fallback link preserves discovery, but cannot retain a stale saved GitHub link.
update private.external_links set source='github',source_item_id='8007',url='https://github.com/fixture/repo',verification_state='verified'
where link_id=followup_test.id(107);
insert into private.external_links(owner_id,source,url,title,visibility)
values (followup_test.id(7),'other','https://example.invalid/fallback','Fallback','private');
insert into auth.identities(id,user_id,provider,provider_id,identity_data)
values (followup_test.id(9007),followup_test.id(7),'github','9007','{"sub":"9007"}');
insert into private.linked_identities(user_id,provider,provider_user_id,handle)
values (followup_test.id(7),'github','9007','fixture');
insert into private.encounters(encounter_id,user_a,user_b,kind,day_a,day_b)
select followup_test.id(500+n),followup_test.id(6),followup_test.id(7),kind,current_date-40,current_date-40
from (values (1,'session'),(2,'ambient')) as t(n,kind);
insert into private.encounter_views(encounter_id,viewer_id,revealed,reveal_report_day)
select followup_test.id(500+n),followup_test.id(v),n=1,current_date-39 from (values (1),(2)) as t(n) cross join (values (6),(7)) as p(v);
insert into private.saved_links(viewer_id,encounter_id,link_id)
values (followup_test.id(6),followup_test.id(501),followup_test.id(107)),(followup_test.id(6),followup_test.id(502),followup_test.id(107));
select extensions.ok(followup_test.call(6,'select public.get_encounter_card(followup_test.id(501))') ? 'links','currently visible saved link retains the expired encounter');
delete from auth.identities where user_id=followup_test.id(7) and provider='github';
select followup_test.error('select followup_test.call(6,''select public.get_encounter_card(followup_test.id(501))'')',
    'not_found','','stale saved link no longer retains the expired encounter');
select extensions.is(followup_test.call(6,'select public.list_saved_links()'),'{"links":[],"truncated":false}'::jsonb,'stale saved metadata stays hidden');
select extensions.is(followup_test.call(6,'select public.unsave_link(followup_test.id(501),followup_test.id(107))')->'saved','false'::jsonb,
    'participant can unsave a reference after link verification and retention are lost');
select extensions.is((select pg_catalog.count(*) from private.saved_links where viewer_id=followup_test.id(6) and encounter_id=followup_test.id(501)),
    0::bigint,'unsave actually removes the stale reference');
insert into private.saved_links(viewer_id,encounter_id,link_id)
values (followup_test.id(6),followup_test.id(501),followup_test.id(107)),(followup_test.id(9),followup_test.id(501),followup_test.id(107));
select followup_test.error('select followup_test.call(9,''select public.unsave_link(followup_test.id(501),followup_test.id(107))'')',
    'not_found','','a nonparticipant cannot drop a reference on somebody else''s encounter');
select extensions.is((select pg_catalog.count(*) from private.waiting_ambient_views(followup_test.id(6),pg_catalog.now()) where encounter_id=followup_test.id(502)),
    0::bigint,'a stale saved reference cannot retain a waiting ambient view');
select private.cleanup_retained_data();
select extensions.is((select pg_catalog.count(*) from private.encounters where encounter_id in (followup_test.id(501),followup_test.id(502))),
    0::bigint,'physical retention ignores stale saved references on both kinds');
select extensions.is((select pg_catalog.count(*) from private.saved_links where encounter_id in (followup_test.id(501),followup_test.id(502))),
    0::bigint,'ignored references cascade when the expired encounter is removed');

select * from extensions.finish();
rollback;
