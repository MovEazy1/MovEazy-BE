-- ─────────────────────────────────────────────────────────────────────────────
-- CRM staff can set a property's open visit times.
--
-- Run once in the Supabase SQL editor, after crm_schema.sql and
-- poster_visit_slots.sql. Idempotent.
--
-- property_visit_slots is writable by the person who posted the listing, or by
-- the hardcoded super-admin allowlist. Neither covers a CRM manager working an
-- inventory row somebody else posted — and setting visit times is most of what
-- that job is. This adds them, behind the same scope that already governs
-- editing a property.
--
-- Reads are untouched: renters still see every slot through "anyone reads
-- slots".
-- ─────────────────────────────────────────────────────────────────────────────

drop policy if exists "crm staff write slots" on public.property_visit_slots;
create policy "crm staff write slots"
  on public.property_visit_slots for all
  to authenticated
  using (public.has_admin_scope('crm.properties.write'))
  with check (public.has_admin_scope('crm.properties.write'));
