-- The marketing funnel, in the order the product now runs.
--
--   Clicks | Visitors | Phone no. | Prop like/dislike | Pref given | Sign up |
--   Visit scheduled | Closed
--
-- SUPERSEDED by marketing_people.sql, which defines the same funnel once for
-- both the tiles and the people table. Run that instead.
--
-- Supersedes _marketing_stats, marketing_overview and marketing_channel_stats
-- from marketing_schema.sql. IF YOU RE-RUN marketing_schema.sql, RE-RUN THIS
-- FILE AFTER IT — that file drops and recreates these three functions in their
-- old shape.
--
-- == Why the counting changed, not just the columns ==
--
-- Every step after Visitors used to count signed-up accounts only: a person
-- entered the funnel through user_profiles.signup_attribution, at sign-up. That
-- matched the old product, where sign-up came first. It does not match this
-- one: a tenant now gives a phone number, then preferences, and only then
-- signs up. Counted the old way, "Phone no." would have missed exactly the
-- people it exists to count — the ones who gave a number and never signed up.
--
-- So a person is now either an account attributed to the channel, or a
-- pre-signup lead (lead_intake) whose first touch was that channel's campaign.
-- A lead that later signs up (lead_intake.claimed_by) is the same person as
-- the account, counted once.
--
-- Steps are still independent, not nested — the rule marketing_schema.sql
-- set: each counts everyone with evidence of it, so a column need not be
-- smaller than the one before it.
--
-- Every existing column is still returned, so a dashboard built before this
-- keeps working; phone_given and prop_reacted are added.
--
-- Run once in the Supabase SQL editor. Safe to re-run.

-- drop-then-create: Postgres refuses to replace a function whose RETURNS
-- TABLE changed. The wrappers go first; they depend on the inner function.
drop function if exists public.marketing_overview();
drop function if exists public.marketing_channel_stats(text);
drop function if exists public._marketing_stats(text);

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
  -- Every column reference is table-qualified: a RETURNS TABLE column is also a
  -- named parameter, so a bare `slug` here is ambiguous and Postgres refuses it.
  with ch as (
    select c.* from public.marketing_channels c
     where not c.is_overview
       and (p_slug is null or c.slug = p_slug)
       -- A channel with no campaign cannot credit anyone; matching '' to ''
       -- would hand it every visitor who arrived without one.
       and coalesce(c.utm_campaign, '') <> ''
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
  -- Everyone the channel can claim, one row per piece of evidence.
  evidence as (
    -- Accounts whose sign-up was credited to this channel.
    select ch.slug as channel_slug,
           'u:' || p.id::text as person,
           p.id as user_id,
           public.normalize_mobile(p.phone) <> '' as has_phone,
           false as lead_prefs,
           p.created_at as signed_up_at
      from public.user_profiles p
      join ch on lower(p.signup_attribution ->> 'campaign') = lower(ch.utm_campaign)
    union all
    -- Leads whose first touch was this channel — signed up or not.
    select ch.slug,
           coalesce('u:' || l.claimed_by::text, 'l:' || l.lead_key),
           l.claimed_by,
           public.normalize_mobile(l.phone) <> '',
           -- Localities or a finished questionnaire. Not flat types or budget:
           -- the questionnaire starts with those pre-filled, so they hold a
           -- value the moment it opens.
           coalesce(l.completed, false)
             or (jsonb_typeof(l.prefs -> 'localities') = 'array'
                 and jsonb_array_length(l.prefs -> 'localities') > 0),
           null::timestamptz
      from public.lead_intake l
      join ch on lower(l.utm ->> 'campaign') = lower(ch.utm_campaign)
  ),
  people as (
    select
      e.channel_slug,
      e.person,
      (array_agg(e.user_id) filter (where e.user_id is not null))[1] as user_id,
      bool_or(e.has_phone)   as has_phone,
      bool_or(e.lead_prefs)  as lead_prefs,
      max(e.signed_up_at)    as signed_up_at
    from evidence e
    group by 1, 2
  ),
  steps as (
    select
      pp.channel_slug,
      pp.has_phone,
      pp.user_id is not null
        and exists (select 1 from public.listing_reactions r where r.user_id = pp.user_id)
        as reacted,
      pp.lead_prefs
        or (pp.user_id is not null and public._mkt_prefs_at(pp.user_id) is not null)
        as prefs,
      pp.user_id is not null as signed_up,
      pp.user_id is not null and public._mkt_shortlist_at(pp.user_id) is not null as shortlisted,
      pp.user_id is not null and public._mkt_visit_at(pp.user_id) is not null     as visited,
      pp.user_id is not null and public._mkt_closed_at(pp.user_id) is not null    as closed,
      pp.signed_up_at
    from people pp
  ),
  totals as (
    select
      s.channel_slug,
      count(*) filter (where s.has_phone)::int   as phone_given,
      count(*) filter (where s.reacted)::int     as prop_reacted,
      count(*) filter (where s.prefs)::int       as prefs_filled,
      count(*) filter (where s.signed_up)::int   as signups,
      count(*) filter (where s.shortlisted)::int as shortlisted,
      count(*) filter (where s.visited)::int     as visits_scheduled,
      count(*) filter (where s.closed)::int      as closed,
      max(s.signed_up_at)                        as last_signup_at
    from steps s
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


/** The roll-up behind /marketing/head. Gated on the overview channel. */
create function public.marketing_overview()
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


/** The header row on one channel's dashboard. */
create function public.marketing_channel_stats(p_slug text)
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


-- == Lock down ===============================================================
-- Recreating a function resets its grants, and Supabase's default privileges
-- grant execute to anon explicitly — so every line from marketing_schema.sql's
-- lockdown for these three is restated here, by name.
revoke all on function public._marketing_stats(text)        from public, anon, authenticated;
revoke all on function public.marketing_overview()          from public, anon;
revoke all on function public.marketing_channel_stats(text) from public, anon;
grant execute on function public.marketing_overview()          to authenticated;
grant execute on function public.marketing_channel_stats(text) to authenticated;


-- == Verify ==================================================================
-- Signed out, both must be refused:
--   curl -X POST "$URL/rest/v1/rpc/marketing_overview" -H "apikey: $ANON"
--   => 42501 permission denied
--
-- The raw numbers, run in the SQL editor (as postgres, so no permission gate):
--   select slug, link_clicks, visitors, phone_given, prop_reacted,
--          prefs_filled, signups, visits_scheduled, closed
--     from public._marketing_stats(null);
