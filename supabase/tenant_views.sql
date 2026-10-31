-- ─────────────────────────────────────────────────────────────────────────────
-- Tenant views: every tenant we can name who opened a property, and what they
-- thought of it — kept per tenant per property, with its full history, so a
-- model can one day score each property from real tenant feedback.
-- (fe: lib/tenantViews.js; the CRM's property, client record and "Tenant
-- views" page; the owner's Tenant views page and building tenants board; the
-- partner app's MovEazy leads.)
--
-- Run in the Supabase SQL editor AFTER owner_qr_overview.sql,
-- building_tenant_tracks.sql, building_tenants_board.sql,
-- partner_website_leads.sql, crm_curated_shares.sql and crm_share_tracking.sql.
-- Safe to re-run.
--
-- Who is a view (property_tenant_views, one row per CRM client per property):
--   share    opened a link the team sent on WhatsApp (crm_shortlists' token, a
--            curated shortlist) — and, from then on, anything that phone opens
--            (visitor_clients)
--   website  opened the property's page signed in (flat_scans.user_id), or
--            liked / booked it on the website
--   qr       scanned the QR and gave a number (owner_building_leads)
--   team     the team added them to a building's tenants (building_tenant_tracks)
--   partner  the partner marked how it went
-- Anonymous opens stay in flat_scans' counts only.
--
-- What it records: opens, first / last opened, seconds on the page and how many
-- photos they looked at (flat_view_engage), and the response — the same labels
-- as BR Homes' tracker (visit pending | done; liked → negotiate | exploring |
-- will_pay_token | paid_token; disliked → reasons, typed ones offered to every
-- property). The tenant's own swipe or booking fills it in ("tenant"), the
-- partner can mark it ("partner"), the team's mark wins ("team"); every answer
-- is kept in property_view_responses.
--
-- BR Homes is the same system: a building card's status is the response on
-- each of its flats, and a response on one of its flats updates the card.
--
-- Partners: each MovEazy lead shows which of their flats the tenant viewed and
-- how it went; their calls, WhatsApps, status changes, follow-ups and responses
-- are kept (partner_lead_events) for the CRM, which can follow up with the
-- broker on WhatsApp (logged too).
-- ─────────────────────────────────────────────────────────────────────────────

begin;

-- ── Tables ──────────────────────────────────────────────────────────────────

create table if not exists public.property_tenant_views (
  id             uuid primary key default gen_random_uuid(),
  property_id    text not null references public.inventory (property_id) on delete cascade,
  client_id      uuid not null references public.crm_clients (id) on delete cascade,
  sources        text[] not null default '{}',
  first_at       timestamptz not null default now(),
  last_at        timestamptz not null default now(),
  opens          int not null default 0,
  seconds        int not null default 0,
  photos         int not null default 0,
  visit          text not null default '' check (visit in ('', 'pending', 'done')),
  liked          text not null default '' check (liked in ('', 'liked', 'disliked')),
  liked_status   text not null default '' check (liked_status in ('', 'negotiate', 'exploring', 'will_pay_token', 'paid_token')),
  reasons        text[] not null default '{}',
  note           text not null default '' check (length(note) <= 1000),
  response_by    text not null default '' check (response_by in ('', 'team', 'partner', 'tenant')),
  response_actor text not null default '',
  response_at    timestamptz,
  follow_up_on   date,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (property_id, client_id)
);
create index if not exists property_tenant_views_client_idx on public.property_tenant_views (client_id, last_at desc);
create index if not exists property_tenant_views_last_idx on public.property_tenant_views (last_at desc);

create table if not exists public.property_view_responses (
  id           bigint generated always as identity primary key,
  view_id      uuid not null references public.property_tenant_views (id) on delete cascade,
  by_kind      text not null check (by_kind in ('team', 'partner', 'tenant')),
  actor        text not null default '',
  broker_id    uuid references auth.users (id) on delete set null,
  visit        text not null default '',
  liked        text not null default '',
  liked_status text not null default '',
  reasons      text[] not null default '{}',
  note         text not null default '',
  follow_up_on date,
  said         jsonb not null default '{}'::jsonb, -- exactly what was sent
  at           timestamptz not null default now()
);
create index if not exists property_view_responses_view_idx on public.property_view_responses (view_id, at desc);

-- A phone that opened a link the team sent: its later anonymous opens are that client's.
create table if not exists public.visitor_clients (
  visitor   text primary key check (length(visitor) between 8 and 64),
  client_id uuid not null references public.crm_clients (id) on delete cascade,
  at        timestamptz not null default now()
);

alter table public.flat_scans add column if not exists seconds int not null default 0;
alter table public.flat_scans add column if not exists photos int not null default 0;
alter table public.flat_scans add column if not exists client_id uuid references public.crm_clients (id) on delete set null;
create index if not exists flat_scans_client_idx on public.flat_scans (client_id) where client_id is not null;

-- What a partner did with a MovEazy lead, and the team's follow-ups with them.
create table if not exists public.partner_lead_events (
  id            bigint generated always as identity primary key,
  assignment_id uuid not null references public.partner_lead_assignments (id) on delete cascade,
  client_id     uuid not null references public.crm_clients (id) on delete cascade,
  broker_id     uuid not null references auth.users (id) on delete cascade,
  kind          text not null check (kind in ('call', 'whatsapp', 'status', 'follow_up', 'response', 'team_follow_up')),
  detail        text not null default '',
  actor         text not null default '',
  at            timestamptz not null default now()
);
create index if not exists partner_lead_events_client_idx on public.partner_lead_events (client_id, at desc);
create index if not exists partner_lead_events_assignment_idx on public.partner_lead_events (assignment_id, at desc);

alter table public.partner_lead_assignments add column if not exists follow_up_on date;
-- Where a building visit request came from: its QR page, or a Meta ad page (visit_ad_pages.sql).
alter table public.owner_building_leads add column if not exists source text not null default 'qr';
alter table public.partner_lead_assignments add column if not exists follow_up_note text not null default '';

create table if not exists public.tenant_views_meta (key text primary key, at timestamptz not null default now());

alter table public.property_tenant_views enable row level security;
alter table public.property_view_responses enable row level security;
alter table public.visitor_clients enable row level security;
alter table public.partner_lead_events enable row level security;
alter table public.tenant_views_meta enable row level security;
revoke all on public.property_tenant_views, public.property_view_responses, public.visitor_clients,
              public.partner_lead_events, public.tenant_views_meta from anon, authenticated;

-- ── Internal ────────────────────────────────────────────────────────────────

/** "Visit done · Liked · Will pay token", "Did not like · size_small, Noisy". Internal. */
create or replace function public.tenant_response_text(p_visit text, p_liked text, p_status text, p_reasons text[])
returns text language sql immutable as $$
  select concat_ws(' · ',
    case p_visit when 'done' then 'Visit done' when 'pending' then 'Visit pending' end,
    case p_liked when 'liked' then 'Liked' when 'disliked' then 'Did not like' end,
    case p_status when 'negotiate' then 'Negotiating on rent' when 'exploring' then 'Exploring other options'
                  when 'will_pay_token' then 'Will pay token' when 'paid_token' then 'Paid token' end,
    nullif(array_to_string(coalesce(p_reasons, '{}'), ', '), ''))
$$;

/**
 * Someone we can name looked at a property: make or top up their view.
 * Opens and seconds add up; photos keep the most; p_min_opens floors the opens
 * (a share link's own counter). Partners, CRM staff and the property's owner
 * aren't tenants. → the view's id, or null.
 */
create or replace function public.tenant_view_touch(p_property text, p_client uuid, p_source text, p_at timestamptz default now(),
                                                    p_opens int default 0, p_seconds int default 0, p_photos int default 0,
                                                    p_min_opens int default 0)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid;
  vid uuid;
  at  timestamptz := coalesce(p_at, now());
