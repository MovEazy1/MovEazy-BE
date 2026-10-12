-- ─────────────────────────────────────────────────────────────────────────────
-- MovEazy Society — society.moveazy.co.in (fe/src/pages/society/).
--
-- A society's manager, guards and staff keep its flat inventory, and share in
-- MovEazy's brokerage when a flat they listed is rented out.
--
--   Societies   A manager sets one up in the app (Google Maps link → name,
--               address, map spot; towers, amenities, tenant rules, charges,
--               photos). It is an owner_buildings row of kind 'society' plus
--               society_accounts, and stays off the site (status 'paused')
--               until MovEazy approves it in the CRM. Meanwhile the manager
--               can add flats and invite people.
--   Members     manager (one or more: invites, removes, sets the split),
--               guard, staff. Google sign-in + mobile, joined by an invite
--               link; one active society per account. A member's number is
--               never a MovEazy tenant lead (crm_partners_not_leads.sql).
--   Flats       society_flats + an inventory row (source 'society',
--               partner_visible false: never shown to partners). Available →
--               published (once approved); Occupied → rented, never promoted
--               until someone confirms it is free. Block + flat number is
--               unique per society. The owner's number goes to
--               inventory_private, so the owner sees the flat in the owner
--               app (crm_onboarding.sql). Move-out reminders 15 days ahead.
--   Earnings    Brokerage on a closed deal = one month's rent. The society's
--               pool is pool_pct of it (70 by default, per society, set in the
--               CRM), split by the manager's percentages — equal until set —
--               locked on the deal. MovEazy pays each share by UPI and marks
--               it paid with the UTR; no UPI, the payout waits. A cancelled
--               deal never deletes history: unpaid shares are cancelled, paid
--               ones get an adjustment row.
--   Explore     societies_explore(): approved societies with an available
--               flat, for tenants — only once the CRM switches it live.
--   Audit       society_events: who did what, with a before/after summary.
--
-- Run in the Supabase SQL editor AFTER owner_buildings.sql, crm_onboarding.sql,
-- crm_property_internal.sql, storage_listing_access.sql, program_settings.sql
-- and crm_partners_not_leads.sql. Safe to re-run.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

-- ── Settings ─────────────────────────────────────────────────────────────────
alter table public.program_settings add column if not exists society_pool_pct numeric not null default 70
  check (society_pool_pct between 0 and 100);
alter table public.program_settings add column if not exists societies_explore_live boolean not null default false;

