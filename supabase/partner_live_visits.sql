-- ─────────────────────────────────────────────────────────────────────────────
-- Partner visits: the CRM gives a partner a tenant's visit to a flat, the
-- partner shares where to meet, the tenant says "I am coming", and both see
-- each other live until it's done (MovEazy-FE lib/partnerVisits.js,
-- pages/partners/VisitCard*.jsx, components/LiveVisit*.jsx,
-- pages/crm/CrmPartnerVisits.jsx).
--
-- Run in the Supabase SQL editor AFTER crm_schema.sql, partner_schema.sql,
-- partner_launch.sql (partner_notifications), visits_schema.sql
-- (visit_bookings), tenant_views.sql (tenant_view_touch / tenant_view_respond)
-- and lead_types.sql. Safe to re-run.
--
--   assigned  the CRM picked the partner (a booked visit, or one set up by hand)
--   shared    the partner shared the meeting spot (a Google Maps link or a pin);
--             it's remembered for that partner and flat and offered next time
--   coming    the tenant tapped "I am coming": both phones share where they
--             are (while the page is open) for 3 hours, or until done
--   done      the partner marked the visit done; both say how it went (the
--             tenant-views labels), saved as "partner said" / "tenant said"
--   cancelled the CRM took it back
--
-- The tenant sees their visits once signed in: theirs by account, or by the
-- mobile number on their profile.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

