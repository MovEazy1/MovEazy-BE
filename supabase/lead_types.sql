-- ─────────────────────────────────────────────────────────────────────────────
-- Lead types: Active, Probable, Dormant (MovEazy-FE CRM → Clients tabs,
-- lib/crmClients.js, lib/leadIntake.js).
--
-- Run in the Supabase SQL editor AFTER crm_schema.sql, lead_intake.sql,
-- crm_follow_ups.sql, visits_schema.sql, user_actions_schema.sql,
-- user_requirements_schema.sql and owner_buildings.sql. Safe to re-run.
--
--   active    did something that means they want a flat: filled in what they
--             need, booked a visit, liked a flat, asked if one is free, paid…
--   probable  only gave a number and browsed (the deals, the society map, the
--             renting guide). Kept out of the daily work: Follow-ups, the
--             Pipeline, Priority closures and the 9:30 summary count Active only.
--   dormant   only when the team marks it.
--
-- Everyone already in the CRM stays Active. A new lead the site creates (the
-- phone gate, a number added after sign-in) starts Probable; one the team adds
-- starts Active. A probable lead becomes Active the moment they do any of the
-- above — and so does a dormant one, so a lead the team had given up on who
-- books a visit is in front of them again.
--
-- "Notify me" on a coming-soon page records what they asked for on the client
-- (interests) and in their history; it doesn't make them Active.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

alter table public.crm_clients add column if not exists lead_type text not null default 'active';
alter table public.crm_clients add column if not exists lead_type_at timestamptz;
alter table public.crm_clients add column if not exists lead_type_by text not null default '';
alter table public.crm_clients add column if not exists interests text[] not null default '{}';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'crm_clients_lead_type_check') then
    alter table public.crm_clients add constraint crm_clients_lead_type_check check (lead_type in ('active', 'probable', 'dormant'));
  end if;
end $$;
create index if not exists crm_clients_lead_type_idx on public.crm_clients (lead_type);

/** A lead the site creates starts Probable; one the team adds, Active. */
create or replace function public.crm_clients_lead_type_new()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() and new.lead_type = 'active' then
    new.lead_type := 'probable';
    new.lead_type_at := now();
    new.lead_type_by := 'site';
  end if;
  return new;
end;
$$;
drop trigger if exists crm_clients_lead_type_new on public.crm_clients;
create trigger crm_clients_lead_type_new before insert on public.crm_clients
  for each row execute function public.crm_clients_lead_type_new();

/** Make a lead Active (a high-intent action). No-op when already Active. */
create or replace function public.crm_lead_activate(p_client uuid, p_why text default '')
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_client is null then return; end if;
  update public.crm_clients
     set lead_type = 'active', lead_type_at = now(), lead_type_by = left(coalesce(nullif(p_why, ''), 'site'), 80)
   where id = p_client and lead_type <> 'active';
end;
$$;

/** The same, found by account or by mobile number. */
create or replace function public.crm_lead_activate_by(p_user uuid, p_phone text, p_why text default '')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  ph text := public.normalize_mobile(coalesce(p_phone, ''));
  c  uuid;
begin
  if p_user is not null then
    for c in select id from public.crm_clients where user_id = p_user loop
      perform public.crm_lead_activate(c, p_why);
    end loop;
  end if;
  if coalesce(ph, '') <> '' then
    for c in select id from public.crm_clients where public.normalize_mobile(phone) = ph loop
      perform public.crm_lead_activate(c, p_why);
    end loop;
  end if;
end;
$$;

-- The client's own funnel moving on (a visit pending, a shortlist sent, a close) is Active.
create or replace function public.crm_clients_lead_type_status()
returns trigger
language plpgsql
as $$
begin
  if new.status is distinct from old.status and new.status <> 'fresh' and new.lead_type <> 'active'
     and new.lead_type = old.lead_type then
    new.lead_type := 'active';
    new.lead_type_at := now();
    new.lead_type_by := 'status: ' || new.status;
  end if;
  return new;
end;
$$;
drop trigger if exists crm_clients_lead_type_status on public.crm_clients;
create trigger crm_clients_lead_type_status before update of status on public.crm_clients
  for each row execute function public.crm_clients_lead_type_status();

-- History rows that mean intent: a visit, a shortlist, a payment, the caretaker
-- called, or the site noting a booking, a like, a saved search, a payment.
create or replace function public.crm_activities_lead_type()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.type in ('visit', 'shortlist', 'payment', 'caretaker')
     or (new.type = 'system' and coalesce(new.body, '') ~* '(booked|visit|liked|saved a flat search|requirement|availab|token|paid|payment|shortlist)') then
    perform public.crm_lead_activate(new.client_id, new.type);
  end if;
  return null;
end;
$$;
drop trigger if exists crm_activities_lead_type on public.crm_activities;
create trigger crm_activities_lead_type after insert on public.crm_activities
  for each row execute function public.crm_activities_lead_type();

create or replace function public.crm_requirements_lead_type()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.crm_lead_activate(new.client_id, 'requirement');
  return null;
end;
$$;

-- A tenant filling in what they need (signed in).
create or replace function public.user_requirements_lead_type()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.crm_lead_activate_by(new.user_id, null, 'requirement');
  return null;
end;
$$;

-- ...or before signing in (the phone-first questionnaire).
create or replace function public.lead_intake_lead_type()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(new.prefs, '{}'::jsonb) <> '{}'::jsonb or new.completed then
    if new.crm_client_id is not null then
      perform public.crm_lead_activate(new.crm_client_id, 'requirement');
    else
      perform public.crm_lead_activate_by(null, new.phone, 'requirement');
    end if;
  end if;
  return null;
