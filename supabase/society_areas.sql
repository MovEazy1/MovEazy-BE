-- ─────────────────────────────────────────────────────────────────────────────
-- Societies across Bangalore (2026-11-17).
--
-- The society prospects began on six roads (HSR, Sarjapur, Haralur, Silver
-- County, Hosa, Kudlu). Now they cover the city's main renting areas — BTM,
-- Electronic City, Koramangala, Whitefield, Hebbal and ~30 more — so `road`
-- holds an area key (the list lives in the app, lib/societyProspects.js).
--
--   society_prospects.road       any area key (a-z, 0-9, _), not the six only
--   society_prospect_save        \
--   society_prospects_import      > accept any area key
--   partner_society_add          /
--   society_prospects_nearby     what's nearby from OpenStreetMap, for
--                                societies with nothing there yet; doesn't mark
--                                them researched (super admin)
--
-- Re-runnable.
-- ─────────────────────────────────────────────────────────────────────────────
begin;

do $$ begin
  if exists (select 1 from pg_constraint where conname = 'society_prospects_road_check') then
    alter table public.society_prospects drop constraint society_prospects_road_check;
  end if;
  alter table public.society_prospects add constraint society_prospects_road_check
    check (road ~ '^[a-z][a-z0-9_]{1,23}$');
end $$;

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
    road           = case when p ->> 'road' ~ '^[a-z][a-z0-9_]{1,23}$' then p ->> 'road' else s.road end,
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
    continue when coalesce(r ->> 'place_id', '') !~ '^[A-Za-z0-9_-]+$' or length(r ->> 'place_id') not between 10 and 300 or length(trim(coalesce(r ->> 'name', ''))) < 2;
    select id into pid from public.society_prospects where place_id = r ->> 'place_id';
    isnew := pid is null;
    if isnew then
      insert into public.society_prospects (place_id, name, road, area, address, lat, lng, maps_url, created_by, updated_by)
      values (r ->> 'place_id', left(trim(r ->> 'name'), 120),
              case when r ->> 'road' ~ '^[a-z][a-z0-9_]{1,23}$' then r ->> 'road' else 'hsr' end,
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
 * What's nearby, from OpenStreetMap (super admin): [{ id | place_id, nearby:
 * { schools: [..], hospitals: [..], supermarkets: [..], transit: [..] } }].
 * Fills only societies with nothing nearby yet (research already done is kept)
 * and leaves "researched" alone. Returns how many it filled.
 */
create or replace function public.society_prospects_nearby(p_rows jsonb)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  r jsonb;
  n int := 0;
begin
  if not public.is_super_admin() then raise exception 'Only the super admin can load what''s nearby.' using errcode = '42501'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 1000 then
    raise exception 'Send up to 1000 societies at a time.' using errcode = '22023';
  end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    continue when jsonb_typeof(r -> 'nearby') <> 'object';
    update public.society_prospects s set nearby = r -> 'nearby', updated_at = now()
     where coalesce(s.nearby, '{}'::jsonb) = '{}'::jsonb
       and ((nullif(r ->> 'id', '') is not null and s.id = (r ->> 'id')::uuid)
         or (nullif(r ->> 'id', '') is null and s.place_id = r ->> 'place_id' and s.place_id <> ''));
    if found then n := n + 1; end if;
  end loop;
  return n;
end;
$$;

do $$
declare
  f text;
begin
  foreach f in array array[
    'public.society_prospect_save(jsonb)', 'public.society_prospects_import(jsonb)',
    'public.partner_society_add(text, numeric, numeric, text, text)', 'public.society_prospects_nearby(jsonb)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

commit;
