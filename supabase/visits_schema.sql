-- Site-visit + reactions schema (fe: Recommendations.jsx, Visits.jsx, CartContext).
-- Run once in the Supabase SQL editor (after inventory_schema.sql).

create extension if not exists "pgcrypto";

-- ── Like / dislike per listing ─────────────────────────────────────────────
create table if not exists public.listing_reactions (
  user_id     uuid not null references auth.users(id) on delete cascade default auth.uid(),
  property_id text not null,
  reaction    text not null check (reaction in ('like','dislike')),
  updated_at  timestamptz not null default now(),
  primary key (user_id, property_id)
);
alter table public.listing_reactions enable row level security;
drop policy if exists "users manage own reactions" on public.listing_reactions;
create policy "users manage own reactions" on public.listing_reactions for all
  to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ── Admin-entered visit slots, per property ────────────────────────────────
create table if not exists public.property_visit_slots (
  id          uuid primary key default gen_random_uuid(),
  property_id text not null references public.inventory(property_id) on delete cascade,
  slot_at     timestamptz not null,
  capacity    int not null default 5,
  created_at  timestamptz not null default now(),
  unique (property_id, slot_at)
);
create index if not exists pvs_property_idx on public.property_visit_slots (property_id, slot_at);
alter table public.property_visit_slots enable row level security;
-- Anyone can read slots (needed to pick one); only admins write them.
drop policy if exists "anyone reads slots" on public.property_visit_slots;
create policy "anyone reads slots" on public.property_visit_slots for select using (true);
drop policy if exists "admins write slots" on public.property_visit_slots;
create policy "admins write slots" on public.property_visit_slots for all
  to authenticated using (public.is_admin_allowlisted()) with check (public.is_admin_allowlisted());

-- ── Scheduled visits ───────────────────────────────────────────────────────
-- One row per property the user has scheduled. kind='individual' = a per-property
-- slot the user picked (free). kind='combined' = the "view all at once" option;
-- combined rows share group_id and carry the ₹1000 upfront (refundable) fee.
create table if not exists public.visit_bookings (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade default auth.uid(),
  property_id text not null,
  slot_at     timestamptz,
  kind        text not null default 'individual' check (kind in ('individual','combined')),
  group_id    uuid,
  amount      numeric not null default 0,
  status      text not null default 'scheduled',
  created_at  timestamptz not null default now(),
  unique (user_id, property_id)
);
create index if not exists vb_user_idx on public.visit_bookings (user_id, created_at desc);
alter table public.visit_bookings enable row level security;
drop policy if exists "users manage own bookings" on public.visit_bookings;
create policy "users manage own bookings" on public.visit_bookings for all
  to authenticated using (user_id = auth.uid() or public.is_admin_allowlisted()) with check (user_id = auth.uid());

grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on public.listing_reactions to authenticated;
grant select on public.property_visit_slots to anon, authenticated;
grant insert, update, delete on public.property_visit_slots to authenticated;
grant select, insert, update, delete on public.visit_bookings to authenticated;

-- ── Seed admin slots for every current listing (5 slots over the next 3 days) ─
insert into public.property_visit_slots (property_id, slot_at, capacity)
select inv.property_id, s.slot_at, 5
from public.inventory inv
cross join lateral (
  values
    (((now()::date + 1)::text || ' 11:00')::timestamptz),
    (((now()::date + 1)::text || ' 16:00')::timestamptz),
    (((now()::date + 2)::text || ' 12:30')::timestamptz),
    (((now()::date + 2)::text || ' 17:30')::timestamptz),
    (((now()::date + 3)::text || ' 18:00')::timestamptz)
) as s(slot_at)
on conflict (property_id, slot_at) do nothing;