end;
$$;

-- Liking a flat.
create or replace function public.listing_reactions_lead_type()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.reaction = 'like' then perform public.crm_lead_activate_by(new.user_id, null, 'liked a flat'); end if;
  return null;
end;
$$;

-- Booking a visit: the site's own bookings, and a building's visit requests.
create or replace function public.visit_bookings_lead_type()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.crm_lead_activate_by(new.user_id, null, 'booked a visit');
  return null;
end;
$$;

create or replace function public.building_leads_lead_type()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.crm_lead_activate_by(null, new.phone, 'asked for a visit');
  return null;
end;
$$;

-- Anything the site logs that is a shortlist, a visit, an availability check, a like, a booking or a payment.
create or replace function public.user_actions_lead_type()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(new.action, '') ~* '(shortlist|visit|availab|like|book|pay|enquir|contact|call)' then
    perform public.crm_lead_activate_by(new.user_id, null, new.action);
  end if;
  return null;
end;
$$;

-- The triggers, on whichever of these tables this project has.
do $$
declare
  t record;
begin
  for t in select * from (values
    ('crm_client_requirements', 'crm_requirements_lead_type', 'after insert or update'),
    ('user_requirements', 'user_requirements_lead_type', 'after insert or update'),
    ('lead_intake', 'lead_intake_lead_type', 'after insert or update'),
    ('listing_reactions', 'listing_reactions_lead_type', 'after insert or update'),
    ('visit_bookings', 'visit_bookings_lead_type', 'after insert'),
    ('owner_building_leads', 'building_leads_lead_type', 'after insert'),
    ('user_actions', 'user_actions_lead_type', 'after insert')) v(tbl, fn, ev)
  loop
    if to_regclass('public.' || t.tbl) is not null then
      execute format('drop trigger if exists %I on public.%I', t.fn, t.tbl);
      execute format('create trigger %I %s on public.%I for each row execute function public.%I()', t.fn, t.ev, t.tbl, t.fn);
    end if;
  end loop;
end $$;

/** The team: mark a client Dormant, or bring them back to Active (or Probable). */
create or replace function public.crm_lead_type_set(p_client uuid, p_type text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  who text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if not public.has_admin_scope('crm.clients.write') then raise exception 'Needs permission to edit clients.' using errcode = '42501'; end if;
  if p_type not in ('active', 'probable', 'dormant') then raise exception 'Pick Active, Probable or Dormant.' using errcode = '22023'; end if;
  update public.crm_clients set lead_type = p_type, lead_type_at = now(), lead_type_by = who where id = p_client;
  if not found then raise exception 'No such client.' using errcode = '22023'; end if;
  insert into public.crm_activities (client_id, actor_email, type, body)
  values (p_client, who, 'note', format('Marked %s', case p_type when 'dormant' then 'Dormant' when 'probable' then 'Probable' else 'Active' end));
  return (select jsonb_build_object('id', id, 'lead_type', lead_type, 'lead_type_at', lead_type_at, 'lead_type_by', lead_type_by)
            from public.crm_clients where id = p_client);
end;
$$;

/**
 * "Notify me when it's live" on a coming-soon page: 'society_map' or
 * 'renting_guide'. Found by the browser's lead key (phone gate) or the
 * signed-in account. Doesn't make them Active.
 */
create or replace function public.lead_interest_add(p_lead_key text, p_interest text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  c uuid;
  label text := case p_interest when 'society_map' then 'the Society map' when 'renting_guide' then 'the Bangalore Flat Renting Guide' end;
begin
  if label is null then raise exception 'Unknown page.' using errcode = '22023'; end if;
  if coalesce(p_lead_key, '') ~ '^[0-9a-f]{32}$' then
    select crm_client_id into c from public.lead_intake where lead_key = p_lead_key;
  end if;
  if c is null and auth.uid() is not null then
    select id into c from public.crm_clients where user_id = auth.uid();
  end if;
  if c is null then return false; end if;
  update public.crm_clients set interests = interests || p_interest
   where id = c and not (p_interest = any(interests));
  if found then
    insert into public.crm_activities (client_id, type, body) values (c, 'note', format('Asked to be told when %s is live', label));
  end if;
  return true;
end;
$$;

revoke all on function public.crm_clients_lead_type_new() from public, anon, authenticated;
revoke all on function public.crm_lead_activate(uuid, text) from public, anon, authenticated;
revoke all on function public.crm_lead_activate_by(uuid, text, text) from public, anon, authenticated;
revoke all on function public.crm_activities_lead_type() from public, anon, authenticated;
revoke all on function public.crm_requirements_lead_type() from public, anon, authenticated;
revoke all on function public.user_requirements_lead_type() from public, anon, authenticated;
revoke all on function public.lead_intake_lead_type() from public, anon, authenticated;
revoke all on function public.listing_reactions_lead_type() from public, anon, authenticated;
revoke all on function public.visit_bookings_lead_type() from public, anon, authenticated;
revoke all on function public.building_leads_lead_type() from public, anon, authenticated;
revoke all on function public.user_actions_lead_type() from public, anon, authenticated;
revoke all on function public.crm_lead_type_set(uuid, text) from public, anon;
grant execute on function public.crm_lead_type_set(uuid, text) to authenticated;
revoke all on function public.lead_interest_add(text, text) from public;
grant execute on function public.lead_interest_add(text, text) to anon, authenticated;

-- The 9:30 summary counts Active leads only (otherwise as in crm_follow_ups.sql).
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
         and coalesce(c.lead_type, 'active') = 'active'
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
revoke all on function public.follow_up_digest_run(boolean) from public, anon, authenticated;

commit;
