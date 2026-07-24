-- Broker CRM schema (fe/src/pages/BrokerDashboard.jsx).
-- Run this once in the Supabase SQL editor for the project referenced by
-- VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY in fe/.env.

create extension if not exists "pgcrypto";

create table if not exists public.hunters (
  id uuid primary key default gen_random_uuid(),
  broker_id uuid references auth.users(id) default auth.uid(),
  name text not null,
  phone text,
  type text default 'tenant',
  budget_min numeric,
  budget_max numeric,
  preferred_areas text[] default '{}',
  status text default 'new',
  move_in_date date,
  created_at timestamptz not null default now()
);

create table if not exists public.properties (
  id uuid primary key default gen_random_uuid(),
  broker_id uuid references auth.users(id) default auth.uid(),
  title text not null,
  area text,
  bhk_type text,
  rent_amount numeric,
  deposit_amount numeric,
  furnishing text,
  full_address text,
  floor_number int,
  description text,
  status text default 'available',
  city text default 'Bengaluru',
  created_at timestamptz not null default now()
);

create table if not exists public.follow_ups (
  id uuid primary key default gen_random_uuid(),
  broker_id uuid references auth.users(id) default auth.uid(),
  hunter_id uuid references public.hunters(id) on delete cascade,
  type text default 'call',
  scheduled_at timestamptz,
  notes text,
  status text default 'pending',
  created_at timestamptz not null default now()
);

create table if not exists public.tasks (
  id uuid primary key default gen_random_uuid(),
  broker_id uuid references auth.users(id) default auth.uid(),
  title text not null,
  priority text default 'medium',
  due_date date,
  status text default 'pending',
  created_at timestamptz not null default now()
);

create table if not exists public.visit_schedules (
  id uuid primary key default gen_random_uuid(),
  broker_id uuid references auth.users(id) default auth.uid(),
  hunter_id uuid references public.hunters(id) on delete cascade,
  property_id uuid references public.properties(id) on delete cascade,
  scheduled_at timestamptz,
  notes text,
  status text default 'pending',
  created_at timestamptz not null default now()
);

create table if not exists public.property_matches (
  id uuid primary key default gen_random_uuid(),
  broker_id uuid references auth.users(id) default auth.uid(),
  hunter_id uuid references public.hunters(id) on delete cascade,
  property_id uuid references public.properties(id) on delete cascade,
  match_score numeric,
  notes text,
  status text default 'pending',
  created_at timestamptz not null default now()
);

create table if not exists public.broker_whatsapp_contacts (
  id uuid primary key default gen_random_uuid(),
  broker_id uuid references auth.users(id),
  property_id text,
  property_title text,
  property_area text,
  rent_amount numeric,
  customer_uid text,
  customer_name text,
  customer_email text,
  customer_phone text,
  broker_phone_last4 text,
  message text,
  source text default 'property_whatsapp',
  user_agent text,
  created_at timestamptz not null default now()
);

create index if not exists broker_whatsapp_contacts_broker_created_idx
  on public.broker_whatsapp_contacts (broker_id, created_at desc);

create index if not exists broker_whatsapp_contacts_customer_created_idx
  on public.broker_whatsapp_contacts (customer_email, created_at desc);

-- Tables created via raw SQL don't automatically get any access for Supabase's
-- `anon`/`authenticated` roles (unlike tables made in the dashboard Table
-- Editor) — without this, every request fails with "insufficient_privilege"
-- (42501) before RLS policies are even evaluated, regardless of how correct
-- those policies are. RLS (enabled below) still restricts which *rows* each
-- role can touch; this just allows the *table* to be touched at all.
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on
  public.hunters,
  public.properties,
  public.follow_ups,
  public.tasks,
  public.visit_schedules,
  public.property_matches,
  public.broker_whatsapp_contacts
to authenticated;
grant select on public.properties to anon;

-- Every "type"/"status"/"priority" column above is declared `text` — no fixed
-- vocabulary. If any of them were later converted to a Postgres enum directly
-- in the database (as happened to `hunters.type` → `hunter_type`, outside of
-- this file), the frontend's free-form values have no way to match the enum's
-- exact labels and get rejected ("invalid input value for enum ..."). Convert
-- any such column back to plain text so it matches what's declared above.
--
-- RLS policies that reference the column (also possibly created out-of-band,
-- e.g. "Anyone can view available properties" on properties.status) block the
-- type change until they're dropped — Postgres won't say which ones up front,
-- so we drop every policy on a table before touching its columns and rely on
-- the policy blocks further down (plus the explicit recreation below) to put
-- everything back.
do $$
declare
  tbl text;
  affected_cols text[];
  col text;
  pol record;
