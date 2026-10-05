-- ─────────────────────────────────────────────────────────────────────────────
-- Partner app: who to call, and where the flat is (fe/src/pages/partners/
-- PropertyDetail.jsx, fe/src/pages/owners/FindTenant.jsx).
--
-- Run in the Supabase SQL editor AFTER partner_schema.sql, partner_launch.sql
-- and owner_schema.sql. Safe to re-run. It replaces partner_inventory() and
-- partner_property_contacts_for() from partner_schema.sql -- re-run this file
-- after that one.
--
-- Who a Premium partner reaches, by who listed the flat:
--   another broker   the listing broker. The area only: the exact address and
--                    map pin open once that broker approves the partner's
--                    request (partner_location_requests).
--   an owner         (owner app) the owner directly, address and all -- unless
--                    the owner switched brokers' calls off for that flat; then
--                    MovEazy's visits desk, 8090911024.
--   MovEazy          the flat's POC -- owner, tenant or broker -- with the
--                    address, as before.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

-- ── Owner: may brokers call me about this flat? ──────────────────────────────
alter table public.owner_property_links add column if not exists broker_contact boolean not null default true;

create or replace function public.owner_set_broker_contact(p_property text, p_on boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.owner_has_property(p_property) then
    raise exception 'That flat is not yours.' using errcode = '42501';
  end if;
  update public.owner_property_links set broker_contact = coalesce(p_on, true)
   where property_id = p_property and owner_id = auth.uid();
  return coalesce(p_on, true);
end;
$$;

-- ── A partner asks for another broker's exact location ───────────────────────
create table if not exists public.partner_location_requests (
  id            uuid primary key default gen_random_uuid(),
  property_id   text not null references public.inventory (property_id) on delete cascade,
  requested_by  uuid not null references auth.users (id) on delete cascade,
  lister_id     uuid not null references auth.users (id) on delete cascade,
  status        text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  note          text not null default '',
  created_at    timestamptz not null default now(),
  decided_at    timestamptz,
  decided_by    text not null default ''
);
create unique index if not exists partner_location_one_open
  on public.partner_location_requests (property_id, requested_by) where status in ('pending', 'approved');
create index if not exists partner_location_lister_idx on public.partner_location_requests (lister_id, status, created_at desc);
alter table public.partner_location_requests enable row level security;
revoke all on public.partner_location_requests from public, anon, authenticated;
drop policy if exists "staff read" on public.partner_location_requests;
create policy "staff read" on public.partner_location_requests for select to authenticated using (public.is_crm_staff());
grant select on public.partner_location_requests to authenticated;

-- Two more notification kinds, keeping whatever kinds the table allows already.
do $$
declare
  kinds text[];
begin
  select array_agg(distinct m[1]) into kinds
    from pg_constraint c, regexp_matches(pg_get_constraintdef(c.oid), '''([a-z_]+)''', 'g') m
   where c.conname = 'partner_notifications_kind_check';
  kinds := array(select distinct k from unnest(coalesce(kinds, '{}') || array['location_request', 'location_decided']) k order by 1);
  alter table public.partner_notifications drop constraint if exists partner_notifications_kind_check;
  -- Written as kind in ('a', 'b', ...) so the next run can read the list back.
  execute format('alter table public.partner_notifications add constraint partner_notifications_kind_check check (kind in (%s))',
                 (select string_agg(quote_literal(k), ', ') from unnest(kinds) k));
end $$;

create or replace function public.partner_inventory()
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
  updated_at      timestamptz,
  rent_flag       text
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
      ) as best_group_pct,
      -- The exact place: the lister, staff, or a broker the lister said yes to.
      (pl.broker_id = (select uid from me) or (select staff from me)
       or exists (select 1 from public.partner_location_requests lr
                   where lr.property_id = i.property_id and lr.requested_by = (select uid from me)
                     and lr.status = 'approved')) as place_open
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
    -- MovEazy's own flats: on a plan. Another broker's: only once they have
    -- approved this caller's request -- until then, the area and nothing finer.
    case when (not r.is_partner_listing and not me.premium) or (r.is_partner_listing and not r.place_open) then '' else r.full_address end,
    case when r.is_partner_listing and not r.place_open then '' else r.landmark end,
    case when (not r.is_partner_listing and not me.premium) or (r.is_partner_listing and not r.place_open) then null else r.latitude end,
    case when (not r.is_partner_listing and not me.premium) or (r.is_partner_listing and not r.place_open) then null else r.longitude end,
    r.rent, r.deposit, r.available_from, r.property_type, r.flat_type, r.bedrooms, r.bathrooms,
    r.furnishing, r.amenities, r.description, r.images, r.cover_image_url, r.is_verified,
    case when r.is_partner_listing then r.pl_broker end,
    case when r.is_partner_listing then coalesce(nullif(bp.name, ''), r.poster_name) end,
    case when r.is_partner_listing then bp.agency end,
    case when r.is_partner_listing then coalesce(nullif(bp.phone, ''), r.phone) end,
    r.created_at, r.updated_at, r.rent_flag
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

create or replace function public.partner_property_contacts_for(p_property text)
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
      -- The owner, directly -- unless they switched brokers' calls off in the
      -- owner app, when MovEazy's visits desk takes them and passes the visit
      -- on (VISITS_DESK in fe/src/lib/partnerContact.js).
      return query
        select case when ol.broker_contact and coalesce(oa.phone, '') <> '' then 'owner' else 'moveazy' end,
               case when ol.broker_contact and coalesce(oa.phone, '') <> '' then coalesce(nullif(oa.name, ''), 'Owner') else 'MovEazy visits desk' end,
               case when ol.broker_contact and coalesce(oa.phone, '') <> '' then oa.phone else '8090911024' end,
               case when ol.broker_contact and coalesce(oa.phone, '') <> '' then 'Owner' else 'Owner takes visits through MovEazy' end,
               ''::text, true
          from public.owner_property_links ol
          left join public.owner_accounts oa on oa.user_id = ol.owner_id
         where ol.property_id = p_property;
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

