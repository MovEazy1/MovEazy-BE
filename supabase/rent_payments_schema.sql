-- Rent Management (fe/src/pages/RentManagement.jsx, /rent-management) — a simple
-- manual rent tracker for owners. No payment processing: the owner just marks each
-- rented property's month as paid or due themselves; this is a record-keeping tool,
-- not a collection system.
--
-- Run once in the Supabase SQL editor, AFTER inventory_schema.sql.

create table if not exists public.rent_payments (
  id          uuid primary key default gen_random_uuid(),
  property_id text not null references public.inventory(property_id) on delete cascade,
  poster_id   uuid not null references auth.users(id) on delete cascade,
  period      date not null, -- first of the month this record covers, e.g. 2026-09-01
  amount      numeric,
  status      text not null default 'due' check (status in ('due', 'paid')),
  paid_at     timestamptz,
  notes       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (property_id, period)
);

create index if not exists rent_payments_poster_idx on public.rent_payments (poster_id);
create index if not exists rent_payments_property_idx on public.rent_payments (property_id);

alter table public.rent_payments enable row level security;

drop policy if exists "posters manage own rent records" on public.rent_payments;
create policy "posters manage own rent records" on public.rent_payments
  for all
  to authenticated
  using (poster_id = auth.uid() or public.is_admin_allowlisted())
  with check (poster_id = auth.uid() or public.is_admin_allowlisted());

grant select, insert, update, delete on public.rent_payments to authenticated;
