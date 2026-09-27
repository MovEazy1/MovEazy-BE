-- One definition of "a person this channel brought in", used by both the
-- funnel tiles and the people table beneath them.
--
-- Supersedes marketing_funnel_v2.sql. IF YOU RE-RUN marketing_schema.sql,
-- RE-RUN THIS FILE AFTER IT — that file recreates these functions in their
-- oldest shape.
--
-- == Why ==
--
-- marketing_funnel_v2.sql taught the tiles to count pre-signup leads, but the
-- people table was still built from _marketing_leads(), which lists signed-up
-- accounts only. So Rishav's dashboard read "7 Phone no." above a table of 4
-- people: the three who gave a number and never signed up were counted and
-- never shown. Two definitions of the same set will always drift like that.
--
-- So there is now one: _marketing_people(). The tiles are aggregates over it
-- and the table is its rows, which means every number on the page is a count
-- of rows you can see.
--
-- A person is an account whose sign-up was credited to the channel, or a
-- pre-signup lead (lead_intake) whose first touch was the channel's campaign.
-- A lead that later signed up (claimed_by) is the same person as the account.
--
-- Who can see it: exactly who could before. The table is behind
-- can_view_marketing(slug), the same gate as the signed-up rows — anyone with
-- a channel's dashboard now also sees the numbers of the people that channel
-- brought in who have not signed up yet.
--
-- Run once in the Supabase SQL editor. Safe to re-run.

drop function if exists public.marketing_overview();
drop function if exists public.marketing_channel_stats(text);
drop function if exists public.marketing_channel_leads(text);
drop function if exists public._marketing_stats(text);
drop function if exists public._marketing_people(text);


create function public._marketing_people(p_slug text default null)
returns table (
  channel_slug        text,
  person_key          text,
  user_id             uuid,
  is_lead_only        boolean,
  name                text,
  email               text,
  phone               text,
  phone_given_at      timestamptz,
  reacted_at          timestamptz,
  reaction_count      int,
  prefs_filled_at     timestamptz,
  signed_up_at        timestamptz,
  shortlisted_at      timestamptz,
  shortlist_count     int,
  visit_scheduled_at  timestamptz,
  visit_count         int,
  closed_at           timestamptz,
  closed_reason       text,
  utm_source          text,
  utm_medium          text,
  utm_content         text,
  referrer            text,
  landing_path        text
)
language sql
stable
security definer
set search_path = public
as $$
  with ch as (
    select c.* from public.marketing_channels c
     where not c.is_overview
       and (p_slug is null or c.slug = p_slug)
       -- A channel with no campaign cannot credit anyone: matching '' to ''
       -- would hand it everybody who arrived without one.
       and coalesce(c.utm_campaign, '') <> ''
  ),
  evidence as (
    -- Accounts whose sign-up was credited to this channel.
    select ch.slug                    as channel_slug,
           'u:' || p.id::text         as person,
           p.id                       as user_id,
           null::text                 as lead_name,
           null::text                 as lead_phone,
           null::timestamptz          as lead_phone_at,
           null::timestamptz          as lead_prefs_at,
           null::jsonb                as lead_utm
      from public.user_profiles p
      join ch on lower(p.signup_attribution ->> 'campaign') = lower(ch.utm_campaign)
    union all
    -- Leads whose first touch was this channel, signed up or not.
    select ch.slug,
           coalesce('u:' || l.claimed_by::text, 'l:' || l.lead_key),
           l.claimed_by,
           nullif(btrim(l.name), ''),
           nullif(public.normalize_mobile(l.phone), ''),
           case when public.normalize_mobile(l.phone) <> '' then l.created_at end,
           -- Localities or a finished questionnaire. Not flat types or budget:
           -- the questionnaire opens with those already filled in.
           -- A CASE, not `typeof = 'array' and length > 0`: Postgres does not
           -- promise to evaluate AND left to right, and jsonb_array_length
           -- raises on a non-array — one odd row would break every dashboard.
           case when coalesce(l.completed, false)
                  or (case when jsonb_typeof(l.prefs -> 'localities') = 'array'
                           then jsonb_array_length(l.prefs -> 'localities') > 0
                           else false end)
                then l.updated_at end,
           l.utm
      from public.lead_intake l
      join ch on lower(l.utm ->> 'campaign') = lower(ch.utm_campaign)
  ),
  grouped as (
    select
      e.channel_slug,
      e.person,
      (array_agg(e.user_id) filter (where e.user_id is not null))[1]   as user_id,
      max(e.lead_name)                                                 as lead_name,
      max(e.lead_phone)                                                as lead_phone,
      min(e.lead_phone_at)                                             as lead_phone_at,
      min(e.lead_prefs_at)                                             as lead_prefs_at,
      (array_agg(e.lead_utm) filter (where e.lead_utm is not null))[1] as lead_utm
    from evidence e
    group by 1, 2
  )
  select
    g.channel_slug,
    g.person,
    g.user_id,
    p.id is null,
    coalesce(nullif(btrim(p.name), ''), g.lead_name, ''),
    coalesce(p.email, ''),
    coalesce(nullif(public.normalize_mobile(p.phone), ''), g.lead_phone, ''),
    -- When they gave the number: the phone gate's own timestamp where there is
    -- one. A number typed in after sign-up has no timestamp of its own, so the
    -- sign-up stands in for it.
    coalesce(g.lead_phone_at,
             case when public.normalize_mobile(p.phone) <> '' then p.created_at end),
    r.first_at,
    coalesce(r.n, 0),
    nullif(least(coalesce(g.lead_prefs_at, 'infinity'::timestamptz),
                 coalesce(case when p.id is not null then public._mkt_prefs_at(p.id) end,
                          'infinity'::timestamptz)),
           'infinity'::timestamptz),
    p.created_at,
    case when p.id is not null then public._mkt_shortlist_at(p.id) end,
    case when p.id is not null then public._mkt_shortlist_count(p.id) else 0 end,
    case when p.id is not null then public._mkt_visit_at(p.id) end,
    case when p.id is not null then public._mkt_visit_count(p.id) else 0 end,
    case when p.id is not null then public._mkt_closed_at(p.id) end,
    case when p.id is not null then public._mkt_closed_reason(p.id) else '' end,
    coalesce(nullif(p.signup_attribution ->> 'source', ''),  g.lead_utm ->> 'source',  ''),
    coalesce(nullif(p.signup_attribution ->> 'medium', ''),  g.lead_utm ->> 'medium',  ''),
    coalesce(nullif(p.signup_attribution ->> 'content', ''), g.lead_utm ->> 'content', ''),
    coalesce(p.signup_attribution ->> 'referrer', ''),
    coalesce(p.signup_attribution ->> 'landing_path', '')
  from grouped g
  left join public.user_profiles p on p.id = g.user_id
  left join lateral (
    select min(lr.updated_at) as first_at, count(*)::int as n
      from public.listing_reactions lr
     where lr.user_id = p.id
  ) r on true;
