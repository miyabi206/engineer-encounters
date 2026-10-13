begin;
create extension if not exists pgtap with schema extensions;
create schema visibility_review_test;
grant usage on schema visibility_review_test to authenticated, service_role;

create function visibility_review_test.id(n integer)
returns uuid language sql immutable set search_path = '' as $$
    select ('91919191-0000-0000-0000-' || pg_catalog.lpad(n::text,12,'0'))::uuid;
$$;
create function visibility_review_test.call(n integer, statement text)
returns jsonb language plpgsql set search_path = '' as $$
declare result jsonb;
begin
    begin
        set local role authenticated;
        perform pg_catalog.set_config('request.jwt.claim.sub','',true);
        perform pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object(
            'sub',visibility_review_test.id(n),'role','authenticated')::text,true);
        execute statement into result;
    exception when others then reset role; raise; end;
    reset role;
    return result;
end;
$$;
create function visibility_review_test.discovery(n integer)
returns void language plpgsql set search_path = '' as $$
begin
    begin
        set local role authenticated;
        perform pg_catalog.set_config('request.jwt.claim.sub','',true);
        perform pg_catalog.set_config('request.jwt.claims',pg_catalog.jsonb_build_object(
            'sub',visibility_review_test.id(n),'role','authenticated')::text,true);
        perform public.set_discovery(true);
    exception when others then reset role; raise; end;
    reset role;
end;
$$;
create function visibility_review_test.service_call(statement text)
returns jsonb language plpgsql set search_path = '' as $$
declare result jsonb;
begin
    begin
        set local role service_role;
        execute statement into result;
    exception when others then reset role; raise; end;
    reset role;
    return result;
end;
$$;
create function visibility_review_test.error(statement text, code text, detail text, description text)
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
create function visibility_review_test.ids(response jsonb)
returns jsonb language sql immutable set search_path = '' as $$
    select coalesce(pg_catalog.jsonb_agg(c.value->'encounter_id' order by c.position),'[]'::jsonb)
    from pg_catalog.jsonb_array_elements(response->'cards') with ordinality as c(value,position);
$$;
-- Compare the entire response, including its dedup winner and truncation flag.
-- Demo sees the same encounters as the three readers after resetting reveal.
create function visibility_review_test.capture()
returns jsonb language plpgsql set search_path = '' as $$
declare result jsonb;
begin
    result := pg_catalog.jsonb_build_object(
        'feed',visibility_review_test.call(1,'select public.get_encounter_feed()'),
        'favorites',visibility_review_test.call(1,'select public.list_encounter_favorites()'),
        'daily',visibility_review_test.call(1,'select public.get_daily_report()'));
    update private.encounter_views set revealed=false,revealed_report_day=null
    where viewer_id=visibility_review_test.id(1);
    result := result || pg_catalog.jsonb_build_object('demo',
        visibility_review_test.call(1,'select public.reveal_ambient_now()'));
    update private.encounter_views set revealed_report_day=(pg_catalog.now() at time zone 'UTC')::date
    where viewer_id=visibility_review_test.id(1);
    return result;
end;
$$;
grant execute on all functions in schema visibility_review_test to authenticated, service_role;

insert into auth.users(id) select visibility_review_test.id(n) from pg_catalog.generate_series(1,205) as n;
insert into private.profiles(user_id,age_18_declared,terms_version,privacy_version,discovery_on,display_name,introduction)
select visibility_review_test.id(n),true,'draft','draft',true,'Owner'||n,'Introduction' from pg_catalog.generate_series(1,205) as n;
insert into private.notification_preferences(user_id,time_zone,report_hour,report_minute)
select visibility_review_test.id(n),'UTC',0,0 from pg_catalog.generate_series(1,205) as n;
insert into private.interests(interest_id,label_ja,label_en) values ('review-a','a','a'),('review-b','b','b');
insert into private.user_interests(user_id,interest_id)
select visibility_review_test.id(n),i from pg_catalog.generate_series(1,205) as n
cross join pg_catalog.unnest(array['review-a','review-b']) as i where n<>3 or i='review-a';
insert into private.user_purposes(user_id,purpose)
select visibility_review_test.id(n),'discovery' from pg_catalog.generate_series(1,205) as n;
insert into private.field_visibility(owner_id,field,level)
select visibility_review_test.id(n),f,case when f='display_name' or (f='interests' and n=3)
    then 'everyone_eligible' else 'private' end
