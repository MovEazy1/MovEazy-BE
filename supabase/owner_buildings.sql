-- ─────────────────────────────────────────────────────────────────────────────
-- Owner buildings — one QR per property, every flat in it, and the visits it
-- brings (fe/src/pages/BuildingPage.jsx, fe/src/pages/owners/Building*.jsx,
-- fe/src/pages/partners/BuildingLeads.jsx, fe/src/pages/crm/CrmBuildingsPage.jsx,
-- fe/src/lib/buildings.js).
--
-- Run in the Supabase SQL editor AFTER owner_schema.sql, partner_schema.sql and
-- partner_launch.sql (partner_tenants, partner_notifications). Safe to re-run.
--
-- An owner's property can hold many flats. The property gets a printed QR:
-- moveazy.co.in/building/<code> shows its photos and every flat floor by floor,
-- and lets a renter ask for a visit at the time they like. The owner's number
-- is never on that page — a visit request goes to the partner broker MovEazy
-- assigns to the building, and to the MovEazy CRM. The owner sees the funnel
-- (scans → numbers → visits asked → visits done → flats booked) in the app.
--
--   owner_buildings          the property: name, locality, photos, the code,
--                            and the partner broker staff assigned to it.
--   inventory.building_id    which building a flat is in (floor_number says
--                            which floor — inventory_floor.sql).
--   owner_building_scans     one row per visitor per day, QR or shared link.
--   owner_building_leads     a renter's visit request: name, mobile, the flats
--                            they want to see, the time they asked for, and
--                            how it went.
--   owner_building_bookings  a flat booked — from a lead, or marked by the owner.
--
-- Instant visit: the owner can let tenants who scan walk in right away. They
-- name a POC (a caretaker, a family member) and their mobile; the QR page then
-- offers "Instant visit". A signed-in tenant who takes it gets the POC's name
-- and number and the address — nobody else ever sees them — and the visit
-- lands as a lead of kind 'instant', in the tenant's visits, the CRM's clients
-- and Visits, the partner's and the owner's notifications, and the QR's counts.
--
-- Nobody reads these tables directly; everything goes through the functions
-- below, each of which says who may call it.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

