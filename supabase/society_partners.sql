-- ─────────────────────────────────────────────────────────────────────────────
-- Society partners: partners who onboard gated societies from the partner app,
-- the CRM's review, the societies tenants then see, and the leads they send
-- (MovEazy-FE pages/partners/Societies*.jsx, pages/find/Societ*.jsx,
-- pages/crm/CrmSocietyLeadsPage.jsx, lib/societyPartners.js).
--
-- Run in the Supabase SQL editor AFTER society_prospects.sql, partner_schema.sql
-- (is_approved_partner), partner_launch.sql (partner_notifications),
-- crm_payments.sql (crm_notifications), crm_follow_ups.sql (crm_team_emails),
-- lead_intake.sql and lead_types.sql. Safe to re-run.
--
--   CRM → Partners turns a partner into a society partner. They see the
--   societies near them (our prospects, nearest first) and can add one that's
--   missing. Starting one locks it to them for 7 days; unfinished after that,
--   another partner may take it (what was saved stays). They add, saved as they
--   go: the property manager's number, guards, brokers, the amenities (each
--   with a photo taken there — within ~300 m of the society) and a sample flat
--   (5+ photos), and, when they can, rent ranges per flat type. Draft until all
--   of it is in; then Submitted → the CRM approves (the society goes live for
--   tenants) or sends it back with a note.
--
--   A live society has a page on moveazy.co.in. A tenant who asks for flats
--   there (number verified first) becomes a society lead for the partner who
--   onboarded it: WhatsApp opens to that partner, the partner is notified in
--   their app (and asked to upload a flat there for this tenant), and the CRM
--   is told. The partner moves the lead along — called, visit set, visit done,
--   closed or lost — and CRM → Society leads shows every step.
--
--   The numbers a partner saves (manager, guards, brokers) are seen only by
--   that partner and the CRM.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

/* ── Who is a society partner ─────────────────────────────────────────────── */

alter table public.broker_partners add column if not exists society_partner boolean not null default false;

/* ── Onboarding, on the society ───────────────────────────────────────────── */

alter table public.society_prospects add column if not exists onboard_by uuid references auth.users (id) on delete set null;
alter table public.society_prospects add column if not exists onboard_status text;
alter table public.society_prospects add column if not exists onboard_started_at timestamptz;
alter table public.society_prospects add column if not exists onboard_locked_until timestamptz;
alter table public.society_prospects add column if not exists onboard_note text not null default '';
alter table public.society_prospects add column if not exists submitted_at timestamptz;
alter table public.society_prospects add column if not exists decided_at timestamptz;
alter table public.society_prospects add column if not exists decided_by text not null default '';
alter table public.society_prospects add column if not exists partner_amenities text[] not null default '{}';
alter table public.society_prospects add column if not exists amenity_photos jsonb not null default '{}';   -- { amenity: [{ url, lat, lng, at }] }
alter table public.society_prospects add column if not exists flat_photos jsonb not null default '[]';      -- [{ slot, url, lat, lng, at }]
alter table public.society_prospects add column if not exists partner_rents jsonb not null default '{}';    -- { "1": [min, max], ... }
alter table public.society_prospects add column if not exists live boolean not null default false;
alter table public.society_prospects add column if not exists public_code text;
alter table public.society_prospects add column if not exists added_by_partner boolean not null default false;
create unique index if not exists society_prospects_public_code_key on public.society_prospects (public_code) where public_code is not null;
create index if not exists society_prospects_onboard_idx on public.society_prospects (onboard_by, onboard_status);

do $$ begin
  if exists (select 1 from pg_constraint where conname = 'society_prospects_road_check') then
    alter table public.society_prospects drop constraint society_prospects_road_check;
  end if;
  alter table public.society_prospects add constraint society_prospects_road_check
    check (road ~ '^[a-z][a-z0-9_]{1,23}$');
  if not exists (select 1 from pg_constraint where conname = 'society_prospects_onboard_status_check') then
    alter table public.society_prospects add constraint society_prospects_onboard_status_check
      check (onboard_status is null or onboard_status in ('draft', 'submitted', 'sent_back', 'approved'));
  end if;
end $$;

alter table public.society_prospect_contacts add column if not exists partner_id uuid references auth.users (id) on delete set null;
-- A number a partner removed (or replaced) stays for the CRM: removed_at / removed_by ('partner:<id>' or 'partner:<id>:changed').
alter table public.society_prospect_contacts add column if not exists removed_at timestamptz;
alter table public.society_prospect_contacts add column if not exists removed_by text not null default '';
do $$ begin
  if exists (select 1 from pg_constraint where conname = 'society_prospect_contacts_source_check') then
    alter table public.society_prospect_contacts drop constraint society_prospect_contacts_source_check;
  end if;
  alter table public.society_prospect_contacts add constraint society_prospect_contacts_source_check
    check (source in ('team', 'google', 'partner'));
end $$;

-- Partner notifications gain two kinds: 'society' (switched on, approved, sent
-- back) and 'society_lead' (a tenant asked for flats). The kinds already
-- allowed are read off the existing check and kept.
do $$
declare
  d    text;
  vals text[];
begin
  select pg_get_constraintdef(oid) into d from pg_constraint where conname = 'partner_notifications_kind_check';
  if d is not null and position('society_lead' in d) = 0 then
    vals := array(select m[1] from regexp_matches(d, '''([a-z_]+)''', 'g') m) || array['society', 'society_lead'];
    alter table public.partner_notifications drop constraint partner_notifications_kind_check;
    execute format('alter table public.partner_notifications add constraint partner_notifications_kind_check check (kind = any (%L::text[]))', vals);
  end if;
end $$;

/* ── Society leads ────────────────────────────────────────────────────────── */

