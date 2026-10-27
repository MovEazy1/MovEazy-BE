-- ─────────────────────────────────────────────────────────────────────────────
-- Tenants the MovEazy team brings to a building, and where each one stands
-- (fe/src/pages/crm/CrmBuildingEditor.jsx — the "Add tenant" bar; the owner
-- sees them through owner_qr_overview.sql, run AFTER this file).
--
-- Run in the Supabase SQL editor AFTER owner_buildings.sql, crm_schema.sql,
-- lead_intake.sql and building_call_desk.sql. Safe to re-run.
--
-- One card per mobile per building, updated as things move:
--   visit     pending | done
--   liked     liked | disliked (once the visit is done)
--   if liked:     negotiate | exploring | will_pay_token | paid_token
--   if disliked:  any of size_small, office_distance, location, ventilation,
--                 amenities, and reasons typed by the team — a typed reason
--                 becomes an option on every building (tenant_reason_options).
-- Each number is a CRM client too; every save is noted on the client's
-- history. "Paid token" books the flats picked on the card (the QR page then
-- shows them taken); moving off it frees what it booked.
-- Only buildings with tenant_tracker on show the bar — BR Homes for now.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

alter table public.owner_buildings add column if not exists tenant_tracker boolean not null default false;

create table if not exists public.building_tenant_tracks (
  id           uuid primary key default gen_random_uuid(),
  building_id  uuid not null references public.owner_buildings (id) on delete cascade,
  phone        text not null check (phone ~ '^[6-9][0-9]{9}$'),
  name         text not null default '' check (length(name) <= 80),
  property_ids text[] not null default '{}',
  note         text not null default '' check (length(note) <= 1000),
  visit        text not null default 'pending' check (visit in ('pending', 'done')),
  liked        text not null default '' check (liked in ('', 'liked', 'disliked')),
  liked_status text not null default '' check (liked_status in ('', 'negotiate', 'exploring', 'will_pay_token', 'paid_token')),
  reasons      text[] not null default '{}',
  client_id    uuid references public.crm_clients (id) on delete set null,
  created_by   text not null default '',
  updated_by   text not null default '',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (building_id, phone)
);
create index if not exists building_tenant_tracks_building_idx on public.building_tenant_tracks (building_id, updated_at desc);

create table if not exists public.tenant_reason_options (
  id         uuid primary key default gen_random_uuid(),
  label      text not null check (length(label) between 2 and 60),
  created_by text not null default '',
  created_at timestamptz not null default now(),
  removed_at timestamptz
);
create unique index if not exists tenant_reason_options_label_idx on public.tenant_reason_options (lower(label)) where removed_at is null;

alter table public.building_tenant_tracks enable row level security;
alter table public.tenant_reason_options enable row level security;
revoke all on public.building_tenant_tracks, public.tenant_reason_options from anon, authenticated;

-- BR Homes.
update public.owner_buildings set tenant_tracker = true where code = 'H33PSH' and not tenant_tracker;

/** The reasons every building offers, built in first. Internal. */
create or replace function public.tenant_reason_builtin()
returns text[] language sql immutable as $$
  select array['size_small', 'office_distance', 'location', 'ventilation', 'amenities']
$$;

/** One card as the CRM shows it. Internal. */
create or replace function public.tenant_track_json(t public.building_tenant_tracks)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', t.id, 'phone', t.phone, 'name', t.name, 'property_ids', t.property_ids, 'note', t.note,
    'visit', t.visit, 'liked', t.liked, 'liked_status', t.liked_status, 'reasons', t.reasons,
    'client_id', t.client_id, 'created_by', t.created_by, 'updated_by', t.updated_by,
    'created_at', t.created_at, 'updated_at', t.updated_at,
    'flats', (select coalesce(jsonb_agg(coalesce(nullif(i.unit_no, ''), i.property_id) order by i.unit_order nulls last, i.unit_no), '[]'::jsonb)
                from public.inventory i where i.property_id = any(t.property_ids)))
$$;

/**
 * The CRM building page: is the bar on, the cards (newest first) and the
 * typed reasons on offer. { enabled, tracks: [...], reasons: [{ id, label }] }
 */
create or replace function public.crm_tenant_tracks(p_building uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'enabled', coalesce((select tenant_tracker from public.owner_buildings where id = p_building), false),
    'tracks', coalesce((select jsonb_agg(public.tenant_track_json(t) order by t.updated_at desc)
                          from public.building_tenant_tracks t where t.building_id = p_building), '[]'::jsonb),
    'reasons', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'label', r.label) order by r.created_at)
                           from public.tenant_reason_options r where r.removed_at is null), '[]'::jsonb));
end;
$$;

/**
 * Add a tenant, or update their card (same building, same mobile):
 * { phone, name, property_ids, note, visit, liked, liked_status, reasons }.
 * A reason that isn't built in is a typed one, offered everywhere from now on.
 * → the card.
 */