create table if not exists public.owner_buildings (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null references auth.users (id) on delete cascade,
  code         text not null unique check (code ~ '^[A-HJ-NP-Z2-9]{6}$'),
  name         text not null check (length(trim(name)) between 2 and 80),
  area         text not null default '',
  landmark     text not null default '',
  full_address text not null default '',        -- never on the public page
  latitude     numeric,
  longitude    numeric,
  total_floors int check (total_floors between 0 and 80),
  description  text not null default '',
  amenities    text[] not null default '{}',
  photos       text[] not null default '{}',
  broker_id    uuid references auth.users (id) on delete set null,
  status       text not null default 'active' check (status in ('active', 'paused')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists owner_buildings_owner_idx on public.owner_buildings (owner_id, created_at desc);
-- A building the MovEazy team adds may not have its owner in the app yet: it
-- carries their contact until they sign in (crm_onboarding.sql).
alter table public.owner_buildings alter column owner_id drop not null;
alter table public.owner_buildings add column if not exists owner_email text not null default '';
alter table public.owner_buildings add column if not exists owner_phone text not null default '';
alter table public.owner_buildings add column if not exists created_by text not null default '';
-- 'building': one owner, who sees it in the owner app. 'society': each flat has
-- its own owner, who sees only their flat; MovEazy runs the society's page.
alter table public.owner_buildings add column if not exists kind text not null default 'building';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'owner_buildings_kind_check') then
    alter table public.owner_buildings add constraint owner_buildings_kind_check check (kind in ('building', 'society'));
  end if;
end $$;
-- The video the QR page opens with (a walk-through of the building).
alter table public.owner_buildings add column if not exists cover_video text not null default '';
create index if not exists owner_buildings_broker_idx on public.owner_buildings (broker_id);
-- Instant visit: on or off, and who shows the flats (never on the public page).
alter table public.owner_buildings add column if not exists instant_visit boolean not null default false;
alter table public.owner_buildings add column if not exists instant_poc_name text not null default '';
alter table public.owner_buildings add column if not exists instant_poc_phone text not null default '';
alter table public.owner_buildings add column if not exists instant_updated_at timestamptz;
alter table public.owner_buildings add column if not exists instant_updated_by text not null default '';

alter table public.inventory add column if not exists building_id uuid references public.owner_buildings (id) on delete set null;
alter table public.inventory add column if not exists floor_number int;
-- The flat's number in its building ("302", "B-1104"), and where MovEazy wants
-- it in the building's list (lower first; unset after the ordered ones).
alter table public.inventory add column if not exists unit_no text not null default '';
alter table public.inventory add column if not exists unit_order int;
create index if not exists inventory_building_idx on public.inventory (building_id) where building_id is not null;
grant select (building_id, floor_number, unit_no, unit_order) on public.inventory to anon, authenticated;

create table if not exists public.owner_building_scans (
  building_id uuid not null references public.owner_buildings (id) on delete cascade,
  visitor     text not null check (length(visitor) between 8 and 64),
  day         date not null default (now() at time zone 'Asia/Kolkata')::date,
  source      text not null default 'link' check (source in ('qr', 'link')),
  created_at  timestamptz not null default now(),
  primary key (building_id, visitor, day)
);

create table if not exists public.owner_building_leads (
  id              uuid primary key default gen_random_uuid(),
  building_id     uuid not null references public.owner_buildings (id) on delete cascade,
  name            text not null default '',
  phone           text not null check (phone ~ '^[6-9][0-9]{9}$'),
  property_ids    text[] not null default '{}',
  visit_at        timestamptz,                    -- null: "call me to fix a time"
  note            text not null default '',
  status          text not null default 'new'
                    check (status in ('new', 'confirmed', 'visited', 'no_show', 'booked', 'cancelled')),
  booked_property text,
  broker_id       uuid references auth.users (id) on delete set null,
  visitor         text not null default '',
  updated_by      text not null default '',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists owner_building_leads_building_idx on public.owner_building_leads (building_id, created_at desc);
create index if not exists owner_building_leads_broker_idx on public.owner_building_leads (broker_id, created_at desc);
-- The account that asked (Google sign-in): the visit is theirs, and they are a client in the CRM.
alter table public.owner_building_leads add column if not exists user_id uuid references auth.users (id) on delete set null;
create index if not exists owner_building_leads_user_idx on public.owner_building_leads (user_id);
-- 'scheduled': a time asked for, the partner confirms it. 'instant': on the way now.
alter table public.owner_building_leads add column if not exists kind text not null default 'scheduled';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'owner_building_leads_kind_check') then
    alter table public.owner_building_leads add constraint owner_building_leads_kind_check check (kind in ('scheduled', 'instant'));
  end if;
end $$;

-- A tenant's own visit to a flat can be an instant one (visits_schema.sql).
do $$ begin
  if to_regclass('public.visit_bookings') is not null then
    alter table public.visit_bookings drop constraint if exists visit_bookings_kind_check;
    alter table public.visit_bookings add constraint visit_bookings_kind_check check (kind in ('individual', 'combined', 'instant'));
  end if;
end $$;

create table if not exists public.owner_building_bookings (
  property_id text primary key references public.inventory (property_id) on delete cascade,
  building_id uuid not null references public.owner_buildings (id) on delete cascade,
  lead_id     uuid references public.owner_building_leads (id) on delete set null,
  booked_by   text not null default '',
  booked_at   timestamptz not null default now()
);

alter table public.owner_buildings enable row level security;
alter table public.owner_building_scans enable row level security;
alter table public.owner_building_leads enable row level security;
alter table public.owner_building_bookings enable row level security;
revoke all on public.owner_buildings, public.owner_building_scans, public.owner_building_leads,
              public.owner_building_bookings from anon, authenticated;

-- A visit request is a lead the broker and MovEazy share.
do $$
begin
  if to_regclass('public.partner_notifications') is not null then
    alter table public.partner_notifications drop constraint if exists partner_notifications_kind_check;
    alter table public.partner_notifications add constraint partner_notifications_kind_check
      check (kind in ('tenant_liked', 'storefront_like', 'sold_out_request', 'sold_out_decided', 'list_opened', 'list_done',
                      'building_visit', 'building_assigned'));
  end if;
  if to_regclass('public.partner_tenants') is not null then
    alter table public.partner_tenants drop constraint if exists partner_tenants_source_check;
    alter table public.partner_tenants add constraint partner_tenants_source_check
      check (source in ('curated', 'storefront', 'building'));
  end if;
end $$;

-- ── Helpers ──────────────────────────────────────────────────────────────────

create or replace function public.building_by_code(p_code text)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select b.id from public.owner_buildings b
   where b.code = upper(trim(coalesce(p_code, ''))) and b.status = 'active';
$$;

/** Can the caller work this building's leads: CRM staff, its broker, or its owner. */
create or replace function public.building_role(p_building uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when auth.uid() is null then null
    when public.is_crm_staff() then 'staff'
    when exists (select 1 from public.owner_buildings b where b.id = p_building and b.broker_id = auth.uid()) then 'broker'
    when exists (select 1 from public.owner_buildings b where b.id = p_building and b.owner_id = auth.uid()) then 'owner'
  end;
$$;

/** The funnel an owner reads: scans, numbers, visits asked, visits done, flats booked. */
create or replace function public.building_stats(p_building uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'scans',     (select count(distinct s.visitor) from public.owner_building_scans s where s.building_id = p_building and s.source = 'qr'),
    'visitors',  (select count(distinct s.visitor) from public.owner_building_scans s where s.building_id = p_building),
    'numbers',   (select count(distinct l.phone) from public.owner_building_leads l where l.building_id = p_building),
    'scheduled', (select count(*) from public.owner_building_leads l
                   where l.building_id = p_building and l.visit_at is not null and l.status <> 'cancelled'),
    'visited',   (select count(*) from public.owner_building_leads l
                   where l.building_id = p_building and l.status in ('visited', 'booked')),
    'booked',    (select count(*) from public.owner_building_bookings k where k.building_id = p_building),
    'upcoming',  (select count(*) from public.owner_building_leads l
                   where l.building_id = p_building and l.status in ('new', 'confirmed') and l.visit_at > now()),
    'instant',   (select count(*) from public.owner_building_leads l
                   where l.building_id = p_building and l.kind = 'instant' and l.status <> 'cancelled')
  );
$$;

/** The flats of a building as everyone may see them: no address, no owner. */
create or replace function public.building_flats(p_building uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'property_id', i.property_id, 'title', i.title, 'flat_type', i.flat_type, 'property_type', i.property_type,
           'bedrooms', i.bedrooms, 'bathrooms', i.bathrooms, 'furnishing', i.furnishing, 'rent', i.rent,
           'deposit', i.deposit, 'available_from', i.available_from, 'area_sqft', i.area_sqft,
           'floor_number', i.floor_number, 'images', i.images, 'cover_image_url', i.cover_image_url,
           'amenities', i.amenities, 'description', i.description, 'unit_no', i.unit_no, 'unit_order', i.unit_order,
           'available', i.status <> 'rented' and not exists (select 1 from public.owner_building_bookings k where k.property_id = i.property_id))
         -- MovEazy's order first; then floor by floor, cheapest first.
         order by i.unit_order nulls last, i.floor_number nulls last, i.rent, i.property_id), '[]'::jsonb)
    from public.inventory i
   where i.building_id = p_building and i.status in ('published', 'paused', 'rented');
$$;

-- ── The public page ──────────────────────────────────────────────────────────

