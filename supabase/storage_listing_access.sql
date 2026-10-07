-- ─────────────────────────────────────────────────────────────────────────────
-- Listing photos: only the flat's own people may change them.
--
-- Run in the Supabase SQL editor AFTER inventory_schema.sql, crm_schema.sql
-- (has_admin_scope), admin_schema.sql, partner_schema.sql, owner_schema.sql and
-- owner_buildings.sql. Safe to re-run.
--
-- Until now the `listings` bucket let ANY signed-in account — a tenant, any
-- broker, any owner — upload into or overwrite any file in it, so anyone could
-- replace another flat's photos. Now a write to
--     inventory/<property id>/<file>        (and its thumbs/ copy)
-- is allowed for:
--   - CRM staff who may edit listings (crm.properties.write) and allowlisted
--     admins — as for the listing itself;
--   - the flat's own people: whoever posted it, its listing broker, its owner
--     (inventory.poster_id / broker_id / owner_id, partner_listings,
--     owner_property_links);
--   - before the listing exists (the forms upload photos first, then create
--     it): whoever uploads into that folder first; nobody else after them.
-- Building photos (inventory/BLD-<building code>/…) belong to the building's
-- owner. Anything else in the bucket (originals-archive/, the old listings/
-- folder) is CRM-only. Reading stays public — the photos are on the site.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

/** Is `uid` one of this flat's own people? */
create or replace function public.owns_listing(p_property text, p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_uid is not null and (
    exists (select 1 from public.inventory i
             where i.property_id = p_property
               and p_uid in (i.poster_id, i.broker_id, i.owner_id))
    or exists (select 1 from public.partner_listings pl where pl.property_id = p_property and pl.broker_id = p_uid)
    or exists (select 1 from public.owner_property_links ol where ol.property_id = p_property and ol.owner_id = p_uid)
  );
$$;

/** May the caller write the listings-bucket object at `p_name`? (Storage policies below.) */
create or replace function public.can_write_listing_media(p_name text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  uid    uuid := auth.uid();
  n      text := coalesce(p_name, '');
  folder text;
  bcode  text;
  pre    text;
begin
  if uid is null then return false; end if;
  if public.has_admin_scope('crm.properties.write') or public.is_admin_allowlisted() then return true; end if;

  if left(n, 7) = 'thumbs/' then n := substr(n, 8); end if;
  if left(n, 10) <> 'inventory/' then return false; end if;
  folder := split_part(n, '/', 2);
  if folder = '' or split_part(n, '/', 3) = '' or folder ~ '[^A-Za-z0-9_-]' then return false; end if;

  if left(folder, 4) = 'BLD-' then
    bcode := upper(substr(folder, 5));
    if exists (select 1 from public.owner_buildings b where b.code = bcode) then
      return exists (select 1 from public.owner_buildings b where b.code = bcode and b.owner_id = uid);
    end if;
  elsif exists (select 1 from public.inventory i where i.property_id = folder) then
    return public.owns_listing(folder, uid);
  end if;

  -- Not a listing (or building) yet: the forms upload first and save after.
  -- Whoever put the first file in this folder holds it until it is saved.
  pre := 'inventory/' || folder || '/';
  return not exists (
    select 1 from storage.objects o
     where o.bucket_id = 'listings'
       and (left(o.name, length(pre)) = pre or left(o.name, length(pre) + 7) = 'thumbs/' || pre)
       and o.owner_id is distinct from uid::text
  );
end;
$$;

revoke all on function public.owns_listing(text, uuid) from public, anon;
grant execute on function public.owns_listing(text, uuid) to authenticated;
revoke all on function public.can_write_listing_media(text) from public, anon;
grant execute on function public.can_write_listing_media(text) to authenticated;

-- The old open policies.
drop policy if exists "Authenticated upload to listings" on storage.objects;
drop policy if exists "Authenticated update listings" on storage.objects;

drop policy if exists "listings: own flat's people upload" on storage.objects;
create policy "listings: own flat's people upload" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'listings' and public.can_write_listing_media(name));

drop policy if exists "listings: own flat's people replace" on storage.objects;
create policy "listings: own flat's people replace" on storage.objects
  for update to authenticated
  using (bucket_id = 'listings' and public.can_write_listing_media(name))
  with check (bucket_id = 'listings' and public.can_write_listing_media(name));

commit;