/**
 * Ask the listing broker for a flat's exact location. Premium partners, on a
 * flat shared with them. Asking again while one is open does nothing; after a
 * no, a fresh ask is allowed.
 */
create or replace function public.partner_request_location(p_property text, p_note text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  lister uuid;
  v      record;
  who    text;
  req    public.partner_location_requests;
begin
  if not (public.is_approved_partner() and public.partner_has_tier('moveazy_inventory')) then
    raise exception 'Asking for the location comes with a Premium plan.' using errcode = '42501';
  end if;
  select * into v from public.partner_inventory() pi where pi.property_id = p_property;
  if not found or v.source <> 'broker' then
    raise exception 'You can ask only about a flat another broker shared with you.' using errcode = '42501';
  end if;
  select pl.broker_id into lister from public.partner_listings pl where pl.property_id = p_property;
  select * into req from public.partner_location_requests
   where property_id = p_property and requested_by = auth.uid() and status in ('pending', 'approved');
  if req.id is not null then
    return jsonb_build_object('status', req.status, 'already', true);
  end if;
  insert into public.partner_location_requests (property_id, requested_by, lister_id, note)
  values (p_property, auth.uid(), lister, left(coalesce(p_note, ''), 300))
  returning * into req;
  select coalesce(nullif(b.name, ''), 'A broker') || case when coalesce(b.agency, '') <> '' then ' (' || b.agency || ')' else '' end
    into who from public.broker_partners b where b.user_id = auth.uid();
  insert into public.partner_notifications (broker_id, kind, title, body, link)
  values (lister, 'location_request', coalesce(who, 'A broker') || ' asks for the exact location',
          concat_ws(' · ', nullif(v.flat_type, ''), nullif(v.area, ''), p_property) || '. Approve to share the address and map pin.',
          '/property/' || p_property);
  return jsonb_build_object('status', req.status, 'request', req.id);
end;
$$;

/** The listing broker (or MovEazy staff with partners.manage) says yes or no. */
create or replace function public.partner_decide_location(p_request uuid, p_approve boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  req   public.partner_location_requests;
  actor text := coalesce(nullif(lower(auth.jwt() ->> 'email'), ''), auth.uid()::text);
  inv   public.inventory;
begin
  select * into req from public.partner_location_requests where id = p_request;
  if req.id is null then raise exception 'No such request.' using errcode = 'P0002'; end if;
  if not (auth.uid() = req.lister_id or public.has_admin_scope('partners.manage')) then
    raise exception 'Only the listing broker or MovEazy can decide this.' using errcode = '42501';
  end if;
  if req.status <> 'pending' then
    return jsonb_build_object('status', req.status, 'already', true);
  end if;
  update public.partner_location_requests
     set status = case when p_approve then 'approved' else 'rejected' end, decided_at = now(), decided_by = left(actor, 120)
   where id = req.id
  returning * into req;
  select * into inv from public.inventory where property_id = req.property_id;
  insert into public.partner_notifications (broker_id, kind, title, body, link)
  values (req.requested_by, 'location_decided',
          case when p_approve then 'Location shared' else 'Location not shared' end,
          concat_ws(' · ', nullif(inv.flat_type, ''), nullif(inv.area, ''), req.property_id)
            || case when p_approve then ' — the exact address and map pin are on the listing now.'
                    else ' — the listing broker declined. Call them to talk it through.' end,
          '/property/' || req.property_id);
  return jsonb_build_object('status', req.status);
end;
$$;

/**
 * The caller's location requests: asked of them (on their listings, with who
 * asked) and asked by them (per flat, the latest).
 */
create or replace function public.partner_location_requests_mine()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'incoming', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', r.id, 'property_id', r.property_id, 'status', r.status, 'note', r.note,
               'created_at', r.created_at, 'decided_at', r.decided_at,
               'name', b.name, 'agency', b.agency, 'phone', b.phone)
             order by r.status = 'pending' desc, r.created_at desc)
        from public.partner_location_requests r
        left join public.broker_partners b on b.user_id = r.requested_by
       where r.lister_id = auth.uid()), '[]'::jsonb),
    'outgoing', coalesce((
      select jsonb_agg(jsonb_build_object('property_id', x.property_id, 'status', x.status,
                                          'created_at', x.created_at, 'decided_at', x.decided_at))
        from (select distinct on (r.property_id) r.*
                from public.partner_location_requests r
               where r.requested_by = auth.uid()
               order by r.property_id, r.created_at desc) x), '[]'::jsonb));
$$;

revoke all on function public.partner_inventory() from public, anon;
grant execute on function public.partner_inventory() to authenticated;
revoke all on function public.partner_property_contacts_for(text) from public, anon;
grant execute on function public.partner_property_contacts_for(text) to authenticated;
revoke all on function public.owner_set_broker_contact(text, boolean) from public, anon;
grant execute on function public.owner_set_broker_contact(text, boolean) to authenticated;
revoke all on function public.partner_request_location(text, text) from public, anon;
grant execute on function public.partner_request_location(text, text) to authenticated;
revoke all on function public.partner_decide_location(uuid, boolean) from public, anon;
grant execute on function public.partner_decide_location(uuid, boolean) to authenticated;
revoke all on function public.partner_location_requests_mine() from public, anon;
grant execute on function public.partner_location_requests_mine() to authenticated;

commit;
