-- Who the flat actually came from, and who to ring about it.
--
-- The CRM uploads a listing from a WhatsApp forward, a broker's list, or an
-- owner walking in. Which of those it was, and the number of the person on the
-- other end, is the most useful thing about a listing internally -- and the one
-- thing that must never reach a tenant.
--
-- == Why a separate table, not columns on inventory ==
--
-- inventory already carries poster_name / phone / poster_email, and those are
-- kept off the public read by COLUMN grants (inventory_public_columns.sql):
-- anon holds select on a named list of columns, so `select=*` fails outright
-- for a signed-out visitor. That is real protection, and it is also the whole
-- of it -- because:
--
--     grant select on public.inventory to anon, authenticated;   (inventory_schema.sql)
--
-- was only ever revoked for anon. `authenticated` still holds select on EVERY
-- column, and the row policy is `status = 'published' or ...`. So any tenant
-- with an account -- which is every tenant, the flow requires Google sign-in --
-- can read the poster's phone and email of every published flat today.
--
-- A new column on inventory would inherit exactly that. So the internal
-- details live in their own table, granted to `authenticated` only because
-- PostgREST needs a grant to consider a request at all, with every row gated
-- behind is_crm_staff(). A signed-in tenant gets an empty array rather than a
-- denial: there is nothing here to notice.
--
-- No view over either table. A view runs as its owner and bypasses the RLS of
-- the tables underneath unless declared `security_invoker = true` -- that is
-- how the lead views leaked (lead_intake_view_lockdown.sql). The CRM reads
-- these tables directly and there is no reason to add one.
--
-- Run once in the Supabase SQL editor. Safe to re-run.


-- == Broker directory ========================================================
-- Every broker typed into the upload form is kept, so the next upload picks
-- them from a list instead of retyping a name and number that then disagree
-- with last time's spelling.
create table if not exists public.crm_brokers (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  phone       text not null default '',
  -- The match key. Two agents typing "98765 43210" and "+919876543210" mean
  -- the same broker, and a directory holding both is not a directory.
  phone_norm  text generated always as (public.normalize_mobile(phone)) stored,
  agency      text not null default '',
  email       text not null default '',
  notes       text not null default '',
  created_at  timestamptz not null default now(),
  created_by  text not null default '',
  -- Sorts the dropdown by who is actually being used, not who was typed first.
  last_used_at timestamptz
);

-- Unique on the normalised number, but only where there is one: brokers
-- entered without a phone should not all collide with each other.
create unique index if not exists crm_brokers_phone_norm_key
  on public.crm_brokers (phone_norm)
  where phone_norm <> '';
create index if not exists crm_brokers_recent_idx
  on public.crm_brokers (last_used_at desc nulls last, name);

comment on table public.crm_brokers is
  'Internal broker directory for CRM uploads. Staff only -- never exposed to tenants.';


-- == Per-listing internal details ============================================
create table if not exists public.inventory_private (
  property_id text primary key
    references public.inventory (property_id) on delete cascade,

  -- How the flat reached us. Deliberately NOT inventory.posted_by, which is a
  -- public column rendered to tenants as "Owner / Broker / Tenant" on the
  -- property card. This one is ours, and the two are free to disagree -- a flat
  -- listed as the owner's may well have reached us through a broker.
  source      text not null default 'owner'
    check (source in ('tenant', 'broker', 'owner')),
  broker_id   uuid references public.crm_brokers (id) on delete set null,

  -- Who to actually contact about this flat.
  poc_name    text not null default '',
  poc_phone   text not null default '',
  poc_email   text not null default '',
  poc_note    text not null default '',

  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  text not null default ''
);

create index if not exists inventory_private_broker_idx
  on public.inventory_private (broker_id);

comment on table public.inventory_private is
  'Internal-only details per listing: where it came from and who to ring. Staff only -- no anon grant, no view, never joined into a customer read.';


-- == Access ==================================================================
alter table public.crm_brokers       enable row level security;
alter table public.inventory_private enable row level security;

-- Reading: any CRM staff. They need the POC to do the job the tab exists for.
drop policy if exists "staff read brokers" on public.crm_brokers;
create policy "staff read brokers"
  on public.crm_brokers for select
  to authenticated
  using (public.is_crm_staff());

drop policy if exists "staff read private details" on public.inventory_private;
create policy "staff read private details"
  on public.inventory_private for select
  to authenticated
  using (public.is_crm_staff());

-- Writing: the same scope that lets someone upload a property in the first
-- place. Anyone who can create the listing can record where it came from.
drop policy if exists "property staff write brokers" on public.crm_brokers;
create policy "property staff write brokers"
  on public.crm_brokers for all
  to authenticated
  using (public.has_admin_scope('crm.properties.write'))
  with check (public.has_admin_scope('crm.properties.write'));

drop policy if exists "property staff write private details" on public.inventory_private;
create policy "property staff write private details"
  on public.inventory_private for all
  to authenticated
  using (public.has_admin_scope('crm.properties.write'))
  with check (public.has_admin_scope('crm.properties.write'));


-- == Lock down ===============================================================
--
-- Stated after the tables exist so the file is safe to re-run and so a later
-- edit cannot separate the revoke from the definition.
--
-- `revoke ... from public` only touches the PUBLIC pseudo-role and leaves an
-- explicit grant to a named role standing, so anon is named outright. Nothing
-- signed-out has any business here: there is no public read of these tables at
-- any column, and the frontend never asks for one.
revoke all on public.crm_brokers       from public, anon;
revoke all on public.inventory_private from public, anon;

-- authenticated gets the grant PostgREST requires to evaluate a request at
-- all; the policies above decide whether any row comes back. A tenant's
-- request is well-formed, permitted, and returns nothing.
grant select, insert, update, delete on public.crm_brokers       to authenticated;
grant select, insert, update, delete on public.inventory_private to authenticated;


-- == Verify ==================================================================
-- 1. anon holds nothing on either table (expect zero rows):
--
--      select table_name, privilege_type
--        from information_schema.role_table_grants
--       where grantee = 'anon'
--         and table_name in ('crm_brokers', 'inventory_private');
--
-- 2. Both are RLS-enabled, and every policy is scoped to authenticated only
--    (expect relrowsecurity = true and polroles = {authenticated}):
--
--      select c.relname, c.relrowsecurity, p.polname, p.polroles::regrole[]
--        from pg_class c left join pg_policy p on p.polrelid = c.oid
--       where c.relname in ('crm_brokers', 'inventory_private');
--
-- 3. From outside, with the publishable key that ships in the JS bundle --
--    both must FAIL, not return []:
--
--      curl "$URL/rest/v1/inventory_private?select=*" -H "apikey: $ANON"
--      curl "$URL/rest/v1/crm_brokers?select=*"       -H "apikey: $ANON"
--    => {"code":"42501","message":"permission denied for table ..."}