create table if not exists public.society_leads (
  id          uuid primary key default gen_random_uuid(),
  prospect_id uuid not null references public.society_prospects (id) on delete cascade,
  partner_id  uuid references auth.users (id) on delete set null,
  client_id   uuid references public.crm_clients (id) on delete set null,
  name        text not null default '',
  phone       text not null default '',
  stage       text not null default 'new' check (stage in ('new', 'called', 'visit_set', 'visit_done', 'closed', 'lost')),
  stage_at    timestamptz not null default now(),
  last_note   text not null default '',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists society_leads_partner_idx on public.society_leads (partner_id, created_at desc);
create index if not exists society_leads_prospect_idx on public.society_leads (prospect_id, created_at desc);

create table if not exists public.society_lead_events (
  id      bigint generated always as identity primary key,
  lead_id uuid not null references public.society_leads (id) on delete cascade,
  at      timestamptz not null default now(),
  actor   text not null default '',
  kind    text not null default 'note',
  body    text not null default ''
);
create index if not exists society_lead_events_idx on public.society_lead_events (lead_id, at);

alter table public.society_leads enable row level security;
alter table public.society_lead_events enable row level security;
revoke all on public.society_leads from anon, authenticated;
revoke all on public.society_lead_events from anon, authenticated;

/* ── Helpers ──────────────────────────────────────────────────────────────── */

/** The amenities a partner ticks from (plus their own "other"). */
create or replace function public.society_amenity_list()
returns text[]
language sql
immutable
as $$
  select array['Swimming pool', 'Gym', 'Clubhouse', 'Kids'' play area', 'Tennis court', 'Badminton court', 'Basketball court',
               'Squash court', 'Jogging track', 'Indoor games', 'Party hall', 'Yoga / meditation deck', 'Library',
               'Power backup', '24×7 security', 'CCTV', 'Lift', 'Covered parking', 'Visitor parking', 'Supermarket inside',
               'Landscaped garden', 'Pet park', 'Rainwater harvesting', 'Sewage treatment plant', 'EV charging', 'Intercom'];
$$;

/** The sample flat's photo slots, in the order the app asks for them. */
create or replace function public.society_flat_slots()
returns text[]
language sql
immutable
as $$
  select array['living', 'bedroom', 'kitchen', 'bathroom', 'balcony', 'other'];
$$;

/** Metres between two points. */
create or replace function public.sp_metres(lat1 numeric, lng1 numeric, lat2 numeric, lng2 numeric)
returns numeric
language sql
immutable
as $$
  select 6371000 * 2 * asin(sqrt(
    power(sin(radians((lat2 - lat1) / 2)), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians((lng2 - lng1) / 2)), 2)));
$$;

/** Is the caller an approved society partner? */
create or replace function public.is_society_partner()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and exists (
    select 1 from public.broker_partners p where p.user_id = auth.uid() and p.status = 'approved' and p.society_partner);
$$;

create or replace function public.sp_require()
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_society_partner() then
    raise exception 'Societies are for MovEazy society partners. Ask the MovEazy team to switch it on for you.' using errcode = '42501';
  end if;
  return auth.uid();
end;
$$;

/** A partner's display name. */
create or replace function public.sp_partner_name(p uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(nullif(trim(bp.name), ''), 'A MovEazy partner') from public.broker_partners bp where bp.user_id = p;
$$;

/** A partner's live numbers at a society, by kind: { manager, guard, broker }. */
create or replace function public.sp_contact_counts(p_id uuid, p_partner uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'manager', count(*) filter (where c.kind = 'manager'),
    'guard', count(*) filter (where c.kind = 'guard'),
    'broker', count(*) filter (where c.kind = 'broker'))
  from public.society_prospect_contacts c
  where c.prospect_id = p_id and c.partner_id = p_partner and c.removed_at is null;
$$;

/** The society, if the caller is onboarding it or has onboarded it (any status) — for its numbers. */
create or replace function public.sp_owned(p_id uuid)
returns public.society_prospects
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := public.sp_require();
  s  public.society_prospects;
begin
  select * into s from public.society_prospects where id = p_id for update;
  if s.id is null then raise exception 'No such society.' using errcode = '22023'; end if;
  if s.onboard_by is distinct from me then raise exception 'Start onboarding this society first.' using errcode = '42501'; end if;
  return s;
end;
$$;

/** What's still missing before a society can be submitted. */
create or replace function public.sp_missing(p_id uuid)
returns text[]
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  s   public.society_prospects;
  out text[] := '{}';
  a   text;
begin
  select * into s from public.society_prospects where id = p_id;
  -- At least one number — the manager's, a guard's or a broker's (more are advised, not required).
  if not exists (select 1 from public.society_prospect_contacts c where c.prospect_id = p_id and c.kind in ('manager', 'guard', 'broker')
                    and c.partner_id = s.onboard_by and c.removed_at is null) then
    out := out || 'At least one number: the society manager, a security guard or a broker'::text;
  end if;
  if cardinality(s.partner_amenities) = 0 then
    out := out || 'The amenities'::text;
  else
    foreach a in array s.partner_amenities loop
      if jsonb_array_length(coalesce(s.amenity_photos -> a, '[]'::jsonb)) = 0 then
        out := out || format('A photo of the %s', lower(a));
      end if;
    end loop;
  end if;
  if jsonb_array_length(s.flat_photos) < 5 then
    out := out || format('%s more photo%s of a sample flat', 5 - jsonb_array_length(s.flat_photos),
                         case when 5 - jsonb_array_length(s.flat_photos) = 1 then '' else 's' end);
  end if;
  return out;
end;
$$;

/** One society as its onboarding partner sees it (their own numbers only). */
create or replace function public.sp_json(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', s.id, 'name', s.name, 'area', s.area, 'road', s.road, 'address', s.address, 'lat', s.lat, 'lng', s.lng,
    'status', s.onboard_status, 'mine', s.onboard_by = auth.uid(), 'locked_until', s.onboard_locked_until,
    'started_at', s.onboard_started_at, 'note', s.onboard_note, 'submitted_at', s.submitted_at, 'live', s.live,
    'public_code', s.public_code, 'amenities', s.partner_amenities, 'amenity_photos', s.amenity_photos,
    'flat_photos', s.flat_photos, 'rents', s.partner_rents, 'research_amenities', s.amenities,
    'facts', s.facts, 'added_by_partner', s.added_by_partner,
    'contacts', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'kind', c.kind, 'name', c.name, 'phone', c.phone, 'note', c.note)
                                    order by array_position(array['manager', 'guard', 'broker'], c.kind), c.created_at)
                            from public.society_prospect_contacts c where c.prospect_id = s.id and c.partner_id = auth.uid() and c.removed_at is null), '[]'::jsonb),
    'contact_counts', public.sp_contact_counts(s.id, auth.uid()),
    'missing', public.sp_missing(s.id),
    'leads', (select count(*) from public.society_leads l where l.prospect_id = s.id and l.partner_id = auth.uid()),
    'amenity_list', to_jsonb(public.society_amenity_list()),
    'flat_slots', to_jsonb(public.society_flat_slots()))
  from public.society_prospects s where s.id = p_id;