begin
  if p_client is null or coalesce(p_property, '') = '' then return null; end if;
  select c.user_id into uid from public.crm_clients c where c.id = p_client;
  if not found then return null; end if;
  if uid is not null and not public.website_tenant_ok(uid, p_property) then return null; end if;
  if not exists (select 1 from public.inventory where property_id = p_property) then return null; end if;
  insert into public.property_tenant_views as v (property_id, client_id, sources, first_at, last_at, opens, seconds, photos)
  values (p_property, p_client, array[p_source], at, at, greatest(coalesce(p_opens, 0), coalesce(p_min_opens, 0), 0),
          least(greatest(coalesce(p_seconds, 0), 0), 360000), least(greatest(coalesce(p_photos, 0), 0), 500))
  on conflict (property_id, client_id) do update set
    sources  = case when p_source = any(v.sources) then v.sources else v.sources || p_source end,
    first_at = least(v.first_at, excluded.first_at),
    last_at  = greatest(v.last_at, excluded.last_at),
    opens    = greatest(v.opens + greatest(coalesce(p_opens, 0), 0), coalesce(p_min_opens, 0)),
    seconds  = least(v.seconds + greatest(coalesce(p_seconds, 0), 0), 360000),
    photos   = greatest(v.photos, excluded.photos),
    updated_at = now()
  returning id into vid;
  return vid;
end;
$$;

/**
 * Record a response on a view: { visit, liked, liked_status, reasons, note,
 * follow_up_on } — a key left out keeps what's there. Always kept in the
 * history; it becomes the view's response when it's the team's, or nobody
 * stronger has answered (team > partner > tenant). Typed reasons from the team
 * or a partner are offered on every property after. → the view.
 */
create or replace function public.tenant_view_respond(p_view uuid, p_by text, p_actor text, p_broker uuid, p jsonb,
                                                      p_at timestamptz default now())
returns public.property_tenant_views
language plpgsql
security definer
set search_path = public
as $$
declare
  v    public.property_tenant_views;
  vis  text;
  lk   text;
  ls   text;
  rs   text[];
  r    text;
  nt   text;
  fu   date;
  wins boolean;
begin
  select * into v from public.property_tenant_views where id = p_view for update;
  if v.id is null then return null; end if;
  if p_by not in ('team', 'partner', 'tenant') then raise exception 'Unknown responder.' using errcode = '22023'; end if;
  vis := case when p ? 'visit' then coalesce(p ->> 'visit', '') else v.visit end;
  lk  := case when p ? 'liked' then coalesce(p ->> 'liked', '') else v.liked end;
  ls  := case when p ? 'liked_status' then coalesce(p ->> 'liked_status', '') else v.liked_status end;
  nt  := case when p ? 'note' then left(trim(coalesce(p ->> 'note', '')), 1000) else v.note end;
  fu  := case when p ? 'follow_up_on' then case when coalesce(p ->> 'follow_up_on', '') ~ '^\d{4}-\d{2}-\d{2}$' then (p ->> 'follow_up_on')::date end
              else v.follow_up_on end;
  if vis not in ('', 'pending', 'done') or lk not in ('', 'liked', 'disliked')
     or ls not in ('', 'negotiate', 'exploring', 'will_pay_token', 'paid_token') then
    raise exception 'Unknown status.' using errcode = '22023';
  end if;
  if p ? 'reasons' then
    rs := '{}';
    for r in select distinct trim(x) from jsonb_array_elements_text(coalesce(p -> 'reasons', '[]'::jsonb)) x where trim(x) <> '' loop
      if r = any(public.tenant_reason_builtin()) then
        rs := rs || r;
      elsif length(r) between 2 and 60 and p_by <> 'tenant' then
        rs := rs || r;
        insert into public.tenant_reason_options (label, created_by)
        select r, coalesce(p_actor, '') where not exists (select 1 from public.tenant_reason_options o where lower(o.label) = lower(r) and o.removed_at is null);
      end if;
    end loop;
  else
    rs := v.reasons;
  end if;
  if lk <> 'liked' then ls := ''; end if;
  if lk <> 'disliked' then rs := '{}'; end if;

  insert into public.property_view_responses (view_id, by_kind, actor, broker_id, visit, liked, liked_status, reasons, note, follow_up_on, said, at)
  values (v.id, p_by, left(coalesce(p_actor, ''), 120), p_broker, vis, lk, ls, rs, nt, fu, coalesce(p, '{}'::jsonb), coalesce(p_at, now()));

  wins := p_by = 'team' or v.response_by in ('', p_by) or (p_by = 'partner' and v.response_by = 'tenant');
  if wins then
    update public.property_tenant_views set
      visit = vis, liked = lk, liked_status = ls, reasons = rs, note = nt,
      follow_up_on = case when p_by = 'team' then fu else follow_up_on end,
      response_by = p_by, response_actor = left(coalesce(p_actor, ''), 120), response_at = coalesce(p_at, now()), updated_at = now()
    where id = v.id
    returning * into v;
  end if;
  return v;
end;
$$;

/** One view as the CRM, owner and partner screens read it. Internal. */
create or replace function public.tenant_view_json(v public.property_tenant_views)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', v.id, 'property_id', v.property_id, 'client_id', v.client_id, 'sources', v.sources,
    'first_at', v.first_at, 'last_at', v.last_at, 'opens', v.opens, 'seconds', v.seconds, 'photos', v.photos,
    'visit', v.visit, 'liked', v.liked, 'liked_status', v.liked_status, 'reasons', v.reasons, 'note', v.note,
    'response_by', v.response_by, 'response_actor', v.response_actor, 'response_at', v.response_at, 'follow_up_on', v.follow_up_on)
$$;

/** A property in a line: id, flat type, area, rent, unit and building. Internal. */
create or replace function public.tenant_view_property_json(p_property text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('property_id', i.property_id, 'flat_type', i.flat_type, 'area', i.area, 'rent', i.rent,
                            'status', i.status, 'unit_no', i.unit_no, 'building_id', i.building_id,
                            'building', (select b.name from public.owner_buildings b where b.id = i.building_id))
    from public.inventory i where i.property_id = p_property
$$;

/** The reasons typed so far, on offer everywhere. Internal. */
create or replace function public.tenant_reason_list()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'label', r.label) order by r.created_at), '[]'::jsonb)
    from public.tenant_reason_options r where r.removed_at is null
$$;

-- ── Where views come from ───────────────────────────────────────────────────

/** A page open: whose it is — the signed-in tenant's client, or the client this phone opened a sent link for. */
create or replace function public.flat_scans_fill_client()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.client_id is null then
    if new.user_id is not null then
      select c.id into new.client_id from public.crm_clients c where c.user_id = new.user_id;
    else
      select vc.client_id into new.client_id from public.visitor_clients vc where vc.visitor = new.visitor;
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists flat_scans_fill_client on public.flat_scans;
create trigger flat_scans_fill_client before insert or update on public.flat_scans
  for each row execute function public.flat_scans_fill_client();

/** …and onto their view: the opens, seconds and photos since last time. */
create or replace function public.tenant_views_from_scan()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  fresh boolean := tg_op = 'INSERT' or old.client_id is null;
  d_open int;
  d_sec  int;
begin
  if new.client_id is null then return null; end if;
  d_open := case when fresh then new.hits else new.hits - old.hits end;
  d_sec  := case when fresh then new.seconds else new.seconds - old.seconds end;
  if not fresh and d_open <= 0 and d_sec <= 0 and new.photos <= old.photos then return null; end if;
  perform public.tenant_view_touch(new.property_id, new.client_id, case when new.source = 'qr' then 'qr' else 'website' end,
                                   new.last_at, greatest(d_open, 0), greatest(d_sec, 0), new.photos);
  return null;
exception when others then
  raise warning 'tenant_views_from_scan: %', sqlerrm;
  return null;
end;
$$;
drop trigger if exists tenant_views_from_scan on public.flat_scans;
create trigger tenant_views_from_scan after insert or update on public.flat_scans
  for each row execute function public.tenant_views_from_scan();