/** What moveazy.co.in/building/<code> shows. Null for an unknown or paused building. */
create or replace function public.building_page(p_code text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'code', b.code, 'name', b.name, 'area', b.area, 'landmark', b.landmark,
    'latitude', round(b.latitude, 3), 'longitude', round(b.longitude, 3),   -- the neighbourhood, not the gate
    'total_floors', b.total_floors, 'description', b.description, 'amenities', b.amenities, 'photos', b.photos,
    'kind', b.kind, 'cover_video', b.cover_video,
    'flats', public.building_flats(b.id),
    'has_partner', b.broker_id is not null,
    -- Only whether it's on: the POC is for a signed-in tenant who takes it.
    'instant_visit', b.instant_visit and b.instant_poc_phone <> ''
  )
  from public.owner_buildings b
  where b.id = public.building_by_code(p_code);
$$;

/** Count one visit. A visitor counts once a day; the owner's own visits don't count. */
create or replace function public.building_view(p_code text, p_visitor text, p_source text default 'link')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  bid uuid := public.building_by_code(p_code);
  who text := coalesce(auth.uid()::text, left(trim(coalesce(p_visitor, '')), 64));
begin
  if bid is null or length(who) < 8 then return; end if;
  if exists (select 1 from public.owner_buildings b where b.id = bid and (b.owner_id = auth.uid() or b.broker_id = auth.uid())) then
    return;
  end if;
  insert into public.owner_building_scans (building_id, visitor, source)
  values (bid, who, case when p_source = 'qr' then 'qr' else 'link' end)
  on conflict (building_id, visitor, day) do nothing;
end;
$$;

/**
 * A renter asks to visit, signed in with Google. Name and mobile, the flats they want to see,
 * and the time they would like — or none, and the broker calls to fix one.
 * The same number asking again while a visit is open updates that request.
 * The building's broker is told at once; MovEazy's CRM gets the number too.
 */
