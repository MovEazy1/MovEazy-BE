-- Renter action log (fe/src/lib/userActions.js). One row per meaningful action a
-- user takes — shortlisting a property, submitting a visit preference, etc. Lets
-- the admin panel review activity both user-wise ("what did this user do") and
-- property-wise ("who is interested in this home").
--
-- Run once in the Supabase SQL editor, AFTER admin_schema.sql (needs
-- public.is_admin_allowlisted()).

create extension if not exists "pgcrypto";

create table if not exists public.user_actions (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade default auth.uid(),
  email        text default '',
  action       text not null,                 -- 'shortlist_property' | 'visit_preference_submitted' | ...
  property_id  text,                           -- the property involved, when applicable
  details      jsonb default '{}'::jsonb,      -- free-form extra context (title, slot_at, …)
  created_at   timestamptz not null default now()
);

create index if not exists ua_user_idx     on public.user_actions (user_id, created_at desc);
create index if not exists ua_property_idx on public.user_actions (property_id, created_at desc);
create index if not exists ua_action_idx   on public.user_actions (action);

alter table public.user_actions enable row level security;

-- Users can write their own actions and read them back; admins can read/manage all.
drop policy if exists "users insert own actions" on public.user_actions;
create policy "users insert own actions"
  on public.user_actions for insert
  to authenticated
  with check (user_id = auth.uid());

drop policy if exists "users read own actions or admin" on public.user_actions;
create policy "users read own actions or admin"
  on public.user_actions for select
  to authenticated
  using (user_id = auth.uid() or public.is_admin_allowlisted());

drop policy if exists "admins manage actions" on public.user_actions;
create policy "admins manage actions"
  on public.user_actions for all
  to authenticated
  using (public.is_admin_allowlisted())
  with check (public.is_admin_allowlisted());

grant usage on schema public to anon, authenticated;
grant select, insert on public.user_actions to authenticated;
grant delete, update on public.user_actions to authenticated; -- admin-gated by RLS