/** A sent link opened, or the tenant swiped / booked on it. */
create or replace function public.tenant_views_from_shortlist()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  src text := case when new.share_token is not null or new.curated_share_id is not null then 'share' else 'website' end;
  vid uuid;
begin
  if new.opened_at is not null and (tg_op = 'INSERT' or old.opened_at is null or new.open_count is distinct from old.open_count) then
    perform public.tenant_view_touch(new.property_id, new.client_id, 'share', coalesce(new.last_opened_at, new.opened_at), 0, 0, 0, new.open_count);
  end if;
  if new.reacted_at is not null and (tg_op = 'INSERT' or new.reacted_at is distinct from old.reacted_at)
     and new.status in ('liked', 'disliked', 'okay', 'visit_scheduled', 'visited') then
    vid := public.tenant_view_touch(new.property_id, new.client_id, src, new.reacted_at);
    if vid is not null and new.status <> 'okay' then
      perform public.tenant_view_respond(vid, 'tenant', case when new.status like 'visit%' then 'visit' else 'swipe' end, null,
        case new.status when 'liked' then '{"liked": "liked"}' when 'disliked' then '{"liked": "disliked"}'
                        when 'visit_scheduled' then '{"visit": "pending"}' else '{"visit": "done"}' end::jsonb, new.reacted_at);
    end if;
  end if;
  return null;
exception when others then
  raise warning 'tenant_views_from_shortlist: %', sqlerrm;
  return null;
end;
$$;
drop trigger if exists tenant_views_from_shortlist on public.crm_shortlists;
create trigger tenant_views_from_shortlist after insert or update on public.crm_shortlists
  for each row execute function public.tenant_views_from_shortlist();

/** ♥ or ✕ on the website (the tenant's), or recorded by the team in the CRM (theirs). */
create or replace function public.tenant_views_from_reaction()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  cid uuid;
  vid uuid;
  crm boolean := coalesce(new.source, 'app') = 'crm';
begin
  if coalesce(new.source, 'app') = 'curated_link' then return null; end if; -- the shortlist's trigger has it
  if tg_op = 'UPDATE' and new.reaction = old.reaction then return null; end if;
  select c.id into cid from public.crm_clients c where c.user_id = new.user_id;
  vid := public.tenant_view_touch(new.property_id, cid, 'website', new.updated_at);
  if vid is not null then
    perform public.tenant_view_respond(vid, case when crm then 'team' else 'tenant' end,
      case when crm then coalesce(new.recorded_by, '') else 'website' end, null,
      jsonb_build_object('liked', case when new.reaction = 'like' then 'liked' else 'disliked' end), new.updated_at);
  end if;
  return null;
exception when others then
  raise warning 'tenant_views_from_reaction: %', sqlerrm;
  return null;
end;
$$;
drop trigger if exists tenant_views_from_reaction on public.listing_reactions;
create trigger tenant_views_from_reaction after insert or update on public.listing_reactions
  for each row execute function public.tenant_views_from_reaction();

/** The client a mobile belongs to — made if there isn't one (a number makes a lead). Internal. */
create or replace function public.tenant_client_for(p_user uuid, p_phone text, p_name text, p_source text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  ph  text := public.normalize_mobile(p_phone);
  cid uuid;
begin
  if p_user is not null then select id into cid from public.crm_clients where user_id = p_user; end if;
  if cid is null and ph ~ '^[6-9][0-9]{9}$' then
    select c.id into cid from public.crm_clients c
     where right(regexp_replace(coalesce(c.phone, ''), '\D', '', 'g'), 10) = ph
     order by c.created_at limit 1;
    if cid is null then
      insert into public.crm_clients (name, phone, source) values (left(coalesce(p_name, ''), 80), ph, p_source) returning id into cid;
    end if;
  end if;
  return cid;
end;
$$;

/** A visit asked for on a building's QR page: a view of each flat picked. */
create or replace function public.tenant_views_from_building_lead()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  cid uuid;
  pid text;
  vid uuid;
begin
  cid := public.tenant_client_for(new.user_id, new.phone, new.name, 'building_qr');
  foreach pid in array coalesce(new.property_ids, '{}') loop
    vid := public.tenant_view_touch(pid, cid, 'qr', new.created_at);
    if vid is not null and new.visit_at is not null then
      perform public.tenant_view_respond(vid, 'tenant', 'visit', null, '{"visit": "pending"}'::jsonb, new.created_at);
    end if;
  end loop;
  return null;
exception when others then
  raise warning 'tenant_views_from_building_lead: %', sqlerrm;
  return null;
end;
$$;
drop trigger if exists tenant_views_from_building_lead on public.owner_building_leads;
create trigger tenant_views_from_building_lead after insert on public.owner_building_leads
  for each row execute function public.tenant_views_from_building_lead();

/**
 * A building card (BR Homes) saved: its status is the team's response on each
 * of its flats. A save that came from one flat's response skips that flat.
 */
create or replace function public.tenant_views_from_track()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  pid  text;
  vid  uuid;
  skip text := coalesce(current_setting('mz.tv_from_view', true), '');
begin
  if new.client_id is null then return null; end if;
  if tg_op = 'UPDATE' and new.property_ids = old.property_ids and new.visit = old.visit and new.liked = old.liked
     and new.liked_status = old.liked_status and new.reasons = old.reasons
     and new.follow_up_on is not distinct from old.follow_up_on and new.note = old.note then
    return null;
  end if;
  foreach pid in array new.property_ids loop
    continue when pid = skip;
    vid := public.tenant_view_touch(pid, new.client_id, 'team', new.updated_at);
    if vid is not null then
      perform public.tenant_view_respond(vid, 'team', new.updated_by, null,
        jsonb_build_object('visit', new.visit, 'liked', new.liked, 'liked_status', new.liked_status, 'reasons', to_jsonb(new.reasons),
                           'note', new.note, 'follow_up_on', new.follow_up_on), new.updated_at);
    end if;
  end loop;
  return null;
end;
$$;
drop trigger if exists tenant_views_from_track on public.building_tenant_tracks;
create trigger tenant_views_from_track after insert or update on public.building_tenant_tracks
  for each row execute function public.tenant_views_from_track();

/** A client linked to an account: the pages that account opened are theirs now. */
create or replace function public.tenant_views_from_client()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.user_id is not null and (tg_op = 'INSERT' or old.user_id is distinct from new.user_id) then
    update public.flat_scans set client_id = new.id where user_id = new.user_id and client_id is null;
  end if;
  return null;
exception when others then
  raise warning 'tenant_views_from_client: %', sqlerrm;
  return null;
end;
$$;
drop trigger if exists tenant_views_from_client on public.crm_clients;
create trigger tenant_views_from_client after insert or update of user_id on public.crm_clients
  for each row execute function public.tenant_views_from_client();

-- ── The tenant's side (moveazy.co.in, signed out too) ───────────────────────

/**
 * A page opened from a link the team sent (?mz_s=…, or a curated shortlist's
 * token): this phone is that client's from now on, and so are its opens of
 * the last week.
 */
create or replace function public.tenant_visitor_link(p_token text, p_visitor text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v   text := left(trim(coalesce(p_visitor, '')), 64);
  cid uuid;
begin
  if length(v) < 8 or length(coalesce(p_token, '')) < 8 then return; end if;
  select client_id into cid from public.crm_shortlists where share_token = p_token;
  if cid is null then select client_id into cid from public.crm_curated_shares where token = p_token; end if;
  if cid is null then return; end if;
  insert into public.visitor_clients (visitor, client_id) values (v, cid)
  on conflict (visitor) do update set client_id = excluded.client_id, at = now();
  update public.flat_scans set client_id = cid
   where visitor = v and user_id is null and client_id is null
     and day >= (now() at time zone 'Asia/Kolkata')::date - 7;
end;
$$;

/** How long the page was open and how many photos they looked at (sent as they leave). */
create or replace function public.flat_view_engage(p_property text, p_visitor text, p_seconds int, p_photos int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  pid text := upper(trim(coalesce(p_property, '')));
  who text := coalesce(auth.uid()::text, left(trim(coalesce(p_visitor, '')), 64));
begin
  if length(who) < 8 then return; end if;
  update public.flat_scans set
    seconds = least(seconds + least(greatest(coalesce(p_seconds, 0), 0), 1800), 36000),
    photos  = greatest(photos, least(greatest(coalesce(p_photos, 0), 0), 200))
  where property_id = pid and visitor = who and day = (now() at time zone 'Asia/Kolkata')::date;
end;
$$;

-- ── The CRM ─────────────────────────────────────────────────────────────────

/** A property's tenant views: { views: [view + client: { id, name, phone }], reasons }. */
create or replace function public.crm_property_tenant_views(p_property text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'views', coalesce((select jsonb_agg(public.tenant_view_json(v) || jsonb_build_object('client',
                        jsonb_build_object('id', c.id, 'name', c.name, 'phone', public.normalize_mobile(c.phone))) order by v.last_at desc)
                         from public.property_tenant_views v join public.crm_clients c on c.id = v.client_id
                        where v.property_id = upper(trim(p_property))), '[]'::jsonb),
    'reasons', public.tenant_reason_list());
end;
$$;

/** A client's tenant views: { views: [view + property: {…}], reasons }. */
create or replace function public.crm_client_tenant_views(p_client uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'views', coalesce((select jsonb_agg(public.tenant_view_json(v) || jsonb_build_object('property', public.tenant_view_property_json(v.property_id))
                                        order by v.last_at desc)
                         from public.property_tenant_views v where v.client_id = p_client), '[]'::jsonb),
    'reasons', public.tenant_reason_list());
end;
$$;

/** The CRM's Tenant views page: the latest views (at most 1,500) with client and property, and the reasons. */
create or replace function public.crm_tenant_views()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'views', coalesce((select jsonb_agg(public.tenant_view_json(v)
                                        || jsonb_build_object('client', jsonb_build_object('id', c.id, 'name', c.name, 'phone', public.normalize_mobile(c.phone)),
                                                              'property', public.tenant_view_property_json(v.property_id))
                                        order by v.last_at desc)
                         from (select * from public.property_tenant_views order by last_at desc limit 1500) v
                         join public.crm_clients c on c.id = v.client_id), '[]'::jsonb),
    'reasons', public.tenant_reason_list());
end;
$$;

/** The bar on the CRM's home: views with no answer from the team (last 30 days), and follow-ups due. */
create or replace function public.crm_tenant_views_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'open', (select count(*) from public.property_tenant_views where response_by <> 'team' and last_at > now() - interval '30 days'),
    'due', (select count(*) from public.property_tenant_views where follow_up_on <= (now() at time zone 'Asia/Kolkata')::date));
end;
$$;

/** Every answer on one view, newest first. */
create or replace function public.crm_tenant_view_history(p_view uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('by', r.by_kind, 'actor', r.actor, 'visit', r.visit, 'liked', r.liked,
                                                       'liked_status', r.liked_status, 'reasons', r.reasons, 'note', r.note,
                                                       'follow_up_on', r.follow_up_on, 'at', r.at) order by r.at desc, r.id desc)
                     from public.property_view_responses r where r.view_id = p_view), '[]'::jsonb);
