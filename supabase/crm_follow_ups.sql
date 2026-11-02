-- Daily follow-ups: every active client on one list, every call ending in an
-- outcome and a next date, partners assigned straight from a client, held to
-- a 24 / 48 hour response, scored, and a 9:30 morning summary for both sides.
-- (MovEazy-FE pages/crm/CrmFollowUpsPage.jsx, FollowUpControls.jsx,
-- lib/followUps.js; the partner app's Today list.)
--
--   crm_clients           + follow_up_note / follow_up_by / follow_up_set_at,
--                           last_outcome(_at), no_answer_streak
--   crm_follow_up_save    an outcome and/or the next date, note, owner — with
--                         what each outcome means (not picked → DNP, three in
--                         a row → Cold; visit booked → visit pending; flats
--                         shared; not interested → Ice; found elsewhere →
--                         closed outside), logged on the client
--   crm_follow_up_settings  round-robin of new leads across the team (off)
--   crm_partner_assign    free, any number of partners; keep the ones they have
--                         or take it off them (history kept in
--                         partner_lead_removed and partner_lead_events)
--   partner_follow_ups / partner_follow_up_save   the partner's Today list
--   crm_partner_follow_ups  every assigned client's partner side, SLA-coloured,
--                         and the partner scorecard
--   follow_up_digest_run  the 9:30 summary: a CRM notification per team member,
--                         a partner-app one per partner; pg_cron runs it, and
--                         the apps poke it on opening in case cron is off.
--
-- Safe to re-run.

begin;

-- ── The client's next step ─────────────────────────────────────────────────

alter table public.crm_clients add column if not exists follow_up_note text not null default '';
alter table public.crm_clients add column if not exists follow_up_by text not null default '';
alter table public.crm_clients add column if not exists follow_up_set_at timestamptz;
alter table public.crm_clients add column if not exists last_outcome text;
alter table public.crm_clients add column if not exists last_outcome_at timestamptz;
alter table public.crm_clients add column if not exists no_answer_streak int not null default 0;
create index if not exists crm_clients_follow_up_idx on public.crm_clients (next_follow_up_at);

/** The outcomes, as stored → as read. */
create or replace function public.follow_up_outcome_label(p text)
returns text
language sql
immutable
as $$
  select case p
    when 'talked' then 'Talked' when 'not_picked' then 'Not picked' when 'call_later' then 'Call later'
    when 'busy' then 'Busy / switched off' when 'visit_booked' then 'Visit booked' when 'flats_shared' then 'Flats shared'
    when 'not_interested' then 'Not interested' when 'found_elsewhere' then 'Found elsewhere' else p end;
$$;

/**
 * The team's follow-up on one client. p: { outcome?, next_at? (ISO, '' clears),
 * note?, owner? (email, '' = nobody) }. Keys left out stay as they are; an
 * outcome that ends the search clears the next date unless one is given.
 * → the client row.
 */
create or replace function public.crm_follow_up_save(p_client uuid, p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me   text := lower(coalesce(auth.jwt() ->> 'email', ''));
  c    public.crm_clients;
  oc   text := nullif(trim(coalesce(p ->> 'outcome', '')), '');
  nt   text := left(trim(coalesce(p ->> 'note', '')), 500);
  nxt  timestamptz;
  st   text;
  tmp  text;
  strk int;
  body text;
begin
  if not public.is_crm_staff() or not public.has_admin_scope('crm.clients.write') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  if oc is not null and oc not in ('talked', 'not_picked', 'call_later', 'busy', 'visit_booked', 'flats_shared', 'not_interested', 'found_elsewhere') then
    raise exception 'Unknown outcome.' using errcode = '22023';
  end if;
  select * into c from public.crm_clients where id = p_client for update;
  if c.id is null then raise exception 'No such client.' using errcode = '22023'; end if;

  nxt := case when p ? 'next_at' then nullif(p ->> 'next_at', '')::timestamptz else c.next_follow_up_at end;
  if oc in ('not_interested', 'found_elsewhere') and not (p ? 'next_at') then nxt := null; end if;
  strk := case when oc in ('not_picked', 'busy') then c.no_answer_streak + 1 when oc is not null then 0 else c.no_answer_streak end;
  st := c.status;
  tmp := c.temperature;
  if c.status not in ('closed_by_us', 'closed_outside') then
    st := case
      when oc = 'found_elsewhere' then 'closed_outside'
      when oc = 'visit_booked' then 'visit_pending'
      when oc = 'flats_shared' and c.status in ('fresh', 'dnp') then 'shared'
      when oc in ('not_picked', 'busy') and c.status = 'fresh' then 'dnp'
      when oc in ('talked', 'call_later') and c.status = 'dnp' then 'fresh'
      else c.status end;
  end if;
  if oc = 'not_interested' then tmp := 'ice';
  elsif strk >= 3 and coalesce(c.temperature, '') <> 'ice' then tmp := 'cold';
  end if;

  update public.crm_clients set
    next_follow_up_at = nxt,
    follow_up_note    = case when p ? 'note' then nt else follow_up_note end,
    follow_up_by      = me,
    follow_up_set_at  = now(),
    last_outcome      = coalesce(oc, last_outcome),
    last_outcome_at   = case when oc is not null then now() else last_outcome_at end,
    no_answer_streak  = strk,
    dnp_count         = dnp_count + case when oc in ('not_picked', 'busy') then 1 else 0 end,
    status            = st,
    temperature       = tmp,
    closed_reason     = case when oc = 'found_elsewhere' and c.status <> 'closed_outside' then 'Found elsewhere' else closed_reason end,
    closed_at         = case when oc = 'found_elsewhere' and c.status <> 'closed_outside' then now() else closed_at end,
    assigned_to       = case when p ? 'owner' then lower(trim(coalesce(p ->> 'owner', ''))) else assigned_to end,
    updated_at        = now()
  where id = c.id
  returning * into c;

  body := concat_ws(' · ',
    case when oc is not null then 'Called — ' || public.follow_up_outcome_label(oc) end,
    case when nxt is not null then 'next follow-up ' || to_char(nxt at time zone 'Asia/Kolkata', 'DD Mon, HH12:MI AM')
         when oc is not null or p ? 'next_at' then 'no next follow-up' end,
    case when p ? 'owner' then 'owner ' || coalesce(nullif(c.assigned_to, ''), 'nobody') end,
    nullif(nt, ''));
  if body <> '' then
    insert into public.crm_activities (client_id, actor_email, type, body, meta)
    values (c.id, me, case when oc is not null then 'call' else 'follow_up' end, body,
            jsonb_build_object('outcome', oc, 'next_at', nxt, 'follow_up', true, 'streak', strk));
  end if;
  if strk = 3 and oc in ('not_picked', 'busy') then
    insert into public.crm_activities (client_id, actor_email, type, body, meta)
    values (c.id, me, 'temperature', 'Marked Cold — didn''t pick up 3 times in a row', jsonb_build_object('temperature', 'cold'));
  end if;
  return to_jsonb(c);
end;
$$;

-- ── Round-robin of new leads (off until the team grows) ────────────────────

create table if not exists public.crm_follow_up_settings (
  id          int primary key default 1 check (id = 1),
  round_robin boolean not null default false,
  updated_by  text not null default '',
  updated_at  timestamptz not null default now()
);
insert into public.crm_follow_up_settings (id) values (1) on conflict do nothing;
alter table public.crm_follow_up_settings enable row level security;
revoke all on public.crm_follow_up_settings from anon, authenticated;

create or replace function public.crm_follow_up_settings_get()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then raise exception 'Not allowed.' using errcode = '42501'; end if;
  return (select jsonb_build_object('round_robin', s.round_robin, 'updated_by', s.updated_by, 'updated_at', s.updated_at,
                 'team', (select coalesce(jsonb_agg(e order by e), '[]'::jsonb) from public.crm_team_emails() e))
            from public.crm_follow_up_settings s where s.id = 1);
end;
$$;

create or replace function public.crm_follow_up_settings_set(p_round_robin boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_super_admin() then raise exception 'Only the super admin can change this.' using errcode = '42501'; end if;
  update public.crm_follow_up_settings set round_robin = coalesce(p_round_robin, false),
         updated_by = lower(coalesce(auth.jwt() ->> 'email', '')), updated_at = now() where id = 1;
  return public.crm_follow_up_settings_get();
end;
$$;

/** Everyone on the CRM team: the roster plus the super admin. */
create or replace function public.crm_team_emails()
returns setof text
language sql
stable
security definer
set search_path = public
as $$
  select distinct lower(e) from (
    select email as e from public.admin_roles
    union all select 'yatharth200018@gmail.com'
  ) x where coalesce(e, '') <> '';
$$;

/** A new MovEazy lead, with round-robin on: to whoever on the team has the fewest open clients. */
create or replace function public.crm_round_robin_owner()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(new.assigned_to, '') = '' and coalesce(new.attributed_to, 'moveazy') = 'moveazy'
     and (select round_robin from public.crm_follow_up_settings where id = 1) then
    new.assigned_to := (
      select t.e from public.crm_team_emails() t(e)
       order by (select count(*) from public.crm_clients c
                  where lower(c.assigned_to) = t.e and c.status not in ('closed_by_us', 'closed_outside')), t.e
       limit 1);
  end if;
  return new;
end;
$$;
drop trigger if exists crm_round_robin_owner on public.crm_clients;
create trigger crm_round_robin_owner before insert on public.crm_clients
  for each row execute function public.crm_round_robin_owner();

-- ── Partners, assigned from the CRM ────────────────────────────────────────

alter table public.partner_lead_requests drop constraint if exists partner_lead_requests_pack_check;
alter table public.partner_lead_requests add constraint partner_lead_requests_pack_check
  check (pack in ('free10', 'paid30', 'premium', 'website', 'milestone', 'crm'));

-- A partner's actions outlive the assignment: taken off a client, their calls
-- and follow-ups stay on the client's history and their scorecard.
alter table public.partner_lead_events alter column assignment_id drop not null;
alter table public.partner_lead_events drop constraint if exists partner_lead_events_assignment_id_fkey;
alter table public.partner_lead_events add constraint partner_lead_events_assignment_id_fkey
  foreign key (assignment_id) references public.partner_lead_assignments (id) on delete set null;
alter table public.partner_lead_reachouts alter column assignment_id drop not null;
alter table public.partner_lead_reachouts drop constraint if exists partner_lead_reachouts_assignment_id_fkey;
alter table public.partner_lead_reachouts add constraint partner_lead_reachouts_assignment_id_fkey
  foreign key (assignment_id) references public.partner_lead_assignments (id) on delete set null;
alter table public.partner_lead_events drop constraint if exists partner_lead_events_kind_check;
alter table public.partner_lead_events add constraint partner_lead_events_kind_check
  check (kind in ('call', 'whatsapp', 'status', 'follow_up', 'response', 'team_follow_up', 'assigned', 'removed', 'outcome'));

create table if not exists public.partner_lead_removed (
  id          uuid primary key,              -- the assignment's id
  client_id   uuid not null references public.crm_clients (id) on delete cascade,
  broker_id   uuid not null references auth.users (id) on delete cascade,
  pack        text not null default '',
  status      text not null default '',
  assigned_at timestamptz,
  removed_at  timestamptz not null default now(),
  removed_by  text not null default '',
  snapshot    jsonb not null default '{}'
);
create index if not exists partner_lead_removed_client_idx on public.partner_lead_removed (client_id, removed_at desc);
create index if not exists partner_lead_removed_broker_idx on public.partner_lead_removed (broker_id, removed_at desc);
alter table public.partner_lead_removed enable row level security;
revoke all on public.partner_lead_removed from anon, authenticated;

/** The partner's standing request that the CRM's own assignments hang off. */
create or replace function public.crm_request_for(p_broker uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  rid uuid;
begin
  select id into rid from public.partner_lead_requests where broker_id = p_broker and pack = 'crm' order by created_at limit 1;
  if rid is null then
    insert into public.partner_lead_requests (broker_id, pack, lead_count, status, note, decided_by, decided_at)
    values (p_broker, 'crm', 100, 'fulfilled', 'Clients the MovEazy team assigned from the CRM', 'crm', now())
    returning id into rid;
  end if;
  return rid;
end;
$$;

/** "2 BHK · HSR, Bellandur · up to ₹35,000" — what a client wants, for a partner. */
create or replace function public.client_need_line(p_client uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select concat_ws(' · ',
           nullif(array_to_string(coalesce(nullif(r.flat_types, '{}'), u.flat_types), ', '), ''),
           nullif(array_to_string(coalesce(nullif(r.localities, '{}'), u.localities), ', '), ''),
           case when coalesce(r.budget_max, u.budget_max) is not null
                then 'up to ₹' || to_char(coalesce(r.budget_max, u.budget_max), 'FM99,99,99,999') end)
    from public.crm_clients c
    left join public.crm_client_requirements r on r.client_id = c.id
    left join public.user_requirements u on u.user_id = c.user_id
   where c.id = p_client;
$$;

/** Take one assignment off its partner, keeping what they did. Internal. */
create or replace function public.partner_lead_remove(p_assignment uuid, p_actor text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  a   public.partner_lead_assignments;
  pk  text;
  who text;
  nm  text;
begin
  select * into a from public.partner_lead_assignments where id = p_assignment for update;
  if a.id is null then return false; end if;
  if a.status = 'closed' then raise exception 'That partner closed this client — it can''t be taken off them.' using errcode = '22023'; end if;
  select q.pack into pk from public.partner_lead_requests q where q.id = a.request_id;
  select coalesce(nullif(b.name, ''), 'Partner') into who from public.broker_partners b where b.user_id = a.broker_id;
  select coalesce(nullif(c.name, ''), 'A client') into nm from public.crm_clients c where c.id = a.client_id;
  insert into public.partner_lead_removed (id, client_id, broker_id, pack, status, assigned_at, removed_by, snapshot)
  values (a.id, a.client_id, a.broker_id, coalesce(pk, ''), a.status, a.assigned_at, coalesce(p_actor, ''), to_jsonb(a))
  on conflict (id) do nothing;
  insert into public.partner_lead_events (assignment_id, client_id, broker_id, kind, detail, actor)
  values (a.id, a.client_id, a.broker_id, 'removed', 'Taken off this partner by the MovEazy team', coalesce(p_actor, ''));
  insert into public.crm_activities (client_id, actor_email, type, body, meta)
  values (a.client_id, coalesce(p_actor, ''), 'system', 'Taken off partner ' || coalesce(who, 'Partner'),
          jsonb_build_object('broker_id', a.broker_id, 'assignment_id', a.id, 'removed', true));
  insert into public.partner_notifications (broker_id, kind, title, body, link)
  values (a.broker_id, 'lead_removed', coalesce(nm, 'A client') || ' was reassigned',
          'The MovEazy team moved this client to another partner.', '/leads?tab=moveazy');
  delete from public.partner_lead_assignments where id = a.id;
  return true;
end;
$$;

/**
 * Assign partners to a client from the CRM — free, as many as you like.
 * p_replace: the partners they had before (not these) lose the client; their
 * history is kept. → { added: [{broker_id, name, phone, assignment_id}],
 * removed, client: {name, phone, need} }
 */
create or replace function public.crm_partner_assign(p_client uuid, p_brokers uuid[], p_replace boolean default false, p_note text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me    text := lower(coalesce(auth.jwt() ->> 'email', ''));
  c     public.crm_clients;
  bid   uuid;
  aid   uuid;
  b     public.broker_partners;
  added jsonb := '[]'::jsonb;
  gone  int := 0;
  need  text;
  nt    text := left(trim(coalesce(p_note, '')), 300);
  x     record;
begin
  if not public.is_crm_staff() or not public.has_admin_scope('crm.clients.write') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  select * into c from public.crm_clients where id = p_client;
  if c.id is null then raise exception 'No such client.' using errcode = '22023'; end if;
  if coalesce(array_length(p_brokers, 1), 0) = 0 and not coalesce(p_replace, false) then
    raise exception 'Pick a partner.' using errcode = '22023';
  end if;
  need := coalesce(public.client_need_line(c.id), '');

  foreach bid in array coalesce(p_brokers, '{}') loop
    select * into b from public.broker_partners where user_id = bid and status = 'approved';
    continue when b.user_id is null;
    aid := null;
    insert into public.partner_lead_assignments (request_id, client_id, broker_id, assigned_by)
    values (public.crm_request_for(bid), c.id, bid, me)
    on conflict (client_id, broker_id) do nothing
    returning id into aid;
    continue when aid is null;
    insert into public.partner_lead_events (assignment_id, client_id, broker_id, kind, detail, actor)
    values (aid, c.id, bid, 'assigned', 'Assigned by the MovEazy team' || case when nt <> '' then ' — ' || nt else '' end, me);
    insert into public.crm_activities (client_id, actor_email, type, body, meta)
    values (c.id, me, 'system', 'Assigned to partner ' || coalesce(nullif(b.name, ''), 'Partner') || case when nt <> '' then ' — ' || nt else '' end,
            jsonb_build_object('broker_id', bid, 'assignment_id', aid, 'assigned', true));
    insert into public.partner_notifications (broker_id, kind, title, body, link)
    values (bid, 'leads_assigned', 'New MovEazy client: ' || coalesce(nullif(c.name, ''), 'a tenant'),
            concat_ws(' · ', nullif(need, ''), nullif(nt, ''), 'Call them today — under Leads → MovEazy leads.'), '/leads?tab=moveazy');
    added := added || jsonb_build_object('broker_id', bid, 'assignment_id', aid, 'name', coalesce(nullif(b.name, ''), 'Partner'),
                                         'phone', public.normalize_mobile(b.phone));
  end loop;

  if coalesce(p_replace, false) then
    for x in select a.id from public.partner_lead_assignments a
              where a.client_id = c.id and a.status <> 'closed' and not (a.broker_id = any (coalesce(p_brokers, '{}')))
    loop
      if public.partner_lead_remove(x.id, me) then gone := gone + 1; end if;
    end loop;
  end if;

  return jsonb_build_object('added', added, 'removed', gone,
    'client', jsonb_build_object('name', coalesce(c.name, ''), 'phone', coalesce(c.phone, ''), 'need', need));
end;
$$;

/** Take a client off one partner, from the client's record. */
create or replace function public.crm_partner_unassign(p_assignment uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() or not public.has_admin_scope('crm.clients.write') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  return public.partner_lead_remove(p_assignment, lower(coalesce(auth.jwt() ->> 'email', '')));
end;
$$;

/** The partners to pick from: approved, with how many open clients each has and the areas of their flats. */
create or replace function public.crm_partner_picker()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then raise exception 'Not allowed.' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'broker_id', b.user_id, 'name', coalesce(nullif(b.name, ''), b.email, 'Partner'), 'agency', b.agency,
             'phone', public.normalize_mobile(b.phone),
             'open', (select count(*) from public.partner_lead_assignments a where a.broker_id = b.user_id and a.status in ('assigned', 'contacted', 'visit')),
             'areas', coalesce((select jsonb_agg(distinct i.area) from public.partner_listings pl join public.inventory i on i.property_id = pl.property_id
                                 where pl.broker_id = b.user_id and i.status = 'published' and coalesce(i.area, '') <> ''), '[]'::jsonb))
           order by lower(coalesce(nullif(b.name, ''), b.email)))
      from public.broker_partners b where b.status = 'approved'), '[]'::jsonb);
end;
$$;

/** (partner_website_leads.sql) The CRM's own holder isn't a request the CRM decides on either. */
create or replace function public.crm_lead_requests()
returns table (id uuid, broker_id uuid, broker_name text, broker_phone text, agency text, pack text, lead_count int,
               amount int, utr text, prefs jsonb, status text, note text, created_at timestamptz, assigned int,
               premium_given int, premium_closed int)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.has_admin_scope('partners.manage') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  return query
  select q.id, q.broker_id, coalesce(b.name, ''), coalesce(b.phone, ''), coalesce(b.agency, ''), q.pack, q.lead_count,
         q.amount, q.utr, q.prefs, q.status, q.note, q.created_at,
         (select count(*)::int from public.partner_lead_assignments a where a.request_id = q.id),
         ((public.partner_lead_allowance(q.broker_id)) ->> 'premium_given')::int,
         ((public.partner_lead_allowance(q.broker_id)) ->> 'premium_closed')::int
    from public.partner_lead_requests q
    left join public.broker_partners b on b.user_id = q.broker_id
   where q.pack not in ('website', 'crm')
   order by (q.status in ('payment_check', 'needs_approval', 'open')) desc, q.created_at desc
   limit 300;
end;
$$;

/** (partner_website_leads.sql) …nor one the broker made. */
create or replace function public.partner_my_lead_requests()
returns table (id uuid, pack text, lead_count int, amount int, utr text, prefs jsonb, status text, note text,
               created_at timestamptz, assigned int)
language sql
stable
security definer
set search_path = public
as $$
  select q.id, q.pack, q.lead_count, q.amount, q.utr, q.prefs, q.status, q.note, q.created_at,
         (select count(*)::int from public.partner_lead_assignments a where a.request_id = q.id)
    from public.partner_lead_requests q
   where q.broker_id = auth.uid() and q.pack not in ('website', 'crm')
   order by q.created_at desc
   limit 50;
$$;

-- (partner_pool_milestones.sql) A client the team assigned from the CRM closes with MovEazy's share, like a website lead.
create or replace function public.partner_lead_update(p_assignment uuid, p_status text, p_rent numeric default null, p_deal text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a    public.partner_lead_assignments;
  pk   text;
  due  numeric := 0;
  who  text;
begin
  select * into a from public.partner_lead_assignments where id = p_assignment and broker_id = auth.uid();
  if a.id is null or not public.is_approved_partner() then
    raise exception 'That lead isn''t yours.' using errcode = '42501';
  end if;
  if p_status not in ('contacted', 'visit', 'closed', 'not_interested') then
    raise exception 'Unknown status.' using errcode = '22023';
  end if;
  select q.pack into pk from public.partner_lead_requests q where q.id = a.request_id;
  if p_status = 'closed' then
    if coalesce(p_rent, 0) < 1000 then raise exception 'Enter the monthly rent.' using errcode = '22023'; end if;
    if coalesce(p_deal, '') not in ('direct', 'shared') then raise exception 'Say how the deal went.' using errcode = '22023'; end if;
    if pk in ('premium', 'website', 'milestone', 'crm') then due := round(p_rent * case when p_deal = 'direct' then 0.30 else 0.20 end); end if;
  end if;
  update public.partner_lead_assignments set
    status = p_status,
    closed_rent = case when p_status = 'closed' then p_rent end,
    deal_type = case when p_status = 'closed' then p_deal end,
    due_amount = due,
    closed_at = case when p_status = 'closed' then coalesce(a.closed_at, now()) end,
    updated_at = now()
  where id = a.id;
  select coalesce(nullif(b.name, ''), b.email, 'A partner broker') into who from public.broker_partners b where b.user_id = a.broker_id;
  insert into public.crm_activities (client_id, actor_email, type, body, meta)
  values (a.client_id, '', 'system',
          format('%s marked this lead %s%s', who, replace(p_status, '_', ' '),
                 case when p_status = 'closed' then format(' · rent ₹%s · %s%s', p_rent::bigint,
                   case when p_deal = 'direct' then 'direct with owner' else 'more than one broker' end,
                   case when due > 0 then format(' · ₹%s due to MovEazy', due::bigint) else '' end) else '' end),
          jsonb_build_object('assignment_id', a.id, 'broker_id', a.broker_id, 'status', p_status, 'due', due));
  return jsonb_build_object('status', p_status, 'due_amount', due);
end;
$$;

/**
 * (tenant_views.sql) The client's partners — now also those taken off them,
 * with 'removed_at' and the calls and follow-ups they made before.
 */
create or replace function public.crm_client_broker_activity(p_client uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(j order by (j ->> 'removed_at') nulls first, j ->> 'assigned_at') from (
      select jsonb_build_object(
               'assignment_id', a.id, 'broker_id', a.broker_id, 'broker_name', coalesce(nullif(b.name, ''), 'Partner'),
               'broker_phone', public.normalize_mobile(b.phone), 'pack', q.pack, 'status', a.status, 'assigned_at', a.assigned_at,
               'follow_up_on', a.follow_up_on, 'follow_up_note', a.follow_up_note, 'removed_at', null,
               'first_flat', public.tenant_view_property_json(coalesce(
                   (select w.property_id from public.partner_website_interest w
                     where w.broker_id = a.broker_id and w.client_id = a.client_id order by w.created_at limit 1),
                   (select v.property_id from public.property_tenant_views v join public.partner_listings pl on pl.property_id = v.property_id
                     where pl.broker_id = a.broker_id and v.client_id = a.client_id order by v.first_at limit 1))),
               'flats_seen', (select count(*) from public.property_tenant_views v join public.partner_listings pl on pl.property_id = v.property_id
                               where pl.broker_id = a.broker_id and v.client_id = a.client_id),
               'events', coalesce((select jsonb_agg(jsonb_build_object('kind', e.kind, 'detail', e.detail, 'actor', e.actor, 'at', e.at)
                                                    order by e.at desc, e.id desc)
                                     from (select * from public.partner_lead_events e where e.assignment_id = a.id order by e.at desc limit 60) e), '[]'::jsonb)) j
        from public.partner_lead_assignments a
        join public.partner_lead_requests q on q.id = a.request_id
        left join public.broker_partners b on b.user_id = a.broker_id
       where a.client_id = p_client
      union all
      select jsonb_build_object(
               'assignment_id', r.id, 'broker_id', r.broker_id, 'broker_name', coalesce(nullif(b.name, ''), 'Partner'),
               'broker_phone', public.normalize_mobile(b.phone), 'pack', r.pack, 'status', r.status, 'assigned_at', r.assigned_at,
               'follow_up_on', null, 'follow_up_note', '', 'removed_at', r.removed_at, 'removed_by', r.removed_by,
               'first_flat', null, 'flats_seen', 0,
               'events', coalesce((select jsonb_agg(jsonb_build_object('kind', e.kind, 'detail', e.detail, 'actor', e.actor, 'at', e.at)
                                                    order by e.at desc, e.id desc)
                                     from (select * from public.partner_lead_events e
                                            where e.assignment_id is null and e.client_id = r.client_id and e.broker_id = r.broker_id
                                              and e.at <= r.removed_at + interval '1 minute' and e.at >= coalesce(r.assigned_at, '-infinity')
                                            order by e.at desc limit 60) e), '[]'::jsonb))
        from public.partner_lead_removed r
        left join public.broker_partners b on b.user_id = r.broker_id
       where r.client_id = p_client
    ) x), '[]'::jsonb);
end;
$$;

-- ── The partner's Today list ───────────────────────────────────────────────

/** When a partner last did something on an assignment (calls, WhatsApp, status, follow-ups, answers). */
create or replace function public.partner_last_action(p_assignment uuid)
returns timestamptz
language sql
stable
security definer
set search_path = public
as $$
  select greatest(
    (select max(e.at) from public.partner_lead_events e
      where e.assignment_id = p_assignment and e.kind in ('call', 'whatsapp', 'status', 'follow_up', 'response', 'outcome')),
    (select max(x.at) from public.partner_lead_reachouts x where x.assignment_id = p_assignment));
$$;

create or replace function public.partner_first_action(p_assignment uuid)
returns timestamptz
language sql
stable
security definer
set search_path = public
as $$
  select least(
    (select min(e.at) from public.partner_lead_events e
      where e.assignment_id = p_assignment and e.kind in ('call', 'whatsapp', 'status', 'follow_up', 'response', 'outcome')),
    (select min(x.at) from public.partner_lead_reachouts x where x.assignment_id = p_assignment));
$$;

/**
 * The partner's open MovEazy clients, for Today: who, what they want, the
 * follow-up date and note, the last thing done and said. The app buckets them.
 */
create or replace function public.partner_follow_ups()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_approved_partner() then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'assignment_id', a.id, 'client_id', a.client_id, 'name', coalesce(c.name, ''), 'phone', coalesce(c.phone, ''),
             'need', coalesce(public.client_need_line(c.id), ''), 'status', a.status, 'assigned_at', a.assigned_at,
             'follow_up_on', a.follow_up_on, 'follow_up_note', coalesce(a.follow_up_note, ''),
             'last_action_at', public.partner_last_action(a.id),
             'last_outcome', (select e.detail from public.partner_lead_events e where e.assignment_id = a.id and e.kind = 'outcome'
                               order by e.at desc, e.id desc limit 1),
             'pack', q.pack)
           order by a.follow_up_on nulls first, a.assigned_at desc)
      from public.partner_lead_assignments a
      join public.partner_lead_requests q on q.id = a.request_id
      join public.crm_clients c on c.id = a.client_id
     where a.broker_id = auth.uid() and a.status in ('assigned', 'contacted', 'visit')), '[]'::jsonb);
