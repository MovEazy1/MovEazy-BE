-- A partner edits their flat (MovEazy-FE pages/partners/AddProperty.jsx in
-- edit mode, "Modify details" on the flat's page).
--
--   partner_listing_update(property, patch): any flat that is theirs —
--   posted by them, or given to them (partner_listings, e.g. the flats
--   MovEazy uploaded from the CRM for them). Only the flat's own fields can
--   change: who posted it, its id and its source never do. Keys absent from
--   the patch are left as they are.
--
-- The plain table update (RLS "posters update own inventory") only reached
-- flats they posted themselves, so a CRM-uploaded flat in their inventory
-- could not be corrected at all.
--
-- Safe to re-run.

begin;

create or replace function public.partner_listing_update(p_property text, p jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  has jsonb := coalesce(p, '{}'::jsonb);
  st  text := nullif(has ->> 'status', '');
begin
  if uid is null or not public.owns_listing(p_property, uid) then
    raise exception 'Not your flat.' using errcode = '42501';
  end if;
  if st is not null and st not in ('published', 'paused', 'rented') then
    raise exception 'Unknown status.' using errcode = '22023';
  end if;
  if has ? 'rent' and coalesce((has ->> 'rent')::numeric, 0) < 0 then
    raise exception 'Rent can''t be negative.' using errcode = '22023';
  end if;

  update public.inventory i set
    flat_type         = case when has ? 'flat_type' then left(coalesce(has ->> 'flat_type', ''), 60) else i.flat_type end,
    property_type     = case when has ? 'property_type' then left(coalesce(has ->> 'property_type', ''), 60) else i.property_type end,
    bedrooms          = case when has ? 'bedrooms' then nullif(has ->> 'bedrooms', '')::int else i.bedrooms end,
    rent              = case when has ? 'rent' then coalesce(nullif(has ->> 'rent', '')::numeric, 0) else i.rent end,
    deposit           = case when has ? 'deposit' then coalesce(nullif(has ->> 'deposit', '')::numeric, 0) else i.deposit end,
    maintenance       = case when has ? 'maintenance' then nullif(has ->> 'maintenance', '')::numeric else i.maintenance end,
    furnishing        = case when has ? 'furnishing' then left(coalesce(has ->> 'furnishing', ''), 40) else i.furnishing end,
    area              = case when has ? 'area' then left(coalesce(has ->> 'area', ''), 120) else i.area end,
    nearby_areas      = case when has ? 'nearby_areas' then array(select left(x, 120) from jsonb_array_elements_text(has -> 'nearby_areas') x) else i.nearby_areas end,
    latitude          = case when has ? 'latitude' then nullif(has ->> 'latitude', '')::numeric else i.latitude end,
    longitude         = case when has ? 'longitude' then nullif(has ->> 'longitude', '')::numeric else i.longitude end,
    occupants_allowed = case when has ? 'occupants_allowed' then array(select left(x, 40) from jsonb_array_elements_text(has -> 'occupants_allowed') x) else i.occupants_allowed end,
    amenities         = case when has ? 'amenities' then array(select left(x, 60) from jsonb_array_elements_text(has -> 'amenities') x) else i.amenities end,
    available_from    = case when has ? 'available_from' then nullif(has ->> 'available_from', '')::date else i.available_from end,
    floor_number      = case when has ? 'floor_number' then nullif(has ->> 'floor_number', '')::int else i.floor_number end,
    title             = case when has ? 'title' then left(coalesce(has ->> 'title', ''), 160) else i.title end,
    description       = case when has ? 'description' then left(coalesce(has ->> 'description', ''), 2000) else i.description end,
    images            = case when has ? 'images' then array(select x from jsonb_array_elements_text(has -> 'images') x) else i.images end,
    cover_image_url   = case when has ? 'cover_image_url' then coalesce(has ->> 'cover_image_url', '') else i.cover_image_url end,
    status            = coalesce(st, i.status),
    updated_at        = now()
  where i.property_id = p_property;
end;
$$;

revoke all on function public.partner_listing_update(text, jsonb) from public, anon;
grant execute on function public.partner_listing_update(text, jsonb) to authenticated;

commit;