end;
$$;

/**
 * The team marks how a property went for a tenant: { visit, liked,
 * liked_status, reasons, note, follow_up_on }. On the client's history; on a
 * BR Homes flat, the building's card says the same. → the view.
 */
create or replace function public.crm_tenant_view_save(p_property text, p_client uuid, p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me   text := lower(coalesce(auth.jwt() ->> 'email', ''));
  pid  text := upper(trim(coalesce(p_property, '')));
  vid  uuid;
  v    public.property_tenant_views;
  c    public.crm_clients;
  bid  uuid;
  trk  public.building_tenant_tracks;
  ph   text;
begin
  if not public.has_admin_scope('crm.clients.write') then
    raise exception 'Needs permission to update clients.' using errcode = '42501';
  end if;
  select * into c from public.crm_clients where id = p_client;
  if c.id is null then raise exception 'That client isn''t there.' using errcode = '22023'; end if;
  select id into vid from public.property_tenant_views where property_id = pid and client_id = p_client;
  if vid is null then vid := public.tenant_view_touch(pid, p_client, 'team', now()); end if;
  if vid is null then raise exception 'That property can''t be marked for this client.' using errcode = '22023'; end if;
  v := public.tenant_view_respond(vid, 'team', me, null,
         jsonb_build_object('visit', coalesce(p ->> 'visit', ''), 'liked', coalesce(p ->> 'liked', ''),
                            'liked_status', coalesce(p ->> 'liked_status', ''), 'reasons', coalesce(p -> 'reasons', '[]'::jsonb),
                            'note', coalesce(p ->> 'note', ''), 'follow_up_on', p ->> 'follow_up_on'));

  -- BR Homes: the building's card carries it (and books the flat on Paid token).
  select b.id into bid from public.inventory i join public.owner_buildings b on b.id = i.building_id and b.tenant_tracker
   where i.property_id = pid;
  ph := public.normalize_mobile(c.phone);
  if bid is not null and ph ~ '^[6-9][0-9]{9}$' then
    select * into trk from public.building_tenant_tracks where building_id = bid and phone = ph;
    perform set_config('mz.tv_from_view', pid, true);
    perform public.crm_tenant_track_save(bid, jsonb_build_object(
      'phone', ph, 'name', coalesce(nullif(trk.name, ''), c.name, ''),
      'property_ids', to_jsonb(array(select distinct x from unnest(coalesce(trk.property_ids, '{}') || pid) x)),
      'note', case when v.note <> '' then v.note else coalesce(trk.note, '') end,
      'visit', case when v.visit = 'done' then 'done' else 'pending' end,
      'liked', v.liked, 'liked_status', v.liked_status, 'reasons', to_jsonb(v.reasons),
      'follow_up_on', coalesce(v.follow_up_on, trk.follow_up_on)));
    perform set_config('mz.tv_from_view', '', true);
  else
    insert into public.crm_activities (client_id, actor_email, type, body, meta)
    values (p_client, me, 'visit',
            pid || coalesce(' (' || nullif(concat_ws(', ', (select i.flat_type from public.inventory i where i.property_id = pid),
                                                     (select i.area from public.inventory i where i.property_id = pid)), '') || ')', '')
              || ' · ' || coalesce(nullif(public.tenant_response_text(v.visit, v.liked, v.liked_status, v.reasons), ''), 'No response')
              || case when v.follow_up_on is not null then ' · follow up ' || to_char(v.follow_up_on, 'DD Mon') else '' end
              || case when v.note <> '' then ' — ' || v.note else '' end,
            jsonb_build_object('property_id', pid, 'view_id', v.id, 'visit', v.visit, 'liked', v.liked,
                               'liked_status', v.liked_status, 'reasons', v.reasons));
  end if;
  return public.tenant_view_json(v);
end;
$$;

/**
 * The brokers who have this client, and everything each did with them — and
 * the flat the client came to them through, for the follow-up message.
 * [{ assignment_id, broker_id, broker_name, broker_phone, pack, status, assigned_at,
 *    follow_up_on, follow_up_note, first_flat: {…} | null, flats_seen, events: [{ kind, detail, actor, at }] }]
 */
create or replace function public.crm_client_broker_activity(p_client uuid)
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
             'assignment_id', a.id, 'broker_id', a.broker_id, 'broker_name', coalesce(nullif(b.name, ''), 'Partner'),
             'broker_phone', public.normalize_mobile(b.phone), 'pack', q.pack, 'status', a.status, 'assigned_at', a.assigned_at,
             'follow_up_on', a.follow_up_on, 'follow_up_note', a.follow_up_note,
             'first_flat', public.tenant_view_property_json(coalesce(
                 (select w.property_id from public.partner_website_interest w
                   where w.broker_id = a.broker_id and w.client_id = a.client_id order by w.created_at limit 1),
                 (select v.property_id from public.property_tenant_views v join public.partner_listings pl on pl.property_id = v.property_id
                   where pl.broker_id = a.broker_id and v.client_id = a.client_id order by v.first_at limit 1))),
             'flats_seen', (select count(*) from public.property_tenant_views v join public.partner_listings pl on pl.property_id = v.property_id
                             where pl.broker_id = a.broker_id and v.client_id = a.client_id),
             'events', coalesce((select jsonb_agg(jsonb_build_object('kind', e.kind, 'detail', e.detail, 'actor', e.actor, 'at', e.at)
                                                  order by e.at desc, e.id desc)
                                   from (select * from public.partner_lead_events e where e.assignment_id = a.id order by e.at desc limit 60) e), '[]'::jsonb))
           order by a.assigned_at)
      from public.partner_lead_assignments a
      join public.partner_lead_requests q on q.id = a.request_id
      left join public.broker_partners b on b.user_id = a.broker_id
     where a.client_id = p_client), '[]'::jsonb);