$$;

/** The society, editable by the caller (their draft, or sent back to them). */
create or replace function public.sp_editable(p_id uuid)
returns public.society_prospects
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := public.sp_require();
  s  public.society_prospects;
begin
  select * into s from public.society_prospects where id = p_id for update;
  if s.id is null then raise exception 'No such society.' using errcode = '22023'; end if;
  if s.onboard_by is distinct from me then raise exception 'Start onboarding this society first.' using errcode = '42501'; end if;
  if s.onboard_status not in ('draft', 'sent_back') then
    raise exception 'This society is %.', case s.onboard_status when 'submitted' then 'with the MovEazy team for review' else 'already approved' end
      using errcode = '22023';
  end if;
  return s;
end;
$$;

/* ── Partner app ──────────────────────────────────────────────────────────── */

/** Societies near a spot (or all, when no spot), nearest first, with who has each. */
create or replace function public.partner_societies_nearby(p_lat numeric, p_lng numeric)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  me uuid := public.sp_require();
begin
  return coalesce((
    select jsonb_agg(x.j order by x.d nulls last, x.name)
      from (
        select s.name, case when p_lat is null or s.lat is null then null else public.sp_metres(p_lat, p_lng, s.lat, s.lng) end d,
               jsonb_build_object(
                 'id', s.id, 'name', s.name, 'area', s.area, 'road', s.road, 'lat', s.lat, 'lng', s.lng,
                 'metres', case when p_lat is null or s.lat is null then null else round(public.sp_metres(p_lat, p_lng, s.lat, s.lng)) end,
                 'state', case
                   when s.onboard_status = 'approved' then case when s.onboard_by = me then 'mine_live' else 'onboarded' end
                   when s.onboard_by = me then 'mine'
                   when s.onboard_status = 'submitted' then 'onboarded'
                   when s.onboard_by is not null and s.onboard_locked_until > now() then 'locked'
                   else 'open' end,
                 'status', case when s.onboard_by = me then s.onboard_status end,
                 'by', case when s.onboard_by is not null and s.onboard_by <> me
                             and (s.onboard_status in ('submitted', 'approved') or s.onboard_locked_until > now())
                            then public.sp_partner_name(s.onboard_by) end,
                 'locked_until', case when s.onboard_by <> me then s.onboard_locked_until end,
                 -- For the map's preview card: the first amenities and the rents (the partner's, else research).
                 'amenities', to_jsonb(coalesce(s.amenities[1:6], '{}'::text[])),
                 'amenity_count', coalesce(cardinality(s.amenities), 0),
                 'rents', case when coalesce(s.partner_rents, '{}'::jsonb) <> '{}'::jsonb then s.partner_rents else coalesce(s.rents, '{}'::jsonb) end,
                 'contact_counts', case when s.onboard_by = me then public.sp_contact_counts(s.id, me) end) j
          from public.society_prospects s
         where not s.hidden and s.lat is not null
         order by 2 nulls last, s.name
         limit 120
      ) x), '[]'::jsonb);
end;
$$;

/** The societies this partner has started, submitted or onboarded. */
create or replace function public.partner_my_societies()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  me uuid := public.sp_require();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', s.id, 'name', s.name, 'area', s.area, 'status', s.onboard_status, 'locked_until', s.onboard_locked_until,
             'note', s.onboard_note, 'live', s.live, 'public_code', s.public_code,
             'missing', cardinality(public.sp_missing(s.id)),
             'cover', coalesce(s.flat_photos -> 0 ->> 'url', ''),
             'leads', (select count(*) from public.society_leads l where l.prospect_id = s.id and l.partner_id = me),
             'new_leads', (select count(*) from public.society_leads l where l.prospect_id = s.id and l.partner_id = me and l.stage = 'new'),
             'contact_counts', public.sp_contact_counts(s.id, me))
           order by array_position(array['sent_back', 'draft', 'submitted', 'approved'], s.onboard_status), s.onboard_started_at desc)
      from public.society_prospects s where s.onboard_by = me), '[]'::jsonb);
end;
$$;

