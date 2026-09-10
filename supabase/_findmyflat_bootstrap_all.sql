-- ============================================================================
-- Find My Flat — one-shot bootstrap bundle (generated 2026-08-04)
-- Run ONCE in the Supabase SQL editor (role: postgres). All statements are
-- idempotent (create-if-not-exists / create-or-replace / drop-policy-if-exists),
-- so re-running is safe. Requires admin_schema.sql (is_admin_allowlisted) — already
-- present in this project — and inventory (already present).
--
-- Order: customer_schema -> user_requirements -> user_actions -> whatsapp(no-op) -> seed
-- ============================================================================


-- ==================== BEGIN customer_schema.sql ====================
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
-- ==================== END customer_schema.sql ====================


-- ==================== BEGIN user_requirements_schema.sql ====================
-- Per-user requirement profile (fe/src/components/AIBroker.jsx "Find My Flat" →
-- fe/src/lib/userRequirements.js). One row per user, keyed by user_id, capturing
-- everything the guided questionnaire learns about them. Described in the shared
-- vocabulary (fe/src/data/preferenceOptions.js) so it scores directly against
-- public.inventory via fe/src/lib/inventoryMatch.js.
--
-- Run once in the Supabase SQL editor, AFTER admin_schema.sql (needs
-- public.is_admin_allowlisted()).

create extension if not exists "pgcrypto";

