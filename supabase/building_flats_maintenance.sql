-- ─────────────────────────────────────────────────────────────────────────────
-- A building's flats show their maintenance (fe/src/pages/BuildingPage.jsx).
--
-- Run in the Supabase SQL editor AFTER owner_buildings.sql. Safe to re-run.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

/** (owner_buildings.sql) The flats of a building as everyone may see them — now with maintenance: no address, no owner. */
create or replace function public.building_flats(p_building uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'property_id', i.property_id, 'title', i.title, 'flat_type', i.flat_type, 'property_type', i.property_type,
           'bedrooms', i.bedrooms, 'bathrooms', i.bathrooms, 'furnishing', i.furnishing, 'rent', i.rent,
           'deposit', i.deposit, 'maintenance', i.maintenance, 'available_from', i.available_from, 'area_sqft', i.area_sqft,
           'floor_number', i.floor_number, 'images', i.images, 'cover_image_url', i.cover_image_url,
           'amenities', i.amenities, 'description', i.description, 'unit_no', i.unit_no, 'unit_order', i.unit_order,
           'available', i.status <> 'rented' and not exists (select 1 from public.owner_building_bookings k where k.property_id = i.property_id))
         -- MovEazy's order first; then floor by floor, cheapest first.
         order by i.unit_order nulls last, i.floor_number nulls last, i.rent, i.property_id), '[]'::jsonb)
    from public.inventory i
   where i.building_id = p_building and i.status in ('published', 'paused', 'rented');
$$;

commit;
