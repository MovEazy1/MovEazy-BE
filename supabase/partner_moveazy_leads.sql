-- ─────────────────────────────────────────────────────────────────────────────
-- MovEazy leads for partner brokers.
--
-- Run in the Supabase SQL editor AFTER crm_schema.sql, user_requirements_schema.sql,
-- program_settings.sql, partner_schema.sql and partner_launch.sql. Safe to re-run.
--
-- What a broker sees on partners.moveazy.co.in → Leads → MovEazy leads:
--   only totals — "312 looking for a 1 BHK in HSR", "100 moving before 1 Nov",
--   "80 with ₹20–35k" — over MovEazy's own open clients (not ones that came in
--   through a broker) with a budget or move-in date, active in the last 60
--   days, and given to fewer than 3 brokers. Never a name or a number.
--
-- Asking for leads (partner_lead_request):
--   free10   10 leads, once per broker, ever
--   paid30   30 leads for program_settings.lead_pack_price (₹2,000). Online
--            (Razorpay, once its keys are in Vercel — api/lead-pay.js): paid
--            means open for assigning, no checking. Until then: UPI to
--            program_settings.lead_upi_id, the broker gives the UTR, and a CRM
--            admin checks the bank before anything is assigned.
--   premium  Premium brokers: up to 10 per request, one every 3 days, nothing
--            up front — MovEazy takes 30% of a month's rent on a closure where
--            the broker dealt with the owner directly, 20% where more than one
--            broker was involved. Every 20 leads given need a closure; past
--            that a request waits for MovEazy's approval (asked on WhatsApp).
--   The broker says what they want (areas, BHK, budget); MovEazy assigns.
--
-- The CRM's Lead requests page (partners.manage) approves payments, picks the
-- clients (each to at most 3 brokers) and assigns them. The broker then sees
-- name and number under "My assigned leads", and every WhatsApp or call they
-- start is logged against that client, so the CRM knows who reached out.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

-- ── Settings the CRM edits ───────────────────────────────────────────────────
alter table public.program_settings add column if not exists lead_upi_id text not null default '8090911024@pthdfc';
alter table public.program_settings add column if not exists lead_pack_price int not null default 2000;
alter table public.program_settings drop constraint if exists program_settings_lead_upi_check;
alter table public.program_settings add constraint program_settings_lead_upi_check
  check (lead_upi_id = '' or lead_upi_id ~ '^[A-Za-z0-9._-]{2,200}@[A-Za-z0-9.-]{2,64}$');
alter table public.program_settings drop constraint if exists program_settings_lead_price_check;
alter table public.program_settings add constraint program_settings_lead_price_check check (lead_pack_price between 0 and 1000000);

-- ── Move-in, as a date ───────────────────────────────────────────────────────
-- The site's questionnaire answers "Immediately / Within 15 days / Within 1
-- month / Flexible", counted from when they answered; the CRM's is free text
-- ("2nd Oct", "15 Oct 2026", "ASAP"). Null when it can't be read, or is flexible.
create or replace function public.lead_move_in_date(p_raw text, p_said timestamptz)
returns date
language plpgsql
stable
as $$
declare
  s    text := lower(trim(coalesce(p_raw, '')));
  base date := coalesce(p_said, now())::date;
  d    date;
begin
  if s = '' or s ~ 'flexib|not sure|any ?time|undecided' then return null; end if;
  if s ~ 'immediate|asap|right away|^now' then return base; end if;
  if s ~ '(15|fifteen) days|2 weeks|two weeks' then return base + 15; end if;
  if s ~ '(1|one) month|30 days' then return base + 30; end if;
  if s ~ '(2|two) months|60 days' then return base + 60; end if;
  s := regexp_replace(s, '(\d+)(st|nd|rd|th)\M', '\1', 'g');
  s := regexp_replace(s, '[,.]', ' ', 'g');
  s := trim(regexp_replace(s, '\s+', ' ', 'g'));
  -- "october" / "oct" alike: the first three letters are the month.
  s := regexp_replace(s, '\m([a-z]{3})[a-z]*\M', '\1', 'g');
  if s ~ '^\d{4}-\d{1,2}-\d{1,2}$' then
    begin return s::date; exception when others then return null; end;
  end if;
  if s ~ '^\d{1,2} [a-z]{3} \d{4}$' then
    begin return to_date(s, 'DD Mon YYYY'); exception when others then null; end;
  end if;
  if s ~ '^\d{1,2} [a-z]{3}$' then
    begin
      d := to_date(s || ' ' || extract(year from base)::int, 'DD Mon YYYY');
      -- "2 Jan" said in December means next January.
      if d < base - 60 then d := (d + interval '1 year')::date; end if;
      return d;
    exception when others then null;
    end;
  end if;
  return null;