end;
$$;

/** The team sent the broker the follow-up on WhatsApp: on the broker's timeline and the client's history. */
create or replace function public.crm_broker_follow_up_log(p_assignment uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  me  text := lower(coalesce(auth.jwt() ->> 'email', ''));
  a   public.partner_lead_assignments;
  who text;
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  select * into a from public.partner_lead_assignments where id = p_assignment;
  if a.id is null then raise exception 'That lead isn''t there.' using errcode = '22023'; end if;
  select coalesce(nullif(b.name, ''), 'the partner') into who from public.broker_partners b where b.user_id = a.broker_id;
  insert into public.partner_lead_events (assignment_id, client_id, broker_id, kind, detail, actor)
  values (a.id, a.client_id, a.broker_id, 'team_follow_up', 'Asked for an update on WhatsApp', me);
  insert into public.crm_activities (client_id, actor_email, type, body, meta)
  values (a.client_id, me, 'whatsapp', 'Followed up with ' || coalesce(who, 'the partner') || ' on WhatsApp',
          jsonb_build_object('assignment_id', a.id, 'broker_id', a.broker_id));
end;
$$;

-- ── The partner's side ──────────────────────────────────────────────────────

/** Their calls and WhatsApps on a lead, kept with everything else they did. */
create or replace function public.partner_events_from_reachout()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.partner_lead_events (assignment_id, client_id, broker_id, kind, detail, at)
  values (new.assignment_id, new.client_id, new.broker_id, new.channel,
          case when new.channel = 'whatsapp' then 'WhatsApped them' else 'Called them' end, new.at);
  return null;
exception when others then
  return null;
end;
$$;
drop trigger if exists partner_events_from_reachout on public.partner_lead_reachouts;
create trigger partner_events_from_reachout after insert on public.partner_lead_reachouts
  for each row execute function public.partner_events_from_reachout();

/** …and every change of a lead's status. */
create or replace function public.partner_events_from_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status is distinct from old.status then
    insert into public.partner_lead_events (assignment_id, client_id, broker_id, kind, detail)
    values (new.id, new.client_id, new.broker_id, 'status',
            case new.status when 'assigned' then 'New' when 'contacted' then 'Contacted' when 'visit' then 'Visit'
                            when 'closed' then 'Closed' || coalesce(' · rent ₹' || new.closed_rent::bigint, '')
                            when 'not_interested' then 'Not interested' else new.status end);
  end if;
  return null;
exception when others then
  return null;
end;
$$;
drop trigger if exists partner_events_from_status on public.partner_lead_assignments;
create trigger partner_events_from_status after update of status on public.partner_lead_assignments
  for each row execute function public.partner_events_from_status();

/**
 * Per MovEazy lead of this partner: their follow-up, and the partner's flats
 * the tenant viewed — opens, when, and how it went (MovEazy's response, and
 * the partner's own last answer).
 * [{ assignment_id, follow_up_on, follow_up_note, flats: [{ property_id, flat_type, area, rent, opens, first_at, last_at,
 *     visit, liked, liked_status, reasons, response_by, mine: {…} | null }] }]
 */
create or replace function public.partner_lead_views()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'assignment_id', a.id, 'follow_up_on', a.follow_up_on, 'follow_up_note', a.follow_up_note,
           'flats', coalesce((
              select jsonb_agg(jsonb_build_object(
                       'property_id', v.property_id, 'flat_type', i.flat_type, 'area', i.area, 'rent', i.rent,
                       'opens', v.opens, 'first_at', v.first_at, 'last_at', v.last_at,
                       'visit', v.visit, 'liked', v.liked, 'liked_status', v.liked_status, 'reasons', v.reasons, 'response_by', v.response_by,
                       'mine', (select jsonb_build_object('visit', r.visit, 'liked', r.liked, 'liked_status', r.liked_status,
                                                          'reasons', r.reasons, 'at', r.at)
                                  from public.property_view_responses r
                                 where r.view_id = v.id and r.by_kind = 'partner' and r.broker_id = a.broker_id
                                 order by r.at desc, r.id desc limit 1))
                     order by v.last_at desc)
                from public.property_tenant_views v
                join public.partner_listings pl on pl.property_id = v.property_id and pl.broker_id = a.broker_id
                join public.inventory i on i.property_id = v.property_id
               where v.client_id = a.client_id), '[]'::jsonb))), '[]'::jsonb)
    from public.partner_lead_assignments a
   where a.broker_id = auth.uid() and public.is_approved_partner();
$$;

