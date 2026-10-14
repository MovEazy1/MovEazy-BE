-- ─────────────────────────────────────────────────────────────────────────────
-- QR leads — what happens after a tenant scans a broker's To-Let poster
-- (fe/src/pages/Storefront.jsx, fe/src/lib/qrLeads.js; the broker's side in
-- pages/partners/LeadsList.jsx, the CRM's in pages/crm/CrmQrScansPage.jsx).
--
-- Run in the Supabase SQL editor AFTER partner_storefront.sql, partner_launch.sql
-- (partner_tenants, partner_notifications, partner_qr_spots),
-- partner_tenant_care.sql (the board, partner_tenant_track/notes) and
-- partner_contact_phone.sql. Safe to re-run.
--
--   1. Signed in with a mobile number on the broker's QR page (/b/<code>), the
--      tenant checks in: where they are (if they allow location), which poster
--      spot. That makes them the broker's lead in My leads — marked QR, with a
--      tentative requirement from what they looked at:
--        flat types   the size chips they tapped + the flats they opened/asked for
--        budget       the lowest to the highest rent of those flats
--        area         the locality nearest to where they scanned (GPS only)
--        move-in      the earliest availability of the flats they asked to visit
--                     (else of those they opened); within 7 days → "Immediate"
--      Tentative until the broker edits the requirement themselves.
--   2. "Schedule visit" on a flat: a visit request — a note on the lead, a bell
--      notification ("X wants to visit …"), and the tenant is told the broker
--      will call.
--   3. MovEazy's CRM sees them too ("both"): the tenant's CRM client is tagged
--      via = 'qr' with the broker, listed under Clients with a QR mark — and
--      kept out of the MovEazy-leads pool other partners are sold from
--      (attributed_to = the broker, when the CRM row is that day's sign-up).
--   4. crm_qr_scans(): every scan for the CRM — the map of located check-ins,
--      hotspot areas, and which broker gets the most.
--   5. The poster page's "How it works" moves down once a poster is downloaded:
--      partner_storefronts.poster_downloaded_at.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

-- ── Columns ─────────────────────────────────────────────────────────────────
alter table public.partner_leads add column if not exists source        text not null default '';
alter table public.partner_leads add column if not exists tentative     boolean not null default false;
alter table public.partner_leads add column if not exists move_in_label text not null default '';
alter table public.partner_leads add column if not exists tenant_user   uuid references auth.users (id) on delete set null;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'partner_leads_source_check') then
    alter table public.partner_leads add constraint partner_leads_source_check check (source in ('', 'qr'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'partner_leads_move_in_label_check') then
    alter table public.partner_leads add constraint partner_leads_move_in_label_check check (move_in_label in ('', 'immediate'));
  end if;
end $$;

alter table public.partner_storefronts add column if not exists poster_downloaded_at timestamptz;

do $$
begin
  if to_regclass('public.crm_clients') is not null then
    execute 'alter table public.crm_clients add column if not exists via text not null default ''''';
    execute 'alter table public.crm_clients add column if not exists via_broker uuid';
  end if;
end $$;

-- ── Tables ──────────────────────────────────────────────────────────────────
/** One per tenant per broker per day: a signed-in visit to the QR page, located if they allowed it. */
create table if not exists public.partner_qr_checkins (
  broker_id  uuid not null references auth.users (id) on delete cascade,
  user_id    uuid not null references auth.users (id) on delete cascade,
  day        date not null default (now() at time zone 'Asia/Kolkata')::date,
  source     text not null default 'qr' check (source in ('qr', 'link')),
  spot_id    uuid references public.partner_qr_spots (id) on delete set null,
  lat        double precision check (lat between -90 and 90),
  lng        double precision check (lng between -180 and 180),
  accuracy_m int,
  locality   text not null default '',
  lead_id    uuid references public.partner_leads (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (broker_id, user_id, day)
);
create index if not exists partner_qr_checkins_day_idx on public.partner_qr_checkins (day desc);

/** "I want to visit" on one of the broker's flats. */
create table if not exists public.partner_storefront_visits (
  id          uuid primary key default gen_random_uuid(),
  broker_id   uuid not null references auth.users (id) on delete cascade,
  user_id     uuid not null references auth.users (id) on delete cascade,
  property_id text not null references public.inventory (property_id) on delete cascade,
  lead_id     uuid references public.partner_leads (id) on delete set null,
  created_at  timestamptz not null default now(),
  unique (broker_id, user_id, property_id)
);
create index if not exists partner_storefront_visits_broker_idx on public.partner_storefront_visits (broker_id, created_at desc);

alter table public.partner_qr_checkins enable row level security;
alter table public.partner_storefront_visits enable row level security;
revoke all on table public.partner_qr_checkins, public.partner_storefront_visits from anon, authenticated;

-- Two new bell kinds, added to whatever the live check already allows.
do $$
declare
  kinds text[];
begin
  select array_agg(distinct m[1]) into kinds
    from pg_constraint c, regexp_matches(pg_get_constraintdef(c.oid), '''([a-z_]+)''', 'g') m
   where c.conname = 'partner_notifications_kind_check';
  if kinds is null then return; end if;
  kinds := array(select distinct k from unnest(kinds || array['storefront_lead', 'storefront_visit']) k order by 1);
  alter table public.partner_notifications drop constraint partner_notifications_kind_check;
  execute format('alter table public.partner_notifications add constraint partner_notifications_kind_check check (kind in (%s))',
                 (select string_agg(quote_literal(k), ', ') from unnest(kinds) k));
end $$;

-- ── Internal ────────────────────────────────────────────────────────────────

/** The locality of the nearest flat we know (within ~5 km), or ''. */
create or replace function public.qr_nearest_locality(p_lat double precision, p_lng double precision)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select btrim(i.area)
      from public.inventory i
     where i.latitude is not null and i.longitude is not null and coalesce(btrim(i.area), '') <> ''
       and i.latitude::float8 between p_lat - 0.05 and p_lat + 0.05
       and i.longitude::float8 between p_lng - 0.05 and p_lng + 0.05
     order by power(i.latitude::float8 - p_lat, 2) + power((i.longitude::float8 - p_lng) * cos(radians(p_lat)), 2)
     limit 1), '');
$$;

/**
 * The tentative requirement from what the tenant did on the broker's page.
 * p_browse: { filters: ["2 BHK"], opened: [property_id…], visits: [property_id…] }
 * → { flat_types: [...], budget_min, budget_max, move_in (date or null) }
 */
create or replace function public.partner_qr_requirement(p_broker uuid, p_browse jsonb)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with ids as (
    select x as pid, false as asked
      from jsonb_array_elements_text(case when jsonb_typeof(p_browse -> 'opened') = 'array' then p_browse -> 'opened' else '[]' end) x
    union all
    select x, true
      from jsonb_array_elements_text(case when jsonb_typeof(p_browse -> 'visits') = 'array' then p_browse -> 'visits' else '[]' end) x
  ), h as (
    select distinct on (i.property_id, ids.asked) i.property_id, i.flat_type, i.rent, i.available_from, ids.asked
      from public.storefront_homes(p_broker) i join ids on ids.pid = i.property_id
  ), today as (select (now() at time zone 'Asia/Kolkata')::date as d)
  select jsonb_build_object(
    'flat_types', coalesce((
       select jsonb_agg(distinct t order by t) from (
         select btrim(f) as t
           from jsonb_array_elements_text(case when jsonb_typeof(p_browse -> 'filters') = 'array' then p_browse -> 'filters' else '[]' end) f
         union
         select btrim(h.flat_type) from h) z
        where t <> '' and lower(t) <> 'all'), '[]'::jsonb),
    'budget_min', (select min(h.rent) from h where h.rent > 0),
    'budget_max', (select max(h.rent) from h where h.rent > 0),
    'move_in', coalesce(
       (select min(coalesce(h.available_from, today.d)) from h, today where h.asked),
       (select min(coalesce(h.available_from, today.d)) from h, today)));
$$;

/** Tag the tenant's CRM client as came-via-this-broker's-QR (made if missing), and log what happened. */
create or replace function public.partner_qr_crm(p_broker uuid, p_user uuid, p_phone text, p_name text, p_email text, p_what text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c   record;
  cid uuid;
begin
  if to_regclass('public.crm_clients') is null then return; end if;
  execute 'select id, attributed_to, via, created_at from public.crm_clients where user_id = $1' into c using p_user;
  if c.id is null then
    execute 'select id, attributed_to, via, created_at from public.crm_clients
              where public.normalize_mobile(phone) = $1 and user_id is null order by created_at limit 1' into c using p_phone;
  end if;
  if c.id is null then
    execute 'insert into public.crm_clients (user_id, name, phone, email, source, status, attributed_to, via, via_broker)
             values ($1, $2, $3, $4, ''broker_qr'', ''fresh'', $5, ''qr'', $6)
             on conflict (user_id) do nothing returning id'
      into cid using p_user, coalesce(p_name, ''), p_phone, lower(coalesce(p_email, '')), p_broker::text, p_broker;
  else
    cid := c.id;
    if coalesce(c.via, '') = '' then
      -- The sign-up the QR page just produced becomes the broker's (out of the
      -- MovEazy-leads pool); an older MovEazy client stays MovEazy's, tagged.
      execute 'update public.crm_clients x
                  set via = ''qr'', via_broker = $2, updated_at = now(),
                      attributed_to = case
                        when x.attributed_to = ''moveazy'' and x.created_at > now() - interval ''1 day''
                         and not exists (select 1 from public.partner_lead_assignments a where a.client_id = x.id)
                        then $2::text else x.attributed_to end
                where x.id = $1' using cid, p_broker;
    end if;
  end if;
  if cid is not null and coalesce(p_what, '') <> '' then
    execute 'insert into public.crm_activities (client_id, actor_email, type, body, meta) values ($1, ''system'', ''system'', $2, $3)'
      using cid, p_what, jsonb_build_object('via', 'qr', 'broker_id', p_broker);
  end if;
exception when others then
  -- The CRM's copy must never stop the broker getting their lead.
  raise warning 'partner_qr_crm(%): %', p_user, sqlerrm;
end;
$$;

/**
 * The tenant on the broker's QR page, signed in with a mobile number: check
 * them in (one row a day, location kept once given) and make or refresh their
 * lead in the broker's My leads. → the lead id, or null without a number.
 */
create or replace function public.partner_qr_touch(p_broker uuid, p_user uuid, p_source text, p_spot uuid,
  p_lat double precision, p_lng double precision, p_accuracy int, p_browse jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  up      public.user_profiles;
  bname   text;
  ph      text;
  nm      text;
  loc     text := '';
  req     jsonb;
  fts     text[];
  mi      date;
  imm     boolean;
  today   date := (now() at time zone 'Asia/Kolkata')::date;
  lid     uuid;
  fresh   boolean := false;
  tr      public.partner_tenant_track;
  summary text;
begin
  select * into up from public.user_profiles where id = p_user;
  ph := public.normalize_mobile(coalesce(up.phone, ''));
  if ph = '' then return null; end if;
  nm := left(coalesce(nullif(btrim(up.name), ''), nullif(split_part(coalesce(up.email, ''), '@', 1), ''), 'Tenant'), 120);
  if p_lat is not null and p_lng is not null then loc := public.qr_nearest_locality(p_lat, p_lng); end if;

  insert into public.partner_qr_checkins as k (broker_id, user_id, source, spot_id, lat, lng, accuracy_m, locality)
  values (p_broker, p_user, case when p_source = 'link' then 'link' else 'qr' end, p_spot, p_lat, p_lng, p_accuracy, coalesce(loc, ''))
  on conflict (broker_id, user_id, day) do update
    set spot_id    = coalesce(k.spot_id, excluded.spot_id),
        lat        = coalesce(excluded.lat, k.lat),
        lng        = coalesce(excluded.lng, k.lng),
        accuracy_m = coalesce(excluded.accuracy_m, k.accuracy_m),
        locality   = case when excluded.locality <> '' then excluded.locality else k.locality end,
        updated_at = now();

  -- The broker's tenant (CRM → Broker leads), as a like already does.
  insert into public.partner_tenants as pt (broker_id, phone, name, source)
  values (p_broker, ph, left(coalesce(up.name, ''), 120), 'storefront')
  on conflict (broker_id, phone) do update set last_seen_at = now();

  req := public.partner_qr_requirement(p_broker, coalesce(p_browse, '{}'::jsonb));
  fts := array(select jsonb_array_elements_text(req -> 'flat_types'));
  mi  := nullif(req ->> 'move_in', '')::date;
  imm := mi is not null and mi <= today + 7;
  if mi is not null and mi < today then mi := today; end if;

  select id into lid from public.partner_leads
   where broker_id = p_broker and public.normalize_mobile(phone) = ph
   order by created_at limit 1;
  if lid is null then
    insert into public.partner_leads (broker_id, name, phone, flat_types, budget_min, budget_max, localities,
                                      source, tentative, move_in_label, tenant_user)
    values (p_broker, nm, ph, fts, (req ->> 'budget_min')::numeric, (req ->> 'budget_max')::numeric,
            case when loc <> '' then array[loc] else '{}'::text[] end,
            'qr', true, case when imm then 'immediate' else '' end, p_user)
    returning id into lid;
    fresh := true;
  else
    -- Only a requirement still tentative grows; once the broker has set it, it is theirs.
    update public.partner_leads l
       set flat_types    = case when l.tentative then array(select distinct x from unnest(l.flat_types || fts) x order by 1) else l.flat_types end,
           budget_min    = case when l.tentative then least(l.budget_min, (req ->> 'budget_min')::numeric) else l.budget_min end,
           budget_max    = case when l.tentative then greatest(l.budget_max, (req ->> 'budget_max')::numeric) else l.budget_max end,
           localities    = case when l.tentative and loc <> '' and not (loc = any (l.localities)) then l.localities || loc else l.localities end,
           move_in_label = case when l.tentative and imm then 'immediate' else l.move_in_label end,
           tenant_user   = coalesce(l.tenant_user, p_user),
           updated_at    = now()
     where l.id = lid;
  end if;

  if mi is not null then
    select * into tr from public.partner_tenant_track where lead_id = lid;
    if tr.id is null then
      insert into public.partner_tenant_track (broker_id, lead_id, move_in) values (p_broker, lid, mi);
    elsif tr.move_in is null or (tr.move_in > mi and exists (select 1 from public.partner_leads where id = lid and tentative)) then
      update public.partner_tenant_track set move_in = mi, updated_at = now() where id = tr.id;
    end if;
  end if;

  update public.partner_qr_checkins set lead_id = lid
   where broker_id = p_broker and user_id = p_user and day = today;

  if fresh then
    select name into bname from public.broker_partners where user_id = p_broker;
    summary := concat_ws(' · ', nullif(array_to_string(fts, ', '), ''),
                 case when (req ->> 'budget_max') is not null then
                   '₹' || to_char((req ->> 'budget_min')::numeric, 'FM99,99,99,999')
                   || case when (req ->> 'budget_max')::numeric > (req ->> 'budget_min')::numeric
                           then '–' || to_char((req ->> 'budget_max')::numeric, 'FM99,99,99,999') else '' end end,
                 nullif(loc, ''), case when imm then 'Immediate move-in' end);
    insert into public.partner_notifications (broker_id, kind, title, body, link)
    values (p_broker, 'storefront_lead', nm || ' scanned your QR — added to My leads',
            concat_ws(' — ', nullif(summary, ''), ph), public.partner_tenant_link(lid, null));
    perform public.partner_qr_crm(p_broker, p_user, ph, nm, up.email,
      'Scanned ' || coalesce(nullif(bname, ''), 'a partner') || '''s QR poster' || coalesce(' · ' || nullif(summary, ''), ''));
  else
    perform public.partner_qr_crm(p_broker, p_user, ph, nm, up.email, '');
  end if;
  return lid;
end;
$$;

revoke all on function public.qr_nearest_locality(double precision, double precision) from public, anon, authenticated;
revoke all on function public.partner_qr_requirement(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.partner_qr_crm(uuid, uuid, text, text, text, text) from public, anon, authenticated;
revoke all on function public.partner_qr_touch(uuid, uuid, text, uuid, double precision, double precision, int, jsonb) from public, anon, authenticated;

-- A broker editing the requirement makes it theirs: no longer tentative.
create or replace function public.partner_leads_untentative()
returns trigger
language plpgsql
as $$
begin
  if old.tentative and auth.uid() = old.broker_id
     and (new.flat_types is distinct from old.flat_types or new.budget_min is distinct from old.budget_min
          or new.budget_max is distinct from old.budget_max or new.localities is distinct from old.localities
          or new.furnishing is distinct from old.furnishing) then
    new.tentative := false;
  end if;
  return new;
end;
$$;
drop trigger if exists partner_leads_untentative on public.partner_leads;
create trigger partner_leads_untentative before update on public.partner_leads
  for each row execute function public.partner_leads_untentative();

-- ── The tenant's side (moveazy.co.in/b/<code>) ──────────────────────────────

/**
 * Check in on the broker's page: signed in, with a mobile number on the
 * account. Location only if the tenant allowed it (India only). → { lead: bool }
 */
create or replace function public.partner_storefront_checkin(p_code text, p_spot text default '', p_source text default 'qr',
  p_lat double precision default null, p_lng double precision default null, p_accuracy int default null,
  p_browse jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  bid uuid := public.storefront_broker(p_code);
  sp  uuid;
  lat double precision := p_lat;
  lng double precision := p_lng;
  lid uuid;
begin
  if uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if bid is null then raise exception 'This storefront is not available.' using errcode = '22023'; end if;
  if bid = uid then return jsonb_build_object('lead', false); end if;
  if lat is null or lng is null or lat not between 6 and 38 or lng not between 68 and 98 then
    lat := null; lng := null;
  end if;
  select s.id into sp from public.partner_qr_spots s where s.code = lower(trim(coalesce(p_spot, ''))) and s.broker_id = bid;
  lid := public.partner_qr_touch(bid, uid, p_source, sp, lat, lng,
                                case when p_accuracy is null then null else least(greatest(p_accuracy, 0), 100000) end, p_browse);
  return jsonb_build_object('lead', lid is not null);
end;
$$;

/**
 * "Schedule visit" on one of the broker's live flats. The tenant needs a
 * mobile number on their account. → what the thank-you page shows:
 * { broker: { name, phone }, home: { property_id, flat_type, area, rent } }
 */
create or replace function public.partner_storefront_visit(p_code text, p_property text, p_browse jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid  uuid := auth.uid();
  bid  uuid := public.storefront_broker(p_code);
  h    record;
  up   public.user_profiles;
  lid  uuid;
  b    jsonb := coalesce(p_browse, '{}'::jsonb);
  flat text;
  first_ask boolean;
  bname text;
begin
  if uid is null then raise exception 'Sign in to ask for a visit.' using errcode = '42501'; end if;
  if bid is null then raise exception 'This storefront is not available.' using errcode = '22023'; end if;
  if bid = uid then raise exception 'This is your own flat.' using errcode = '22023'; end if;
  select i.property_id, i.flat_type, i.area, i.rent into h from public.storefront_homes(bid) i where i.property_id = p_property;
  if h.property_id is null then raise exception 'That home is not on this storefront any more.' using errcode = '22023'; end if;
  select * into up from public.user_profiles where id = uid;
  if public.normalize_mobile(coalesce(up.phone, '')) = '' then
    raise exception 'Add your mobile number so the broker can call you.' using errcode = '22023';
  end if;

  b := jsonb_set(b, '{visits}', coalesce(case when jsonb_typeof(b -> 'visits') = 'array' then b -> 'visits' end, '[]'::jsonb) || to_jsonb(p_property));
  lid := public.partner_qr_touch(bid, uid, null, null, null, null, null, b);

  insert into public.partner_storefront_visits as v (broker_id, user_id, property_id, lead_id)
  values (bid, uid, p_property, lid)
  on conflict (broker_id, user_id, property_id) do update set lead_id = excluded.lead_id
  returning (xmax = 0) into first_ask;

  flat := concat_ws(' · ', nullif(h.flat_type, ''), nullif(h.area, ''),
                    case when h.rent > 0 then '₹' || to_char(h.rent, 'FM99,99,99,999') end);
  if first_ask and lid is not null then
    insert into public.partner_tenant_notes (broker_id, lead_id, body)
    values (bid, lid, left('Asked to visit ' || coalesce(nullif(flat, ''), p_property) || ' from your QR page.', 1000));
    insert into public.partner_notifications (broker_id, kind, title, body, link)
    values (bid, 'storefront_visit',
            left(coalesce(nullif(btrim(up.name), ''), 'A tenant'), 80) || ' wants to visit your flat',
            concat_ws(' — ', nullif(flat, ''), public.normalize_mobile(up.phone)), public.partner_tenant_link(lid, null));
    select name into bname from public.broker_partners where user_id = bid;
    perform public.partner_qr_crm(bid, uid, public.normalize_mobile(up.phone), up.name, up.email,
      'Asked ' || coalesce(nullif(bname, ''), 'a partner') || ' (QR) for a visit · ' || coalesce(nullif(flat, ''), p_property));
  end if;

  return jsonb_build_object(
    'broker', (select jsonb_build_object('name', p.name, 'phone', public.partner_contact_phone(p.user_id))
                 from public.broker_partners p where p.user_id = bid),
    'home', jsonb_build_object('property_id', h.property_id, 'flat_type', h.flat_type, 'area', h.area, 'rent', h.rent));
end;
$$;

-- ── The broker's side ───────────────────────────────────────────────────────

/** The poster page: has this partner downloaded a poster yet? Marks it when p_mark. → timestamptz or null */
create or replace function public.partner_poster_downloaded(p_mark boolean default false)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
  at timestamptz;
begin
  if not public.is_approved_partner() then raise exception 'Only MovEazy partners.' using errcode = '42501'; end if;
  if p_mark then
    update public.partner_storefronts set poster_downloaded_at = coalesce(poster_downloaded_at, now())
     where broker_id = auth.uid() returning poster_downloaded_at into at;
    return at;
  end if;
  select poster_downloaded_at into at from public.partner_storefronts where broker_id = auth.uid();
  return at;
end;
$$;

/** The board (partner_tenant_care.sql), plus for own leads: via ('qr'), tentative, QR visit requests, "Immediate move-in". */
create or replace function public.partner_tenants_board()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with t as (
    select l.id as lead_id, null::uuid as assignment_id, 'own'::text as kind,
           l.name, public.normalize_mobile(l.phone) as phone, l.localities, l.flat_types, l.budget_min, l.budget_max,
           l.furnishing, case when l.move_in_label = 'immediate' then 'Immediate move-in' else '' end as move_in_raw,
           null::date as req_move_in, l.created_at,
           l.last_contacted_at as contact_at, l.status as own_status, null::text as asg_status, null::text as pack,
           l.source as via, l.tentative
      from public.partner_leads l where l.broker_id = auth.uid()
    union all
    select null, m.id, 'moveazy', m.name, public.normalize_mobile(m.phone), m.localities, m.flat_types, m.budget_min, m.budget_max,
           '', m.move_in_raw, m.move_in, m.assigned_at, m.last_reach_at, null, m.status, m.pack, '', false
      from public.partner_my_assigned_leads() m
  ), x as (
    select t.*, tr.outcome, tr.outcome_at, tr.lost_reason, tr.move_in, tr.deal_property_id, tr.deal_rent, tr.deal_move_in, tr.actions_seen_at,
           (select array_agg(cl.id) from public.partner_curated_lists cl
             where cl.broker_id = auth.uid()
               and ((t.lead_id is not null and cl.lead_id = t.lead_id) or (t.assignment_id is not null and cl.assignment_id = t.assignment_id))) as list_ids
      from t
      left join public.partner_tenant_track tr
        on (t.lead_id is not null and tr.lead_id = t.lead_id) or (t.assignment_id is not null and tr.assignment_id = t.assignment_id)
  ), y as (
    select x.*,
           coalesce(cardinality(x.list_ids), 0) as lists,
           (select count(distinct a.property_id)::int from public.partner_curated_actions a where a.list_id = any (coalesce(x.list_ids, '{}')) and a.action = 'liked') as liked,
           (select count(*)::int from public.partner_curated_actions a where a.list_id = any (coalesce(x.list_ids, '{}'))
              and a.at > coalesce(x.actions_seen_at, '-infinity')) as new_actions,
           (select max(a.at) from public.partner_curated_actions a where a.list_id = any (coalesce(x.list_ids, '{}'))) as last_action_at,
           exists (select 1 from public.partner_curated_lists cl where cl.id = any (coalesce(x.list_ids, '{}')) and cl.opened_at is not null) as opened,
           (select min(v.visit_at) from public.partner_visits v where v.status = 'fixed' and v.visit_at > now() - interval '12 hours'
              and ((x.lead_id is not null and v.lead_id = x.lead_id) or (x.assignment_id is not null and v.assignment_id = x.assignment_id))) as next_visit,
           exists (select 1 from public.partner_visits v where v.status = 'fixed'
              and ((x.lead_id is not null and v.lead_id = x.lead_id) or (x.assignment_id is not null and v.assignment_id = x.assignment_id))) as has_visit,
           (select jsonb_build_object('id', r.id, 'due_at', r.due_at, 'note', r.note, 'kind', r.kind)
              from public.partner_reminders r where r.done_at is null and r.broker_id = auth.uid()
               and ((x.lead_id is not null and r.lead_id = x.lead_id) or (x.assignment_id is not null and r.assignment_id = x.assignment_id))
             order by r.due_at limit 1) as next_reminder,
           (select count(*)::int from public.partner_storefront_visits sv where x.lead_id is not null and sv.lead_id = x.lead_id) as qr_visits
      from x
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', case when y.lead_id is not null then 'lead:' || y.lead_id else 'asg:' || y.assignment_id end,
           'slug', case when y.lead_id is not null then 'lead-' || y.lead_id else 'asg-' || y.assignment_id end,
           'kind', y.kind, 'lead_id', y.lead_id, 'assignment_id', y.assignment_id, 'pack', y.pack,
           'name', y.name, 'phone', y.phone, 'localities', y.localities, 'flat_types', y.flat_types,
           'budget_min', y.budget_min, 'budget_max', y.budget_max, 'furnishing', y.furnishing, 'move_in_raw', y.move_in_raw,
           'move_in', coalesce(y.move_in, y.req_move_in),
           'stage', case
              when y.outcome = 'done' or y.asg_status = 'closed' then 'done'
              when y.outcome = 'lost' or y.asg_status = 'not_interested' or (y.kind = 'own' and y.own_status = 'closed') then 'lost'
              when y.has_visit then 'visit'
              when y.liked > 0 then 'liked'
              when y.lists > 0 then 'list_sent'
              when y.contact_at is not null or y.asg_status in ('contacted', 'visit') then 'contacted'
              else 'new' end,
           'lost_reason', y.lost_reason, 'outcome_at', y.outcome_at,
           'deal', case when y.deal_property_id <> '' or y.deal_rent is not null then
                     jsonb_build_object('property_id', y.deal_property_id, 'rent', y.deal_rent, 'move_in', y.deal_move_in) end,
           'lists', y.lists, 'opened', y.opened, 'liked', y.liked, 'new_actions', y.new_actions, 'last_action_at', y.last_action_at,
           'last_contact_at', y.contact_at, 'next_visit', y.next_visit, 'next_reminder', y.next_reminder, 'created_at', y.created_at,
           'via', y.via, 'tentative', y.tentative, 'qr_visits', y.qr_visits)
           order by y.created_at desc), '[]'::jsonb)
    from y
   where public.is_approved_partner();
$$;

-- ── The CRM ─────────────────────────────────────────────────────────────────

/**
 * Every QR scan, for the CRM's QR scans page. p_days: 7, 30… or null for all.
 * → { totals, brokers: [...], areas: [...], points: [...] }
 *   scans       poster scans (partner_storefront_views, source 'qr'): a device once a day
 *   signed_in   tenants who signed in on a broker's page (check-ins)
 *   located     check-ins with a location; points are those, for the map
 *   areas       hotspots: GPS check-ins by nearest locality + scans by poster spot area
 */
create or replace function public.crm_qr_scans(p_days int default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  since date := case when p_days is null then null else (now() at time zone 'Asia/Kolkata')::date - greatest(p_days, 1) + 1 end;
  t0    timestamptz := case when since is null then '-infinity'::timestamptz else (since::timestamp at time zone 'Asia/Kolkata') end;
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  return (
    with v as (select * from public.partner_storefront_views where source = 'qr' and (since is null or day >= since)),
         c as (select * from public.partner_qr_checkins where since is null or day >= since),
         l as (select * from public.partner_leads where source = 'qr' and created_at >= t0),
         sv as (select * from public.partner_storefront_visits where created_at >= t0),
         brokers as (
           select bp.user_id, bp.name, bp.agency, bp.phone,
                  (select count(*) from v where v.broker_id = bp.user_id) as scans,
                  (select count(distinct v.visitor) from v where v.broker_id = bp.user_id) as scanners,
                  (select count(distinct c.user_id) from c where c.broker_id = bp.user_id) as signed_in,
                  (select count(*) from l where l.broker_id = bp.user_id) as leads,
                  (select count(*) from sv where sv.broker_id = bp.user_id) as visits,
                  (select count(*) from public.partner_qr_spots s where s.broker_id = bp.user_id and s.active) as spots,
                  (select max(v.created_at) from v where v.broker_id = bp.user_id) as last_scan
             from public.broker_partners bp
            where bp.status = 'approved'),
         areas as (
           select area, sum(gps)::int as gps, sum(poster)::int as poster, count(distinct broker_id)::int as brokers
             from (select c.locality as area, 1 as gps, 0 as poster, c.broker_id from c where c.locality <> ''
                   union all
                   select s.area, 0, 1, v.broker_id from v join public.partner_qr_spots s on s.id = v.spot_id where coalesce(s.area, '') <> '') z
            group by area)
    select jsonb_build_object(
      'since', since,
      'totals', jsonb_build_object(
         'scans', (select count(*) from v), 'scanners', (select count(distinct v.visitor) from v),
         'signed_in', (select count(*) from c), 'located', (select count(*) from c where c.lat is not null),
         'leads', (select count(*) from l), 'visits', (select count(*) from sv),
         'brokers', (select count(distinct v.broker_id) from v)),
      'brokers', coalesce((select jsonb_agg(jsonb_build_object(
           'broker_id', b.user_id, 'name', b.name, 'agency', b.agency, 'phone', b.phone, 'scans', b.scans, 'scanners', b.scanners,
           'signed_in', b.signed_in, 'leads', b.leads, 'visits', b.visits, 'spots', b.spots, 'last_scan', b.last_scan)
           order by b.scans desc, b.signed_in desc, b.name)
         from brokers b where b.scans > 0 or b.signed_in > 0 or b.spots > 0), '[]'::jsonb),
      'areas', coalesce((select jsonb_agg(jsonb_build_object('area', a.area, 'gps', a.gps, 'poster', a.poster,
           'scans', a.gps + a.poster, 'brokers', a.brokers) order by a.gps + a.poster desc, a.area)
         from (select * from areas order by gps + poster desc limit 60) a), '[]'::jsonb),
      'points', coalesce((select jsonb_agg(jsonb_build_object('lat', round(c.lat::numeric, 5), 'lng', round(c.lng::numeric, 5),
           'locality', c.locality, 'day', c.day, 'broker', bp.name, 'lead', c.lead_id is not null))
         from (select * from c where c.lat is not null order by c.updated_at desc limit 3000) c
         left join public.broker_partners bp on bp.user_id = c.broker_id), '[]'::jsonb))
  );
end;
$$;

revoke all on function public.partner_storefront_checkin(text, text, text, double precision, double precision, int, jsonb) from public, anon;
revoke all on function public.partner_storefront_visit(text, text, jsonb) from public, anon;
revoke all on function public.partner_poster_downloaded(boolean) from public, anon;
revoke all on function public.partner_tenants_board() from public, anon;
revoke all on function public.crm_qr_scans(int) from public, anon;
grant execute on function public.partner_storefront_checkin(text, text, text, double precision, double precision, int, jsonb) to authenticated;
grant execute on function public.partner_storefront_visit(text, text, jsonb) to authenticated;
grant execute on function public.partner_poster_downloaded(boolean) to authenticated;
grant execute on function public.partner_tenants_board() to authenticated;
grant execute on function public.crm_qr_scans(int) to authenticated;

commit;
