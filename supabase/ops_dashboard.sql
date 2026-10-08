-- ─────────────────────────────────────────────────────────────────────────────
-- /dashboard — the day-on-day operating numbers, and who may look at them.
--
-- Three pieces, same shape as marketing_schema.sql:
--
--   1. public.dashboard_access        — one row per email allowed to open it.
--   2. public.can_view_ops_dashboard()— the gate, security definer.
--   3. public.ops_daily_metrics()     — one row per calendar day, six numbers.
--
-- Why a separate grant table rather than admin_roles: the people who want these
-- numbers (an investor, a founder's co-founder, an ops hire on day one) are
-- deliberately not CRM staff. A grant here gives that email the six counts on
-- /dashboard and nothing else — no client list, no phone numbers, no inventory
-- rows, no CRM. That boundary is this file, not the React page.
--
-- Run once in the Supabase SQL editor. Safe to re-run; safe to run before
-- crm_schema.sql / inventory_schema.sql / visits_schema.sql, in which case the
-- metrics those tables feed report 0 until their own migration lands.
-- ─────────────────────────────────────────────────────────────────────────────

create extension if not exists "pgcrypto";

-- Every day boundary in this file is Asia/Kolkata. A visit at 11pm in Bengaluru
-- belongs to that day's row, not to tomorrow's, which is what UTC would do.

/**
 * The one hardcoded identity, mirrored from crm_schema.sql, marketing_schema.sql
 * and MovEazy-FE/src/lib/adminAccess.js. Defined here too so this file stands on
 * its own — create or replace with the same body is a no-op where crm_schema has
 * already run. Change it in all four places together.
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

-- ── Who may open /dashboard ──────────────────────────────────────────────────

create table if not exists public.dashboard_access (
  id          uuid primary key default gen_random_uuid(),
  email       text not null,
  notes       text default '',
  granted_by  text default '',
  created_at  timestamptz not null default now()
);

create unique index if not exists dashboard_access_email_idx
  on public.dashboard_access (lower(email));

alter table public.dashboard_access enable row level security;

/**
 * The gate.
 *
 * Security definer so the lookup is not itself gated by the policies below,
 * which would recurse. The super admin always passes, even before any row
 * exists — otherwise the first grant could never be made.
 *
 * CRM staff are NOT included on purpose: holding crm.analytics.read is a
 * different decision from being handed the company's headline numbers, and
 * conflating them means a new CRM manager silently gains this page.
 */
create or replace function public.can_view_ops_dashboard()
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
        from public.dashboard_access a
       where lower(a.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
    );
$$;

revoke all on function public.can_view_ops_dashboard() from public, anon;
grant execute on function public.can_view_ops_dashboard() to authenticated;

-- A grant holder may see that they hold one, and nothing else in the table.
-- The super admin sees the whole roster, which is what the panel renders.
drop policy if exists "read own dashboard grant" on public.dashboard_access;
create policy "read own dashboard grant"
  on public.dashboard_access for select
  to authenticated
  using (
    public.is_super_admin()
    or lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );

drop policy if exists "super admin writes dashboard grants" on public.dashboard_access;
create policy "super admin writes dashboard grants"
  on public.dashboard_access for all
  to authenticated
  using (public.is_super_admin())
  with check (public.is_super_admin());

grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on public.dashboard_access to authenticated;

-- RLS already refuses anon here (both policies are declared `to authenticated`),
-- so this is the second lock rather than the first — but Supabase's default
-- privileges hand anon a SELECT on every new table, and a grant table whose
-- privileges say "anon may read" is one policy edit away from publishing the
-- roster of everyone who can see the company's numbers.
revoke all on public.dashboard_access from anon;

-- ── The six numbers ──────────────────────────────────────────────────────────
--
-- Built with dynamic SQL because each metric reads a table that arrives with a
-- different migration. A project without crm_schema.sql still gets a working
-- dashboard with zeroes in the lead columns, rather than a 42P01 that blanks
-- the whole page — the same reason marketing_schema.sql composes its helpers.
--
-- Three of the six are point-in-time ("how many were open at the end of that
-- day"). Postgres has no history of a status that has since changed, so those
-- are reconstructed from the row's current state plus its updated_at: a client
-- that is closed today but was last touched after day D was still open on D.
-- Exact for today, an honest approximation going back. Add a status-history
-- table later and these three become exact without the page changing.

do $do$
declare
  f_new_leads      text := '0';
  f_active_leads   text := '0';
  f_new_props      text := '0';
  f_active_props   text := '0';
  f_visits         text := '0';
  f_closures       text := '0';
begin
  if to_regclass('public.crm_clients') is not null then
    -- A lead is a CRM client row. Created that day.
    f_new_leads := $f$(
      select count(*)::int
        from public.crm_clients c
       where (c.created_at at time zone 'Asia/Kolkata')::date = d.day
    )$f$;

    -- Open at the end of that day: created by then, not yet closed either way.
    f_active_leads := $f$(
      select count(*)::int
        from public.crm_clients c
       where (c.created_at at time zone 'Asia/Kolkata')::date <= d.day
         and (
           c.status not in ('closed_by_us', 'closed_outside')
           or (coalesce(c.closed_at, c.updated_at) at time zone 'Asia/Kolkata')::date > d.day
         )
    )$f$;

    -- Ours, not "closed_outside" — the flats we actually placed someone in.
    f_closures := $f$(
      select count(*)::int
        from public.crm_clients c
       where c.status = 'closed_by_us'
         and (coalesce(c.closed_at, c.updated_at) at time zone 'Asia/Kolkata')::date = d.day
    )$f$;
  end if;

  if to_regclass('public.inventory') is not null then
    f_new_props := $f$(
      select count(*)::int
        from public.inventory i
       where (i.created_at at time zone 'Asia/Kolkata')::date = d.day
    )$f$;

    -- Live supply at the end of that day. Paused and rented are both "not
    -- active": a paused flat cannot be shown, so counting it would overstate
    -- what a seeker could actually be sent.
    f_active_props := $f$(
      select count(*)::int
        from public.inventory i
       where (i.created_at at time zone 'Asia/Kolkata')::date <= d.day
         and (
           i.status = 'published'
           or (i.updated_at at time zone 'Asia/Kolkata')::date > d.day
         )
    )$f$;
  end if;

  if to_regclass('public.visit_bookings') is not null then
    -- Dated by when the visit happens, not when it was booked — this row is
    -- "how many people saw a flat that day". A booking with no slot yet falls
    -- back to its creation date so it is counted somewhere rather than dropped.
    f_visits := $f$(
      select count(*)::int
        from public.visit_bookings b
       where (coalesce(b.slot_at, b.created_at) at time zone 'Asia/Kolkata')::date = d.day
         and coalesce(b.status, '') <> 'cancelled'
    )$f$;
  end if;

  -- drop-then-create rather than create-or-replace: Postgres refuses to replace
  -- a function whose RETURNS TABLE shape changed, and this file runs in one
  -- transaction in the SQL editor — so adding a seventh metric later would roll
  -- the access rules back along with it.
  execute 'drop function if exists public._ops_daily_metrics(date, date)';

  execute format($q$
    create function public._ops_daily_metrics(p_from date, p_to date)
    returns table (
      day               date,
      new_leads         int,
      active_leads      int,
      new_properties    int,
      active_properties int,
      visits            int,
      closures          int
    )
    language sql
    stable
    security definer
    set search_path = public
    as $body$
      select
        d.day,
        %s, %s, %s, %s, %s, %s
      from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') as g(ts)
      cross join lateral (select g.ts::date as day) d
      order by d.day desc;
    $body$;
  $q$, f_new_leads, f_active_leads, f_new_props, f_active_props, f_visits, f_closures);
end
$do$;

revoke all on function public._ops_daily_metrics(date, date) from public, anon, authenticated;

/**
 * The public entry point. One row per day in [p_from, p_to], newest first.
 *
 * An unauthorised caller gets an empty set rather than an error, matching
 * marketing_overview(): the page has already said "no access", and raising here
 * would turn that into a broken screen. The range is clamped to a year because
 * every column is a correlated subquery per day — a five-year request is a
 * table scan per metric per day and nobody is reading 1,800 rows anyway.
 */
drop function if exists public.ops_daily_metrics(date, date);
create function public.ops_daily_metrics(p_from date, p_to date)
returns table (
  day               date,
  new_leads         int,
  active_leads      int,
  new_properties    int,
  active_properties int,
  visits            int,
  closures          int
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_to   date := coalesce(p_to, (now() at time zone 'Asia/Kolkata')::date);
  v_from date := coalesce(p_from, v_to - 29);
begin
  if not public.can_view_ops_dashboard() then
    return;
  end if;
  if v_from > v_to then
    return;
  end if;
  v_from := greatest(v_from, v_to - 365);
  return query select * from public._ops_daily_metrics(v_from, v_to);
end;
$$;

revoke all on function public.ops_daily_metrics(date, date) from public, anon;
grant execute on function public.ops_daily_metrics(date, date) to authenticated;
