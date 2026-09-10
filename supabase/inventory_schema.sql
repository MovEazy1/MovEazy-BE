-- Property inventory (fe/src/pages/ListMyFlat.jsx → fe/src/lib/inventory.js).
-- One row per listed home. Every flat gets a human-friendly property_id (MZ-XXXXXX)
-- and is described with the SAME preference vocabulary a seeker uses in
-- "Train My Broker" (fe/src/data/preferenceOptions.js), so a listing can be
-- scored against public.customer_search_profiles (see fe/src/lib/inventoryMatch.js).
--
-- Run once in the Supabase SQL editor alongside customer_schema.sql /
-- broker_schema.sql / admin_schema.sql.

create extension if not exists "pgcrypto";

-- Short, shareable property code: MZ- + 6 upper-alnum chars. Collisions are
-- retried by the client on insert; the unique PK guarantees correctness.
create table if not exists public.inventory (
  property_id     text primary key,

  -- Who put this on the platform, and their identity on each possible side.
  -- posted_by is the role the poster claimed; poster_id is always the auth user
  -- who created the row; the matching tenant/broker/owner id column is filled
  -- from poster_id based on that role.
  posted_by       text not null default 'owner'
                    check (posted_by in ('tenant', 'broker', 'owner')),
  poster_id       uuid references auth.users(id) on delete set null default auth.uid(),
  tenant_id       uuid references auth.users(id) on delete set null,
  broker_id       uuid references auth.users(id) on delete set null,
  owner_id        uuid references auth.users(id) on delete set null,
  poster_name     text default '',
  poster_email    text default '',
  phone           text default '',

  -- Exact location of the flat.
  city            text default 'Bengaluru',
  area            text default '',              -- primary locality (preferenceOptions locality)
  nearby_areas    text[] default '{}',          -- other localities this maps to
  full_address    text default '',              -- exact address, house/flat no.
  landmark        text default '',              -- nearest landmark
  latitude        numeric,
  longitude       numeric,

  -- Commercials.
  rent            numeric not null default 0,
  deposit         numeric default 0,
  available_from  date,

  -- The home itself — mirrors the Train My Broker requirement fields.
  flat_type       text default '',              -- one of FLAT_TYPES
  bedrooms        int default 1,
  bathrooms       int default 1,
  furnishing      text default 'Unfurnished',   -- one of FURNISHINGS
  max_flatmates   int default 0,
  gender_pref     text default 'any',           -- any | male | female
  occupants_allowed text[] default '{}',        -- subset of OCCUPANTS
  amenities       text[] default '{}',          -- subset of MUST_HAVES
  lifestyle       text[] default '{}',          -- subset of LIFESTYLE
  house_rules     text[] default '{}',          -- free tags / restrictions

  -- Presentation.
  title           text default '',
  description     text default '',
  images          text[] default '{}',
  cover_image_url text default '',

  status          text not null default 'published',  -- published | paused | rented
  is_verified     boolean not null default false,
  view_count      int not null default 0,

  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index if not exists inventory_poster_idx    on public.inventory (poster_id, created_at desc);
create index if not exists inventory_area_idx       on public.inventory (lower(area));
create index if not exists inventory_status_rent_idx on public.inventory (status, rent);

alter table public.inventory enable row level security;

-- Anyone (even signed-out) can browse published inventory on the map/listings.
drop policy if exists "anyone reads published inventory" on public.inventory;
create policy "anyone reads published inventory"
  on public.inventory for select
  using (status = 'published' or poster_id = auth.uid() or public.is_admin_allowlisted());

-- A signed-in user may only create rows they own.
drop policy if exists "posters create own inventory" on public.inventory;
create policy "posters create own inventory"
  on public.inventory for insert
  to authenticated
  with check (poster_id = auth.uid());

drop policy if exists "posters update own inventory" on public.inventory;
create policy "posters update own inventory"
  on public.inventory for update
  to authenticated
  using (poster_id = auth.uid() or public.is_admin_allowlisted())
  with check (poster_id = auth.uid() or public.is_admin_allowlisted());

drop policy if exists "posters delete own inventory" on public.inventory;
create policy "posters delete own inventory"
  on public.inventory for delete
  to authenticated
  using (poster_id = auth.uid() or public.is_admin_allowlisted());

-- Raw-SQL tables get no role grants by default; without this every request
-- fails with insufficient_privilege (42501) before RLS is even evaluated.
grant usage on schema public to anon, authenticated;
grant select on public.inventory to anon, authenticated;
grant insert, update, delete on public.inventory to authenticated;