-- ── Tables ───────────────────────────────────────────────────────────────────
create table if not exists public.society_accounts (
  building_id     uuid primary key references public.owner_buildings (id) on delete cascade,
  place_id        text not null default '',
  google_url      text not null default '',
  towers          text[] not null default '{}',
  total_flats     int check (total_flats between 1 and 20000),
  year_built      int check (year_built between 1950 and 2100),
  maintenance     numeric check (maintenance between 0 and 1000000),
  rules           jsonb not null default '{}'::jsonb,
  pool_pct        numeric not null default 70 check (pool_pct between 0 and 100),
  status          text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  reject_reason   text not null default '',
  decided_at      timestamptz,
  decided_by      text not null default '',
  created_by      uuid references auth.users (id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create table if not exists public.society_members (
  id          uuid primary key default gen_random_uuid(),
  building_id uuid not null references public.owner_buildings (id) on delete cascade,
  user_id     uuid not null references auth.users (id) on delete cascade,
  name        text not null default '',
  phone       text not null default '',
  role        text not null default 'guard' check (role in ('manager', 'guard', 'staff')),
  status      text not null default 'active' check (status in ('active', 'removed')),
  split_pct   numeric check (split_pct between 0 and 100),
  upi_id      text not null default '',
  invited_by  uuid references auth.users (id) on delete set null,
  joined_at   timestamptz not null default now(),
  removed_at  timestamptz,
  unique (building_id, user_id)
);
create unique index if not exists society_members_one_active on public.society_members (user_id) where status = 'active';
create index if not exists society_members_building_idx on public.society_members (building_id, status);

create table if not exists public.society_invites (
  token       text primary key default replace(gen_random_uuid()::text, '-', ''),
  building_id uuid not null references public.owner_buildings (id) on delete cascade,
  role        text not null check (role in ('manager', 'guard', 'staff')),
  created_by  uuid references auth.users (id) on delete set null,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '14 days',
  revoked_at  timestamptz,
  used_count  int not null default 0
);

create table if not exists public.society_flats (
  property_id     text primary key references public.inventory (property_id) on delete cascade,
  building_id     uuid not null references public.owner_buildings (id) on delete cascade,
  block           text not null default '',
  flat_no         text not null check (length(flat_no) between 1 and 12),
  occupancy       text not null default 'available' check (occupancy in ('available', 'occupied')),
  move_out_date   date,
  notes           text not null default '',
  owner_name      text not null default '',
  owner_phone     text not null default '',
  created_by      uuid references auth.users (id) on delete set null,
  updated_by      uuid references auth.users (id) on delete set null,
  reminded_for    date,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create unique index if not exists society_flats_unique_no on public.society_flats (building_id, upper(block), upper(flat_no));
create index if not exists society_flats_building_idx on public.society_flats (building_id, updated_at desc);

create table if not exists public.society_deals (
  id            uuid primary key default gen_random_uuid(),
  building_id   uuid not null references public.owner_buildings (id) on delete cascade,
  property_id   text not null references public.inventory (property_id) on delete cascade,
  flat_label    text not null default '',
  rent          numeric not null check (rent > 0),
  brokerage     numeric not null check (brokerage > 0),
  pool_pct      numeric not null,
  pool_amount   numeric not null,
  split         jsonb not null default '[]'::jsonb,
  status        text not null default 'closed' check (status in ('closed', 'cancelled')),
  closed_on     date not null default (now() at time zone 'Asia/Kolkata')::date,
  reference     text not null default '',
  created_by    text not null default '',
  created_at    timestamptz not null default now(),
  cancelled_at  timestamptz,
  cancel_reason text not null default ''
);
create index if not exists society_deals_building_idx on public.society_deals (building_id, created_at desc);

create table if not exists public.society_payouts (
  id          uuid primary key default gen_random_uuid(),
  deal_id     uuid not null references public.society_deals (id) on delete cascade,
  building_id uuid not null references public.owner_buildings (id) on delete cascade,
  member_id   uuid not null references public.society_members (id) on delete cascade,
  user_id     uuid not null references auth.users (id) on delete cascade,
  kind        text not null default 'share' check (kind in ('share', 'adjustment')),
  share_pct   numeric not null default 0,
  amount      numeric not null,
  status      text not null default 'pending' check (status in ('pending', 'paid', 'cancelled', 'adjustment')),
  upi_id      text not null default '',
  utr         text not null default '',
  paid_at     timestamptz,
  paid_by     text not null default '',
  created_at  timestamptz not null default now()
);
create index if not exists society_payouts_user_idx on public.society_payouts (user_id, created_at desc);
create index if not exists society_payouts_deal_idx on public.society_payouts (deal_id);

create table if not exists public.society_notifications (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users (id) on delete cascade,
  building_id uuid references public.owner_buildings (id) on delete cascade,
  kind        text not null,
  title       text not null,
  body        text not null default '',
  link        text not null default '',
  created_at  timestamptz not null default now(),
  read_at     timestamptz
);
create index if not exists society_notifications_user_idx on public.society_notifications (user_id, created_at desc);

create table if not exists public.society_events (
  id          bigint generated always as identity primary key,
  building_id uuid references public.owner_buildings (id) on delete cascade,
  actor       uuid,
  actor_email text not null default '',
  action      text not null,
  entity      text not null default '',
  entity_id   text not null default '',
  summary     jsonb not null default '{}'::jsonb,
  at          timestamptz not null default now()
);
create index if not exists society_events_building_idx on public.society_events (building_id, at desc);

-- Everything goes through the functions below.
do $$
declare t text;
begin
  foreach t in array array['society_accounts', 'society_members', 'society_invites', 'society_flats', 'society_deals',
                           'society_payouts', 'society_notifications', 'society_events'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
    execute format('drop policy if exists "staff read" on public.%I', t);
    execute format('create policy "staff read" on public.%I for select to authenticated using (public.is_crm_staff())', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;

-- ── Helpers ──────────────────────────────────────────────────────────────────
/** The caller's active membership (or nothing). */
create or replace function public.society_my_member()
returns public.society_members
language sql
stable
security definer
set search_path = public
as $$
  select m.* from public.society_members m where m.user_id = auth.uid() and m.status = 'active' limit 1;
$$;

create or replace function public.society_is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.has_admin_scope('crm.properties.write') or public.is_admin_allowlisted();
$$;

create or replace function public.society_log(p_building uuid, p_action text, p_entity text, p_entity_id text, p_summary jsonb default '{}')
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.society_events (building_id, actor, actor_email, action, entity, entity_id, summary)
  values (p_building, auth.uid(), lower(coalesce(auth.jwt() ->> 'email', '')), p_action, p_entity, coalesce(p_entity_id, ''), coalesce(p_summary, '{}'));
$$;

create or replace function public.society_notify(p_building uuid, p_user uuid, p_kind text, p_title text, p_body text default '', p_link text default '')
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.society_notifications (user_id, building_id, kind, title, body, link)
  select p_user, p_building, p_kind, p_title, coalesce(p_body, ''), coalesce(p_link, '') where p_user is not null;
$$;

/** Each active member's share of the pool right now: the manager's split, or equal. */
create or replace function public.society_split_now(p_building uuid)
returns table (member_id uuid, user_id uuid, name text, pct numeric)
language sql
stable
security definer
set search_path = public
as $$
  with a as (
    select m.* from public.society_members m where m.building_id = p_building and m.status = 'active'
  ), s as (
    select bool_and(a.split_pct is not null) as set_all, coalesce(sum(a.split_pct), 0) as total, count(*) as n from a
  )
  select a.id, a.user_id, a.name,
         case when s.set_all and s.total = 100 then a.split_pct else round(100.0 / s.n, 4) end
    from a, s
   order by a.joined_at;
$$;

/** Flat label as people say it: "A-1203", or "1203" with no block. */
create or replace function public.society_flat_label(p_block text, p_flat text)
returns text
language sql
immutable
as $$
  select case when btrim(regexp_replace(regexp_replace(coalesce(p_block, ''), '(tower|block|wing|phase)', '', 'gi'), '\s+', '', 'g'), '-') = ''
              then upper(trim(p_flat))
              else upper(btrim(regexp_replace(regexp_replace(p_block, '(tower|block|wing|phase)', '', 'gi'), '\s+', '', 'g'), '-'))
                   || '-' || upper(trim(p_flat)) end;
$$;

/** What the app shows for one flat. `full`: owner contact and history too. */
create or replace function public.society_flat_json(p_property text, p_full boolean default false)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
           'property_id', f.property_id, 'block', f.block, 'flat_no', f.flat_no,
           'label', public.society_flat_label(f.block, f.flat_no),
           'occupancy', f.occupancy, 'move_out_date', f.move_out_date,
           'bhk', i.flat_type, 'rent', i.rent, 'furnishing', i.furnishing, 'area_sqft', i.area_sqft,
           'available_from', i.available_from, 'images', i.images, 'cover_image_url', i.cover_image_url,
           'live', i.status = 'published', 'updated_at', f.updated_at, 'created_at', f.created_at)
         || case when p_full then jsonb_build_object(
           'owner_name', f.owner_name, 'owner_phone', f.owner_phone, 'notes', f.notes,
           'created_by', (select m.name from public.society_members m where m.user_id = f.created_by and m.building_id = f.building_id),
           'updated_by', (select m.name from public.society_members m where m.user_id = f.updated_by and m.building_id = f.building_id),
           'deal', (select jsonb_build_object('id', d.id, 'closed_on', d.closed_on, 'rent', d.rent)
                      from public.society_deals d where d.property_id = f.property_id and d.status = 'closed'
                     order by d.created_at desc limit 1))
           else '{}'::jsonb end
    from public.society_flats f join public.inventory i on i.property_id = f.property_id
   where f.property_id = p_property;
$$;

/** The society as the app (and the CRM) sees it. */
create or replace function public.society_json(p_building uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
           'id', b.id, 'code', b.code, 'name', b.name, 'area', b.area, 'landmark', b.landmark,
           'full_address', b.full_address, 'latitude', b.latitude, 'longitude', b.longitude,
           'total_floors', b.total_floors, 'description', b.description, 'amenities', b.amenities, 'photos', b.photos,
           'place_id', a.place_id, 'google_url', a.google_url, 'towers', a.towers, 'total_flats', a.total_flats,
           'year_built', a.year_built, 'maintenance', a.maintenance, 'rules', a.rules, 'pool_pct', a.pool_pct,
           'status', a.status, 'reject_reason', a.reject_reason, 'created_at', a.created_at)
    from public.owner_buildings b join public.society_accounts a on a.building_id = b.id
   where b.id = p_building;
$$;

-- ── Never a tenant lead (crm_partners_not_leads.sql) ─────────────────────────
-- A society member is like a partner: their number is not demand. The guard
-- there asks this function; extended here to members.
create or replace function public.crm_partner_not_searching(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select (exists (select 1 from public.broker_partners b where b.user_id = p_user)
          or exists (select 1 from public.society_members m where m.user_id = p_user))
     and not exists (
           select 1 from public.user_requirements r
            where r.user_id = p_user
              and (cardinality(coalesce(r.localities, '{}')) > 0
                   or cardinality(coalesce(r.flat_types, '{}')) > 0
                   or r.budget_min is not null or r.budget_max is not null));
$$;

create or replace function public.society_members_drop_signup_lead()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.crm_drop_partner_signup_lead(new.user_id);
  return new;
exception when others then
  raise warning 'society_members_drop_signup_lead(%): %', new.user_id, sqlerrm;
  return new;
end;
$$;
drop trigger if exists society_members_drop_signup_lead on public.society_members;
create trigger society_members_drop_signup_lead after insert on public.society_members
  for each row execute function public.society_members_drop_signup_lead();

-- ── Photos: a society's members may change its flats' photos ─────────────────
create or replace function public.owns_listing(p_property text, p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_uid is not null and (
    exists (select 1 from public.inventory i
             where i.property_id = p_property
               and p_uid in (i.poster_id, i.broker_id, i.owner_id))
    or exists (select 1 from public.partner_listings pl where pl.property_id = p_property and pl.broker_id = p_uid)
    or exists (select 1 from public.owner_property_links ol where ol.property_id = p_property and ol.owner_id = p_uid)
    or exists (select 1 from public.society_flats f join public.society_members m on m.building_id = f.building_id
                where f.property_id = p_property and m.user_id = p_uid and m.status = 'active')
  );
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- The app
-- ═════════════════════════════════════════════════════════════════════════════

/** Who am I here: my membership and my society (or none yet). */
create or replace function public.society_me()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  m public.society_members;
  ph text;
begin
  if auth.uid() is null then return null; end if;
  m := public.society_my_member();
  select public.normalize_mobile(coalesce(p.phone, '')) into ph from public.user_profiles p where p.id = auth.uid();
  return jsonb_build_object(
    'phone', coalesce(ph, ''),
    'staff', public.society_is_admin(),
    'member', case when m.id is null then null else jsonb_build_object(
      'id', m.id, 'name', m.name, 'phone', m.phone, 'role', m.role, 'upi_id', m.upi_id, 'joined_at', m.joined_at) end,
    'society', case when m.id is null then null else public.society_json(m.building_id) end,
    'unread', (select count(*) from public.society_notifications n where n.user_id = auth.uid() and n.read_at is null)
  );
end;
$$;

/**
 * Set up a society (no membership yet: the caller becomes its manager), or
 * edit it (managers). A new society waits for MovEazy's approval; one that
 * was turned down goes back for review when it is edited.
 */
create or replace function public.society_setup_save(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid  uuid := auth.uid();
  m    public.society_members;
  bid  uuid;
  c    text;
  i    int;
  nm   text := left(trim(coalesce(p ->> 'name', '')), 80);
  ph   text;
  pname text;
  v_towers text[];
  was  jsonb;
begin
  if uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  m := public.society_my_member();
  if m.id is not null and m.role <> 'manager' then
    raise exception 'Only a manager can change the society''s details.' using errcode = '42501';
  end if;
  if length(nm) < 2 then raise exception 'Enter the society''s name.' using errcode = '22023'; end if;
  if trim(coalesce(p ->> 'area', '')) = '' then raise exception 'Enter the area (locality).' using errcode = '22023'; end if;
  v_towers := array(select left(trim(t.x), 30) from jsonb_array_elements_text(coalesce(p -> 'towers', '[]')) with ordinality t(x, o)
                     where trim(t.x) <> '' group by left(trim(t.x), 30) order by min(t.o) limit 60);

  if m.id is null then
    select public.normalize_mobile(coalesce(up.phone, '')), coalesce(nullif(trim(up.name), ''), split_part(coalesce(up.email, ''), '@', 1))
      into ph, pname from public.user_profiles up where up.id = uid;
    if coalesce(ph, '') = '' then raise exception 'Add your mobile number first.' using errcode = '22023'; end if;
    for i in 1..25 loop
      select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '') into c from generate_series(1, 6);
      exit when not exists (select 1 from public.owner_buildings where code = c);
    end loop;
    insert into public.owner_buildings (owner_id, code, name, kind, status, created_by)
    values (null, c, nm, 'society', 'paused', lower(coalesce(auth.jwt() ->> 'email', '')))
    returning id into bid;
    insert into public.society_accounts (building_id, created_by, pool_pct)
    values (bid, uid, coalesce((select ps.society_pool_pct from public.program_settings ps where ps.id = 1), 70));
    insert into public.society_members (building_id, user_id, name, phone, role)
    values (bid, uid, left(coalesce(nullif(trim(p ->> 'manager_name'), ''), pname, ''), 80), ph, 'manager');
  else
    bid := m.building_id;
    was := public.society_json(bid);
  end if;

  update public.owner_buildings b set
    name         = nm,
    area         = left(trim(p ->> 'area'), 80),
    landmark     = left(coalesce(p ->> 'landmark', ''), 160),
    full_address = left(coalesce(p ->> 'full_address', ''), 400),
    latitude     = nullif(p ->> 'latitude', '')::numeric,
    longitude    = nullif(p ->> 'longitude', '')::numeric,
    total_floors = nullif(p ->> 'total_floors', '')::int,
    description  = left(coalesce(p ->> 'description', ''), 2000),
    amenities    = array(select left(t.x, 60) from jsonb_array_elements_text(coalesce(p -> 'amenities', '[]')) with ordinality t(x, o)
                          group by left(t.x, 60) order by min(t.o) limit 60),
    photos       = array(select x from jsonb_array_elements_text(coalesce(p -> 'photos', '[]')) x where x ~ '^https://' limit 30),
    updated_at   = now()
  where b.id = bid;

  update public.society_accounts a set
    place_id    = left(coalesce(p ->> 'place_id', ''), 300),
    google_url  = left(coalesce(p ->> 'google_url', ''), 600),
    towers      = v_towers,
    total_flats = nullif(p ->> 'total_flats', '')::int,
    year_built  = nullif(p ->> 'year_built', '')::int,
    maintenance = nullif(p ->> 'maintenance', '')::numeric,
    rules       = jsonb_build_object(
                    'families', coalesce((p -> 'rules' ->> 'families')::boolean, true),
                    'bachelors', coalesce((p -> 'rules' ->> 'bachelors')::boolean, true),
                    'pets', coalesce((p -> 'rules' ->> 'pets')::boolean, false),
                    'veg_only', coalesce((p -> 'rules' ->> 'veg_only')::boolean, false),
                    'notes', left(coalesce(p -> 'rules' ->> 'notes', ''), 600)),
    status      = case when a.status = 'rejected' then 'pending' else a.status end,
    updated_at  = now()
  where a.building_id = bid;

  -- Flats take the society's place and amenities with them.
  update public.inventory i set
    area = b.area, landmark = b.landmark, full_address = b.full_address,
    latitude = coalesce(b.latitude, i.latitude), longitude = coalesce(b.longitude, i.longitude),
    amenities = b.amenities, updated_at = now()
    from public.owner_buildings b
   where b.id = bid and i.building_id = bid and i.source = 'society';

  perform public.society_log(bid, case when was is null then 'society_created' else 'society_updated' end, 'society', bid::text,
                             jsonb_build_object('before', was, 'after', public.society_json(bid)));
  return public.society_json(bid);
exception when check_violation or invalid_text_representation or numeric_value_out_of_range then
  raise exception 'Check the numbers: floors, flats, year built and maintenance.' using errcode = '22023';
end;
$$;

/** Home: the society's counts, what I've earned, and the latest flats. */
create or replace function public.society_home()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  m public.society_members := public.society_my_member();
begin
  if m.id is null then raise exception 'You''re not in a society yet.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'total', (select count(*) from public.society_flats f where f.building_id = m.building_id),
    'available', (select count(*) from public.society_flats f where f.building_id = m.building_id and f.occupancy = 'available'),
    'my_earned', (select coalesce(sum(p.amount), 0) from public.society_payouts p where p.user_id = m.user_id and p.building_id = m.building_id and p.status <> 'cancelled'),
    'recent', coalesce((select jsonb_agg(public.society_flat_json(x.property_id) order by x.created_at desc)
                          from (select f.property_id, f.created_at from public.society_flats f where f.building_id = m.building_id
                                 order by f.created_at desc limit 5) x), '[]'::jsonb)
  );
end;
$$;

/** All flats: search by flat number, block or owner name; filter all / available / occupied. */
create or replace function public.society_flats_list(p_filter text default 'all', p_q text default '')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  m public.society_members := public.society_my_member();
  q text := lower(trim(coalesce(p_q, '')));
begin
  if m.id is null then raise exception 'You''re not in a society yet.' using errcode = '42501'; end if;
  return (
    with s as (
      select f.* from public.society_flats f
       where f.building_id = m.building_id
         and (q = '' or lower(public.society_flat_label(f.block, f.flat_no)) like '%' || q || '%'
              or lower(f.flat_no) like '%' || q || '%' or lower(f.block) like '%' || q || '%'
              or lower(f.owner_name) like '%' || q || '%')
    )
    select jsonb_build_object(
      'counts', jsonb_build_object('all', count(*), 'available', count(*) filter (where occupancy = 'available'),
                                   'occupied', count(*) filter (where occupancy = 'occupied')),
      'flats', coalesce(jsonb_agg(public.society_flat_json(s.property_id) order by upper(s.block), s.flat_no)
                          filter (where coalesce(p_filter, 'all') = 'all' or s.occupancy = p_filter), '[]'::jsonb))
      from s
  );
end;
$$;

create or replace function public.society_flat(p_property text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  m public.society_members := public.society_my_member();
begin
  if not exists (select 1 from public.society_flats f where f.property_id = p_property and f.building_id = m.building_id) then
    raise exception 'That flat isn''t in your society.' using errcode = '42501';
  end if;
  return public.society_flat_json(p_property, true);
end;
$$;

/**
 * Add or edit a flat. A block + flat number already in the society returns
 * {duplicate: property_id} instead of a second record. Marking an occupied
 * flat available needs confirm_available: that is what puts it on the site.
 */
create or replace function public.society_flat_save(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid   uuid := auth.uid();
  m     public.society_members := public.society_my_member();
  b     public.owner_buildings;
  a     public.society_accounts;
  pid   text := upper(trim(coalesce(p ->> 'property_id', '')));
  cur   public.society_flats;
  blk   text := left(trim(coalesce(p ->> 'block', '')), 30);
  fno   text := upper(left(regexp_replace(trim(coalesce(p ->> 'flat_no', '')), '\s+', '', 'g'), 12));
  bhk   text := coalesce(p ->> 'bhk', '');
  v_rent numeric;
  furn  text := coalesce(p ->> 'furnishing', '');
  occ   text := coalesce(p ->> 'occupancy', 'available');
  oname text := left(trim(coalesce(p ->> 'owner_name', '')), 80);
  oph   text := public.normalize_mobile(coalesce(p ->> 'owner_phone', ''));
  dt    date;
  sqft  int;
  imgs  text[] := array(select x from jsonb_array_elements_text(coalesce(p -> 'images', '[]')) x where x ~ '^https://' limit 30);
  dup   text;
  st    text;
  was   jsonb;
  fresh boolean;
begin
  if m.id is null then raise exception 'You''re not in a society yet.' using errcode = '42501'; end if;
  select * into b from public.owner_buildings where id = m.building_id;
  select * into a from public.society_accounts where building_id = m.building_id;

  if fno !~ '^[A-Z0-9/-]{1,12}$' then raise exception 'Enter the flat number (letters, numbers, - or /).' using errcode = '22023'; end if;
  if cardinality(a.towers) > 0 and not (blk = any (a.towers)) then raise exception 'Pick the building / block.' using errcode = '22023'; end if;
  if bhk not in ('1 RK', '1 BHK', '2 BHK', '3 BHK', '4 BHK', '5 BHK') then raise exception 'Pick the BHK type.' using errcode = '22023'; end if;
  begin v_rent := nullif(p ->> 'rent', '')::numeric; exception when others then v_rent := null; end;
  if v_rent is null or v_rent < 1000 or v_rent > 2000000 then raise exception 'Enter the expected rent (₹1,000 or more).' using errcode = '22023'; end if;
  if furn not in ('Fully Furnished', 'Semi Furnished', 'Unfurnished') then raise exception 'Pick the furnishing.' using errcode = '22023'; end if;
  if occ not in ('available', 'occupied') then raise exception 'Pick Available or Occupied.' using errcode = '22023'; end if;
  if length(oname) < 2 then raise exception 'Enter the owner''s name.' using errcode = '22023'; end if;
  if oph = '' then raise exception 'Enter the owner''s 10-digit mobile number.' using errcode = '22023'; end if;
  begin dt := nullif(p ->> 'date', '')::date; exception when others then raise exception 'Pick a valid date.' using errcode = '22023'; end;
  begin sqft := nullif(p ->> 'area_sqft', '')::int; exception when others then raise exception 'Enter the size in sq ft as a number.' using errcode = '22023'; end;
  if sqft is not null and (sqft < 100 or sqft > 20000) then raise exception 'Enter the size in sq ft (100–20,000).' using errcode = '22023'; end if;

  if pid <> '' then select * into cur from public.society_flats where property_id = pid; end if;
  fresh := cur.property_id is null;
  if not fresh and cur.building_id <> m.building_id then raise exception 'That flat isn''t in your society.' using errcode = '42501'; end if;

  select f.property_id into dup from public.society_flats f
   where f.building_id = m.building_id and upper(f.block) = upper(blk) and upper(f.flat_no) = fno
     and f.property_id is distinct from cur.property_id;
  if dup is not null then
    return jsonb_build_object('duplicate', dup, 'label', public.society_flat_label(blk, fno));
  end if;

  if not fresh and cur.occupancy = 'occupied' and occ = 'available' and not coalesce((p ->> 'confirm_available')::boolean, false) then
    raise exception 'Confirm the flat is free to rent before marking it available.' using errcode = 'P0001';
  end if;

  st := case when occ = 'occupied' then 'rented' when a.status = 'approved' then 'published' else 'paused' end;

  if fresh then
    if pid !~ '^MZ-[A-Z0-9]{6}$' or exists (select 1 from public.inventory where property_id = pid) then
      loop
        select 'MZ-' || string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '') into pid from generate_series(1, 6);
        exit when not exists (select 1 from public.inventory where property_id = pid);
      end loop;
    end if;
    insert into public.inventory (property_id, posted_by, poster_id, poster_name, city, area, landmark, full_address, latitude, longitude,
                                  rent, available_from, flat_type, bedrooms, furnishing, amenities, title, description, images,
                                  status, building_id, unit_no, area_sqft, source, partner_visible)
    values (pid, 'owner', uid, b.name, 'Bengaluru', b.area, b.landmark, b.full_address, b.latitude, b.longitude,
            v_rent, case when occ = 'available' then coalesce(dt, current_date) else dt end, bhk,
            coalesce(nullif(substring(bhk from '^(\d)'), '')::int, 1), furn, b.amenities,
            bhk || ' in ' || b.name, bhk || ' in ' || b.name || ', ' || b.area || '.', imgs,
            st, b.id, public.society_flat_label(blk, fno), sqft, 'society', false);
    insert into public.society_flats (property_id, building_id, block, flat_no, occupancy, move_out_date, notes, owner_name, owner_phone, created_by, updated_by)
    values (pid, b.id, blk, fno, occ, case when occ = 'occupied' then dt end, left(coalesce(p ->> 'notes', ''), 1000), oname, oph, uid, uid);
  else
    was := public.society_flat_json(pid, true);
    update public.inventory i set
      rent = v_rent, flat_type = bhk, bedrooms = coalesce(nullif(substring(bhk from '^(\d)'), '')::int, 1), furnishing = furn,
      available_from = case when occ = 'available' then coalesce(dt, i.available_from, current_date) else dt end,
      images = imgs, status = st, unit_no = public.society_flat_label(blk, fno), area_sqft = sqft,
      title = bhk || ' in ' || b.name, partner_visible = false, updated_at = now()
     where i.property_id = pid;
    update public.society_flats f set
      block = blk, flat_no = fno, occupancy = occ, move_out_date = case when occ = 'occupied' then dt end,
      notes = left(coalesce(p ->> 'notes', ''), 1000), owner_name = oname, owner_phone = oph,
      reminded_for = case when occ = 'occupied' and dt is distinct from f.move_out_date then null else f.reminded_for end,
      updated_by = uid, updated_at = now()
     where f.property_id = pid;
  end if;

  -- The owner: MovEazy's contact for the flat, and their way into the owner app.
  insert into public.inventory_private as ip (property_id, source, poc_name, poc_phone, owner_onboarded, owner_phone, created_by)
  values (pid, 'owner', oname, oph, true, oph, 'society:' || coalesce(auth.jwt() ->> 'email', ''))
  on conflict (property_id) do update
     set poc_name = excluded.poc_name, poc_phone = excluded.poc_phone, owner_onboarded = true,
         owner_phone = excluded.owner_phone, updated_at = now();

  perform public.society_log(b.id, case when fresh then 'flat_added' else 'flat_updated' end, 'flat', pid,
                             jsonb_build_object('before', was, 'after', public.society_flat_json(pid, true)));
  return public.society_flat_json(pid, true);
end;
$$;

/** Members, managers first. Numbers only for managers' eyes. */
create or replace function public.society_members_list()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  m public.society_members := public.society_my_member();
begin
  if m.id is null then raise exception 'You''re not in a society yet.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'can_manage', m.role = 'manager',
    'split_custom', exists (select 1 from public.society_members x where x.building_id = m.building_id and x.status = 'active' and x.split_pct is not null),
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', x.id, 'name', x.name, 'role', x.role, 'me', x.user_id = m.user_id,
               'phone', case when m.role = 'manager' or x.user_id = m.user_id then x.phone else '' end,
               'joined_at', x.joined_at, 'pct', s.pct, 'has_upi', x.upi_id <> '')
             order by case x.role when 'manager' then 0 when 'guard' then 1 else 2 end, x.joined_at)
        from public.society_members x join public.society_split_now(m.building_id) s on s.member_id = x.id
       where x.building_id = m.building_id and x.status = 'active'), '[]'::jsonb));
end;
$$;

/** An invite link for a role. Managers only. */
create or replace function public.society_invite_create(p_role text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.society_members := public.society_my_member();
  t text;
begin
  if m.id is null or m.role <> 'manager' then raise exception 'Only a manager can invite members.' using errcode = '42501'; end if;
  if p_role not in ('manager', 'guard', 'staff') then raise exception 'Pick a role.' using errcode = '22023'; end if;
  -- One live link per role: share the same one again rather than piling up.
  select i.token into t from public.society_invites i
   where i.building_id = m.building_id and i.role = p_role and i.revoked_at is null and i.expires_at > now() + interval '3 days'
   order by i.created_at desc limit 1;
  if t is null then
    insert into public.society_invites (building_id, role, created_by) values (m.building_id, p_role, m.user_id) returning token into t;
    perform public.society_log(m.building_id, 'invite_created', 'invite', t, jsonb_build_object('role', p_role));
  end if;
  return (select jsonb_build_object('token', i.token, 'role', i.role, 'expires_at', i.expires_at,
                                    'society', b.name)
            from public.society_invites i join public.owner_buildings b on b.id = i.building_id where i.token = t);
end;
$$;

/** What an invite link is, before signing in. */
create or replace function public.society_invite_peek(p_token text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select jsonb_build_object(
             'society', b.name, 'area', b.area, 'role', i.role,
             'valid', i.revoked_at is null and i.expires_at > now(),
             'reason', case when i.revoked_at is not null then 'revoked' when i.expires_at <= now() then 'expired' else '' end)
      from public.society_invites i join public.owner_buildings b on b.id = i.building_id
     where i.token = p_token), jsonb_build_object('valid', false, 'reason', 'unknown'));
$$;

/** Join through an invite: the society on the link, the role on the link. */
create or replace function public.society_invite_accept(p_token text, p_name text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  i   public.society_invites;
  cur public.society_members;
  ph  text;
  nm  text;
begin
  if uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  select * into i from public.society_invites where token = p_token;
  if i.token is null then raise exception 'This invite link isn''t valid. Ask your manager for a new one.' using errcode = '22023'; end if;
  if i.revoked_at is not null then raise exception 'This invite was cancelled. Ask your manager for a new one.' using errcode = '22023'; end if;
  if i.expires_at <= now() then raise exception 'This invite has expired. Ask your manager for a new one.' using errcode = '22023'; end if;
  cur := public.society_my_member();
  if cur.id is not null and cur.building_id <> i.building_id then
    raise exception 'You''re already a member of another society. Ask its manager to remove you first.' using errcode = '22023';
  end if;
  if cur.id is not null then return jsonb_build_object('joined', false, 'already', true); end if;
  select public.normalize_mobile(coalesce(up.phone, '')), coalesce(nullif(trim(p_name), ''), nullif(trim(up.name), ''), split_part(coalesce(up.email, ''), '@', 1))
    into ph, nm from public.user_profiles up where up.id = uid;
  if coalesce(ph, '') = '' then raise exception 'Add your mobile number first.' using errcode = '22023'; end if;

  insert into public.society_members as sm (building_id, user_id, name, phone, role, invited_by)
  values (i.building_id, uid, left(nm, 80), ph, i.role, i.created_by)
  on conflict (building_id, user_id) do update
     set status = 'active', role = excluded.role, phone = excluded.phone, removed_at = null, joined_at = now(),
         name = coalesce(nullif(excluded.name, ''), sm.name);
  update public.society_invites set used_count = used_count + 1 where token = i.token;
  -- Someone new: a custom split no longer adds up, so it goes back to equal.
  update public.society_members set split_pct = null where building_id = i.building_id and split_pct is not null;
  perform public.society_notify(i.building_id, x.user_id, 'member_joined', left(nm, 80) || ' joined as ' || i.role,
                                'The earnings split is equal again — set it from Members if you share it differently.', '/members')
     from public.society_members x where x.building_id = i.building_id and x.role = 'manager' and x.status = 'active' and x.user_id <> uid;
  perform public.society_log(i.building_id, 'member_joined', 'member', uid::text, jsonb_build_object('role', i.role, 'invite', i.token));
  return jsonb_build_object('joined', true);
end;
$$;

/** Change a member's role, or remove them. Managers only; never the last manager. */
create or replace function public.society_member_update(p_member uuid, p_role text default null, p_remove boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me public.society_members := public.society_my_member();
  x  public.society_members;
begin
  if me.id is null or me.role <> 'manager' then raise exception 'Only a manager can change members.' using errcode = '42501'; end if;
  select * into x from public.society_members where id = p_member and building_id = me.building_id and status = 'active';
  if x.id is null then raise exception 'That member isn''t in your society.' using errcode = '22023'; end if;
  if (p_remove or coalesce(p_role, x.role) <> 'manager') and x.role = 'manager'
     and (select count(*) from public.society_members y where y.building_id = me.building_id and y.status = 'active' and y.role = 'manager') <= 1 then
    raise exception 'A society needs at least one manager. Make someone else a manager first.' using errcode = '22023';
  end if;
  if p_remove then
    -- Access ends; their flats and earnings stay attributed to them.
    update public.society_members set status = 'removed', removed_at = now(), split_pct = null where id = x.id;
    update public.society_members set split_pct = null where building_id = me.building_id and split_pct is not null;
    perform public.society_log(me.building_id, 'member_removed', 'member', x.user_id::text, jsonb_build_object('name', x.name, 'role', x.role));
  elsif p_role in ('manager', 'guard', 'staff') and p_role <> x.role then
    update public.society_members set role = p_role where id = x.id;
    perform public.society_log(me.building_id, 'member_role', 'member', x.user_id::text, jsonb_build_object('from', x.role, 'to', p_role));
  end if;
  return public.society_members_list();
end;
$$;

/**
 * The manager's split of the society's pool: [{member_id, pct}] for every
 * active member, adding up to 100. An empty list goes back to equal.
 * Applies to deals closed from now on; every change is logged.
 */
create or replace function public.society_split_set(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me public.society_members := public.society_my_member();
  before jsonb;
  total numeric;
  n_in int;
  n_active int;
begin
  if me.id is null or me.role <> 'manager' then raise exception 'Only a manager can set the split.' using errcode = '42501'; end if;
  select jsonb_agg(jsonb_build_object('name', s.name, 'pct', s.pct)) into before from public.society_split_now(me.building_id) s;
  if p is null or jsonb_array_length(p) = 0 then
    update public.society_members set split_pct = null where building_id = me.building_id;
  else
    select count(*) into n_active from public.society_members where building_id = me.building_id and status = 'active';
    select count(*), coalesce(sum((x ->> 'pct')::numeric), 0) into n_in, total
      from jsonb_array_elements(p) x
      join public.society_members m on m.id = (x ->> 'member_id')::uuid and m.building_id = me.building_id and m.status = 'active';
    if n_in <> n_active or n_in <> jsonb_array_length(p) then raise exception 'Give every member a share.' using errcode = '22023'; end if;
    if total <> 100 then raise exception '%', 'The shares must add up to 100% (now ' || trim(to_char(total, 'FM999990.##')) || '%).' using errcode = '22023'; end if;
    if exists (select 1 from jsonb_array_elements(p) x where (x ->> 'pct')::numeric < 0 or (x ->> 'pct')::numeric > 100) then
      raise exception 'Each share is between 0%% and 100%%.' using errcode = '22023';
    end if;
    update public.society_members m set split_pct = (x ->> 'pct')::numeric
      from jsonb_array_elements(p) x where m.id = (x ->> 'member_id')::uuid and m.building_id = me.building_id;
  end if;
  perform public.society_log(me.building_id, 'split_changed', 'society', me.building_id::text,
                             jsonb_build_object('before', before,
                                                'after', (select jsonb_agg(jsonb_build_object('name', s.name, 'pct', s.pct)) from public.society_split_now(me.building_id) s)));
  return public.society_members_list();
end;
$$;

/** My earnings: total, pending, paid, and every ledger row with its deal. */
create or replace function public.society_earnings()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  m public.society_members := public.society_my_member();
begin
  if m.id is null then raise exception 'You''re not in a society yet.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'total', (select coalesce(sum(p.amount), 0) from public.society_payouts p where p.user_id = m.user_id and p.status <> 'cancelled'),
    'pending', (select coalesce(sum(p.amount), 0) from public.society_payouts p where p.user_id = m.user_id and p.status = 'pending'),
    'paid', (select coalesce(sum(p.amount), 0) from public.society_payouts p where p.user_id = m.user_id and p.status in ('paid', 'adjustment')),
    'pool_pct', (select a.pool_pct from public.society_accounts a where a.building_id = m.building_id),
    'upi_id', m.upi_id,
    'entries', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id, 'kind', p.kind, 'status', p.status, 'amount', p.amount, 'share_pct', p.share_pct,
               'utr', p.utr, 'paid_at', p.paid_at, 'created_at', p.created_at,
               'deal_ref', upper(left(replace(d.id::text, '-', ''), 8)), 'flat', d.flat_label, 'bhk', i.flat_type,
               'closed_on', d.closed_on, 'brokerage', d.brokerage, 'pool_pct', d.pool_pct, 'pool_amount', d.pool_amount,
               'deal_status', d.status)
             order by p.created_at desc)
        from public.society_payouts p
        join public.society_deals d on d.id = p.deal_id
        left join public.inventory i on i.property_id = d.property_id
       where p.user_id = m.user_id), '[]'::jsonb));
