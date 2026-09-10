-- ─────────────────────────────────────────────────────────────────────────────
-- Maintenance is a figure the lister quotes, not one we calculate.
--
-- Run once in the Supabase SQL editor. Idempotent.
--
-- The property page had been showing 8% of rent as "Maintenance (est.)" on
-- every listing, because there was nowhere for a real figure to live. Owners
-- were being made to answer for a monthly charge they never set. This adds the
-- column the posting flows now write; a listing with no figure shows no
-- maintenance row at all.
--
-- Nullable on purpose. 0 would mean "the lister told us it is zero", which is
-- a different statement from "the lister didn't say".
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.inventory
  add column if not exists maintenance numeric;

comment on column public.inventory.maintenance is
  'Monthly maintenance in INR, as quoted by the lister. NULL means not stated — never estimate it.';