/** The partner sets the day to follow up with a lead, and a note. */
create or replace function public.partner_lead_follow_up(p_assignment uuid, p_on text, p_note text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a  public.partner_lead_assignments;
  fu date := case when coalesce(p_on, '') ~ '^\d{4}-\d{2}-\d{2}$' then p_on::date end;
  nt text := left(trim(coalesce(p_note, '')), 500);
  who text;
begin
  select * into a from public.partner_lead_assignments where id = p_assignment and broker_id = auth.uid();
  if a.id is null or not public.is_approved_partner() then
    raise exception 'That lead isn''t yours.' using errcode = '42501';
  end if;
  update public.partner_lead_assignments set follow_up_on = fu, follow_up_note = nt, updated_at = now() where id = a.id;
  select coalesce(nullif(b.name, ''), 'Partner') into who from public.broker_partners b where b.user_id = a.broker_id;
  insert into public.partner_lead_events (assignment_id, client_id, broker_id, kind, detail, actor)
  values (a.id, a.client_id, a.broker_id, 'follow_up',
          coalesce('Follow up on ' || to_char(fu, 'DD Mon'), 'Follow-up cleared') || case when nt <> '' then ' — ' || nt else '' end, coalesce(who, ''));
  return jsonb_build_object('follow_up_on', fu, 'follow_up_note', nt);
end;
$$;

/** The partner marks how one of their flats went for a lead: { visit, liked, liked_status, reasons }. */
create or replace function public.partner_view_respond(p_assignment uuid, p_property text, p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a   public.partner_lead_assignments;
  pid text := upper(trim(coalesce(p_property, '')));
  vid uuid;
  v   public.property_tenant_views;
  who text;
begin
  select * into a from public.partner_lead_assignments where id = p_assignment and broker_id = auth.uid();
  if a.id is null or not public.is_approved_partner() then
    raise exception 'That lead isn''t yours.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.partner_listings where property_id = pid and broker_id = a.broker_id) then
    raise exception 'That flat isn''t yours.' using errcode = '42501';
  end if;
  select coalesce(nullif(b.name, ''), 'Partner') into who from public.broker_partners b where b.user_id = a.broker_id;
  select id into vid from public.property_tenant_views where property_id = pid and client_id = a.client_id;
  if vid is null then vid := public.tenant_view_touch(pid, a.client_id, 'partner', now()); end if;
  if vid is null then raise exception 'That flat can''t be marked for this tenant.' using errcode = '22023'; end if;
  v := public.tenant_view_respond(vid, 'partner', coalesce(who, 'Partner'), a.broker_id,
         jsonb_build_object('visit', coalesce(p ->> 'visit', ''), 'liked', coalesce(p ->> 'liked', ''),
                            'liked_status', coalesce(p ->> 'liked_status', ''), 'reasons', coalesce(p -> 'reasons', '[]'::jsonb)));
  insert into public.partner_lead_events (assignment_id, client_id, broker_id, kind, detail, actor)
  select a.id, a.client_id, a.broker_id, 'response',
         pid || ' · ' || coalesce(nullif(public.tenant_response_text(r.visit, r.liked, r.liked_status, r.reasons), ''), 'No response'), coalesce(who, '')
    from public.property_view_responses r where r.view_id = vid order by r.id desc limit 1;
  insert into public.crm_activities (client_id, actor_email, type, body, meta)
  select a.client_id, '', 'system',
         coalesce(who, 'Partner') || ' marked ' || pid || ' · ' || coalesce(nullif(public.tenant_response_text(r.visit, r.liked, r.liked_status, r.reasons), ''), 'No response'),
         jsonb_build_object('assignment_id', a.id, 'broker_id', a.broker_id, 'property_id', pid, 'view_id', vid)
    from public.property_view_responses r where r.view_id = vid order by r.id desc limit 1;
  return public.tenant_view_json(v);
end;
$$;

-- ── The owner's side ────────────────────────────────────────────────────────

/**
 * (owner_qr_overview.sql) Now also the tenants who viewed the owner's flats
 * through MovEazy — a link the team sent, or the website — tagged via
 * 'moveazy', without their number or email (MovEazy's tenants). Someone who
 * reached the owner's QR keeps theirs. 'people' counts the QR ones (gave
 * contact); 'moveazy' the others; 'liked' / 'disliked' / 'reasons' read the
 * responses. status is the latest answer: a building card's or a flat's.
 */
create or replace function public.owner_qr_overview()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with me as (select auth.uid() as uid where public.is_approved_owner()),
  today as (select (now() at time zone 'Asia/Kolkata')::date as d),
  flats as (select l.property_id from public.owner_property_links l join me on l.owner_id = me.uid),
  blds as (select b.id, b.name from public.owner_buildings b join me on b.owner_id = me.uid),
  scans as (
    select 'flat'::text as kind, s.property_id as ref, s.day, s.hits, s.last_at, s.user_id, s.source = 'qr' as qr
      from public.flat_scans s join flats f on f.property_id = s.property_id
    union all
    select 'building', s.building_id::text, s.day, s.hits, s.last_at, s.user_id, true
      from public.owner_building_scans s join blds b on b.id = s.building_id),
  touches as (
    select s.user_id, null::text as phone, null::text as name, s.kind, s.ref, s.last_at as at, s.hits, false as visit,
           null::text as called, null::text as fb, null::text as note, null::uuid as trk, null::uuid as vw, s.qr
      from scans s where s.user_id is not null
    union all
    select v.user_id, null, null, 'flat', v.property_id, v.created_at, 0, true, null, null, null, null, null, false
      from public.visit_bookings v join flats f on f.property_id = v.property_id
     where coalesce(v.status, '') not ilike 'cancel%'
    union all
    select bl.user_id, bl.phone, bl.name, 'building', bl.building_id::text, bl.created_at, 0, true, null, null, null, null, null,
           bl.source <> 'ad' -- booked from a Meta ad page (visit_ad_pages.sql): MovEazy's, no number
      from public.owner_building_leads bl join blds b on b.id = bl.building_id
     where bl.status <> 'cancelled'
    union all
    -- Call Caretaker on the building's QR page (building_call_desk.sql).
    select e.user_id, e.phone, nullif(e.name, ''), 'building', e.building_id::text, e.created_at, 0, false,
           nullif(e.target, ''), nullif(e.feedback, ''), nullif(e.note, ''), null, null, true
      from public.building_call_events e join blds b on b.id = e.building_id
    union all
    -- Tenants the MovEazy team brought, and where each stands (building_tenant_tracks.sql).
    select null, k.phone, nullif(k.name, ''), 'building', k.building_id::text, k.updated_at, 0, k.visit = 'done',
           null, null, null, k.id, null, true
      from public.building_tenant_tracks k join blds b on b.id = k.building_id
    union all
    -- Tenants who viewed a flat through MovEazy, once we know who they are (tenant_views.sql).
    select c.user_id, nullif(public.normalize_mobile(c.phone), ''), nullif(c.name, ''), 'flat', v.property_id, v.last_at, 0,
           v.visit <> '', null, null, null, null, v.id, 'qr' = any(v.sources)
      from public.property_tenant_views v join flats f on f.property_id = v.property_id
      join public.crm_clients c on c.id = v.client_id),
  t as (
    select x.*, coalesce(x.user_id::text, 'tel:' || x.phone) as who
      from touches x, me
     where x.user_id is distinct from me.uid and (x.user_id is not null or x.phone is not null)),
  places as (
    select who, kind, ref, max(at) as at, sum(hits)::int as hits, bool_or(visit) as visit,
           coalesce(array_agg(distinct called) filter (where called is not null), '{}') as called
      from t group by who, kind, ref),
  people as (
    select p.who, max(p.at) as at, bool_or(p.visit) as visit,
           (select bool_or(t.qr) from t where t.who = p.who) as qr,
           jsonb_agg(jsonb_build_object('kind', p.kind, 'ref', p.ref, 'at', p.at, 'hits', p.hits, 'visit', p.visit, 'called', p.called)
                     order by p.at desc) as places
      from places p group by p.who),
  answers as (
    select x.who, x.visit, x.liked, x.liked_status, x.reasons, x.at,
           row_number() over (partition by x.who order by x.at desc) as n
      from (
        select t.who, k.visit, k.liked, k.liked_status, k.reasons, k.updated_at as at
          from t join public.building_tenant_tracks k on k.id = t.trk
        union all
        select t.who, v.visit, v.liked, v.liked_status, v.reasons, v.response_at
          from t join public.property_tenant_views v on v.id = t.vw
         where v.response_by <> '') x),
  status as (select * from answers where n = 1)
  select case when exists (select 1 from me) then jsonb_build_object(
    'scans',   (select coalesce(sum(s.hits), 0) from scans s),
    'week',    (select coalesce(sum(s.hits), 0) from scans s, today where s.day > today.d - 7),
    'by_day',  (select jsonb_agg(jsonb_build_object('day', g.d::date,
                                   'scans', (select coalesce(sum(s.hits), 0) from scans s where s.day = g.d::date)) order by g.d)
                  from today, generate_series(today.d - 13, today.d, interval '1 day') g(d)),
    'people',  (select count(*) from people where qr),
    'moveazy', (select count(*) from people where not qr),
    'visited', (select count(*) from people where visit),
    'liked',    (select count(*) from status where liked = 'liked'),
    'disliked', (select count(*) from status where liked = 'disliked'),
    'reasons', (select coalesce(jsonb_agg(jsonb_build_object('reason', r, 'n', n) order by n desc, r), '[]'::jsonb)
                  from (select r, count(*) as n from status, unnest(status.reasons) r where status.liked = 'disliked' group by r) z),
    'by_place', (
      select coalesce(jsonb_agg(x order by (x ->> 'scans')::int desc), '[]'::jsonb) from (
        select jsonb_build_object('kind', 'flat', 'ref', f.property_id, 'name', null,
                 'scans',  (select coalesce(sum(s.hits), 0) from scans s where s.kind = 'flat' and s.ref = f.property_id),
                 'week',   (select coalesce(sum(s.hits), 0) from scans s, today
                             where s.kind = 'flat' and s.ref = f.property_id and s.day > today.d - 7),
                 'people', (select count(*) from places pl where pl.kind = 'flat' and pl.ref = f.property_id)) as x
          from flats f
        union all
        select jsonb_build_object('kind', 'building', 'ref', b.id::text, 'name', b.name,
                 'scans',  (select coalesce(sum(s.hits), 0) from scans s where s.kind = 'building' and s.ref = b.id::text),
                 'week',   (select coalesce(sum(s.hits), 0) from scans s, today
                             where s.kind = 'building' and s.ref = b.id::text and s.day > today.d - 7),
                 'people', (select count(*) from places pl where pl.kind = 'building' and pl.ref = b.id::text))
          from blds b) q),
    'list', (
      select coalesce(jsonb_agg(row order by row ->> 'at' desc), '[]'::jsonb) from (
        select jsonb_build_object(
                 'key', md5(pe.who), 'user_id', case when pe.qr then u.id end, 'at', pe.at, 'visit', pe.visit, 'places', pe.places,
                 'via', case when pe.qr then 'qr' else 'moveazy' end,
                 'status', (select jsonb_build_object('visit', s.visit, 'liked', s.liked, 'liked_status', s.liked_status,
                                                       'reasons', s.reasons, 'at', s.at)
                              from status s where s.who = pe.who),
                 'feedback', coalesce((select jsonb_agg(jsonb_build_object('kind', t.fb, 'note', t.note, 'at', t.at, 'ref', t.ref) order by t.at desc)
                                        from t where t.who = pe.who and t.fb is not null), '[]'::jsonb),
                 'name', coalesce(nullif(trim(up.name), ''),
                                  (select t.name from t where t.who = pe.who and coalesce(t.name, '') <> '' order by t.at desc limit 1),
                                  case when pe.qr then split_part(coalesce(up.email, u.email, ''), '@', 1) end, 'Tenant'),
                 'phone', case when pe.qr then coalesce(nullif(trim(up.phone), ''), nullif(trim(ur.whatsapp), ''),
                                   (select t.phone from t where t.who = pe.who and t.phone is not null order by t.at desc limit 1), '') else '' end,
                 'email', case when pe.qr then coalesce(nullif(up.email, ''), u.email, '') else '' end,
                 'profile', (select jsonb_build_object(
                                'company', tp.current_company, 'past_company', tp.past_company, 'first_job', tp.first_job,
                                'college', tp.college, 'graduation_year', tp.graduation_year,
                                'linkedin', case when pe.qr then tp.linkedin end,
                                'in_bangalore_since', tp.in_bangalore_since, 'score', tp.score)
                               from public.tenant_profiles tp where tp.user_id = u.id)) as row
          from people pe
          left join auth.users u on pe.who not like 'tel:%' and u.id::text = pe.who
          left join public.user_profiles up on up.id = u.id
          left join public.user_requirements ur on ur.user_id = u.id
         order by pe.at desc
         limit 300) l)
  ) end;
$$;

/**
 * (building_tenants_board.sql) One building's tenants, now with the people who
 * viewed its flats through MovEazy: each row also has views (the flats they
 * viewed, how often, how it went), status (the card's, else the latest flat
 * answer) and via ('team' | 'qr' | 'moveazy'). For the owner (p_for_owner) a
 * MovEazy-only row has no number. key is stable either way.
 */
create or replace function public.building_tenants_board(p_building uuid, p_for_owner boolean)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with vw as (
    select v.*, public.normalize_mobile(c.phone) as phone, c.name as cname, i.unit_no
      from public.property_tenant_views v
      join public.inventory i on i.property_id = v.property_id and i.building_id = p_building
      join public.crm_clients c on c.id = v.client_id),
  phones as (
    select phone from public.building_tenant_tracks where building_id = p_building
    union
    select phone from public.building_call_events where building_id = p_building
    union
    select phone from vw where phone ~ '^[6-9][0-9]{9}$'),
  rows as (
    select ph.phone,
           (select t from public.building_tenant_tracks t where t.building_id = p_building and t.phone = ph.phone) as t,
           (select jsonb_build_object(
                     'first_at', min(e.created_at), 'last_at', max(e.created_at),
                     'asked', count(*) filter (where e.kind = 'contacts'),
                     'called', coalesce(to_jsonb(array_agg(distinct e.target) filter (where e.kind = 'call')), '[]'::jsonb),
                     'feedback', coalesce(jsonb_agg(jsonb_build_object('kind', e.feedback, 'note', e.note, 'at', e.created_at) order by e.created_at desc)
                                            filter (where e.kind = 'feedback'), '[]'::jsonb),
                     'name', (array_agg(e.name order by e.created_at desc) filter (where e.name <> ''))[1])
              from public.building_call_events e where e.building_id = p_building and e.phone = ph.phone
            having count(*) > 0) as qr,
           (select jsonb_agg(jsonb_build_object('property_id', v.property_id, 'unit_no', v.unit_no, 'opens', v.opens,
                                                'last_at', v.last_at, 'visit', v.visit, 'liked', v.liked, 'liked_status', v.liked_status,
                                                'reasons', v.reasons, 'response_by', v.response_by, 'response_at', v.response_at)
                             order by v.last_at desc)
              from vw v where v.phone = ph.phone) as views,
           (select max(v.last_at) from vw v where v.phone = ph.phone) as views_at,
           (select v.cname from vw v where v.phone = ph.phone and coalesce(v.cname, '') <> '' limit 1) as cname,
           (select bool_or('qr' = any(v.sources)) from vw v where v.phone = ph.phone) as view_qr,
           (select jsonb_build_object('visit', v.visit, 'liked', v.liked, 'liked_status', v.liked_status, 'reasons', v.reasons,
                                      'follow_up_on', v.follow_up_on, 'at', v.response_at)
              from vw v where v.phone = ph.phone and v.response_by <> '' order by v.response_at desc limit 1) as vstatus
      from phones ph),
  shaped as (
    select r.*, case when (r.t).id is not null then 'team' when r.qr is not null or coalesce(r.view_qr, false) then 'qr' else 'moveazy' end as via
      from rows r)
  select coalesce(jsonb_agg(x order by x ->> 'last_at' desc), '[]'::jsonb)
    from (
      select jsonb_build_object(
               'key', md5(r.phone),
               'phone', case when p_for_owner and r.via = 'moveazy' then null else r.phone end,
               'name', coalesce(nullif((r.t).name, ''), r.qr ->> 'name', nullif(r.cname, ''), ''),
               'last_at', greatest((r.t).updated_at, (r.qr ->> 'last_at')::timestamptz, r.views_at),
               'track', case when (r.t).id is not null then public.tenant_track_json(r.t) end,
               'qr', r.qr - 'name',
               'views', coalesce(r.views, '[]'::jsonb),
               'status', case when (r.t).id is not null
                              then jsonb_build_object('visit', (r.t).visit, 'liked', (r.t).liked, 'liked_status', (r.t).liked_status,
                                                      'reasons', (r.t).reasons, 'follow_up_on', (r.t).follow_up_on, 'at', (r.t).updated_at)
                              else r.vstatus end,
               'via', r.via) as x
        from shaped r) z;
$$;

/** (building_tenants_board.sql) The CRM's tenants page, with the MovEazy viewers. */
create or replace function public.crm_building_tenants(p_building uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  return (
    select jsonb_build_object(
      'building', jsonb_build_object('id', b.id, 'name', b.name, 'code', b.code, 'enabled', b.tenant_tracker),
      'tenants', public.building_tenants_board(b.id, false),
      'reasons', public.tenant_reason_list(),
      'flats', coalesce((select jsonb_agg(jsonb_build_object('property_id', i.property_id, 'unit_no', i.unit_no)
                                          order by i.unit_order nulls last, i.unit_no)
                           from public.inventory i where i.building_id = b.id), '[]'::jsonb))
    from public.owner_buildings b where b.id = p_building);
end;
$$;

/** (building_tenants_board.sql) The owner's view: MovEazy's tenants without their number. */
create or replace function public.owner_building_tenants(p_building uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select case when public.is_approved_owner() then (
    select jsonb_build_object('building', jsonb_build_object('id', b.id, 'name', b.name, 'code', b.code),
                              'tenants', public.building_tenants_board(b.id, true))
      from public.owner_buildings b where b.id = p_building and b.owner_id = auth.uid()) end;
$$;

/** (building_tenants_board.sql) The home bar counts the MovEazy viewers too. */
create or replace function public.crm_tracked_buildings()
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
             'id', b.id, 'name', b.name, 'code', b.code,
             'tenants', (select count(*) from (
                           select phone from public.building_tenant_tracks where building_id = b.id
                           union select phone from public.building_call_events where building_id = b.id
                           union select public.normalize_mobile(c.phone) from public.property_tenant_views v
                                   join public.inventory i on i.property_id = v.property_id and i.building_id = b.id
                                   join public.crm_clients c on c.id = v.client_id
                                  where public.normalize_mobile(c.phone) ~ '^[6-9][0-9]{9}$') p),
             'due', (select count(*) from public.building_tenant_tracks t
                      where t.building_id = b.id and t.follow_up_on <= (now() at time zone 'Asia/Kolkata')::date))
           order by b.name)
      from public.owner_buildings b where b.tenant_tracker), '[]'::jsonb);
