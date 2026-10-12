-- Tenant management for every partner, free or Premium.
--
-- One board of everyone a partner works — their own clients (partner_leads)
-- and the MovEazy tenants assigned to them (partner_lead_assignments) — each
-- with a stage that moves by itself:
--
--   new → contacted → list sent → liked → visit fixed → done / lost
--
-- contacted: a WhatsApp/call logged; list sent: a curated list went out;
-- liked: they liked a flat on one; visit fixed: partner_visits. Only "done"
-- (with the flat, rent and move-in — and, 10 months on, a renewal reminder)
-- and "lost" are set by hand. Plus a move-in date, reminders that land in the
-- partner's bell when due, notes, a timeline of everything, which tenants did
-- something new since the partner last looked, and per flat: who it went to,
-- who opened it, who liked it.
--
-- Run after partner_matcher_history.sql (curated lists, visits) and
-- partner_moveazy_leads.sql. Safe to re-run.

begin;

-- ── Tables ──────────────────────────────────────────────────────────────────
create table if not exists public.partner_tenant_track (
  id               uuid primary key default gen_random_uuid(),
  broker_id        uuid not null references auth.users (id) on delete cascade,
  lead_id          uuid references public.partner_leads (id) on delete cascade,
  assignment_id    uuid references public.partner_lead_assignments (id) on delete cascade,
  outcome          text check (outcome in ('done', 'lost')),
  outcome_at       timestamptz,
  lost_reason      text not null default '' check (char_length(lost_reason) <= 200),
  move_in          date,
  deal_property_id text not null default '',
  deal_rent        numeric,
  deal_move_in     date,
  actions_seen_at  timestamptz,
  updated_at       timestamptz not null default now(),
  check (num_nonnulls(lead_id, assignment_id) = 1)
);
create unique index if not exists partner_tenant_track_lead_uq on public.partner_tenant_track (lead_id) where lead_id is not null;
create unique index if not exists partner_tenant_track_asg_uq on public.partner_tenant_track (assignment_id) where assignment_id is not null;

create table if not exists public.partner_reminders (
  id            uuid primary key default gen_random_uuid(),
  broker_id     uuid not null references auth.users (id) on delete cascade,
  lead_id       uuid references public.partner_leads (id) on delete cascade,
  assignment_id uuid references public.partner_lead_assignments (id) on delete cascade,
  due_at        timestamptz not null,
  note          text not null default '' check (char_length(note) <= 300),
  kind          text not null default 'follow_up' check (kind in ('follow_up', 'renewal')),
  done_at       timestamptz,
  fired_at      timestamptz,
  created_at    timestamptz not null default now(),
  check (num_nonnulls(lead_id, assignment_id) = 1)
);
create index if not exists partner_reminders_due_idx on public.partner_reminders (broker_id, due_at) where done_at is null;

create table if not exists public.partner_tenant_notes (
  id            uuid primary key default gen_random_uuid(),
  broker_id     uuid not null references auth.users (id) on delete cascade,
  lead_id       uuid references public.partner_leads (id) on delete cascade,
  assignment_id uuid references public.partner_lead_assignments (id) on delete cascade,
  body          text not null check (char_length(body) between 1 and 1000),
  created_at    timestamptz not null default now(),
  check (num_nonnulls(lead_id, assignment_id) = 1)
);
create index if not exists partner_tenant_notes_idx on public.partner_tenant_notes (broker_id, created_at desc);

alter table public.partner_tenant_track enable row level security;
alter table public.partner_reminders    enable row level security;
alter table public.partner_tenant_notes enable row level security;
revoke all on table public.partner_tenant_track, public.partner_reminders, public.partner_tenant_notes from anon, authenticated;

do $$
declare
  kinds text[];
begin
  select array_agg(distinct m[1]) into kinds
    from pg_constraint c, regexp_matches(pg_get_constraintdef(c.oid), '''([a-z_]+)''', 'g') m
   where c.conname = 'partner_notifications_kind_check';
  if kinds is null then return; end if;
  kinds := array(select distinct k from unnest(kinds || array['reminder']) k order by 1);
  alter table public.partner_notifications drop constraint partner_notifications_kind_check;
  execute format('alter table public.partner_notifications add constraint partner_notifications_kind_check check (kind in (%s))',
                 (select string_agg(quote_literal(k), ', ') from unnest(kinds) k));