create or replace function public.partner_society_get(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  me uuid := public.sp_require();
begin
  if not exists (select 1 from public.society_prospects where id = p_id and onboard_by = me) then
    raise exception 'Start onboarding this society first.' using errcode = '42501';
  end if;
  return public.sp_json(p_id);
end;
$$;

/** Start (or pick back up) onboarding a society: it's yours for 7 days. */
create or replace function public.partner_society_start(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := public.sp_require();
  s  public.society_prospects;
begin
  select * into s from public.society_prospects where id = p_id and not hidden for update;
  if s.id is null then raise exception 'No such society.' using errcode = '22023'; end if;
  if s.onboard_by is distinct from me then
    if s.onboard_status in ('submitted', 'approved') then
      raise exception '% has already onboarded this society.', public.sp_partner_name(s.onboard_by) using errcode = '22023';
    end if;
    if s.onboard_by is not null and s.onboard_locked_until > now() then
      raise exception '% is onboarding this society until %.', public.sp_partner_name(s.onboard_by),
        to_char(s.onboard_locked_until at time zone 'Asia/Kolkata', 'DD Mon') using errcode = '22023';
    end if;
    update public.society_prospects set onboard_by = me, onboard_status = 'draft', onboard_started_at = now(),
           onboard_locked_until = now() + interval '7 days', onboard_note = '', updated_at = now()
     where id = p_id;
  elsif s.onboard_status = 'draft' and coalesce(s.onboard_locked_until, now()) < now() + interval '1 day' then
    -- Their own draft: back on it, for another 7 days from now.
    update public.society_prospects set onboard_locked_until = now() + interval '7 days', updated_at = now() where id = p_id;
  end if;
  return public.sp_json(p_id);
end;
$$;

/** A society that isn't on the map: name, and the spot the partner is standing at. */
create or replace function public.partner_society_add(p_name text, p_lat numeric, p_lng numeric, p_area text default '', p_road text default 'other')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me  uuid := public.sp_require();
  nm  text := regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g');
  dup record;
  pid uuid;
begin
  if length(nm) < 3 then raise exception 'Give the society''s name.' using errcode = '22023'; end if;
  if p_lat is null or p_lng is null or p_lat not between 12.6 and 13.3 or p_lng not between 77.3 and 77.95 then
    raise exception 'Turn on location and stand at the society to add it.' using errcode = '22023';
  end if;
  select s.id, s.name into dup from public.society_prospects s
   where not s.hidden and s.lat is not null and public.sp_metres(p_lat, p_lng, s.lat, s.lng) < 250
     and (lower(s.name) like '%' || lower(split_part(nm, ' ', 1)) || '%' or lower(nm) like '%' || lower(split_part(s.name, ' ', 1)) || '%')
   limit 1;
  if dup.id is not null then
    raise exception '% is already on the map right here — open it from the list.', dup.name using errcode = '23505';
  end if;
  insert into public.society_prospects (name, road, area, lat, lng, added_by_partner, created_by, updated_by)
  values (left(nm, 120), case when p_road ~ '^[a-z][a-z0-9_]{1,23}$' then p_road else 'other' end,
          left(coalesce(p_area, ''), 80), p_lat, p_lng, true, 'partner:' || me, 'partner:' || me)
  returning id into pid;
  return public.partner_society_start(pid);
end;
$$;

/**
 * Amenities ticked, and rent ranges per flat type (optional). Once the society
 * is live, only the rents can still change — they go straight onto its page.
 */
create or replace function public.partner_society_save(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me   uuid := public.sp_require();
  s    public.society_prospects;
  v_am text[];
  v_rents jsonb := '{}'::jsonb;
  k    text;
  lo   numeric;
  hi   numeric;
begin
  select * into s from public.society_prospects where id = nullif(p ->> 'id', '')::uuid and onboard_by = me;
  if s.onboard_status = 'approved' then
    if p ? 'amenities' then raise exception 'Amenities are set once a society is live — ask the MovEazy team to change them.' using errcode = '22023'; end if;
  else
    s := public.sp_editable(nullif(p ->> 'id', '')::uuid);
  end if;
  if jsonb_typeof(p -> 'amenities') = 'array' then
    v_am := array(select distinct left(trim(x), 50) from jsonb_array_elements_text(p -> 'amenities') x where trim(x) <> '' limit 40);
    update public.society_prospects set partner_amenities = v_am,
           -- A photo of an amenity they've unticked goes with it.
           amenity_photos = coalesce((select jsonb_object_agg(e.key, e.value) from jsonb_each(amenity_photos) e where e.key = any(v_am)), '{}'::jsonb)
     where id = s.id;
  end if;
  if jsonb_typeof(p -> 'rents') = 'object' then
    for k in select jsonb_object_keys(p -> 'rents') loop
      continue when k not in ('1rk', '1', '2', '3', '4');
      lo := nullif(p -> 'rents' -> k ->> 0, '')::numeric;
      hi := nullif(p -> 'rents' -> k ->> 1, '')::numeric;
      continue when lo is null and hi is null;
      if coalesce(lo, hi) < 3000 or coalesce(hi, lo) > 1000000 or (lo is not null and hi is not null and lo > hi) then
        raise exception 'Check the rent for %: min below max, in rupees a month.', case k when '1rk' then '1 RK' else k || ' BHK' end using errcode = '22023';
      end if;
      v_rents := v_rents || jsonb_build_object(k, jsonb_build_array(coalesce(lo, hi), coalesce(hi, lo)));
    end loop;
    update public.society_prospects set partner_rents = v_rents,
           rents = case when onboard_status = 'approved' then rents || v_rents else rents end
     where id = s.id;
  end if;
  update public.society_prospects set updated_at = now(), updated_by = 'partner:' || auth.uid() where id = s.id;
  return public.sp_json(s.id);
end;
$$;

/** Add or change one of the partner's numbers: { id?, society_id, kind manager|guard|broker, name, phone }. */
create or replace function public.partner_society_contact_save(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  cid uuid := nullif(p ->> 'id', '')::uuid;
  s   public.society_prospects := public.sp_owned(nullif(p ->> 'society_id', '')::uuid);
  ph  text := public.normalize_mobile(coalesce(p ->> 'phone', ''));
  old public.society_prospect_contacts;
begin
  if coalesce(p ->> 'kind', '') not in ('manager', 'guard', 'broker') then raise exception 'Pick who this is.' using errcode = '22023'; end if;
  if coalesce(ph, '') = '' then raise exception 'Give a 10-digit mobile number.' using errcode = '22023'; end if;
  if p ->> 'kind' = 'broker' and length(trim(coalesce(p ->> 'name', ''))) < 2 then raise exception 'Give the broker''s name.' using errcode = '22023'; end if;
  if cid is null then
    insert into public.society_prospect_contacts (prospect_id, kind, name, phone, note, source, partner_id, created_by)
    values (s.id, p ->> 'kind', left(trim(coalesce(p ->> 'name', '')), 80), ph, left(coalesce(p ->> 'note', ''), 300),
            'partner', auth.uid(), 'partner:' || auth.uid());
  else
    select * into old from public.society_prospect_contacts c
     where c.id = cid and c.prospect_id = s.id and c.partner_id = auth.uid() and c.removed_at is null;
    if old.id is null then raise exception 'No such number.' using errcode = '22023'; end if;
    if old.phone is distinct from ph then
      -- A new number: the old one is kept for the CRM, marked replaced.
      update public.society_prospect_contacts set removed_at = now(), removed_by = 'partner:' || auth.uid() || ':changed', updated_at = now()
       where id = old.id;
      insert into public.society_prospect_contacts (prospect_id, kind, name, phone, note, source, partner_id, created_by)
      values (s.id, p ->> 'kind', left(trim(coalesce(p ->> 'name', '')), 80), ph, left(coalesce(p ->> 'note', ''), 300),
              'partner', auth.uid(), 'partner:' || auth.uid());
    else
      update public.society_prospect_contacts c set kind = p ->> 'kind', name = left(trim(coalesce(p ->> 'name', '')), 80),
             note = left(coalesce(p ->> 'note', ''), 300), updated_at = now()
       where c.id = old.id;
    end if;
  end if;
  update public.society_prospects set updated_at = now() where id = s.id;
  return public.sp_json(s.id);
end;
$$;

create or replace function public.partner_society_contact_remove(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  sid uuid;
  s   public.society_prospects;
begin
  select prospect_id into sid from public.society_prospect_contacts where id = p_id and partner_id = auth.uid() and removed_at is null;
  if sid is null then raise exception 'No such number.' using errcode = '22023'; end if;
  s := public.sp_owned(sid);
  -- Kept for the CRM ("removed by partner"); gone from the partner's app.
  update public.society_prospect_contacts set removed_at = now(), removed_by = 'partner:' || auth.uid(), updated_at = now() where id = p_id;
  return public.sp_json(s.id);
end;
$$;

/**
 * A photo taken at the society: an amenity's (p_slot = the amenity) or the
 * sample flat's (p_slot = living | bedroom | kitchen | bathroom | balcony |
 * other). The phone must be within 300 m of the society's spot.
 */
create or replace function public.partner_society_photo_add(p_id uuid, p_kind text, p_slot text, p_url text, p_lat numeric, p_lng numeric)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s   public.society_prospects := public.sp_editable(p_id);
  m   numeric;
  ph  jsonb;
begin
  if coalesce(p_url, '') !~ '^https://' then raise exception 'That photo didn''t upload.' using errcode = '22023'; end if;
  if p_lat is null or p_lng is null then raise exception 'Turn on location to add photos.' using errcode = '22023'; end if;
  if s.lat is not null then
    m := public.sp_metres(p_lat, p_lng, s.lat, s.lng);
    if m > 300 then
      raise exception 'You''re % from %. Photos have to be taken at the society.',
        case when m >= 1000 then to_char(m / 1000, 'FM990.0') || ' km' else round(m)::text || ' m' end, s.name using errcode = '22023';
    end if;
  else
    update public.society_prospects set lat = p_lat, lng = p_lng where id = s.id;
  end if;
  ph := jsonb_build_object('url', p_url, 'lat', round(p_lat, 6), 'lng', round(p_lng, 6), 'at', now());
  if p_kind = 'amenity' then
    if not (p_slot = any(s.partner_amenities)) then raise exception 'Tick % first.', p_slot using errcode = '22023'; end if;
    if jsonb_array_length(coalesce(s.amenity_photos -> p_slot, '[]'::jsonb)) >= 6 then raise exception 'Six photos of each amenity is plenty.' using errcode = '22023'; end if;
    update public.society_prospects
       set amenity_photos = jsonb_set(amenity_photos, array[p_slot], coalesce(amenity_photos -> p_slot, '[]'::jsonb) || ph), updated_at = now()
     where id = s.id;
  elsif p_kind = 'flat' then
    if not (p_slot = any(public.society_flat_slots())) then raise exception 'Pick which room this is.' using errcode = '22023'; end if;
    if jsonb_array_length(s.flat_photos) >= 20 then raise exception 'Twenty photos of the flat is plenty.' using errcode = '22023'; end if;
    update public.society_prospects set flat_photos = flat_photos || (ph || jsonb_build_object('slot', p_slot)), updated_at = now() where id = s.id;
  else
    raise exception 'Unknown photo.' using errcode = '22023';
  end if;
  return public.sp_json(s.id);
end;
$$;

create or replace function public.partner_society_photo_remove(p_id uuid, p_kind text, p_slot text, p_url text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.society_prospects := public.sp_editable(p_id);
begin
  if p_kind = 'amenity' then
    update public.society_prospects
       set amenity_photos = jsonb_set(amenity_photos, array[p_slot],
             coalesce((select jsonb_agg(e) from jsonb_array_elements(coalesce(amenity_photos -> p_slot, '[]'::jsonb)) e where e ->> 'url' <> p_url), '[]'::jsonb))
     where id = s.id;
  else
    update public.society_prospects
       set flat_photos = coalesce((select jsonb_agg(e) from jsonb_array_elements(flat_photos) e where e ->> 'url' <> p_url), '[]'::jsonb)
     where id = s.id;
  end if;
  return public.sp_json(s.id);
end;
$$;

/** Everything is in: to the MovEazy team for review. */
create or replace function public.partner_society_submit(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s    public.society_prospects := public.sp_editable(p_id);
  miss text[] := public.sp_missing(p_id);
  e    text;
begin
  if cardinality(miss) > 0 then
    raise exception 'Still to add: %.', array_to_string(miss, ', ') using errcode = '22023';
  end if;
  update public.society_prospects set onboard_status = 'submitted', submitted_at = now(), onboard_note = '', updated_at = now() where id = s.id;
  for e in select x from public.crm_team_emails() x loop
    insert into public.crm_notifications (for_email, type, title, body)
    values (e, 'society', format('Society to review: %s', s.name), format('%s onboarded %s. Review it in CRM → Society prospects.', public.sp_partner_name(auth.uid()), s.name));
  end loop;
  return public.sp_json(s.id);
end;
$$;

/** Tenants who asked for flats in the partner's societies. */
create or replace function public.partner_society_leads()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  me uuid := public.sp_require();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', l.id, 'society', s.name, 'society_id', s.id, 'name', l.name, 'phone', l.phone, 'stage', l.stage,
             'stage_at', l.stage_at, 'created_at', l.created_at, 'last_note', l.last_note)
           order by (l.stage in ('closed', 'lost')), l.created_at desc)
      from public.society_leads l join public.society_prospects s on s.id = l.prospect_id
     where l.partner_id = me), '[]'::jsonb);
end;
$$;

/** Move a society lead along: called, visit_set, visit_done, closed, lost — with a note. */
create or replace function public.partner_society_lead_update(p_lead uuid, p_stage text, p_note text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := public.sp_require();
  l  public.society_leads;
  label text;
begin
  select * into l from public.society_leads where id = p_lead and partner_id = me for update;
  if l.id is null then raise exception 'No such lead.' using errcode = '22023'; end if;
  if p_stage not in ('new', 'called', 'visit_set', 'visit_done', 'closed', 'lost') then raise exception 'Pick a step.' using errcode = '22023'; end if;
  label := case p_stage when 'called' then 'Called' when 'visit_set' then 'Visit set' when 'visit_done' then 'Visit done'
                        when 'closed' then 'Closed' when 'lost' then 'Lost' else 'New' end;
  update public.society_leads set stage = p_stage, stage_at = case when p_stage <> l.stage then now() else stage_at end,
         last_note = case when trim(coalesce(p_note, '')) <> '' then left(trim(p_note), 500) else last_note end, updated_at = now()
   where id = l.id;
  insert into public.society_lead_events (lead_id, actor, kind, body)
  values (l.id, public.sp_partner_name(me), p_stage, concat_ws(' · ', label, nullif(trim(coalesce(p_note, '')), '')));
  if l.client_id is not null then
    insert into public.crm_activities (client_id, type, body)
    values (l.client_id, 'partner', format('Society lead (%s): %s%s', (select name from public.society_prospects where id = l.prospect_id), label,
                                          case when trim(coalesce(p_note, '')) <> '' then ' — ' || trim(p_note) else '' end));
  end if;
  return public.partner_society_leads();
end;
$$;

/* ── CRM ──────────────────────────────────────────────────────────────────── */

/** Who is a society partner (user ids). */
create or replace function public.crm_society_partner_ids()
returns uuid[]
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  return coalesce(array(select user_id from public.broker_partners where society_partner), '{}');
end;
$$;

create or replace function public.crm_society_partner_set(p_user uuid, p_on boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.has_admin_scope('partners.manage') then raise exception 'Needs permission to manage partners.' using errcode = '42501'; end if;
  update public.broker_partners set society_partner = coalesce(p_on, false), updated_at = now() where user_id = p_user;
  if not found then raise exception 'No such partner.' using errcode = '22023'; end if;
  if p_on then
    insert into public.partner_notifications (broker_id, kind, title, body, link)
    values (p_user, 'society', 'You''re a MovEazy society partner',
            'Onboard the gated societies near you: open Societies, pick one on the map and add its details. Every MovEazy tenant who wants a flat there comes to you.',
            '/societies');
  end if;
  return coalesce(p_on, false);
end;
$$;

/** Approve a submitted society (it goes live for tenants) or send it back with a note. */
create or replace function public.crm_society_onboard_decide(p_id uuid, p_approve boolean, p_note text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  who  text := lower(coalesce(auth.jwt() ->> 'email', ''));
  s    public.society_prospects;
  code text;
  i    int;
  urls text[];
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  select * into s from public.society_prospects where id = p_id for update;
  if s.id is null then raise exception 'No such society.' using errcode = '22023'; end if;
  if s.onboard_status not in ('submitted', 'approved') then raise exception 'Nothing submitted to review yet.' using errcode = '22023'; end if;

  if p_approve then
    code := s.public_code;
    if code is null then
      for i in 1..25 loop
        select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '') into code from generate_series(1, 6);
        exit when not exists (select 1 from public.society_prospects where public_code = code);
      end loop;
    end if;
    -- The partner's photos lead the society's own: the sample flat, then the amenities.
    urls := array(select u from (
              select u, min(o * 100000 + n) k from (
                select e ->> 'url' u, 1 o, n from jsonb_array_elements(s.flat_photos) with ordinality t(e, n)
                union all select ph ->> 'url', 2, n from jsonb_each(s.amenity_photos) a, jsonb_array_elements(a.value) with ordinality t(ph, n)
                union all select x, 3, n from unnest(s.photos) with ordinality t(x, n)) q
              where u ~ '^https://' group by u) r
            order by k);
    update public.society_prospects set
      onboard_status = 'approved', live = true, public_code = code, decided_at = now(), decided_by = who, onboard_note = '',
      verified = true, verified_by = who, verified_at = now(), status = case when status = 'prospect' then 'onboarded' else status end,
      amenities = case when cardinality(partner_amenities) > 0 then partner_amenities else amenities end,
      photos = (select array_agg(x) from (select x from unnest(urls) x limit 20) y),
      rents = rents || partner_rents,   -- the partner's ranges win where they gave one
      updated_at = now(), updated_by = who
     where id = p_id;
    insert into public.partner_notifications (broker_id, kind, title, body, link)
    values (s.onboard_by, 'society', format('%s is live', s.name),
            format('The MovEazy team approved %s. Tenants can now find it on moveazy.co.in — every one who asks for a flat there comes to you.', s.name),
            '/societies');
  else
    if trim(coalesce(p_note, '')) = '' then raise exception 'Say what needs fixing.' using errcode = '22023'; end if;
    update public.society_prospects set onboard_status = 'sent_back', onboard_note = left(trim(p_note), 1000), decided_at = now(), decided_by = who,
           live = false, onboard_locked_until = now() + interval '7 days', updated_at = now(), updated_by = who
     where id = p_id;
    insert into public.partner_notifications (broker_id, kind, title, body, link)
    values (s.onboard_by, 'society', format('%s needs a fix', s.name), left(trim(p_note), 300), '/societies/' || s.id);
  end if;
  return public.society_prospect_json(p_id);
end;
$$;

/** Take a live society off the site (or put it back). */
create or replace function public.crm_society_live_set(p_id uuid, p_live boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  update public.society_prospects set live = coalesce(p_live, false) and onboard_status = 'approved', updated_at = now() where id = p_id;
  return public.society_prospect_json(p_id);
end;
$$;

/** Every society lead with its society, partner, tenant and timeline. */
create or replace function public.crm_society_leads()
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
             'id', l.id, 'society', s.name, 'society_id', s.id, 'area', s.area, 'partner', public.sp_partner_name(l.partner_id),
             'partner_phone', (select bp.phone from public.broker_partners bp where bp.user_id = l.partner_id),
             'client_id', l.client_id, 'name', l.name, 'phone', l.phone, 'stage', l.stage, 'stage_at', l.stage_at,
             'created_at', l.created_at, 'last_note', l.last_note,
             'events', coalesce((select jsonb_agg(jsonb_build_object('at', e.at, 'actor', e.actor, 'kind', e.kind, 'body', e.body) order by e.at)
                                   from public.society_lead_events e where e.lead_id = l.id), '[]'::jsonb))
           order by l.created_at desc)
      from public.society_leads l join public.society_prospects s on s.id = l.prospect_id), '[]'::jsonb);
end;
$$;

/** The CRM's prospect list, now with onboarding and live state (otherwise as in society_prospects.sql). */
create or replace function public.society_prospects_list()
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
             'id', s.id, 'place_id', s.place_id, 'name', s.name, 'road', s.road, 'area', s.area,
             'lat', s.lat, 'lng', s.lng, 'status', s.status, 'last_contacted', s.last_contacted,
             'verified', s.verified, 'researched', s.researched_at is not null, 'hidden', s.hidden,
             'amenities', cardinality(s.amenities), 'photos', cardinality(s.photos), 'building_id', s.building_id,
             'contacts', (select count(*) from public.society_prospect_contacts c where c.prospect_id = s.id),
             'onboard_status', s.onboard_status, 'onboard_by_name', case when s.onboard_by is not null then public.sp_partner_name(s.onboard_by) end,
             'live', s.live, 'public_code', s.public_code, 'added_by_partner', s.added_by_partner,
             'leads', (select count(*) from public.society_leads l where l.prospect_id = s.id),
             'updated_at', s.updated_at)
           order by s.road, s.name)
      from public.society_prospects s), '[]'::jsonb);