create or replace function public.building_request_visit(
  p_code text, p_visitor text, p_name text, p_phone text,
  p_properties text[] default '{}', p_visit_at timestamptz default null, p_note text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid     uuid := auth.uid();
  b       public.owner_buildings%rowtype;
  ph      text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  nm      text := left(trim(coalesce(p_name, '')), 80);
  flats   text[];
  lid     uuid;
  fresh   boolean := false;
  when_tx text;
begin
  -- A visit is booked by an account (Google sign-in), so it shows in the
  -- tenant's visits and the tenant is a client in the CRM, not just a number.
  if uid is null then raise exception 'Sign in with Google to book your visit.' using errcode = '42501'; end if;
  select * into b from public.owner_buildings where id = public.building_by_code(p_code);
  if b.id is null then raise exception 'This property is not taking visits right now.' using errcode = '22023'; end if;
  if ph !~ '^[6-9][0-9]{9}$' then raise exception 'Enter a 10-digit mobile number.' using errcode = '22023'; end if;
  if length(nm) < 2 then raise exception 'Tell us your name.' using errcode = '22023'; end if;
  if p_visit_at is not null and (p_visit_at < now() - interval '15 minutes' or p_visit_at > now() + interval '60 days') then
    raise exception 'Pick a time in the next two months.' using errcode = '22023';
  end if;
  -- Twenty requests an hour from one account is a script, not a renter.
  if (select count(*) from public.owner_building_leads
       where user_id = uid and created_at > now() - interval '1 hour') >= 20 then
    raise exception 'Too many requests. Try again in a while.' using errcode = '54000';
  end if;

  select coalesce(array_agg(distinct i.property_id), '{}') into flats
    from public.inventory i
   where i.building_id = b.id and i.property_id = any(coalesce(p_properties, '{}'));

  select id into lid from public.owner_building_leads
   where building_id = b.id and (user_id = uid or phone = ph) and status in ('new', 'confirmed')
   order by created_at desc limit 1;

  if lid is null then
    insert into public.owner_building_leads (building_id, name, phone, property_ids, visit_at, note, broker_id, visitor, user_id)
    values (b.id, nm, ph, flats, p_visit_at, left(coalesce(p_note, ''), 500), b.broker_id, left(coalesce(p_visitor, ''), 64), uid)
    returning id into lid;
    fresh := true;
  else
    update public.owner_building_leads set
      name = nm, phone = ph, user_id = uid,
      property_ids = (select coalesce(array_agg(distinct x), '{}') from unnest(property_ids || flats) x),
      visit_at = coalesce(p_visit_at, visit_at),
      note = case when coalesce(p_note, '') <> '' then left(p_note, 500) else note end,
      status = 'new', updated_at = now(), updated_by = 'renter'
    where id = lid;
  end if;

  when_tx := coalesce(to_char(p_visit_at at time zone 'Asia/Kolkata', 'Dy DD Mon, HH12:MI AM'), 'any time — call to fix it');

  if b.broker_id is not null and to_regclass('public.partner_tenants') is not null then
    insert into public.partner_tenants (broker_id, phone, name, source)
    values (b.broker_id, ph, nm, 'building')
    on conflict (broker_id, phone) do update set last_seen_at = now(),
      name = case when partner_tenants.name = '' then excluded.name else partner_tenants.name end;
  end if;
  if b.broker_id is not null and to_regclass('public.partner_notifications') is not null then
    insert into public.partner_notifications (broker_id, kind, title, body, link)
    values (b.broker_id, 'building_visit',
            nm || case when fresh then ' wants to visit ' else ' updated a visit to ' end || b.name,
            ph || ' · ' || when_tx || case when cardinality(flats) > 0 then ' · ' || cardinality(flats) || ' flat' ||
              case when cardinality(flats) = 1 then '' else 's' end else '' end,
            '/building-leads');
  end if;

  -- Their account keeps the number they gave, if it had none.
  update public.user_profiles set phone = ph, name = case when coalesce(name, '') = '' then nm else name end
   where id = uid and coalesce(trim(phone), '') = '';

  -- MovEazy's client list: this account, as one client. A lead that came in by
  -- this number before (no account then) becomes this account's.
  if to_regclass('public.crm_clients') is not null then
    execute 'update public.crm_clients c set user_id = $1
              where c.user_id is null
                and not exists (select 1 from public.crm_clients x where x.user_id = $1)
                and c.id = (select y.id from public.crm_clients y
                             where y.user_id is null and right(regexp_replace(coalesce(y.phone, ''''), ''\D'', '''', ''g''), 10) = $2
                             limit 1)'
      using uid, ph;
    execute 'insert into public.crm_clients (user_id, name, phone, source)
             select $1, $2, $3, ''building_qr''
              where not exists (select 1 from public.crm_clients x where x.user_id = $1)'
      using uid, nm, ph;
  end if;

  -- The tenant's own visits (and the CRM's Visits): one booking per flat they picked.
  if cardinality(flats) > 0 and to_regclass('public.visit_bookings') is not null then
    insert into public.visit_bookings (user_id, property_id, slot_at, kind, status)
    select uid, f, p_visit_at, 'individual', case when p_visit_at is null then 'preference' else 'scheduled' end
      from unnest(flats) f
    on conflict (user_id, property_id) do update set slot_at = excluded.slot_at, status = excluded.status;
  end if;

  return jsonb_build_object('id', lid, 'updated', not fresh, 'has_partner', b.broker_id is not null);
end;
$$;

/**
 * Instant visit: a signed-in tenant is heading to the property now. Their
 * name and mobile, the flats they want to see (none picked: every free flat),
 * and back come the POC's name and number and the address — what they need to
 * walk in. The visit is theirs (visit_bookings, kind 'instant'), they are a
 * client in the CRM, the partner and MovEazy are told at once, and the owner
 * sees it in their notifications.
 */
create or replace function public.building_instant_visit(
  p_code text, p_visitor text, p_name text, p_phone text, p_properties text[] default '{}'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid   uuid := auth.uid();
  b     public.owner_buildings%rowtype;
  ph    text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  nm    text := left(trim(coalesce(p_name, '')), 80);
  flats text[];
  lid   uuid;
  fresh boolean := false;
  -- Expected at the gate in about half an hour.
  arrive timestamptz := date_trunc('minute', now()) + interval '30 minutes';
  cid   uuid;
begin
  if uid is null then raise exception 'Sign in with Google to start your instant visit.' using errcode = '42501'; end if;
  select * into b from public.owner_buildings where id = public.building_by_code(p_code);
  if b.id is null then raise exception 'This property is not taking visits right now.' using errcode = '22023'; end if;
  if not b.instant_visit or b.instant_poc_phone = '' then
    raise exception 'Instant visits are off here right now — schedule a visit instead.' using errcode = '22023';
  end if;
  if ph !~ '^[6-9][0-9]{9}$' then raise exception 'Enter a 10-digit mobile number.' using errcode = '22023'; end if;
  if length(nm) < 2 then raise exception 'Tell us your name.' using errcode = '22023'; end if;
  if (select count(*) from public.owner_building_leads
       where user_id = uid and created_at > now() - interval '1 hour') >= 20 then
    raise exception 'Too many requests. Try again in a while.' using errcode = '54000';
  end if;

  -- The free flats they picked; none picked, every free flat.
  select coalesce(array_agg(distinct i.property_id), '{}') into flats
    from public.inventory i
   where i.building_id = b.id and i.status in ('published', 'paused')
     and not exists (select 1 from public.owner_building_bookings k where k.property_id = i.property_id)
     and (cardinality(coalesce(p_properties, '{}')) = 0 or i.property_id = any(p_properties));
  if cardinality(flats) = 0 and cardinality(coalesce(p_properties, '{}')) > 0 then
    select coalesce(array_agg(distinct i.property_id), '{}') into flats
      from public.inventory i
     where i.building_id = b.id and i.status in ('published', 'paused')
       and not exists (select 1 from public.owner_building_bookings k where k.property_id = i.property_id);
  end if;

  -- An open request from them becomes this instant visit.
  select id into lid from public.owner_building_leads
   where building_id = b.id and (user_id = uid or phone = ph) and status in ('new', 'confirmed')
   order by created_at desc limit 1;
  if lid is null then
    insert into public.owner_building_leads (building_id, name, phone, property_ids, visit_at, status, kind, broker_id, visitor, user_id, updated_by)
    values (b.id, nm, ph, flats, arrive, 'confirmed', 'instant', b.broker_id, left(coalesce(p_visitor, ''), 64), uid, 'renter')
    returning id into lid;
    fresh := true;
  else
    update public.owner_building_leads set
      name = nm, phone = ph, user_id = uid, kind = 'instant', visit_at = arrive, status = 'confirmed',
      property_ids = (select coalesce(array_agg(distinct x), '{}') from unnest(property_ids || flats) x),
      updated_at = now(), updated_by = 'renter'
    where id = lid;
  end if;
  -- Every flat in the visit is seen now, including any from the request it replaced.
  select l.property_ids into flats from public.owner_building_leads l where l.id = lid;

  if b.broker_id is not null and to_regclass('public.partner_tenants') is not null then
    insert into public.partner_tenants (broker_id, phone, name, source)
    values (b.broker_id, ph, nm, 'building')
    on conflict (broker_id, phone) do update set last_seen_at = now(),
      name = case when partner_tenants.name = '' then excluded.name else partner_tenants.name end;
  end if;
  if b.broker_id is not null and to_regclass('public.partner_notifications') is not null then
    insert into public.partner_notifications (broker_id, kind, title, body, link)
    values (b.broker_id, 'building_visit', 'Instant visit: ' || nm || ' is heading to ' || b.name,
            ph || ' · there by ' || to_char(arrive at time zone 'Asia/Kolkata', 'HH12:MI AM') || ' · ' || b.instant_poc_name || ' shows the flats',
            '/building-leads');
  end if;

  update public.user_profiles set phone = ph, name = case when coalesce(name, '') = '' then nm else name end
   where id = uid and coalesce(trim(phone), '') = '';

  if to_regclass('public.crm_clients') is not null then
    execute 'update public.crm_clients c set user_id = $1
              where c.user_id is null
                and not exists (select 1 from public.crm_clients x where x.user_id = $1)
                and c.id = (select y.id from public.crm_clients y
                             where y.user_id is null and right(regexp_replace(coalesce(y.phone, ''''), ''\D'', '''', ''g''), 10) = $2
                             limit 1)'
      using uid, ph;
    execute 'insert into public.crm_clients (user_id, name, phone, source)
             select $1, $2, $3, ''instant_visit''
              where not exists (select 1 from public.crm_clients x where x.user_id = $1)'
      using uid, nm, ph;
    execute 'select id from public.crm_clients where user_id = $1' into cid using uid;
  end if;

  if cardinality(flats) > 0 and to_regclass('public.visit_bookings') is not null then
    insert into public.visit_bookings (user_id, property_id, slot_at, kind, status)
    select uid, f, arrive, 'instant', 'scheduled' from unnest(flats) f
    on conflict (user_id, property_id) do update set slot_at = excluded.slot_at, status = excluded.status, kind = excluded.kind;
  end if;

  -- MovEazy's team hears at once: someone is at the gate within the half hour.
  if to_regclass('public.crm_notifications') is not null then
    execute format('insert into public.crm_notifications (for_email, type, title, body%s) values ($1, ''visit'', $2, $3%s)',
                   case when cid is not null and exists (select 1 from information_schema.columns
                          where table_schema = 'public' and table_name = 'crm_notifications' and column_name = 'client_id')
                        then ', client_id' else '' end,
                   case when cid is not null and exists (select 1 from information_schema.columns
                          where table_schema = 'public' and table_name = 'crm_notifications' and column_name = 'client_id')
                        then ', $4' else '' end)
      using 'yatharth200018@gmail.com', 'Instant visit · ' || b.name,
            nm || ' (' || ph || ') is heading there now — ' || b.instant_poc_name || ' (' || b.instant_poc_phone || ') shows the flats.',
            cid;
  end if;

  return jsonb_build_object(
    'id', lid, 'updated', not fresh, 'arrive_by', arrive, 'flats', cardinality(flats),
    'poc_name', b.instant_poc_name, 'poc_phone', b.instant_poc_phone,
    'name', b.name, 'area', b.area, 'landmark', b.landmark, 'address', b.full_address,
    'latitude', b.latitude, 'longitude', b.longitude
  );
end;
$$;

-- ── The owner's side ─────────────────────────────────────────────────────────

/** The caller's buildings, each with its funnel and flat counts. */
create or replace function public.owner_buildings_list()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', b.id, 'code', b.code, 'name', b.name, 'area', b.area, 'landmark', b.landmark,
           'full_address', b.full_address, 'latitude', b.latitude, 'longitude', b.longitude,
           'total_floors', b.total_floors, 'description', b.description, 'amenities', b.amenities,
           'photos', b.photos, 'status', b.status, 'created_at', b.created_at, 'kind', b.kind, 'cover_video', b.cover_video,
           'has_partner', b.broker_id is not null, 'instant_visit', b.instant_visit,
           'flats', (select count(*) from public.inventory i where i.building_id = b.id),
           'stats', public.building_stats(b.id))
         order by b.created_at desc), '[]'::jsonb)
    from public.owner_buildings b
   where b.owner_id = auth.uid() and public.is_approved_owner();
$$;

/** Create (no id) or edit a building. Returns its id and code. */
create or replace function public.owner_building_save(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  bid uuid := nullif(p ->> 'id', '')::uuid;
  c   text;
  i   int;
  nm  text := trim(coalesce(p ->> 'name', ''));
begin
  if not public.is_approved_owner() then raise exception 'Only owners can add a property.' using errcode = '42501'; end if;
  if length(nm) < 2 then raise exception 'Give the property a name.' using errcode = '22023'; end if;
  if bid is not null and not exists (select 1 from public.owner_buildings where id = bid and owner_id = auth.uid()) then
    raise exception 'That is not one of your properties.' using errcode = '42501';
  end if;

  if bid is null then
    for i in 1..25 loop
      select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '')
        into c from generate_series(1, 6);
      exit when not exists (select 1 from public.owner_buildings where code = c);
    end loop;
    insert into public.owner_buildings (owner_id, code, name) values (auth.uid(), c, left(nm, 80)) returning id into bid;
  end if;

  update public.owner_buildings b set
    name         = left(nm, 80),
    area         = case when p ? 'area' then left(trim(coalesce(p ->> 'area', '')), 80) else b.area end,
    landmark     = case when p ? 'landmark' then left(coalesce(p ->> 'landmark', ''), 160) else b.landmark end,
    full_address = case when p ? 'full_address' then left(coalesce(p ->> 'full_address', ''), 400) else b.full_address end,
    latitude     = case when p ? 'latitude' then nullif(p ->> 'latitude', '')::numeric else b.latitude end,
    longitude    = case when p ? 'longitude' then nullif(p ->> 'longitude', '')::numeric else b.longitude end,
    total_floors = case when p ? 'total_floors' then nullif(p ->> 'total_floors', '')::int else b.total_floors end,
    description  = case when p ? 'description' then left(coalesce(p ->> 'description', ''), 2000) else b.description end,
    amenities    = case when p ? 'amenities' then array(select left(x, 60) from jsonb_array_elements_text(p -> 'amenities') x limit 40) else b.amenities end,
    photos       = case when p ? 'photos' then array(select x from jsonb_array_elements_text(p -> 'photos') x where x ~ '^https://' limit 30) else b.photos end,
    cover_video  = case when p ? 'cover_video' and coalesce(p ->> 'cover_video', '') ~ '^(https://.*)?$' then coalesce(p ->> 'cover_video', '') else b.cover_video end,
    status       = case when p ->> 'status' in ('active', 'paused') then p ->> 'status' else b.status end,
    updated_at   = now()
  where b.id = bid;

  return (select jsonb_build_object('id', b.id, 'code', b.code) from public.owner_buildings b where b.id = bid);
end;
$$;

/** Put one of the owner's flats in one of their buildings, on a floor — or take it out (null building). */
create or replace function public.owner_building_set_flat(p_property text, p_building uuid, p_floor int default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not (public.is_approved_owner() and public.owner_has_property(p_property)) then
    raise exception 'That is not one of your flats.' using errcode = '42501';
  end if;
  if p_building is not null and not exists (select 1 from public.owner_buildings where id = p_building and owner_id = auth.uid()) then
    raise exception 'That is not one of your properties.' using errcode = '42501';
  end if;
  if p_floor is not null and p_floor not between -2 and 80 then
    raise exception 'Floor is between basement 2 and 80.' using errcode = '22023';
  end if;
  update public.inventory set building_id = p_building, floor_number = coalesce(p_floor, floor_number), updated_at = now()
   where property_id = p_property;
  if p_building is null then delete from public.owner_building_bookings where property_id = p_property; end if;
end;
$$;

/**
 * Turn instant visit on (with the POC who shows the flats) or off. The
 * building's owner, or MovEazy staff for a building whose owner isn't in the
 * app yet. Off keeps the POC, so turning it back on is one tap.
 */
create or replace function public.building_set_instant_visit(p_building uuid, p_on boolean, p_name text default '', p_phone text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  who text;
  ph  text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  nm  text := left(trim(coalesce(p_name, '')), 80);
begin
  who := case
    when auth.uid() is null then null
    when public.is_crm_staff() then 'staff'
    when public.is_approved_owner()
         and exists (select 1 from public.owner_buildings b where b.id = p_building and b.owner_id = auth.uid()) then 'owner'
  end;
  if who is null then raise exception 'Only the owner can set up instant visits.' using errcode = '42501'; end if;
  if coalesce(p_on, false) then
    if length(nm) < 2 then raise exception 'Add the name of the person who shows the flats.' using errcode = '22023'; end if;
    if ph !~ '^[6-9][0-9]{9}$' then raise exception 'Add their 10-digit mobile number.' using errcode = '22023'; end if;
  end if;
  update public.owner_buildings b set
    instant_visit      = coalesce(p_on, false),
    instant_poc_name   = case when coalesce(p_on, false) then nm else b.instant_poc_name end,
    instant_poc_phone  = case when coalesce(p_on, false) then ph else b.instant_poc_phone end,
    instant_updated_at = now(),
    instant_updated_by = who,
    updated_at         = now()
  where b.id = p_building;
  if not found then raise exception 'No such property.' using errcode = '22023'; end if;
  return (select jsonb_build_object('instant_visit', b.instant_visit, 'poc_name', b.instant_poc_name, 'poc_phone', b.instant_poc_phone)
            from public.owner_buildings b where b.id = p_building);
end;
$$;

/** One building, in full, for its owner: the funnel, the flats, and every visit (first name and initial only). */
create or replace function public.owner_building_detail(p_building uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', b.id, 'code', b.code, 'name', b.name, 'area', b.area, 'landmark', b.landmark, 'full_address', b.full_address,
    'latitude', b.latitude, 'longitude', b.longitude, 'total_floors', b.total_floors, 'description', b.description,
    'amenities', b.amenities, 'photos', b.photos, 'status', b.status, 'has_partner', b.broker_id is not null,
    'kind', b.kind, 'cover_video', b.cover_video,
    'instant_visit', b.instant_visit, 'instant_poc_name', b.instant_poc_name, 'instant_poc_phone', b.instant_poc_phone,
    'stats', public.building_stats(b.id),
    'flats', public.building_flats(b.id),
    'booked', coalesce((select jsonb_agg(k.property_id) from public.owner_building_bookings k where k.building_id = b.id), '[]'::jsonb),
    'leads', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', l.id, 'name', public.owner_display_name(l.name), 'property_ids', l.property_ids,
               'visit_at', l.visit_at, 'status', l.status, 'booked_property', l.booked_property, 'created_at', l.created_at,
               'kind', l.kind)
             order by coalesce(l.visit_at, l.created_at) desc)
        from public.owner_building_leads l where l.building_id = b.id), '[]'::jsonb),
    'by_day', (
      select jsonb_agg(jsonb_build_object('day', d::date,
               'scans', (select count(*) from public.owner_building_scans s where s.building_id = b.id and s.day = d::date and s.source = 'qr'),
               'views', (select count(*) from public.owner_building_scans s where s.building_id = b.id and s.day = d::date)) order by d)
        from generate_series((now() at time zone 'Asia/Kolkata')::date - 13, (now() at time zone 'Asia/Kolkata')::date, interval '1 day') d)
  )
  from public.owner_buildings b
  where b.id = p_building and b.owner_id = auth.uid() and public.is_approved_owner();
$$;

/** The owner marks a flat booked (or not) — it leaves the public list either way. */
create or replace function public.owner_building_mark_booked(p_property text, p_on boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  bid uuid;
begin
  select i.building_id into bid from public.inventory i
    join public.owner_buildings b on b.id = i.building_id and b.owner_id = auth.uid()
   where i.property_id = p_property;
  if bid is null or not public.is_approved_owner() then
    raise exception 'That flat is not in one of your properties.' using errcode = '42501';
  end if;
  if p_on then
    insert into public.owner_building_bookings (property_id, building_id, booked_by)
    values (p_property, bid, 'owner') on conflict (property_id) do nothing;
  else
    delete from public.owner_building_bookings where property_id = p_property;
  end if;
end;
$$;

-- ── Working a lead: broker, CRM staff, or the owner ──────────────────────────

/**
 * Move a visit along. Broker and staff can change anything; the owner can say
 * how it went (visited / no-show / booked / cancelled) but not the time.
 * 'booked' needs the flat, and books it.
 */
create or replace function public.building_lead_update(p_lead uuid, p_patch jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  l    public.owner_building_leads%rowtype;
  who  text;
  st   text := p_patch ->> 'status';
  flat text := nullif(p_patch ->> 'booked_property', '');
begin
  select * into l from public.owner_building_leads where id = p_lead;
  if l.id is null then raise exception 'No such visit.' using errcode = '22023'; end if;
  who := public.building_role(l.building_id);
  if who is null then raise exception 'Not your visit to update.' using errcode = '42501'; end if;
  if who = 'owner' and (p_patch ? 'visit_at' or p_patch ? 'note') then
    raise exception 'The partner confirms visit times.' using errcode = '42501';
  end if;
  if st is not null and st not in ('new', 'confirmed', 'visited', 'no_show', 'booked', 'cancelled') then
    raise exception 'Unknown status.' using errcode = '22023';
  end if;
  if who = 'owner' and st in ('new', 'confirmed') then
    raise exception 'The partner confirms visit times.' using errcode = '42501';
  end if;
  if st = 'booked' then
    flat := coalesce(flat, case when cardinality(l.property_ids) = 1 then l.property_ids[1] end);
    if flat is null or not exists (select 1 from public.inventory where property_id = flat and building_id = l.building_id) then
      raise exception 'Pick the flat that was booked.' using errcode = '22023';
    end if;
  end if;

  update public.owner_building_leads set
    status          = coalesce(st, status),
    visit_at        = case when p_patch ? 'visit_at' then nullif(p_patch ->> 'visit_at', '')::timestamptz else visit_at end,
    note            = case when p_patch ? 'note' then left(coalesce(p_patch ->> 'note', ''), 500) else note end,
    booked_property = case when st = 'booked' then flat when st is not null then null else booked_property end,
    updated_at      = now(),
    updated_by      = who
  where id = p_lead;

  if st is not null then
    delete from public.owner_building_bookings where lead_id = p_lead and (st <> 'booked' or property_id <> flat);
  end if;
  if st = 'booked' then
    insert into public.owner_building_bookings (property_id, building_id, lead_id, booked_by)
    values (flat, l.building_id, p_lead, who)
    on conflict (property_id) do update set lead_id = excluded.lead_id, booked_by = excluded.booked_by, booked_at = now();
  end if;
  return jsonb_build_object('id', p_lead, 'status', coalesce(st, l.status));
end;
$$;

/** The calling partner's building visits, with numbers — the buildings MovEazy assigned them. */
create or replace function public.partner_building_leads()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'buildings', coalesce((
      select jsonb_agg(jsonb_build_object('id', b.id, 'code', b.code, 'name', b.name, 'area', b.area, 'landmark', b.landmark,
                                          'full_address', b.full_address, 'flats', public.building_flats(b.id),
                                          'stats', public.building_stats(b.id), 'instant_visit', b.instant_visit,
                                          'instant_poc_name', b.instant_poc_name, 'instant_poc_phone', b.instant_poc_phone) order by b.name)
        from public.owner_buildings b where b.broker_id = auth.uid()), '[]'::jsonb),
    'leads', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', l.id, 'building_id', l.building_id, 'name', l.name, 'phone', l.phone, 'property_ids', l.property_ids,
               'visit_at', l.visit_at, 'note', l.note, 'status', l.status, 'booked_property', l.booked_property,
               'created_at', l.created_at, 'updated_at', l.updated_at, 'kind', l.kind)
             order by l.created_at desc)
        from public.owner_building_leads l join public.owner_buildings b on b.id = l.building_id
       where b.broker_id = auth.uid()), '[]'::jsonb)
  )
  where public.is_approved_partner();
