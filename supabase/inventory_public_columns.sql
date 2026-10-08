-- Restrict the PUBLIC (signed-out / anon) read of inventory to non-PII columns.
--
-- inventory has a "status = 'published'" read policy so the map/discovery feed
-- works while signed out. But the anon role also had table-level SELECT, so a
-- signed-out request (or a raw curl with the public anon key that ships in the
-- JS bundle) could read every poster's phone, email, name and user ids via
-- select=*. RLS gates ROWS, not COLUMNS — so this adds column-level grants.
--
-- anon may read only the listing's public columns. authenticated was left
-- untouched here, which left every signed-in tenant able to read the same PII;
-- inventory_authenticated_columns.sql gives it this same list, and owners and
-- staff read full rows through inventory_full() (inventory_private_read.sql).
-- Run once in the Supabase SQL editor. Safe to re-run.

revoke select on public.inventory from anon;

grant select (
  property_id, posted_by, city, area, nearby_areas, full_address, landmark,
  latitude, longitude, rent, deposit, available_from, flat_type, bedrooms,
  bathrooms, furnishing, max_flatmates, gender_pref, occupants_allowed,
  amenities, lifestyle, house_rules, title, description, images,
  cover_image_url, status, is_verified, view_count, created_at, updated_at
) on public.inventory to anon;

-- Deliberately NOT granted to anon: phone, poster_email, poster_name,
-- poster_id, owner_id, tenant_id, broker_id. A signed-out visitor can no
-- longer read a poster's contact details or account id from this table.
