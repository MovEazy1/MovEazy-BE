-- Lifetime referral commission, and the partner's Wallet.
--
--   · A partner who brings another partner in (broker_partners.referred_by =
--     their referral code) earns on every MovEazy lead that partner closes,
--     for as long as both are on MovEazy. It comes out of MovEazy's share —
--     the closing partner keeps their full brokerage.
--   · The rate is a % of the month's rent: by default a third of MovEazy's
--     share, at most 10% — 10% on a direct deal (MovEazy 30%), 6.67% on a
--     shared one (MovEazy 20%). The CRM can set a referrer's own rates
--     (broker_partners.referral_direct_pct / referral_shared_pct); never more
--     than MovEazy's share on that deal.
--   · Only deals that owe MovEazy a share count (a Premium lead), closed while
--     the closing partner was on Premium — paid or Trial.
--   · It's earned when MovEazy has its share: the CRM marks the closure
--     "received" (partner_lead_assignments.due_received_at). Then:
--       referrer on Premium (paid or Trial) → due, paid out like referral
--       rewards; not on Premium → held 30 days — going Premium in that time
--       makes it due, otherwise it's lost.
--   · partner_my_referrals() (the Wallet) also returns the lifetime rates,
--     every commission, and how each referred partner is doing: plan, leads
--     they're working, deals closed and what each earned the referrer. Never
--     a client's name or number. A partner without Premium still gets their
--     Wallet (code null, can_refer false) instead of an error.
--
-- Replaces partner_my_referrals (partner_premium_upi.sql), crm_lead_closures
-- (partner_moveazy_leads.sql) and partner_admin_list (partner_trial.sql): run
-- this after those. Safe to re-run.

begin;

-- ── Columns and table ───────────────────────────────────────────────────────
alter table public.broker_partners
  add column if not exists referral_direct_pct numeric check (referral_direct_pct between 0 and 30),
  add column if not exists referral_shared_pct numeric check (referral_shared_pct between 0 and 20);
alter table public.partner_lead_assignments
  add column if not exists due_received_at timestamptz,
  add column if not exists due_received_by text not null default '';

create table if not exists public.partner_referral_commissions (
  id            uuid primary key default gen_random_uuid(),
  assignment_id uuid not null unique references public.partner_lead_assignments (id) on delete cascade,
  referrer_id   uuid not null references auth.users (id) on delete cascade,
  referee_id    uuid not null references auth.users (id) on delete cascade,
  rent          numeric not null,
  deal_type     text not null,
  rate_pct      numeric not null,
  amount        int not null check (amount >= 0),
  -- held: the referrer wasn't on Premium; due until hold_until if they go Premium, else lost.
  status        text not null default 'due' check (status in ('held', 'due', 'paid', 'lost')),
  hold_until    timestamptz,
  created_at    timestamptz not null default now(),
  paid_at       timestamptz,
  paid_by       text not null default ''
);
create index if not exists partner_referral_commissions_referrer_idx on public.partner_referral_commissions (referrer_id, created_at desc);
alter table public.partner_referral_commissions enable row level security;
revoke all on public.partner_referral_commissions from anon, authenticated;

-- ── Helpers (internal) ──────────────────────────────────────────────────────

/** On Premium — paid or Trial — at that moment (or Premium is free for everyone). */
create or replace function public.partner_premium_at(p_user uuid, p_at timestamptz default now())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.partner_tiers t where t.tier = 'moveazy_inventory' and t.is_free)
      or exists (select 1 from public.partner_entitlements e
                  where e.user_id = p_user and e.tier = 'moveazy_inventory'
                    and coalesce(p_at, now()) >= e.starts_at and coalesce(p_at, now()) < e.ends_at);
$$;

