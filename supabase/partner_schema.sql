-- ─────────────────────────────────────────────────────────────────────────────
-- MovEazy Partners — the broker app (fe/src/pages/partners/*, fe/src/lib/partners*.js).
--
-- Run ONCE in the Supabase SQL editor, AFTER crm_schema.sql (is_super_admin,
-- has_admin_scope, is_crm_staff), inventory_schema.sql, customer_schema.sql and
-- program_settings.sql (the brokerage share on MovEazy listings, the price).
-- Uses inventory_private (crm_property_internal.sql) when it exists; defines
-- is_inventory_poster and normalize_mobile itself if their own files
-- (inventory_private_read.sql, lead_intake.sql) have not been run — with the
-- same definitions, so running those later changes nothing. Safe to re-run: every statement is
-- idempotent, and every function whose shape could change is dropped first
-- (create or replace cannot change a RETURNS TABLE — see tests/README.md).
--
-- == What a broker sees, and why the database decides it ==
--
-- A partner sees inventory from four places, and the rules differ per place:
--
--   mine      listings they added in the partner app, whatever their status.
--   moveazy   every published listing MovEazy holds that the CRM has not
--             switched off for partners (inventory.partner_visible). LOCKED
--             unless they hold the moveazy_inventory tier: no address, no
--             contacts. The broker keeps program_settings.property_share of
--             the brokerage (50% by default, set in the CRM).
--   broker    other partners' listings shared with "All MovEazy brokers".
--             Premium only (any active plan): a partner without one sees the
--             app on demo data (fe/docs/PARTNERS_LAUNCH_PRD.md).
--   group     other partners' listings shared with a group the caller is a
--             CURRENT member of. Leaving or being removed takes it away on the
--             next read; nothing is copied into the member's account.
--
-- That rule lives in partner_inventory() and nowhere else. The tables under it
-- grant brokers nothing directly, so a browser console asking the table for a
-- group listing gets the same answer as the app: nothing.
--
-- One canonical record per flat. A partner listing is an ordinary inventory
-- row (so it is live on moveazy.co.in like every other flat, and a customer
-- enquiry there reaches the CRM, not the broker) plus a marker row in
-- partner_listings and zero or more share rows. Sharing never duplicates.
--
-- Staff: the super admin holds everything. Any CRM staff member sees every
-- partner listing, group-only ones included, unlocked. partners.manage is the
-- scope for approving brokers, the auto-approve switch and granting premium.
-- ─────────────────────────────────────────────────────────────────────────────

create extension if not exists "pgcrypto";

begin;

-- ── Program settings ─────────────────────────────────────────────────────────
-- One row. auto_approve starts ON: an invited broker is in as soon as they
-- sign in and give a number. Turning it off queues new sign-ups as 'pending'
-- for the CRM's Brokers → MovEazy partners section.
create table if not exists public.partner_program_settings (
  id           int primary key default 1 check (id = 1),
  auto_approve boolean not null default true,
  updated_at   timestamptz not null default now(),
  updated_by   text not null default ''
);
insert into public.partner_program_settings (id) values (1) on conflict (id) do nothing;


-- ── Plans, by inventory type ─────────────────────────────────────────────────
-- Access is granted per TYPE of inventory, not as one "premium" bit, so a
-- later plan ("group inventory only", "broker network") is a row here and an
-- entitlement, not a schema change. Today only moveazy_inventory is paid.
create table if not exists public.partner_tiers (
  tier            text primary key,
  label           text not null,
  is_free         boolean not null default false,
  price_monthly   int not null default 0,     -- rupees
  trial_price     int not null default 0,     -- rupees, first month
  description     text not null default ''
);
insert into public.partner_tiers (tier, label, is_free, price_monthly, trial_price, description) values
  ('moveazy_inventory', 'MovEazy Premium', false, 2499, 999,
   'Unlock 1000+ MovEazy listings updated daily, with owner contacts.'),
  ('broker_network', 'Broker network', true, 0, 0,
   'Listings other partners share with all MovEazy brokers.'),
  ('group_inventory', 'Group inventory', true, 0, 0,
   'Listings shared inside the groups you belong to.')
on conflict (tier) do nothing;
-- The price lives in program_settings (the CRM edits it there); the plan row mirrors it.
update public.partner_tiers t
   set price_monthly = s.premium_price, trial_price = s.premium_price,
       description = replace(t.description, ' and 100% brokerage', '')
  from public.program_settings s
 where s.id = 1 and t.tier = 'moveazy_inventory';


-- ── Partners ─────────────────────────────────────────────────────────────────
create table if not exists public.broker_partners (
  user_id          uuid primary key references auth.users (id) on delete cascade,
  name             text not null default '',
  phone            text not null default '',
  email            text not null default '',
  agency           text not null default '',
  status           text not null default 'pending'
                     check (status in ('pending', 'approved', 'suspended')),
  approved_at      timestamptz,
  approved_by      text not null default '',
  joined_via_group uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists broker_partners_status_idx on public.broker_partners (status, created_at desc);
-- Share of the brokerage this broker keeps on MovEazy clients; null = the
-- program default (program_settings.client_share).
alter table public.broker_partners add column if not exists client_share_pct numeric;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'broker_partners_client_share_range') then
    alter table public.broker_partners
      add constraint broker_partners_client_share_range check (client_share_pct between 0 and 100);
  end if;
end $$;

create table if not exists public.partner_entitlements (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete cascade,
  tier        text not null references public.partner_tiers (tier),
  plan        text not null default 'monthly',
  starts_at   timestamptz not null default now(),
  ends_at     timestamptz not null,
  -- 'manual' until the payment gateway lands; then 'razorpay' with its id.
  source      text not null default 'manual',
  source_ref  text not null default '',
  granted_by  text not null default '',
  created_at  timestamptz not null default now(),
  check (ends_at > starts_at)
);
create index if not exists partner_entitlements_user_idx on public.partner_entitlements (user_id, tier, ends_at desc);


-- ── Groups (associations) ────────────────────────────────────────────────────
create table if not exists public.partner_groups (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) between 2 and 80),
  description text not null default '',
  city        text not null default 'Bengaluru',
  created_by  uuid references auth.users (id) on delete set null,
  created_at  timestamptz not null default now()
);

create table if not exists public.partner_group_members (
  group_id  uuid not null references public.partner_groups (id) on delete cascade,
  user_id   uuid not null references auth.users (id) on delete cascade,
  role      text not null default 'member' check (role in ('owner', 'admin', 'member')),
  added_by  uuid references auth.users (id) on delete set null,
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
create index if not exists partner_group_members_user_idx on public.partner_group_members (user_id);

-- An invite is a bearer token: whoever opens the link may join. Hence short
-- lived and, by default, single use. max_uses exists so a reusable link for a
-- whole WhatsApp group is a number, not a migration.
create table if not exists public.partner_group_invites (
  token       text primary key default replace(gen_random_uuid()::text, '-', ''),
  group_id    uuid not null references public.partner_groups (id) on delete cascade,
  created_by  uuid references auth.users (id) on delete set null,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '7 days',
  max_uses    int not null default 1 check (max_uses between 1 and 500),
  use_count   int not null default 0,
  last_used_by uuid references auth.users (id) on delete set null,
  last_used_at timestamptz
);
create index if not exists partner_group_invites_group_idx on public.partner_group_invites (group_id, created_at desc);


-- ── Partner listings and how they are shared ─────────────────────────────────
create table if not exists public.partner_listings (
  property_id text primary key references public.inventory (property_id) on delete cascade,
  broker_id   uuid not null references auth.users (id) on delete cascade,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists partner_listings_broker_idx on public.partner_listings (broker_id, created_at desc);

-- "All MovEazy brokers", with the brokerage share offered to them.
create table if not exists public.partner_platform_shares (
  property_id text primary key references public.partner_listings (property_id) on delete cascade,
  share_pct   numeric not null check (share_pct between 0 and 100),
  updated_at  timestamptz not null default now()
);

-- One row per group, each with its own percentage (PRD: store per group, not globally).
create table if not exists public.partner_group_shares (
  property_id text not null references public.partner_listings (property_id) on delete cascade,
  group_id    uuid not null references public.partner_groups (id) on delete cascade,
  share_pct   numeric not null check (share_pct between 0 and 100),
  created_at  timestamptz not null default now(),
  primary key (property_id, group_id)
);
create index if not exists partner_group_shares_group_idx on public.partner_group_shares (group_id);

-- Owner / current tenant of a partner listing. Seen by the listing broker and
-- CRM staff only — never by the other brokers the flat is shared with.
create table if not exists public.partner_property_contacts (
  property_id  text not null references public.inventory (property_id) on delete cascade,
  role         text not null check (role in ('owner', 'tenant')),
  name         text not null default '',
  phone        text not null default '',
  availability text not null default '',
  verified     boolean not null default false,
  updated_at   timestamptz not null default now(),
  primary key (property_id, role)
);


-- ── MovEazy inventory, as the CRM offers it to partners ─────────────────────
-- partner_share_pct is what a non-premium partner would earn; kept for future
-- plans (premium partners earn 100%). Neither column is granted to anon or to
-- authenticated: partners read them only through partner_inventory(), staff
-- through inventory_full().
alter table public.inventory add column if not exists partner_visible boolean not null default true;
alter table public.inventory add column if not exists partner_share_pct numeric not null default 50;
-- Apartment / Villa / Independent House / Builder Floor. Public, like flat_type.
alter table public.inventory add column if not exists property_type text not null default '';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'inventory_partner_share_pct_range') then
    alter table public.inventory
      add constraint inventory_partner_share_pct_range check (partner_share_pct between 0 and 100);
  end if;
end $$;

-- property_type reads like every other public column: granted to both roles
-- together, or a signed-out select naming it would fail the whole map.
grant select (property_type) on public.inventory to anon, authenticated;


-- ── Leads and saved properties (private to the broker) ──────────────────────
create table if not exists public.partner_leads (
  id                uuid primary key default gen_random_uuid(),
  broker_id         uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name              text not null check (length(trim(name)) > 0),
  phone             text not null default '',
  status            text not null default 'active' check (status in ('active', 'closed')),
  flat_types        text[] not null default '{}',
  budget_min        numeric,
  budget_max        numeric,
  localities        text[] not null default '{}',
  furnishing        text not null default '',
  notes             text not null default '',
  last_contacted_at timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index if not exists partner_leads_broker_idx on public.partner_leads (broker_id, status, updated_at desc);

create table if not exists public.partner_saved (
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  property_id text not null references public.inventory (property_id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, property_id)
);


-- ── Helpers ──────────────────────────────────────────────────────────────────

-- Two helpers owned by other files. Created here only when missing, so this
-- file does not depend on the order those were run in — and never overwrites
-- a definition that is already there.
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

/** The caller is an approved partner. Suspended and pending partners are not. */
create or replace function public.is_approved_partner()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and exists (
    select 1 from public.broker_partners p
     where p.user_id = auth.uid() and p.status = 'approved'
  );
$$;

/** Does the caller hold `tier`? Free tiers and CRM staff always do. */
create or replace function public.partner_has_tier(p_tier text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    public.is_crm_staff()
    or exists (select 1 from public.partner_tiers t where t.tier = p_tier and t.is_free)
    or exists (
      select 1 from public.partner_entitlements e
       where e.user_id = auth.uid() and e.tier = p_tier
         and now() >= e.starts_at and now() < e.ends_at
    );
$$;

create or replace function public.is_partner_group_member(p_group uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and exists (
    select 1 from public.partner_group_members m
     where m.group_id = p_group and m.user_id = auth.uid()
  );
$$;


-- ── The one read: what this caller may see ───────────────────────────────────
drop function if exists public.partner_inventory();
create function public.partner_inventory()
returns table (
  property_id     text,
  source          text,       -- mine | moveazy | broker
  on_platform     boolean,    -- shared with all MovEazy brokers
  group_ids       uuid[],     -- groups it is shared with that the caller can see
  brokerage_pct   numeric,    -- what the CALLER earns on it (null: not offered)
  locked          boolean,
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
  amenities       text[],
  description     text,
  images          text[],
  cover_image_url text,
  is_verified     boolean,
  lister_id       uuid,
  lister_name     text,
  lister_agency   text,
  lister_phone    text,
  created_at      timestamptz,
  updated_at      timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  with me as (
    select auth.uid() as uid,
           public.is_crm_staff() as staff,
           public.is_approved_partner() as partner,
           public.partner_has_tier('moveazy_inventory') as premium,
           (select ps.property_share from public.program_settings ps where ps.id = 1) as property_share
  ),
  my_groups as (
    select m.group_id from public.partner_group_members m, me where m.user_id = me.uid
  ),
  src as (
    select
      i.*,
      pl.broker_id as pl_broker,
      (pl.property_id is not null) as is_partner_listing,
      ps.share_pct as platform_pct,
      (
        select coalesce(array_agg(gs.group_id order by gs.group_id), '{}')
          from public.partner_group_shares gs, me
         where gs.property_id = i.property_id
           and (me.staff or gs.group_id in (select group_id from my_groups)
                or pl.broker_id = me.uid)
      ) as visible_groups,
      (
        select max(gs.share_pct)
          from public.partner_group_shares gs
         where gs.property_id = i.property_id
           and gs.group_id in (select group_id from my_groups)
      ) as best_group_pct
    from public.inventory i
    left join public.partner_listings pl on pl.property_id = i.property_id
    left join public.partner_platform_shares ps on ps.property_id = i.property_id
  )
  select
    r.property_id,
    case when not r.is_partner_listing then 'moveazy'
         when r.pl_broker = me.uid then 'mine'
         else 'broker' end,
    r.platform_pct is not null,
    r.visible_groups,
    case when not r.is_partner_listing then me.property_share
         when r.pl_broker = me.uid then greatest(r.platform_pct, (select max(gs.share_pct) from public.partner_group_shares gs where gs.property_id = r.property_id))
         else greatest(r.platform_pct, r.best_group_pct) end,
    (not r.is_partner_listing and not me.premium),
    r.status,
    r.title, r.city, r.area, r.nearby_areas,
    case when not r.is_partner_listing and not me.premium then '' else r.full_address end,
    r.landmark,
    case when not r.is_partner_listing and not me.premium then null else r.latitude end,
    case when not r.is_partner_listing and not me.premium then null else r.longitude end,
    r.rent, r.deposit, r.available_from, r.property_type, r.flat_type, r.bedrooms, r.bathrooms,
    r.furnishing, r.amenities, r.description, r.images, r.cover_image_url, r.is_verified,
    case when r.is_partner_listing then r.pl_broker end,
    case when r.is_partner_listing then coalesce(nullif(bp.name, ''), r.poster_name) end,
    case when r.is_partner_listing then bp.agency end,
    case when r.is_partner_listing then coalesce(nullif(bp.phone, ''), r.phone) end,
    r.created_at, r.updated_at
  from src r
  cross join me
  left join public.broker_partners bp on bp.user_id = r.pl_broker
  where (me.partner or me.staff)
    and (
      -- MovEazy's own inventory, unless the CRM held it back.
      (not r.is_partner_listing and r.status = 'published' and (r.partner_visible or me.staff))
      -- Your own, in any state.
      or (r.is_partner_listing and r.pl_broker = me.uid)
      -- Someone else's, shared with everyone or with a group you are in now —
      -- for partners on a plan.
      or (r.is_partner_listing and r.status = 'published' and me.premium
          and (r.platform_pct is not null or r.best_group_pct is not null))
      -- Staff see every partner listing, group-only and paused ones included.
      or (r.is_partner_listing and me.staff)
    );
$$;

comment on function public.partner_inventory() is
  'Every listing the calling partner may see, with the source, their brokerage share and whether it is locked. The only read path for partner inventory.';


-- ── Contacts for one listing ────────────────────────────────────────────────
drop function if exists public.partner_property_contacts_for(text);
create function public.partner_property_contacts_for(p_property text)
returns table (role text, name text, phone text, label text, availability text, verified boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v record;
  staff boolean := public.is_crm_staff();
begin
  select * into v from public.partner_inventory() pi where pi.property_id = p_property;
  -- Not visible, or visible but locked: no contacts at all.
  if not found or v.locked then
    return;
  end if;

  -- A flat its owner manages in the owner app (owner_schema.sql): brokers
  -- reach MovEazy, never the owner. Nested ifs, not one condition: Postgres
  -- does not promise to evaluate to_regclass first, and planning the exists
  -- against a table that is not there would fail.
  if v.source = 'moveazy' and to_regclass('public.owner_property_links') is not null then
    if exists (select 1 from public.owner_property_links ol where ol.property_id = p_property) then
      -- The team number in config/contactChannels.js (MOVEAZY_TEAM_WHATSAPP).
      return query select 'owner'::text, 'MovEazy team'::text, '9146969162'::text,
                          'Owner-managed via MovEazy'::text, ''::text, true;
      return;
    end if;
  end if;

  if v.source = 'moveazy' and to_regclass('public.inventory_private') is null then
    -- No CRM internal details on this database: the poster is the contact.
    return query
      select 'owner'::text, coalesce(i.poster_name, ''), coalesce(i.phone, ''),
             case i.posted_by when 'broker' then 'Listing broker' when 'tenant' then 'Current tenant' else 'Owner' end,
             ''::text, coalesce(i.is_verified, false)
        from public.inventory i
       where i.property_id = p_property;
    return;
  end if;

  if v.source = 'moveazy' then
    -- Premium (or staff): the person MovEazy deals with on this flat.
    return query
      select 'owner'::text,
             coalesce(nullif(ip.poc_name, ''), i.poster_name, ''),
             coalesce(nullif(ip.poc_phone, ''), i.phone, ''),
             case coalesce(ip.source, i.posted_by)
               when 'broker' then 'Listing broker'
               when 'tenant' then 'Current tenant'
               else 'Owner' end,
             ''::text,
             coalesce(i.is_verified, false)
        from public.inventory i
        left join public.inventory_private ip on ip.property_id = i.property_id
       where i.property_id = p_property;
    return;
  end if;

  -- A partner listing: the listing broker is visible to everyone it is shared with.
  return query
    select 'broker'::text, coalesce(v.lister_name, ''), coalesce(v.lister_phone, ''),
           coalesce(nullif(v.lister_agency, ''), 'Individual broker'), ''::text, false;

  -- Owner / tenant only for the listing broker and staff.
  if v.source = 'mine' or staff then
    return query
      select c.role, c.name, c.phone,
             case c.role when 'owner' then 'Owner' else 'Current tenant' end,
             c.availability, c.verified
        from public.partner_property_contacts c
       where c.property_id = p_property
       order by c.role;
  end if;
end;
$$;


-- ── Who am I ────────────────────────────────────────────────────────────────
create or replace function public.partner_me()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'partner', (select to_jsonb(p) from public.broker_partners p where p.user_id = auth.uid()),
    'staff', public.is_crm_staff(),
    'can_manage', public.has_admin_scope('partners.manage'),
    'property_share', (select s.property_share from public.program_settings s where s.id = 1),
    'client_share', coalesce((select p.client_share_pct from public.broker_partners p where p.user_id = auth.uid()),
                             (select s.client_share from public.program_settings s where s.id = 1)),
    'tiers', coalesce((
      select jsonb_object_agg(t.tier, jsonb_build_object(
        'label', t.label, 'is_free', t.is_free, 'price_monthly', t.price_monthly,
        'trial_price', t.trial_price, 'description', t.description,
        'active', public.partner_has_tier(t.tier),
        'ends_at', (select max(e.ends_at) from public.partner_entitlements e
                     where e.user_id = auth.uid() and e.tier = t.tier and now() < e.ends_at)))
        from public.partner_tiers t), '{}'::jsonb)
  );
$$;


-- ── Sign-up ─────────────────────────────────────────────────────────────────
-- The number comes from user_profiles (the phone modal saved it), not from the
-- caller's arguments: the client is not trusted with it.
create or replace function public.partner_register(p_name text default null, p_agency text default null)
returns public.broker_partners
language plpgsql
security definer
set search_path = public
as $$
declare
  uid   uuid := auth.uid();
  prof  public.user_profiles;
  phone text;
  auto  boolean;
  rec   public.broker_partners;
begin
  if uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;

  select * into prof from public.user_profiles where id = uid;
  phone := public.normalize_mobile(coalesce(prof.phone, ''));
  if phone = '' then
    raise exception 'Add your mobile number first.' using errcode = '22023';
  end if;

  select s.auto_approve into auto from public.partner_program_settings s where s.id = 1;

  insert into public.broker_partners as bp (user_id, name, phone, email, agency, status, approved_at, approved_by)
  values (
    uid,
    left(coalesce(nullif(trim(p_name), ''), prof.name, split_part(coalesce(auth.jwt() ->> 'email', ''), '@', 1)), 120),
    phone,
    lower(coalesce(auth.jwt() ->> 'email', '')),
    left(coalesce(trim(p_agency), ''), 120),
    case when coalesce(auto, true) then 'approved' else 'pending' end,
    case when coalesce(auto, true) then now() end,
    case when coalesce(auto, true) then 'auto' else '' end
  )
  -- Re-registering refreshes the profile but never changes a decision:
  -- a suspended partner stays suspended.
  on conflict (user_id) do update
     set name = coalesce(nullif(left(trim(p_name), 120), ''), bp.name),
         agency = coalesce(nullif(left(trim(p_agency), 120), ''), bp.agency),
         phone = excluded.phone,
         updated_at = now()
  returning * into rec;
  return rec;
end;
$$;


-- ── Groups ──────────────────────────────────────────────────────────────────
drop function if exists public.partner_my_groups();
create function public.partner_my_groups()
returns table (id uuid, name text, description text, city text, my_role text,
               member_count int, property_count int, created_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select g.id, g.name, g.description, g.city,
         m.role,
         (select count(*)::int from public.partner_group_members x where x.group_id = g.id),
         (select count(*)::int from public.partner_group_shares s
            join public.inventory i on i.property_id = s.property_id
           where s.group_id = g.id and i.status = 'published'),
         g.created_at
    from public.partner_groups g
    left join public.partner_group_members m on m.group_id = g.id and m.user_id = auth.uid()
   where m.user_id is not null or public.is_crm_staff()
   order by g.name;
$$;

create or replace function public.partner_create_group(p_name text, p_description text default '')
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare gid uuid;
begin
  if not public.is_approved_partner() then
    raise exception 'Only approved partners can create a group.' using errcode = '42501';
  end if;
  insert into public.partner_groups (name, description, created_by)
  values (trim(p_name), left(coalesce(trim(p_description), ''), 400), auth.uid())
  returning id into gid;
  insert into public.partner_group_members (group_id, user_id, role, added_by)
  values (gid, auth.uid(), 'owner', auth.uid());
  return gid;
end;
$$;

drop function if exists public.partner_group_members_list(uuid);
create function public.partner_group_members_list(p_group uuid)
returns table (user_id uuid, name text, phone text, agency text, role text, joined_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select m.user_id, coalesce(p.name, ''), coalesce(p.phone, ''), coalesce(p.agency, ''), m.role, m.joined_at
    from public.partner_group_members m
    left join public.broker_partners p on p.user_id = m.user_id
   where m.group_id = p_group
     and (public.is_partner_group_member(p_group) or public.is_crm_staff())
   order by case m.role when 'owner' then 0 when 'admin' then 1 else 2 end, m.joined_at;
$$;

/** Any member may invite (the association grows by word of mouth). */
create or replace function public.partner_create_invite(p_group uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare tok text;
begin
  if not (public.is_approved_partner() and public.is_partner_group_member(p_group)) then
    raise exception 'Only members of this group can invite.' using errcode = '42501';
  end if;
  insert into public.partner_group_invites (group_id, created_by)
  values (p_group, auth.uid())
  returning token into tok;
  return tok;
end;
$$;

/**
 * What the join page shows before sign-in. Callable signed out: holding the
 * token is what entitles you to the group's name and who invited you.
 */
create or replace function public.partner_invite_preview(p_token text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'group_name', g.name,
    'group_id', g.id,
    'invited_by', coalesce(nullif(p.name, ''), 'A MovEazy partner'),
    'member_count', (select count(*) from public.partner_group_members m where m.group_id = g.id),
    'valid', (inv.expires_at > now() and inv.use_count < inv.max_uses),
    'expires_at', inv.expires_at
  )
  from public.partner_group_invites inv
  join public.partner_groups g on g.id = inv.group_id
  left join public.broker_partners p on p.user_id = inv.created_by
  where inv.token = p_token;
$$;

/** Join through an invite. The caller must have registered as a partner first. */
create or replace function public.partner_accept_invite(p_token text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  inv public.partner_group_invites;
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if not exists (select 1 from public.broker_partners where user_id = uid and status <> 'suspended') then
    raise exception 'Finish signing up first.' using errcode = '42501';
  end if;

  select * into inv from public.partner_group_invites where token = p_token for update;
  if not found then raise exception 'This invite link is not valid.' using errcode = '22023'; end if;

  -- Already in: opening the link twice must not burn someone else's use.
  if exists (select 1 from public.partner_group_members where group_id = inv.group_id and user_id = uid) then
    return inv.group_id;
  end if;

  if inv.expires_at <= now() or inv.use_count >= inv.max_uses then
    raise exception 'This invite link has expired. Ask for a new one.' using errcode = '22023';
  end if;

  insert into public.partner_group_members (group_id, user_id, role, added_by)
  values (inv.group_id, uid, 'member', inv.created_by);
  update public.partner_group_invites
     set use_count = use_count + 1, last_used_by = uid, last_used_at = now()
   where token = p_token;
  update public.broker_partners
     set joined_via_group = coalesce(joined_via_group, inv.group_id), updated_at = now()
   where user_id = uid;
  return inv.group_id;
end;
$$;

/** Owners and admins remove anyone but the owner; anyone may leave. */
create or replace function public.partner_remove_member(p_group uuid, p_user uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  my_role text;
  their_role text;
begin
  select role into my_role from public.partner_group_members where group_id = p_group and user_id = auth.uid();
  select role into their_role from public.partner_group_members where group_id = p_group and user_id = p_user;
  if their_role is null then return; end if;
  if their_role = 'owner' then
    raise exception 'The group owner cannot be removed.' using errcode = '42501';
  end if;
  if not (p_user = auth.uid() or my_role in ('owner', 'admin') or public.has_admin_scope('partners.manage')) then
    raise exception 'Only group admins can remove members.' using errcode = '42501';
  end if;
  delete from public.partner_group_members where group_id = p_group and user_id = p_user;
end;
$$;

create or replace function public.partner_set_member_role(p_group uuid, p_user uuid, p_role text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_role not in ('admin', 'member') then
    raise exception 'Role must be admin or member.' using errcode = '22023';
  end if;
  if not (exists (select 1 from public.partner_group_members
                   where group_id = p_group and user_id = auth.uid() and role = 'owner')
          or public.has_admin_scope('partners.manage')) then
    raise exception 'Only the group owner can change roles.' using errcode = '42501';
  end if;
  update public.partner_group_members set role = p_role
   where group_id = p_group and user_id = p_user and role <> 'owner';
end;
$$;


-- ── Publishing and sharing a listing ────────────────────────────────────────
/**
 * Claim a freshly inserted inventory row as a partner listing and set who it is
 * shared with. p_platform_pct null = not shared with all brokers. p_groups is
 * [{"group_id": "...", "pct": 50}]. Replaces the previous sharing entirely, so
 * the Share screen can simply send what it shows.
 */
create or replace function public.partner_set_sharing(p_property text, p_platform_pct numeric, p_groups jsonb default '[]')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_owner uuid;
  g jsonb;
  gid uuid;
  pct numeric;
begin
  if not public.is_approved_partner() then
    raise exception 'Only approved partners can share listings.' using errcode = '42501';
  end if;

  select i.poster_id into v_owner from public.inventory i where i.property_id = p_property;
  if v_owner is null or v_owner <> uid then
    raise exception 'You can only share your own listings.' using errcode = '42501';
  end if;
  if p_platform_pct is not null and (p_platform_pct < 0 or p_platform_pct > 100) then
    raise exception 'Brokerage share must be between 0 and 100.' using errcode = '22023';
  end if;

  insert into public.partner_listings (property_id, broker_id) values (p_property, uid)
  on conflict (property_id) do update set updated_at = now();

  delete from public.partner_platform_shares where property_id = p_property;
  if p_platform_pct is not null then
    insert into public.partner_platform_shares (property_id, share_pct) values (p_property, p_platform_pct);
  end if;

  delete from public.partner_group_shares where property_id = p_property;
  for g in select * from jsonb_array_elements(coalesce(p_groups, '[]'::jsonb)) loop
    gid := (g ->> 'group_id')::uuid;
    pct := coalesce((g ->> 'pct')::numeric, 0);
    if pct < 0 or pct > 100 then
      raise exception 'Brokerage share must be between 0 and 100.' using errcode = '22023';
    end if;
    -- Sharing into a group you are not in would leak the listing to strangers.
    if not public.is_partner_group_member(gid) then
      raise exception 'You are not a member of one of those groups.' using errcode = '42501';
    end if;
    insert into public.partner_group_shares (property_id, group_id, share_pct) values (p_property, gid, pct);
  end loop;
end;
$$;


/** The lister's own sharing settings, per group, for the edit screen. */
create or replace function public.partner_listing_sharing(p_property text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select case when public.is_inventory_poster(p_property) or public.is_crm_staff() then
    jsonb_build_object(
      'platform_pct', (select s.share_pct from public.partner_platform_shares s where s.property_id = p_property),
      'groups', coalesce((select jsonb_agg(jsonb_build_object('group_id', g.group_id, 'pct', g.share_pct))
                            from public.partner_group_shares g where g.property_id = p_property), '[]'::jsonb)
    )
  end;
$$;


-- ── Staff: the CRM's MovEazy partners section ───────────────────────────────
drop function if exists public.partner_admin_list();
create function public.partner_admin_list()
returns table (user_id uuid, name text, phone text, email text, agency text, status text,
               created_at timestamptz, approved_at timestamptz, approved_by text,
               listing_count int, group_count int, premium_until timestamptz, client_share_pct numeric)
language sql
stable
security definer
set search_path = public
as $$
  select p.user_id, p.name, p.phone, p.email, p.agency, p.status, p.created_at, p.approved_at, p.approved_by,
         (select count(*)::int from public.partner_listings l where l.broker_id = p.user_id),
         (select count(*)::int from public.partner_group_members m where m.user_id = p.user_id),
         (select max(e.ends_at) from public.partner_entitlements e
           where e.user_id = p.user_id and e.tier = 'moveazy_inventory' and now() < e.ends_at),
         p.client_share_pct
    from public.broker_partners p
   where public.is_crm_staff()
   order by case p.status when 'pending' then 0 when 'approved' then 1 else 2 end, p.created_at desc;
$$;

create or replace function public.partner_admin_set_status(p_user uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.has_admin_scope('partners.manage') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  if p_status not in ('pending', 'approved', 'suspended') then
    raise exception 'Unknown status.' using errcode = '22023';
  end if;
  update public.broker_partners
     set status = p_status,
         approved_at = case when p_status = 'approved' then now() else approved_at end,
         approved_by = case when p_status = 'approved' then lower(coalesce(auth.jwt() ->> 'email', '')) else approved_by end,
         updated_at = now()
   where user_id = p_user;
end;
$$;

create or replace function public.partner_admin_set_auto_approve(p_on boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.has_admin_scope('partners.manage') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  update public.partner_program_settings
     set auto_approve = p_on, updated_at = now(), updated_by = lower(coalesce(auth.jwt() ->> 'email', ''))
   where id = 1;
end;
$$;

/** One broker's share on MovEazy clients; null goes back to the program default. */
create or replace function public.partner_admin_set_client_share(p_user uuid, p_pct numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.has_admin_scope('partners.manage') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  if p_pct is not null and (p_pct < 0 or p_pct > 100) then
    raise exception 'Brokerage share must be between 0 and 100.' using errcode = '22023';
  end if;
  update public.broker_partners set client_share_pct = p_pct, updated_at = now() where user_id = p_user;
end;
$$;

/** Manual premium until the gateway lands: grant N months, or revoke (p_months = 0). */
create or replace function public.partner_admin_grant_tier(p_user uuid, p_tier text, p_months int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare from_ts timestamptz;
begin
  if not public.has_admin_scope('partners.manage') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  if p_months <= 0 then
    delete from public.partner_entitlements
     where user_id = p_user and tier = p_tier and starts_at > now();
    update public.partner_entitlements set ends_at = now()
     where user_id = p_user and tier = p_tier and ends_at > now();
    return;
  end if;
  -- Extending stacks on whatever is still running rather than overlapping it.
  select greatest(now(), coalesce(max(ends_at), now())) into from_ts
    from public.partner_entitlements where user_id = p_user and tier = p_tier;
  insert into public.partner_entitlements (user_id, tier, plan, starts_at, ends_at, source, granted_by)
  values (p_user, p_tier, 'monthly', from_ts, from_ts + make_interval(months => least(p_months, 24)),
          'manual', lower(coalesce(auth.jwt() ->> 'email', '')));
end;
$$;


-- ── Row access ──────────────────────────────────────────────────────────────
alter table public.partner_program_settings  enable row level security;
alter table public.partner_tiers             enable row level security;
alter table public.broker_partners           enable row level security;
alter table public.partner_entitlements      enable row level security;
alter table public.partner_groups            enable row level security;
alter table public.partner_group_members     enable row level security;
alter table public.partner_group_invites     enable row level security;
alter table public.partner_listings          enable row level security;
alter table public.partner_platform_shares   enable row level security;
alter table public.partner_group_shares      enable row level security;
alter table public.partner_property_contacts enable row level security;
alter table public.partner_leads             enable row level security;
alter table public.partner_saved             enable row level security;

-- Staff read everything here: the CRM shows who added a flat and how they shared it.
do $$
declare t text;
begin
  foreach t in array array[
    'partner_program_settings', 'partner_tiers', 'broker_partners', 'partner_entitlements',
    'partner_groups', 'partner_group_members', 'partner_listings',
    'partner_platform_shares', 'partner_group_shares', 'partner_property_contacts'
  ] loop
    execute format('drop policy if exists "staff read" on public.%I', t);
    execute format('create policy "staff read" on public.%I for select to authenticated using (public.is_crm_staff())', t);
  end loop;
end $$;

drop policy if exists "partner reads own row" on public.broker_partners;
create policy "partner reads own row" on public.broker_partners
  for select to authenticated using (user_id = auth.uid());

drop policy if exists "anyone reads tiers" on public.partner_tiers;
create policy "anyone reads tiers" on public.partner_tiers
  for select to authenticated using (true);

-- The listing broker keeps their owner/tenant contacts; nobody else writes them.
drop policy if exists "lister manages contacts" on public.partner_property_contacts;
create policy "lister manages contacts" on public.partner_property_contacts
  for all to authenticated
  using (public.is_inventory_poster(property_id))
  with check (public.is_inventory_poster(property_id) and public.is_approved_partner());

drop policy if exists "broker owns leads" on public.partner_leads;
create policy "broker owns leads" on public.partner_leads
  for all to authenticated
  using (broker_id = auth.uid() or public.is_super_admin())
  with check (broker_id = auth.uid() and public.is_approved_partner());

drop policy if exists "user owns saved" on public.partner_saved;
create policy "user owns saved" on public.partner_saved
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());


-- ── Grants ──────────────────────────────────────────────────────────────────
-- Supabase's default privileges hand anon everything in public. Take it back
-- for every table here; authenticated gets only what its policies above use.
revoke all on public.partner_program_settings, public.partner_tiers, public.broker_partners,
              public.partner_entitlements, public.partner_groups, public.partner_group_members,
              public.partner_group_invites, public.partner_listings, public.partner_platform_shares,
              public.partner_group_shares, public.partner_property_contacts, public.partner_leads,
              public.partner_saved
  from public, anon, authenticated;

grant select on public.partner_program_settings, public.partner_tiers, public.broker_partners,
                public.partner_entitlements, public.partner_groups, public.partner_group_members,
                public.partner_listings, public.partner_platform_shares, public.partner_group_shares
  to authenticated;
grant select, insert, update, delete on public.partner_property_contacts, public.partner_leads,
                                        public.partner_saved
  to authenticated;
-- partner_group_invites: no direct access at all. Tokens are bearer secrets;
-- they are created and redeemed only through the functions above.

do $$
declare f text;
begin
  foreach f in array array[
    'public.is_approved_partner()',
    'public.partner_has_tier(text)',
    'public.is_partner_group_member(uuid)',
    'public.partner_inventory()',
    'public.partner_property_contacts_for(text)',
    'public.partner_me()',
    'public.partner_register(text, text)',
    'public.partner_my_groups()',
    'public.partner_create_group(text, text)',
    'public.partner_group_members_list(uuid)',
    'public.partner_create_invite(uuid)',
    'public.partner_invite_preview(text)',
    'public.partner_accept_invite(text)',
    'public.partner_remove_member(uuid, uuid)',
    'public.partner_set_member_role(uuid, uuid, text)',
    'public.partner_set_sharing(text, numeric, jsonb)',
    'public.partner_listing_sharing(text)',
    'public.partner_admin_list()',
    'public.partner_admin_set_status(uuid, text)',
    'public.partner_admin_set_auto_approve(boolean)',
    'public.partner_admin_grant_tier(uuid, text, int)',
    'public.partner_admin_set_client_share(uuid, numeric)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- The one signed-out call: the join page, before the invitee has an account.
grant execute on function public.partner_invite_preview(text) to anon;

-- The super admin's roster row gains the new scope (has_admin_scope already
-- answers true for them; this keeps the Team screen honest).
update public.admin_roles
   set scopes = array(select distinct unnest(scopes || array['partners.manage']))
 where lower(email) = 'yatharth200018@gmail.com';

commit;


-- == Verify ==================================================================
-- 1. anon holds nothing on the partner tables (expect zero rows):
--      select table_name, privilege_type from information_schema.role_table_grants
--       where grantee = 'anon'
--         and (table_name like 'partner%' or table_name = 'broker_partners');
-- 2. A partner outside a group sees none of its group-only listings:
--      tests/partner_check.mjs covers this and every other visibility rule.
