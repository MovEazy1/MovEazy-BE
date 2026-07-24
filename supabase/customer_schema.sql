-- Customer/account data (fe/src/lib/profileService.js, customerSearchProfile.js,
-- AuthContext.jsx, PropertyModal.jsx "Request a tour").
-- Run once in the Supabase SQL editor alongside broker_schema.sql / admin_schema.sql.
--
-- Replaces the old Firestore collections (userProfiles / userRoles / emailRoles /
-- customerSearchProfiles / visits / listingPrivate) now that auth is Supabase-only.

create extension if not exists "pgcrypto";

-- One row per signed-in user: identity + role + seller-badge state.
create table if not exists public.user_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  name text default '',
  phone text default '',
  role text not null default 'customer',
  seller_badge_status text default 'none',
  seller_badge_application jsonb,
  flat_search jsonb,
  profile_complete boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists user_profiles_email_lower_idx
  on public.user_profiles (lower(email));

alter table public.user_profiles enable row level security;

drop policy if exists "users read own profile" on public.user_profiles;
create policy "users read own profile"
  on public.user_profiles for select
  using (id = auth.uid() or public.is_admin_allowlisted());

drop policy if exists "users insert own profile" on public.user_profiles;
create policy "users insert own profile"
  on public.user_profiles for insert
  with check (id = auth.uid());

drop policy if exists "users update own profile" on public.user_profiles;
create policy "users update own profile"
  on public.user_profiles for update
  using (id = auth.uid() or public.is_admin_allowlisted())
  with check (id = auth.uid() or public.is_admin_allowlisted());

-- Create the profile row server-side the instant an auth user is created, so it
-- exists even if email confirmation delays the client from getting a session
-- (client-side upsert in profileService.js then just enriches phone/name).
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.user_profiles (id, email, name, role, seller_badge_status)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name', split_part(new.email, '@', 1)),
    coalesce(new.raw_user_meta_data ->> 'role', 'customer'),
    case when coalesce(new.raw_user_meta_data ->> 'role', 'customer') in ('seller', 'broker') then 'none' else null end
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- One row per customer: their saved flat-search preferences.
create table if not exists public.customer_search_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  preferred_areas text[] default '{}',
  budget_min numeric,
  budget_max numeric,
  bhk text default '',
  property_type text default '',
  furnishing text default '',
  move_in_date text default '',
  commute_to text default '',
  max_commute_mins numeric,
  must_haves text default '',
  deal_breakers text default '',
  pets text default '',
  parking text default '',
  notes text default '',
  priority text default '',
  updated_at timestamptz not null default now()
);

alter table public.customer_search_profiles enable row level security;

drop policy if exists "customers manage own search profile" on public.customer_search_profiles;
create policy "customers manage own search profile"
  on public.customer_search_profiles for all
  using (user_id = auth.uid() or public.is_admin_allowlisted())
  with check (user_id = auth.uid());

-- Tour / visit requests submitted from the listing modal ("Request a tour" / "Enquire").
create table if not exists public.visit_requests (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid references auth.users(id) default auth.uid(),
  customer_email text,
  customer_phone text default '',
  listing_id text not null,
  listing_title text default '',
  seller_email text default '',
  visit_time text default '',
  notes text default '',
  status text not null default 'pending',
  created_at timestamptz not null default now()
);

create index if not exists visit_requests_customer_created_idx
  on public.visit_requests (customer_id, created_at desc);

alter table public.visit_requests enable row level security;

drop policy if exists "customers create own visit requests" on public.visit_requests;
create policy "customers create own visit requests"
  on public.visit_requests for insert
  to authenticated
  with check (customer_id = auth.uid());

drop policy if exists "customers read own visit requests" on public.visit_requests;
create policy "customers read own visit requests"
  on public.visit_requests for select
  to authenticated
  using (customer_id = auth.uid() or public.is_admin_allowlisted());

-- Saved / bookmarked listings ("Save" heart button in PropertyModal, MapView,
-- and the flat-search chat agent). One row per (customer, listing); toggling
-- save just inserts or deletes this row. Shown on the Profile page "Saved" tab.
create table if not exists public.saved_properties (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  listing_id text not null,
  listing_title text default '',
  listing_data jsonb,
  created_at timestamptz not null default now(),
  unique (customer_id, listing_id)
);

-- Snapshot of the full listing (title/image/rent/address) at save time, so the
-- Profile "Saved" tab can render a real card and open it without a separate
-- lookup — the flat-agent's catalog (fe/public/listings.json) isn't otherwise
-- queryable by id from the frontend. Safe to re-run if the table predates this column.
alter table public.saved_properties add column if not exists listing_data jsonb;

create index if not exists saved_properties_customer_created_idx
  on public.saved_properties (customer_id, created_at desc);

alter table public.saved_properties enable row level security;

drop policy if exists "customers manage own saved properties" on public.saved_properties;
create policy "customers manage own saved properties"
  on public.saved_properties for all
  to authenticated
  using (customer_id = auth.uid() or public.is_admin_allowlisted())
  with check (customer_id = auth.uid());

-- Private contact numbers for a listing (broker/owner phone) — not world-readable.
create table if not exists public.listing_private (
  listing_id text primary key,
  agent_phone text default '',
  owner_phone text default '',
  owner_email text default '',
  updated_at timestamptz not null default now()
);

alter table public.listing_private enable row level security;

drop policy if exists "staff manage listing private data" on public.listing_private;
create policy "staff manage listing private data"
  on public.listing_private for all
  to authenticated
  using (public.is_admin_allowlisted())
  with check (public.is_admin_allowlisted());

drop policy if exists "owner reads own listing private data" on public.listing_private;
create policy "owner reads own listing private data"
  on public.listing_private for select
  to authenticated
  using (lower(owner_email) = lower(coalesce(auth.jwt() ->> 'email', '')));

-- Public site settings (contact team, support email) shown on marketing pages
-- (fe/src/lib/sitePublicSettings.js). Single row keyed by id = 'public'.
create table if not exists public.site_public_settings (
  id text primary key default 'public',
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.site_public_settings enable row level security;

drop policy if exists "anyone reads site public settings" on public.site_public_settings;
create policy "anyone reads site public settings"
  on public.site_public_settings for select
  using (true);

drop policy if exists "admins write site public settings" on public.site_public_settings;
create policy "admins write site public settings"
  on public.site_public_settings for all
  to authenticated
  using (public.is_admin_allowlisted())
  with check (public.is_admin_allowlisted());

-- Tables created via raw SQL don't automatically get any access for Supabase's
-- `anon`/`authenticated` roles (unlike tables made in the dashboard Table
-- Editor) — without this, every request fails with "insufficient_privilege"
-- (42501) before RLS policies are even evaluated, regardless of how correct
-- those policies are. RLS (enabled above) still restricts which *rows* each
-- role can touch; this just allows the *table* to be touched at all.
grant usage on schema public to anon, authenticated;
grant select, insert, update on
  public.user_profiles,
  public.customer_search_profiles,
  public.visit_requests,
  public.saved_properties,
  public.listing_private
to authenticated;
grant select, insert, update on public.site_public_settings to authenticated;
grant select on public.site_public_settings to anon;
