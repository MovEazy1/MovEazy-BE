-- ─────────────────────────────────────────────────────────────────────────────
-- The CRM's "Curate list" screen.
--
-- Run in the Supabase SQL editor AFTER crm_schema.sql and crm_curated_shares.sql.
-- Safe to re-run.
--
--   crm_curated_shares.status / sent_at / updated_at
--       A list can be saved as a draft (kept on the client, link not sent yet)
--       and sent later. Lists made before this were all sent when made.
--
--   crm_client_passes
--       An agent's "Pass" while curating: that flat doesn't come back when
--       curating for this client again (Matches still shows it).
--
--   crm_client_requirements.office_radius_km
--       How far from the client's office a flat may be and still count as
--       "their area" when pre-selecting from earlier lists. 8 km, straight line,
--       unless an agent changes it.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

alter table public.crm_curated_shares add column if not exists status text not null default 'sent';
alter table public.crm_curated_shares add column if not exists sent_at timestamptz;
alter table public.crm_curated_shares add column if not exists updated_at timestamptz not null default now();
alter table public.crm_curated_shares drop constraint if exists crm_curated_shares_status_check;
alter table public.crm_curated_shares add constraint crm_curated_shares_status_check check (status in ('draft', 'sent'));
-- Everything before drafts existed went out the moment it was made.
update public.crm_curated_shares set sent_at = created_at where status = 'sent' and sent_at is null;
create index if not exists crm_curated_shares_recent_idx on public.crm_curated_shares (created_at desc);

-- An agent's "Pass" while curating: kept apart from crm_shortlists, so passing
-- on a flat the client already saw never overwrites what they said about it.
create table if not exists public.crm_client_passes (
  client_id  uuid not null references public.crm_clients(id) on delete cascade,
  property_id text not null,
  passed_by  text not null default '',
  passed_at  timestamptz not null default now(),
  primary key (client_id, property_id)
);
alter table public.crm_client_passes enable row level security;
drop policy if exists "crm read client passes" on public.crm_client_passes;
create policy "crm read client passes" on public.crm_client_passes for select to authenticated
  using (public.is_crm_staff());
drop policy if exists "crm write client passes" on public.crm_client_passes;
create policy "crm write client passes" on public.crm_client_passes for all to authenticated
  using (public.has_admin_scope('crm.clients.write'))
  with check (public.has_admin_scope('crm.clients.write'));
revoke all on public.crm_client_passes from anon;
grant select, insert, update, delete on public.crm_client_passes to authenticated;

alter table public.crm_client_requirements add column if not exists office_radius_km numeric not null default 8;
alter table public.crm_client_requirements drop constraint if exists crm_client_requirements_radius_check;
alter table public.crm_client_requirements add constraint crm_client_requirements_radius_check
  check (office_radius_km > 0 and office_radius_km <= 100);

commit;
