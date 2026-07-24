-- Admin email allowlist (fe/src/lib/adminAccess.js, /admin dashboard).
-- Run once in the Supabase SQL editor alongside broker_schema.sql.
--
-- Bootstrap: replace with your first admin Gmail before running, or insert after.
-- VITE_ADMIN_EMAILS in fe/.env is also honored as a fallback when the table is empty.

create extension if not exists "pgcrypto";

create table if not exists public.admin_allowlist (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  notes text default '',
  added_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  constraint admin_allowlist_email_unique unique (email)
);

create index if not exists admin_allowlist_email_lower_idx
  on public.admin_allowlist (lower(email));

alter table public.admin_allowlist enable row level security;

-- Helper: signed-in user's email is on the allowlist (or matches env bootstrap via table row).
create or replace function public.is_admin_allowlisted()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.admin_allowlist a
    where lower(a.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

drop policy if exists "allowlisted admins read allowlist" on public.admin_allowlist;
create policy "allowlisted admins read allowlist"
  on public.admin_allowlist for select
  using (
    public.is_admin_allowlisted()
    or lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );

drop policy if exists "allowlisted admins insert allowlist" on public.admin_allowlist;
create policy "allowlisted admins insert allowlist"
  on public.admin_allowlist for insert
  with check (
    public.is_admin_allowlisted()
    or (
      (select count(*) from public.admin_allowlist) = 0
      and lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
    )
  );

drop policy if exists "allowlisted admins delete allowlist" on public.admin_allowlist;
create policy "allowlisted admins delete allowlist"
  on public.admin_allowlist for delete
  using (public.is_admin_allowlisted());

-- Tables created via raw SQL don't automatically get any access for Supabase's
-- `anon`/`authenticated` roles (unlike tables made in the dashboard Table
-- Editor) — without this, direct queries against admin_allowlist (adminAccess.js's
-- fetchAdminAllowlist/addAdminAllowlistEmail/removeAdminAllowlistEmail) fail with
-- "insufficient_privilege" (42501) before RLS policies are even evaluated.
-- is_admin_allowlisted() itself is unaffected — it's `security definer`, so it
-- runs with the function owner's privileges regardless of the caller's grants.
grant usage on schema public to anon, authenticated;
grant select, insert, delete on public.admin_allowlist to authenticated;

-- Bootstrap first admin (edit email, then run):
-- insert into public.admin_allowlist (email, notes)
-- values ('your-admin@gmail.com', 'bootstrap')
-- on conflict (email) do nothing;
