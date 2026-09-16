-- ─────────────────────────────────────────────────────────────────────────────
-- Marketing channel dashboards (/marketing/* in MovEazy-FE).
--
-- Run in the Supabase SQL editor. Safe to re-run: every statement is
-- idempotent, and re-running is how you pick up a funnel source that didn't
-- exist the first time.
--
-- The only hard requirement is public.user_profiles. Everything else it reads —
-- user_actions, saved_properties, listing_reactions, user_requirements,
-- customer_search_profiles, visit_bookings, crm_clients — is optional: the
-- funnel helpers are built from whichever of those tables the project has. The
-- environments have drifted apart (production had no user_actions when this
-- shipped), and failing the whole migration on the first missing table would
-- leave that project with no dashboards rather than an honest partial one.
-- After applying any of those schemas, run this file again.
--
-- The question this answers: of the people who arrived from one specific post,
-- group or page, how many got as far as each step of the funnel — and who are
-- they. Four things make that possible:
--
--   1. public.marketing_channels  — one row per tracked surface. utm_campaign is
--      the join key, because it is the one UTM parameter we control end to end
--      and the only one that stays unique (two Facebook surfaces share a
--      utm_source, so source can never identify a channel on its own).
--   2. public.marketing_clicks    — a row per arrival, written by signed-out
--      visitors through a security-definer function. Clicks and unique visitors
--      are the only two funnel steps that happen before an account exists, so
--      they cannot be derived from user rows later.
--   3. public.marketing_access    — which email may open which dashboard.
--   4. The reporting functions    — security definer, because a channel owner
--      (Rishav, say) is deliberately NOT an admin: they must see the funnel for
--      their own link and nothing else. Every one of them checks
--      can_view_marketing() before returning a single row.
--
-- There is no signup_channel column on user_profiles on purpose. The channel is
-- resolved at read time from signup_attribution->>'campaign', so renaming or
-- re-pointing a channel re-attributes history instead of leaving a stale copy
-- behind, and a client that has never heard of marketing_channels still writes
-- correct attribution.
-- ─────────────────────────────────────────────────────────────────────────────

create extension if not exists "pgcrypto";

-- ── Channels ─────────────────────────────────────────────────────────────────

create table if not exists public.marketing_channels (
  slug          text primary key
                  constraint marketing_channels_slug_check
                  check (slug ~ '^[a-z0-9][a-z0-9-]{1,40}$'),
  label         text not null,
  description   text not null default '',

  utm_source    text not null,
  utm_medium    text not null default 'social',
  utm_campaign  text not null,
  landing_path  text not null default '/',

  -- The roll-up view (/marketing/head). Excluded from the channel list it
  -- reports on, so it never counts itself.
  is_overview   boolean not null default false,
  active        boolean not null default true,

  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- The join key has to be unique or a signup could be credited to two channels.
create unique index if not exists marketing_channels_campaign_idx
  on public.marketing_channels (lower(utm_campaign));

alter table public.marketing_channels enable row level security;

-- ── Who may open which dashboard ─────────────────────────────────────────────

create table if not exists public.marketing_access (
  id            uuid primary key default gen_random_uuid(),
  email         text not null,
  channel_slug  text not null references public.marketing_channels(slug) on delete cascade,
  notes         text default '',
  granted_by    text default '',
  created_at    timestamptz not null default now()
);

create unique index if not exists marketing_access_email_channel_idx
  on public.marketing_access (lower(email), channel_slug);

alter table public.marketing_access enable row level security;

-- ── Arrivals ─────────────────────────────────────────────────────────────────
-- Written only through record_marketing_click(). The table itself grants nothing
-- to anon: a public insert policy would let anyone forge a million clicks on a
-- channel, and the function can at least resolve the campaign itself and damp
-- repeats.

create table if not exists public.marketing_clicks (
  id            uuid primary key default gen_random_uuid(),
  channel_slug  text not null references public.marketing_channels(slug) on delete cascade,
  anon_id       text not null default '',
  user_id       uuid references auth.users(id) on delete set null,
  landing_path  text not null default '',
  referrer      text not null default '',
  utm           jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now()
);

create index if not exists marketing_clicks_channel_idx
  on public.marketing_clicks (channel_slug, created_at desc);
create index if not exists marketing_clicks_anon_idx
  on public.marketing_clicks (channel_slug, anon_id, created_at desc);

alter table public.marketing_clicks enable row level security;

-- ── The columns a signup is credited through ─────────────────────────────────
-- These arrive with MovEazy-FE/db/2026-09-16_signup_attribution.sql and with
-- crm_schema.sql, which is where they are documented. Repeated here —
-- idempotently — because every reporting function below reads them, and this
-- whole file would fail on a project where either migration hasn't been run.
alter table public.user_profiles
  add column if not exists attribution_token     text,
  add column if not exists signup_source         text,
  add column if not exists signup_attribution    jsonb,
  add column if not exists search_status         text not null default 'searching',
  add column if not exists search_closed_at      timestamptz,
  add column if not exists search_closed_reason  text default '';

/**
 * The one hardcoded identity, mirrored from crm_schema.sql and from
 * MovEazy-FE/src/lib/adminAccess.js. Defined here too so this file stands on
 * its own: create or replace with the same body is a no-op where crm_schema has
 * already run, and the difference between a working dashboard and a 42883 where
 * it hasn't. Change it in all three places together.
 */
create or replace function public.is_super_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select lower(coalesce(auth.jwt() ->> 'email', '')) = 'yatharth200018@gmail.com';
$$;

-- Counting signups per channel means joining on this expression on every
-- dashboard load. Partial, because unattributed rows can never match.
create index if not exists user_profiles_signup_campaign_idx
  on public.user_profiles (lower(signup_attribution ->> 'campaign'))
  where signup_attribution is not null;

-- ── Access helpers ───────────────────────────────────────────────────────────

/**
 * May the caller open this channel's dashboard?
 *
 * Security definer so the lookup is not itself gated by marketing_access's
 * policies (which would recurse). The super admin holds every channel; everyone
 * else holds exactly what has been granted to their email.
 */
create or replace function public.can_view_marketing(p_slug text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    public.is_super_admin()
    or exists (
      select 1
      from public.marketing_access a
      where a.channel_slug = p_slug
        and lower(a.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
    );
$$;

/**
 * May the caller open the roll-up?
 *
 * Exists as its own function only so the marketing_channels read policy can ask
 * the question without selecting from marketing_channels — a policy on a table
 * that reads that same table recurses and Postgres refuses the query outright.
 * Security definer sidesteps the policy, which is exactly the point.
 */
create or replace function public.can_view_marketing_overview()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.marketing_channels c
    where c.is_overview
      and public.can_view_marketing(c.slug)
  );
$$;

/** Any marketing dashboard at all — gates the shell and the channel picker. */
create or replace function public.has_marketing_access()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    public.is_super_admin()
    or exists (
      select 1
      from public.marketing_access a
      where lower(a.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
    );
$$;

revoke all on function public.can_view_marketing(text) from public;
revoke all on function public.can_view_marketing_overview() from public;
revoke all on function public.has_marketing_access() from public;
grant execute on function public.can_view_marketing(text) to authenticated;
grant execute on function public.can_view_marketing_overview() to authenticated;
grant execute on function public.has_marketing_access() to authenticated;

-- ── Policies ─────────────────────────────────────────────────────────────────

-- A channel row is readable by anyone who can open that channel, and by anyone
-- who can open the roll-up (which has to name every channel it reports on).
drop policy if exists "marketing read own channels" on public.marketing_channels;
create policy "marketing read own channels"
  on public.marketing_channels for select
  to authenticated
  using (public.can_view_marketing(slug) or public.can_view_marketing_overview());

drop policy if exists "super admin writes channels" on public.marketing_channels;
create policy "super admin writes channels"
  on public.marketing_channels for all
  to authenticated
  using (public.is_super_admin())
  with check (public.is_super_admin());

-- A grantee may see their own grants (so the UI can list their dashboards);
-- only the super admin may hand them out. Same shape as admin_roles, and for
-- the same reason: the policy does not consult any grantable permission, so
-- "can grant marketing access" is not itself something that can be granted.
drop policy if exists "read own marketing grants" on public.marketing_access;
create policy "read own marketing grants"
  on public.marketing_access for select
  to authenticated
  using (
    public.is_super_admin()
    or lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );

drop policy if exists "super admin writes marketing grants" on public.marketing_access;
create policy "super admin writes marketing grants"
  on public.marketing_access for all
  to authenticated
  using (public.is_super_admin())
  with check (public.is_super_admin());

-- Raw clicks are never read directly — the reporting functions aggregate them.
drop policy if exists "super admin reads clicks" on public.marketing_clicks;
create policy "super admin reads clicks"
  on public.marketing_clicks for select
  to authenticated
  using (public.is_super_admin());

grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on public.marketing_channels to authenticated;
grant select, insert, update, delete on public.marketing_access to authenticated;
grant select on public.marketing_clicks to authenticated;

-- ── Recording an arrival ─────────────────────────────────────────────────────

/**
 * Record that someone arrived from a tracked link.
 *
 * Callable by signed-out visitors, which is the whole point — the person tapping
 * a link in a Facebook group has no session, and the click has to be counted
 * before any account exists. Safe to expose: an unknown campaign is a silent
 * no-op, nothing is returned that the caller did not already know, and a repeat
 * from the same browser inside the dedupe window is dropped so a refresh (the
 * UTM parameters are still in the address bar) cannot inflate the count.
 */
create or replace function public.record_marketing_click(
  p_campaign     text,
  p_anon_id      text default '',
  p_landing_path text default '',
  p_referrer     text default '',
  p_utm          jsonb default '{}'::jsonb
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_slug text;
  v_anon text := left(coalesce(p_anon_id, ''), 64);
begin
  if p_campaign is null or length(trim(p_campaign)) = 0 then
    return null;
  end if;

  select slug into v_slug
    from public.marketing_channels
   where lower(utm_campaign) = lower(trim(p_campaign))
     and active;

  if v_slug is null then
    return null;  -- unknown campaign; say nothing either way
  end if;

  -- One arrival per browser per channel per half hour. A visitor who navigates
  -- with the parameters still attached, or reloads, is one click — not five.
  if v_anon <> '' and exists (
    select 1 from public.marketing_clicks
     where channel_slug = v_slug
       and anon_id = v_anon
       and created_at > now() - interval '30 minutes'
  ) then
    return v_slug;
  end if;

  insert into public.marketing_clicks
    (channel_slug, anon_id, user_id, landing_path, referrer, utm)
  values (
    v_slug,
    v_anon,
    auth.uid(),
    left(coalesce(p_landing_path, ''), 300),
    left(coalesce(p_referrer, ''), 300),
    coalesce(p_utm, '{}'::jsonb)
  );

  return v_slug;
end;
$$;

revoke all on function public.record_marketing_click(text, text, text, text, jsonb) from public;
grant execute on function public.record_marketing_click(text, text, text, text, jsonb)
  to anon, authenticated;

-- ── Reporting ────────────────────────────────────────────────────────────────

/**
 * The funnel steps, one small function each, built against the tables this
 * project actually has.
 *
 * The four middle steps are evidenced by tables that were introduced at
 * different times and are not all present in every environment — production had
 * no user_actions when this shipped. Naming a missing one directly would fail
 * the whole migration on a 42P01 and leave the project with no dashboards at
 * all, which is a far worse answer than a dashboard whose "Prop shortlisted"
 * column is honestly empty.
 *
 * So each helper's body is assembled from the sources that exist right now. Two
 * consequences worth knowing:
 *
 *   - Adding one of these tables later does NOT retroactively widen the
 *     helpers. Re-run this file after any such migration; it is idempotent and
 *     will pick the new source up.
 *   - A step with no source at all reports null rather than zero-as-fact. The
 *     dashboard then shows nobody reaching it, which is true of what we can
 *     see, and the comment above says why.
 */
do $mig$
declare
  ts    text[] := '{}';   -- expressions for "when did this first happen"
  ids   text[] := '{}';   -- branches of the "how many distinct properties" union
  expr  text;
begin
  -- Told us what they want: the guided Find My Flat questionnaire, or the
  -- lighter search profile saved at signup. Either is a filled preference.
  if to_regclass('public.user_requirements') is not null then
    ts := ts || $q$(select min(r.created_at) from public.user_requirements r where r.user_id = p_user)$q$::text;
  end if;
  if to_regclass('public.customer_search_profiles') is not null then
    ts := ts || $q$(select min(s.updated_at) from public.customer_search_profiles s where s.user_id = p_user)$q$::text;
  end if;

  expr := case when cardinality(ts) = 0 then 'null::timestamptz'
               else 'least(' || array_to_string(ts, ', ') || ')' end;
  execute format($fn$
    create or replace function public._mkt_prefs_at(p_user uuid)
    returns timestamptz language sql stable security definer set search_path = public
    as $body$ select %s $body$;
  $fn$, expr);

  -- Saving a flat is logged three different ways depending on which surface the
  -- person used, and all three count.
  ts := '{}';
  if to_regclass('public.user_actions') is not null then
    ts  := ts  || $q$(select min(a.created_at) from public.user_actions a
                       where a.user_id = p_user and a.action ~* 'shortlist|save|like|favou?rite')$q$::text;
    ids := ids || $q$select a.property_id as pid from public.user_actions a
                      where a.user_id = p_user and a.action ~* 'shortlist|save|like|favou?rite'
                        and a.property_id is not null$q$::text;
  end if;
  if to_regclass('public.saved_properties') is not null then
    ts  := ts  || $q$(select min(sp.created_at) from public.saved_properties sp where sp.customer_id = p_user)$q$::text;
    ids := ids || $q$select sp.listing_id as pid from public.saved_properties sp where sp.customer_id = p_user$q$::text;
  end if;
  if to_regclass('public.listing_reactions') is not null then
    ts  := ts  || $q$(select min(lr.updated_at) from public.listing_reactions lr
                       where lr.user_id = p_user and lr.reaction = 'like')$q$::text;
    ids := ids || $q$select lr.property_id as pid from public.listing_reactions lr
                      where lr.user_id = p_user and lr.reaction = 'like'$q$::text;
  end if;

  expr := case when cardinality(ts) = 0 then 'null::timestamptz'
               else 'least(' || array_to_string(ts, ', ') || ')' end;
  execute format($fn$
    create or replace function public._mkt_shortlist_at(p_user uuid)
    returns timestamptz language sql stable security definer set search_path = public
    as $body$ select %s $body$;
  $fn$, expr);

  expr := case when cardinality(ids) = 0 then '0'
               else '(select count(distinct x.pid)::int from ('
                    || array_to_string(ids, ' union ') || ') x)' end;
  execute format($fn$
    create or replace function public._mkt_shortlist_count(p_user uuid)
    returns int language sql stable security definer set search_path = public
    as $body$ select %s $body$;
  $fn$, expr);

  -- A booked slot is a scheduled visit. A tour request is only the ask, so it
  -- is the fallback rather than an equal source — used only where the booking
  -- table doesn't exist, and then said plainly rather than counted as more.
  if to_regclass('public.visit_bookings') is not null then
    execute $fn$
      create or replace function public._mkt_visit_at(p_user uuid)
      returns timestamptz language sql stable security definer set search_path = public
      as $body$ select min(v.created_at) from public.visit_bookings v where v.user_id = p_user $body$;
      $fn$;
    execute $fn$
      create or replace function public._mkt_visit_count(p_user uuid)
      returns int language sql stable security definer set search_path = public
      as $body$ select count(*)::int from public.visit_bookings v where v.user_id = p_user $body$;
      $fn$;
  elsif to_regclass('public.visit_requests') is not null then
    execute $fn$
      create or replace function public._mkt_visit_at(p_user uuid)
      returns timestamptz language sql stable security definer set search_path = public
      as $body$ select min(vr.created_at) from public.visit_requests vr where vr.customer_id = p_user $body$;
      $fn$;
    execute $fn$
      create or replace function public._mkt_visit_count(p_user uuid)
      returns int language sql stable security definer set search_path = public
      as $body$ select count(*)::int from public.visit_requests vr where vr.customer_id = p_user $body$;
      $fn$;
  else
    execute $fn$
      create or replace function public._mkt_visit_at(p_user uuid)
      returns timestamptz language sql stable security definer set search_path = public
      as $body$ select null::timestamptz $body$;
      $fn$;
    execute $fn$
      create or replace function public._mkt_visit_count(p_user uuid)
      returns int language sql stable security definer set search_path = public
      as $body$ select 0 $body$;
      $fn$;
  end if;

  -- Closed means the search ended with us, from either side of the house: the
  -- flag the product writes on the profile, or the CRM marking the deal done.
  -- 'closed_outside' is deliberately not counted — a channel does not get
  -- credit for a person who rented somewhere else.
  ts := array[$q$(select case when up.search_status = 'closed_by_us'
                              then coalesce(up.search_closed_at, up.updated_at) end
                    from public.user_profiles up where up.id = p_user)$q$::text];
  if to_regclass('public.crm_clients') is not null then
    ts := ts || $q$(select min(cc.closed_at) from public.crm_clients cc
                     where cc.user_id = p_user and cc.status = 'closed_by_us')$q$::text;
  end if;

  execute format($fn$
    create or replace function public._mkt_closed_at(p_user uuid)
    returns timestamptz language sql stable security definer set search_path = public
    as $body$ select least(%s) $body$;
  $fn$, array_to_string(ts, ', '));

  ts := array[$q$(select nullif(up.search_closed_reason, '')
                    from public.user_profiles up where up.id = p_user)$q$::text];
  if to_regclass('public.crm_clients') is not null then
    ts := ts || $q$(select cc.closed_reason from public.crm_clients cc
                     where cc.user_id = p_user and cc.status = 'closed_by_us'
                     order by cc.closed_at nulls last limit 1)$q$::text;
  end if;

  execute format($fn$
    create or replace function public._mkt_closed_reason(p_user uuid)
    returns text language sql stable security definer set search_path = public
    as $body$ select coalesce(%s, '') $body$;
  $fn$, array_to_string(ts, ', '));
end;
$mig$;

revoke all on function public._mkt_prefs_at(uuid)        from public;
revoke all on function public._mkt_shortlist_at(uuid)    from public;
revoke all on function public._mkt_shortlist_count(uuid) from public;
revoke all on function public._mkt_visit_at(uuid)        from public;
revoke all on function public._mkt_visit_count(uuid)     from public;
revoke all on function public._mkt_closed_at(uuid)       from public;
revoke all on function public._mkt_closed_reason(uuid)   from public;

/**
 * Every signed-up account that came from a tracked channel, with the moment it
 * reached each funnel step.
 *
 * Internal: no permission check, not granted to anyone. The two public wrappers
 * below check can_view_marketing() first. Split this way so the funnel is
 * defined exactly once — a roll-up that counted steps differently from the
 * per-channel view would be worse than no roll-up.
 *
 * A step's timestamp is the earliest evidence of it, and the steps are
 * deliberately independent rather than nested: someone can book a visit without
 * ever having saved a flat, and showing that as "0 shortlisted, 1 visit" is the
 * truth. Totals are counted the same way, so the columns do not have to descend.
 */
create or replace function public._marketing_leads(p_slug text default null)
returns table (
  channel_slug        text,
  user_id             uuid,
  email               text,
  name                text,
  phone               text,
  signed_up_at        timestamptz,
  prefs_filled_at     timestamptz,
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
  select
    c.slug,
    p.id,
    coalesce(p.email, ''),
    coalesce(p.name, ''),
    coalesce(p.phone, ''),
    p.created_at,

    -- Each step's evidence is spread across tables that don't all exist in
    -- every environment, so the definitions live in the helpers built above
    -- rather than inline here. See the DO block for what each one reads.
    public._mkt_prefs_at(p.id),
    public._mkt_shortlist_at(p.id),
    public._mkt_shortlist_count(p.id),
    public._mkt_visit_at(p.id),
    public._mkt_visit_count(p.id),
    public._mkt_closed_at(p.id),
    public._mkt_closed_reason(p.id),

    coalesce(p.signup_attribution ->> 'source', ''),
    coalesce(p.signup_attribution ->> 'medium', ''),
    coalesce(p.signup_attribution ->> 'content', ''),
    coalesce(p.signup_attribution ->> 'referrer', ''),
    coalesce(p.signup_attribution ->> 'landing_path', '')
  from public.user_profiles p
  join public.marketing_channels c
    on lower(p.signup_attribution ->> 'campaign') = lower(c.utm_campaign)
   and not c.is_overview
  where p_slug is null or c.slug = p_slug;
$$;

revoke all on function public._marketing_leads(text) from public;

/** Per-channel funnel totals. Internal; wrappers below do the permission check. */
create or replace function public._marketing_stats(p_slug text default null)
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
  signups           int,
  prefs_filled      int,
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
  -- Every column reference below is table-qualified on purpose: a RETURNS TABLE
  -- column is also a named parameter, so a bare `slug` or `active` here is
  -- ambiguous and Postgres refuses the whole function.
  with ch as (
    select c.* from public.marketing_channels c
     where not c.is_overview and (p_slug is null or c.slug = p_slug)
  ),
  clicks as (
    select
      mc.channel_slug,
      count(*)::int                                                  as link_clicks,
      -- A browser with no anon id (private mode, storage blocked) is still one
      -- visitor; falling back to the row id keeps it from collapsing them all
      -- into a single phantom person.
      count(distinct coalesce(nullif(mc.anon_id, ''), mc.id::text))::int as visitors,
      max(mc.created_at)                                             as last_click_at
    from public.marketing_clicks mc
    join ch on ch.slug = mc.channel_slug
    group by 1
  ),
  leads as (
    select
      l.channel_slug,
      count(*)::int                                                   as signups,
      count(*) filter (where l.prefs_filled_at is not null)::int      as prefs_filled,
      count(*) filter (where l.shortlisted_at is not null)::int       as shortlisted,
      count(*) filter (where l.visit_scheduled_at is not null)::int   as visits_scheduled,
      count(*) filter (where l.closed_at is not null)::int            as closed,
      max(l.signed_up_at)                                             as last_signup_at
    from public._marketing_leads(p_slug) l
    group by 1
  )
  select
    ch.slug, ch.label, ch.utm_source, ch.utm_medium, ch.utm_campaign,
    ch.landing_path, ch.active,
    coalesce(clicks.link_clicks, 0),
    coalesce(clicks.visitors, 0),
    coalesce(leads.signups, 0),
    coalesce(leads.prefs_filled, 0),
    coalesce(leads.shortlisted, 0),
    coalesce(leads.visits_scheduled, 0),
    coalesce(leads.closed, 0),
    clicks.last_click_at,
    leads.last_signup_at
  from ch
  left join clicks on clicks.channel_slug = ch.slug
  left join leads  on leads.channel_slug  = ch.slug
  order by coalesce(leads.signups, 0) desc, coalesce(clicks.link_clicks, 0) desc, ch.label;
$$;

revoke all on function public._marketing_stats(text) from public;

/**
 * The roll-up behind /marketing/head: one row per channel.
 *
 * Gated on the overview channel rather than on each row, because that is what
 * the page is — whoever may see the comparison may see every line of it. An
 * unauthorised caller gets an empty set, not an error: the UI has already said
 * "you don't have access", and a raised exception here would only turn that
 * into a broken page.
 */
create or replace function public.marketing_overview()
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
  signups           int,
  prefs_filled      int,
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
create or replace function public.marketing_channel_stats(p_slug text)
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
  signups           int,
  prefs_filled      int,
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

/** The people behind those numbers, one row each. */
create or replace function public.marketing_channel_leads(p_slug text)
returns table (
  user_id             uuid,
  email               text,
  name                text,
  phone               text,
  signed_up_at        timestamptz,
  prefs_filled_at     timestamptz,
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
    select l.user_id, l.email, l.name, l.phone, l.signed_up_at, l.prefs_filled_at,
           l.shortlisted_at, l.shortlist_count, l.visit_scheduled_at, l.visit_count,
           l.closed_at, l.closed_reason, l.utm_source, l.utm_medium, l.utm_content,
           l.referrer, l.landing_path
      from public._marketing_leads(p_slug) l
     order by l.signed_up_at desc;
end;
$$;

/**
 * Which dashboards the signed-in email may open.
 *
 * The super admin sees every channel. Everyone else sees exactly their grants —
 * this is what the /marketing index renders, and what decides whether a direct
 * visit to someone else's URL gets a dashboard or a refusal.
 */
create or replace function public.my_marketing_channels()
returns table (
  slug         text,
  label        text,
  description  text,
  is_overview  boolean,
  active       boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select c.slug, c.label, c.description, c.is_overview, c.active
    from public.marketing_channels c
   where public.can_view_marketing(c.slug)
   order by c.is_overview desc, c.label;
$$;

revoke all on function public.marketing_overview() from public;
revoke all on function public.marketing_channel_stats(text) from public;
revoke all on function public.marketing_channel_leads(text) from public;
revoke all on function public.my_marketing_channels() from public;
grant execute on function public.marketing_overview() to authenticated;
grant execute on function public.marketing_channel_stats(text) to authenticated;
grant execute on function public.marketing_channel_leads(text) to authenticated;
grant execute on function public.my_marketing_channels() to authenticated;

-- ── The channels we start with ───────────────────────────────────────────────
-- on conflict do nothing, not "do update": re-running this file must never
-- silently reset a campaign string that links already in the wild depend on.

insert into public.marketing_channels
  (slug, label, description, utm_source, utm_medium, utm_campaign, landing_path, is_overview)
values
  ('head', 'All channels', 'Every marketing channel side by side.',
   'moveazy', 'internal', 'mkt_head', '/', true),

  ('rishav', 'Rishav''s group', 'Leads from the WhatsApp group Rishav runs.',
   'rishav', 'group', 'mkt_rishav', '/', false),

  ('fbprofile', 'Facebook profile', 'Posts from the MovEazy founder profile.',
   'facebook', 'profile', 'mkt_fbprofile', '/', false),

  ('fbpage', 'Facebook page', 'Posts from the MovEazy Facebook page.',
   'facebook', 'page', 'mkt_fbpage', '/', false),

  ('reddithsrkora', 'Reddit — HSR / Koramangala', 'The HSR and Koramangala subreddit threads.',
   'reddit', 'community', 'mkt_reddithsrkora', '/', false)
on conflict (slug) do nothing;

-- ── Which funnel steps this project can actually see ─────────────────────────
-- Run this after applying. A 'missing' row is a column that will read empty on
-- every dashboard until that schema is applied and this file is re-run.
select step, case when present then 'ok' else 'missing — apply its schema, then re-run this file' end as status
from (values
  ('Pref filled  (user_requirements)',      to_regclass('public.user_requirements')       is not null),
  ('Pref filled  (customer_search_profiles)', to_regclass('public.customer_search_profiles') is not null),
  ('Shortlisted  (user_actions)',           to_regclass('public.user_actions')            is not null),
  ('Shortlisted  (saved_properties)',       to_regclass('public.saved_properties')        is not null),
  ('Shortlisted  (listing_reactions)',      to_regclass('public.listing_reactions')       is not null),
  ('Visit sched. (visit_bookings)',         to_regclass('public.visit_bookings')          is not null),
  ('Closed       (crm_clients)',            to_regclass('public.crm_clients')             is not null)
) as t(step, present);

-- ── Check it landed ──────────────────────────────────────────────────────────
--
--   select slug, utm_campaign,
--          'https://www.moveazy.co.in' || landing_path
--            || '?utm_source=' || utm_source
--            || '&utm_medium=' || utm_medium
--            || '&utm_campaign=' || utm_campaign as share_link
--     from public.marketing_channels
--    where not is_overview
--    order by label;
--
-- Grant someone their dashboard (the Marketing tab in /superadmin does this too):
--
--   insert into public.marketing_access (email, channel_slug)
--   values ('rishav@example.com', 'rishav')
--   on conflict do nothing;