end $$;

-- ── Internal ────────────────────────────────────────────────────────────────

/** The caller's tenant (one of the two ids), or an error. */
create or replace function public.partner_tenant_check(p_lead uuid, p_assignment uuid)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_approved_partner() then raise exception 'Only MovEazy partners.' using errcode = '42501'; end if;
  if num_nonnulls(p_lead, p_assignment) <> 1 then raise exception 'Pick one tenant.' using errcode = '22023'; end if;
  if p_lead is not null and not exists (select 1 from public.partner_leads where id = p_lead and broker_id = auth.uid()) then
    raise exception 'That tenant isn''t yours.' using errcode = '42501';
  end if;
  if p_assignment is not null and not exists (select 1 from public.partner_lead_assignments where id = p_assignment and broker_id = auth.uid()) then
    raise exception 'That tenant isn''t yours.' using errcode = '42501';
  end if;
end;
$$;

/** The tenant's track row, made on first use. */
create or replace function public.partner_tenant_track_id(p_lead uuid, p_assignment uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  tid uuid;
begin
  select id into tid from public.partner_tenant_track
   where (p_lead is not null and lead_id = p_lead) or (p_assignment is not null and assignment_id = p_assignment);
  if tid is null then
    insert into public.partner_tenant_track (broker_id, lead_id, assignment_id) values (auth.uid(), p_lead, p_assignment)
    returning id into tid;
  end if;
  return tid;
end;
$$;

/** "/tenants/lead-…" or "/tenants/asg-…" */
create or replace function public.partner_tenant_link(p_lead uuid, p_assignment uuid)
returns text
language sql
immutable
as $$ select '/tenants/' || case when p_lead is not null then 'lead-' || p_lead::text else 'asg-' || p_assignment::text end; $$;

revoke all on function public.partner_tenant_check(uuid, uuid) from public, anon, authenticated;
revoke all on function public.partner_tenant_track_id(uuid, uuid) from public, anon, authenticated;
revoke all on function public.partner_tenant_link(uuid, uuid) from public, anon, authenticated;

-- ── The board ───────────────────────────────────────────────────────────────

/** Every tenant the caller works, with stage, move-in, what's new and what's next. */
create or replace function public.partner_tenants_board()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with t as (
    select l.id as lead_id, null::uuid as assignment_id, 'own'::text as kind,
           l.name, public.normalize_mobile(l.phone) as phone, l.localities, l.flat_types, l.budget_min, l.budget_max,
           l.furnishing, ''::text as move_in_raw, null::date as req_move_in, l.created_at,
           l.last_contacted_at as contact_at, l.status as own_status, null::text as asg_status, null::text as pack
      from public.partner_leads l where l.broker_id = auth.uid()
    union all
    select null, m.id, 'moveazy', m.name, public.normalize_mobile(m.phone), m.localities, m.flat_types, m.budget_min, m.budget_max,
           '', m.move_in_raw, m.move_in, m.assigned_at, m.last_reach_at, null, m.status, m.pack
      from public.partner_my_assigned_leads() m
  ), x as (
    select t.*, tr.outcome, tr.outcome_at, tr.lost_reason, tr.move_in, tr.deal_property_id, tr.deal_rent, tr.deal_move_in, tr.actions_seen_at,
           (select array_agg(cl.id) from public.partner_curated_lists cl
             where cl.broker_id = auth.uid()
               and ((t.lead_id is not null and cl.lead_id = t.lead_id) or (t.assignment_id is not null and cl.assignment_id = t.assignment_id))) as list_ids
      from t
      left join public.partner_tenant_track tr
        on (t.lead_id is not null and tr.lead_id = t.lead_id) or (t.assignment_id is not null and tr.assignment_id = t.assignment_id)
  ), y as (
    select x.*,
           coalesce(cardinality(x.list_ids), 0) as lists,
           (select count(distinct a.property_id)::int from public.partner_curated_actions a where a.list_id = any (coalesce(x.list_ids, '{}')) and a.action = 'liked') as liked,
           (select count(*)::int from public.partner_curated_actions a where a.list_id = any (coalesce(x.list_ids, '{}'))
              and a.at > coalesce(x.actions_seen_at, '-infinity')) as new_actions,
           (select max(a.at) from public.partner_curated_actions a where a.list_id = any (coalesce(x.list_ids, '{}'))) as last_action_at,
           exists (select 1 from public.partner_curated_lists cl where cl.id = any (coalesce(x.list_ids, '{}')) and cl.opened_at is not null) as opened,
           (select min(v.visit_at) from public.partner_visits v where v.status = 'fixed' and v.visit_at > now() - interval '12 hours'
              and ((x.lead_id is not null and v.lead_id = x.lead_id) or (x.assignment_id is not null and v.assignment_id = x.assignment_id))) as next_visit,
           exists (select 1 from public.partner_visits v where v.status = 'fixed'
              and ((x.lead_id is not null and v.lead_id = x.lead_id) or (x.assignment_id is not null and v.assignment_id = x.assignment_id))) as has_visit,
           (select jsonb_build_object('id', r.id, 'due_at', r.due_at, 'note', r.note, 'kind', r.kind)
              from public.partner_reminders r where r.done_at is null and r.broker_id = auth.uid()
               and ((x.lead_id is not null and r.lead_id = x.lead_id) or (x.assignment_id is not null and r.assignment_id = x.assignment_id))
             order by r.due_at limit 1) as next_reminder
      from x
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', case when y.lead_id is not null then 'lead:' || y.lead_id else 'asg:' || y.assignment_id end,
           'slug', case when y.lead_id is not null then 'lead-' || y.lead_id else 'asg-' || y.assignment_id end,
           'kind', y.kind, 'lead_id', y.lead_id, 'assignment_id', y.assignment_id, 'pack', y.pack,
           'name', y.name, 'phone', y.phone, 'localities', y.localities, 'flat_types', y.flat_types,
           'budget_min', y.budget_min, 'budget_max', y.budget_max, 'furnishing', y.furnishing, 'move_in_raw', y.move_in_raw,
           'move_in', coalesce(y.move_in, y.req_move_in),
           'stage', case
              when y.outcome = 'done' or y.asg_status = 'closed' then 'done'
              when y.outcome = 'lost' or y.asg_status = 'not_interested' or (y.kind = 'own' and y.own_status = 'closed') then 'lost'
              when y.has_visit then 'visit'
              when y.liked > 0 then 'liked'
              when y.lists > 0 then 'list_sent'
              when y.contact_at is not null or y.asg_status in ('contacted', 'visit') then 'contacted'
              else 'new' end,
           'lost_reason', y.lost_reason, 'outcome_at', y.outcome_at,
           'deal', case when y.deal_property_id <> '' or y.deal_rent is not null then
                     jsonb_build_object('property_id', y.deal_property_id, 'rent', y.deal_rent, 'move_in', y.deal_move_in) end,
           'lists', y.lists, 'opened', y.opened, 'liked', y.liked, 'new_actions', y.new_actions, 'last_action_at', y.last_action_at,
           'last_contact_at', y.contact_at, 'next_visit', y.next_visit, 'next_reminder', y.next_reminder, 'created_at', y.created_at)
           order by y.created_at desc), '[]'::jsonb)
    from y
   where public.is_approved_partner();