end;
$$;

/** One prospect with its contacts (otherwise as in society_prospects.sql), plus who's onboarding it. */
create or replace function public.society_prospect_json(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select to_jsonb(s) || jsonb_build_object(
           'building_code', (select b.code from public.owner_buildings b where b.id = s.building_id),
           'onboard_by_name', case when s.onboard_by is not null then public.sp_partner_name(s.onboard_by) end,
           'onboard_by_phone', (select bp.phone from public.broker_partners bp where bp.user_id = s.onboard_by),
           'missing', case when s.onboard_by is not null then to_jsonb(public.sp_missing(s.id)) end,
           'contacts', coalesce((select jsonb_agg(to_jsonb(c) || jsonb_build_object('partner_name', case when c.partner_id is not null then public.sp_partner_name(c.partner_id) end)
                                   order by array_position(array['office', 'manager', 'guard', 'broker', 'tenant'], c.kind), c.created_at)
                                   from public.society_prospect_contacts c where c.prospect_id = s.id), '[]'::jsonb))
    from public.society_prospects s
   where s.id = p_id;
$$;

/* ── Tenants ──────────────────────────────────────────────────────────────── */

/** A live society for a card: never the gate — the spot is rounded to ~100 m. */
create or replace function public.society_live_card(s public.society_prospects)
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'code', s.public_code, 'name', s.name, 'area', s.area, 'road', s.road,
    'lat', round(s.lat, 3), 'lng', round(s.lng, 3), 'cover', coalesce(s.photos[1], ''), 'photos', cardinality(s.photos),
    'amenities', to_jsonb(s.amenities[1:6]), 'amenity_count', cardinality(s.amenities),
    'rents', case when s.partner_rents <> '{}'::jsonb then s.partner_rents else s.rents end,
    'facts', jsonb_build_object('builder', s.facts ->> 'builder', 'towers', s.facts ->> 'towers', 'total_flats', s.facts ->> 'total_flats'));