create table if not exists public.partner_visits (
  id             uuid primary key default gen_random_uuid(),
  client_id      uuid not null references public.crm_clients (id) on delete cascade,
  property_id    text not null references public.inventory (property_id) on delete cascade,
  broker_id      uuid not null references auth.users (id) on delete cascade,
  booking_id     uuid references public.visit_bookings (id) on delete set null,
  visit_at       timestamptz,
  status         text not null default 'assigned' check (status in ('assigned', 'shared', 'coming', 'done', 'cancelled')),
  meet_lat       numeric,
  meet_lng       numeric,
  meet_link      text not null default '',
  shared_at      timestamptz,
  coming_at      timestamptz,
  live_until     timestamptz,
  done_at        timestamptz,
  cancelled_at   timestamptz,
  broker_loc     jsonb,           -- { lat, lng, acc, at }
  tenant_loc     jsonb,
  broker_sharing boolean not null default true,
  tenant_sharing boolean not null default true,
  assigned_by    text not null default '',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create unique index if not exists partner_visits_booking_key on public.partner_visits (booking_id) where booking_id is not null and status <> 'cancelled';
create index if not exists partner_visits_broker_idx on public.partner_visits (broker_id, visit_at desc);
create index if not exists partner_visits_client_idx on public.partner_visits (client_id, visit_at desc);

-- Where a partner meets tenants for a flat: offered again on their next visit there.
create table if not exists public.partner_flat_spots (
  broker_id   uuid not null references auth.users (id) on delete cascade,
  property_id text not null references public.inventory (property_id) on delete cascade,
  lat         numeric not null,
  lng         numeric not null,
  link        text not null default '',
  updated_at  timestamptz not null default now(),
  primary key (broker_id, property_id)
);

alter table public.partner_visits enable row level security;
alter table public.partner_flat_spots enable row level security;
revoke all on public.partner_visits, public.partner_flat_spots from anon, authenticated;

-- Partner notifications gain the visit kinds (the kinds already allowed are kept).
do $$
declare
  d    text;
  vals text[];
begin
  select pg_get_constraintdef(oid) into d from pg_constraint where conname = 'partner_notifications_kind_check';
  if d is not null and position('visit_assigned' in d) = 0 then
    vals := array(select m[1] from regexp_matches(d, '([a-z_]{3,})', 'g') m
                   where m[1] not in ('kind', 'any', 'array', 'text', 'check'));
    vals := array(select distinct x from unnest(vals || array['visit_assigned', 'visit_coming', 'visit_update']) x);
    alter table public.partner_notifications drop constraint partner_notifications_kind_check;
    execute format('alter table public.partner_notifications add constraint partner_notifications_kind_check check (kind = any (%L::text[]))', vals);
  end if;
end $$;

/* ── Helpers ──────────────────────────────────────────────────────────────── */

/** Live: the tenant is coming and the 3 hours aren't up. */
create or replace function public.pv_live(v public.partner_visits)
returns boolean
language sql
stable
as $$
  select v.status = 'coming' and coalesce(v.live_until, now()) > now();
$$;

/** The flat as a visit card shows it. */
create or replace function public.pv_flat(p text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('property_id', i.property_id, 'title', coalesce(nullif(i.title, ''), concat_ws(' in ', i.flat_type, i.area)),
                            'flat_type', i.flat_type, 'area', i.area, 'landmark', i.landmark, 'rent', i.rent,
                            'lat', i.latitude, 'lng', i.longitude,
                            'cover', coalesce(nullif(i.cover_image_url, ''), i.images[1]))
    from public.inventory i where i.property_id = p;
$$;

/** The latest answer a side gave on this visit's flat for this tenant. */
create or replace function public.pv_answer(v public.partner_visits, p_by text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('visit', r.visit, 'liked', r.liked, 'liked_status', r.liked_status, 'reasons', to_jsonb(r.reasons), 'at', r.at)
    from public.property_tenant_views t join public.property_view_responses r on r.view_id = t.id
   where t.property_id = v.property_id and t.client_id = v.client_id and r.by_kind = p_by and r.at >= v.created_at
   order by r.at desc limit 1;
$$;

/** One visit, for any side (the caller decides what each side may see). */
create or replace function public.pv_json(v public.partner_visits)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', v.id, 'status', v.status, 'live', public.pv_live(v), 'visit_at', v.visit_at,
    'meet', case when v.meet_lat is not null then jsonb_build_object('lat', v.meet_lat, 'lng', v.meet_lng, 'link', v.meet_link) end,
    'shared_at', v.shared_at, 'coming_at', v.coming_at, 'live_until', v.live_until, 'done_at', v.done_at,
    'flat', public.pv_flat(v.property_id),
    'client', (select jsonb_build_object('id', c.id, 'name', c.name, 'phone', c.phone) from public.crm_clients c where c.id = v.client_id),
    'partner', (select jsonb_build_object('name', coalesce(nullif(b.name, ''), 'Your MovEazy partner'), 'phone', public.normalize_mobile(b.phone))
                  from public.broker_partners b where b.user_id = v.broker_id),
    'broker_loc', case when public.pv_live(v) and v.broker_sharing then v.broker_loc end,
    'tenant_loc', case when public.pv_live(v) and v.tenant_sharing then v.tenant_loc end,
    'broker_sharing', v.broker_sharing, 'tenant_sharing', v.tenant_sharing,
    'partner_answer', public.pv_answer(v, 'partner'), 'tenant_answer', public.pv_answer(v, 'tenant'),
    'reasons', public.tenant_reason_list());
$$;

/** A JSON spot → { lat, lng, acc, at } (rounded; null when not a spot). */
create or replace function public.pv_spot(p_lat numeric, p_lng numeric, p_acc numeric)
returns jsonb
language sql
stable
as $$
  select case when p_lat between -90 and 90 and p_lng between -180 and 180
              then jsonb_build_object('lat', round(p_lat, 6), 'lng', round(p_lng, 6), 'acc', round(coalesce(p_acc, 0)), 'at', now()) end;
$$;

/** The tenant's own visit (by account, or the number on their profile), locked for change. */
create or replace function public.pv_mine_tenant(p_id uuid)
returns public.partner_visits
language plpgsql
security definer
set search_path = public
as $$
declare
  v  public.partner_visits;
  ph text;
begin
  if auth.uid() is null then raise exception 'Sign in to see your visit.' using errcode = '42501'; end if;
  select public.normalize_mobile(p.phone) into ph from public.user_profiles p where p.id = auth.uid();
  select pv.* into v from public.partner_visits pv join public.crm_clients c on c.id = pv.client_id
   where pv.id = p_id and (c.user_id = auth.uid() or (coalesce(ph, '') <> '' and public.normalize_mobile(c.phone) = ph))
   for update of pv;
  if v.id is null then raise exception 'This visit isn''t on your account. Sign in with the number you gave MovEazy.' using errcode = '42501'; end if;
  return v;
end;
$$;

create or replace function public.pv_mine_partner(p_id uuid)
returns public.partner_visits
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.partner_visits;
begin
  select * into v from public.partner_visits where id = p_id and broker_id = auth.uid() for update;
  if v.id is null or not public.is_approved_partner() then raise exception 'That visit isn''t yours.' using errcode = '42501'; end if;
  return v;
end;
$$;

/* ── CRM ──────────────────────────────────────────────────────────────────── */

/**
 * Partner visits from p_from on, every status, plus the booked visits from
 * p_from on that no partner has yet (to assign).
 */
create or replace function public.crm_partner_visits(p_from timestamptz default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  since timestamptz := coalesce(p_from, now() - interval '2 days');
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'visits', coalesce((
      select jsonb_agg(public.pv_json(v) || jsonb_build_object('broker_id', v.broker_id, 'booking_id', v.booking_id,
               'assigned_by', v.assigned_by, 'cancelled_at', v.cancelled_at,
               -- The CRM sees where both are while it's live, sharing or not.
               'broker_loc', case when public.pv_live(v) then v.broker_loc end, 'tenant_loc', case when public.pv_live(v) then v.tenant_loc end)
             order by v.visit_at nulls last, v.created_at)
        from public.partner_visits v where coalesce(v.visit_at, v.created_at) >= since or v.status in ('assigned', 'shared', 'coming')), '[]'::jsonb),
    'unassigned', coalesce((
      select jsonb_agg(jsonb_build_object('booking_id', b.id, 'visit_at', b.slot_at, 'flat', public.pv_flat(b.property_id),
               'client', (select jsonb_build_object('id', c.id, 'name', c.name, 'phone', c.phone) from public.crm_clients c where c.user_id = b.user_id limit 1))
             order by b.slot_at nulls last)
        from public.visit_bookings b
       where coalesce(b.slot_at, b.created_at) >= since and coalesce(b.status, '') not in ('cancelled', 'done', 'completed')
         and not exists (select 1 from public.partner_visits v where v.booking_id = b.id and v.status <> 'cancelled')
         and exists (select 1 from public.crm_clients c where c.user_id = b.user_id)), '[]'::jsonb));
end;
$$;

/**
 * Give a visit to a partner: { id? (change one), booking_id?, client_id,
 * property_id, visit_at, broker_id }. A booked visit brings its own client,
 * flat and time. The partner is told.
 */
create or replace function public.crm_partner_visit_save(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  who  text := lower(coalesce(auth.jwt() ->> 'email', ''));
  vid  uuid := nullif(p ->> 'id', '')::uuid;
  bid  uuid := nullif(p ->> 'booking_id', '')::uuid;
  cid  uuid := nullif(p ->> 'client_id', '')::uuid;
  pid  text := upper(trim(coalesce(p ->> 'property_id', '')));
  brk  uuid := nullif(p ->> 'broker_id', '')::uuid;
  at   timestamptz := nullif(p ->> 'visit_at', '')::timestamptz;
  b    record;
  v    public.partner_visits;
  old  uuid;
  nm   text;
  flat text;
begin
  if not public.has_admin_scope('crm.clients.write') then raise exception 'Needs permission to edit clients.' using errcode = '42501'; end if;
  if bid is not null then
    select vb.*, (select c.id from public.crm_clients c where c.user_id = vb.user_id limit 1) cid into b from public.visit_bookings vb where vb.id = bid;
    if b.id is null then raise exception 'No such booked visit.' using errcode = '22023'; end if;
    cid := coalesce(cid, b.cid); pid := coalesce(nullif(pid, ''), upper(b.property_id)); at := coalesce(at, b.slot_at);
  end if;
  if cid is null or not exists (select 1 from public.crm_clients where id = cid) then raise exception 'Pick the client.' using errcode = '22023'; end if;
  if pid = '' or not exists (select 1 from public.inventory where property_id = pid) then raise exception 'Pick the flat.' using errcode = '22023'; end if;
  if brk is null or not exists (select 1 from public.broker_partners where user_id = brk and status = 'approved') then raise exception 'Pick an approved partner.' using errcode = '22023'; end if;

  if vid is null then
    insert into public.partner_visits (client_id, property_id, broker_id, booking_id, visit_at, assigned_by)
    values (cid, pid, brk, bid, at, who) returning * into v;
  else
    select broker_id into old from public.partner_visits where id = vid;
    update public.partner_visits set client_id = cid, property_id = pid, broker_id = brk, visit_at = at, updated_at = now(),
           -- A new partner starts over: their own spot, their own sharing.
           status = case when broker_id <> brk and status in ('shared', 'coming') then 'assigned' else status end,
           meet_lat = case when broker_id <> brk then null else meet_lat end, meet_lng = case when broker_id <> brk then null else meet_lng end
     where id = vid and status not in ('done', 'cancelled') returning * into v;
    if v.id is null then raise exception 'That visit is already done or cancelled.' using errcode = '22023'; end if;
  end if;

  if old is distinct from brk then
    select c.name into nm from public.crm_clients c where c.id = cid;
    select coalesce(nullif(i.title, ''), concat_ws(' in ', i.flat_type, i.area)) into flat from public.inventory i where i.property_id = pid;
    insert into public.partner_notifications (broker_id, kind, title, body, link)
    values (brk, 'visit_assigned', format('Visit: %s', coalesce(nullif(nm, ''), 'a MovEazy tenant')),
            format('%s%s. Share where to meet them.', flat,
                   case when at is not null then ' · ' || to_char(at at time zone 'Asia/Kolkata', 'Dy DD Mon, HH12:MI AM') else '' end),
            '/visits/' || v.id);
    insert into public.crm_activities (client_id, actor_email, type, body)
    values (cid, who, 'visit', format('Visit to %s given to partner %s', flat, (select coalesce(nullif(name, ''), 'a partner') from public.broker_partners where user_id = brk)));
  end if;
  return public.pv_json(v);
end;
$$;

create or replace function public.crm_partner_visit_cancel(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.partner_visits;
begin
  if not public.has_admin_scope('crm.clients.write') then raise exception 'Needs permission to edit clients.' using errcode = '42501'; end if;
  update public.partner_visits set status = 'cancelled', cancelled_at = now(), updated_at = now()
   where id = p_id and status not in ('done', 'cancelled') returning * into v;
  if v.id is null then raise exception 'That visit is already done or cancelled.' using errcode = '22023'; end if;
  insert into public.partner_notifications (broker_id, kind, title, body, link)
  values (v.broker_id, 'visit_update', 'A visit was cancelled', 'The MovEazy team cancelled a visit they had given you.', '/');
  return public.pv_json(v);
end;
$$;

/* ── Partner ──────────────────────────────────────────────────────────────── */

/** The partner's visits: open ones, and those done in the last day. With the spot they used here before. */
create or replace function public.partner_visits()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_approved_partner() then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(public.pv_json(v) || jsonb_build_object('saved_spot',
             (select jsonb_build_object('lat', s.lat, 'lng', s.lng, 'link', s.link) from public.partner_flat_spots s
               where s.broker_id = v.broker_id and s.property_id = v.property_id))
           order by (v.status = 'done'), v.visit_at nulls last)
      from public.partner_visits v
     where v.broker_id = auth.uid() and (v.status in ('assigned', 'shared', 'coming') or (v.status = 'done' and v.done_at > now() - interval '1 day'))), '[]'::jsonb);
end;
$$;

/** Where to meet: a pin (and the Google Maps link it came from, if any). Remembered for this partner and flat. */
create or replace function public.partner_visit_share(p_id uuid, p_lat numeric, p_lng numeric, p_link text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v    public.partner_visits := public.pv_mine_partner(p_id);
  link text := case when coalesce(p_link, '') ~ '^https://' then left(p_link, 500) else '' end;
begin
  if v.status in ('done', 'cancelled') then raise exception 'This visit is over.' using errcode = '22023'; end if;
  if p_lat is null or p_lng is null or p_lat not between 6 and 37.5 or p_lng not between 68 and 97.5 then
    raise exception 'Mark the spot on the map, or paste a Google Maps link with a pin.' using errcode = '22023';
  end if;
  update public.partner_visits set meet_lat = round(p_lat, 6), meet_lng = round(p_lng, 6), meet_link = link,
         status = case when status = 'assigned' then 'shared' else status end, shared_at = coalesce(shared_at, now()), updated_at = now()
   where id = v.id returning * into v;
  insert into public.partner_flat_spots (broker_id, property_id, lat, lng, link) values (v.broker_id, v.property_id, v.meet_lat, v.meet_lng, link)
  on conflict (broker_id, property_id) do update set lat = excluded.lat, lng = excluded.lng, link = excluded.link, updated_at = now();
  insert into public.crm_activities (client_id, type, body)
  values (v.client_id, 'visit', format('Partner shared the meeting spot for %s', v.property_id));
  return public.pv_json(v);
end;
$$;

/** The partner's phone, while live. */
create or replace function public.partner_visit_ping(p_id uuid, p_lat numeric, p_lng numeric, p_acc numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.partner_visits := public.pv_mine_partner(p_id);
begin
  if public.pv_live(v) and v.broker_sharing then
    update public.partner_visits set broker_loc = public.pv_spot(p_lat, p_lng, p_acc) where id = v.id returning * into v;
  end if;
  return public.pv_json(v);
end;
$$;

create or replace function public.partner_visit_sharing(p_id uuid, p_on boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.partner_visits := public.pv_mine_partner(p_id);
begin
  update public.partner_visits set broker_sharing = coalesce(p_on, false), broker_loc = case when coalesce(p_on, false) then broker_loc end
   where id = v.id returning * into v;
  return public.pv_json(v);
end;
$$;

/** The visit happened: live sharing stops. */
create or replace function public.partner_visit_done(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.partner_visits := public.pv_mine_partner(p_id);
begin
  if v.status = 'cancelled' then raise exception 'This visit was cancelled.' using errcode = '22023'; end if;
  update public.partner_visits set status = 'done', done_at = coalesce(done_at, now()), broker_loc = null, tenant_loc = null, updated_at = now()
   where id = v.id returning * into v;
  insert into public.crm_activities (client_id, type, body) values (v.client_id, 'visit', format('Visit done: %s (partner)', v.property_id));
  return public.pv_json(v);
end;
$$;

/** How it went, from the partner (the tenant-views labels): "partner said". */
create or replace function public.partner_visit_respond(p_id uuid, p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v   public.partner_visits := public.pv_mine_partner(p_id);
  vid uuid;
  who text;
begin
  select coalesce(nullif(name, ''), 'Partner') into who from public.broker_partners where user_id = v.broker_id;
  select id into vid from public.property_tenant_views where property_id = v.property_id and client_id = v.client_id;
  if vid is null then vid := public.tenant_view_touch(v.property_id, v.client_id, 'partner', now()); end if;
  if vid is null then raise exception 'That flat can''t be marked for this tenant.' using errcode = '22023'; end if;
  perform public.tenant_view_respond(vid, 'partner', who, v.broker_id,
    jsonb_build_object('visit', 'done', 'liked', coalesce(p ->> 'liked', ''), 'liked_status', coalesce(p ->> 'liked_status', ''),
                       'reasons', coalesce(p -> 'reasons', '[]'::jsonb)));
  return public.pv_json(v);
end;
$$;

/* ── Tenant ───────────────────────────────────────────────────────────────── */

/** The signed-in tenant's visits with a partner: open ones and those done in the last day. */
create or replace function public.tenant_partner_visits()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  ph text;
begin
  if auth.uid() is null then return '[]'::jsonb; end if;
  select public.normalize_mobile(p.phone) into ph from public.user_profiles p where p.id = auth.uid();
  return coalesce((
    select jsonb_agg(public.pv_json(v) - 'client' order by (v.status = 'done'), v.visit_at nulls last)
      from public.partner_visits v join public.crm_clients c on c.id = v.client_id
     where (c.user_id = auth.uid() or (coalesce(ph, '') <> '' and public.normalize_mobile(c.phone) = ph))
       and (v.status in ('assigned', 'shared', 'coming') or (v.status = 'done' and v.done_at > now() - interval '1 day'))), '[]'::jsonb);
end;
$$;

/** "I am coming": both start sharing where they are, for 3 hours. The partner is told. */
create or replace function public.tenant_visit_coming(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v  public.partner_visits := public.pv_mine_tenant(p_id);
  nm text;
begin
  if v.status = 'assigned' then raise exception 'Your partner hasn''t shared where to meet yet.' using errcode = '22023'; end if;
  if v.status in ('done', 'cancelled') then raise exception 'This visit is over.' using errcode = '22023'; end if;
  update public.partner_visits set status = 'coming', coming_at = now(), live_until = now() + interval '3 hours',
         tenant_sharing = true, broker_sharing = true, updated_at = now()
   where id = v.id returning * into v;
  select c.name into nm from public.crm_clients c where c.id = v.client_id;
  insert into public.partner_notifications (broker_id, kind, title, body, link)
  values (v.broker_id, 'visit_coming', format('%s is on the way', coalesce(nullif(nm, ''), 'Your tenant')),
          'Open the visit to see where they are. Offer them a cold drink when they arrive!', '/visits/' || v.id);
  insert into public.crm_activities (client_id, type, body) values (v.client_id, 'visit', format('Tenant is on the way to %s', v.property_id));
  perform public.crm_lead_activate(v.client_id, 'coming to a visit');
  return public.pv_json(v) - 'client';
end;
$$;

create or replace function public.tenant_visit_ping(p_id uuid, p_lat numeric, p_lng numeric, p_acc numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.partner_visits := public.pv_mine_tenant(p_id);
begin
  if public.pv_live(v) and v.tenant_sharing then
    update public.partner_visits set tenant_loc = public.pv_spot(p_lat, p_lng, p_acc) where id = v.id returning * into v;
  end if;
  return public.pv_json(v) - 'client';
end;
$$;

create or replace function public.tenant_visit_sharing(p_id uuid, p_on boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.partner_visits := public.pv_mine_tenant(p_id);
begin
  update public.partner_visits set tenant_sharing = coalesce(p_on, false), tenant_loc = case when coalesce(p_on, false) then tenant_loc end
   where id = v.id returning * into v;
  return public.pv_json(v) - 'client';
end;
$$;

/** How it went, from the tenant: "tenant said". */
create or replace function public.tenant_visit_respond(p_id uuid, p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v   public.partner_visits := public.pv_mine_tenant(p_id);
  vid uuid;
  nm  text;
begin
  select coalesce(nullif(c.name, ''), 'Tenant') into nm from public.crm_clients c where c.id = v.client_id;
  select id into vid from public.property_tenant_views where property_id = v.property_id and client_id = v.client_id;
  if vid is null then vid := public.tenant_view_touch(v.property_id, v.client_id, 'website', now()); end if;
  if vid is null then raise exception 'Couldn''t save that.' using errcode = '22023'; end if;
  perform public.tenant_view_respond(vid, 'tenant', nm, null,
    jsonb_build_object('visit', 'done', 'liked', coalesce(p ->> 'liked', ''), 'liked_status', coalesce(p ->> 'liked_status', ''),
                       'reasons', coalesce(p -> 'reasons', '[]'::jsonb)));
  return public.pv_json(v) - 'client';
end;
$$;

/* ── Grants ───────────────────────────────────────────────────────────────── */

do $$
declare
  f text;
begin
  foreach f in array array[
    'public.pv_live(public.partner_visits)', 'public.pv_flat(text)', 'public.pv_answer(public.partner_visits, text)',
    'public.pv_json(public.partner_visits)', 'public.pv_spot(numeric, numeric, numeric)', 'public.pv_mine_tenant(uuid)',
    'public.pv_mine_partner(uuid)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
  foreach f in array array[
    'public.crm_partner_visits(timestamptz)', 'public.crm_partner_visit_save(jsonb)', 'public.crm_partner_visit_cancel(uuid)',
    'public.partner_visits()', 'public.partner_visit_share(uuid, numeric, numeric, text)', 'public.partner_visit_ping(uuid, numeric, numeric, numeric)',
    'public.partner_visit_sharing(uuid, boolean)', 'public.partner_visit_done(uuid)', 'public.partner_visit_respond(uuid, jsonb)',
    'public.tenant_partner_visits()', 'public.tenant_visit_coming(uuid)', 'public.tenant_visit_ping(uuid, numeric, numeric, numeric)',
    'public.tenant_visit_sharing(uuid, boolean)', 'public.tenant_visit_respond(uuid, jsonb)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

commit;