end;
$$;

/** My UPI ID (format-checked; MovEazy pays to it by hand) and my name. */
create or replace function public.society_profile_save(p_name text default null, p_upi text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.society_members := public.society_my_member();
  upi text := lower(trim(coalesce(p_upi, '')));
begin
  if m.id is null then raise exception 'You''re not in a society yet.' using errcode = '42501'; end if;
  if p_upi is not null then
    if upi !~ '^[a-z0-9][a-z0-9._-]{1,255}@[a-z][a-z0-9]{1,63}$' then
      raise exception 'That doesn''t look like a UPI ID — it''s like name@okaxis.' using errcode = '22023';
    end if;
    update public.society_members set upi_id = upi where id = m.id;
    -- Shares waiting for an ID carry it from now on.
    update public.society_payouts set upi_id = upi where user_id = m.user_id and status = 'pending';
    perform public.society_log(m.building_id, 'upi_saved', 'member', m.user_id::text, jsonb_build_object('had', m.upi_id <> ''));
  end if;
  if p_name is not null and length(trim(p_name)) >= 2 then
    update public.society_members set name = left(trim(p_name), 80) where id = m.id;
  end if;
  return public.society_me();
end;
$$;

/**
 * Due work, checked whenever the app opens: an occupied flat freeing up in 15
 * days or less reminds whoever added it (or the managers, if they've left) —
 * once per move-out date.
 */
create or replace function public.society_tick()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.society_members := public.society_my_member();
  f record;
  n int := 0;
  who uuid;
begin
  if m.id is null then return 0; end if;
  for f in
    select * from public.society_flats x
     where x.building_id = m.building_id and x.occupancy = 'occupied' and x.move_out_date is not null
       and x.move_out_date <= (now() at time zone 'Asia/Kolkata')::date + 15
       and x.move_out_date >= (now() at time zone 'Asia/Kolkata')::date - 7
       and x.reminded_for is distinct from x.move_out_date
  loop
    select y.user_id into who from public.society_members y where y.building_id = f.building_id and y.user_id = f.created_by and y.status = 'active';
    if who is not null then
      perform public.society_notify(f.building_id, who, 'move_out',
        public.society_flat_label(f.block, f.flat_no) || ' frees up on ' || to_char(f.move_out_date, 'FMDD Mon'),
        'Mark it Available so MovEazy can find a tenant.', '/flats/' || f.property_id);
    else
      perform public.society_notify(f.building_id, y.user_id, 'move_out',
        public.society_flat_label(f.block, f.flat_no) || ' frees up on ' || to_char(f.move_out_date, 'FMDD Mon'),
        'Mark it Available so MovEazy can find a tenant.', '/flats/' || f.property_id)
        from public.society_members y where y.building_id = f.building_id and y.role = 'manager' and y.status = 'active';
    end if;
    update public.society_flats set reminded_for = f.move_out_date where property_id = f.property_id;
    n := n + 1;
  end loop;
  return n;
end;
$$;

create or replace function public.society_notifications_list()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'kind', n.kind, 'title', n.title, 'body', n.body, 'link', n.link,
                                               'created_at', n.created_at, 'read', n.read_at is not null) order by n.created_at desc), '[]'::jsonb)
    from (select * from public.society_notifications where user_id = auth.uid() order by created_at desc limit 60) n;
