-- Keep the board honest: ask whether a flat is still going.
--
-- A listing goes up and stays up. Nothing ever asked the owner whether it was
-- taken, so the site accumulates flats that were let weeks ago — and a tenant
-- who asks to see one of those learns it the hard way, which costs more than
-- the listing was ever worth.
--
-- The CRM's Notifications tab now has a follow-up queue of anything published
-- more than a week ago and not checked since. This is the one column it needs:
-- when somebody last confirmed it.
--
-- No new status constraint is required. inventory.status is plain text, and
-- the public read policy is `status = 'published' or poster_id = auth.uid()
-- or is_admin_allowlisted()`. So writing 'dormant' takes a flat off the site
-- for everyone while leaving it whole, visible to its owner and to us —
-- dormant rather than deleted, because an owner who re-lets next month should
-- not have to type it all again.

alter table public.inventory
  add column if not exists availability_checked_at timestamptz,
  add column if not exists availability_note       text default '';

comment on column public.inventory.availability_checked_at is
  'When somebody last confirmed with the owner that this flat is still going. Null means never asked.';
comment on column public.inventory.availability_note is
  'What the owner said at that check, in their words.';

-- The queue reads exactly this: published, old, and not recently confirmed.
create index if not exists inventory_availability_due_idx
  on public.inventory (availability_checked_at nulls first, created_at)
  where status = 'published';


-- ── Backfill ─────────────────────────────────────────────────────────────────
-- Everything already published has never been checked, which is true and is
-- what null means — so there is nothing to backfill. The queue will open with
-- every listing older than a week in it, which is the real backlog rather than
-- an artefact.


-- ── Verify ───────────────────────────────────────────────────────────────────
-- What the follow-up queue will show, newest listings last:
--
--   select property_id, title, area, created_at, availability_checked_at
--     from public.inventory
--    where status = 'published'
--      and created_at < now() - interval '7 days'
--      and (availability_checked_at is null
--           or availability_checked_at < now() - interval '7 days')
--    order by availability_checked_at nulls first, created_at;
--
-- And, once the tab has been used, what went dormant:
--
--   select property_id, title, availability_note, availability_checked_at
--     from public.inventory
--    where status = 'dormant'
--    order by availability_checked_at desc;