end;
$$;

-- ── Once: everything already tracked becomes views ──────────────────────────
do $$
declare
  r   record;
  vid uuid;
begin
  if exists (select 1 from public.tenant_views_meta where key = 'backfill_v1') then return; end if;
  insert into public.tenant_views_meta (key) values ('backfill_v1');

  -- Signed-in opens (the scan trigger takes it from here).
  update public.flat_scans s set client_id = c.id
    from public.crm_clients c
   where s.client_id is null and s.user_id is not null and c.user_id = s.user_id;

  -- Links the team sent, opened; swipes and bookings on them.
  for r in select * from public.crm_shortlists where opened_at is not null loop
    perform public.tenant_view_touch(r.property_id, r.client_id, 'share', coalesce(r.last_opened_at, r.opened_at), 0, 0, 0, r.open_count);
  end loop;
  for r in select * from public.crm_shortlists where reacted_at is not null and status in ('liked', 'disliked', 'okay', 'visit_scheduled', 'visited') loop
    vid := public.tenant_view_touch(r.property_id, r.client_id,
             case when r.share_token is not null or r.curated_share_id is not null then 'share' else 'website' end, r.reacted_at);
    if vid is not null and r.status <> 'okay' then
      perform public.tenant_view_respond(vid, 'tenant', case when r.status like 'visit%' then 'visit' else 'swipe' end, null,
        case r.status when 'liked' then '{"liked": "liked"}' when 'disliked' then '{"liked": "disliked"}'
                      when 'visit_scheduled' then '{"visit": "pending"}' else '{"visit": "done"}' end::jsonb, r.reacted_at);
    end if;
  end loop;

  -- ♥ / ✕ on the website.
  for r in select lr.*, c.id as cid from public.listing_reactions lr join public.crm_clients c on c.user_id = lr.user_id
            where coalesce(lr.source, 'app') <> 'curated_link' order by lr.updated_at loop
    vid := public.tenant_view_touch(r.property_id, r.cid, 'website', r.updated_at);
    if vid is not null then
      perform public.tenant_view_respond(vid, case when r.source = 'crm' then 'team' else 'tenant' end,
        case when r.source = 'crm' then coalesce(r.recorded_by, '') else 'website' end, null,
        jsonb_build_object('liked', case when r.reaction = 'like' then 'liked' else 'disliked' end), r.updated_at);
    end if;
  end loop;

  -- Visits asked for on a building's QR page.
  for r in select * from public.owner_building_leads order by created_at loop
    vid := null;
    declare
      cid uuid := public.tenant_client_for(r.user_id, r.phone, r.name, 'building_qr');
      pid text;
    begin
      foreach pid in array coalesce(r.property_ids, '{}') loop
        vid := public.tenant_view_touch(pid, cid, 'qr', r.created_at);
        if vid is not null and r.visit_at is not null then
          perform public.tenant_view_respond(vid, 'tenant', 'visit', null, '{"visit": "pending"}'::jsonb, r.created_at);
        end if;
      end loop;
    end;
  end loop;

  -- BR Homes cards.
  for r in select * from public.building_tenant_tracks where client_id is not null order by updated_at loop
    declare pid text;
    begin
      foreach pid in array r.property_ids loop
        vid := public.tenant_view_touch(pid, r.client_id, 'team', r.updated_at);
        if vid is not null then
          perform public.tenant_view_respond(vid, 'team', r.updated_by, null,
            jsonb_build_object('visit', r.visit, 'liked', r.liked, 'liked_status', r.liked_status, 'reasons', to_jsonb(r.reasons),
                               'note', r.note, 'follow_up_on', r.follow_up_on), r.updated_at);
        end if;
      end loop;
    end;
  end loop;

  -- What partners already did.
  insert into public.partner_lead_events (assignment_id, client_id, broker_id, kind, detail, at)
  select x.assignment_id, x.client_id, x.broker_id, x.channel,
         case when x.channel = 'whatsapp' then 'WhatsApped them' else 'Called them' end, x.at
    from public.partner_lead_reachouts x;
  insert into public.partner_lead_events (assignment_id, client_id, broker_id, kind, detail, at)
  select a.id, a.client_id, a.broker_id, 'status', initcap(replace(ac.meta ->> 'status', '_', ' ')), ac.created_at
    from public.crm_activities ac
    join public.partner_lead_assignments a
      on a.id = case when ac.meta ->> 'assignment_id' ~ '^[0-9a-f-]{36}$' then (ac.meta ->> 'assignment_id')::uuid end
   where ac.meta ? 'status';
