-- ─────────────────────────────────────────────────────────────────────────────
-- Society prospects — the gated societies around HSR the team means to bring
-- on (MovEazy-FE pages/crm/CrmSocietyProspectsPage.jsx, lib/societyProspects.js).
--
-- Run in the Supabase SQL editor AFTER crm_schema.sql (is_crm_staff,
-- is_super_admin), owner_buildings.sql and society_app.sql. Safe to re-run.
--
-- The super admin imports them from Google Maps, road by road (HSR, Sarjapur
-- Road, Haralur Road, Silver County Road, Hosa Road, Kudlu Road), through
-- api/places.js. Each starts as a prospect: never on the public site, only in
-- the CRM, on its map and list. The team works it — contacted, interested,
-- onboarded — with notes and the people to call (guards, the manager, the
-- brokers working it, tenants living there). Its amenities, facts, rents and
-- what's nearby come from research and stay "to verify" until someone in the
-- CRM ticks them. Each one prints as a tenant brochure. "Make live" turns it
-- into a society building (owner_buildings, kind 'society') and links it.
--
--   society_prospects          the society: name, pin, road, status, research.
--   society_prospect_contacts  people and numbers: office, manager, guard,
--                              broker, tenant. Business numbers (the society's
--                              office, nearby agencies) may come from Google;
--                              people are added by the team.
--
-- Nobody reads these tables directly; everything goes through the functions
-- below. Any CRM staff member may read and work them; only the super admin
-- imports.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

create table if not exists public.society_prospects (
  id             uuid primary key default gen_random_uuid(),
  place_id       text not null default '',
  name           text not null check (length(trim(name)) between 2 and 120),
  road           text not null default 'hsr' check (road in ('hsr', 'sarjapur', 'haralur', 'silver', 'hosa', 'kudlu')),
  area           text not null default '',
  address        text not null default '',
  lat            numeric,
  lng            numeric,
  maps_url       text not null default '',
  status         text not null default 'prospect' check (status in ('prospect', 'contacted', 'interested', 'onboarded')),
  notes          text not null default '',
  last_contacted date,
  -- builder, year_built, towers, total_flats, floors, families, bachelors, pets, maintenance, about
  facts          jsonb not null default '{}',
  amenities      text[] not null default '{}',
  -- { "1": [min, max], "2": [...], "3": [...] } monthly rent in rupees
  rents          jsonb not null default '{}',
  -- { schools: [{ name, km }], hospitals: [...], supermarkets: [...], transit: [...] }
  nearby         jsonb not null default '{}',
  sources        text[] not null default '{}',
  researched_at  timestamptz,
  verified       boolean not null default false,
  verified_by    text not null default '',
  verified_at    timestamptz,
  photos         text[] not null default '{}',
  hidden         boolean not null default false,   -- "not a society": off the map and list
  building_id    uuid references public.owner_buildings (id) on delete set null,
  created_by     text not null default '',
  updated_by     text not null default '',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create unique index if not exists society_prospects_place_key on public.society_prospects (place_id) where place_id <> '';
create index if not exists society_prospects_road_idx on public.society_prospects (road, status);

create table if not exists public.society_prospect_contacts (
  id          uuid primary key default gen_random_uuid(),
  prospect_id uuid not null references public.society_prospects (id) on delete cascade,
  kind        text not null check (kind in ('office', 'manager', 'guard', 'broker', 'tenant')),
  name        text not null default '',
  phone       text not null default '' check (phone ~ '^[0-9+ -]{0,20}$'),
  note        text not null default '',
  source      text not null default 'team' check (source in ('team', 'google')),
  created_by  text not null default '',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists society_prospect_contacts_idx on public.society_prospect_contacts (prospect_id, kind);

alter table public.society_prospects enable row level security;
alter table public.society_prospect_contacts enable row level security;
revoke all on public.society_prospects from anon, authenticated;
revoke all on public.society_prospect_contacts from anon, authenticated;

/** Who is calling, for the who-changed-it columns. */
create or replace function public.society_prospect_actor()
returns text
language sql
stable
as $$
  select lower(coalesce(auth.jwt() ->> 'email', ''));
$$;

/** One prospect as the CRM shows it, with its contacts. */
create or replace function public.society_prospect_json(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select to_jsonb(s) || jsonb_build_object(
           'building_code', (select b.code from public.owner_buildings b where b.id = s.building_id),
           'contacts', coalesce((select jsonb_agg(to_jsonb(c) order by
                                   array_position(array['office', 'manager', 'guard', 'broker', 'tenant'], c.kind), c.created_at)
                                   from public.society_prospect_contacts c where c.prospect_id = s.id), '[]'::jsonb))
    from public.society_prospects s
   where s.id = p_id;
$$;

/** Every prospect, for the map and list (hidden ones too, flagged). */
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
             'updated_at', s.updated_at)
           order by s.road, s.name)
      from public.society_prospects s), '[]'::jsonb);