create or replace function public.crm_tenant_track_save(p_building uuid, p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me     text := lower(coalesce(auth.jwt() ->> 'email', ''));
  ph     text := public.normalize_mobile(p ->> 'phone');
  nm     text := left(trim(coalesce(p ->> 'name', '')), 80);
  vis    text := coalesce(nullif(p ->> 'visit', ''), 'pending');
  lk     text := coalesce(p ->> 'liked', '');
  ls     text := coalesce(p ->> 'liked_status', '');
  flats  text[];
  rs     text[];
  r      text;
  old    public.building_tenant_tracks;
  t      public.building_tenant_tracks;
  cid    uuid;
  bname  text;
  marker text;
begin
  if not public.has_admin_scope('crm.clients.write') then
    raise exception 'Needs permission to update clients.' using errcode = '42501';
  end if;
  select name into bname from public.owner_buildings where id = p_building and tenant_tracker;
  if bname is null then raise exception 'This building doesn''t track tenants.' using errcode = '22023'; end if;
  if ph !~ '^[6-9][0-9]{9}$' then raise exception 'Enter a valid 10-digit mobile number.' using errcode = '22023'; end if;
  if vis not in ('pending', 'done') or lk not in ('', 'liked', 'disliked')
     or ls not in ('', 'negotiate', 'exploring', 'will_pay_token', 'paid_token') then
    raise exception 'Unknown status.' using errcode = '22023';
  end if;

  -- Only flats of this building.
  select coalesce(array_agg(i.property_id order by i.property_id), '{}') into flats
    from public.inventory i
   where i.building_id = p_building
     and i.property_id in (select upper(trim(x)) from jsonb_array_elements_text(coalesce(p -> 'property_ids', '[]'::jsonb)) x);

  -- Reasons: built in by key, the rest typed (trimmed, unique, offered from now on).
  rs := '{}';
  for r in select distinct trim(x) from jsonb_array_elements_text(coalesce(p -> 'reasons', '[]'::jsonb)) x where trim(x) <> '' loop
    if r = any(public.tenant_reason_builtin()) then
      rs := rs || r;
    elsif length(r) between 2 and 60 then
      rs := rs || r;
      insert into public.tenant_reason_options (label, created_by)
      select r, me where not exists (select 1 from public.tenant_reason_options o where lower(o.label) = lower(r) and o.removed_at is null);
    end if;
  end loop;

  -- What follows a status only once the step before it is there.
  if vis = 'pending' then lk := ''; end if;
  if lk <> 'liked' then ls := ''; end if;
  if lk <> 'disliked' then rs := '{}'; end if;

  select * into old from public.building_tenant_tracks where building_id = p_building and phone = ph;

  -- The CRM client: theirs if the number is known, else a new one.
  cid := old.client_id;
  if cid is null then
    select c.id into cid from public.crm_clients c
     where right(regexp_replace(coalesce(c.phone, ''), '\D', '', 'g'), 10) = ph
     order by c.created_at limit 1;
  end if;
  if cid is null then
    insert into public.crm_clients (name, phone, source) values (nm, ph, 'building_qr') returning id into cid;
  end if;
  if cid is not null and nm <> '' then
    update public.crm_clients set name = nm where id = cid and coalesce(name, '') = '';
  end if;

  insert into public.building_tenant_tracks as x
    (building_id, phone, name, property_ids, note, visit, liked, liked_status, reasons, client_id, created_by, updated_by)
  values (p_building, ph, nm, flats, left(trim(coalesce(p ->> 'note', '')), 1000), vis, lk, ls, rs, cid, me, me)
  on conflict (building_id, phone) do update set
    name = case when excluded.name <> '' then excluded.name else x.name end,
    property_ids = excluded.property_ids, note = excluded.note, visit = excluded.visit, liked = excluded.liked,
    liked_status = excluded.liked_status, reasons = excluded.reasons, client_id = coalesce(x.client_id, excluded.client_id),
    updated_by = me, updated_at = now()
  returning * into t;

  -- Paid token books the card's flats; moving off it frees what it booked.
  marker := 'tenant_track:' || t.id;
  delete from public.owner_building_bookings
   where booked_by = marker and (t.liked_status <> 'paid_token' or not (property_id = any(t.property_ids)));
  if t.liked_status = 'paid_token' then
    insert into public.owner_building_bookings (property_id, building_id, booked_by)
    select f, p_building, marker from unnest(t.property_ids) f
    on conflict (property_id) do nothing;
  end if;

  -- The client's history says what changed, and who.
  if t.client_id is not null then
    insert into public.crm_activities (client_id, actor_email, type, body, meta)
    values (t.client_id, me, 'visit',
            bname || ' · ' || case t.visit when 'done' then 'Visit done' else 'Visit pending' end
              || case t.liked when 'liked' then ' · Liked' when 'disliked' then ' · Did not like' else '' end
              || case t.liked_status when 'negotiate' then ' · Negotiating on rent' when 'exploring' then ' · Exploring other options'
                   when 'will_pay_token' then ' · Will pay token' when 'paid_token' then ' · Paid token' else '' end
              || case when cardinality(t.reasons) > 0 then ' · ' || array_to_string(t.reasons, ', ') else '' end
              || case when cardinality(t.property_ids) > 0 then ' · flats ' || (select string_agg(coalesce(nullif(i.unit_no, ''), i.property_id), ', ')
                                                                            from public.inventory i where i.property_id = any(t.property_ids)) else '' end
              || case when t.note <> '' then ' — ' || t.note else '' end,
            jsonb_build_object('building_id', p_building, 'track_id', t.id, 'visit', t.visit, 'liked', t.liked,
                               'liked_status', t.liked_status, 'reasons', t.reasons, 'property_ids', t.property_ids));
  end if;

  return public.tenant_track_json(t);
end;
$$;

/** Take a typed reason off the list. Cards that have it keep it. */
create or replace function public.crm_tenant_reason_remove(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.has_admin_scope('crm.clients.write') then
    raise exception 'Needs permission to update clients.' using errcode = '42501';
  end if;
  update public.tenant_reason_options set removed_at = now() where id = p_id and removed_at is null;
end;
$$;

-- ── Grants ───────────────────────────────────────────────────────────────────
revoke all on function public.tenant_reason_builtin() from public;
revoke all on function public.tenant_track_json(public.building_tenant_tracks) from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array['public.crm_tenant_tracks(uuid)', 'public.crm_tenant_track_save(uuid, jsonb)', 'public.crm_tenant_reason_remove(uuid)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

commit;
