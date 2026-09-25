-- Which flats has each client shown interest in?
--
-- A client who never finishes Find My Flat shows up in the CRM as "not set"
-- across the board -- area, budget, flat type -- even when they have plainly
-- told us what they want by what they opened. A lead who arrives on a shared
-- link to a 2 BHK in JP Nagar at 27k has answered three of those questions.
--
-- That evidence is spread across four tables, none of which the CRM reads for
-- this. This returns it in one request, so the CRM can fill the gaps until the
-- client gives real answers. It is read-only: nothing is written into the
-- client's requirement, so the moment they answer for themselves, their
-- answers win and this stops being consulted.
--
-- The signals, and why each is here:
--   opened_link   lead_intake.property_id -- the flat whose shared link
--                 brought a direct lead in. Their first choice.
--   booked        visit_bookings -- asked to see it. The strongest signal.
--   liked / okay  listing_reactions -- 'dislike' is deliberately excluded: a
--                 flat they rejected says what they do NOT want.
--   opened_share  crm_shortlists.opened_at -- a flat the team sent that they
--                 opened. Weaker: we chose it, they only clicked.
--
-- Security definer so one call can read across four tables whose policies
-- differ -- reactions and bookings are scoped to the user who made them -- and
-- the join to crm_clients happens in one place. The gate is is_crm_staff()
-- inside the query, and anon cannot execute it at all.
--
-- Run once in the Supabase SQL editor. Safe to re-run.

create or replace function public.crm_client_property_interest()
returns table (client_id uuid, property_id text, signal text, at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  with signals as (
    select l.crm_client_id as client_id, l.property_id, 'opened_link'::text as signal,
           coalesce(l.created_at, l.updated_at) as at
      from public.lead_intake l
     where l.crm_client_id is not null
       and coalesce(l.property_id, '') <> ''

    union all
    select c.id, b.property_id, 'booked', b.created_at
      from public.visit_bookings b
      join public.crm_clients c on c.user_id = b.user_id
     where coalesce(b.property_id, '') <> ''
       and coalesce(b.status, '') not ilike 'cancel%'

    union all
    select c.id, r.property_id,
           case r.reaction when 'like' then 'liked' else 'okay' end,
           r.updated_at
      from public.listing_reactions r
      join public.crm_clients c on c.user_id = r.user_id
     where r.reaction in ('like', 'okay')
       and coalesce(r.property_id, '') <> ''

    union all
    select s.client_id, s.property_id, 'opened_share', s.opened_at
      from public.crm_shortlists s
     where s.opened_at is not null
  ),
  ranked as (
    select s.*, row_number() over (partition by s.client_id order by s.at desc nulls last) as n
      from signals s
  )
  select client_id, property_id, signal, at
    from ranked
   -- Enough to read a pattern from; a client with a hundred reactions does not
   -- need all of them shipped to every CRM page load.
   where n <= 25
     and public.is_crm_staff();
$$;

-- Supabase's default privileges grant execute on new functions to anon
-- explicitly; `revoke ... from public` alone would leave that standing.
revoke all on function public.crm_client_property_interest() from public, anon;
grant execute on function public.crm_client_property_interest() to authenticated;


-- == Verify ==================================================================
-- As a signed-out visitor this must be refused, not return []:
--
--   curl -X POST "$URL/rest/v1/rpc/crm_client_property_interest" -H "apikey: $ANON"
--   => {"code":"42501", "message":"permission denied for function ..."}
--
-- In the SQL editor (runs as postgres, so is_crm_staff() is false and it
-- returns nothing -- that is correct). To see the raw evidence instead:
--
--   select c.name, c.phone, l.property_id
--     from public.lead_intake l join public.crm_clients c on c.id = l.crm_client_id
--    where coalesce(l.property_id, '') <> ''
--    order by l.created_at desc limit 20;
