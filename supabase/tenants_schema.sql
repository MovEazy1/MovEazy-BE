-- Owner ↔ tenant mapping — fe/src/pages/TenantManagement.jsx "+ Add Tenant".
-- Lets an owner record who's actually renting each property (name, contact,
-- rent, due day) and invite them to MovEazy. This is separate from
-- rent_payments (rent_payments_schema.sql), which tracks month-by-month
-- paid/due state once a tenant exists here.
--
-- v1 is owner-write-only: the invited tenant isn't linked to their own auth
-- account yet (tenant_user_id is a placeholder for that future step — once a
-- signed-in user's email matches an unlinked row, the app can offer to claim
-- it). For now the tenant only receives an email/message; they don't get their
-- own read access to this table.
--
-- Run once in the Supabase SQL editor, AFTER inventory_schema.sql. Safe to
-- re-run (create-if-not-exists + drop/recreate policy).

create table if not exists public.tenants (
  id             uuid primary key default gen_random_uuid(),
  property_id    text not null references public.inventory(property_id) on delete cascade,
  poster_id      uuid not null references auth.users(id) on delete cascade default auth.uid(),
  tenant_user_id uuid references auth.users(id) on delete set null, -- linked once the tenant signs in with a matching account (future step)
  name           text not null,
  phone          text not null default '',
  email          text not null default '',
  rent_amount    numeric not null default 0,
  rent_due_day   int not null default 1 check (rent_due_day between 1 and 28),
  status         text not null default 'invited' check (status in ('invited', 'active', 'removed')),
  invited_at     timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create index if not exists tenants_property_idx on public.tenants (property_id);
create index if not exists tenants_poster_idx on public.tenants (poster_id);

alter table public.tenants enable row level security;

drop policy if exists "owners manage own tenants" on public.tenants;
create policy "owners manage own tenants" on public.tenants
  for all
  to authenticated
  using (poster_id = auth.uid())
  with check (poster_id = auth.uid());

grant select, insert, update, delete on public.tenants to authenticated;