$$;

create or replace function public.society_notifications_read()
returns void
language sql
security definer
set search_path = public
as $$
  update public.society_notifications set read_at = now() where user_id = auth.uid() and read_at is null;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- The CRM
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.crm_societies()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.society_is_admin() then raise exception 'Needs permission to manage properties.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'live', (select ps.societies_explore_live from public.program_settings ps where ps.id = 1),
    'default_pool_pct', (select ps.society_pool_pct from public.program_settings ps where ps.id = 1),
    'live_flats', (select count(*) from public.society_flats f join public.inventory i on i.property_id = f.property_id
                    where i.status = 'published'),
    'societies', coalesce((
      select jsonb_agg(public.society_json(a.building_id) || jsonb_build_object(
               'flats', (select count(*) from public.society_flats f where f.building_id = a.building_id),
               'available', (select count(*) from public.society_flats f where f.building_id = a.building_id and f.occupancy = 'available'),
               'no_photos', (select count(*) from public.society_flats f join public.inventory i on i.property_id = f.property_id
                              where f.building_id = a.building_id and f.occupancy = 'available' and cardinality(coalesce(i.images, '{}')) = 0),
               'members', (select count(*) from public.society_members m where m.building_id = a.building_id and m.status = 'active'),
               'manager', (select jsonb_build_object('name', m.name, 'phone', m.phone) from public.society_members m
                            where m.building_id = a.building_id and m.role = 'manager' and m.status = 'active' order by m.joined_at limit 1),
               'pending_payout', (select coalesce(sum(p.amount), 0) from public.society_payouts p where p.building_id = a.building_id and p.status = 'pending'))
             order by case a.status when 'pending' then 0 when 'approved' then 1 else 2 end, a.created_at desc)
        from public.society_accounts a), '[]'::jsonb));
