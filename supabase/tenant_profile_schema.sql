-- ─────────────────────────────────────────────────────────────────────────────
-- Tenant profiles — what a tenant fills in on their home (fe/src/pages/tenant/*,
-- fe/src/lib/tenantProfile.js), and the score it earns.
--
-- Run in the Supabase SQL editor AFTER crm_schema.sql (is_crm_staff) and
-- customer_schema.sql (user_profiles). Safe to re-run.
--
-- It is the ground the tenant verification portal will stand on — the page an
-- owner is sent to see who is asking for their flat — so two rules hold here
-- rather than in the browser:
--
--   * the SCORE is worked out by the database (tenant_profile_score), from the
--     row and the tenant's own name and verified mobile on user_profiles. A
--     browser can send any number; this one is not taken from it.
--   * who READS a profile is decided here: the tenant, and CRM staff. Owners
--     will read one only through the portal's own function, for the tenant
--     who shared it — nothing on this table grants them a thing.
--
-- Score (mirrors lib/tenantProfile.js — change both together):
--   name 10 · verified mobile 10 · LinkedIn 10 · current company 15 ·
--   past company (or first job) 10 · college 10 · graduation year 5 ·
--   in Bangalore since 10 · married / single 10                = 90 Excellent
--   every field in, and married / married with kids            = 100 Outstanding
-- ─────────────────────────────────────────────────────────────────────────────

begin;

create table if not exists public.tenant_profiles (
  user_id            uuid primary key references auth.users (id) on delete cascade,
  linkedin           text not null default '',
  current_company    text not null default '' check (length(current_company) <= 120),
  past_company       text not null default '' check (length(past_company) <= 120),
  first_job          boolean not null default false,   -- "this is my first job" stands in for a past company
  college            text not null default '' check (length(college) <= 160),
  graduation_year    int check (graduation_year between 1950 and 2100),
  in_bangalore_since text not null default '' check (length(in_bangalore_since) <= 30),
  marital_status     text not null default '' check (marital_status in ('', 'single', 'married', 'family')),
  score              int not null default 0,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

-- A LinkedIn profile link, canonical (the app writes it so): IDs in other
-- scripts arrive percent-encoded, hence the room.
alter table public.tenant_profiles drop constraint if exists tenant_profiles_linkedin_check;
alter table public.tenant_profiles add constraint tenant_profiles_linkedin_check
  check (linkedin = '' or (length(linkedin) <= 450 and linkedin ~* '^https://www\.linkedin\.com/in/[A-Za-z0-9_%-]{3,}$'));

/** The score for one profile, given the tenant's name and mobile. */
create or replace function public.tenant_profile_score(p public.tenant_profiles, p_name text, p_phone text)
returns int
language sql
immutable
as $$
  with parts as (
    select
      (coalesce(trim(p_name), '') <> '')                                   as has_name,
      (coalesce(trim(p_phone), '') <> '')                                  as has_phone,
      (p.linkedin <> '')                                                   as has_linkedin,
      (trim(p.current_company) <> '')                                      as has_current,
      (trim(p.past_company) <> '' or p.first_job)                          as has_past,
      (trim(p.college) <> '')                                              as has_college,
      (p.graduation_year is not null)                                      as has_grad,
      (trim(p.in_bangalore_since) <> '')                                   as has_since,
      (p.marital_status <> '')                                             as has_status
  )
  select
      (case when has_name then 10 else 0 end) + (case when has_phone then 10 else 0 end)
    + (case when has_linkedin then 10 else 0 end) + (case when has_current then 15 else 0 end)
    + (case when has_past then 10 else 0 end) + (case when has_college then 10 else 0 end)
    + (case when has_grad then 5 else 0 end) + (case when has_since then 10 else 0 end)
    + (case when has_status then 10 else 0 end)
    + (case when has_name and has_phone and has_linkedin and has_current and has_past and has_college
                 and has_grad and has_since and has_status and p.marital_status in ('married', 'family')
            then 10 else 0 end)
  from parts;
$$;

/** Every write recomputes the score and the timestamp; the client's values are ignored. */
create or replace function public.tenant_profiles_before_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare nm text; ph text;
begin
  if tg_op = 'UPDATE' then
    new.user_id := old.user_id;
    new.created_at := old.created_at;
  end if;
  select u.name, u.phone into nm, ph from public.user_profiles u where u.id = new.user_id;
  new.score := public.tenant_profile_score(new, nm, ph);
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists tenant_profiles_before_write on public.tenant_profiles;
create trigger tenant_profiles_before_write
  before insert or update on public.tenant_profiles
  for each row execute function public.tenant_profiles_before_write();

-- ── Row access ──────────────────────────────────────────────────────────────
alter table public.tenant_profiles enable row level security;

drop policy if exists "tenant reads own profile" on public.tenant_profiles;
create policy "tenant reads own profile" on public.tenant_profiles
  for select to authenticated using (user_id = auth.uid() or public.is_crm_staff());

drop policy if exists "tenant creates own profile" on public.tenant_profiles;
create policy "tenant creates own profile" on public.tenant_profiles
  for insert to authenticated with check (user_id = auth.uid());

drop policy if exists "tenant updates own profile" on public.tenant_profiles;
create policy "tenant updates own profile" on public.tenant_profiles
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "tenant deletes own profile" on public.tenant_profiles;
create policy "tenant deletes own profile" on public.tenant_profiles
  for delete to authenticated using (user_id = auth.uid());

-- Supabase hands anon everything in public by default; take it back.
revoke all on public.tenant_profiles from public, anon, authenticated;
grant select, insert, update, delete on public.tenant_profiles to authenticated;
revoke all on function public.tenant_profile_score(public.tenant_profiles, text, text) from public, anon;
revoke all on function public.tenant_profiles_before_write() from public, anon, authenticated;

commit;
