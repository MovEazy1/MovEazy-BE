-- Owner/poster dashboard stats (fe/src/pages/MyProperties.jsx, /my-properties and
-- fe/src/pages/TenantManagement.jsx) — per-property performance: views, shortlists
-- (likes), visit requests (asked to join the next open visit, no slot chosen yet),
-- and visit bookings (a real slot picked).
--
-- REPLACES an earlier version of this file that referenced public.saved_properties
-- and public.visit_requests — saved_properties is a disused legacy save mechanism
-- (the app's actual "shortlist" is a listing_reactions 'like'), and visit_requests
-- was never created at all (so the old function couldn't even be installed). This
-- version reads only the tables the live app actually writes to:
-- listing_reactions and visit_bookings (see visits_schema.sql).
--
-- Run once in the Supabase SQL editor, AFTER inventory_schema.sql and
-- visits_schema.sql (needs public.inventory, public.listing_reactions,
-- public.visit_bookings).

create or replace function public.my_listing_stats()
returns table (
  property_id         text,
  title               text,
  status              text,
  rent                numeric,
  area                text,
  full_address        text,
  cover_image_url     text,
  images              text[],
  posted_by           text,
  created_at          timestamptz,
  view_count          int,
  shortlist_count     bigint,
  visit_request_count bigint,
  visit_booking_count bigint,
  like_count          bigint,
  dislike_count       bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select
    i.property_id,
    i.title,
    i.status,
    i.rent,
    i.area,
    i.full_address,
    i.cover_image_url,
    i.images,
    i.posted_by,
    i.created_at,
    i.view_count,
    coalesce(lr.likes, 0)    as shortlist_count, -- "shortlisted" = liked, same signal as like_count below
    coalesce(vb.requested, 0) as visit_request_count, -- asked to join the next open visit, no slot picked yet
    coalesce(vb.booked, 0)    as visit_booking_count,  -- picked an actual slot
    coalesce(lr.likes, 0)    as like_count,
    coalesce(lr.dislikes, 0) as dislike_count
  from public.inventory i
  left join (
    select property_id,
      count(*) filter (where reaction = 'like')    as likes,
      count(*) filter (where reaction = 'dislike') as dislikes
    from public.listing_reactions
    group by property_id
  ) lr on lr.property_id = i.property_id
  left join (
    select property_id,
      count(*) filter (where status = 'preference')     as requested,
      count(*) filter (where status <> 'preference')     as booked
    from public.visit_bookings
    group by property_id
  ) vb on vb.property_id = i.property_id
  where auth.uid() is not null
    and i.poster_id = auth.uid()
  order by i.created_at desc;
$$;

-- security definer functions run with the owner's privileges, so table-level RLS on
-- inventory/listing_reactions/visit_bookings is bypassed here by design — the
-- `poster_id = auth.uid()` filter above is what keeps each caller scoped to their
-- own listings. Returns only aggregate counts, never who did it.
grant execute on function public.my_listing_stats() to authenticated;

-- ── View counting ────────────────────────────────────────────────────────────
-- inventory's own RLS only lets a poster update their own row, so a renter
-- viewing someone else's listing can't bump view_count directly. This function
-- does the one safe, narrow thing renters need: increment a counter on a listing
-- that isn't theirs, nothing else. Callable while signed out too (browsing the
-- map doesn't require an account).
create or replace function public.increment_listing_view(pid text)
returns void
language sql
security definer
set search_path = public
as $$
  update public.inventory set view_count = coalesce(view_count, 0) + 1 where property_id = pid;
$$;

grant execute on function public.increment_listing_view(text) to anon, authenticated;