$$;

-- ── Changing a tenant ───────────────────────────────────────────────────────

/**
 * Move-in date, or the outcome: 'done' (flat, rent, move-in — and for a
 * MovEazy tenant the deal type, which works out MovEazy's share), 'lost'
 * (a reason), or null to reopen. p_patch keys: move_in, outcome, lost_reason,
 * deal_property_id, deal_rent, deal_move_in, deal_type.
 */
create or replace function public.partner_tenant_update(p_lead uuid, p_assignment uuid, p_patch jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  tid  uuid;
  oc   text;
  rent numeric;
  mi   date;
  flat text;
begin
  perform public.partner_tenant_check(p_lead, p_assignment);
  tid := public.partner_tenant_track_id(p_lead, p_assignment);

  if p_patch ? 'move_in' then
    update public.partner_tenant_track set move_in = nullif(p_patch ->> 'move_in', '')::date, updated_at = now() where id = tid;
  end if;

  if p_patch ? 'outcome' then
    oc := nullif(p_patch ->> 'outcome', '');
    if oc is not null and oc not in ('done', 'lost') then raise exception 'Unknown outcome.' using errcode = '22023'; end if;
    if oc = 'done' then
      rent := nullif(p_patch ->> 'deal_rent', '')::numeric;
      mi := nullif(p_patch ->> 'deal_move_in', '')::date;
      flat := left(coalesce(p_patch ->> 'deal_property_id', ''), 40);
      if coalesce(rent, 0) < 1000 then raise exception 'Enter the monthly rent.' using errcode = '22023'; end if;
      if p_assignment is not null then
        if coalesce(p_patch ->> 'deal_type', '') not in ('direct', 'shared') then
          raise exception 'Say how the deal went: direct with the owner, or with other brokers.' using errcode = '22023';
        end if;
        perform public.partner_lead_update(p_assignment, 'closed', rent, p_patch ->> 'deal_type');
      else
        update public.partner_leads set status = 'closed', updated_at = now() where id = p_lead;
      end if;
      update public.partner_tenant_track
         set outcome = 'done', outcome_at = now(), lost_reason = '', deal_property_id = flat, deal_rent = rent,
             deal_move_in = mi, move_in = coalesce(mi, move_in), updated_at = now()
       where id = tid;
      -- Ten months on: renew, or find them the next one.
      delete from public.partner_reminders
       where kind = 'renewal' and done_at is null
         and ((p_lead is not null and lead_id = p_lead) or (p_assignment is not null and assignment_id = p_assignment));
      insert into public.partner_reminders (broker_id, lead_id, assignment_id, due_at, note, kind)
      values (auth.uid(), p_lead, p_assignment,
              ((coalesce(mi, (now() at time zone 'Asia/Kolkata')::date) + interval '10 months')::date + time '10:00') at time zone 'Asia/Kolkata',
              'Lease renewal coming up' || case when flat <> '' then ' — ' || public.partner_flat_line(flat) else '' end ||
              '. Renew it, or find them their next home.', 'renewal');
    elsif oc = 'lost' then
      if p_assignment is not null then
        perform public.partner_lead_update(p_assignment, 'not_interested');
      else
        update public.partner_leads set status = 'closed', updated_at = now() where id = p_lead;
      end if;
      update public.partner_tenant_track
         set outcome = 'lost', outcome_at = now(), lost_reason = left(coalesce(p_patch ->> 'lost_reason', ''), 200), updated_at = now()
       where id = tid;
    else
      if p_assignment is not null then
        if exists (select 1 from public.partner_lead_assignments where id = p_assignment and status = 'closed') then
          raise exception 'A closed MovEazy deal can''t be reopened here — message MovEazy.' using errcode = '22023';
        end if;
        perform public.partner_lead_update(p_assignment, 'contacted');
      else
        update public.partner_leads set status = 'active', updated_at = now() where id = p_lead;
      end if;
      update public.partner_tenant_track set outcome = null, outcome_at = null, lost_reason = '', updated_at = now() where id = tid;
    end if;
  end if;
end;
$$;

/** The partner looked at this tenant: their likes and opens are no longer "new". */
create or replace function public.partner_tenant_seen(p_lead uuid, p_assignment uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  tid uuid;
begin
  perform public.partner_tenant_check(p_lead, p_assignment);
  tid := public.partner_tenant_track_id(p_lead, p_assignment);
  update public.partner_tenant_track set actions_seen_at = now() where id = tid;
end;
$$;

-- ── Reminders ───────────────────────────────────────────────────────────────

create or replace function public.partner_reminder_add(p_lead uuid, p_assignment uuid, p_due timestamptz, p_note text default '')
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  rid uuid;
begin
  perform public.partner_tenant_check(p_lead, p_assignment);
  if p_due is null or p_due < now() - interval '1 hour' or p_due > now() + interval '2 years' then
    raise exception 'Pick a time from now on.' using errcode = '22023';
  end if;
  insert into public.partner_reminders (broker_id, lead_id, assignment_id, due_at, note)
  values (auth.uid(), p_lead, p_assignment, p_due, left(btrim(coalesce(p_note, '')), 300))
  returning id into rid;
  return rid;
end;
$$;

create or replace function public.partner_reminder_done(p_id uuid)
returns void
language sql
security definer
set search_path = public
as $$ update public.partner_reminders set done_at = now() where id = p_id and broker_id = auth.uid() and done_at is null; $$;

create or replace function public.partner_reminder_snooze(p_id uuid, p_due timestamptz)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_due is null or p_due < now() - interval '1 hour' or p_due > now() + interval '2 years' then
    raise exception 'Pick a time from now on.' using errcode = '22023';
  end if;
  update public.partner_reminders set due_at = p_due, fired_at = null
   where id = p_id and broker_id = auth.uid() and done_at is null;
end;
$$;

/** Open reminders, soonest first, with the tenant. */
create or replace function public.partner_reminders_open()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', r.id, 'due_at', r.due_at, 'note', r.note, 'kind', r.kind, 'lead_id', r.lead_id, 'assignment_id', r.assignment_id,
           'slug', case when r.lead_id is not null then 'lead-' || r.lead_id else 'asg-' || r.assignment_id end,
           'tenant', coalesce(
             (select jsonb_build_object('name', l.name, 'phone', public.normalize_mobile(l.phone)) from public.partner_leads l where l.id = r.lead_id),
             (select jsonb_build_object('name', c.name, 'phone', public.normalize_mobile(c.phone))
                from public.partner_lead_assignments a join public.crm_clients c on c.id = a.client_id where a.id = r.assignment_id)))
           order by r.due_at), '[]'::jsonb)
    from public.partner_reminders r
   where r.broker_id = auth.uid() and r.done_at is null and public.is_approved_partner();