begin
  foreach tbl in array array['hunters', 'properties', 'follow_ups', 'tasks', 'visit_schedules', 'property_matches']
  loop
    affected_cols := array(
      select column_name
      from information_schema.columns
      where table_schema = 'public' and table_name = tbl and data_type = 'USER-DEFINED'
        and column_name = any (
          case tbl
            when 'hunters' then array['type', 'status']
            when 'properties' then array['status']
            when 'follow_ups' then array['type', 'status']
            when 'tasks' then array['priority', 'status']
            when 'visit_schedules' then array['status']
            when 'property_matches' then array['status']
            else array[]::text[]
          end
        )
    );

    if affected_cols is null or array_length(affected_cols, 1) is null then
      continue;
    end if;

    for pol in select policyname from pg_policies where schemaname = 'public' and tablename = tbl loop
      execute format('drop policy if exists %I on public.%I;', pol.policyname, tbl);
    end loop;

    foreach col in array affected_cols loop
      -- A default tied to the enum (e.g. DEFAULT 'tenant'::hunter_type) blocks
      -- the type change unless dropped first — otherwise this errors with
      -- "default ... cannot be cast automatically to type text" and nothing
      -- below it in this DO block runs. Drop it, convert, restore as text.
      execute format('alter table public.%I alter column %I drop default;', tbl, col);
      execute format('alter table public.%I alter column %I type text using %I::text;', tbl, col, col);
    end loop;
  end loop;
end $$;

alter table public.hunters alter column type set default 'tenant';
alter table public.hunters alter column status set default 'new';
alter table public.properties alter column status set default 'available';
alter table public.follow_ups alter column type set default 'call';
alter table public.follow_ups alter column status set default 'pending';
alter table public.tasks alter column priority set default 'medium';
alter table public.tasks alter column status set default 'pending';
alter table public.visit_schedules alter column status set default 'pending';
alter table public.property_matches alter column status set default 'pending';

-- Recreate the out-of-band public-read policy this migration just dropped
-- (now against the plain-text column, so it no longer depends on the enum).
drop policy if exists "Anyone can view available properties" on public.properties;
create policy "Anyone can view available properties"
  on public.properties
  for select
  to anon, authenticated
  using (status = 'available');

-- Row Level Security: each signed-in broker only sees/edits their own rows
-- (admins can manage any broker's rows too, e.g. editing a listing from
-- /admin — without this, admin@... writes trip RLS with "new row violates
-- row-level security policy" since their uid never matches broker_id).
alter table public.hunters enable row level security;
alter table public.properties enable row level security;
alter table public.follow_ups enable row level security;
alter table public.tasks enable row level security;
alter table public.visit_schedules enable row level security;
alter table public.property_matches enable row level security;
alter table public.broker_whatsapp_contacts enable row level security;

do $$
declare
  t text;
begin
  foreach t in array array['hunters', 'properties', 'follow_ups', 'tasks', 'visit_schedules', 'property_matches']
  loop
    execute format('drop policy if exists "brokers manage own rows" on public.%I;', t);
    execute format(
      'create policy "brokers manage own rows" on public.%I
         for all using (broker_id = auth.uid() or public.is_admin_allowlisted())
         with check (broker_id = auth.uid() or public.is_admin_allowlisted());',
      t
    );
  end loop;
end $$;

drop policy if exists "authenticated users create whatsapp contacts" on public.broker_whatsapp_contacts;
create policy "authenticated users create whatsapp contacts"
  on public.broker_whatsapp_contacts
  for insert
  to authenticated
  with check (true);

drop policy if exists "brokers read own whatsapp contacts" on public.broker_whatsapp_contacts;
create policy "brokers read own whatsapp contacts"
  on public.broker_whatsapp_contacts
  for select
  to authenticated
  using (
    broker_id = auth.uid()
    or (
      property_id is not null
      and exists (
        select 1
        from public.properties p
        where p.id::text = broker_whatsapp_contacts.property_id
          and p.broker_id = auth.uid()
      )
    )
  );