/** Who brought this partner in (an approved partner, never themselves). */
create or replace function public.partner_referrer_of(p_user uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select r.user_id
    from public.broker_partners b
    join public.broker_partners r on r.referral_code = nullif(b.referred_by, '') and r.user_id <> b.user_id
   where b.user_id = p_user and r.status = 'approved'
   limit 1;
$$;

/** A referrer's rate, % of rent: their own if the CRM set one, else a third of MovEazy's share, at most 10%. */
create or replace function public.partner_referral_rate(p_referrer uuid, p_deal text)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
           case when p_deal = 'direct' then b.referral_direct_pct else b.referral_shared_pct end,
           round(least(10, (case when p_deal = 'direct' then 30 else 20 end) / 3.0), 2))
    from (select 1) one
    left join public.broker_partners b on b.user_id = p_referrer;
$$;

/** Held commissions: due once the referrer is on Premium, lost after their 30 days. */
create or replace function public.partner_referral_commissions_settle()
returns void
language sql
security definer
set search_path = public
as $$
  update public.partner_referral_commissions c set status = 'due'
   where c.status = 'held' and c.hold_until > now() and public.partner_premium_at(c.referrer_id, now());
  update public.partner_referral_commissions c set status = 'lost'
   where c.status = 'held' and c.hold_until <= now();
$$;

-- ── CRM: MovEazy has its share ─────────────────────────────────────────────

/**
 * MovEazy received its share of a closed lead (or undo, while no commission
 * on it has been paid). The closing partner's referrer earns their commission.
 * → { received, commission: { amount, status, referrer } | null }
 */
create or replace function public.crm_lead_closure_received(p_assignment uuid, p_undo boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a     public.partner_lead_assignments;
  ref   uuid;
  rate  numeric;
  amt   int;
  st    text;
  who   text;
  c     public.partner_referral_commissions;
begin
  if not public.has_admin_scope('partners.manage') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  select * into a from public.partner_lead_assignments where id = p_assignment for update;
  if a.id is null or a.status <> 'closed' then
    raise exception 'That lead hasn''t closed.' using errcode = '22023';
  end if;

  if p_undo then
    if exists (select 1 from public.partner_referral_commissions where assignment_id = a.id and status = 'paid') then
      raise exception 'The referral commission on this deal is already paid out.' using errcode = '22023';
    end if;
    delete from public.partner_referral_commissions where assignment_id = a.id;
    update public.partner_lead_assignments set due_received_at = null, due_received_by = '', updated_at = now() where id = a.id;
    return jsonb_build_object('received', false, 'commission', null);
  end if;
  if coalesce(a.due_amount, 0) <= 0 then
    raise exception 'Nothing is due to MovEazy on this deal.' using errcode = '22023';
  end if;

  update public.partner_lead_assignments
     set due_received_at = coalesce(due_received_at, now()),
         due_received_by = case when due_received_at is null then lower(coalesce(auth.jwt() ->> 'email', '')) else due_received_by end,
         updated_at = now()
   where id = a.id;

  select * into c from public.partner_referral_commissions where assignment_id = a.id;
  if c.id is null then
    ref := public.partner_referrer_of(a.broker_id);
    if ref is not null and public.partner_premium_at(a.broker_id, coalesce(a.closed_at, now())) then
      rate := public.partner_referral_rate(ref, a.deal_type);
      amt := least(a.due_amount, round(a.closed_rent * rate / 100))::int;
      if amt > 0 then
        st := case when public.partner_premium_at(ref, now()) then 'due' else 'held' end;
        insert into public.partner_referral_commissions
          (assignment_id, referrer_id, referee_id, rent, deal_type, rate_pct, amount, status, hold_until)
        values (a.id, ref, a.broker_id, a.closed_rent, a.deal_type, rate, amt, st,
                case when st = 'held' then now() + interval '30 days' end)
        returning * into c;
        select coalesce(nullif(b.name, ''), 'A partner you referred') into who from public.broker_partners b where b.user_id = a.broker_id;
        insert into public.partner_notifications (broker_id, kind, title, body, link)
        values (ref, 'referral',
                case when st = 'due' then '₹' || to_char(amt, 'FM99,99,999') || ' earned — lifetime commission'
                     else '₹' || to_char(amt, 'FM99,99,999') || ' waiting for you' end,
                case when st = 'due' then who || ' closed a deal. Your commission is in your Wallet.'
                     else who || ' closed a deal. Go Premium within 30 days to claim it.' end,
                '/referrals');
      end if;
    end if;
  end if;

  return jsonb_build_object('received', true, 'commission', case when c.id is null then null else jsonb_build_object(
    'amount', c.amount, 'status', c.status,
    'referrer', (select coalesce(nullif(b.name, ''), 'Referrer') from public.broker_partners b where b.user_id = c.referrer_id)) end);
end;
$$;

/** Closed MovEazy leads: what's due, whether MovEazy has it, and who earns a commission on it. */
drop function if exists public.crm_lead_closures();
create function public.crm_lead_closures()
returns table (assignment_id uuid, client_id uuid, client_name text, broker_name text, broker_phone text, pack text,
               closed_rent numeric, deal_type text, due_amount numeric, closed_at timestamptz,
               received_at timestamptz, received_by text, referrer_name text, commission int, commission_status text)
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
         a.closed_rent, a.deal_type, a.due_amount, a.closed_at,
         a.due_received_at, a.due_received_by,
         coalesce(rb.name, (select coalesce(nullif(x.name, ''), 'Referrer') from public.broker_partners x
                              where x.user_id = public.partner_referrer_of(a.broker_id))),
         rc.amount, rc.status
    from public.partner_lead_assignments a
    join public.partner_lead_requests q on q.id = a.request_id
    left join public.crm_clients c on c.id = a.client_id
    left join public.broker_partners b on b.user_id = a.broker_id
    left join public.partner_referral_commissions rc on rc.assignment_id = a.id
    left join public.broker_partners rb on rb.user_id = rc.referrer_id
   where a.status = 'closed'
   order by a.closed_at desc;
end;
$$;

/** Commissions to pay (and recently paid), with where to send them. */
create or replace function public.crm_referral_commissions()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.has_admin_scope('partners.manage') then raise exception 'Not allowed.' using errcode = '42501'; end if;
  perform public.partner_referral_commissions_settle();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', c.id, 'status', c.status, 'amount', c.amount, 'rent', c.rent, 'deal_type', c.deal_type, 'rate_pct', c.rate_pct,
             'hold_until', c.hold_until, 'created_at', c.created_at, 'paid_at', c.paid_at, 'paid_by', c.paid_by,
             'referrer', a.name, 'referrer_phone', a.phone, 'referee', b.name,
             'upi', a.payout_upi, 'bank', a.payout_bank)
           order by case c.status when 'due' then 0 when 'held' then 1 else 2 end, c.created_at)
      from public.partner_referral_commissions c
      left join public.broker_partners a on a.user_id = c.referrer_id
      left join public.broker_partners b on b.user_id = c.referee_id
     where c.status in ('held', 'due') or c.paid_at > now() - interval '60 days'), '[]'::jsonb);