$$;

/** Every live society, nearest first when a spot is given. */
create or replace function public.societies_live(p_lat numeric default null, p_lng numeric default null)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(public.society_live_card(s) || jsonb_build_object('metres',
           case when p_lat is null or s.lat is null then null else round(public.sp_metres(p_lat, p_lng, s.lat, s.lng)) end)
         order by case when p_lat is null or s.lat is null then null else public.sp_metres(p_lat, p_lng, s.lat, s.lng) end nulls last, s.name), '[]'::jsonb)
    from public.society_prospects s
   where s.live and s.public_code is not null and not s.hidden;
$$;

/** One live society's page: photos by amenity and the sample flat, facts, rents, nearby. No numbers. */
create or replace function public.society_live(p_code text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.society_live_card(s) || jsonb_build_object(
           'photos_all', to_jsonb(s.photos),
           'amenities_all', to_jsonb(s.amenities),
           'amenity_photos', coalesce((select jsonb_object_agg(a.key, (select jsonb_agg(p ->> 'url') from jsonb_array_elements(a.value) p))
                                         from jsonb_each(s.amenity_photos) a), '{}'::jsonb),
           'flat_photos', coalesce((select jsonb_agg(jsonb_build_object('slot', p ->> 'slot', 'url', p ->> 'url')) from jsonb_array_elements(s.flat_photos) p), '[]'::jsonb),
           'facts_all', s.facts - 'about', 'about', s.facts ->> 'about', 'nearby', s.nearby,
           'partner_first_name', (select split_part(trim(bp.name), ' ', 1) from public.broker_partners bp where bp.user_id = s.onboard_by))
    from public.society_prospects s
   where s.public_code = upper(trim(p_code)) and s.live and not s.hidden;
$$;

/**
 * "Get flats" on a society's page. The tenant is known by their account or by
 * the browser's lead key (the number they verified). Becomes a society lead for
 * the partner who onboarded it — notified in their app, and asked to upload a
 * flat there for this tenant — the CRM is told, and the lead is Active.
 * Returns the partner's first name and number for WhatsApp.
 */
create or replace function public.society_enquire(p_code text, p_lead_key text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s   public.society_prospects;
  cid uuid;
  nm  text := '';
  ph  text := '';
  lid uuid;
  partner record;
  e   text;
  isnew boolean := false;
begin
  select * into s from public.society_prospects where public_code = upper(trim(p_code)) and live and not hidden;
  if s.id is null then raise exception 'This society isn''t listed right now.' using errcode = '22023'; end if;

  if auth.uid() is not null then
    select c.id, c.name, c.phone into cid, nm, ph from public.crm_clients c where c.user_id = auth.uid();
  end if;
  if cid is null and coalesce(p_lead_key, '') ~ '^[0-9a-f]{32}$' then
    select li.crm_client_id, li.name, li.phone into cid, nm, ph from public.lead_intake li where li.lead_key = p_lead_key;
    if cid is not null then select c.name, c.phone into nm, ph from public.crm_clients c where c.id = cid; end if;
  end if;
  if cid is null or coalesce(ph, '') = '' then raise exception 'Verify your mobile number first.' using errcode = '42501'; end if;

  select bp.user_id, bp.name, bp.phone, bp.status into partner from public.broker_partners bp where bp.user_id = s.onboard_by;

  -- One lead per tenant per society a day: asking twice doesn't double it.
  select id into lid from public.society_leads
   where prospect_id = s.id and client_id = cid and created_at > now() - interval '1 day' order by created_at desc limit 1;
  if lid is null then
    isnew := true;
    insert into public.society_leads (prospect_id, partner_id, client_id, name, phone)
    values (s.id, s.onboard_by, cid, coalesce(nm, ''), ph) returning id into lid;
    insert into public.society_lead_events (lead_id, actor, kind, body)
    values (lid, coalesce(nullif(nm, ''), 'Tenant'), 'enquired', format('Asked for flats in %s on moveazy.co.in — sent to %s', s.name, coalesce(nullif(partner.name, ''), 'the partner')));
  end if;

  perform public.crm_lead_activate(cid, 'society enquiry');
  if isnew then
    update public.crm_clients set interests = interests || ('society:' || s.public_code) where id = cid and not (('society:' || s.public_code) = any(interests));
    insert into public.crm_activities (client_id, type, body)
    values (cid, 'partner', format('Asked for flats in %s — sent to partner %s (%s)', s.name, coalesce(nullif(partner.name, ''), '—'), coalesce(partner.phone, '')));
    if partner.user_id is not null then
      insert into public.partner_notifications (broker_id, kind, title, body, link)
      values (partner.user_id, 'society_lead', format('New tenant for %s', s.name),
              format('%s wants a flat in %s. Call them, and upload a flat in this society for them in Add property.', coalesce(nullif(nm, ''), 'A tenant'), s.name),
              '/societies/leads');
    end if;
    for e in select x from public.crm_team_emails() x loop
      insert into public.crm_notifications (for_email, type, title, body, client_id)
      values (e, 'society_lead', format('Society lead: %s', s.name),
              format('%s is contacting %s for %s.', coalesce(nullif(nm, ''), 'A tenant'), coalesce(nullif(partner.name, ''), 'the partner'), s.name), cid);
    end loop;
  end if;

  return jsonb_build_object('society', s.name,
    'partner_first_name', case when partner.status = 'approved' then split_part(trim(coalesce(partner.name, '')), ' ', 1) end,
    'partner_phone', case when partner.status = 'approved' then partner.phone end);
end;
$$;

/* ── Grants ───────────────────────────────────────────────────────────────── */

do $$
declare
  f text;
begin
  foreach f in array array[
    'public.sp_metres(numeric, numeric, numeric, numeric)', 'public.sp_require()', 'public.sp_partner_name(uuid)',
    'public.sp_missing(uuid)', 'public.sp_json(uuid)', 'public.sp_editable(uuid)',
    'public.sp_contact_counts(uuid, uuid)', 'public.sp_owned(uuid)',
    'public.society_live_card(public.society_prospects)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
  foreach f in array array[
    'public.is_society_partner()', 'public.partner_societies_nearby(numeric, numeric)', 'public.partner_my_societies()',
    'public.partner_society_get(uuid)', 'public.partner_society_start(uuid)', 'public.partner_society_add(text, numeric, numeric, text, text)',
    'public.partner_society_save(jsonb)', 'public.partner_society_contact_save(jsonb)', 'public.partner_society_contact_remove(uuid)',
    'public.partner_society_photo_add(uuid, text, text, text, numeric, numeric)', 'public.partner_society_photo_remove(uuid, text, text, text)',
    'public.partner_society_submit(uuid)', 'public.partner_society_leads()', 'public.partner_society_lead_update(uuid, text, text)',
    'public.crm_society_partner_ids()', 'public.crm_society_partner_set(uuid, boolean)', 'public.crm_society_onboard_decide(uuid, boolean, text)',
    'public.crm_society_live_set(uuid, boolean)', 'public.crm_society_leads()'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array['public.societies_live(numeric, numeric)', 'public.society_live(text)', 'public.society_enquire(text, text)',
                           'public.society_amenity_list()', 'public.society_flat_slots()'] loop
    execute format('revoke all on function %s from public', f);
    execute format('grant execute on function %s to anon, authenticated', f);
  end loop;
end $$;

commit;
