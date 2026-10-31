-- ─────────────────────────────────────────────────────────────────────────────
-- Visit ad pages: one page per property and per building for Meta ads
-- (fe: pages/VisitAdPage.jsx at /visit/<property id> and /visit/b/<code>;
-- lib/visitAds.js). Photos, the key details and one button: Schedule a visit.
--
-- Run in the Supabase SQL editor AFTER tenant_views.sql, owner_buildings.sql,
-- visits_schema.sql, partner_website_leads.sql and crm_payments.sql. Safe to
-- re-run.
--
-- The tenant gives a mobile (saved, no OTP), picks a day and an hour, and
-- optionally their name. No account needed. The page never says a flat is
-- rented: every booking is a lead. Slots are the team's for that property in
-- the next 7 days, else every day 10 am – 6 pm, on the hour.
--
-- A booking (one per number per page; booking again moves it) is:
--   - a CRM client (found by number, else new, source 'meta_ad'), a visit on
--     their history with the ad's UTM, the CRM's Visits, a CRM notification;
--   - a flat: a tenant view with "visit pending" (the owner sees it without
--     the number) and, on a partner's flat, that partner's website lead;
--   - a building: a visit request on the building (source 'ad': the owner
--     sees it without the number), and its partner told.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

create table if not exists public.ad_visit_bookings (
  id                   uuid primary key default gen_random_uuid(),
  kind                 text not null check (kind in ('flat', 'building')),
  property_id          text references public.inventory (property_id) on delete cascade,
  building_id          uuid references public.owner_buildings (id) on delete cascade,
  ref                  text not null,                       -- the property id, or the building's id
  client_id            uuid references public.crm_clients (id) on delete set null,
  user_id              uuid references auth.users (id) on delete set null,
  phone                text not null check (phone ~ '^[6-9][0-9]{9}$'),
  name                 text not null default '' check (length(name) <= 80),
  slot_at              timestamptz not null,
  utm                  jsonb not null default '{}'::jsonb,
  visitor              text not null default '',
  status               text not null default 'scheduled' check (status in ('scheduled', 'visited', 'no_show', 'cancelled')),
  building_lead_id     uuid references public.owner_building_leads (id) on delete set null,
  reminder_sent_at     timestamptz,
  reminder_sent_by     text not null default '',
  confirmation_sent_at timestamptz,
  confirmation_sent_by text not null default '',
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (kind, ref, phone),
  check ((kind = 'flat') = (property_id is not null) and (kind = 'building') = (building_id is not null))
);
create index if not exists ad_visit_bookings_slot_idx on public.ad_visit_bookings (slot_at);
alter table public.ad_visit_bookings enable row level security;
revoke all on public.ad_visit_bookings from anon, authenticated;

-- A building visit request that came from an ad: the owner sees it without the number.
alter table public.owner_building_leads add column if not exists source text not null default 'qr';

-- ── Internal ────────────────────────────────────────────────────────────────

/** The team's open slots for a property in the next 7 days, if it has any. */
create or replace function public.visit_ad_team_slots(p_property text)
returns timestamptz[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(s.slot_at order by s.slot_at), '{}')
    from public.property_visit_slots s
   where s.property_id = p_property and s.slot_at > now() and s.slot_at <= now() + interval '7 days'
$$;

/** Is this a slot the page offers? The team's, else 10 am – 5 pm starts on the hour (IST), 1 hour to 8 days out. */
create or replace function public.visit_ad_slot_ok(p_property text, p_slot timestamptz)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_slot is not null and p_slot > now() and p_slot <= now() + interval '8 days'
     and case when p_property is not null and cardinality(public.visit_ad_team_slots(p_property)) > 0
              then p_slot = any(public.visit_ad_team_slots(p_property))
              else extract(hour from p_slot at time zone 'Asia/Kolkata') between 10 and 17
                   and extract(minute from p_slot at time zone 'Asia/Kolkata') = 0
                   and extract(second from p_slot at time zone 'Asia/Kolkata') = 0
                   and p_slot >= now() + interval '1 hour' end
$$;

