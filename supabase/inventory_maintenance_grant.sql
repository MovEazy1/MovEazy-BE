-- ─────────────────────────────────────────────────────────────────────────────
-- Let signed-out visitors read inventory.maintenance.
--
-- Run once in the Supabase SQL editor. Idempotent.
--
-- public.inventory does not give `anon` table-wide select; it grants an
-- explicit list of columns, deliberately excluding phone, poster_email,
-- poster_name and the various owner ids. A column added later therefore
-- inherits no grant at all — and Postgres answers a select naming it with
-- 42501, "permission denied for table inventory", failing the WHOLE request
-- rather than omitting that column.
--
-- The effect is invisible to anyone signed in and total for anyone who is not:
-- every listing disappeared from the public map until someone opened it in a
-- private window. `maintenance` is not private — it is a figure the lister
-- quotes and renters need — so it belongs in the public set.
-- ─────────────────────────────────────────────────────────────────────────────

grant select (maintenance) on public.inventory to anon, authenticated;

-- Verify: this must return two rows, anon and authenticated.
select grantee, privilege_type
  from information_schema.column_privileges
 where table_schema = 'public'
   and table_name = 'inventory'
   and column_name = 'maintenance'
   and grantee in ('anon', 'authenticated')
 order by grantee;