end $$;

-- ── Grants ───────────────────────────────────────────────────────────────────
do $$
declare f text;
begin
  foreach f in array array[
    'public.tenant_response_text(text, text, text, text[])',
    'public.tenant_view_touch(text, uuid, text, timestamptz, int, int, int, int)',
    'public.tenant_view_respond(uuid, text, text, uuid, jsonb, timestamptz)',
    'public.tenant_view_json(public.property_tenant_views)', 'public.tenant_view_property_json(text)', 'public.tenant_reason_list()',
    'public.tenant_client_for(uuid, text, text, text)', 'public.building_tenants_board(uuid, boolean)',
    'public.flat_scans_fill_client()', 'public.tenant_views_from_scan()', 'public.tenant_views_from_shortlist()',
    'public.tenant_views_from_reaction()', 'public.tenant_views_from_building_lead()', 'public.tenant_views_from_track()',
    'public.tenant_views_from_client()', 'public.partner_events_from_reachout()', 'public.partner_events_from_status()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
  foreach f in array array['public.tenant_visitor_link(text, text)', 'public.flat_view_engage(text, text, int, int)'] loop
    execute format('revoke all on function %s from public', f);
    execute format('grant execute on function %s to anon, authenticated', f);
  end loop;
  foreach f in array array[
    'public.crm_property_tenant_views(text)', 'public.crm_client_tenant_views(uuid)', 'public.crm_tenant_views()',
    'public.crm_tenant_views_summary()', 'public.crm_tenant_view_history(uuid)', 'public.crm_tenant_view_save(text, uuid, jsonb)',
    'public.crm_client_broker_activity(uuid)', 'public.crm_broker_follow_up_log(uuid)',
    'public.partner_lead_views()', 'public.partner_lead_follow_up(uuid, text, text)', 'public.partner_view_respond(uuid, text, jsonb)',
    'public.owner_qr_overview()', 'public.crm_building_tenants(uuid)', 'public.owner_building_tenants(uuid)', 'public.crm_tracked_buildings()'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

commit;
