-- Find My Flat — test inventory seed.
-- Adds three published listings so the Assured/broker rules can be seen on screen:
--   • MZ-SEED01  owner   → shows "★ MovEazy Assured" + "20% Brokerage Off"
--   • MZ-SEED02  tenant  → shows "★ MovEazy Assured" + "20% Brokerage Off"
--   • MZ-SEED03  broker  → ordinary listing, NO "listed by" tag
--
-- Idempotent: fixed property_ids + ON CONFLICT DO UPDATE, so re-running just refreshes.
-- Run in the Supabase SQL editor AFTER inventory_schema.sql. (SQL-editor runs as the
-- service role, so RLS is bypassed and poster_id may be left null.)
--
-- NOTE: "shortlisting" is stored client-side (localStorage) and the user_actions
-- 'shortlist_property' row is written in the browser when you click "Add to site
-- visit" — it cannot be seeded here. Seed = supply only; shortlist in the UI.

insert into public.inventory (
  property_id, posted_by, poster_name, poster_email, phone,
  city, area, full_address, landmark, latitude, longitude,
  rent, deposit, available_from,
  flat_type, bedrooms, bathrooms, furnishing, gender_pref,
  occupants_allowed, amenities, lifestyle,
  title, description, cover_image_url, images,
  status, is_verified
) values
  (
    'MZ-SEED01', 'owner', 'Ramesh (Owner)', 'owner.demo@moveazy.test', '',
    'Bengaluru', 'HSR Layout', '17th Cross, Sector 3, HSR Layout', 'Near Apollo Pharmacy, 17th Cross', 12.9141, 77.6411,
    32000, 100000, current_date,
    '2 BHK', 2, 2, 'Semi-furnished', 'any',
    '{Family,Bachelors}', '{Lift,Parking,Power backup}', '{Pet-friendly}',
    '2 BHK in HSR Layout', 'Bright 2 BHK with balcony, walkable to 27th Main. Direct owner listing.',
    'https://images.unsplash.com/photo-1502672260266-1c1ef2d93688?auto=format&fit=crop&q=80&w=1000',
    '{https://images.unsplash.com/photo-1502672260266-1c1ef2d93688?auto=format&fit=crop&q=80&w=1000}',
    'published', true
  ),
  (
    'MZ-SEED02', 'tenant', 'Priya (Tenant)', 'tenant.demo@moveazy.test', '',
    'Bengaluru', 'Koramangala', '5th Block, Koramangala', '5th Block', 12.9352, 77.6245,
    26000, 80000, current_date,
    '1 BHK', 1, 1, 'Fully Furnished', 'any',
    '{Bachelors,Family}', '{Lift,Gym,Parking}', '{}',
    '1 BHK in Koramangala', 'Fully furnished 1 BHK, tenant leaving city — takeover available.',
    'https://images.unsplash.com/photo-1522708323590-d24dbb6b0267?auto=format&fit=crop&q=80&w=1000',
    '{https://images.unsplash.com/photo-1522708323590-d24dbb6b0267?auto=format&fit=crop&q=80&w=1000}',
    'published', true
  ),
  (
    'MZ-SEED03', 'broker', 'Zippy Homes', 'broker.demo@moveazy.test', '',
    'Bengaluru', 'Indiranagar', '100 Feet Road, Indiranagar', '100 Feet Road', 12.9719, 77.6412,
    55000, 200000, current_date,
    '3 BHK', 3, 3, 'Semi-furnished', 'any',
    '{Family}', '{Lift,Parking,Power backup,Security}', '{}',
    '3 BHK in Indiranagar', 'Spacious 3 BHK near 100 Feet Road. Listed by broker.',
    'https://images.unsplash.com/photo-1505691938895-1758d7feb511?auto=format&fit=crop&q=80&w=1000',
    '{https://images.unsplash.com/photo-1505691938895-1758d7feb511?auto=format&fit=crop&q=80&w=1000}',
    'published', true
  )
on conflict (property_id) do update set
  posted_by       = excluded.posted_by,
  poster_name     = excluded.poster_name,
  area            = excluded.area,
  full_address    = excluded.full_address,
  landmark        = excluded.landmark,
  latitude        = excluded.latitude,
  longitude       = excluded.longitude,
  rent            = excluded.rent,
  deposit         = excluded.deposit,
  flat_type       = excluded.flat_type,
  furnishing      = excluded.furnishing,
  occupants_allowed = excluded.occupants_allowed,
  amenities       = excluded.amenities,
  title           = excluded.title,
  description     = excluded.description,
  cover_image_url = excluded.cover_image_url,
  images          = excluded.images,
  status          = 'published',
  is_verified     = true,
  updated_at      = now();

-- Confirm the seed:
select property_id, posted_by, area, flat_type, rent, status
from public.inventory
where property_id in ('MZ-SEED01','MZ-SEED02','MZ-SEED03')
order by property_id;