end;
$$;

create or replace function public.crm_society(p_building uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.society_is_admin() then raise exception 'Needs permission to manage properties.' using errcode = '42501'; end if;
  if not exists (select 1 from public.society_accounts where building_id = p_building) then raise exception 'No such society.' using errcode = '22023'; end if;
  return public.society_json(p_building) || jsonb_build_object(
    'members', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'phone', m.phone, 'role', m.role, 'status', m.status,
                                                            'upi_id', m.upi_id, 'joined_at', m.joined_at, 'pct', s.pct)
                                          order by m.status, m.joined_at)
                           from public.society_members m left join public.society_split_now(p_building) s on s.member_id = m.id
                          where m.building_id = p_building), '[]'::jsonb),
    'flats', coalesce((select jsonb_agg(public.society_flat_json(f.property_id, true) order by upper(f.block), f.flat_no)
                         from public.society_flats f where f.building_id = p_building), '[]'::jsonb),
    'deals', coalesce((select jsonb_agg(jsonb_build_object(
                                 'id', d.id, 'flat', d.flat_label, 'property_id', d.property_id, 'rent', d.rent, 'brokerage', d.brokerage,
                                 'pool_pct', d.pool_pct, 'pool_amount', d.pool_amount, 'status', d.status, 'closed_on', d.closed_on,
                                 'reference', d.reference, 'cancel_reason', d.cancel_reason,
                                 'payouts', (select jsonb_agg(jsonb_build_object('id', p.id, 'name', m.name, 'kind', p.kind, 'share_pct', p.share_pct,
                                                                                 'amount', p.amount, 'status', p.status, 'upi_id', coalesce(nullif(p.upi_id, ''), m.upi_id),
                                                                                 'utr', p.utr, 'paid_at', p.paid_at) order by p.created_at, m.name)
                                               from public.society_payouts p join public.society_members m on m.id = p.member_id
                                              where p.deal_id = d.id))
                               order by d.created_at desc)
                         from public.society_deals d where d.building_id = p_building), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(jsonb_build_object('at', e.at, 'action', e.action, 'actor', coalesce(
                                   (select m.name from public.society_members m where m.user_id = e.actor and m.building_id = p_building), e.actor_email),
                                   'entity', e.entity, 'entity_id', e.entity_id) order by e.at desc)
                          from (select * from public.society_events where building_id = p_building order by at desc limit 80) e), '[]'::jsonb));
