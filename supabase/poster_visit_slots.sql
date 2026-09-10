-- Poster-managed open visit slots
-- ---------------------------------
-- By default property_visit_slots is admin-write-only. This lets the PERSON WHO
-- POSTED a listing (owner / tenant / broker) add & remove its open visit slots too.
-- Run once in the Supabase SQL editor, AFTER visits_schema.sql + inventory_schema.sql.
--
-- Safe to re-run (drops+recreates the policy). Read access is unchanged: renters
-- still see all slots via the existing "anyone reads slots" select policy.

-- Replace the admin-only write policy with a poster-or-admin write policy.
drop policy if exists "admins write slots" on public.property_visit_slots;
drop policy if exists "posters manage own slots" on public.property_visit_slots;

create policy "posters manage own slots" on public.property_visit_slots
  for all
  to authenticated
  using (
    public.is_admin_allowlisted()
    or exists (
      select 1 from public.inventory inv
      where inv.property_id = property_visit_slots.property_id
        and inv.poster_id = auth.uid()
    )
  )
  with check (
    public.is_admin_allowlisted()
    or exists (
      select 1 from public.inventory inv
      where inv.property_id = property_visit_slots.property_id
        and inv.poster_id = auth.uid()
    )
  );

-- Grants already allow authenticated insert/update/delete (see visits_schema.sql).
-- Mark-as-sold needs NO change here: inventory already has "posters update own inventory".
