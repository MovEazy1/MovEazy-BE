-- ─────────────────────────────────────────────────────────────────────────────
-- MovEazy Owners — the owner app (fe/src/pages/owners/*, fe/src/lib/owners.js)
-- and the CRM's Inventory Ops tab (fe/src/pages/crm/CrmInventoryOpsPage.jsx).
--
-- Run ONCE in the Supabase SQL editor, AFTER crm_schema.sql, inventory_schema.sql,
-- visits_schema.sql and tenants_schema.sql. Safe to re-run: every statement is
-- idempotent, and every function whose shape could change is dropped first.
-- Brings normalize_mobile() and is_inventory_poster() itself if their own files
-- have not been run (same definitions; an existing one is never overwritten).
--
-- == What an owner is ==
--
-- A signed-in user with an owner_accounts row. Auto-approve starts ON (the CRM
-- can switch it off), so opening the app, signing in with Google and giving a
-- mobile number is the whole sign-up.
--
-- An owner's properties are the rows in owner_property_links, and nothing else.
-- Flats they posted themselves as the owner through the site are linked when
-- they register; flats the team uploaded for them are linked by hand in the
-- CRM — never by matching a phone number, which is not OTP-verified and would
-- hand a stranger someone else's flat and its tenants.
--
-- == What is deliberately not here ==
--
-- Rent collection, payment history, dues, late fees, receipts and bank details
-- are out of scope for V1. The rent_payments table and the old /rent-management
-- page are untouched; nothing here reads or writes them.
--
-- == Who sees what ==
--
--   owner      their own properties, tenants, ratings, documents and requests.
--              Interested renters appear by first name and initial with what
--              they are looking for — never a phone, email or account id:
--              MovEazy coordinates the visit.
--   CRM staff  everything here except documents (owner + super admin only),
--              because the ops team works the requests and a repair visit
--              needs the tenant's number.
--   brokers    an owner's vacant, listed flat appears in the broker partner
--              app as MovEazy inventory; partner_property_contacts_for() shows
--              MovEazy as the contact for it, never the owner (partner_schema.sql).
-- ─────────────────────────────────────────────────────────────────────────────

create extension if not exists "pgcrypto";

begin;

-- ── Helpers owned by other files, created only when missing ─────────────────
do $$
begin
  if to_regprocedure('public.normalize_mobile(text)') is null then
    execute $f$
      create function public.normalize_mobile(raw text)
      returns text
      language plpgsql
      immutable
      as $b$
      declare
        digits text := regexp_replace(coalesce(raw, ''), '\D', '', 'g');
        local  text;
      begin
        local := case
                   when length(digits) > 10 and left(digits, 2) = '91' then right(digits, 10)
                   else digits
                 end;
        return case when local ~ '^[6-9]\d{9}$' then local else '' end;
      end;
      $b$
    $f$;
  end if;

  if to_regprocedure('public.is_inventory_poster(text)') is null then
    execute $f$
      create function public.is_inventory_poster(pid text)
      returns boolean
      language sql
      stable
      security definer
      set search_path = public
      as $b$
        select auth.uid() is not null and exists (
          select 1 from public.inventory i
           where i.property_id = pid
             and i.poster_id = auth.uid()
        );
      $b$
    $f$;
    execute 'revoke all on function public.is_inventory_poster(text) from public, anon';
    execute 'grant execute on function public.is_inventory_poster(text) to authenticated';
  end if;
end $$;


-- ── Settings ────────────────────────────────────────────────────────────────
create table if not exists public.owner_program_settings (
  id                       int primary key default 1 check (id = 1),
  auto_approve             boolean not null default true,
  -- A quote at or above this needs the owner's yes before work starts; below
  -- it, the team goes ahead (a ₹399 plumber visit should not wait on a tap).
  quote_approval_threshold int not null default 2000 check (quote_approval_threshold >= 0),
  updated_at               timestamptz not null default now(),
  updated_by               text not null default ''
);
insert into public.owner_program_settings (id) values (1) on conflict (id) do nothing;


-- ── Owners and their properties ─────────────────────────────────────────────
create table if not exists public.owner_accounts (
  user_id     uuid primary key references auth.users (id) on delete cascade,
  name        text not null default '',
  phone       text not null default '',
  email       text not null default '',
  status      text not null default 'pending' check (status in ('pending', 'approved', 'suspended')),
  approved_at timestamptz,
  approved_by text not null default '',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists owner_accounts_status_idx on public.owner_accounts (status, created_at desc);

-- One owner per flat. A row here is what makes a flat "theirs" in the app.
create table if not exists public.owner_property_links (
  property_id text primary key references public.inventory (property_id) on delete cascade,
  owner_id    uuid not null references auth.users (id) on delete cascade,
  linked_by   text not null default '',   -- 'auto' | 'self' | the staff email that linked it
  linked_at   timestamptz not null default now()
);
create index if not exists owner_property_links_owner_idx on public.owner_property_links (owner_id, linked_at desc);

-- Carpet area. Public like the other listing facts, so granted to both roles
-- together (a column one role cannot read fails the whole select for it).
alter table public.inventory add column if not exists area_sqft int;
-- Also added by partner_schema.sql; repeated so this file does not depend on it.
alter table public.inventory add column if not exists property_type text not null default '';
grant select (area_sqft, property_type) on public.inventory to anon, authenticated;


-- ── Tenants: the existing table, with what an owner actually keeps ──────────
-- rent_amount / rent_due_day stay as they are for the old Tenant Management
-- page; the owner app does not show or ask for them.
alter table public.tenants add column if not exists occupation     text not null default '';
alter table public.tenants add column if not exists company        text not null default '';
alter table public.tenants add column if not exists linkedin_url   text not null default '';
alter table public.tenants add column if not exists move_in_date   date;
alter table public.tenants add column if not exists lease_end_date date;   -- expected move-out
alter table public.tenants add column if not exists moved_out_on   date;   -- actual
alter table public.tenants add column if not exists notes          text not null default '';

do $$
begin
  alter table public.tenants drop constraint if exists tenants_status_check;
  alter table public.tenants add constraint tenants_status_check
    check (status in ('invited', 'active', 'past', 'removed'));
end $$;

create table if not exists public.owner_tenant_ratings (
  tenant_id  uuid primary key references public.tenants (id) on delete cascade,
  owner_id   uuid not null default auth.uid() references auth.users (id) on delete cascade,
  stars      int not null check (stars between 1 and 5),
  comment    text not null default '',
  updated_at timestamptz not null default now()
);


-- ── Documents (private storage bucket owner-docs) ───────────────────────────
create table if not exists public.owner_documents (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  property_id  text references public.inventory (property_id) on delete cascade,
  tenant_id    uuid references public.tenants (id) on delete set null,
  kind         text not null default 'other'
                 check (kind in ('agreement', 'police_verification', 'move_in', 'other')),
  title        text not null default '',
  storage_path text not null,
  mime         text not null default '',
  size_bytes   bigint not null default 0,
  created_at   timestamptz not null default now()
);
create index if not exists owner_documents_owner_idx on public.owner_documents (owner_id, created_at desc);


-- ── Services, repairs and designer calls ────────────────────────────────────
create table if not exists public.owner_service_catalogue (
  id          text primary key,
  category    text not null default 'repairs'
                check (category in ('cleaning', 'repairs', 'appliances', 'painting', 'other')),
  title       text not null,
  from_price  int not null default 0,
  summary     text not null default '',
  scope       text not null default '',        -- one line per item included
  duration    text not null default '',
  popular     boolean not null default false,
  sort        int not null default 100,
  active      boolean not null default true,
  updated_at  timestamptz not null default now()
);
insert into public.owner_service_catalogue (id, category, title, from_price, summary, scope, duration, popular, sort) values
  ('deep-cleaning', 'cleaning', 'Deep Cleaning', 1999, 'Professional home cleaning',
   E'Kitchen degreasing and appliance exteriors\nBathroom descaling\nFloors, windows and fans\nBalcony and wardrobes (outside)', '4–6 hours', true, 10),
  ('ac-service', 'appliances', 'AC Service', 499, 'AC installation, service & repair',
   E'Filter and coil cleaning\nGas pressure check\nDrainage check\nRepair quoted separately if needed', '45–60 min', true, 20),
  ('plumbing', 'repairs', 'Plumbing Repair', 399, 'Leakage, tap, pipeline repair',
   E'Leaks, taps and mixers\nBlocked drains\nFlush tanks and fittings\nParts charged at actuals', '30–90 min', true, 30),
  ('electrical', 'repairs', 'Electrical Work', 399, 'Wiring, lights, fittings',
   E'Switches, sockets and lights\nFans and fixtures\nMCB and wiring faults\nParts charged at actuals', '30–90 min', true, 40),
  ('painting', 'painting', 'Painting Service', 1999, 'Interior & exterior painting',
   E'Site visit and colour consult\nWall preparation and putty\nTwo coats, premium emulsion\nPriced per area after the visit', '1–4 days', true, 50),
  ('appliance-repair', 'appliances', 'Appliance Repair', 349, 'Washing machine, fridge, geyser',
   E'Diagnosis visit\nCommon parts replaced on the spot\nRepair quoted before work starts', '45–90 min', false, 60),
  ('carpentry', 'repairs', 'Carpentry', 399, 'Doors, hinges, wardrobes, furniture',
   E'Door and hinge alignment\nLocks and handles\nWardrobe and drawer repairs', '30–120 min', false, 70),
  ('pest-control', 'cleaning', 'Pest Control', 999, 'Cockroach, ant and general pest treatment',
   E'Kitchen and bathroom gel treatment\nSpray for common areas\nOdourless, safe for pets after drying', '1–2 hours', false, 80)
on conflict (id) do nothing;

create table if not exists public.owner_requests (
  id              uuid primary key default gen_random_uuid(),
  owner_id        uuid not null references auth.users (id) on delete cascade,
  property_id     text not null references public.inventory (property_id) on delete cascade,
  kind            text not null check (kind in ('repair', 'service', 'designer_call')),
  category        text not null default 'other',
  service_id      text references public.owner_service_catalogue (id) on delete set null,
  property_ids    text[] not null default '{}',   -- a designer call can cover the whole portfolio
  title           text not null default '',
  description     text not null default '',
  photos          text[] not null default '{}',   -- owner-docs storage paths under the owner's folder
  preferred_date  date,
  preferred_slot  text not null default 'any' check (preferred_slot in ('morning', 'afternoon', 'evening', 'any')),
  status          text not null default 'open'
                    check (status in ('open', 'scheduled', 'in_progress', 'awaiting_approval', 'resolved', 'cancelled')),
  vendor_name     text not null default '',
  vendor_phone    text not null default '',
  scheduled_at    timestamptz,
  quote_amount    numeric,
  quote_note      text not null default '',
  quote_status    text not null default 'none' check (quote_status in ('none', 'pending', 'approved', 'declined')),
  final_cost      numeric,
  resolved_at     timestamptz,
  -- Ops only. Never returned to the owner (owner_requests_list() omits both).
  assigned_to     text not null default '',
  internal_note   text not null default '',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists owner_requests_owner_idx on public.owner_requests (owner_id, created_at desc);
create index if not exists owner_requests_status_idx on public.owner_requests (status, created_at desc);

-- The timeline. visible_to_owner separates what the owner reads from notes the
-- team keeps for itself.
create table if not exists public.owner_request_events (
  id               uuid primary key default gen_random_uuid(),
  request_id       uuid not null references public.owner_requests (id) on delete cascade,
  at               timestamptz not null default now(),
  actor            text not null default 'system' check (actor in ('owner', 'staff', 'system')),
  kind             text not null default 'note',
  message          text not null default '',
  visible_to_owner boolean not null default true
);
create index if not exists owner_request_events_request_idx on public.owner_request_events (request_id, at);


-- ── Predicates ──────────────────────────────────────────────────────────────
create or replace function public.is_approved_owner()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and exists (
    select 1 from public.owner_accounts o where o.user_id = auth.uid() and o.status = 'approved'
  );
$$;

create or replace function public.owner_has_property(pid text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and exists (
    select 1 from public.owner_property_links l where l.property_id = pid and l.owner_id = auth.uid()
  );
$$;

/** "Rahul Mehta" → "Rahul M." — how an owner sees an interested renter. */
create or replace function public.owner_display_name(full_name text)
returns text
language sql
immutable
as $$
  select case
    when coalesce(trim(full_name), '') = '' or position('@' in full_name) > 0 then 'MovEazy renter'
    else initcap(split_part(regexp_replace(trim(full_name), '\s+', ' ', 'g'), ' ', 1))
      || coalesce(
           ' ' || upper(left(nullif(regexp_replace(trim(full_name), '^.*\s', ''), trim(full_name)), 1)) || '.',
           '')
  end;
$$;


-- ── Sign-up and "who am I" ──────────────────────────────────────────────────
-- Called on every app open: idempotent, refreshes the number from the profile,
-- and links any flat the owner has since posted through the site.
create or replace function public.owner_register(p_name text default null)
returns public.owner_accounts
language plpgsql
security definer
set search_path = public
as $$
declare
  uid   uuid := auth.uid();
  prof  public.user_profiles;
  phone text;
  auto  boolean;
  rec   public.owner_accounts;
begin
  if uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;

  select * into prof from public.user_profiles where id = uid;
  phone := public.normalize_mobile(coalesce(prof.phone, ''));
  if phone = '' then
    raise exception 'Add your mobile number first.' using errcode = '22023';
  end if;

  select s.auto_approve into auto from public.owner_program_settings s where s.id = 1;

  insert into public.owner_accounts as oa (user_id, name, phone, email, status, approved_at, approved_by)
  values (
    uid,
    left(coalesce(nullif(trim(p_name), ''), nullif(prof.name, ''), split_part(coalesce(auth.jwt() ->> 'email', ''), '@', 1)), 120),
    phone,
    lower(coalesce(auth.jwt() ->> 'email', '')),
    case when coalesce(auto, true) then 'approved' else 'pending' end,
    case when coalesce(auto, true) then now() end,
    case when coalesce(auto, true) then 'auto' else '' end
  )
  -- A decision already made is never changed by opening the app again.
  on conflict (user_id) do update
     set name = coalesce(nullif(left(trim(p_name), 120), ''), oa.name),
         phone = excluded.phone,
         updated_at = now()
  returning * into rec;

  -- Flats they posted themselves, as the owner, through the site. Not CRM
  -- uploads (source 'crm' and friends): a staff member who opened the app
  -- must not inherit every flat they ever typed in for someone else.
  if rec.status <> 'suspended' and not public.is_crm_staff() then
    insert into public.owner_property_links (property_id, owner_id, linked_by)
    select i.property_id, uid, 'auto'
      from public.inventory i
     where i.poster_id = uid
       and i.posted_by = 'owner'
       and coalesce(i.source, '') in ('', 'owner_app', 'list_my_flat')
    on conflict (property_id) do nothing;
  end if;
  return rec;
end;
$$;

create or replace function public.owner_me()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'owner', (select to_jsonb(o) from public.owner_accounts o where o.user_id = auth.uid()),
    'staff', public.is_crm_staff(),
    'can_manage', public.has_admin_scope('inventory.ops'),
    'quote_approval_threshold', (select s.quote_approval_threshold from public.owner_program_settings s where s.id = 1)
  );