$$;

/**
 * Due reminders into the bell, once each. The app calls this with its
 * notification check (every 30 s while open) — the partner app has no push.
 * → how many fired.
 */
create or replace function public.partner_reminders_fire()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  n int;
begin
  if not public.is_approved_partner() then return 0; end if;
  with due as (
    update public.partner_reminders r set fired_at = now()
     where r.broker_id = auth.uid() and r.done_at is null and r.fired_at is null and r.due_at <= now()
    returning r.*
  )
  insert into public.partner_notifications (broker_id, kind, title, body, link)
  select d.broker_id, 'reminder',
         case when d.kind = 'renewal' then 'Renewal: ' else 'Follow up: ' end ||
           coalesce(nullif(coalesce((select l.name from public.partner_leads l where l.id = d.lead_id),
                                    (select c.name from public.partner_lead_assignments a join public.crm_clients c on c.id = a.client_id where a.id = d.assignment_id)), ''), 'your tenant'),
         coalesce(nullif(d.note, ''), 'Time to check in with them.'),
         public.partner_tenant_link(d.lead_id, d.assignment_id)
    from due d;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- ── Notes and the timeline ──────────────────────────────────────────────────

create or replace function public.partner_tenant_note_add(p_lead uuid, p_assignment uuid, p_body text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.partner_tenant_check(p_lead, p_assignment);
  if char_length(btrim(coalesce(p_body, ''))) = 0 then raise exception 'Write a note.' using errcode = '22023'; end if;
  insert into public.partner_tenant_notes (broker_id, lead_id, assignment_id, body)
  values (auth.uid(), p_lead, p_assignment, left(btrim(p_body), 1000));
end;
$$;

/** Everything that happened with a tenant, newest first. */
create or replace function public.partner_tenant_timeline(p_lead uuid, p_assignment uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  lists uuid[];
begin
  perform public.partner_tenant_check(p_lead, p_assignment);
  select coalesce(array_agg(cl.id), '{}') into lists from public.partner_curated_lists cl
   where cl.broker_id = auth.uid() and ((p_lead is not null and cl.lead_id = p_lead) or (p_assignment is not null and cl.assignment_id = p_assignment));
  return coalesce((select jsonb_agg(e order by (e ->> 'at') desc) from (
    select jsonb_build_object('at', n.created_at, 'kind', 'note', 'text', n.body) e
      from public.partner_tenant_notes n
     where n.broker_id = auth.uid() and ((p_lead is not null and n.lead_id = p_lead) or (p_assignment is not null and n.assignment_id = p_assignment))
    union all
    select jsonb_build_object('at', cl.created_at, 'kind', 'list', 'text', 'You sent ' || cardinality(cl.property_ids) || ' flat' ||
             case when cardinality(cl.property_ids) = 1 then '' else 's' end, 'list_id', cl.id)
      from public.partner_curated_lists cl where cl.id = any (lists)
    union all
    select jsonb_build_object('at', cl.opened_at, 'kind', 'opened', 'text', 'Opened your list', 'list_id', cl.id)
      from public.partner_curated_lists cl where cl.id = any (lists) and cl.opened_at is not null
    union all
    select jsonb_build_object('at', a.at, 'kind', a.action, 'text', case when a.action = 'liked' then 'Liked ' else 'Skipped ' end || public.partner_flat_line(a.property_id),
             'property_id', a.property_id)
      from public.partner_curated_actions a where a.list_id = any (lists)
    union all
    select jsonb_build_object('at', v.created_at, 'kind', 'visit',
             'text', case when v.status = 'cancelled' then 'Visit called off: ' else 'Visit fixed: ' end || public.partner_flat_line(v.property_id) ||
                     ' · ' || to_char(v.visit_at at time zone 'Asia/Kolkata', 'Dy DD Mon, FMHH12:MI am'), 'property_id', v.property_id)
      from public.partner_visits v
     where (p_lead is not null and v.lead_id = p_lead) or (p_assignment is not null and v.assignment_id = p_assignment)
    union all
    select jsonb_build_object('at', r.done_at, 'kind', 'reminder', 'text', 'Followed up' || coalesce(': ' || nullif(r.note, ''), ''))
      from public.partner_reminders r
     where r.done_at is not null and ((p_lead is not null and r.lead_id = p_lead) or (p_assignment is not null and r.assignment_id = p_assignment))
    union all
    select jsonb_build_object('at', x.at, 'kind', 'reach', 'text', case when x.channel = 'call' then 'You called' else 'You WhatsApped' end)
      from public.partner_lead_reachouts x where p_assignment is not null and x.assignment_id = p_assignment
    union all
    select jsonb_build_object('at', tr.outcome_at, 'kind', tr.outcome,
             'text', case when tr.outcome = 'done' then 'Deal done' || coalesce(' · ₹' || to_char(tr.deal_rent, 'FM99,99,999') || '/month', '')
                          else 'Marked lost' || coalesce(' — ' || nullif(tr.lost_reason, ''), '') end)
      from public.partner_tenant_track tr
     where tr.outcome is not null and ((p_lead is not null and tr.lead_id = p_lead) or (p_assignment is not null and tr.assignment_id = p_assignment))
    union all
    select jsonb_build_object('at', a.assigned_at, 'kind', 'start', 'text', 'Given to you by MovEazy')
      from public.partner_lead_assignments a where a.id = p_assignment
    union all
    select jsonb_build_object('at', l.created_at, 'kind', 'start', 'text', 'You added them')
      from public.partner_leads l where l.id = p_lead
  ) q where e ->> 'at' is not null), '[]'::jsonb);
end;
$$;

-- ── Flats ───────────────────────────────────────────────────────────────────

/** One flat: how many tenants it went to, opened, liked — and who. */
create or replace function public.partner_flat_interest(p_property text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with mine as (
    select cl.*, (select a.action from public.partner_curated_actions a where a.list_id = cl.id and a.property_id = p_property) as action
      from public.partner_curated_lists cl
     where cl.broker_id = auth.uid() and p_property = any (cl.property_ids)
  )
  select jsonb_build_object(
    'sent', (select count(*) from mine),
    'opened', (select count(*) from mine where opened_at is not null),
    'liked', (select count(*) from mine where action = 'liked'),
    'tenants', coalesce((select jsonb_agg(jsonb_build_object(
                  'name', coalesce(nullif(m.lead_name, ''), 'Tenant'),
                  'slug', case when m.lead_id is not null then 'lead-' || m.lead_id when m.assignment_id is not null then 'asg-' || m.assignment_id end,
                  'action', coalesce(m.action, case when m.opened_at is not null then 'opened' else 'sent' end),
                  'at', m.created_at) order by (m.action = 'liked') desc nulls last, m.created_at desc)
                 from mine m), '[]'::jsonb))
   where public.is_approved_partner();
$$;

-- ── Grants ──────────────────────────────────────────────────────────────────
do $$
declare f text;
begin
  foreach f in array array[
    'public.partner_tenants_board()', 'public.partner_tenant_update(uuid, uuid, jsonb)', 'public.partner_tenant_seen(uuid, uuid)',
    'public.partner_reminder_add(uuid, uuid, timestamptz, text)', 'public.partner_reminder_done(uuid)',
    'public.partner_reminder_snooze(uuid, timestamptz)', 'public.partner_reminders_open()', 'public.partner_reminders_fire()',
    'public.partner_tenant_note_add(uuid, uuid, text)', 'public.partner_tenant_timeline(uuid, uuid)', 'public.partner_flat_interest(text)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

commit;
