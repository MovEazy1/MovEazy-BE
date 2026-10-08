-- "Remind me in X hours" for the daily follow-up queue.
--
-- The CRM had no list of what clients had just done. Somebody opened a
-- shortlist, asked for a visit, reacted to a flat — and unless an agent went
-- looking at that client's record, nothing said so. The Notifications tab now
-- has a Daily tasks list built from crm_activities, and this is the one piece
-- of state it needs that cannot be derived: a row an agent has dealt with, and
-- when it should come back.
--
-- One row per client, not per activity. An agent follows up with a person, not
-- with an event, and a client who did four things this morning is one call.
-- Snoozing again just moves the time, which is why client_id is the key.
--
-- A snoozed client reappears on either of two triggers, and the second is the
-- point of the whole thing:
--   * the clock runs out (now >= remind_at), or
--   * they do something new (an activity newer than snoozed_at).
-- The second is why snoozed_at is stored alongside remind_at. Without it a
-- client who replied thirty seconds after being snoozed would stay hidden for
-- the rest of the day.

create table if not exists public.crm_task_snoozes (
  client_id   uuid primary key references public.crm_clients(id) on delete cascade,
  snoozed_at  timestamptz not null default now(),
  remind_at   timestamptz not null,
  actor_email text default '',
  note        text default ''
);

comment on table public.crm_task_snoozes is
  'Follow-ups an agent has parked. One row per client; the task returns when remind_at passes or the client acts again after snoozed_at.';

create index if not exists crm_task_snoozes_remind_idx
  on public.crm_task_snoozes (remind_at);

alter table public.crm_task_snoozes enable row level security;

-- The whole team works the same queue, so any CRM staffer can park an item and
-- any of them can see it parked. Hiding one agent's snooze from another would
-- mean two people ringing the same client an hour apart.
drop policy if exists "crm staff read snoozes" on public.crm_task_snoozes;
create policy "crm staff read snoozes"
  on public.crm_task_snoozes for select
  to authenticated
  using (public.is_crm_staff());

drop policy if exists "crm staff write snoozes" on public.crm_task_snoozes;
create policy "crm staff write snoozes"
  on public.crm_task_snoozes for all
  to authenticated
  using (public.is_crm_staff())
  with check (public.is_crm_staff());


-- ── Verify ───────────────────────────────────────────────────────────────────
-- As signed-in staff, this should return an empty table rather than an error:
--
--   select * from public.crm_task_snoozes;
--
-- And the anon key must get nothing at all — no view is added over this, for
-- the same reason the lead views needed locking down: a view over an
-- RLS-protected table is only as safe as its security_invoker setting.