$$;


-- ── Properties ──────────────────────────────────────────────────────────────
drop function if exists public.owner_properties();
create function public.owner_properties()
returns table (
  property_id     text,
  status          text,
  title           text,
  city            text,
  area            text,
  nearby_areas    text[],
  full_address    text,
  landmark        text,
  latitude        numeric,
  longitude       numeric,
  rent            numeric,
  deposit         numeric,
  available_from  date,
  property_type   text,
  flat_type       text,
  bedrooms        int,
  bathrooms       int,
  furnishing      text,
  area_sqft       int,
  amenities       text[],
  description     text,
  images          text[],
  cover_image_url text,
  view_count      int,
  created_at      timestamptz,
  updated_at      timestamptz,
  linked_at       timestamptz,
  likes           int,
  visit_requests  int,
  visits_booked   int,
  upcoming_visits int,
  shortlisted     int,
  open_requests   int,
  active_tenants  int
)
language sql
stable
security definer
set search_path = public
as $$
  select
    i.property_id, i.status, i.title, i.city, i.area, i.nearby_areas, i.full_address, i.landmark,
    i.latitude, i.longitude, i.rent, i.deposit, i.available_from, i.property_type, i.flat_type,
    i.bedrooms, i.bathrooms, i.furnishing, i.area_sqft, i.amenities, i.description, i.images,
    i.cover_image_url, coalesce(i.view_count, 0), i.created_at, i.updated_at, l.linked_at,
    (select count(*)::int from public.listing_reactions r
      where r.property_id = i.property_id and r.reaction = 'like'),
    (select count(*)::int from public.visit_bookings b
      where b.property_id = i.property_id and coalesce(b.status, '') not ilike 'cancel%'
        and (b.status = 'preference' or b.slot_at is null)),
    (select count(*)::int from public.visit_bookings b
      where b.property_id = i.property_id and coalesce(b.status, '') not ilike 'cancel%'
        and b.status <> 'preference' and b.slot_at is not null),
    (select count(*)::int from public.visit_bookings b
      where b.property_id = i.property_id and coalesce(b.status, '') not ilike 'cancel%'
        and b.status <> 'preference' and b.slot_at > now()),
    (select count(*)::int from public.crm_shortlists s
      where s.property_id = i.property_id and s.status in ('shared', 'liked', 'okay', 'visited')),
    (select count(*)::int from public.owner_requests q
      where q.property_id = i.property_id and q.status not in ('resolved', 'cancelled')),
    (select count(*)::int from public.tenants t
      where t.property_id = i.property_id and t.poster_id = l.owner_id and t.status in ('active', 'invited'))
  from public.owner_property_links l
  join public.inventory i on i.property_id = l.property_id
  where l.owner_id = auth.uid()
    and public.is_approved_owner()
  order by l.linked_at desc;