end;
$$;

-- ── Requests, assignments, reach-outs ───────────────────────────────────────
create table if not exists public.partner_lead_requests (
  id          uuid primary key default gen_random_uuid(),
  broker_id   uuid not null references auth.users (id) on delete cascade,
  pack        text not null check (pack in ('free10', 'paid30', 'premium')),
  lead_count  int not null check (lead_count between 1 and 100),
  amount      int not null default 0,
  utr         text not null default '',
  prefs       jsonb not null default '{}'::jsonb,
  status      text not null default 'open'
                check (status in ('awaiting_payment', 'payment_check', 'needs_approval', 'open', 'fulfilled', 'rejected', 'cancelled')),
  note        text not null default '',
  -- Razorpay, when it's on: the link we made and the payment that settled it.
  link_id     text not null default '',
  link_url    text not null default '',
  gateway_payment text not null default '',
  decided_by  text not null default '',
  decided_at  timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists partner_lead_requests_broker_idx on public.partner_lead_requests (broker_id, created_at desc);
create index if not exists partner_lead_requests_status_idx on public.partner_lead_requests (status, created_at);
-- A UTR pays for one pack.
create unique index if not exists partner_lead_requests_utr_idx on public.partner_lead_requests (upper(utr)) where utr <> '';

create table if not exists public.partner_lead_assignments (
  id           uuid primary key default gen_random_uuid(),
  request_id   uuid not null references public.partner_lead_requests (id) on delete cascade,
  client_id    uuid not null references public.crm_clients (id) on delete cascade,
  broker_id    uuid not null references auth.users (id) on delete cascade,
  status       text not null default 'assigned'
                 check (status in ('assigned', 'contacted', 'visit', 'closed', 'not_interested')),
  closed_rent  numeric,
  deal_type    text check (deal_type in ('direct', 'shared')),
  due_amount   numeric not null default 0,
  closed_at    timestamptz,
  assigned_by  text not null default '',
  assigned_at  timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (client_id, broker_id)
);
create index if not exists partner_lead_assignments_broker_idx on public.partner_lead_assignments (broker_id, assigned_at desc);
create index if not exists partner_lead_assignments_client_idx on public.partner_lead_assignments (client_id);

create table if not exists public.partner_lead_reachouts (
  id            bigint generated always as identity primary key,
  assignment_id uuid not null references public.partner_lead_assignments (id) on delete cascade,
  client_id     uuid not null references public.crm_clients (id) on delete cascade,
  broker_id     uuid not null references auth.users (id) on delete cascade,
  channel       text not null check (channel in ('whatsapp', 'call')),
  at            timestamptz not null default now()
);
create index if not exists partner_lead_reachouts_client_idx on public.partner_lead_reachouts (client_id, at desc);

alter table public.partner_lead_requests enable row level security;
alter table public.partner_lead_assignments enable row level security;
alter table public.partner_lead_reachouts enable row level security;
revoke all on public.partner_lead_requests, public.partner_lead_assignments, public.partner_lead_reachouts
  from public, anon, authenticated;
-- Everything goes through the functions below; staff may also read.
drop policy if exists "staff read" on public.partner_lead_requests;
create policy "staff read" on public.partner_lead_requests for select to authenticated using (public.is_crm_staff());
drop policy if exists "staff read" on public.partner_lead_assignments;
create policy "staff read" on public.partner_lead_assignments for select to authenticated using (public.is_crm_staff());
drop policy if exists "staff read" on public.partner_lead_reachouts;
create policy "staff read" on public.partner_lead_reachouts for select to authenticated using (public.is_crm_staff());
grant select on public.partner_lead_requests, public.partner_lead_assignments, public.partner_lead_reachouts to authenticated;

-- Two more notification kinds, keeping whatever kinds the table allows already.
do $$
declare
  kinds text[];
begin
  select array_agg(distinct m[1]) into kinds
    from pg_constraint c, regexp_matches(pg_get_constraintdef(c.oid), '''([a-z_]+)''', 'g') m
   where c.conname = 'partner_notifications_kind_check';
  kinds := array(select distinct k from unnest(coalesce(kinds, '{}') || array['leads_assigned', 'lead_request']) k order by 1);
  alter table public.partner_notifications drop constraint if exists partner_notifications_kind_check;
  execute format('alter table public.partner_notifications add constraint partner_notifications_kind_check check (kind in (%s))',
                 (select string_agg(quote_literal(k), ', ') from unnest(kinds) k));
end $$;

-- ── The pool ─────────────────────────────────────────────────────────────────
-- MovEazy's own open clients with something to go on: the CRM's requirement
-- where an agent set one, else what they told the site. Internal only.
drop function if exists public.moveazy_lead_pool();
create function public.moveazy_lead_pool()
returns table (
  client_id   uuid,
  name        text,
  phone       text,
  localities  text[],
  flat_types  text[],
  occupants   text[],
  budget_min  numeric,
  budget_max  numeric,
  move_in_raw text,
  move_in     date,
  active_at   timestamptz,
  brokers     int
)
language sql
stable
security definer
set search_path = public
as $$
  with base as (
    select c.id, c.name, c.phone,
           coalesce(nullif(r.localities, '{}'), u.localities, '{}') as localities,
           coalesce(nullif(r.flat_types, '{}'), u.flat_types, '{}') as flat_types,
           coalesce(nullif(r.occupants, '{}'), u.occupants, '{}') as occupants,
           coalesce(r.budget_min, u.budget_min) as budget_min,
           coalesce(r.budget_max, u.budget_max) as budget_max,
           case when coalesce(r.move_in, '') <> '' then r.move_in else coalesce(u.notes ->> 'moveInDate', '') end as move_in_raw,
           case when coalesce(r.move_in, '') <> '' then r.updated_at else u.updated_at end as said_at,
           greatest(c.created_at, c.updated_at, r.updated_at, u.updated_at) as active_at
      from public.crm_clients c
      left join public.crm_client_requirements r on r.client_id = c.id
      left join public.user_requirements u on u.user_id = c.user_id
     where coalesce(c.attributed_to, 'moveazy') = 'moveazy'
       and coalesce(c.status, '') not in ('closed_by_us', 'closed_outside')
  )
  select b.id, coalesce(b.name, ''), coalesce(b.phone, ''), b.localities, b.flat_types, b.occupants,
         b.budget_min, b.budget_max, b.move_in_raw, public.lead_move_in_date(b.move_in_raw, b.said_at), b.active_at,
         (select count(*)::int from public.partner_lead_assignments a where a.client_id = b.id)
    from base b
   where b.active_at >= now() - interval '60 days'
     and (b.budget_min is not null or b.budget_max is not null or b.move_in_raw <> '');
$$;
revoke all on function public.moveazy_lead_pool() from public, anon, authenticated;

-- ── What a broker may ask for right now ──────────────────────────────────────
create or replace function public.partner_lead_allowance(p_broker uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  free_used boolean;
  open_req  jsonb;
  last_prem timestamptz;
  given     int;
  closed    int;
begin
  select exists (select 1 from public.partner_lead_requests q
                  where q.broker_id = p_broker and q.pack = 'free10' and q.status not in ('rejected', 'cancelled'))
    into free_used;
  select jsonb_build_object('id', q.id, 'pack', q.pack, 'status', q.status) into open_req
    from public.partner_lead_requests q
   where q.broker_id = p_broker and q.status in ('payment_check', 'needs_approval', 'open')
   order by q.created_at desc limit 1;
  -- An online payment started and never finished doesn't hold anything up.
  select max(q.created_at) into last_prem from public.partner_lead_requests q
   where q.broker_id = p_broker and q.pack = 'premium' and q.status not in ('rejected', 'cancelled');
  select count(*) filter (where true), count(*) filter (where a.status = 'closed')
    into given, closed
    from public.partner_lead_assignments a
    join public.partner_lead_requests q on q.id = a.request_id
   where a.broker_id = p_broker and q.pack = 'premium';
  return jsonb_build_object(
    'free_used', free_used,
    'open_request', open_req,
    'premium_next_at', case when last_prem > now() - interval '3 days' then last_prem + interval '3 days' end,
    'premium_given', given,
    'premium_closed', closed,
    -- Every 20 given needs a closure; past that MovEazy decides.
    'premium_needs_approval', given >= 20 * (closed + 1)
  );
end;
$$;
revoke all on function public.partner_lead_allowance(uuid) from public, anon, authenticated;

-- ── Broker side ──────────────────────────────────────────────────────────────

/** The totals, the price and UPI to pay, and what this broker may ask for. Never a lead. */
create or replace function public.partner_moveazy_lead_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  today      date := (now() at time zone 'Asia/Kolkata')::date;
  next_month date := (date_trunc('month', (now() at time zone 'Asia/Kolkata')) + interval '1 month')::date;
  out        jsonb;
begin
  if not public.is_approved_partner() then
    raise exception 'Only MovEazy partners can see this.' using errcode = '42501';
  end if;
  with pool as (select * from public.moveazy_lead_pool() p where p.brokers < 3),
  pairs as (
    select f as bhk, a as area, count(distinct p.client_id)::int as n
      from pool p, unnest(case when cardinality(p.flat_types) > 0 then p.flat_types else array['Any'] end) f,
                   unnest(case when cardinality(p.localities) > 0 then p.localities else array['Anywhere'] end) a
     group by 1, 2
  )
  select jsonb_build_object(
    'total', (select count(*) from pool),
    'bhk_area', coalesce((select jsonb_agg(jsonb_build_object('bhk', bhk, 'area', area, 'n', n) order by n desc, bhk, area)
                            from pairs), '[]'::jsonb),
    'move_in', jsonb_build_object(
      'week',     (select count(*) from pool where move_in <= today + 7),
      'before',   (select count(*) from pool where move_in < next_month),
      'before_date', next_month,
      'month',    (select count(*) from pool where move_in > today + 7 and move_in <= today + 30),
      'two_months', (select count(*) from pool where move_in > today + 30 and move_in <= today + 60),
      'later',    (select count(*) from pool where move_in > today + 60),
      'flexible', (select count(*) from pool where move_in is null)),
    'budget', jsonb_build_object(
      'under20', (select count(*) from pool where coalesce(budget_max, budget_min) < 20000),
      'b20_35',  (select count(*) from pool where coalesce(budget_max, budget_min) >= 20000 and coalesce(budget_max, budget_min) < 35000),
      'b35_50',  (select count(*) from pool where coalesce(budget_max, budget_min) >= 35000 and coalesce(budget_max, budget_min) < 50000),
      'b50plus', (select count(*) from pool where coalesce(budget_max, budget_min) >= 50000),
      'unknown', (select count(*) from pool where coalesce(budget_max, budget_min) is null)),
    'pack_price', (select s.lead_pack_price from public.program_settings s where s.id = 1),
    'upi_id', (select s.lead_upi_id from public.program_settings s where s.id = 1),
    'premium', public.partner_has_tier('moveazy_inventory'),
    'allowance', public.partner_lead_allowance(auth.uid())
  ) into out;
  return out;
end;
$$;

/**
 * Ask for leads. p_prefs: { areas: [], flat_types: [], budget_min, budget_max }.
 * → { id, status, pack } — status 'needs_approval' means: message MovEazy.
 */
drop function if exists public.partner_lead_request(text, jsonb, text);
create or replace function public.partner_lead_request(p_pack text, p_prefs jsonb default '{}', p_utr text default '', p_online boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me     uuid := auth.uid();
  allow  jsonb;
  v_utr  text := upper(regexp_replace(coalesce(p_utr, ''), '\s', '', 'g'));
  prefs  jsonb;
  v_status text := 'open';
  cnt    int;
  amt    int := 0;
  v_row  public.partner_lead_requests;
begin
  if not public.is_approved_partner() then
    raise exception 'Only MovEazy partners can ask for leads.' using errcode = '42501';
  end if;
  -- A Razorpay payment they started and left: dropped when they ask again.
  update public.partner_lead_requests set status = 'cancelled', updated_at = now()
   where broker_id = me and status = 'awaiting_payment';
  allow := public.partner_lead_allowance(me);
  if allow -> 'open_request' is not null and allow -> 'open_request' <> 'null'::jsonb then
    raise exception 'You already have a request with MovEazy. We''ll assign those leads first.' using errcode = '22023';
  end if;

  prefs := jsonb_build_object(
    'areas', coalesce((select jsonb_agg(left(x, 60)) from (select jsonb_array_elements_text(coalesce(p_prefs -> 'areas', '[]')) x limit 10) s), '[]'::jsonb),
    'flat_types', coalesce((select jsonb_agg(left(x, 40)) from (select jsonb_array_elements_text(coalesce(p_prefs -> 'flat_types', '[]')) x limit 6) s), '[]'::jsonb),
    'budget_min', case when coalesce(p_prefs ->> 'budget_min', '') ~ '^\d{1,7}$' then (p_prefs ->> 'budget_min')::int end,
    'budget_max', case when coalesce(p_prefs ->> 'budget_max', '') ~ '^\d{1,7}$' then (p_prefs ->> 'budget_max')::int end
  );

  if p_pack = 'free10' then
    if (allow ->> 'free_used')::boolean then
      raise exception 'Your 10 free leads are already used.' using errcode = '22023';
    end if;
    cnt := 10;
  elsif p_pack = 'paid30' and p_online then
    cnt := 30;
    amt := (select s.lead_pack_price from public.program_settings s where s.id = 1);
    v_utr := '';
    v_status := 'awaiting_payment';
  elsif p_pack = 'paid30' then
    if v_utr !~ '^[A-Z0-9]{6,30}$' then
      raise exception 'Enter the UTR / reference number from your payment app.' using errcode = '22023';
    end if;
    if exists (select 1 from public.partner_lead_requests q where upper(q.utr) = v_utr) then
      raise exception 'That UTR has already been used.' using errcode = '22023';
    end if;
    cnt := 30;
    amt := (select s.lead_pack_price from public.program_settings s where s.id = 1);
    v_status := 'payment_check';
  elsif p_pack = 'premium' then
    if not public.partner_has_tier('moveazy_inventory') then
      raise exception 'Unlimited leads come with Premium.' using errcode = '42501';
    end if;
    if allow ->> 'premium_next_at' is not null then
      raise exception 'You can ask again on %.',
        to_char(((allow ->> 'premium_next_at')::timestamptz at time zone 'Asia/Kolkata'), 'DD Mon, HH12:MI AM')
        using errcode = '22023';
    end if;
    cnt := 10;
    if (allow ->> 'premium_needs_approval')::boolean then v_status := 'needs_approval'; end if;
  else
    raise exception 'Unknown pack.' using errcode = '22023';
  end if;

  insert into public.partner_lead_requests (broker_id, pack, lead_count, amount, utr, prefs, status)
  values (me, p_pack, cnt, amt, v_utr, prefs, v_status)
  returning * into v_row;
  return jsonb_build_object('id', v_row.id, 'status', v_row.status, 'pack', v_row.pack, 'lead_count', v_row.lead_count,
                            'amount', v_row.amount);
end;
$$;

/**
 * Razorpay says a lead pack's link was paid (api/razorpay-webhook.js, as the
 * service role). The link and the amount must be the ones we made; then the
 * request is open for assigning. Idempotent — Razorpay retries.
 */
create or replace function public.partner_lead_razorpay_paid(p_request uuid, p_link_id text, p_gateway_payment text, p_amount_paise bigint)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  q public.partner_lead_requests;
begin
  select * into q from public.partner_lead_requests where id = p_request for update;
  if q.id is null then return 'unknown'; end if;
  if q.status in ('open', 'fulfilled') and q.gateway_payment <> '' then return 'already'; end if;
  if q.status not in ('awaiting_payment', 'cancelled') then return 'not_waiting'; end if;
  if q.link_id = '' or q.link_id <> coalesce(p_link_id, '') then return 'wrong_link'; end if;
  if coalesce(p_amount_paise, 0) < q.amount::bigint * 100 then return 'short'; end if;
  update public.partner_lead_requests
     set status = 'open', gateway_payment = left(coalesce(p_gateway_payment, ''), 60),
         utr = case when utr = '' then upper(left(coalesce(p_gateway_payment, ''), 30)) else utr end,
         note = 'Paid online', decided_at = now(), decided_by = 'razorpay', updated_at = now()
   where id = q.id;
  insert into public.partner_notifications (broker_id, kind, title, body, link)
  values (q.broker_id, 'lead_request', 'Payment received', 'MovEazy is picking your 30 leads now.', '/leads?tab=moveazy');
  return 'paid';
end;
$$;
revoke all on function public.partner_lead_razorpay_paid(uuid, text, text, bigint) from public, anon, authenticated;
-- The webhook's server-side call.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.partner_lead_razorpay_paid(uuid, text, text, bigint) to service_role';
  end if;
end $$;

/** The broker's requests, newest first, with how many were assigned. */
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
   where q.broker_id = auth.uid()
   order by q.created_at desc
   limit 50;
$$;

/** Leads MovEazy gave this broker: name and number, what they want, where it stands. */
create or replace function public.partner_my_assigned_leads()
returns table (id uuid, name text, phone text, localities text[], flat_types text[], occupants text[],
               budget_min numeric, budget_max numeric, move_in_raw text, move_in date, status text,
               closed_rent numeric, deal_type text, due_amount numeric, pack text, assigned_at timestamptz,
               last_reach_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  with mine as (
    select a.*, q.pack from public.partner_lead_assignments a
      join public.partner_lead_requests q on q.id = a.request_id
     where a.broker_id = auth.uid() and public.is_approved_partner()
  ),
  c as (
    select c.id, c.name, c.phone,
           coalesce(nullif(r.localities, '{}'), u.localities, '{}') localities,
           coalesce(nullif(r.flat_types, '{}'), u.flat_types, '{}') flat_types,
           coalesce(nullif(r.occupants, '{}'), u.occupants, '{}') occupants,
           coalesce(r.budget_min, u.budget_min) budget_min, coalesce(r.budget_max, u.budget_max) budget_max,
           case when coalesce(r.move_in, '') <> '' then r.move_in else coalesce(u.notes ->> 'moveInDate', '') end move_in_raw,
           case when coalesce(r.move_in, '') <> '' then r.updated_at else u.updated_at end said_at
      from public.crm_clients c
      left join public.crm_client_requirements r on r.client_id = c.id
      left join public.user_requirements u on u.user_id = c.user_id
     where c.id in (select client_id from mine)
  )
  select m.id, coalesce(c.name, ''), coalesce(c.phone, ''), c.localities, c.flat_types, c.occupants,
         c.budget_min, c.budget_max, c.move_in_raw, public.lead_move_in_date(c.move_in_raw, c.said_at),
         m.status, m.closed_rent, m.deal_type, m.due_amount, m.pack, m.assigned_at,
         (select max(x.at) from public.partner_lead_reachouts x where x.assignment_id = m.id)
    from mine m join c on c.id = m.client_id
   order by m.assigned_at desc;
$$;

/** The broker tapped WhatsApp or Call on an assigned lead: remember it. */
create or replace function public.partner_lead_reach_out(p_assignment uuid, p_channel text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.partner_lead_assignments;
begin
  select * into a from public.partner_lead_assignments where id = p_assignment and broker_id = auth.uid();
  if a.id is null or not public.is_approved_partner() then
    raise exception 'That lead isn''t yours.' using errcode = '42501';
  end if;
  if p_channel not in ('whatsapp', 'call') then
    raise exception 'Unknown channel.' using errcode = '22023';
  end if;
  insert into public.partner_lead_reachouts (assignment_id, client_id, broker_id, channel) values (a.id, a.client_id, a.broker_id, p_channel);
  if a.status = 'assigned' then
    update public.partner_lead_assignments set status = 'contacted', updated_at = now() where id = a.id;
  end if;
end;
$$;

/**
 * Where an assigned lead stands. Closed needs the month's rent and how the deal
 * went: 'direct' (the broker dealt with the owner) or 'shared' (more than one
 * broker). On a Premium lead MovEazy's share is 30% / 20% of that rent.
 */
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
    if p_deal not in ('direct', 'shared') then raise exception 'Say how the deal went.' using errcode = '22023'; end if;
    if pk = 'premium' then due := round(p_rent * case when p_deal = 'direct' then 0.30 else 0.20 end); end if;
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

-- ── CRM side (partners.manage) ───────────────────────────────────────────────

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
   order by (q.status in ('payment_check', 'needs_approval', 'open')) desc, q.created_at desc
   limit 300;
end;
$$;

/** Payment checked (or more leads allowed): approve → open for assigning; or reject. */
create or replace function public.crm_lead_request_decide(p_request uuid, p_approve boolean, p_note text default '')
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  q public.partner_lead_requests;
  st text;
begin
  if not public.has_admin_scope('partners.manage') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  select * into q from public.partner_lead_requests where id = p_request for update;
  if q.id is null then raise exception 'No such request.' using errcode = '22023'; end if;
  if q.status not in ('payment_check', 'needs_approval', 'open') then
    raise exception 'This request is already %.', q.status using errcode = '22023';
  end if;
  st := case when p_approve then 'open' else 'rejected' end;
  update public.partner_lead_requests
     set status = st, note = left(coalesce(p_note, ''), 300), decided_at = now(),
         decided_by = coalesce(auth.jwt() ->> 'email', ''), updated_at = now()
   where id = q.id;
  insert into public.partner_notifications (broker_id, kind, title, body, link)
  values (q.broker_id, 'lead_request',
          case when p_approve then 'Your lead request is approved' else 'Your lead request wasn''t approved' end,
          case when p_approve then 'MovEazy is picking your leads now — they''ll appear under MovEazy leads.'
               else coalesce(nullif(p_note, ''), 'Message MovEazy on WhatsApp to sort it out.') end,
          '/leads?tab=moveazy');
  return st;
end;
$$;

/**
 * Clients that could go to this request's broker: in the pool, with fewer than
 * 3 brokers, not theirs already — those fitting what they asked for first.
 */
create or replace function public.crm_lead_candidates(p_request uuid)
returns table (client_id uuid, name text, phone text, localities text[], flat_types text[], budget_min numeric,
               budget_max numeric, move_in_raw text, move_in date, brokers int, fits int, active_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  q public.partner_lead_requests;
  areas text[];
  types text[];
  bmin numeric;
  bmax numeric;
begin
  if not public.has_admin_scope('partners.manage') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  select * into q from public.partner_lead_requests where id = p_request;
  if q.id is null then raise exception 'No such request.' using errcode = '22023'; end if;
  areas := array(select lower(jsonb_array_elements_text(coalesce(q.prefs -> 'areas', '[]'))));
  types := array(select lower(jsonb_array_elements_text(coalesce(q.prefs -> 'flat_types', '[]'))));
  bmin := nullif(q.prefs ->> 'budget_min', '')::numeric;
  bmax := nullif(q.prefs ->> 'budget_max', '')::numeric;
  return query
  select p.client_id, p.name, p.phone, p.localities, p.flat_types, p.budget_min, p.budget_max, p.move_in_raw, p.move_in,
         p.brokers,
         (case when cardinality(areas) = 0 or exists (select 1 from unnest(p.localities) l where lower(l) = any (areas)) then 1 else 0 end
        + case when cardinality(types) = 0 or exists (select 1 from unnest(p.flat_types) t where lower(t) = any (types)) then 1 else 0 end
        + case when (bmin is null and bmax is null) or coalesce(p.budget_max, p.budget_min) is null
                    or (coalesce(p.budget_max, p.budget_min) >= coalesce(bmin, 0) and coalesce(p.budget_max, p.budget_min) <= coalesce(bmax, 1e9))
               then 1 else 0 end)::int,
         p.active_at
    from public.moveazy_lead_pool() p
   where p.brokers < 3
     and not exists (select 1 from public.partner_lead_assignments a where a.client_id = p.client_id and a.broker_id = q.broker_id)
   order by 11 desc, p.move_in nulls last, p.active_at desc
   limit 300;
end;
$$;

/** Give these clients to the request's broker. → how many were given. */
create or replace function public.crm_lead_assign(p_request uuid, p_clients uuid[])
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  q     public.partner_lead_requests;
  room  int;
  given int := 0;
  cid   uuid;
  who   text;
  actor text := coalesce(auth.jwt() ->> 'email', '');
begin
  if not public.has_admin_scope('partners.manage') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  select * into q from public.partner_lead_requests where id = p_request for update;
  if q.id is null then raise exception 'No such request.' using errcode = '22023'; end if;
  if q.status <> 'open' then
    raise exception 'Approve the request first (it is %).', q.status using errcode = '22023';
  end if;
  room := q.lead_count - (select count(*) from public.partner_lead_assignments a where a.request_id = q.id);
  select coalesce(nullif(b.name, ''), b.email, 'a partner broker') into who from public.broker_partners b where b.user_id = q.broker_id;
  foreach cid in array coalesce(p_clients, '{}') loop
    exit when given >= room;
    -- In the pool, under 3 brokers, not this broker's already.
    continue when not exists (select 1 from public.moveazy_lead_pool() p where p.client_id = cid and p.brokers < 3);
    continue when exists (select 1 from public.partner_lead_assignments a where a.client_id = cid and a.broker_id = q.broker_id);
    insert into public.partner_lead_assignments (request_id, client_id, broker_id, assigned_by)
    values (q.id, cid, q.broker_id, actor);
    insert into public.crm_activities (client_id, actor_email, type, body, meta)
    values (cid, actor, 'system', format('Shared with partner broker %s (%s)', who, q.pack),
            jsonb_build_object('broker_id', q.broker_id, 'request_id', q.id));
    given := given + 1;
  end loop;
  if given > 0 then
    if given >= room then
      update public.partner_lead_requests set status = 'fulfilled', updated_at = now() where id = q.id;
    end if;
    insert into public.partner_notifications (broker_id, kind, title, body, link)
    values (q.broker_id, 'leads_assigned',
            format('%s MovEazy lead%s for you', given, case when given = 1 then '' else 's' end),
            'Names and numbers are under Leads → MovEazy leads. Reach out soon — they''re fresh.',
            '/leads?tab=moveazy');
  end if;
  return given;
end;
$$;

/** For a client's CRM record: which brokers have them, and who reached out when. */
create or replace function public.crm_client_brokers(p_client uuid)
returns table (assignment_id uuid, broker_name text, broker_phone text, pack text, status text, assigned_at timestamptz,
               reach_count int, last_reach_at timestamptz, closed_rent numeric, deal_type text, due_amount numeric)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  return query
  select a.id, coalesce(b.name, ''), coalesce(b.phone, ''), q.pack, a.status, a.assigned_at,
         (select count(*)::int from public.partner_lead_reachouts x where x.assignment_id = a.id),
         (select max(x.at) from public.partner_lead_reachouts x where x.assignment_id = a.id),
         a.closed_rent, a.deal_type, a.due_amount
    from public.partner_lead_assignments a
    join public.partner_lead_requests q on q.id = a.request_id
    left join public.broker_partners b on b.user_id = a.broker_id
   where a.client_id = p_client
   order by a.assigned_at;
end;
$$;

/** Every MovEazy lead a broker closed, with what's due to MovEazy. */
create or replace function public.crm_lead_closures()
returns table (assignment_id uuid, client_id uuid, client_name text, broker_name text, broker_phone text, pack text,
               closed_rent numeric, deal_type text, due_amount numeric, closed_at timestamptz)
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
  select a.id, a.client_id, coalesce(c.name, ''), coalesce(b.name, ''), coalesce(b.phone, ''), q.pack,
         a.closed_rent, a.deal_type, a.due_amount, a.closed_at
    from public.partner_lead_assignments a
    join public.partner_lead_requests q on q.id = a.request_id
    left join public.crm_clients c on c.id = a.client_id
    left join public.broker_partners b on b.user_id = a.broker_id
   where a.status = 'closed'
   order by a.closed_at desc;
end;
$$;

/** The UPI ID brokers pay and the 30-lead pack's price — read and set on the CRM's Lead requests page. */
create or replace function public.crm_lead_settings()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.has_admin_scope('partners.manage') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  return (select jsonb_build_object('upi_id', s.lead_upi_id, 'pack_price', s.lead_pack_price)
            from public.program_settings s where s.id = 1);
end;
$$;

create or replace function public.crm_set_lead_settings(p_upi text, p_price int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.has_admin_scope('partners.manage') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  if coalesce(trim(p_upi), '') !~ '^[A-Za-z0-9._-]{2,200}@[A-Za-z0-9.-]{2,64}$' then
    raise exception 'That doesn''t look like a UPI ID (name@bank).' using errcode = '22023';
  end if;
  if p_price is null or p_price < 0 or p_price > 1000000 then
    raise exception 'Enter a price.' using errcode = '22023';
  end if;
  update public.program_settings set lead_upi_id = trim(p_upi), lead_pack_price = p_price, updated_at = now() where id = 1;
  return public.crm_lead_settings();
end;
$$;

-- Signed-in only; each function checks who is calling.
revoke all on function public.partner_moveazy_lead_stats() from public, anon;
revoke all on function public.partner_lead_request(text, jsonb, text, boolean) from public, anon;
revoke all on function public.partner_my_lead_requests() from public, anon;
revoke all on function public.partner_my_assigned_leads() from public, anon;
revoke all on function public.partner_lead_reach_out(uuid, text) from public, anon;
revoke all on function public.partner_lead_update(uuid, text, numeric, text) from public, anon;
revoke all on function public.crm_lead_requests() from public, anon;
revoke all on function public.crm_lead_request_decide(uuid, boolean, text) from public, anon;
revoke all on function public.crm_lead_candidates(uuid) from public, anon;
revoke all on function public.crm_lead_assign(uuid, uuid[]) from public, anon;
revoke all on function public.crm_client_brokers(uuid) from public, anon;
revoke all on function public.crm_lead_closures() from public, anon;
revoke all on function public.crm_lead_settings() from public, anon;
revoke all on function public.crm_set_lead_settings(text, int) from public, anon;
grant execute on function public.partner_moveazy_lead_stats(), public.partner_lead_request(text, jsonb, text, boolean),
  public.partner_my_lead_requests(), public.partner_my_assigned_leads(), public.partner_lead_reach_out(uuid, text),
  public.partner_lead_update(uuid, text, numeric, text), public.crm_lead_requests(),
  public.crm_lead_request_decide(uuid, boolean, text), public.crm_lead_candidates(uuid),
  public.crm_lead_assign(uuid, uuid[]), public.crm_client_brokers(uuid), public.crm_lead_closures(),
  public.crm_lead_settings(), public.crm_set_lead_settings(text, int)
  to authenticated;

commit;