end;
$$;

create or replace function public.crm_referral_commission_paid(p_commission uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.partner_referral_commissions;
begin
  if not public.has_admin_scope('partners.manage') then raise exception 'Not allowed.' using errcode = '42501'; end if;
  perform public.partner_referral_commissions_settle();
  update public.partner_referral_commissions
     set status = 'paid', paid_at = now(), paid_by = lower(coalesce(auth.jwt() ->> 'email', ''))
   where id = p_commission and status = 'due'
  returning * into c;
  if c.id is null then raise exception 'Only a commission that''s due can be marked paid.' using errcode = '22023'; end if;
  insert into public.partner_notifications (broker_id, kind, title, body, link)
  values (c.referrer_id, 'referral', '₹' || to_char(c.amount, 'FM99,99,999') || ' sent to you',
          'Your lifetime commission has been paid out. Keep bringing partners to MovEazy.', '/referrals');
end;
$$;

/** A referrer's own rates, % of rent (null = the default: a third of MovEazy's share, at most 10%). */
create or replace function public.partner_admin_set_referral_rate(p_user uuid, p_direct numeric, p_shared numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.has_admin_scope('partners.manage') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  if p_direct is not null and (p_direct < 0 or p_direct > 30) then
    raise exception 'A direct-deal commission is between 0 and 30%% of the rent (MovEazy''s share).' using errcode = '22023';
  end if;
  if p_shared is not null and (p_shared < 0 or p_shared > 20) then
    raise exception 'A shared-deal commission is between 0 and 20%% of the rent (MovEazy''s share).' using errcode = '22023';
  end if;
  update public.broker_partners set referral_direct_pct = p_direct, referral_shared_pct = p_shared, updated_at = now()
   where user_id = p_user;
end;
$$;

/** The CRM's partner list, now with each partner's referral rates (null = default). */
drop function if exists public.partner_admin_list();
create function public.partner_admin_list()
returns table (user_id uuid, name text, phone text, email text, agency text, status text,
               created_at timestamptz, approved_at timestamptz, approved_by text,
               listing_count int, group_count int, premium_until timestamptz, client_share_pct numeric,
               trial_until timestamptz, referral_direct_pct numeric, referral_shared_pct numeric, referred_count int)
language sql
stable
security definer
set search_path = public
as $$
  select p.user_id, p.name, p.phone, p.email, p.agency, p.status, p.created_at, p.approved_at, p.approved_by,
         (select count(*)::int from public.partner_listings l where l.broker_id = p.user_id),
         (select count(*)::int from public.partner_group_members m where m.user_id = p.user_id),
         (select max(e.ends_at) from public.partner_entitlements e
           where e.user_id = p.user_id and e.tier = 'moveazy_inventory' and e.plan <> 'trial' and now() < e.ends_at),
         p.client_share_pct,
         (select max(e.ends_at) from public.partner_entitlements e
           where e.user_id = p.user_id and e.tier = 'moveazy_inventory' and e.plan = 'trial' and now() < e.ends_at),
         p.referral_direct_pct, p.referral_shared_pct,
         (select count(*)::int from public.broker_partners x
           where p.referral_code is not null and x.referred_by = p.referral_code and x.user_id <> p.user_id)
    from public.broker_partners p
   where public.is_crm_staff()
   order by case p.status when 'pending' then 0 when 'approved' then 1 else 2 end, p.created_at desc;
$$;

-- ── The partner's Wallet ────────────────────────────────────────────────────

/**
 * Who joined with my code and how each is doing, the one-time rewards and the
 * lifetime commission, totals, rates, and where I'm paid.
 */
create or replace function public.partner_my_referrals()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  code   text;
  me     public.broker_partners;
  uid    uuid := auth.uid();
  direct numeric;
  shared numeric;
begin
  if not public.is_approved_partner() then
    raise exception 'Only approved partners.' using errcode = '42501';
  end if;
  begin
    code := public.partner_referral_code();
  exception when others then
    code := null; -- no Premium yet: the Wallet still opens
  end;
  perform public.partner_referrals_settle();
  perform public.partner_referral_commissions_settle();
  select * into me from public.broker_partners where user_id = uid;
  direct := public.partner_referral_rate(uid, 'direct');
  shared := public.partner_referral_rate(uid, 'shared');
  return jsonb_build_object(
    'code', code,
    'can_refer', code is not null,
    'premium', public.partner_premium_at(uid, now()),
    'rates', jsonb_build_object('direct', direct, 'shared', shared),
    'joined', coalesce((
      select jsonb_agg(jsonb_build_object(
               'name', coalesce(nullif(bp.name, ''), 'A broker'),
               'joined_at', bp.created_at,
               'plan', r.plan_id,
               'plan_label', (select pl.label from public.partner_plans pl where pl.id = r.plan_id),
               'status', coalesce(r.status, 'signed_up'),
               'amount', coalesce(r.amount, 0),
               'earn_after', r.earn_after,
               'days_left', case when r.status = 'pending' then greatest(0, ceil(extract(epoch from (r.earn_after - now())) / 86400))::int end,
               'paid_at', r.paid_at,
               'phone', coalesce(bp.phone, ''),
               'premium_until', (select max(e.ends_at) from public.partner_entitlements e
                                  where e.user_id = bp.user_id and e.tier = 'moveazy_inventory' and e.plan <> 'trial' and now() < e.ends_at),
               'trial_until', (select max(e.ends_at) from public.partner_entitlements e
                                where e.user_id = bp.user_id and e.tier = 'moveazy_inventory' and e.plan = 'trial' and now() < e.ends_at),
               'working', (select count(*)::int from public.partner_lead_assignments a
                            where a.broker_id = bp.user_id and a.status in ('assigned', 'contacted', 'visit')),
               'deals', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'rent', a.closed_rent, 'deal_type', a.deal_type, 'closed_at', a.closed_at,
                          'amount', coalesce(rc.amount, case when rc.id is null and a.due_received_at is null and a.due_amount > 0
                                                               and public.partner_premium_at(bp.user_id, coalesce(a.closed_at, now()))
                                                             then least(a.due_amount, round(a.closed_rent * case when a.deal_type = 'direct' then direct else shared end / 100))::int end, 0),
                          'status', coalesce(rc.status,
                                      case when a.due_amount > 0 and a.due_received_at is null
                                                and public.partner_premium_at(bp.user_id, coalesce(a.closed_at, now())) then 'waiting'
                                           else 'none' end),
                          'hold_until', rc.hold_until, 'paid_at', rc.paid_at)
                          order by a.closed_at desc)
                   from public.partner_lead_assignments a
                   left join public.partner_referral_commissions rc on rc.assignment_id = a.id and rc.referrer_id = uid
                  where a.broker_id = bp.user_id and a.status = 'closed'), '[]'::jsonb))
             order by bp.created_at desc)
        from public.broker_partners bp
        left join public.partner_referrals r on r.referee_id = bp.user_id and r.referrer_id = uid
       where me.referral_code is not null and bp.referred_by = me.referral_code and bp.user_id <> uid), '[]'::jsonb),
    -- one-time Premium rewards
    'pending', coalesce((select sum(amount) from public.partner_referrals where referrer_id = uid and status = 'pending'), 0),
    'earned', coalesce((select sum(amount) from public.partner_referrals where referrer_id = uid and status = 'earned'), 0),
    'paid', coalesce((select sum(amount) from public.partner_referrals where referrer_id = uid and status = 'paid'), 0),
    -- lifetime commission
    'commission', jsonb_build_object(
      'due', coalesce((select sum(amount) from public.partner_referral_commissions where referrer_id = uid and status = 'due'), 0),
      'held', coalesce((select sum(amount) from public.partner_referral_commissions where referrer_id = uid and status = 'held'), 0),
      'held_until', (select min(hold_until) from public.partner_referral_commissions where referrer_id = uid and status = 'held'),
      'paid', coalesce((select sum(amount) from public.partner_referral_commissions where referrer_id = uid and status = 'paid'), 0),
      'lost', coalesce((select sum(amount) from public.partner_referral_commissions where referrer_id = uid and status = 'lost'), 0)),
    'rewards', coalesce((select jsonb_agg(jsonb_build_object('label', pl.label, 'price', pl.price, 'months', pl.months, 'reward', pl.referral_reward)
                                          order by pl.sort, pl.price)
                           from public.partner_plans pl where pl.active and pl.referral_reward > 0), '[]'::jsonb),
    'payout', jsonb_build_object(
      'upi', coalesce(me.payout_upi, ''),
      'bank_name', coalesce(me.payout_bank ->> 'name', ''),
      'bank_last4', right(coalesce(me.payout_bank ->> 'account', ''), 4),
      'ifsc', coalesce(me.payout_bank ->> 'ifsc', ''))
  );
end;
$$;

-- ── Grants ──────────────────────────────────────────────────────────────────
do $$
declare f text;
begin
  foreach f in array array[
    'public.partner_premium_at(uuid, timestamptz)', 'public.partner_referrer_of(uuid)',
    'public.partner_referral_rate(uuid, text)', 'public.partner_referral_commissions_settle()'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
  foreach f in array array[
    'public.crm_lead_closure_received(uuid, boolean)', 'public.crm_lead_closures()', 'public.crm_referral_commissions()',
    'public.crm_referral_commission_paid(uuid)', 'public.partner_admin_set_referral_rate(uuid, numeric, numeric)',
    'public.partner_admin_list()', 'public.partner_my_referrals()'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

commit;