create table if not exists public.user_requirements (
  user_id        uuid primary key references auth.users(id) on delete cascade default auth.uid(),
  email          text default '',

  office         jsonb,                        -- { label, lat, lng, display }
  whatsapp       text default '',              -- mandatory WhatsApp number (office step)
  age            text default '',
  localities     text[] default '{}',          -- subset of preferenceOptions localities
  budget_min     numeric,
  budget_max     numeric,
  stretch        boolean default false,        -- willing to stretch ~15% over budget
  occupants      text[] default '{}',          -- subset of OCCUPANTS
  flat_types     text[] default '{}',          -- subset of FLAT_TYPES
  must_haves     text[] default '{}',          -- subset of MUST_HAVES
  lifestyle      text[] default '{}',          -- subset of LIFESTYLE
  deal_breakers  text[] default '{}',          -- subset of DEALBREAKERS
  priority       text[] default '{}',          -- ranked priorities, most important first
  notes          jsonb  default '{}'::jsonb,   -- free-text notes keyed by question id

  last_match_count int default 0,              -- inventory matches at last run (for admin insight)
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

alter table public.user_requirements enable row level security;

drop policy if exists "users manage own requirement" on public.user_requirements;
create policy "users manage own requirement"
  on public.user_requirements for all
  to authenticated
  using (user_id = auth.uid() or public.is_admin_allowlisted())
  with check (user_id = auth.uid());

-- Posters need to read every requirement to find who their new flat matches
-- (fe/src/pages/ListMyFlat.jsx success screen). Requirements are non-sensitive
-- preference data, not contact details, so authenticated read-all is acceptable.
drop policy if exists "authenticated read requirements for matching" on public.user_requirements;
create policy "authenticated read requirements for matching"
  on public.user_requirements for select
  to authenticated
  using (true);

grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on public.user_requirements to authenticated;
-- ==================== END user_requirements_schema.sql ====================


-- ==================== BEGIN user_actions_schema.sql ====================
-- Renter action log (fe/src/lib/userActions.js). One row per meaningful action a
-- user takes — shortlisting a property, submitting a visit preference, etc. Lets
-- the admin panel review activity both user-wise ("what did this user do") and
-- property-wise ("who is interested in this home").
--
-- Run once in the Supabase SQL editor, AFTER admin_schema.sql (needs
-- public.is_admin_allowlisted()).

create extension if not exists "pgcrypto";

create table if not exists public.user_actions (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade default auth.uid(),
  email        text default '',
  action       text not null,                 -- 'shortlist_property' | 'visit_preference_submitted' | ...
  property_id  text,                           -- the property involved, when applicable
  details      jsonb default '{}'::jsonb,      -- free-form extra context (title, slot_at, …)
  created_at   timestamptz not null default now()
);

create index if not exists ua_user_idx     on public.user_actions (user_id, created_at desc);
create index if not exists ua_property_idx on public.user_actions (property_id, created_at desc);
create index if not exists ua_action_idx   on public.user_actions (action);

alter table public.user_actions enable row level security;

-- Users can write their own actions and read them back; admins can read/manage all.
drop policy if exists "users insert own actions" on public.user_actions;
create policy "users insert own actions"
  on public.user_actions for insert
  to authenticated
  with check (user_id = auth.uid());

drop policy if exists "users read own actions or admin" on public.user_actions;
create policy "users read own actions or admin"
  on public.user_actions for select
  to authenticated
  using (user_id = auth.uid() or public.is_admin_allowlisted());

drop policy if exists "admins manage actions" on public.user_actions;
create policy "admins manage actions"
  on public.user_actions for all
  to authenticated
  using (public.is_admin_allowlisted())
  with check (public.is_admin_allowlisted());

grant usage on schema public to anon, authenticated;
grant select, insert on public.user_actions to authenticated;
grant delete, update on public.user_actions to authenticated; -- admin-gated by RLS
-- ==================== END user_actions_schema.sql ====================


-- ==================== BEGIN add_whatsapp_to_user_requirements.sql ====================
-- Migration: add the mandatory WhatsApp number to the Find My Flat questionnaire.
-- Safe to run on an existing database (no-op if the column already exists).
-- Run once in the Supabase SQL editor.

alter table public.user_requirements
  add column if not exists whatsapp text default '';
-- ==================== END add_whatsapp_to_user_requirements.sql ====================


-- ==================== BEGIN seed_findmyflat_test_inventory.sql ====================
-- Find My Flat — test inventory seed.
-- Adds three published listings so the Assured/broker rules can be seen on screen:
--   • MZ-SEED01  owner   → shows "★ MovEazy Assured" + "20% Brokerage Off"
--   • MZ-SEED02  tenant  → shows "★ MovEazy Assured" + "20% Brokerage Off"
--   • MZ-SEED03  broker  → ordinary listing, NO "listed by" tag
--
-- Idempotent: fixed property_ids + ON CONFLICT DO UPDATE, so re-running just refreshes.
-- Run in the Supabase SQL editor AFTER inventory_schema.sql. (SQL-editor runs as the
-- service role, so RLS is bypassed and poster_id may be left null.)
--
-- NOTE: "shortlisting" is stored client-side (localStorage) and the user_actions
-- 'shortlist_property' row is written in the browser when you click "Add to site
-- visit" — it cannot be seeded here. Seed = supply only; shortlist in the UI.

insert into public.inventory (
  property_id, posted_by, poster_name, poster_email, phone,
  city, area, full_address, landmark, latitude, longitude,
  rent, deposit, available_from,
  flat_type, bedrooms, bathrooms, furnishing, gender_pref,
  occupants_allowed, amenities, lifestyle,
  title, description, cover_image_url, images,
  status, is_verified
) values
  (
    'MZ-SEED01', 'owner', 'Ramesh (Owner)', 'owner.demo@moveazy.test', '',
    'Bengaluru', 'HSR Layout', '17th Cross, Sector 3, HSR Layout', 'Near Apollo Pharmacy, 17th Cross', 12.9141, 77.6411,
    32000, 100000, current_date,
    '2 BHK', 2, 2, 'Semi-furnished', 'any',
    '{Family,Bachelors}', '{Lift,Parking,Power backup}', '{Pet-friendly}',
    '2 BHK in HSR Layout', 'Bright 2 BHK with balcony, walkable to 27th Main. Direct owner listing.',
    'https://images.unsplash.com/photo-1502672260266-1c1ef2d93688?auto=format&fit=crop&q=80&w=1000',
    '{https://images.unsplash.com/photo-1502672260266-1c1ef2d93688?auto=format&fit=crop&q=80&w=1000}',
    'published', true
  ),
  (
    'MZ-SEED02', 'tenant', 'Priya (Tenant)', 'tenant.demo@moveazy.test', '',
    'Bengaluru', 'Koramangala', '5th Block, Koramangala', '5th Block', 12.9352, 77.6245,
    26000, 80000, current_date,
    '1 BHK', 1, 1, 'Fully Furnished', 'any',
    '{Bachelors,Family}', '{Lift,Gym,Parking}', '{}',
    '1 BHK in Koramangala', 'Fully furnished 1 BHK, tenant leaving city — takeover available.',
    'https://images.unsplash.com/photo-1522708323590-d24dbb6b0267?auto=format&fit=crop&q=80&w=1000',
    '{https://images.unsplash.com/photo-1522708323590-d24dbb6b0267?auto=format&fit=crop&q=80&w=1000}',
    'published', true
  ),
  (
    'MZ-SEED03', 'broker', 'Zippy Homes', 'broker.demo@moveazy.test', '',
    'Bengaluru', 'Indiranagar', '100 Feet Road, Indiranagar', '100 Feet Road', 12.9719, 77.6412,
    55000, 200000, current_date,
    '3 BHK', 3, 3, 'Semi-furnished', 'any',
    '{Family}', '{Lift,Parking,Power backup,Security}', '{}',
    '3 BHK in Indiranagar', 'Spacious 3 BHK near 100 Feet Road. Listed by broker.',
    'https://images.unsplash.com/photo-1505691938895-1758d7feb511?auto=format&fit=crop&q=80&w=1000',
    '{https://images.unsplash.com/photo-1505691938895-1758d7feb511?auto=format&fit=crop&q=80&w=1000}',
    'published', true
  )
on conflict (property_id) do update set
  posted_by       = excluded.posted_by,
  poster_name     = excluded.poster_name,
  area            = excluded.area,
  full_address    = excluded.full_address,
  landmark        = excluded.landmark,
  latitude        = excluded.latitude,
  longitude       = excluded.longitude,
  rent            = excluded.rent,
  deposit         = excluded.deposit,
  flat_type       = excluded.flat_type,
  furnishing      = excluded.furnishing,
  occupants_allowed = excluded.occupants_allowed,
  amenities       = excluded.amenities,
  title           = excluded.title,
  description     = excluded.description,
  cover_image_url = excluded.cover_image_url,
  images          = excluded.images,
  status          = 'published',
  is_verified     = true,
  updated_at      = now();

-- Confirm the seed:
select property_id, posted_by, area, flat_type, rent, status
from public.inventory
where property_id in ('MZ-SEED01','MZ-SEED02','MZ-SEED03')
order by property_id;
-- ==================== END seed_findmyflat_test_inventory.sql ====================