$$;

-- ── MovEazy's side ───────────────────────────────────────────────────────────

/** Every building, its owner and partner, its funnel and every visit. CRM staff only. */
create or replace function public.crm_buildings()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'buildings', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', b.id, 'code', b.code, 'name', b.name, 'area', b.area, 'landmark', b.landmark, 'full_address', b.full_address,
               'status', b.status, 'created_at', b.created_at,
               'owner', coalesce(
                          (select jsonb_build_object('name', o.name, 'phone', o.phone, 'email', o.email, 'joined', true)
                             from public.owner_accounts o where o.user_id = b.owner_id),
                          case when b.owner_email <> '' or b.owner_phone <> '' then
                            jsonb_build_object('name', '', 'phone', b.owner_phone, 'email', b.owner_email, 'joined', false) end),
               'broker_id', b.broker_id,
               'broker', (select jsonb_build_object('name', p.name, 'phone', p.phone, 'agency', p.agency)
                            from public.broker_partners p where p.user_id = b.broker_id),
               'flats', public.building_flats(b.id),
               'stats', public.building_stats(b.id),
               'instant_visit', b.instant_visit, 'instant_poc_name', b.instant_poc_name,
               'instant_poc_phone', b.instant_poc_phone, 'instant_updated_at', b.instant_updated_at,
               'instant_updated_by', b.instant_updated_by)
             order by b.created_at desc)
        from public.owner_buildings b), '[]'::jsonb),
    'leads', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', l.id, 'building_id', l.building_id, 'name', l.name, 'phone', l.phone, 'property_ids', l.property_ids,
               'visit_at', l.visit_at, 'note', l.note, 'status', l.status, 'booked_property', l.booked_property,
               'updated_by', l.updated_by, 'created_at', l.created_at, 'kind', l.kind)
             order by l.created_at desc)
        from public.owner_building_leads l), '[]'::jsonb),
    'partners', coalesce((
      select jsonb_agg(jsonb_build_object('user_id', p.user_id, 'name', p.name, 'phone', p.phone, 'agency', p.agency) order by p.name)
        from public.broker_partners p where p.status = 'approved'), '[]'::jsonb)
  );