/** Only these UTM keys, short. */
create or replace function public.visit_ad_utm(p jsonb)
returns jsonb
language sql
immutable
as $$
  select coalesce(jsonb_object_agg(k, left(p ->> k, 120)), '{}'::jsonb)
    from unnest(array['utm_source', 'utm_medium', 'utm_campaign', 'utm_content', 'utm_term', 'fbclid', 'ad_id', 'adset_id', 'campaign_id']) k
   where jsonb_typeof(p) = 'object' and coalesce(p ->> k, '') <> ''
$$;

-- ── The page (anyone) ───────────────────────────────────────────────────────

/**
 * What the ad page shows: { kind, … details, slots: [team slots] | [] }.
 * A flat whatever its status (the page never says rented); a building that's
 * active. Never the exact address or anyone's number. null if there's no such page.
 */
create or replace function public.visit_ad_page(p_kind text, p_ref text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select case when p_kind = 'flat' then (
    select jsonb_build_object(
      'kind', 'flat', 'property_id', i.property_id, 'title', i.title, 'flat_type', i.flat_type, 'area', i.area, 'landmark', i.landmark,
      'rent', i.rent, 'deposit', i.deposit, 'maintenance', i.maintenance, 'furnishing', i.furnishing,
      'bedrooms', i.bedrooms, 'bathrooms', i.bathrooms, 'area_sqft', i.area_sqft, 'amenities', i.amenities,
      'images', i.images, 'cover_image_url', i.cover_image_url, 'description', i.description,
      'building', (select b.name from public.owner_buildings b where b.id = i.building_id),
      'latitude', round(i.latitude, 3), 'longitude', round(i.longitude, 3),
      'slots', to_jsonb(public.visit_ad_team_slots(i.property_id)))
      from public.inventory i where i.property_id = upper(trim(coalesce(p_ref, ''))))
  when p_kind = 'building' then (
    select jsonb_build_object(
      'kind', 'building', 'code', b.code, 'name', b.name, 'area', b.area, 'landmark', b.landmark, 'description', b.description,
      'amenities', b.amenities, 'photos', b.photos, 'total_floors', b.total_floors,
      'latitude', round(b.latitude, 3), 'longitude', round(b.longitude, 3),
      'rent_from', (select min(i.rent) from public.inventory i where i.building_id = b.id and i.rent > 0),
      'rent_to', (select max(i.rent) from public.inventory i where i.building_id = b.id and i.rent > 0),
      'flat_types', (select coalesce(jsonb_agg(distinct i.flat_type), '[]'::jsonb) from public.inventory i
                      where i.building_id = b.id and coalesce(i.flat_type, '') <> ''),
      'flats', (select count(*) from public.inventory i where i.building_id = b.id),
      'slots', '[]'::jsonb)
      from public.owner_buildings b where b.id = public.building_by_code(p_ref)) end
$$;

/**
 * Book (or move) a visit from an ad page: the mobile, an offered slot, a name
 * if they gave one, and the UTM they arrived with.
 * → { id, slot_at, moved, area, landmark, title }
 */
create or replace function public.visit_ad_book(p_kind text, p_ref text, p_visitor text, p_phone text, p_name text,
                                                p_slot timestamptz, p_utm jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid   uuid := auth.uid();
  ph    text := public.normalize_mobile(p_phone);
  nm    text := left(trim(coalesce(p_name, '')), 80);
  vis   text := left(trim(coalesce(p_visitor, '')), 64);
  v_utm jsonb := public.visit_ad_utm(coalesce(p_utm, '{}'::jsonb));
  i     public.inventory;
  b     public.owner_buildings;
  v_ref text;
  cid   uuid;
  bk    public.ad_visit_bookings;
  moved boolean := false;
  vid   uuid;
  lid   uuid;
  when_tx text := to_char(p_slot at time zone 'Asia/Kolkata', 'Dy DD Mon, HH12 AM');
  what  text;
  src   text;
begin
  if p_kind = 'flat' then
    select * into i from public.inventory where property_id = upper(trim(coalesce(p_ref, '')));
    if i.property_id is null then raise exception 'This page isn''t taking visits right now.' using errcode = '22023'; end if;
    v_ref := i.property_id;
    what := i.property_id || coalesce(' (' || nullif(concat_ws(', ', nullif(i.flat_type, ''), nullif(i.area, '')), '') || ')', '');
  elsif p_kind = 'building' then
    select * into b from public.owner_buildings where id = public.building_by_code(p_ref);
    if b.id is null then raise exception 'This page isn''t taking visits right now.' using errcode = '22023'; end if;
    v_ref := b.id::text;
    what := b.name || coalesce(' (' || nullif(b.area, '') || ')', '');
  else
    raise exception 'Unknown page.' using errcode = '22023';
  end if;
  if ph !~ '^[6-9][0-9]{9}$' then raise exception 'Enter a 10-digit mobile number.' using errcode = '22023'; end if;
  if not public.visit_ad_slot_ok(i.property_id, p_slot) then
    raise exception 'That time isn''t available any more. Pick another one.' using errcode = '22023';
  end if;
  -- Twenty bookings an hour from one number or phone is a script, not a renter.
  if (select count(*) from public.ad_visit_bookings
       where (phone = ph or (vis <> '' and visitor = vis)) and updated_at > now() - interval '1 hour') >= 20 then
    raise exception 'Too many bookings. Try again in a while.' using errcode = '54000';
  end if;

  cid := public.tenant_client_for(uid, ph, nm, 'meta_ad');
  if cid is not null and nm <> '' then
    update public.crm_clients set name = nm where id = cid and coalesce(btrim(name), '') = '';
  end if;
  src := coalesce(nullif(concat_ws(' / ', v_utm ->> 'utm_source', v_utm ->> 'utm_campaign', v_utm ->> 'utm_content'), ''), 'no UTM');

  select * into bk from public.ad_visit_bookings where kind = p_kind and ad_visit_bookings.ref = v_ref and phone = ph;
  if bk.id is not null then
    moved := bk.slot_at is distinct from p_slot;
    update public.ad_visit_bookings set
      slot_at = p_slot, name = case when nm <> '' then nm else name end, client_id = coalesce(cid, client_id),
      user_id = coalesce(uid, user_id), utm = case when v_utm <> '{}'::jsonb then v_utm else ad_visit_bookings.utm end,
      visitor = case when vis <> '' then vis else visitor end, status = 'scheduled',
      reminder_sent_at = case when moved then null else reminder_sent_at end,
      confirmation_sent_at = case when moved then null else confirmation_sent_at end,
      updated_at = now()
    where id = bk.id returning * into bk;
  else
    insert into public.ad_visit_bookings (kind, property_id, building_id, ref, client_id, user_id, phone, name, slot_at, utm, visitor)
    values (p_kind, i.property_id, b.id, v_ref, cid, uid, ph, nm, p_slot, v_utm, vis)
    returning * into bk;
  end if;

  if p_kind = 'flat' then
    -- A tenant view, visit pending; on a partner's flat, the partner's lead.
    vid := public.tenant_view_touch(i.property_id, cid, 'ad', now());
    if vid is not null then
      perform public.tenant_view_respond(vid, 'tenant', 'visit', null, '{"visit": "pending"}'::jsonb, now());
    end if;
    if cid is not null then perform public.website_lead(cid, i.property_id, 'visit', 'booked a visit for ' || when_tx); end if;
  else
    -- The building's visit requests (owner: no number; partner told).
    select id into lid from public.owner_building_leads where id = bk.building_lead_id;
    if lid is null then
      insert into public.owner_building_leads (building_id, name, phone, property_ids, visit_at, note, broker_id, visitor, user_id, source)
      values (b.id, coalesce(nullif(nm, ''), (select c.name from public.crm_clients c where c.id = cid), ''), ph, '{}', p_slot,
              'Booked from the ad page', b.broker_id, vis, uid, 'ad')
      returning id into lid;
      update public.ad_visit_bookings set building_lead_id = lid where id = bk.id;
    else
      update public.owner_building_leads set visit_at = p_slot, status = 'new', updated_at = now(), updated_by = 'renter',
        name = case when nm <> '' then nm else name end
       where id = lid;
    end if;
    if b.broker_id is not null and to_regclass('public.partner_notifications') is not null then
      insert into public.partner_notifications (broker_id, kind, title, body, link)
      values (b.broker_id, 'building_visit',
              coalesce(nullif(nm, ''), 'A tenant') || case when moved then ' moved a visit to ' else ' wants to visit ' end || b.name,
              ph || ' · ' || when_tx, '/building-leads');
    end if;
  end if;

  if cid is not null then
    update public.crm_clients set status = 'visit_pending', updated_at = now()
     where id = cid and status not in ('closed_by_us', 'closed_outside', 'visit_pending');
    insert into public.crm_activities (client_id, actor_email, type, body, meta)
    values (cid, '', 'visit',
            case when moved then 'Moved their visit from the ad page · ' else 'Booked a visit from the ad page · ' end
              || what || ' · ' || when_tx || ' · ' || src,
            jsonb_build_object('ad_visit_id', bk.id, 'kind', p_kind, 'ref', v_ref, 'slot_at', p_slot, 'utm', bk.utm));
    insert into public.crm_notifications (for_email, type, title, body, client_id)
    values ('yatharth200018@gmail.com', 'visit',
            case when moved then 'Ad visit moved' else 'Visit booked from an ad' end,
            coalesce(nullif(nm, ''), 'A tenant') || ' · ' || ph || ' · ' || what || ' · ' || when_tx || ' · ' || src, cid);
  end if;

  return jsonb_build_object('id', bk.id, 'slot_at', bk.slot_at, 'moved', moved,
    'title', what, 'area', coalesce(i.area, b.area), 'landmark', coalesce(i.landmark, b.landmark));
end;
$$;

-- ── The CRM ─────────────────────────────────────────────────────────────────

/** Ad visits from `p_days` ago on, with the client, the page and the UTM. */
create or replace function public.crm_ad_visits(p_days int default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', a.id, 'kind', a.kind, 'property_id', a.property_id, 'building_id', a.building_id,
             'building', (select jsonb_build_object('name', b.name, 'code', b.code, 'area', b.area)
                            from public.owner_buildings b where b.id = a.building_id),
             'client_id', a.client_id, 'name', coalesce(nullif(a.name, ''), c.name, ''), 'phone', a.phone,
             'slot_at', a.slot_at, 'status', a.status, 'utm', a.utm, 'created_at', a.created_at,
             'reminder_sent_at', a.reminder_sent_at, 'reminder_sent_by', a.reminder_sent_by,
             'confirmation_sent_at', a.confirmation_sent_at, 'confirmation_sent_by', a.confirmation_sent_by)
           order by a.slot_at)
      from public.ad_visit_bookings a
      left join public.crm_clients c on c.id = a.client_id
     where a.slot_at >= now() - make_interval(days => greatest(coalesce(p_days, 30), 1))), '[]'::jsonb);