from pg_catalog.generate_series(1,205) as n cross join pg_catalog.unnest(array['display_name','interests','purposes']) as f;
insert into private.external_links(link_id,owner_id,source,source_item_id,url,title,visibility,verification_state)
select visibility_review_test.id(1000+n),visibility_review_test.id(n),case when n=2 then 'github' else 'other' end,
    case when n=2 then '9002' else null end,
    case when n=2 then 'https://github.com/owner/repo' else 'https://example.invalid/fixture' end,'Link',
    case when n=2 then 'everyone_eligible' else 'private' end,case when n=2 then 'verified' else 'unverified' end
from pg_catalog.generate_series(1,205) as n;
insert into private.external_links(link_id,owner_id,source,url,title,visibility)
values (visibility_review_test.id(2002),visibility_review_test.id(2),'other','https://example.invalid/fallback','Fallback','private');
insert into auth.identities(id,user_id,provider,provider_id,identity_data)
values (visibility_review_test.id(8002),visibility_review_test.id(2),'github','91002','{"sub":"91002"}');
insert into private.linked_identities(user_id,provider,provider_user_id,handle)
values (visibility_review_test.id(2),'github','91002','owner');
insert into private.encounters(encounter_id,user_a,user_b,kind,day_a,day_b)
select visibility_review_test.id(10000+n),visibility_review_test.id(1),visibility_review_test.id(n),'ambient',
    (pg_catalog.now() at time zone 'UTC')::date,(pg_catalog.now() at time zone 'UTC')::date
from pg_catalog.generate_series(2,3) as n;
insert into private.encounter_views(encounter_id,viewer_id,revealed,reveal_report_day,favorite,revealed_report_day)
select visibility_review_test.id(10000+n),visibility_review_test.id(1),true,(pg_catalog.now() at time zone 'UTC')::date,true,
    (pg_catalog.now() at time zone 'UTC')::date from pg_catalog.generate_series(2,3) as n;
insert into private.report_deliveries(user_id,report_day,status)
values (visibility_review_test.id(1),(pg_catalog.now() at time zone 'UTC')::date,'closed');
update private.server_settings set environment='local',demo_reveal_enabled=true where singleton;
create temporary table visibility_results(label text primary key,value jsonb);

-- Ordering 12 + cap/dedup 6 + independent Auth unlink/cache loss 28 = 46.
select extensions.plan(46);

-- Owner 3 is a colluding reference with one visible common interest. Owner 2
-- has two hidden common interests and a smaller encounter ID, but sorts second.
insert into visibility_results values ('private',visibility_review_test.capture());
select extensions.is(visibility_review_test.ids((select value->op from visibility_results where label='private')),
    pg_catalog.jsonb_build_array(visibility_review_test.id(10003),visibility_review_test.id(10002)),
    op || ': only the visible intersection sorts ahead of the reference UUID')
from (values ('feed'),('favorites'),('daily'),('demo')) as t(op);
select extensions.is((select shared_interest_count from private.visible_encounter_facts(
    visibility_review_test.id(1),array[visibility_review_test.id(10002)],false)),0,
    'hidden interests contribute zero to pre-cap sort facts');
delete from private.user_interests where user_id=visibility_review_test.id(2) and interest_id='review-b';
select extensions.is(visibility_review_test.capture(),(select value from visibility_results where label='private'),
    'changing hidden interests cannot move a card relative to a colluding reference');
insert into private.user_interests values (visibility_review_test.id(2),'review-b');
update private.user_purposes set purpose='collaboration' where user_id=visibility_review_test.id(2);
select extensions.is(visibility_review_test.capture(),(select value from visibility_results where label='private'),
    'changing hidden purposes and compatibility cannot move a card relative to a reference');
update private.field_visibility set level='compatible_only' where owner_id=visibility_review_test.id(2) and field='interests';
select extensions.is(visibility_review_test.capture(),(select value from visibility_results where label='private'),
    'unauthorized compatible-only interests have zero sort count');
update private.field_visibility set level='everyone_eligible' where owner_id=visibility_review_test.id(2) and field='interests';
insert into visibility_results values ('visible',visibility_review_test.capture());
select extensions.is(visibility_review_test.ids((select value->op from visibility_results where label='visible')),
    pg_catalog.jsonb_build_array(visibility_review_test.id(10002),visibility_review_test.id(10003)),
    op || ': an incompatible card with two visible common interests sorts first')