$$;


/** Per-channel funnel totals: counts over _marketing_people, nothing else. */
create function public._marketing_stats(p_slug text default null)
returns table (
  slug              text,
  label             text,
  utm_source        text,
  utm_medium        text,
  utm_campaign      text,
  landing_path      text,
  active            boolean,
  link_clicks       int,
  visitors          int,
  phone_given       int,
  prop_reacted      int,
  prefs_filled      int,
  signups           int,
  shortlisted       int,
  visits_scheduled  int,
  closed            int,
  last_click_at     timestamptz,
  last_signup_at    timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  -- Table-qualified throughout: a RETURNS TABLE column is also a parameter.
  with ch as (
    select c.* from public.marketing_channels c
     where not c.is_overview and (p_slug is null or c.slug = p_slug)
  ),
  clicks as (
    select
      mc.channel_slug,
      count(*)::int                                                      as link_clicks,
      count(distinct coalesce(nullif(mc.anon_id, ''), mc.id::text))::int as visitors,
      max(mc.created_at)                                                 as last_click_at
    from public.marketing_clicks mc
    join ch on ch.slug = mc.channel_slug
    group by 1
  ),
  totals as (
    select
      pe.channel_slug,
      count(*) filter (where pe.phone_given_at     is not null)::int as phone_given,
      count(*) filter (where pe.reacted_at         is not null)::int as prop_reacted,
      count(*) filter (where pe.prefs_filled_at    is not null)::int as prefs_filled,
      count(*) filter (where pe.signed_up_at       is not null)::int as signups,
      count(*) filter (where pe.shortlisted_at     is not null)::int as shortlisted,
      count(*) filter (where pe.visit_scheduled_at is not null)::int as visits_scheduled,
      count(*) filter (where pe.closed_at          is not null)::int as closed,
      max(pe.signed_up_at)                                           as last_signup_at
    from public._marketing_people(p_slug) pe
    group by 1
  )
  select
    ch.slug, ch.label, ch.utm_source, ch.utm_medium, ch.utm_campaign,
    ch.landing_path, ch.active,
    coalesce(clicks.link_clicks, 0),
    coalesce(clicks.visitors, 0),
    coalesce(totals.phone_given, 0),
    coalesce(totals.prop_reacted, 0),
    coalesce(totals.prefs_filled, 0),
    coalesce(totals.signups, 0),
    coalesce(totals.shortlisted, 0),
    coalesce(totals.visits_scheduled, 0),
    coalesce(totals.closed, 0),
    clicks.last_click_at,
    totals.last_signup_at
  from ch
  left join clicks on clicks.channel_slug = ch.slug
  left join totals on totals.channel_slug = ch.slug
  order by coalesce(totals.phone_given, 0) desc, coalesce(clicks.link_clicks, 0) desc, ch.label;
$$;


create function public.marketing_overview()
returns table (
  slug text, label text, utm_source text, utm_medium text, utm_campaign text, landing_path text,
  active boolean, link_clicks int, visitors int, phone_given int, prop_reacted int, prefs_filled int,
  signups int, shortlisted int, visits_scheduled int, closed int,
  last_click_at timestamptz, last_signup_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_overview text;
begin
  select c.slug into v_overview from public.marketing_channels c where c.is_overview limit 1;
  if v_overview is null or not public.can_view_marketing(v_overview) then
    return;
  end if;
  return query select * from public._marketing_stats(null::text);
end;
$$;


create function public.marketing_channel_stats(p_slug text)
returns table (
  slug text, label text, utm_source text, utm_medium text, utm_campaign text, landing_path text,
  active boolean, link_clicks int, visitors int, phone_given int, prop_reacted int, prefs_filled int,
  signups int, shortlisted int, visits_scheduled int, closed int,
  last_click_at timestamptz, last_signup_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_slug is null or not public.can_view_marketing(p_slug) then
    return;
  end if;
  return query select * from public._marketing_stats(p_slug);
end;
$$;


/** The people behind the tiles — the same rows they are counted from. */
create function public.marketing_channel_leads(p_slug text)
returns table (
  person_key          text,
  user_id             uuid,
  is_lead_only        boolean,
  name                text,
  email               text,
  phone               text,
  phone_given_at      timestamptz,
  reacted_at          timestamptz,
  reaction_count      int,
  prefs_filled_at     timestamptz,
  signed_up_at        timestamptz,
  shortlisted_at      timestamptz,
  shortlist_count     int,
  visit_scheduled_at  timestamptz,
  visit_count         int,
  closed_at           timestamptz,
  closed_reason       text,
  utm_source          text,
  utm_medium          text,
  utm_content         text,
  referrer            text,
  landing_path        text
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_slug is null or not public.can_view_marketing(p_slug) then
    return;
  end if;
  return query
    select pe.person_key, pe.user_id, pe.is_lead_only, pe.name, pe.email, pe.phone,
           pe.phone_given_at, pe.reacted_at, pe.reaction_count, pe.prefs_filled_at,
           pe.signed_up_at, pe.shortlisted_at, pe.shortlist_count, pe.visit_scheduled_at,
           pe.visit_count, pe.closed_at, pe.closed_reason, pe.utm_source, pe.utm_medium,
           pe.utm_content, pe.referrer, pe.landing_path
      from public._marketing_people(p_slug) pe
     -- Newest first by whatever they did last that we can date.
     order by greatest(pe.signed_up_at, pe.phone_given_at, pe.prefs_filled_at) desc nulls last;
end;
$$;


-- == Lock down ===============================================================
-- Recreated functions lose their grants, and Supabase's default privileges
-- grant execute to anon explicitly — so each is restated here, by name.
revoke all on function public._marketing_people(text)       from public, anon, authenticated;
revoke all on function public._marketing_stats(text)        from public, anon, authenticated;
revoke all on function public.marketing_overview()          from public, anon;
revoke all on function public.marketing_channel_stats(text) from public, anon;
revoke all on function public.marketing_channel_leads(text) from public, anon;
grant execute on function public.marketing_overview()          to authenticated;
grant execute on function public.marketing_channel_stats(text) to authenticated;
grant execute on function public.marketing_channel_leads(text) to authenticated;


-- == Verify ==================================================================
-- The tiles and the table must agree. For every channel, expect phone_given
-- to equal the number of rows with a phone_given_at:
--
--   select s.slug, s.phone_given,
--          (select count(*) from public._marketing_people(s.slug) p
--            where p.phone_given_at is not null) as rows_with_phone
--     from public._marketing_stats(null) s;
--
-- Signed out, all three must be refused (42501):
--   curl -X POST "$URL/rest/v1/rpc/marketing_channel_leads" -H "apikey: $ANON" \
--        -H "Content-Type: application/json" -d '{"p_slug":"rishav"}'