end;
$$;

/** Mark (or clear) the reminder / confirmation sent for an ad visit. */
create or replace function public.crm_ad_visit_stamp(p_id uuid, p_what text, p_clear boolean default false)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  me text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if not public.has_admin_scope('crm.clients.write') then
    raise exception 'Needs permission to update clients.' using errcode = '42501';
  end if;
  if p_what = 'reminder' then
    update public.ad_visit_bookings set reminder_sent_at = case when p_clear then null else now() end,
      reminder_sent_by = case when p_clear then '' else me end where id = p_id;
  elsif p_what = 'confirmation' then
    update public.ad_visit_bookings set confirmation_sent_at = case when p_clear then null else now() end,
      confirmation_sent_by = case when p_clear then '' else me end where id = p_id;
  else
    raise exception 'Unknown stamp.' using errcode = '22023';
  end if;
end;
$$;

-- ── Grants ───────────────────────────────────────────────────────────────────
revoke all on function public.visit_ad_team_slots(text) from public, anon, authenticated;
revoke all on function public.visit_ad_slot_ok(text, timestamptz) from public, anon, authenticated;
revoke all on function public.visit_ad_utm(jsonb) from public, anon, authenticated;
revoke all on function public.visit_ad_page(text, text) from public;
revoke all on function public.visit_ad_book(text, text, text, text, text, timestamptz, jsonb) from public;
grant execute on function public.visit_ad_page(text, text) to anon, authenticated;
grant execute on function public.visit_ad_book(text, text, text, text, text, timestamptz, jsonb) to anon, authenticated;
revoke all on function public.crm_ad_visits(int) from public, anon;
revoke all on function public.crm_ad_visit_stamp(uuid, text, boolean) from public, anon;
grant execute on function public.crm_ad_visits(int) to authenticated;
grant execute on function public.crm_ad_visit_stamp(uuid, text, boolean) to authenticated;

commit;