end;
$$;

/** One prospect with its contacts. */
create or replace function public.society_prospect_get(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  return public.society_prospect_json(p_id);
end;
$$;

/**
 * Change a prospect: { id, name?, area?, road?, status?, notes?, last_contacted?,
 * facts?, amenities?, rents?, nearby?, photos?, verified?, hidden?, building_id? }.
 * Keys left out stay as they are. Returns the prospect.
 */
create or replace function public.society_prospect_save(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  pid uuid := nullif(p ->> 'id', '')::uuid;
  who text := public.society_prospect_actor();
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  if pid is null or not exists (select 1 from public.society_prospects where id = pid) then
    raise exception 'No such society.' using errcode = '22023';
  end if;
  if p ? 'name' and length(trim(coalesce(p ->> 'name', ''))) not between 2 and 120 then
    raise exception 'Give the society a name.' using errcode = '22023';
  end if;
  if p ? 'building_id' and nullif(p ->> 'building_id', '') is not null
     and not exists (select 1 from public.owner_buildings b where b.id = (p ->> 'building_id')::uuid) then
    raise exception 'No such building.' using errcode = '22023';
  end if;

  update public.society_prospects s set
    name           = case when p ? 'name' then trim(p ->> 'name') else s.name end,
    area           = case when p ? 'area' then left(trim(coalesce(p ->> 'area', '')), 80) else s.area end,
    road           = case when p ->> 'road' in ('hsr', 'sarjapur', 'haralur', 'silver', 'hosa', 'kudlu') then p ->> 'road' else s.road end,
    status         = case when p ->> 'status' in ('prospect', 'contacted', 'interested', 'onboarded') then p ->> 'status' else s.status end,
    notes          = case when p ? 'notes' then left(coalesce(p ->> 'notes', ''), 4000) else s.notes end,
    last_contacted = case when p ? 'last_contacted' then nullif(p ->> 'last_contacted', '')::date else s.last_contacted end,
    facts          = case when jsonb_typeof(p -> 'facts') = 'object' then p -> 'facts' else s.facts end,
    amenities      = case when jsonb_typeof(p -> 'amenities') = 'array'
                          then array(select left(trim(x), 60) from jsonb_array_elements_text(p -> 'amenities') x where trim(x) <> '' limit 60)
                          else s.amenities end,
    rents          = case when jsonb_typeof(p -> 'rents') = 'object' then p -> 'rents' else s.rents end,
    nearby         = case when jsonb_typeof(p -> 'nearby') = 'object' then p -> 'nearby' else s.nearby end,
    photos         = case when jsonb_typeof(p -> 'photos') = 'array'
                          then array(select x from jsonb_array_elements_text(p -> 'photos') x where x ~ '^https://' limit 20)
                          else s.photos end,
    verified       = case when p ? 'verified' then coalesce((p ->> 'verified')::boolean, false) else s.verified end,
    verified_by    = case when p ? 'verified' then (case when (p ->> 'verified')::boolean then who else '' end) else s.verified_by end,
    verified_at    = case when p ? 'verified' then (case when (p ->> 'verified')::boolean then now() end) else s.verified_at end,
    hidden         = case when p ? 'hidden' then coalesce((p ->> 'hidden')::boolean, false) else s.hidden end,
    building_id    = case when p ? 'building_id' then nullif(p ->> 'building_id', '')::uuid else s.building_id end,
    updated_by     = who,
    updated_at     = now()
  where s.id = pid;
  return public.society_prospect_json(pid);
end;
$$;

/** Add (no id) or change a contact: { id?, prospect_id, kind, name, phone, note }. */
create or replace function public.society_prospect_contact_save(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  cid uuid := nullif(p ->> 'id', '')::uuid;
  pid uuid := nullif(p ->> 'prospect_id', '')::uuid;
  ph  text := regexp_replace(coalesce(p ->> 'phone', ''), '[^0-9+ -]', '', 'g');
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  if coalesce(p ->> 'kind', '') not in ('office', 'manager', 'guard', 'broker', 'tenant') then
    raise exception 'Pick who this is.' using errcode = '22023';
  end if;
  if length(regexp_replace(ph, '[^0-9]', '', 'g')) not between 8 and 13 then
    raise exception 'Give a phone number.' using errcode = '22023';
  end if;
  if cid is null then
    if pid is null or not exists (select 1 from public.society_prospects where id = pid) then
      raise exception 'No such society.' using errcode = '22023';
    end if;
    insert into public.society_prospect_contacts (prospect_id, kind, name, phone, note, created_by)
    values (pid, p ->> 'kind', left(trim(coalesce(p ->> 'name', '')), 80), left(ph, 20), left(coalesce(p ->> 'note', ''), 300), public.society_prospect_actor())
    returning prospect_id into pid;
  else
    update public.society_prospect_contacts c set
      kind = p ->> 'kind', name = left(trim(coalesce(p ->> 'name', '')), 80), phone = left(ph, 20),
      note = left(coalesce(p ->> 'note', ''), 300), updated_at = now()
     where c.id = cid
    returning c.prospect_id into pid;
    if pid is null then raise exception 'No such contact.' using errcode = '22023'; end if;
  end if;
  update public.society_prospects set updated_at = now(), updated_by = public.society_prospect_actor() where id = pid;
  return public.society_prospect_json(pid);
end;
$$;

/** Remove a contact. Returns the prospect. */
create or replace function public.society_prospect_contact_remove(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  pid uuid;
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  delete from public.society_prospect_contacts where id = p_id returning prospect_id into pid;
  if pid is null then raise exception 'No such contact.' using errcode = '22023'; end if;
  return public.society_prospect_json(pid);
end;
$$;

/**
 * The import from Google (super admin): [{ place_id, name, road, area, address,
 * lat, lng, maps_url, phone, agents: [{ name, phone }] }]. A place already here
 * keeps its name, road and everything the team did; only its pin, address and
 * map link are refreshed. Its office number and up to five agencies arrive as
 * Google contacts once. Returns { added, updated }.
 */
create or replace function public.society_prospects_import(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r      jsonb;
  a      jsonb;
  pid    uuid;
  isnew  boolean;
  added  int := 0;
  upd    int := 0;
  who    text := public.society_prospect_actor();
  ph     text;
begin
  if not public.is_super_admin() then raise exception 'Only the super admin can import societies.' using errcode = '42501'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 500 then
    raise exception 'Send up to 500 societies at a time.' using errcode = '22023';
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    continue when coalesce(r ->> 'place_id', '') !~ '^[A-Za-z0-9_-]{10,300}$' or length(trim(coalesce(r ->> 'name', ''))) < 2;
    select id into pid from public.society_prospects where place_id = r ->> 'place_id';
    isnew := pid is null;
    if isnew then
      insert into public.society_prospects (place_id, name, road, area, address, lat, lng, maps_url, created_by, updated_by)
      values (r ->> 'place_id', left(trim(r ->> 'name'), 120),
              case when r ->> 'road' in ('hsr', 'sarjapur', 'haralur', 'silver', 'hosa', 'kudlu') then r ->> 'road' else 'hsr' end,
              left(coalesce(r ->> 'area', ''), 80), left(coalesce(r ->> 'address', ''), 400),
              nullif(r ->> 'lat', '')::numeric, nullif(r ->> 'lng', '')::numeric,
              case when coalesce(r ->> 'maps_url', '') ~ '^https://' then left(r ->> 'maps_url', 400) else '' end, who, who)
      returning id into pid;
      added := added + 1;
    else
      update public.society_prospects s set
        lat = coalesce(nullif(r ->> 'lat', '')::numeric, s.lat),
        lng = coalesce(nullif(r ->> 'lng', '')::numeric, s.lng),
        address = coalesce(nullif(left(coalesce(r ->> 'address', ''), 400), ''), s.address),
        maps_url = case when coalesce(r ->> 'maps_url', '') ~ '^https://' then left(r ->> 'maps_url', 400) else s.maps_url end,
        updated_at = now()
       where s.id = pid;
      upd := upd + 1;
    end if;

    ph := regexp_replace(coalesce(r ->> 'phone', ''), '[^0-9+ -]', '', 'g');
    if length(regexp_replace(ph, '[^0-9]', '', 'g')) between 8 and 13
       and not exists (select 1 from public.society_prospect_contacts c where c.prospect_id = pid and c.kind = 'office') then
      insert into public.society_prospect_contacts (prospect_id, kind, name, phone, note, source, created_by)
      values (pid, 'office', 'Society office', left(ph, 20), 'From Google Maps', 'google', who);
    end if;

    if not exists (select 1 from public.society_prospect_contacts c where c.prospect_id = pid and c.kind = 'broker' and c.source = 'google') then
      for a in select * from jsonb_array_elements(coalesce(r -> 'agents', '[]'::jsonb)) limit 5 loop
        ph := regexp_replace(coalesce(a ->> 'phone', ''), '[^0-9+ -]', '', 'g');
        continue when length(regexp_replace(ph, '[^0-9]', '', 'g')) not between 8 and 13;
        insert into public.society_prospect_contacts (prospect_id, kind, name, phone, note, source, created_by)
        values (pid, 'broker', left(trim(coalesce(a ->> 'name', '')), 80), left(ph, 20),
                left(coalesce(a ->> 'note', 'Nearby agency on Google Maps'), 300), 'google', who);
      end loop;
    end if;
  end loop;
  return jsonb_build_object('added', added, 'updated', upd);
end;
$$;

/**
 * Research results (super admin): [{ id | place_id, facts, amenities, rents,
 * nearby, sources }]. Overwrites those fields and marks the society "to verify".
 * Returns how many it matched.
 */
create or replace function public.society_prospects_research(p_rows jsonb)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  r jsonb;
  n int := 0;
begin
  if not public.is_super_admin() then raise exception 'Only the super admin can load research.' using errcode = '42501'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    update public.society_prospects s set
      facts         = case when jsonb_typeof(r -> 'facts') = 'object' then r -> 'facts' else s.facts end,
      amenities     = case when jsonb_typeof(r -> 'amenities') = 'array'
                           then array(select left(trim(x), 60) from jsonb_array_elements_text(r -> 'amenities') x where trim(x) <> '' limit 60)
                           else s.amenities end,
      rents         = case when jsonb_typeof(r -> 'rents') = 'object' then r -> 'rents' else s.rents end,
      nearby        = case when jsonb_typeof(r -> 'nearby') = 'object' then r -> 'nearby' else s.nearby end,
      sources       = case when jsonb_typeof(r -> 'sources') = 'array'
                           then array(select x from jsonb_array_elements_text(r -> 'sources') x where x ~ '^https?://' limit 12)
                           else s.sources end,
      hidden        = case when (r ->> 'not_a_society')::boolean then true else s.hidden end,
      researched_at = now(),
      verified      = false, verified_by = '', verified_at = null,
      updated_at    = now()
     where (nullif(r ->> 'id', '') is not null and s.id = (r ->> 'id')::uuid)
        or (nullif(r ->> 'id', '') is null and s.place_id = r ->> 'place_id' and s.place_id <> '');
    if found then n := n + 1; end if;
  end loop;
  return n;
end;
$$;

/** Is this Google place one of our societies — set up, or a prospect? (The Places proxy only looks up places we list.) */
create or replace function public.society_place_known(p_place text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.society_accounts a where a.place_id = p_place and a.place_id <> '')
      or exists (select 1 from public.society_prospects s where s.place_id = p_place and s.place_id <> '' and not s.hidden);
$$;

revoke all on function public.society_prospect_actor() from public, anon, authenticated;
revoke all on function public.society_prospect_json(uuid) from public, anon, authenticated;
do $$
declare
  f text;
begin
  foreach f in array array[
    'public.society_prospects_list()', 'public.society_prospect_get(uuid)', 'public.society_prospect_save(jsonb)',
    'public.society_prospect_contact_save(jsonb)', 'public.society_prospect_contact_remove(uuid)',
    'public.society_prospects_import(jsonb)', 'public.society_prospects_research(jsonb)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

commit;
