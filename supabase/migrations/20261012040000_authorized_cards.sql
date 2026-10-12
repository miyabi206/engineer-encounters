-- The caller supplies the participants of a confirmed encounter. Confirmation,
-- reveal, retention and moderation are separate read gates, so the feed can use
-- these same current-settings facts without changing their definition.
create function private.encounter_authorization(viewer_account uuid, owner_account uuid)
returns table (eligible boolean, compatible boolean, shared_interest_count integer)
language sql
stable
set search_path = ''
as $$
    with facts as (
        select coalesce(viewer_account <> owner_account, false)
            and exists (
                select 1 from private.profiles as p
                where p.user_id = viewer_account and p.discovery_on
            )
            and exists (
                select 1 from private.profiles as p
                where p.user_id = owner_account and p.discovery_on
            )
            and not exists (
                select 1 from private.blocks as b
                where (b.blocker_id = viewer_account and b.blocked_id = owner_account)
                   or (b.blocker_id = owner_account and b.blocked_id = viewer_account)
            ) as eligible,
            exists (
                select 1 from private.user_purposes as v
                join private.user_purposes as o on o.purpose = v.purpose
                where v.user_id = viewer_account and o.user_id = owner_account
            ) as overlapping_purposes,
            (select pg_catalog.count(*)::integer
                from private.user_interests as v
                join private.user_interests as o on o.interest_id = v.interest_id
                where v.user_id = viewer_account and o.user_id = owner_account
            ) as shared_interest_count,
            coalesce((select m.minimum_shared_interests from private.matching_preferences as m
                where m.user_id = viewer_account), 1) as viewer_threshold,
            coalesce((select m.minimum_shared_interests from private.matching_preferences as m
                where m.user_id = owner_account), 1) as owner_threshold
    )
    select f.eligible,
        f.eligible and f.overlapping_purposes
            and f.shared_interest_count >= f.viewer_threshold
            and f.shared_interest_count >= f.owner_threshold,
        f.shared_interest_count
    from facts as f;
$$;

revoke all on function private.encounter_authorization(uuid, uuid)
    from public, anon, authenticated, service_role;

create function private.get_encounter_card(input_encounter_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    caller uuid := private.require_caller();
    card jsonb;
begin
    -- Gates, current authorization and values share one statement snapshot.
    -- Add 30 local calendar days before converting midnight to an instant;
    -- neither the session zone nor a daylight-saving change shifts the date.
    select pg_catalog.jsonb_build_object(
            'encounter_id', e.encounter_id, 'kind', e.kind,
            'day', case when e.user_a = caller then e.day_a else e.day_b end
        )
        || coalesce(fields.value, '{}'::jsonb)
        || case when links.value is null then '{}'::jsonb
            else pg_catalog.jsonb_build_object('links', links.value) end
        || case when fields.value is null and links.value is null
            then pg_catalog.jsonb_build_object('shell', true) else '{}'::jsonb end
    into card
    from private.encounters as e
    join private.encounter_views as v on v.encounter_id = e.encounter_id and v.viewer_id = caller
    left join private.notification_preferences as n on n.user_id = caller
    left join pg_catalog.pg_timezone_names as z on z.name = n.time_zone
    join private.profiles as p on p.user_id = case when e.user_a = caller then e.user_b else e.user_a end
    cross join lateral private.encounter_authorization(caller, p.user_id) as a
    cross join lateral (
        select pg_catalog.jsonb_object_agg(f.field,
            case f.field
                when 'display_name' then pg_catalog.to_jsonb(p.display_name)
                when 'introduction' then pg_catalog.to_jsonb(p.introduction)
                when 'contact_detail' then pg_catalog.to_jsonb(p.contact_detail)
                when 'interests' then coalesce((
                    select pg_catalog.jsonb_agg(i.interest_id order by i.interest_id)
                    from private.user_interests as i where i.user_id = p.user_id
                ), '[]'::jsonb)
                when 'purposes' then coalesce((
                    select pg_catalog.jsonb_agg(u.purpose order by u.purpose)
                    from private.user_purposes as u where u.user_id = p.user_id
                ), '[]'::jsonb)
            end
        ) as value
        from private.field_visibility as f
        where f.owner_id = p.user_id
          and (f.level = 'everyone_eligible' or (f.level = 'compatible_only' and a.compatible))
    ) as fields
    cross join lateral (
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'link_id', l.link_id, 'source', l.source, 'url', l.url,
            'title', l.title, 'description', l.description,
            'main_language', l.main_language, 'tags', l.tags,
            'opening_text', l.opening_text, 'verification_state', l.verification_state
        ) order by l.display_order, l.link_id) as value
        from private.external_links as l
        where l.owner_id = p.user_id
          and (l.visibility = 'everyone_eligible' or (l.visibility = 'compatible_only' and a.compatible))
    ) as links
    where e.encounter_id = input_encounter_id
      and caller in (e.user_a, e.user_b)
      and v.revealed
      and (v.favorite or pg_catalog.now() < pg_catalog.timezone(z.name,
          ((case when e.user_a = caller then e.day_a else e.day_b end) + 30)::timestamp))
      and a.eligible
      and p.moderation_state = 'active';

    if card is null then
        perform private.raise_error('not_found');
    end if;
    return card;
end;
$$;

-- SQL preserves the RPC argument names without PL/pgSQL column ambiguity.
create function public.get_encounter_card(encounter_id uuid)
returns jsonb
language sql
security definer
set search_path = ''
as $$
    select private.get_encounter_card($1);
$$;

revoke all on function private.get_encounter_card(uuid) from public, anon, authenticated, service_role;

revoke all on function public.get_encounter_card(uuid) from public, anon, authenticated, service_role;
grant execute on function public.get_encounter_card(uuid) to authenticated;