from (values ('feed'),('favorites'),('daily'),('demo')) as t(op);
update private.field_visibility set level='private' where owner_id=visibility_review_test.id(2) and field='interests';
update private.user_purposes set purpose='discovery' where user_id=visibility_review_test.id(2);

insert into private.encounters(encounter_id,user_a,user_b,kind,day_a,day_b)
select visibility_review_test.id(10000+n),visibility_review_test.id(1),visibility_review_test.id(n),'ambient',
    (pg_catalog.now() at time zone 'UTC')::date,(pg_catalog.now() at time zone 'UTC')::date
from pg_catalog.generate_series(4,205) as n;
insert into private.encounter_views(encounter_id,viewer_id,revealed,reveal_report_day,favorite,revealed_report_day)
select visibility_review_test.id(10000+n),visibility_review_test.id(1),true,(pg_catalog.now() at time zone 'UTC')::date,true,
    (pg_catalog.now() at time zone 'UTC')::date from pg_catalog.generate_series(4,205) as n;
insert into visibility_results values ('cap',visibility_review_test.capture());
select extensions.is((select value#>>'{feed,cards,199,encounter_id}' from visibility_results where label='cap'),
    visibility_review_test.id(10201)::text,'visible-count/UUID sort fixes the truncation boundary');
select extensions.is((select value#>'{feed,truncated}' from visibility_results where label='cap'),'true'::jsonb,
    '204 authorized winners are truncated');
delete from private.user_interests where user_id=visibility_review_test.id(201);
select extensions.is(visibility_review_test.capture(),(select value from visibility_results where label='cap'),
    'hidden interest changes at the boundary leave all four capped responses unchanged');
update private.user_purposes set purpose='collaboration' where user_id=visibility_review_test.id(205);
select extensions.is(visibility_review_test.capture(),(select value from visibility_results where label='cap'),
    'hidden purposes beyond the boundary leave all four capped responses unchanged');
insert into private.encounters(encounter_id,user_a,user_b,kind,day_a,day_b)
values (visibility_review_test.id(30002),visibility_review_test.id(1),visibility_review_test.id(2),'ambient',
    (pg_catalog.now() at time zone 'UTC')::date,(pg_catalog.now() at time zone 'UTC')::date+1);
insert into private.encounter_views(encounter_id,viewer_id,revealed,reveal_report_day,favorite,revealed_report_day)
values (visibility_review_test.id(30002),visibility_review_test.id(1),true,(pg_catalog.now() at time zone 'UTC')::date,true,
    (pg_catalog.now() at time zone 'UTC')::date);
select extensions.is(visibility_review_test.capture(),(select value from visibility_results where label='cap'),
    'dedup chooses the same favorite/UUID winner before truncation');
delete from private.user_interests where user_id=visibility_review_test.id(2);
select extensions.is(visibility_review_test.capture(),(select value from visibility_results where label='cap'),
    'hidden interests change neither the dedup winner nor truncation');
insert into private.user_interests values (visibility_review_test.id(2),'review-a'),(visibility_review_test.id(2),'review-b');
delete from private.encounters where encounter_id<>visibility_review_test.id(10002);

select extensions.is(visibility_review_test.call(2,'select public.list_own_links()')#>>'{0,verification_state}',
    'verified','matching managed identity verifies the owner link');
select extensions.is(visibility_review_test.call(1,'select public.get_encounter_card(visibility_review_test.id(10002))')#>>'{links,0,verification_state}',
    'verified','matching managed identity exposes verified repository evidence');
select extensions.is(visibility_review_test.call(1,'select public.save_link(visibility_review_test.id(10002),visibility_review_test.id(1002))')->'saved',
    'true'::jsonb,'matching managed identity allows saving repository evidence');
select extensions.is(visibility_review_test.call(1,'select public.list_saved_links()')#>>'{links,0,link,link_id}',
    visibility_review_test.id(1002)::text,'saved read resolves the current repository');
-- Direct Auth unlink; keep the app cache, repository row and saved reference.
delete from auth.identities where user_id=visibility_review_test.id(2) and provider='github';
select extensions.ok(exists(select 1 from private.linked_identities where user_id=visibility_review_test.id(2))
    and exists(select 1 from private.saved_links where link_id=visibility_review_test.id(1002)),
    'direct Auth unlink leaves the cache and saved reference intact');
select extensions.is(visibility_review_test.call(2,'select public.list_own_links()')#>>'{0,verification_state}',
    'unverified','owner retains the row but sees it as unverified after Auth unlink');
select extensions.ok(not (visibility_review_test.call(1,'select public.get_encounter_card(visibility_review_test.id(10002))') ? 'links'),
    'other-source private link preserves eligibility while stale GitHub evidence disappears');
select extensions.is(visibility_review_test.call(1,'select public.list_saved_links()'),'{"links":[],"truncated":false}'::jsonb,
    'direct Auth unlink hides the saved repository without deleting its reference');
select visibility_review_test.error('select visibility_review_test.call(1,''select public.save_link(visibility_review_test.id(10002),visibility_review_test.id(1002))'')',
    'not_found','','direct Auth unlink refuses even an idempotent save');
select extensions.lives_ok('select visibility_review_test.discovery(2)','remaining other-source link still counts for discovery');
delete from private.external_links where link_id=visibility_review_test.id(2002);
select visibility_review_test.error('select visibility_review_test.call(1,''select public.get_encounter_card(visibility_review_test.id(10002))'')',
    'not_found','','account with no countable link is treated as discovery off');
insert into visibility_results values ('unlinked',visibility_review_test.capture());
select extensions.is(visibility_review_test.ids((select value->op from visibility_results where label='unlinked')),'[]'::jsonb,
    op || ': account with only stale GitHub evidence is ineligible')
from (values ('feed'),('favorites'),('daily'),('demo')) as t(op);
select visibility_review_test.error('select visibility_review_test.discovery(2)','prerequisite_missing','link',
    'stale repository row does not meet the discovery link prerequisite');
select extensions.ok((select discovery_on from private.profiles where user_id=visibility_review_test.id(2)),
    'eligibility fails closed without rewriting the discovery setting');
select extensions.is(visibility_review_test.call(2,'select public.list_own_links()')#>>'{0,verification_state}',
    'unverified','owner can still inspect its sole stale row while ineligible');
insert into auth.identities(id,user_id,provider,provider_id,identity_data)
values (visibility_review_test.id(8002),visibility_review_test.id(2),'github','91002','{"sub":"91002"}');
select extensions.is(visibility_review_test.call(1,'select public.get_encounter_card(visibility_review_test.id(10002))')#>>'{links,0,verification_state}',
    'verified','relink to the matching identity restores card eligibility and verification');
select extensions.is(visibility_review_test.call(2,'select public.list_own_links()')#>>'{0,verification_state}',
    'verified','relink restores verification in owner reads');
select extensions.lives_ok('select visibility_review_test.discovery(2)','relinked repository counts again for discovery');
select extensions.is(visibility_review_test.call(1,'select public.list_saved_links()')#>>'{links,0,link,link_id}',
    visibility_review_test.id(1002)::text,'relink restores the original saved reference');
select extensions.is(visibility_review_test.call(1,'select public.save_link(visibility_review_test.id(10002),visibility_review_test.id(1002))')->'saved',
    'true'::jsonb,'relink permits saving the same reference again');
-- Live Auth without a matching cache is insufficient too.
delete from private.linked_identities where user_id=visibility_review_test.id(2);
select visibility_review_test.error('select visibility_review_test.call(1,''select public.get_encounter_card(visibility_review_test.id(10002))'')',
    'not_found','','live GitHub identity without a matching cache does not count');
select extensions.is(visibility_review_test.call(2,'select public.list_own_links()')#>>'{0,verification_state}',
    'unverified','cache loss also makes owner verification unverified');
select visibility_review_test.error($q$select visibility_review_test.service_call('select service.save_github_link(visibility_review_test.id(2),''9002'',''91002'',''https://github.com/owner/repo'',''Link'','''',null,''{}''::text[],'''',''everyone_eligible'',true)')$q$,
    'not_found','','service save requires a matching linked identity as well as live Auth');
select extensions.lives_ok($q$select visibility_review_test.service_call('select service.sync_github_identity(visibility_review_test.id(2),''91002'',''owner'',''{}''::text[])')$q$,
    'sync can restore a missing cache for the same live managed identity');
select extensions.is(visibility_review_test.call(1,'select public.list_saved_links()')#>>'{links,0,link,link_id}',
    visibility_review_test.id(1002)::text,'restored matching cache makes the retained link count again');

select * from extensions.finish();
rollback;