end;
$$;

/** Assign (or clear) the partner broker for a building. Open visits move to them. */
create or replace function public.crm_building_assign_broker(p_building uuid, p_broker uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  if p_broker is not null and not exists (select 1 from public.broker_partners where user_id = p_broker and status = 'approved') then
    raise exception 'Pick an approved partner.' using errcode = '22023';
  end if;
  update public.owner_buildings set broker_id = p_broker, updated_at = now() where id = p_building;
  if not found then raise exception 'No such property.' using errcode = '22023'; end if;
  update public.owner_building_leads set broker_id = p_broker
   where building_id = p_building and status in ('new', 'confirmed');
  if p_broker is not null and to_regclass('public.partner_notifications') is not null then
    insert into public.partner_notifications (broker_id, kind, title, body, link)
    select p_broker, 'building_assigned', 'MovEazy assigned you ' || b.name,
           coalesce(nullif(b.area, ''), 'Bengaluru') || ' · visit requests from its QR now come to you.', '/building-leads'
      from public.owner_buildings b where b.id = p_building;
  end if;
end;
$$;

-- ── The owner's flat list, now with the building and floor each flat is in ───
-- The same as owner_schema.sql's, plus three columns at the end. Re-running
-- owner_schema.sql puts the old one back; re-run this file after it.
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
  active_tenants  int,
  building_id     uuid,
  floor_number    int,
  building_name   text,
  unit_no         text
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
      where t.property_id = i.property_id and t.poster_id = l.owner_id and t.status in ('active', 'invited')),
    i.building_id, i.floor_number, ob.name, i.unit_no
  from public.owner_property_links l
  join public.inventory i on i.property_id = l.property_id
  left join public.owner_buildings ob on ob.id = i.building_id
  where l.owner_id = auth.uid()
    and public.is_approved_owner()
  order by l.linked_at desc;
