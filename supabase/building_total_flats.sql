-- ─────────────────────────────────────────────────────────────────────────────
-- How many flats a building has in all, booked ones included
-- (fe/src/pages/BuildingPage.jsx, fe/src/pages/crm/CrmBuildingEditor.jsx).
--
-- Run in the Supabase SQL editor AFTER owner_buildings.sql and
-- crm_onboarding.sql. Safe to re-run.
--
-- A building's page says "26 of 42 flats available": the flats listed on
-- MovEazy are only the ones still free (and a few booked ones), so the CRM
-- sets the building's real count. Unset, the page counts the listed flats.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

alter table public.owner_buildings add column if not exists total_flats int;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'owner_buildings_total_flats_check') then
    alter table public.owner_buildings add constraint owner_buildings_total_flats_check check (total_flats between 1 and 2000);
  end if;
end $$;

/** (owner_buildings.sql) What moveazy.co.in/building/<code> shows — now with the building's flat count. Null for an unknown or paused building. */
create or replace function public.building_page(p_code text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'code', b.code, 'name', b.name, 'area', b.area, 'landmark', b.landmark,
    'latitude', round(b.latitude, 3), 'longitude', round(b.longitude, 3),   -- the neighbourhood, not the gate
    'total_floors', b.total_floors, 'total_flats', b.total_flats,
    'description', b.description, 'amenities', b.amenities, 'photos', b.photos,
    'kind', b.kind, 'cover_video', b.cover_video,
    'flats', public.building_flats(b.id),
    'has_partner', b.broker_id is not null,
    -- Only whether it's on: the POC is for a signed-in tenant who takes it.
    'instant_visit', b.instant_visit and b.instant_poc_phone <> ''
  )
  from public.owner_buildings b
  where b.id = public.building_by_code(p_code);
$$;

/**
 * The CRM's building editor: read the building's flat count (p_total null),
 * or set it ('' clears it — the page then counts the listed flats). → the count.
 */
create or replace function public.crm_building_total_flats(p_building uuid, p_total text default null)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  n int;
begin
  if p_total is null then
    if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
    return (select total_flats from public.owner_buildings where id = p_building);
  end if;
  if not public.has_admin_scope('crm.properties.write') then
    raise exception 'Needs permission to change properties.' using errcode = '42501';
  end if;
  if trim(p_total) !~ '^[0-9]{0,4}$' then raise exception 'Total flats is a number.' using errcode = '22023'; end if;
  n := nullif(trim(p_total), '')::int;
  if n is not null and (n < 1 or n > 2000) then raise exception 'Total flats is between 1 and 2000.' using errcode = '22023'; end if;
  update public.owner_buildings set total_flats = n, updated_at = now() where id = p_building;
  if not found then raise exception 'No such building.' using errcode = '22023'; end if;
  return n;
end;
$$;

revoke all on function public.crm_building_total_flats(uuid, text) from public, anon;
grant execute on function public.crm_building_total_flats(uuid, text) to authenticated;

commit;