end;
$$;

/** Approve (everything available goes live) or turn down, with a reason the manager sees. */
create or replace function public.crm_society_decide(p_building uuid, p_approve boolean, p_reason text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.society_accounts;
begin
  if not public.society_is_admin() then raise exception 'Needs permission to manage properties.' using errcode = '42501'; end if;
  select * into a from public.society_accounts where building_id = p_building;
  if a.building_id is null then raise exception 'No such society.' using errcode = '22023'; end if;
  if not p_approve and length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Say why, so the manager can fix it.' using errcode = '22023'; end if;
  update public.society_accounts set status = case when p_approve then 'approved' else 'rejected' end,
         reject_reason = case when p_approve then '' else left(trim(p_reason), 400) end,
         decided_at = now(), decided_by = lower(coalesce(auth.jwt() ->> 'email', '')), updated_at = now()
   where building_id = p_building;
  update public.owner_buildings set status = case when p_approve then 'active' else 'paused' end, updated_at = now() where id = p_building;
  update public.inventory i set status = case when p_approve then 'published' else 'paused' end, updated_at = now()
    from public.society_flats f
   where f.property_id = i.property_id and f.building_id = p_building and f.occupancy = 'available';
  perform public.society_notify(p_building, m.user_id, case when p_approve then 'approved' else 'rejected' end,
            case when p_approve then 'Your society is live on MovEazy' else 'Your society needs changes' end,
            case when p_approve then 'Available flats are now on moveazy.co.in for tenants.' else trim(p_reason) end,
            case when p_approve then '/' else '/setup' end)
     from public.society_members m where m.building_id = p_building and m.role = 'manager' and m.status = 'active';
  perform public.society_log(p_building, case when p_approve then 'society_approved' else 'society_rejected' end, 'society', p_building::text,
                             jsonb_build_object('reason', p_reason));
  return public.society_json(p_building);
end;
$$;

create or replace function public.crm_society_set_pool(p_building uuid, p_pct numeric)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  was numeric;
begin
  if not public.society_is_admin() then raise exception 'Needs permission to manage properties.' using errcode = '42501'; end if;
  if p_pct is null or p_pct < 0 or p_pct > 100 then raise exception 'Between 0 and 100.' using errcode = '22023'; end if;
  select pool_pct into was from public.society_accounts where building_id = p_building;
  update public.society_accounts set pool_pct = p_pct, updated_at = now() where building_id = p_building;
  perform public.society_log(p_building, 'pool_changed', 'society', p_building::text, jsonb_build_object('from', was, 'to', p_pct));
  return public.society_json(p_building);
end;
$$;

/** Explore societies on or off for tenants, and the default pool for new societies. */
create or replace function public.crm_society_settings(p_live boolean default null, p_default_pool numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.society_is_admin() then raise exception 'Needs permission to manage properties.' using errcode = '42501'; end if;
  if p_default_pool is not null and (p_default_pool < 0 or p_default_pool > 100) then raise exception 'Between 0 and 100.' using errcode = '22023'; end if;
  update public.program_settings set
    societies_explore_live = coalesce(p_live, societies_explore_live),
    society_pool_pct = coalesce(p_default_pool, society_pool_pct)
   where id = 1;
  perform public.society_log(null, 'settings_changed', 'settings', '1', jsonb_build_object('live', p_live, 'default_pool', p_default_pool));
  return (select jsonb_build_object('live', ps.societies_explore_live, 'default_pool_pct', ps.society_pool_pct) from public.program_settings ps where ps.id = 1);
end;
$$;


/**
 * A rental closed on a society flat: brokerage is one month's rent, the pool
 * is the society's percentage of it, and each active member's share is fixed
 * now by the split in force (whole rupees; the odd rupees go to the largest
 * share). The flat becomes occupied. Members are told.
 */
create or replace function public.crm_society_deal_close(p_property text, p_rent numeric default null, p_closed_on date default null, p_reference text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  f     public.society_flats;
  a     public.society_accounts;
  rnt   numeric;
  pool  numeric;
  did   uuid;
  s     record;
  amt   numeric;
  given numeric := 0;
  top   uuid;
  label text;
begin
  if not public.society_is_admin() then raise exception 'Needs permission to manage properties.' using errcode = '42501'; end if;
  select * into f from public.society_flats where property_id = p_property;
  if f.property_id is null then raise exception 'That isn''t a society flat.' using errcode = '22023'; end if;
  if exists (select 1 from public.society_deals d where d.property_id = p_property and d.status = 'closed'
              and d.created_at > now() - interval '30 days') then
    raise exception 'A deal on this flat was recorded in the last 30 days. Cancel that one first if it was wrong.' using errcode = '22023';
  end if;
  if not exists (select 1 from public.society_members m where m.building_id = f.building_id and m.status = 'active') then
    raise exception 'This society has no active members to pay.' using errcode = '22023';
  end if;
  select * into a from public.society_accounts where building_id = f.building_id;
  rnt := coalesce(p_rent, (select i.rent from public.inventory i where i.property_id = p_property));
  if rnt is null or rnt <= 0 then raise exception 'Enter the rent the deal closed at.' using errcode = '22023'; end if;
  pool := floor(rnt * a.pool_pct / 100);
  label := public.society_flat_label(f.block, f.flat_no);

  insert into public.society_deals (building_id, property_id, flat_label, rent, brokerage, pool_pct, pool_amount, split, closed_on, reference, created_by)
  values (f.building_id, p_property, label, rnt, rnt, a.pool_pct, pool,
          (select jsonb_agg(jsonb_build_object('member_id', x.member_id, 'name', x.name, 'pct', x.pct)) from public.society_split_now(f.building_id) x),
          coalesce(p_closed_on, (now() at time zone 'Asia/Kolkata')::date), left(coalesce(p_reference, ''), 200),
          lower(coalesce(auth.jwt() ->> 'email', '')))
  returning id into did;

  for s in select x.member_id, x.user_id, x.pct, m.upi_id
             from public.society_split_now(f.building_id) x join public.society_members m on m.id = x.member_id
            order by x.pct desc, m.joined_at loop
    amt := floor(pool * s.pct / 100);
    given := given + amt;
    top := coalesce(top, s.member_id);
    insert into public.society_payouts (deal_id, building_id, member_id, user_id, share_pct, amount, upi_id)
    values (did, f.building_id, s.member_id, s.user_id, s.pct, amt, s.upi_id);
  end loop;
  update public.society_payouts set amount = amount + (pool - given) where deal_id = did and member_id = top and pool > given;
  delete from public.society_payouts where deal_id = did and amount = 0;

  update public.society_flats set occupancy = 'occupied', move_out_date = null, updated_at = now() where property_id = p_property;
  update public.inventory set status = 'rented', updated_at = now() where property_id = p_property;

  perform public.society_notify(f.building_id, p.user_id, 'earning', 'Rental closed: ' || label,
            'Your share: ₹' || to_char(p.amount, 'FM99,99,99,999') ||
            case when coalesce(nullif(p.upi_id, ''), '') = '' then ' — add your UPI ID to get paid.' else ' — MovEazy will pay it to your UPI.' end,
            '/earnings')
     from public.society_payouts p where p.deal_id = did;
  perform public.society_log(f.building_id, 'deal_closed', 'deal', did::text,
                             jsonb_build_object('flat', label, 'rent', rnt, 'pool_pct', a.pool_pct, 'pool', pool));
  return jsonb_build_object('id', did, 'pool', pool);
end;
$$;

/** A deal that fell through: unpaid shares are cancelled, paid ones get an adjustment row. Nothing is deleted. */
create or replace function public.crm_society_deal_cancel(p_deal uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  d public.society_deals;
begin
  if not public.society_is_admin() then raise exception 'Needs permission to manage properties.' using errcode = '42501'; end if;
  select * into d from public.society_deals where id = p_deal;
  if d.id is null or d.status <> 'closed' then raise exception 'That deal isn''t open.' using errcode = '22023'; end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Say why it was cancelled.' using errcode = '22023'; end if;
  update public.society_deals set status = 'cancelled', cancelled_at = now(), cancel_reason = left(trim(p_reason), 300) where id = d.id;
  update public.society_payouts set status = 'cancelled' where deal_id = d.id and status = 'pending';
  insert into public.society_payouts (deal_id, building_id, member_id, user_id, kind, share_pct, amount, status, upi_id)
  select p.deal_id, p.building_id, p.member_id, p.user_id, 'adjustment', p.share_pct, -p.amount, 'adjustment', p.upi_id
    from public.society_payouts p where p.deal_id = d.id and p.status = 'paid' and p.kind = 'share';
  perform public.society_notify(d.building_id, p.user_id, 'earning', 'Deal cancelled: ' || d.flat_label, trim(p_reason), '/earnings')
     from public.society_payouts p where p.deal_id = d.id and p.kind = 'share';
  perform public.society_log(d.building_id, 'deal_cancelled', 'deal', d.id::text, jsonb_build_object('reason', p_reason));
  return jsonb_build_object('id', d.id, 'status', 'cancelled');
end;
$$;

/** MovEazy paid one share by UPI: the UTR proves it. */
create or replace function public.crm_society_payout_paid(p_payout uuid, p_utr text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.society_payouts;
  upi text;
  v_utr text := upper(regexp_replace(coalesce(p_utr, ''), '\s', '', 'g'));
begin
  if not public.society_is_admin() then raise exception 'Needs permission to manage properties.' using errcode = '42501'; end if;
  select * into p from public.society_payouts where id = p_payout;
  if p.id is null or p.status <> 'pending' then raise exception 'That payout isn''t waiting to be paid.' using errcode = '22023'; end if;
  if v_utr !~ '^[A-Z0-9]{8,30}$' then raise exception 'Enter the UPI reference (UTR).' using errcode = '22023'; end if;
  select coalesce(nullif(p.upi_id, ''), m.upi_id) into upi from public.society_members m where m.id = p.member_id;
  if coalesce(upi, '') = '' then raise exception 'This member hasn''t added a UPI ID yet.' using errcode = '22023'; end if;
  update public.society_payouts set status = 'paid', utr = v_utr, upi_id = upi, paid_at = now(),
         paid_by = lower(coalesce(auth.jwt() ->> 'email', '')) where id = p.id;
  perform public.society_notify(p.building_id, p.user_id, 'paid', '₹' || to_char(p.amount, 'FM99,99,99,999') || ' paid to ' || upi,
                                'UPI reference ' || v_utr, '/earnings');
  perform public.society_log(p.building_id, 'payout_paid', 'payout', p.id::text, jsonb_build_object('amount', p.amount, 'utr', v_utr));
  return jsonb_build_object('id', p.id, 'status', 'paid');
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- Tenants: Explore societies, and a society's own page
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.societies_explore_live()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select ps.societies_explore_live from public.program_settings ps where ps.id = 1), false)
         or (auth.uid() is not null and public.is_crm_staff());
$$;

/**
 * Approved societies with at least one flat to rent, nearest first when a
 * spot is given (within p_km). Only while the CRM has it live (staff always,
 * to preview). The spot is the neighbourhood, never the gate.
 */
create or replace function public.societies_explore(p_lat numeric default null, p_lng numeric default null, p_km numeric default 20)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with s as (
    select b.*, a.place_id, a.rules, a.maintenance, a.year_built, a.total_flats, a.towers,
           case when p_lat is null or p_lng is null or b.latitude is null then null
                else 6371 * 2 * asin(sqrt(power(sin(radians(b.latitude - p_lat) / 2), 2)
                     + cos(radians(p_lat)) * cos(radians(b.latitude)) * power(sin(radians(b.longitude - p_lng) / 2), 2))) end as km
      from public.owner_buildings b join public.society_accounts a on a.building_id = b.id
     where a.status = 'approved' and b.status = 'active' and public.societies_explore_live()
  ), f as (
    select f.building_id, i.rent, i.flat_type, i.images, i.cover_image_url
      from public.society_flats f join public.inventory i on i.property_id = f.property_id
     where f.occupancy = 'available' and i.status = 'published'
  )
  select jsonb_build_object('live', public.societies_explore_live(), 'societies', coalesce(jsonb_agg(x.j order by x.km nulls last, x.n desc), '[]'::jsonb))
    from (
      select s.km, (select count(*) from f where f.building_id = s.id) as n,
             jsonb_build_object(
               'code', s.code, 'name', s.name, 'area', s.area, 'landmark', s.landmark,
               'latitude', round(s.latitude, 3), 'longitude', round(s.longitude, 3), 'km', round(s.km::numeric, 1),
               'photos', s.photos, 'amenities', s.amenities, 'rules', s.rules, 'place_id', s.place_id,
               'maintenance', s.maintenance, 'year_built', s.year_built, 'total_flats', s.total_flats, 'towers', cardinality(s.towers),
               'flats', (select count(*) from f where f.building_id = s.id),
               'min_rent', (select min(f.rent) from f where f.building_id = s.id),
               'max_rent', (select max(f.rent) from f where f.building_id = s.id),
               'bhks', (select array_agg(distinct f.flat_type) from f where f.building_id = s.id),
               'flat_photos', (select array_agg(x) from (select coalesce(nullif(f.cover_image_url, ''), f.images[1]) x from f
                                where f.building_id = s.id and coalesce(nullif(f.cover_image_url, ''), f.images[1]) is not null limit 4) y)) as j
        from s
       where exists (select 1 from f where f.building_id = s.id)
         and (s.km is null or p_lat is null or s.km <= coalesce(p_km, 20))
    ) x;
$$;

/** What a society's public page adds to building_page: rules, charges, size, and its Google place. */
create or replace function public.society_public(p_code text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('place_id', a.place_id, 'rules', a.rules, 'maintenance', a.maintenance, 'year_built', a.year_built,
                            'total_flats', a.total_flats, 'towers', cardinality(a.towers))
    from public.owner_buildings b join public.society_accounts a on a.building_id = b.id
   where b.code = upper(trim(coalesce(p_code, ''))) and b.status = 'active' and a.status = 'approved';
$$;

/** Is this Google place one of our societies? (The Places proxy only looks up places we list.) */
create or replace function public.society_place_known(p_place text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.society_accounts a where a.place_id = p_place and a.place_id <> '');
$$;

-- ── Grants ───────────────────────────────────────────────────────────────────
do $$
declare
  f text;
begin
  -- Internal helpers: nobody calls these directly.
  foreach f in array array[
    'public.society_my_member()', 'public.society_is_admin()', 'public.society_log(uuid, text, text, text, jsonb)',
    'public.society_notify(uuid, uuid, text, text, text, text)', 'public.society_split_now(uuid)',
    'public.society_flat_json(text, boolean)', 'public.society_json(uuid)', 'public.society_members_drop_signup_lead()',
    'public.crm_partner_not_searching(uuid)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
  -- The app and the CRM: signed in (each checks who).
  foreach f in array array[
    'public.society_me()', 'public.society_setup_save(jsonb)', 'public.society_home()', 'public.society_flats_list(text, text)',
    'public.society_flat(text)', 'public.society_flat_save(jsonb)', 'public.society_members_list()', 'public.society_invite_create(text)',
    'public.society_invite_accept(text, text)', 'public.society_member_update(uuid, text, boolean)', 'public.society_split_set(jsonb)',
    'public.society_earnings()', 'public.society_profile_save(text, text)', 'public.society_tick()',
    'public.society_notifications_list()', 'public.society_notifications_read()',
    'public.crm_societies()', 'public.crm_society(uuid)', 'public.crm_society_decide(uuid, boolean, text)',
    'public.crm_society_set_pool(uuid, numeric)', 'public.crm_society_settings(boolean, numeric)',
    'public.crm_society_deal_close(text, numeric, date, text)', 'public.crm_society_deal_cancel(uuid, text)',
    'public.crm_society_payout_paid(uuid, text)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  -- Anyone: an invite's society, and the tenant side.
  foreach f in array array[
    'public.society_invite_peek(text)', 'public.societies_explore_live()', 'public.societies_explore(numeric, numeric, numeric)',
    'public.society_public(text)', 'public.society_place_known(text)'] loop
    execute format('revoke all on function %s from public', f);
    execute format('grant execute on function %s to anon, authenticated', f);
  end loop;
end $$;

commit;
