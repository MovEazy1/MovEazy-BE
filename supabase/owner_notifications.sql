-- Owner notification feed — "fresh leads / visits to your properties" bell in
-- fe/src/components/layout/MovEazyNav.jsx. Returns individual timestamped events
-- (unlike my_listing_stats(), which is aggregate-only by design) so the FE can
-- show "X liked your 2BHK in Bellandur, 3h ago" and a badge count of unseen ones.
--
-- Run once in the Supabase SQL editor, AFTER owner_dashboard_stats.sql (needs
-- public.inventory, public.listing_reactions, public.visit_bookings — see
-- visits_schema.sql / inventory_schema.sql).

create or replace function public.my_recent_activity(days int default 14, limit_n int default 50)
returns table (
  event_type   text,          -- 'like' | 'visit_request' | 'visit_booking'
  property_id  text,
  title        text,
  occurred_at  timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select * from (
    select
      'like'::text as event_type,
      lr.property_id,
      i.title,
      lr.updated_at as occurred_at
    from public.listing_reactions lr
    join public.inventory i on i.property_id = lr.property_id
    where i.poster_id = auth.uid()
      and lr.reaction = 'like'
      and lr.updated_at > now() - make_interval(days => days)

    union all

    select
      case when vb.status = 'preference' then 'visit_request' else 'visit_booking' end,
      vb.property_id,
      i.title,
      vb.created_at
    from public.visit_bookings vb
    join public.inventory i on i.property_id = vb.property_id
    where i.poster_id = auth.uid()
      and vb.created_at > now() - make_interval(days => days)
  ) events
  where auth.uid() is not null
  order by occurred_at desc
  limit limit_n;
$$;

-- security definer bypasses RLS on listing_reactions/visit_bookings by design; the
-- `i.poster_id = auth.uid()` join condition (re-checked here since RLS is bypassed)
-- is what keeps each caller scoped to only their own properties' activity — never
-- another owner's, and no PII about who liked/booked, just what happened and when.
grant execute on function public.my_recent_activity(int, int) to authenticated;

-- ── Booked visits on one of my properties ────────────────────────────────────
-- visit_bookings is RLS'd to `user_id = auth.uid()`, so a poster cannot read who
-- booked their own listing. This exposes exactly the slot times (and how many
-- people are coming), scoped to properties the caller posted — no renter
-- identity, matching how my_listing_stats() stays aggregate-only.
create or replace function public.my_property_visits(pid text)
returns table (
  slot_at    timestamptz,
  kind       text,
  status     text,
  visitors   bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select vb.slot_at, min(vb.kind) as kind, min(vb.status) as status, count(*) as visitors
  from public.visit_bookings vb
  join public.inventory i on i.property_id = vb.property_id
  where i.poster_id = auth.uid()
    and vb.property_id = pid
    and vb.slot_at is not null      -- 'preference' rows have no time yet
    and vb.status <> 'preference'   -- only visits the renter actually finalised
  group by vb.slot_at
  order by vb.slot_at asc;          -- nearest date first
$$;

grant execute on function public.my_property_visits(text) to authenticated;
