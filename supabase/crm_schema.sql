-- ─────────────────────────────────────────────────────────────────────────────
-- Internal CRM (fe/src/pages/crm/*, fe/src/lib/crm*.js).
--
-- Run ONCE in the Supabase SQL editor, AFTER admin_schema.sql (needs
-- public.is_admin_allowlisted()), customer_schema.sql, inventory_schema.sql and
-- visits_schema.sql. Safe to re-run: every statement is idempotent.
--
-- Access model, in two layers:
--   1. public.admin_roles maps an email -> a role -> a set of scope strings.
--   2. public.has_admin_scope('crm.clients.write') is the single check every
--      policy below is written against. The UI mirrors it (lib/adminScopes.js)
--      but Postgres is the authority — a browser console gets the same answer.
--
-- The super admin email is hardcoded here exactly as it is in the frontend
-- (lib/adminAccess.js). admin.roles.write is never grantable to anyone else.
-- ─────────────────────────────────────────────────────────────────────────────

create extension if not exists "pgcrypto";

-- ── Who is staff, and what may they touch ────────────────────────────────────

create table if not exists public.admin_roles (
  email       text primary key,
  role        text not null default 'crm_manager',
  scopes      text[] not null default '{}',
  notes       text default '',
  added_by    uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists admin_roles_email_lower_idx on public.admin_roles (lower(email));

alter table public.admin_roles enable row level security;

/**
 * The one hardcoded identity. Kept as a function so every policy reads the same
 * constant; change it here and in fe/src/lib/adminAccess.js together.
 */
create or replace function public.is_super_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select lower(coalesce(auth.jwt() ->> 'email', '')) = 'yatharth200018@gmail.com';
$$;

/**
 * Does the caller hold `scope`?
 *
 * Super admin holds everything. Everyone else holds exactly what their
 * admin_roles row lists. Deliberately security definer so the lookup itself
 * isn't gated by admin_roles' own policies (which would recurse).
 */
create or replace function public.has_admin_scope(scope text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    public.is_super_admin()
    or exists (
      select 1
      from public.admin_roles r
      where lower(r.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
        and scope = any (r.scopes)
    );
$$;

/** Any CRM access at all — used to gate the shell and read-only lookups. */
create or replace function public.is_crm_staff()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    public.is_super_admin()
    or exists (
      select 1
      from public.admin_roles r
      where lower(r.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
        and cardinality(r.scopes) > 0
    );
$$;

-- Staff may read the roster (they need to see who owns a client); only the
-- super admin may change it. This is the rule that makes admin.roles.write
-- ungrantable: the policy does not consult scopes at all.
drop policy if exists "staff read roles" on public.admin_roles;
create policy "staff read roles"
  on public.admin_roles for select
  to authenticated
  using (public.is_crm_staff() or lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')));

drop policy if exists "super admin writes roles" on public.admin_roles;
create policy "super admin writes roles"
  on public.admin_roles for all
  to authenticated
  using (public.is_super_admin())
  with check (public.is_super_admin());

grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on public.admin_roles to authenticated;

-- ── Clients ──────────────────────────────────────────────────────────────────
-- One row per person we are selling to. user_id is null for a lead entered by
-- hand that never signed up.
--
-- status  : the funnel, set from the CRM (never inferred behind your back).
-- temperature : the human read. NULL until someone decides — never computed.

create table if not exists public.crm_clients (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid references auth.users(id) on delete set null,
  name               text default '',
  phone              text default '',
  email              text default '',
  source             text default 'app',          -- app | whatsapp | facebook | referral | walkin

  status             text not null default 'fresh'
                       check (status in ('fresh','dnp','shared','need_inventory',
                                         'visit_pending','closed_by_us','closed_outside')),
  temperature        text check (temperature in ('fire','hot','cold','ice')),

  -- The standing brief. One paragraph, rewritten as we learn; the append-only
  -- history lives in crm_activities.
  note               text default '',
  note_by            text default '',
  note_at            timestamptz,

  dnp_count          int not null default 0,
  assigned_to        text default '',             -- staff email
  next_follow_up_at  timestamptz,
  tags               text[] default '{}',

  -- Terminal outcome detail.
  closed_property_id text,
  closed_rent        numeric,
  closed_reason      text,
  closed_at          timestamptz,

  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),

  constraint crm_clients_user_unique unique (user_id)
);

create index if not exists crm_clients_status_idx  on public.crm_clients (status);
create index if not exists crm_clients_temp_idx    on public.crm_clients (temperature);
create index if not exists crm_clients_assigned_idx on public.crm_clients (lower(assigned_to));
create index if not exists crm_clients_phone_idx   on public.crm_clients (phone);

alter table public.crm_clients enable row level security;

drop policy if exists "crm read clients" on public.crm_clients;
create policy "crm read clients"
  on public.crm_clients for select
  to authenticated
  using (
    public.has_admin_scope('crm.clients.read.all')
    or (
      public.has_admin_scope('crm.clients.read.assigned')
      and lower(assigned_to) = lower(coalesce(auth.jwt() ->> 'email', ''))
    )
  );

drop policy if exists "crm write clients" on public.crm_clients;
create policy "crm write clients"
  on public.crm_clients for insert
  to authenticated
  with check (public.has_admin_scope('crm.clients.write'));

drop policy if exists "crm update clients" on public.crm_clients;
create policy "crm update clients"
  on public.crm_clients for update
  to authenticated
  using (
    public.has_admin_scope('crm.clients.write')
    and (
      public.has_admin_scope('crm.clients.read.all')
      or lower(assigned_to) = lower(coalesce(auth.jwt() ->> 'email', ''))
    )
  )
  with check (public.has_admin_scope('crm.clients.write'));

drop policy if exists "crm delete clients" on public.crm_clients;
create policy "crm delete clients"
  on public.crm_clients for delete
  to authenticated
  using (public.has_admin_scope('crm.clients.delete'));

grant select, insert, update, delete on public.crm_clients to authenticated;

-- ── CRM-side requirement override ────────────────────────────────────────────
-- Layered OVER public.user_requirements — the client's own answers are never
-- overwritten. Same vocabulary as data/preferenceOptions.js so it scores
-- directly in lib/inventoryMatch.js.

create table if not exists public.crm_client_requirements (
  client_id     uuid primary key references public.crm_clients(id) on delete cascade,
  localities    text[] default '{}',
  budget_min    numeric,
  budget_max    numeric,
  flat_types    text[] default '{}',
  furnishing    text default '',
  must_haves    text[] default '{}',
  deal_breakers text[] default '{}',
  occupants     text[] default '{}',
  move_in       text default '',
  min_score     int not null default 60,
  updated_by    text default '',
  updated_at    timestamptz not null default now()
);

alter table public.crm_client_requirements enable row level security;

drop policy if exists "crm manage requirement overrides" on public.crm_client_requirements;
create policy "crm manage requirement overrides"
  on public.crm_client_requirements for all
  to authenticated
  using (public.has_admin_scope('crm.requirements.write'))
  with check (public.has_admin_scope('crm.requirements.write'));

grant select, insert, update, delete on public.crm_client_requirements to authenticated;

-- ── Activity timeline (append-only) ──────────────────────────────────────────

create table if not exists public.crm_activities (
  id          uuid primary key default gen_random_uuid(),
  client_id   uuid not null references public.crm_clients(id) on delete cascade,
  actor_email text default '',
  type        text not null default 'note',   -- note | call | whatsapp | status | temperature | shortlist | visit | system
  body        text default '',
  meta        jsonb default '{}'::jsonb,
  created_at  timestamptz not null default now()
);

create index if not exists crm_activities_client_idx on public.crm_activities (client_id, created_at desc);

alter table public.crm_activities enable row level security;

drop policy if exists "crm read activities" on public.crm_activities;
create policy "crm read activities"
  on public.crm_activities for select
  to authenticated
  using (public.is_crm_staff());

-- Append-only by design: insert yes, update/delete no. A CRM whose history can
-- be edited is not a history.
drop policy if exists "crm append activities" on public.crm_activities;
create policy "crm append activities"
  on public.crm_activities for insert
  to authenticated
  with check (public.has_admin_scope('crm.clients.write'));

grant select, insert on public.crm_activities to authenticated;

-- ── What we sent whom ────────────────────────────────────────────────────────

create table if not exists public.crm_shortlists (
  id             uuid primary key default gen_random_uuid(),
  client_id      uuid not null references public.crm_clients(id) on delete cascade,
  property_id    text not null,
  status         text not null default 'shortlisted'
                   check (status in ('shortlisted','shared','liked','okay','disliked','visited','rejected')),
  score_at_share int,
  shared_by      text default '',
  shared_at      timestamptz,
  created_at     timestamptz not null default now(),
  unique (client_id, property_id)
);

create index if not exists crm_shortlists_client_idx on public.crm_shortlists (client_id, created_at desc);

alter table public.crm_shortlists enable row level security;

drop policy if exists "crm manage shortlists" on public.crm_shortlists;
create policy "crm manage shortlists"
  on public.crm_shortlists for all
  to authenticated
  using (public.has_admin_scope('crm.clients.write'))
  with check (public.has_admin_scope('crm.clients.write'));

grant select, insert, update, delete on public.crm_shortlists to authenticated;

-- ── Shared team settings: WhatsApp templates, pipeline labels ────────────────
-- One row, id='default'. Everyone reads it; only crm.templates.write may change
-- it, so nobody quietly rewrites what the company sounds like.

create table if not exists public.crm_settings (
  id          text primary key default 'default',
  data        jsonb not null default '{}'::jsonb,
  updated_by  text default '',
  updated_at  timestamptz not null default now()
);

alter table public.crm_settings enable row level security;

drop policy if exists "crm read settings" on public.crm_settings;
create policy "crm read settings"
  on public.crm_settings for select
  to authenticated
  using (public.is_crm_staff());

drop policy if exists "crm write settings" on public.crm_settings;
create policy "crm write settings"
  on public.crm_settings for all
  to authenticated
  using (public.has_admin_scope('crm.templates.write'))
  with check (public.has_admin_scope('crm.templates.write'));

grant select, insert, update, delete on public.crm_settings to authenticated;

-- ── Website sessions ─────────────────────────────────────────────────────────
-- lib/sessionTracking.js has always counted these, but only in the visitor's own
-- browser storage. This is where they go now, so "opens" and "time on site" are
-- sortable in the CRM. Anonymous visitors are kept too (user_id null, anon_id
-- set) so a session that starts logged-out still counts once they sign in.

create table if not exists public.user_sessions (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid references auth.users(id) on delete cascade,
  anon_id          text default '',
  email            text default '',
  started_at       timestamptz not null default now(),
  ended_at         timestamptz,
  duration_seconds int not null default 0,
  page_count       int not null default 0,
  pages            jsonb default '[]'::jsonb,
  device           text default '',
  os               text default '',
  referrer         text default '',
  created_at       timestamptz not null default now()
);

create index if not exists user_sessions_user_idx  on public.user_sessions (user_id, started_at desc);
create index if not exists user_sessions_anon_idx  on public.user_sessions (anon_id);

alter table public.user_sessions enable row level security;

-- A visitor may write their own session rows; staff may read all of them.
drop policy if exists "anyone records own session" on public.user_sessions;
create policy "anyone records own session"
  on public.user_sessions for insert
  to anon, authenticated
  with check (user_id is null or user_id = auth.uid());

drop policy if exists "own session update" on public.user_sessions;
create policy "own session update"
  on public.user_sessions for update
  to anon, authenticated
  using (user_id is null or user_id = auth.uid())
  with check (user_id is null or user_id = auth.uid());

drop policy if exists "staff read sessions" on public.user_sessions;
create policy "staff read sessions"
  on public.user_sessions for select
  to authenticated
  using (user_id = auth.uid() or public.is_crm_staff());

grant select, insert, update on public.user_sessions to anon, authenticated;

/** Per-user engagement rollup — what the CRM sorts on. */
create or replace view public.user_engagement as
  select
    user_id,
    count(*)::int                              as session_count,
    coalesce(sum(duration_seconds), 0)::int    as total_seconds,
    coalesce(max(duration_seconds), 0)::int    as longest_seconds,
    max(coalesce(ended_at, started_at))        as last_seen_at
  from public.user_sessions
  where user_id is not null
  group by user_id;

grant select on public.user_engagement to authenticated;

-- ── Additive changes to existing tables ──────────────────────────────────────

-- 1. How a person's search ended, kept on the profile itself so the public site
--    can stop nudging someone who has already moved, and so the outcome outlives
--    any CRM row.
alter table public.user_profiles add column if not exists search_status text not null default 'searching';
alter table public.user_profiles add column if not exists search_closed_at timestamptz;
alter table public.user_profiles add column if not exists search_closed_reason text default '';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'user_profiles_search_status_check'
  ) then
    alter table public.user_profiles
      add constraint user_profiles_search_status_check
      check (search_status in ('searching','closed_by_us','closed_outside'));
  end if;
end $$;

-- 2. Reactions gain 'okay' (the third WhatsApp reply) and a note of who recorded
--    it, so an agent can log what a client said on WhatsApp on their behalf.
alter table public.listing_reactions add column if not exists recorded_by text default '';
alter table public.listing_reactions add column if not exists source text default 'app';  -- app | crm

do $$
begin
  alter table public.listing_reactions drop constraint if exists listing_reactions_reaction_check;
  alter table public.listing_reactions
    add constraint listing_reactions_reaction_check
    check (reaction in ('like','dislike','okay'));
end $$;

drop policy if exists "crm records reactions for clients" on public.listing_reactions;
create policy "crm records reactions for clients"
  on public.listing_reactions for all
  to authenticated
  using (public.has_admin_scope('crm.clients.write'))
  with check (public.has_admin_scope('crm.clients.write'));

-- 3. Where a listing came from. Facebook post links can't be fetched (their
--    oEmbed returns an embed widget, not the post), so the URL is stored as
--    provenance only — trace a flat back to its source, spot duplicates, and see
--    which groups actually produce inventory.
alter table public.inventory add column if not exists source text default '';
alter table public.inventory add column if not exists source_url text default '';

-- Staff need to read every listing to match and to manage supply.
drop policy if exists "crm staff read all inventory" on public.inventory;
create policy "crm staff read all inventory"
  on public.inventory for select
  to authenticated
  using (public.is_crm_staff());

drop policy if exists "crm staff write inventory" on public.inventory;
create policy "crm staff write inventory"
  on public.inventory for all
  to authenticated
  using (public.has_admin_scope('crm.properties.write'))
  with check (public.has_admin_scope('crm.properties.write'));

-- Staff need every requirement and profile to build the client list.
drop policy if exists "crm staff read profiles" on public.user_profiles;
create policy "crm staff read profiles"
  on public.user_profiles for select
  to authenticated
  using (id = auth.uid() or public.is_admin_allowlisted() or public.is_crm_staff());

-- ── Bootstrap ────────────────────────────────────────────────────────────────

-- The super admin is hardcoded, but give them a row too so the Team screen
-- shows them and so is_crm_staff() is true even before any grant.
insert into public.admin_roles (email, role, scopes, notes)
values (
  'yatharth200018@gmail.com',
  'super_admin',
  array[
    'crm.clients.read.all','crm.clients.write','crm.clients.delete',
    'crm.requirements.write','crm.properties.read','crm.properties.write',
    'crm.properties.verify','crm.visits.write','crm.templates.use',
    'crm.templates.write','crm.analytics.read','admin.roles.write'
  ],
  'super admin — hardcoded in code as well'
)
on conflict (email) do update set scopes = excluded.scopes, role = excluded.role;

-- Default WhatsApp templates. Editable at /crm/settings by anyone holding
-- crm.templates.write; this only seeds the first version.
insert into public.crm_settings (id, data)
values (
  'default',
  jsonb_build_object(
    'defaultTemplateId', 'share_matches',
    'templates', jsonb_build_array(
      jsonb_build_object(
        'id', 'share_matches',
        'name', 'Share matches',
        'body', E'Hi {{client_name}}, this is {{agent_name}} from MovEazy 👋\n\nBased on what you''re looking for in {{localities}} around {{budget}}, I''ve shortlisted {{match_count}} homes for you:\n\n{{match_list}}\n\nWant me to book visits this weekend?'
      ),
      jsonb_build_object(
        'id', 'send_property',
        'name', 'Send one property',
        'body', E'{{flat_type}} at {{rent}}. Reply with like / dislike / okay to help us understand your preference.\n\n{{link}}'
      ),
      jsonb_build_object(
        'id', 'first_outreach',
        'name', 'First outreach',
        'body', E'Hi {{client_name}}, this is {{agent_name}} from MovEazy. You were looking for a home in {{localities}} — I have a few that fit. Is now a good time to talk?'
      ),
      jsonb_build_object(
        'id', 'visit_confirmation',
        'name', 'Visit confirmation',
        'body', E'Hi {{client_name}}, your visit is confirmed for {{visit_time}}.\n\n{{property_title}} — {{rent}}\n{{link}}\n\nI''ll meet you there. Reply here if anything changes.'
      ),
      jsonb_build_object(
        'id', 'follow_up',
        'name', 'Follow-up',
        'body', E'Hi {{client_name}}, just checking in — did any of the homes I sent work for you? Happy to send more if none of them felt right.'
      )
    ),
    'closedOutsideReasons', jsonb_build_array(
      'Nothing in their area', 'We were too slow', 'Price', 'Went with a broker',
      'Plans changed', 'Other'
    )
  )
)
on conflict (id) do nothing;

-- ── Backfill: everyone who already used the product becomes a client ─────────
-- Status is inferred ONCE, here, from what they have already done. After this
-- the CRM never moves anyone on its own.

insert into public.crm_clients (user_id, name, phone, email, source, status, created_at)
select
  p.id,
  coalesce(nullif(p.name, ''), split_part(p.email, '@', 1)),
  coalesce(p.phone, ''),
  p.email,
  'app',
  case
    when exists (select 1 from public.visit_bookings b where b.user_id = p.id) then 'visit_pending'
    when exists (select 1 from public.listing_reactions r where r.user_id = p.id) then 'shared'
    when exists (select 1 from public.user_requirements q where q.user_id = p.id) then 'need_inventory'
    else 'fresh'
  end,
  p.created_at
from public.user_profiles p
where p.role not in ('broker')
on conflict (user_id) do nothing;

-- Seed the CRM requirement override from what each client already told us, so
-- matching works on day one. Editing it later never touches user_requirements.
insert into public.crm_client_requirements
  (client_id, localities, budget_min, budget_max, flat_types, must_haves, deal_breakers, occupants)
select
  c.id, coalesce(q.localities, '{}'), q.budget_min, q.budget_max,
  coalesce(q.flat_types, '{}'), coalesce(q.must_haves, '{}'),
  coalesce(q.deal_breakers, '{}'), coalesce(q.occupants, '{}')
from public.crm_clients c
join public.user_requirements q on q.user_id = c.user_id
on conflict (client_id) do nothing;
