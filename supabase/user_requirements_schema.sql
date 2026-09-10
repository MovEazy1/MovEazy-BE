-- Per-user requirement profile (fe/src/components/AIBroker.jsx "Find My Flat" →
-- fe/src/lib/userRequirements.js). One row per user, keyed by user_id, capturing
-- everything the guided questionnaire learns about them. Described in the shared
-- vocabulary (fe/src/data/preferenceOptions.js) so it scores directly against
-- public.inventory via fe/src/lib/inventoryMatch.js.
--
-- Run once in the Supabase SQL editor, AFTER admin_schema.sql (needs
-- public.is_admin_allowlisted()).

create extension if not exists "pgcrypto";

create table if not exists public.user_requirements (
  user_id        uuid primary key references auth.users(id) on delete cascade default auth.uid(),
  email          text default '',

  office         jsonb,                        -- { label, lat, lng, display }
  whatsapp       text default '',              -- mandatory WhatsApp number (office step)
  age            text default '',
  localities     text[] default '{}',          -- subset of preferenceOptions localities
  budget_min     numeric,
  budget_max     numeric,
  stretch        boolean default false,        -- willing to stretch ~15% over budget
  occupants      text[] default '{}',          -- subset of OCCUPANTS
  flat_types     text[] default '{}',          -- subset of FLAT_TYPES
  must_haves     text[] default '{}',          -- subset of MUST_HAVES
  lifestyle      text[] default '{}',          -- subset of LIFESTYLE
  deal_breakers  text[] default '{}',          -- subset of DEALBREAKERS
  priority       text[] default '{}',          -- ranked priorities, most important first
  notes          jsonb  default '{}'::jsonb,   -- free-text notes keyed by question id

  last_match_count int default 0,              -- inventory matches at last run (for admin insight)
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

alter table public.user_requirements enable row level security;

drop policy if exists "users manage own requirement" on public.user_requirements;
create policy "users manage own requirement"
  on public.user_requirements for all
  to authenticated
  using (user_id = auth.uid() or public.is_admin_allowlisted())
  with check (user_id = auth.uid());

-- Posters need to read every requirement to find who their new flat matches
-- (fe/src/pages/ListMyFlat.jsx success screen). Requirements are non-sensitive
-- preference data, not contact details, so authenticated read-all is acceptable.
drop policy if exists "authenticated read requirements for matching" on public.user_requirements;
create policy "authenticated read requirements for matching"
  on public.user_requirements for select
  to authenticated
  using (true);

grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on public.user_requirements to authenticated;