$$;

-- ── The owner's notifications, with their buildings' visits ─────────────────
-- owner_schema.sql's owner_activity, plus a visit (scheduled or instant) asked
-- for through one of the owner's building QRs — once, not again per flat it
-- also put in the tenant's visits. Re-running owner_schema.sql puts the old
-- one back; re-run this file after it.
drop function if exists public.owner_activity(int);
create function public.owner_activity(p_days int default 30)
returns table (kind text, property_id text, request_id uuid, who text, slot_at timestamptz, message text, at timestamptz, building_id uuid)
language sql
stable
security definer
set search_path = public
as $$
  with mine as (
    select l.property_id from public.owner_property_links l
     where l.owner_id = auth.uid() and public.is_approved_owner()
  ), my_buildings as (
    select b.id, b.name from public.owner_buildings b
     where b.owner_id = auth.uid() and public.is_approved_owner()
  )
  select * from (
    select case when b.status = 'preference' or b.slot_at is null then 'visit_requested' else 'visit_booked' end,
           b.property_id, null::uuid,
           public.owner_display_name((select up.name from public.user_profiles up where up.id = b.user_id)),
           b.slot_at, ''::text, b.created_at, null::uuid
      from public.visit_bookings b
     where b.property_id in (select property_id from mine)
       and coalesce(b.status, '') not ilike 'cancel%'
       and b.created_at > now() - make_interval(days => p_days)
       and not exists (select 1 from public.owner_building_leads l
                        where l.user_id = b.user_id and b.property_id = any(l.property_ids)
                          and l.building_id in (select id from my_buildings))
    union all
    select case when l.kind = 'instant' then 'instant_visit' else 'building_visit' end,
           l.property_ids[1], null::uuid, public.owner_display_name(l.name), l.visit_at, mb.name,
           case when l.updated_by = 'renter' then l.updated_at else l.created_at end, l.building_id
      from public.owner_building_leads l
      join my_buildings mb on mb.id = l.building_id
     where l.status <> 'cancelled'
       and l.created_at > now() - make_interval(days => p_days)
    union all
    select 'liked', r.property_id, null::uuid,
           public.owner_display_name((select up.name from public.user_profiles up where up.id = r.user_id)),
           null::timestamptz, ''::text, r.updated_at, null::uuid
      from public.listing_reactions r
     where r.property_id in (select property_id from mine)
       and r.reaction = 'like'
       and r.updated_at > now() - make_interval(days => p_days)
    union all
    select 'request_update', q.property_id, q.id, ''::text, null::timestamptz, q.title || ': ' || e.message, e.at, null::uuid
      from public.owner_request_events e
      join public.owner_requests q on q.id = e.request_id
     where q.owner_id = auth.uid()
       and e.visible_to_owner and e.actor <> 'owner'
       and e.at > now() - make_interval(days => p_days)
  ) ev
  order by 7 desc
  limit 60;
$$;

-- ── Grants ───────────────────────────────────────────────────────────────────
do $$
declare f text;
begin
  foreach f in array array[
    'public.building_by_code(text)', 'public.building_role(uuid)', 'public.building_stats(uuid)', 'public.building_flats(uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
  foreach f in array array[
    'public.building_page(text)', 'public.building_view(text, text, text)',
    'public.building_request_visit(text, text, text, text, text[], timestamptz, text)',
    'public.building_instant_visit(text, text, text, text, text[])'
  ] loop
    execute format('revoke all on function %s from public', f);
    execute format('grant execute on function %s to anon, authenticated', f);
  end loop;
  foreach f in array array[
    'public.owner_properties()', 'public.owner_buildings_list()', 'public.owner_building_save(jsonb)', 'public.owner_building_set_flat(text, uuid, int)',
    'public.owner_building_detail(uuid)', 'public.owner_building_mark_booked(text, boolean)',
    'public.building_lead_update(uuid, jsonb)', 'public.partner_building_leads()',
    'public.crm_buildings()', 'public.crm_building_assign_broker(uuid, uuid)',
    'public.building_set_instant_visit(uuid, boolean, text, text)', 'public.owner_activity(int)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

commit;