end;
$$;

/**
 * The partner logs a call: the outcome, the next date (YYYY-MM-DD, '' = none),
 * a note. Moves their status along (talked → contacted, visit booked → visit,
 * not interested / found elsewhere → not interested) and tells the CRM.
 */
create or replace function public.partner_follow_up_save(p_assignment uuid, p_outcome text, p_next text default '', p_note text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a   public.partner_lead_assignments;
  fu  date := case when coalesce(p_next, '') ~ '^\d{4}-\d{2}-\d{2}$' then p_next::date end;
  nt  text := left(trim(coalesce(p_note, '')), 500);
  st  text;
  who text;
  line text;
begin
  select * into a from public.partner_lead_assignments where id = p_assignment and broker_id = auth.uid();
  if a.id is null or not public.is_approved_partner() then
    raise exception 'That lead isn''t yours.' using errcode = '42501';
  end if;
  if p_outcome not in ('talked', 'not_picked', 'call_later', 'busy', 'visit_booked', 'flats_shared', 'not_interested', 'found_elsewhere') then
    raise exception 'Unknown outcome.' using errcode = '22023';
  end if;
  if p_outcome in ('not_interested', 'found_elsewhere') then fu := null; end if;
  st := case
    when a.status = 'closed' then a.status
    when p_outcome in ('not_interested', 'found_elsewhere') then 'not_interested'
    when p_outcome = 'visit_booked' then 'visit'
    when a.status = 'assigned' then 'contacted'
    else a.status end;
  update public.partner_lead_assignments set follow_up_on = fu, follow_up_note = nt, status = st, updated_at = now() where id = a.id;
  select coalesce(nullif(b.name, ''), 'Partner') into who from public.broker_partners b where b.user_id = a.broker_id;
  line := concat_ws(' · ', public.follow_up_outcome_label(p_outcome),
                    coalesce('next ' || to_char(fu, 'DD Mon'), 'no next follow-up'), nullif(nt, ''));
  insert into public.partner_lead_events (assignment_id, client_id, broker_id, kind, detail, actor)
  values (a.id, a.client_id, a.broker_id, 'outcome', line, coalesce(who, ''));
  insert into public.crm_activities (client_id, actor_email, type, body, meta)
  values (a.client_id, '', 'system', coalesce(who, 'Partner') || ' called — ' || line,
          jsonb_build_object('assignment_id', a.id, 'broker_id', a.broker_id, 'outcome', p_outcome, 'follow_up_on', fu));
  return jsonb_build_object('status', st, 'follow_up_on', fu, 'follow_up_note', nt);
end;
$$;

-- ── The CRM's view of the partner side ─────────────────────────────────────

/**
 * Every open assignment with its SLA — 'new' (under 24h, nothing yet), 'amber'
 * (24–48h, nothing yet), 'red' (48h+, nothing yet), 'missed' (their follow-up
 * date passed), 'ok' — and per partner: open, assigned / contacted within 24h /
 * visits / closures / taken off in the last 30 days, hours to first action,
 * overdue now.
 */
create or replace function public.crm_partner_follow_ups()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if not public.is_crm_staff() then raise exception 'Not allowed.' using errcode = '42501'; end if;
  return (
    with open_a as (
      select a.*, q.pack, public.partner_first_action(a.id) first_at, public.partner_last_action(a.id) last_at
        from public.partner_lead_assignments a
        join public.partner_lead_requests q on q.id = a.request_id
       where a.status in ('assigned', 'contacted', 'visit')
    ),
    cur as (
      select o.*, case
               when o.last_at is null and now() - o.assigned_at >= interval '48 hours' then 'red'
               when o.last_at is null and now() - o.assigned_at >= interval '24 hours' then 'amber'
               when o.last_at is null then 'new'
               when o.follow_up_on is not null and o.follow_up_on < today then 'missed'
               else 'ok' end as sla
        from open_a o
    ),
    recent as (
      select a.broker_id, a.id, a.assigned_at, a.status, a.closed_at, public.partner_first_action(a.id) first_at
        from public.partner_lead_assignments a where a.assigned_at > now() - interval '30 days'
    ),
    brokers as (
      select distinct broker_id from public.partner_lead_assignments
      union select broker_id from public.partner_lead_removed where removed_at > now() - interval '30 days'
    )
    select jsonb_build_object(
      'rows', coalesce((select jsonb_agg(jsonb_build_object(
                 'assignment_id', r.id, 'client_id', r.client_id, 'client_name', coalesce(c.name, ''), 'client_phone', coalesce(c.phone, ''),
                 'client_status', c.status, 'broker_id', r.broker_id, 'broker_name', coalesce(nullif(b.name, ''), 'Partner'),
                 'broker_phone', public.normalize_mobile(b.phone), 'status', r.status, 'pack', r.pack, 'assigned_at', r.assigned_at,
                 'first_action_at', r.first_at, 'last_action_at', r.last_at, 'follow_up_on', r.follow_up_on,
                 'follow_up_note', coalesce(r.follow_up_note, ''), 'sla', r.sla,
                 'last_detail', (select e.detail from public.partner_lead_events e where e.assignment_id = r.id
                                  and e.kind in ('outcome', 'follow_up', 'status', 'response') order by e.at desc, e.id desc limit 1))
               order by case r.sla when 'red' then 0 when 'missed' then 1 when 'amber' then 2 when 'new' then 3 else 4 end, r.assigned_at)
          from cur r join public.crm_clients c on c.id = r.client_id
          left join public.broker_partners b on b.user_id = r.broker_id), '[]'::jsonb),
      'partners', coalesce((select jsonb_agg(jsonb_build_object(
                 'broker_id', br.broker_id, 'name', coalesce(nullif(b.name, ''), 'Partner'), 'phone', public.normalize_mobile(b.phone),
                 'open', (select count(*) from cur r where r.broker_id = br.broker_id),
                 'overdue', (select count(*) from cur r where r.broker_id = br.broker_id and r.sla in ('red', 'missed')),
                 'due_today', (select count(*) from cur r where r.broker_id = br.broker_id
                                and (r.follow_up_on <= today or (r.last_at is null) or (r.follow_up_on is null and r.last_at < now() - interval '2 days'))),
                 'assigned_30d', (select count(*) from recent x where x.broker_id = br.broker_id),
                 'contacted_24h', (select count(*) from recent x where x.broker_id = br.broker_id and x.first_at <= x.assigned_at + interval '24 hours'),
                 'visits_30d', (select count(*) from recent x where x.broker_id = br.broker_id and x.status in ('visit', 'closed')),
                 'closed_30d', (select count(*) from public.partner_lead_assignments x where x.broker_id = br.broker_id and x.closed_at > now() - interval '30 days'),
                 'removed_30d', (select count(*) from public.partner_lead_removed x where x.broker_id = br.broker_id and x.removed_at > now() - interval '30 days'),
                 'first_hours', (select round(avg(extract(epoch from (x.first_at - x.assigned_at)) / 3600)::numeric, 1)
                                   from recent x where x.broker_id = br.broker_id and x.first_at is not null))
               order by lower(coalesce(nullif(b.name, ''), 'Partner')))
          from brokers br join public.broker_partners b on b.user_id = br.broker_id), '[]'::jsonb)
    ));
end;
$$;

-- ── The 9:30 morning summary ───────────────────────────────────────────────

create table if not exists public.follow_up_digests (
  day      date primary key,
  ran_at   timestamptz not null default now(),
  crm      int not null default 0,
  partners int not null default 0
);
alter table public.follow_up_digests enable row level security;
revoke all on public.follow_up_digests from anon, authenticated;

/**
 * Once a day, from 9:30 IST: each team member's count of clients due today
 * (theirs plus the unassigned — everyone, while the team shares the list)
 * and overdue; each partner's due and overdue clients. → whether it ran now.
 */
create or replace function public.follow_up_digest_run(p_force boolean default false)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  ist   timestamp := now() at time zone 'Asia/Kolkata';
  today date := (now() at time zone 'Asia/Kolkata')::date;
  sod   timestamptz := (today::timestamp) at time zone 'Asia/Kolkata';
  eod   timestamptz := ((today + 1)::timestamp) at time zone 'Asia/Kolkata';
  ran   date;
  ncrm  int := 0;
  npar  int := 0;
  x     record;
begin
  if not coalesce(p_force, false) and ist::time < time '09:30' then return false; end if;
  insert into public.follow_up_digests (day) values (today) on conflict do nothing returning day into ran;
  if ran is null then return false; end if;

  for x in
    with active as (
      select c.id, lower(coalesce(c.assigned_to, '')) owner, c.next_follow_up_at nxt,
             (select max(a.created_at) from public.crm_activities a
               where a.client_id = c.id and a.type in ('whatsapp', 'call', 'shortlist', 'status', 'contacted')) last_at
        from public.crm_clients c
       where (c.attributed_to = 'moveazy' or c.via = 'qr')
         and c.status not in ('closed_by_us', 'closed_outside') and coalesce(c.temperature, '') <> 'ice'
    ),
    graded as (
      select a.owner,
             (a.nxt is not null and a.nxt < eod) or (a.nxt is null and (a.last_at is null or a.last_at < now() - interval '2 days')) due,
             (a.nxt is not null and a.nxt < sod) or (a.nxt is null and (a.last_at is null or a.last_at < now() - interval '3 days')) overdue
        from active a
    )
    select t.e,
           (select count(*) from graded g where g.due) due,
           (select count(*) from graded g where g.overdue) overdue,
           (select count(*) from graded g where g.due and g.owner = t.e) mine
      from public.crm_team_emails() t(e)
  loop
    insert into public.crm_notifications (for_email, type, title, body)
    values (x.e, 'follow_up', format('Follow-ups today: %s', x.due),
            concat_ws(' · ', format('%s overdue', x.overdue), case when x.mine > 0 then format('%s yours', x.mine) end,
                      'Open Follow-ups to start'));
    ncrm := ncrm + 1;
  end loop;

  for x in
    select a.broker_id,
           count(*) filter (where a.follow_up_on <= today or public.partner_last_action(a.id) is null
                            or (a.follow_up_on is null and public.partner_last_action(a.id) < now() - interval '2 days')) due,
           count(*) filter (where (a.follow_up_on < today) or (public.partner_last_action(a.id) is null and a.assigned_at < now() - interval '48 hours')) overdue
      from public.partner_lead_assignments a
     where a.status in ('assigned', 'contacted', 'visit')
     group by a.broker_id
  loop
    continue when x.due = 0;
    insert into public.partner_notifications (broker_id, kind, title, body, link)
    values (x.broker_id, 'follow_ups', format('%s MovEazy client%s to follow up today', x.due, case when x.due = 1 then '' else 's' end),
            case when x.overdue > 0 then format('%s overdue — call them first.', x.overdue) else 'Log each call so the team sees it.' end,
            '/leads?tab=today');
    npar := npar + 1;
  end loop;

  update public.follow_up_digests set crm = ncrm, partners = npar where day = today;
  return true;
end;
$$;

/** The CRM or partner app opened: send today's summary if 9:30 has passed and cron hasn't yet. */
create or replace function public.follow_up_digest_poke()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not (public.is_crm_staff() or public.is_approved_partner()) then return false; end if;
  return public.follow_up_digest_run(false);
end;
$$;

-- pg_cron at 04:00 UTC = 9:30 IST, where the extension is available.
do $$
begin
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise notice 'pg_cron not available (%); the apps send the summary on opening.', sqlerrm;
  end;
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    execute $q$select cron.schedule('moveazy-follow-up-digest', '0 4 * * *', 'select public.follow_up_digest_run()')$q$;
  end if;
exception when others then
  raise notice 'Could not schedule the summary (%); the apps send it on opening.', sqlerrm;
end;
$$;

-- ── Who may call what ──────────────────────────────────────────────────────

revoke all on function public.follow_up_outcome_label(text) from public, anon;
grant execute on function public.follow_up_outcome_label(text) to authenticated;
revoke all on function public.crm_follow_up_save(uuid, jsonb) from public, anon;
grant execute on function public.crm_follow_up_save(uuid, jsonb) to authenticated;
revoke all on function public.crm_follow_up_settings_get() from public, anon;
grant execute on function public.crm_follow_up_settings_get() to authenticated;
revoke all on function public.crm_follow_up_settings_set(boolean) from public, anon;
grant execute on function public.crm_follow_up_settings_set(boolean) to authenticated;
revoke all on function public.crm_team_emails() from public, anon, authenticated;
revoke all on function public.crm_round_robin_owner() from public, anon, authenticated;
revoke all on function public.crm_request_for(uuid) from public, anon, authenticated;
revoke all on function public.client_need_line(uuid) from public, anon, authenticated;
revoke all on function public.partner_lead_remove(uuid, text) from public, anon, authenticated;
revoke all on function public.crm_partner_assign(uuid, uuid[], boolean, text) from public, anon;
grant execute on function public.crm_partner_assign(uuid, uuid[], boolean, text) to authenticated;
revoke all on function public.crm_partner_unassign(uuid) from public, anon;
grant execute on function public.crm_partner_unassign(uuid) to authenticated;
revoke all on function public.crm_partner_picker() from public, anon;
grant execute on function public.crm_partner_picker() to authenticated;
revoke all on function public.partner_last_action(uuid) from public, anon, authenticated;
revoke all on function public.partner_first_action(uuid) from public, anon, authenticated;
revoke all on function public.partner_follow_ups() from public, anon;
grant execute on function public.partner_follow_ups() to authenticated;
revoke all on function public.partner_follow_up_save(uuid, text, text, text) from public, anon;
grant execute on function public.partner_follow_up_save(uuid, text, text, text) to authenticated;
revoke all on function public.crm_partner_follow_ups() from public, anon;
grant execute on function public.crm_partner_follow_ups() to authenticated;
revoke all on function public.follow_up_digest_run(boolean) from public, anon, authenticated;
revoke all on function public.follow_up_digest_poke() from public, anon;
grant execute on function public.follow_up_digest_poke() to authenticated;

commit;
