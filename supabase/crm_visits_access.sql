-- ─────────────────────────────────────────────────────────────────────────────
-- The CRM can see, and follow up on, every booked visit.
--
-- Run once in the Supabase SQL editor, after crm_schema.sql. Idempotent.
--
-- Until now visit_bookings was readable only by the renter who made it and by
-- the hardcoded super-admin allowlist. A CRM manager — the person who actually
-- has to be at the flat — could not see a single booking. This adds the staff
-- policies, plus two columns recording that a reminder or a confirmation went
-- out, so two agents don't message the same client twice and nobody is left
-- wondering whether anyone told them.
--
-- The timestamps say a message was *sent from the CRM*, not that the client
-- read it: WhatsApp opens in its own window and never reports back. That is
-- what the UI claims too.
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.visit_bookings
  add column if not exists reminder_sent_at     timestamptz,
  add column if not exists reminder_sent_by     text,
  add column if not exists confirmation_sent_at timestamptz,
  add column if not exists confirmation_sent_by text;

-- Every screen in the visits tab reads by time, not by user.
create index if not exists vb_slot_idx on public.visit_bookings (slot_at);
create index if not exists vb_property_idx on public.visit_bookings (property_id, slot_at);

-- Staff read every booking. Policies are permissive and OR together, so the
-- renter's own "users manage own bookings" is untouched.
drop policy if exists "crm staff read visit bookings" on public.visit_bookings;
create policy "crm staff read visit bookings"
  on public.visit_bookings for select
  to authenticated
  using (public.is_crm_staff());

-- Writing is narrower than reading: recording a send, or rescheduling, needs
-- crm.visits.write. Note the existing renter policy's WITH CHECK demands
-- user_id = auth.uid(); this one is what lets a staff row through.
drop policy if exists "crm staff update visit bookings" on public.visit_bookings;
create policy "crm staff update visit bookings"
  on public.visit_bookings for update
  to authenticated
  using (public.has_admin_scope('crm.visits.write'))
  with check (public.has_admin_scope('crm.visits.write'));
