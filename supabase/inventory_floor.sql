-- ─────────────────────────────────────────────────────────────────────────────
-- Which floor the flat is on.
--
-- Run once in the Supabase SQL editor. Idempotent.
--
-- The property page has always had a "Floor / total floors" row, but nothing
-- ever filled it: no posting flow asked, and there was no column to put it in.
-- It's among the first things a renter asks — top floor in a Bengaluru summer,
-- or a third floor with no lift, changes the answer.
--
-- Nullable on purpose. 0 is a real answer (ground floor), so it cannot double
-- as "not stated".
--
-- The GRANT is not optional. public.inventory does not give `anon` table-wide
-- select — it grants an explicit column list — so a column added without one is
-- readable signed in and answers 42501, "permission denied for table", to
-- everyone signed out. That fails the WHOLE select, not just the column, and it
-- emptied the public map once already.
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.inventory
  add column if not exists floor_number int,
  add column if not exists total_floors int;

comment on column public.inventory.floor_number is
  'Floor the flat is on. 0 = ground. NULL means not stated.';
comment on column public.inventory.total_floors is
  'Floors in the building. NULL means not stated.';

grant select (floor_number, total_floors) on public.inventory to anon, authenticated;

-- Verify: four rows — both columns, for anon and authenticated.
select column_name, grantee, privilege_type
  from information_schema.column_privileges
 where table_schema = 'public'
   and table_name = 'inventory'
   and column_name in ('floor_number', 'total_floors')
   and grantee in ('anon', 'authenticated')
 order by column_name, grantee;