$$;

/** A flat the owner just created in the app becomes theirs. */
create or replace function public.owner_claim_property(p_property text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_approved_owner() then
    raise exception 'Your owner account is not active.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.inventory i where i.property_id = p_property and i.poster_id = auth.uid()) then
    raise exception 'You can only add flats you listed yourself.' using errcode = '42501';
  end if;
  insert into public.owner_property_links (property_id, owner_id, linked_by)
  values (p_property, auth.uid(), 'self')
  on conflict (property_id) do nothing;
  if not public.owner_has_property(p_property) then
    raise exception 'This flat is already linked to another owner. Contact MovEazy.' using errcode = '42501';
  end if;
end;
$$;

/**
 * Change one of your flats. Whitelisted fields only; status is the three the
 * app offers: published (finding a tenant, live on moveazy.co.in and the
 * broker network), paused (vacant, not listed), rented (occupied, off the site).
 */
create or replace function public.owner_update_property(p_property text, p_patch jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  st text := p_patch ->> 'status';
begin
  if not (public.is_approved_owner() and public.owner_has_property(p_property)) then
    raise exception 'That is not one of your properties.' using errcode = '42501';
  end if;
  if st is not null and st not in ('published', 'paused', 'rented') then
    raise exception 'Unknown status.' using errcode = '22023';
  end if;
  if p_patch ? 'rent' and coalesce(nullif(p_patch ->> 'rent', '')::numeric, 0) < 1000 then
    raise exception 'Enter the monthly rent.' using errcode = '22023';
  end if;

  update public.inventory i set
    title           = case when p_patch ? 'title' then left(coalesce(p_patch ->> 'title', ''), 160) else i.title end,
    description     = case when p_patch ? 'description' then left(coalesce(p_patch ->> 'description', ''), 2000) else i.description end,
    rent            = case when p_patch ? 'rent' then (p_patch ->> 'rent')::numeric else i.rent end,
    deposit         = case when p_patch ? 'deposit' then coalesce(nullif(p_patch ->> 'deposit', '')::numeric, 0) else i.deposit end,
    furnishing      = case when p_patch ? 'furnishing' then coalesce(p_patch ->> 'furnishing', i.furnishing) else i.furnishing end,
    property_type   = case when p_patch ? 'property_type' then coalesce(p_patch ->> 'property_type', '') else i.property_type end,
    flat_type       = case when p_patch ? 'flat_type' then coalesce(p_patch ->> 'flat_type', '') else i.flat_type end,
    bedrooms        = case when p_patch ? 'bedrooms' then coalesce(nullif(p_patch ->> 'bedrooms', '')::int, i.bedrooms) else i.bedrooms end,
    bathrooms       = case when p_patch ? 'bathrooms' then coalesce(nullif(p_patch ->> 'bathrooms', '')::int, i.bathrooms) else i.bathrooms end,
    area            = case when p_patch ? 'area' then coalesce(nullif(trim(p_patch ->> 'area'), ''), i.area) else i.area end,
    nearby_areas    = case when p_patch ? 'nearby_areas'
                        then array(select jsonb_array_elements_text(p_patch -> 'nearby_areas')) else i.nearby_areas end,
    full_address    = case when p_patch ? 'full_address' then left(coalesce(p_patch ->> 'full_address', ''), 400) else i.full_address end,
    landmark        = case when p_patch ? 'landmark' then left(coalesce(p_patch ->> 'landmark', ''), 200) else i.landmark end,
    latitude        = case when p_patch ? 'latitude' then nullif(p_patch ->> 'latitude', '')::numeric else i.latitude end,
    longitude       = case when p_patch ? 'longitude' then nullif(p_patch ->> 'longitude', '')::numeric else i.longitude end,
    available_from  = case when p_patch ? 'available_from' then nullif(p_patch ->> 'available_from', '')::date else i.available_from end,
    area_sqft       = case when p_patch ? 'area_sqft' then nullif(p_patch ->> 'area_sqft', '')::int else i.area_sqft end,
    amenities       = case when p_patch ? 'amenities'
                        then array(select jsonb_array_elements_text(p_patch -> 'amenities')) else i.amenities end,
    images          = case when p_patch ? 'images'
                        then array(select jsonb_array_elements_text(p_patch -> 'images')) else i.images end,
    cover_image_url = case when p_patch ? 'cover_image_url' then coalesce(p_patch ->> 'cover_image_url', '') else i.cover_image_url end,
    status          = coalesce(st, i.status),
    updated_at      = now()
  where i.property_id = p_property;
end;
$$;


-- ── Find a tenant: who is interested ────────────────────────────────────────
-- Every renter who booked or asked to see the flat, liked it, or was sent it
-- by the MovEazy team. First name and initial, what they are looking for, and
-- their visit time. No phone, email or id: the team coordinates, and `key` is
-- a hash so the app can tell people apart without learning who they are.
drop function if exists public.owner_property_candidates(text);
create function public.owner_property_candidates(p_property text)
returns table (
  key          text,
  display_name text,
  best         text,        -- visit_booked | visited | visit_requested | shortlisted | liked
  signals      text[],
  next_visit   timestamptz,
  last_at      timestamptz,
  occupants    text[],
  budget_max   numeric,
  flat_types   text[]
)
language sql
stable
security definer
set search_path = public
as $$
  with allowed as (
    select public.is_crm_staff() or (public.is_approved_owner() and public.owner_has_property(p_property)) as ok
  ),
  sig as (
    select b.user_id, null::uuid as client_id,
           case when b.status = 'preference' or b.slot_at is null then 'visit_requested'
                when b.slot_at < now() then 'visited'
                else 'visit_booked' end as signal,
           b.slot_at, b.created_at as at
      from public.visit_bookings b
     where b.property_id = p_property and coalesce(b.status, '') not ilike 'cancel%'
    union all
    select r.user_id, null::uuid, 'liked', null::timestamptz, r.updated_at
      from public.listing_reactions r
     where r.property_id = p_property and r.reaction = 'like'
    union all
    select c.user_id, c.id, 'shortlisted', null::timestamptz, coalesce(s.shared_at, s.created_at)
      from public.crm_shortlists s
      join public.crm_clients c on c.id = s.client_id
     where s.property_id = p_property and s.status in ('shared', 'liked', 'okay', 'visited')
  ),
  keyed as (
    select case when user_id is not null then 'u:' || user_id::text else 'c:' || client_id::text end as k,
           user_id, client_id, signal, slot_at, at,
           case signal when 'visit_booked' then 1 when 'visited' then 2 when 'visit_requested' then 3
                       when 'shortlisted' then 4 else 5 end as rank
      from sig
  ),
  people as (
    select k,
           (array_agg(user_id) filter (where user_id is not null))[1] as user_id,
           (array_agg(client_id) filter (where client_id is not null))[1] as client_id,
           (array_agg(signal order by rank))[1] as best,
           array_agg(distinct signal) as signals,
           min(slot_at) filter (where signal = 'visit_booked') as next_visit,
           max(at) as last_at
      from keyed
     group by k
  )
  select
    md5(p.k),
    public.owner_display_name(coalesce(
      nullif((select up.name from public.user_profiles up where up.id = p.user_id), ''),
      (select c.name from public.crm_clients c where c.id = p.client_id or (p.client_id is null and c.user_id = p.user_id) limit 1)
    )),
    p.best,
    p.signals,
    p.next_visit,
    p.last_at,
    coalesce((select ur.occupants from public.user_requirements ur where ur.user_id = p.user_id),
             (select cr.occupants from public.crm_client_requirements cr
                join public.crm_clients c on c.id = cr.client_id
               where c.id = p.client_id or (p.client_id is null and c.user_id = p.user_id) limit 1),
             '{}'),
    coalesce((select ur.budget_max from public.user_requirements ur where ur.user_id = p.user_id),
             (select cr.budget_max from public.crm_client_requirements cr
                join public.crm_clients c on c.id = cr.client_id
               where c.id = p.client_id or (p.client_id is null and c.user_id = p.user_id) limit 1)),
    coalesce((select ur.flat_types from public.user_requirements ur where ur.user_id = p.user_id),
             (select cr.flat_types from public.crm_client_requirements cr
                join public.crm_clients c on c.id = cr.client_id
               where c.id = p.client_id or (p.client_id is null and c.user_id = p.user_id) limit 1),
             '{}')
  from people p, allowed a
  where a.ok
  order by case p.best when 'visit_booked' then 1 when 'visited' then 2 when 'visit_requested' then 3
                       when 'shortlisted' then 4 else 5 end,
           p.next_visit nulls last, p.last_at desc;
$$;


-- ── Increase rent: what similar flats nearby go for ─────────────────────────
-- Same BHK in the same locality (or a locality this flat is also in), from
-- MovEazy's own live and recently rented stock. Too few to say anything? The
-- same BHK across Bengaluru, labelled as such. Rounded to ₹500: it is a
-- rough guide, and false precision would read as a promise.
create or replace function public.owner_area_rent(p_property text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v      public.inventory;
  n      int;
  p25    numeric;
  med    numeric;
  p75    numeric;
  scope  text;
  bhk    text;
begin
  if not (public.is_crm_staff() or (public.is_approved_owner() and public.owner_has_property(p_property))) then
    return null;
  end if;
  select * into v from public.inventory i where i.property_id = p_property;
  if not found then return null; end if;
  bhk := regexp_replace(lower(coalesce(v.flat_type, '')), '\s', '', 'g');

  select count(*), percentile_cont(0.25) within group (order by i.rent),
         percentile_cont(0.5) within group (order by i.rent), percentile_cont(0.75) within group (order by i.rent)
    into n, p25, med, p75
    from public.inventory i
   where i.property_id <> p_property
     and i.status in ('published', 'rented')
     and i.rent between 3000 and 1000000
     and (case when bhk <> '' then regexp_replace(lower(coalesce(i.flat_type, '')), '\s', '', 'g') = bhk
               else i.bedrooms = v.bedrooms end)
     and (lower(i.area) = lower(v.area)
          or lower(v.area) = any (select lower(x) from unnest(coalesce(i.nearby_areas, '{}')) x)
          or lower(i.area) = any (select lower(x) from unnest(coalesce(v.nearby_areas, '{}')) x));
  scope := v.area;

  if n < 3 then
    select count(*), percentile_cont(0.25) within group (order by i.rent),
           percentile_cont(0.5) within group (order by i.rent), percentile_cont(0.75) within group (order by i.rent)
      into n, p25, med, p75
      from public.inventory i
     where i.property_id <> p_property
       and i.status in ('published', 'rented')
       and i.rent between 3000 and 1000000
       and (case when bhk <> '' then regexp_replace(lower(coalesce(i.flat_type, '')), '\s', '', 'g') = bhk
                 else i.bedrooms = v.bedrooms end);
    scope := 'Bengaluru';
  end if;

  return jsonb_build_object(
    'scope', scope,
    'bhk', coalesce(nullif(v.flat_type, ''), v.bedrooms || ' BHK'),
    'count', n,
    'low', round(p25 / 500) * 500,
    'median', round(med / 500) * 500,
    'high', round(p75 / 500) * 500,
    'your_rent', v.rent
  );
end;
$$;


-- ── Requests: repairs, services, designer calls ─────────────────────────────
create or replace function public.owner_create_request(p jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid   uuid := auth.uid();
  k     text := p ->> 'kind';
  pid   text := nullif(p ->> 'property_id', '');
  pids  text[] := '{}';
  pics  text[] := '{}';
  svc   public.owner_service_catalogue;
  ttl   text;
  cat   text := coalesce(nullif(p ->> 'category', ''), 'other');
  rid   uuid;
  slot  text := coalesce(nullif(p ->> 'preferred_slot', ''), 'any');
begin
  if not public.is_approved_owner() then
    raise exception 'Your owner account is not active.' using errcode = '42501';
  end if;
  if k is null or k not in ('repair', 'service', 'designer_call') then
    raise exception 'Unknown request type.' using errcode = '22023';
  end if;

  if k = 'designer_call' then
    if jsonb_typeof(p -> 'property_ids') = 'array' then
      pids := array(select jsonb_array_elements_text(p -> 'property_ids'));
    end if;
    if cardinality(pids) = 0 then
      pids := array(select l.property_id from public.owner_property_links l where l.owner_id = uid order by l.linked_at);
    end if;
    if cardinality(pids) = 0 then
      raise exception 'Add a property first.' using errcode = '22023';
    end if;
    if exists (select 1 from unnest(pids) x where not public.owner_has_property(x)) then
      raise exception 'That is not one of your properties.' using errcode = '42501';
    end if;
    pid := coalesce(pid, pids[1]);
    cat := 'designer';
  end if;

  if pid is null or not public.owner_has_property(pid) then
    raise exception 'Pick one of your properties.' using errcode = '42501';
  end if;

  if k = 'service' then
    select * into svc from public.owner_service_catalogue s where s.id = p ->> 'service_id' and s.active;
    if not found then
      raise exception 'That service is not available.' using errcode = '22023';
    end if;
    cat := svc.category;
  end if;

  if jsonb_typeof(p -> 'photos') = 'array' then
    pics := array(select jsonb_array_elements_text(p -> 'photos'));
    -- Only files in the owner's own folder: a path is a claim on a file.
    if exists (select 1 from unnest(pics) x where x not like uid::text || '/%') then
      raise exception 'Photos must be uploaded from this account.' using errcode = '22023';
    end if;
  end if;

  if slot not in ('morning', 'afternoon', 'evening', 'any') then slot := 'any'; end if;

  ttl := left(coalesce(nullif(trim(p ->> 'title'), ''),
    case k when 'designer_call' then 'Home Designer call'
           when 'service' then svc.title
           else initcap(replace(cat, '_', ' ')) || ' repair' end), 120);

  insert into public.owner_requests
    (owner_id, property_id, kind, category, service_id, property_ids, title, description, photos, preferred_date, preferred_slot)
  values
    (uid, pid, k, cat, svc.id, case when k = 'designer_call' then pids else array[pid] end, ttl,
     left(coalesce(p ->> 'description', ''), 2000), pics, nullif(p ->> 'preferred_date', '')::date, slot)
  returning id into rid;

  insert into public.owner_request_events (request_id, actor, kind, message)
  values (rid, 'owner', 'created',
          case k when 'designer_call' then 'Designer call requested' when 'service' then 'Service booked' else 'Repair requested' end);

  -- The CRM inbox. Guarded: crm_payments.sql creates it, and a project without
  -- it should still take the request.
  if to_regclass('public.crm_notifications') is not null then
    insert into public.crm_notifications (for_email, type, title, body, actor_email)
    values ('yatharth200018@gmail.com', 'owner_request', ttl,
            coalesce((select o.name from public.owner_accounts o where o.user_id = uid), 'An owner') || ' · ' || pid,
            lower(coalesce(auth.jwt() ->> 'email', '')));
  end if;
  return rid;
end;
$$;

-- What the owner sees of their requests: no assignee, no internal note.
drop function if exists public.owner_requests_list();
create function public.owner_requests_list()
returns table (
  id uuid, property_id text, property_ids text[], kind text, category text, service_id text, title text,
  description text, photos text[], preferred_date date, preferred_slot text, status text,
  vendor_name text, vendor_phone text, scheduled_at timestamptz, quote_amount numeric, quote_note text,
  quote_status text, final_cost numeric, resolved_at timestamptz, created_at timestamptz, updated_at timestamptz,
  events jsonb
)
language sql
stable
security definer
set search_path = public
as $$
  select q.id, q.property_id, q.property_ids, q.kind, q.category, q.service_id, q.title, q.description, q.photos,
         q.preferred_date, q.preferred_slot, q.status, q.vendor_name, q.vendor_phone, q.scheduled_at,
         q.quote_amount, q.quote_note, q.quote_status, q.final_cost, q.resolved_at, q.created_at, q.updated_at,
         coalesce((select jsonb_agg(jsonb_build_object('at', e.at, 'actor', e.actor, 'kind', e.kind, 'message', e.message)
                                    order by e.at)
                     from public.owner_request_events e
                    where e.request_id = q.id and e.visible_to_owner), '[]'::jsonb)
    from public.owner_requests q
   where q.owner_id = auth.uid()
     and public.is_approved_owner()
   order by q.created_at desc;
$$;

create or replace function public.owner_respond_quote(p_request uuid, p_approve boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare q public.owner_requests;
begin
  select * into q from public.owner_requests r where r.id = p_request and r.owner_id = auth.uid() for update;
  if not found or not public.is_approved_owner() then
    raise exception 'Request not found.' using errcode = '42501';
  end if;
  if q.quote_status <> 'pending' then
    raise exception 'There is no quote waiting for you on this request.' using errcode = '22023';
  end if;
  update public.owner_requests
     set quote_status = case when p_approve then 'approved' else 'declined' end,
         status = case when p_approve then (case when scheduled_at is not null then 'scheduled' else 'in_progress' end)
                       else 'open' end,
         updated_at = now()
   where id = p_request;
  insert into public.owner_request_events (request_id, actor, kind, message)
  values (p_request, 'owner', case when p_approve then 'approved' else 'declined' end,
          case when p_approve then 'You approved the quote of ₹' || trim(to_char(q.quote_amount, 'FM99,99,99,999'))
               else 'You declined the quote' end);
end;
$$;

create or replace function public.owner_cancel_request(p_request uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_approved_owner() then
    raise exception 'Request not found.' using errcode = '42501';
  end if;
  update public.owner_requests
     set status = 'cancelled', updated_at = now()
   where id = p_request and owner_id = auth.uid() and status not in ('resolved', 'cancelled');
  if not found then
    raise exception 'This request can no longer be cancelled.' using errcode = '22023';
  end if;
  insert into public.owner_request_events (request_id, actor, kind, message)
  values (p_request, 'owner', 'cancelled', 'You cancelled this request');
end;
$$;


-- ── Notifications for the owner ─────────────────────────────────────────────
drop function if exists public.owner_activity(int);
create function public.owner_activity(p_days int default 30)
returns table (kind text, property_id text, request_id uuid, who text, slot_at timestamptz, message text, at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  with mine as (
    select l.property_id from public.owner_property_links l
     where l.owner_id = auth.uid() and public.is_approved_owner()
  )
  select * from (
    select case when b.status = 'preference' or b.slot_at is null then 'visit_requested' else 'visit_booked' end,
           b.property_id, null::uuid,
           public.owner_display_name((select up.name from public.user_profiles up where up.id = b.user_id)),
           b.slot_at, ''::text, b.created_at
      from public.visit_bookings b
     where b.property_id in (select property_id from mine)
       and coalesce(b.status, '') not ilike 'cancel%'
       and b.created_at > now() - make_interval(days => p_days)
    union all
    select 'liked', r.property_id, null::uuid,
           public.owner_display_name((select up.name from public.user_profiles up where up.id = r.user_id)),
           null::timestamptz, ''::text, r.updated_at
      from public.listing_reactions r
     where r.property_id in (select property_id from mine)
       and r.reaction = 'like'
       and r.updated_at > now() - make_interval(days => p_days)
    union all
    select 'request_update', q.property_id, q.id, ''::text, null::timestamptz, q.title || ': ' || e.message, e.at
      from public.owner_request_events e
      join public.owner_requests q on q.id = e.request_id
     where q.owner_id = auth.uid()
       and e.visible_to_owner and e.actor <> 'owner'
       and e.at > now() - make_interval(days => p_days)
  ) ev
  order by 7 desc
  limit 60;
$$;


-- ── Inventory Ops (CRM) ─────────────────────────────────────────────────────
/**
 * The team's one write on a request. Every field optional; each change that
 * matters to the owner leaves a visible event. A quote at or above the
 * threshold waits for the owner; below it, it is approved on the spot.
 */
create or replace function public.ops_update_request(p_request uuid, p_patch jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  q      public.owner_requests;
  thr    int;
  st     text := nullif(p_patch ->> 'status', '');
  amount numeric := nullif(p_patch ->> 'quote_amount', '')::numeric;
  msg    text := nullif(trim(coalesce(p_patch ->> 'message', '')), '');
  labels jsonb := '{"open":"Open","scheduled":"Scheduled","in_progress":"In progress","awaiting_approval":"Awaiting your approval","resolved":"Resolved","cancelled":"Cancelled"}';
begin
  if not public.has_admin_scope('inventory.ops') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  select * into q from public.owner_requests r where r.id = p_request for update;
  if not found then raise exception 'Request not found.' using errcode = '22023'; end if;
  if st is not null and st not in ('open', 'scheduled', 'in_progress', 'awaiting_approval', 'resolved', 'cancelled') then
    raise exception 'Unknown status.' using errcode = '22023';
  end if;
  select s.quote_approval_threshold into thr from public.owner_program_settings s where s.id = 1;

  update public.owner_requests r set
    vendor_name   = case when p_patch ? 'vendor_name' then left(coalesce(p_patch ->> 'vendor_name', ''), 120) else r.vendor_name end,
    vendor_phone  = case when p_patch ? 'vendor_phone' then left(coalesce(p_patch ->> 'vendor_phone', ''), 20) else r.vendor_phone end,
    scheduled_at  = case when p_patch ? 'scheduled_at' then nullif(p_patch ->> 'scheduled_at', '')::timestamptz else r.scheduled_at end,
    quote_note    = case when p_patch ? 'quote_note' then left(coalesce(p_patch ->> 'quote_note', ''), 500) else r.quote_note end,
    final_cost    = case when p_patch ? 'final_cost' then nullif(p_patch ->> 'final_cost', '')::numeric else r.final_cost end,
    assigned_to   = case when p_patch ? 'assigned_to' then coalesce(p_patch ->> 'assigned_to', '') else r.assigned_to end,
    internal_note = case when p_patch ? 'internal_note' then left(coalesce(p_patch ->> 'internal_note', ''), 2000) else r.internal_note end,
    updated_at    = now()
  where r.id = p_request;

  if amount is not null and amount is distinct from q.quote_amount then
    if amount >= coalesce(thr, 2000) then
      update public.owner_requests set quote_amount = amount, quote_status = 'pending', status = 'awaiting_approval'
       where id = p_request;
      insert into public.owner_request_events (request_id, actor, kind, message)
      values (p_request, 'staff', 'quote', 'Quote of ₹' || trim(to_char(amount, 'FM99,99,99,999')) || ' is waiting for your approval');
      st := null;  -- the quote decides the status
    else
      update public.owner_requests set quote_amount = amount, quote_status = 'approved' where id = p_request;
      insert into public.owner_request_events (request_id, actor, kind, message)
      values (p_request, 'staff', 'quote', 'Quote of ₹' || trim(to_char(amount, 'FM99,99,99,999')) || ' (under ₹'
              || trim(to_char(coalesce(thr, 2000), 'FM99,99,999')) || ', approved automatically)');
    end if;
  end if;

  if st is not null and st is distinct from q.status then
    update public.owner_requests
       set status = st,
           resolved_at = case when st = 'resolved' then now() else resolved_at end
     where id = p_request;
    insert into public.owner_request_events (request_id, actor, kind, message)
    values (p_request, 'staff', 'status', 'Status: ' || coalesce(labels ->> st, st));
  end if;

  if p_patch ? 'scheduled_at' and nullif(p_patch ->> 'scheduled_at', '') is not null
     and (nullif(p_patch ->> 'scheduled_at', '')::timestamptz) is distinct from q.scheduled_at then
    insert into public.owner_request_events (request_id, actor, kind, message)
    values (p_request, 'staff', 'scheduled', 'Visit scheduled for '
            || to_char((p_patch ->> 'scheduled_at')::timestamptz at time zone 'Asia/Kolkata', 'Dy DD Mon, HH12:MI AM'));
  end if;

  if msg is not null then
    insert into public.owner_request_events (request_id, actor, kind, message, visible_to_owner)
    values (p_request, 'staff', 'note', left(msg, 1000), coalesce((p_patch ->> 'message_internal')::boolean, false) = false);
  end if;
end;
$$;

drop function if exists public.owner_admin_list();
create function public.owner_admin_list()
returns table (user_id uuid, name text, phone text, email text, status text, created_at timestamptz,
               approved_at timestamptz, approved_by text, property_count int, tenant_count int, open_requests int)
language sql
stable
security definer
set search_path = public
as $$
  select o.user_id, o.name, o.phone, o.email, o.status, o.created_at, o.approved_at, o.approved_by,
         (select count(*)::int from public.owner_property_links l where l.owner_id = o.user_id),
         (select count(*)::int from public.tenants t
           where t.poster_id = o.user_id and t.status in ('active', 'invited')),
         (select count(*)::int from public.owner_requests q
           where q.owner_id = o.user_id and q.status not in ('resolved', 'cancelled'))
    from public.owner_accounts o
   where public.is_crm_staff()
   order by case o.status when 'pending' then 0 when 'approved' then 1 else 2 end, o.created_at desc;
$$;

create or replace function public.owner_admin_set_status(p_user uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.has_admin_scope('inventory.ops') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  if p_status not in ('pending', 'approved', 'suspended') then
    raise exception 'Unknown status.' using errcode = '22023';
  end if;
  update public.owner_accounts
     set status = p_status,
         approved_at = case when p_status = 'approved' then now() else approved_at end,
         approved_by = case when p_status = 'approved' then lower(coalesce(auth.jwt() ->> 'email', '')) else approved_by end,
         updated_at = now()
   where user_id = p_user;
end;
$$;

create or replace function public.owner_admin_settings(p_auto_approve boolean default null, p_threshold int default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.has_admin_scope('inventory.ops') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  update public.owner_program_settings
     set auto_approve = coalesce(p_auto_approve, auto_approve),
         quote_approval_threshold = coalesce(p_threshold, quote_approval_threshold),
         updated_at = now(),
         updated_by = lower(coalesce(auth.jwt() ->> 'email', ''))
   where id = 1;
end;
$$;

/** Give a flat to an owner (moves it if it was linked to someone else). */
create or replace function public.owner_admin_link_property(p_property text, p_user uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.has_admin_scope('inventory.ops') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.inventory i where i.property_id = upper(trim(p_property))) then
    raise exception 'No listing with that id.' using errcode = '22023';
  end if;
  if not exists (select 1 from public.owner_accounts o where o.user_id = p_user) then
    raise exception 'That person has not signed up as an owner yet.' using errcode = '22023';
  end if;
  insert into public.owner_property_links (property_id, owner_id, linked_by)
  values (upper(trim(p_property)), p_user, lower(coalesce(auth.jwt() ->> 'email', '')))
  on conflict (property_id) do update
     set owner_id = excluded.owner_id, linked_by = excluded.linked_by, linked_at = now();
end;
$$;

create or replace function public.owner_admin_unlink_property(p_property text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.has_admin_scope('inventory.ops') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  delete from public.owner_property_links where property_id = p_property;
end;
$$;


-- ── Row access ──────────────────────────────────────────────────────────────
alter table public.owner_program_settings  enable row level security;
alter table public.owner_accounts          enable row level security;
alter table public.owner_property_links    enable row level security;
alter table public.owner_tenant_ratings    enable row level security;
alter table public.owner_documents         enable row level security;
alter table public.owner_service_catalogue enable row level security;
alter table public.owner_requests          enable row level security;
alter table public.owner_request_events    enable row level security;

do $$
declare t text;
begin
  foreach t in array array[
    'owner_program_settings', 'owner_accounts', 'owner_property_links', 'owner_tenant_ratings',
    'owner_requests', 'owner_request_events'
  ] loop
    execute format('drop policy if exists "staff read" on public.%I', t);
    execute format('create policy "staff read" on public.%I for select to authenticated using (public.is_crm_staff())', t);
  end loop;
end $$;

drop policy if exists "owner reads own row" on public.owner_accounts;
create policy "owner reads own row" on public.owner_accounts
  for select to authenticated using (user_id = auth.uid());

drop policy if exists "owner reads own links" on public.owner_property_links;
create policy "owner reads own links" on public.owner_property_links
  for select to authenticated using (owner_id = auth.uid());

-- A rating is on your own tenant, by you, and read by you (and staff).
drop policy if exists "owner manages own ratings" on public.owner_tenant_ratings;
create policy "owner manages own ratings" on public.owner_tenant_ratings
  for all to authenticated
  using (owner_id = auth.uid())
  with check (
    owner_id = auth.uid()
    and exists (select 1 from public.tenants t where t.id = tenant_id and t.poster_id = auth.uid())
  );

drop policy if exists "owner manages own documents" on public.owner_documents;
create policy "owner manages own documents" on public.owner_documents
  for all to authenticated
  using (owner_id = auth.uid() or public.is_super_admin())
  with check (
    owner_id = auth.uid()
    and storage_path like auth.uid()::text || '/%'
    and (property_id is null or public.owner_has_property(property_id))
  );

drop policy if exists "owners and staff read catalogue" on public.owner_service_catalogue;
create policy "owners and staff read catalogue" on public.owner_service_catalogue
  for select to authenticated using (public.is_approved_owner() or public.is_crm_staff());
drop policy if exists "ops writes catalogue" on public.owner_service_catalogue;
create policy "ops writes catalogue" on public.owner_service_catalogue
  for all to authenticated
  using (public.has_admin_scope('inventory.ops'))
  with check (public.has_admin_scope('inventory.ops'));

-- Tenants: reads unchanged (your own rows); a new tenant must be on a flat you
-- posted or own — before, any signed-in user could file a tenant against any
-- property id. Staff read, because a repair visit needs the tenant's number.
drop policy if exists "owners manage own tenants" on public.tenants;
create policy "owners manage own tenants" on public.tenants
  for all to authenticated
  using (poster_id = auth.uid())
  with check (
    poster_id = auth.uid()
    and (public.is_inventory_poster(property_id) or public.owner_has_property(property_id))
  );
drop policy if exists "staff read tenants" on public.tenants;
create policy "staff read tenants" on public.tenants
  for select to authenticated using (public.is_crm_staff());

-- Visit times on a flat linked to you, even one the team uploaded.
do $$
begin
  if to_regclass('public.property_visit_slots') is not null then
    execute 'drop policy if exists "linked owners manage slots" on public.property_visit_slots';
    execute $p$
      create policy "linked owners manage slots" on public.property_visit_slots
        for all to authenticated
        using (public.owner_has_property(property_visit_slots.property_id))
        with check (public.owner_has_property(property_visit_slots.property_id) and public.is_approved_owner())
    $p$;
  end if;
end $$;


-- ── Grants ──────────────────────────────────────────────────────────────────
revoke all on public.owner_program_settings, public.owner_accounts, public.owner_property_links,
              public.owner_tenant_ratings, public.owner_documents, public.owner_service_catalogue,
              public.owner_requests, public.owner_request_events
  from public, anon, authenticated;

grant select on public.owner_program_settings, public.owner_accounts, public.owner_property_links,
                public.owner_requests, public.owner_request_events
  to authenticated;
grant select, insert, update, delete on public.owner_tenant_ratings, public.owner_documents,
                                        public.owner_service_catalogue
  to authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'public.is_approved_owner()',
    'public.owner_has_property(text)',
    'public.owner_register(text)',
    'public.owner_me()',
    'public.owner_properties()',
    'public.owner_claim_property(text)',
    'public.owner_update_property(text, jsonb)',
    'public.owner_property_candidates(text)',
    'public.owner_area_rent(text)',
    'public.owner_create_request(jsonb)',
    'public.owner_requests_list()',
    'public.owner_respond_quote(uuid, boolean)',
    'public.owner_cancel_request(uuid)',
    'public.owner_activity(int)',
    'public.ops_update_request(uuid, jsonb)',
    'public.owner_admin_list()',
    'public.owner_admin_set_status(uuid, text)',
    'public.owner_admin_settings(boolean, int)',
    'public.owner_admin_link_property(text, uuid)',
    'public.owner_admin_unlink_property(text)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

update public.admin_roles
   set scopes = array(select distinct unnest(scopes || array['inventory.ops']))
 where lower(email) = 'yatharth200018@gmail.com';

commit;


-- ── Storage: the private owner-docs bucket ──────────────────────────────────
-- Outside the transaction above and fenced with its own handler: Supabase has
-- changed who may create policies on storage.objects more than once, and a
-- refusal here must not roll back everything else. If it is refused, create
-- the bucket and these three policies from the dashboard (Storage → Policies).
--
-- Paths are <owner uid>/docs/<file> and <owner uid>/requests/<file>. The owner
-- reads and writes their own folder; staff read request photos (the ops team
-- has to see the leak); the super admin reads everything.
do $$
begin
  if to_regclass('storage.buckets') is null then
    raise notice 'No storage schema here — skipping the owner-docs bucket.';
    return;
  end if;
  begin
    insert into storage.buckets (id, name, public) values ('owner-docs', 'owner-docs', false)
    on conflict (id) do nothing;

    execute 'drop policy if exists "owner docs: own folder" on storage.objects';
    execute $p$
      create policy "owner docs: own folder" on storage.objects
        for all to authenticated
        using (bucket_id = 'owner-docs' and (storage.foldername(name))[1] = auth.uid()::text)
        with check (bucket_id = 'owner-docs' and (storage.foldername(name))[1] = auth.uid()::text)
    $p$;
    execute 'drop policy if exists "owner docs: staff read request photos" on storage.objects';
    execute $p$
      create policy "owner docs: staff read request photos" on storage.objects
        for select to authenticated
        using (bucket_id = 'owner-docs' and (storage.foldername(name))[2] = 'requests' and public.is_crm_staff())
    $p$;
    execute 'drop policy if exists "owner docs: super admin reads" on storage.objects';
    execute $p$
      create policy "owner docs: super admin reads" on storage.objects
        for select to authenticated
        using (bucket_id = 'owner-docs' and public.is_super_admin())
    $p$;
  exception when insufficient_privilege then
    raise notice 'Could not create the owner-docs bucket policies (%). Create them from the dashboard.', sqlerrm;
  end;
end $$;


-- == Verify ==================================================================
-- 1. anon holds nothing on the owner tables (expect zero rows):
--      select table_name, privilege_type from information_schema.role_table_grants
--       where grantee = 'anon' and table_name like 'owner%';
-- 2. tests/owner_check.mjs covers every access rule above.
