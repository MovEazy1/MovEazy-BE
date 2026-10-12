-- Premium by UPI, and referral rewards per plan.
--
--   · Paying: the partner picks a plan, scans MovEazy's UPI QR (the same UPI
--     ID as the ₹2,000 lead pack, program_settings.lead_upi_id) and enters the
--     UTR. The payment waits as 'payment_check' until someone with
--     partners.manage approves it in the CRM (Brokers → MovEazy partners);
--     approving starts Premium (trial days kept, partner_trial.sql).
--   · Referral rewards are per plan (partner_plans.referral_reward, editable in
--     the CRM): ₹500 / ₹1,500 / ₹3,000 for the ₹1,500 / ₹4,999 / ₹9,999 plans
--     to start. Earned on a referred partner's first paid plan, redeemable 30
--     days after the payment is approved if it isn't cancelled.
--   · The referrer hears when someone joins with their link and when the
--     reward is on its way; they leave a UPI ID or bank account for the
--     payout; the CRM lists what's due, with those details, and marks it paid.
--   · Only partners on Premium — paid or Trial — get a referral link.
--
-- Replaces partner_activate_payment (partner_trial.sql), partner_plans_list,
-- partner_referral_code and partner_my_referrals (partner_launch.sql): run
-- this after those. Safe to re-run.

begin;

create temp table _upi_first on commit drop as
  select not exists (select 1 from information_schema.columns
                      where table_schema = 'public' and table_name = 'partner_plans' and column_name = 'referral_reward') as first;

-- ── Columns ─────────────────────────────────────────────────────────────────
alter table public.partner_plans add column if not exists referral_reward int not null default 0
  check (referral_reward between 0 and 100000);
do $$
begin
  if (select first from _upi_first) then
    update public.partner_plans
       set referral_reward = case id when 'trial_1m' then 500 when 'pro_5m' then 1500 when 'pro_12m' then 3000
                                     else case when price <= 2500 then 500 when price <= 6000 then 1500 else 3000 end end;
  end if;
end $$;

alter table public.partner_payments add column if not exists utr text not null default '';
create unique index if not exists partner_payments_utr_once on public.partner_payments (upper(utr)) where utr <> '';
do $$
declare
  c text;
begin
  -- The status check gains 'payment_check' (a UTR waiting for the CRM).
  for c in select conname from pg_constraint
            where conrelid = 'public.partner_payments'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%status%'
  loop
    execute format('alter table public.partner_payments drop constraint %I', c);
  end loop;
  alter table public.partner_payments add constraint partner_payments_status_check
    check (status in ('started', 'payment_check', 'paid', 'approved', 'rejected', 'refunded'));
end $$;

alter table public.broker_partners add column if not exists payout_upi  text  not null default '';
alter table public.broker_partners add column if not exists payout_bank jsonb not null default '{}'::jsonb;

-- Notification kinds: keep what's there, add these.
do $$
declare
  kinds text[];
begin
  select array_agg(distinct m[1]) into kinds
    from pg_constraint c, regexp_matches(pg_get_constraintdef(c.oid), '''([a-z_]+)''', 'g') m
   where c.conname = 'partner_notifications_kind_check';
  if kinds is null then return; end if;
  kinds := array(select distinct k from unnest(kinds || array['referral', 'plan_approved', 'plan_rejected']) k order by 1);
  alter table public.partner_notifications drop constraint partner_notifications_kind_check;
  execute format('alter table public.partner_notifications add constraint partner_notifications_kind_check check (kind in (%s))',
                 (select string_agg(quote_literal(k), ', ') from unnest(kinds) k));
end $$;

-- ── Plans ───────────────────────────────────────────────────────────────────

/** The plans a broker can buy, cheapest first — with the referral reward each earns. */
create or replace function public.partner_plans_list()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'label', p.label, 'months', p.months, 'price', p.price,
           'per_month', round(p.price::numeric / p.months), 'refund_days', p.refund_days,
           'note', p.note, 'has_link', p.payment_link <> '', 'referral_reward', p.referral_reward) order by p.sort, p.price), '[]'::jsonb)
    from public.partner_plans p where p.active;
$$;

create or replace function public.crm_plans_list()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then raise exception 'Not allowed.' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'label', p.label, 'months', p.months, 'price', p.price,
                                                        'referral_reward', p.referral_reward, 'active', p.active) order by p.sort, p.price)
                     from public.partner_plans p), '[]'::jsonb);
end;
$$;

create or replace function public.crm_set_plan_reward(p_plan text, p_reward int)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.has_admin_scope('partners.manage') then raise exception 'Not allowed.' using errcode = '42501'; end if;
  if p_reward is null or p_reward < 0 or p_reward > 100000 then
    raise exception 'A reward between ₹0 and ₹1,00,000.' using errcode = '22023';
  end if;
  update public.partner_plans set referral_reward = p_reward, updated_at = now() where id = p_plan;
  if not found then raise exception 'No such plan.' using errcode = '22023'; end if;
end;
$$;

-- ── Paying by UPI ───────────────────────────────────────────────────────────

/** "Pay" on a plan: the payment to pay, and where. */
create or replace function public.partner_plan_pay_upi(p_plan text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  pl  public.partner_plans;
  pay public.partner_payments;
begin
  if not public.is_approved_partner() then
    raise exception 'Only approved partners can buy a plan.' using errcode = '42501';
  end if;
  if exists (select 1 from public.partner_payments where user_id = auth.uid() and status = 'payment_check') then
    raise exception 'Your last payment is being checked — we''ll let you know shortly.' using errcode = '22023';
  end if;
  select * into pl from public.partner_plans where id = p_plan and active;
  if pl.id is null then raise exception 'That plan is not available.' using errcode = '22023'; end if;
  insert into public.partner_payments (user_id, plan_id, amount, months)
  values (auth.uid(), pl.id, pl.price, pl.months) returning * into pay;
  insert into public.partner_funnel_events (user_id, phone, event, meta)
  select auth.uid(), bp.phone, 'payment_tried', jsonb_build_object('plan', pl.id, 'amount', pl.price, 'payment', pay.id, 'via', 'upi')
    from public.broker_partners bp where bp.user_id = auth.uid();
  return jsonb_build_object('id', pay.id, 'plan', pl.id, 'label', pl.label, 'amount', pl.price, 'months', pl.months,
                            'upi_id', coalesce((select s.lead_upi_id from public.program_settings s where s.id = 1), ''));
end;
$$;

/** Paid: the UTR from their UPI app. The CRM checks it. */
create or replace function public.partner_plan_submit_utr(p_payment uuid, p_utr text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_utr text := upper(regexp_replace(coalesce(p_utr, ''), '[^A-Za-z0-9]', '', 'g'));
  pay   public.partner_payments;
begin
  if v_utr !~ '^[A-Z0-9]{6,30}$' then
    raise exception 'Enter the UTR / reference number from your payment app.' using errcode = '22023';
  end if;
  select * into pay from public.partner_payments where id = p_payment and user_id = auth.uid() for update;
  if pay.id is null then raise exception 'That payment is not yours.' using errcode = '42501'; end if;
  if pay.status <> 'started' then raise exception 'This payment has already been sent.' using errcode = '22023'; end if;
  if exists (select 1 from public.partner_payments where upper(utr) = v_utr) then
    raise exception 'That UTR has already been used.' using errcode = '22023';
  end if;
  update public.partner_payments set status = 'payment_check', utr = v_utr, paid_at = now() where id = pay.id returning * into pay;
  insert into public.partner_funnel_events (user_id, phone, event, meta)
  select auth.uid(), bp.phone, 'payment_utr', jsonb_build_object('plan', pay.plan_id, 'amount', pay.amount, 'payment', pay.id)
    from public.broker_partners bp where bp.user_id = auth.uid();
  return jsonb_build_object('id', pay.id, 'status', pay.status);
end;
$$;

-- ── Premium time, and the referrer's reward (replacing partner_trial.sql's) ──

create or replace function public.partner_activate_payment(p_payment uuid, p_source text, p_gateway_payment text, p_actor text)
returns public.partner_payments
language plpgsql
security definer
set search_path = public
as $$
declare
  pay    public.partner_payments;
  start  timestamptz;
  extra  interval;
  ent    uuid;
  bp     public.broker_partners;
  ref    public.broker_partners;
  reward int;
  ref_id uuid;
begin
  select * into pay from public.partner_payments where id = p_payment for update;
  if pay.id is null then raise exception 'No such payment.' using errcode = '22023'; end if;
  if pay.status in ('paid', 'approved') then return pay; end if;

  select coalesce(max(e.ends_at), now()) into start
    from public.partner_entitlements e
   where e.user_id = pay.user_id and e.tier = 'moveazy_inventory' and e.plan <> 'trial' and e.ends_at > now();
  start := greatest(start, now());
  extra := public.partner_trial_convert(pay.user_id);

  insert into public.partner_entitlements (user_id, tier, plan, starts_at, ends_at, source, source_ref, granted_by)
  values (pay.user_id, 'moveazy_inventory', pay.plan_id, start, start + make_interval(months => pay.months) + extra,
          p_source, pay.id::text, left(coalesce(p_actor, ''), 120))
  returning id into ent;

  update public.partner_payments
     set status = case when p_source = 'razorpay' then 'paid' else 'approved' end,
         paid_at = coalesce(paid_at, now()),
         decided_at = case when p_source = 'razorpay' then decided_at else now() end,
         decided_by = case when p_source = 'razorpay' then decided_by else left(coalesce(p_actor, ''), 120) end,
         gateway_payment_id = coalesce(nullif(p_gateway_payment, ''), gateway_payment_id),
         entitlement_id = ent
   where id = pay.id
   returning * into pay;

  select * into bp from public.broker_partners where user_id = pay.user_id;
  if p_source = 'razorpay' then
    insert into public.partner_funnel_events (user_id, phone, event, meta)
    values (pay.user_id, coalesce(bp.phone, ''), 'payment_paid', jsonb_build_object('plan', pay.plan_id, 'amount', pay.amount, 'payment', pay.id));
  end if;
  insert into public.partner_funnel_events (user_id, phone, event, meta)
  values (pay.user_id, coalesce(bp.phone, ''), 'plan_approved',
          jsonb_build_object('plan', pay.plan_id, 'amount', pay.amount, 'payment', pay.id, 'by', case when p_source = 'razorpay' then 'razorpay' else p_actor end));

  -- A referred broker's first paid plan earns their referrer that plan's reward, 30 days on.
  if coalesce(bp.referred_by, '') <> '' then
    select * into ref from public.broker_partners where referral_code = bp.referred_by;
    select referral_reward into reward from public.partner_plans where id = pay.plan_id;
    if ref.user_id is not null and ref.user_id <> pay.user_id and coalesce(reward, 0) > 0 then
      insert into public.partner_referrals (referrer_id, referee_id, payment_id, plan_id, amount, earn_after)
      values (ref.user_id, pay.user_id, pay.id, pay.plan_id, reward, now() + interval '30 days')
      on conflict (referee_id) do nothing
      returning id into ref_id;
      if ref_id is not null then
        insert into public.partner_notifications (broker_id, kind, title, body, link)
        values (ref.user_id, 'referral', '₹' || to_char(reward, 'FM99,99,999') || ' on the way',
                coalesce(nullif(bp.name, ''), 'A broker you referred') || ' took Premium. Redeemable in 30 days if they keep it.',
                '/referrals');
      end if;
    end if;
  end if;
  return pay;
end;
$$;

-- ── The CRM: check UTRs ─────────────────────────────────────────────────────

create or replace function public.crm_premium_payments()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.has_admin_scope('partners.manage') then raise exception 'Not allowed.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'todo', coalesce((
      select jsonb_agg(x order by x ->> 'paid_at') from (
        select jsonb_build_object('id', p.id, 'user_id', p.user_id, 'name', bp.name, 'phone', bp.phone, 'email', bp.email, 'agency', bp.agency,
                 'plan', pl.label, 'months', p.months, 'amount', p.amount, 'utr', p.utr, 'paid_at', p.paid_at,
                 'referred_by', (select r.name from public.broker_partners r where r.referral_code = nullif(bp.referred_by, '')),
                 'on_trial', exists (select 1 from public.partner_trials t where t.user_id = p.user_id and t.converted_at is null and t.ends_at > now())) x
          from public.partner_payments p
          join public.partner_plans pl on pl.id = p.plan_id
          left join public.broker_partners bp on bp.user_id = p.user_id
         where p.status = 'payment_check') q), '[]'::jsonb),
    'done', coalesce((
      select jsonb_agg(x order by x ->> 'decided_at' desc) from (
        select jsonb_build_object('id', p.id, 'name', bp.name, 'plan', pl.label, 'amount', p.amount, 'utr', p.utr,
                 'status', p.status, 'decided_at', p.decided_at, 'decided_by', p.decided_by, 'note', p.note) x
          from public.partner_payments p
          join public.partner_plans pl on pl.id = p.plan_id
          left join public.broker_partners bp on bp.user_id = p.user_id
         where p.utr <> '' and p.status in ('approved', 'rejected', 'refunded')
         order by p.decided_at desc nulls last limit 40) q), '[]'::jsonb)
  );
end;
$$;

/** Approve (Premium starts) or reject a UTR. */
create or replace function public.crm_premium_payment_decide(p_payment uuid, p_approve boolean, p_note text default '')
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  pay   public.partner_payments;
  actor text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if not public.has_admin_scope('partners.manage') then raise exception 'Not allowed.' using errcode = '42501'; end if;
  select * into pay from public.partner_payments where id = p_payment for update;
  if pay.id is null then raise exception 'No such payment.' using errcode = '22023'; end if;
  if pay.status <> 'payment_check' then raise exception 'Already decided.' using errcode = '22023'; end if;
  if p_approve then
    pay := public.partner_activate_payment(pay.id, 'upi', pay.utr, actor);
    if coalesce(p_note, '') <> '' then update public.partner_payments set note = left(p_note, 500) where id = pay.id; end if;
    insert into public.partner_notifications (broker_id, kind, title, body, link)
    values (pay.user_id, 'plan_approved', 'Premium is on',
            'Payment of ₹' || to_char(pay.amount, 'FM99,99,999') || ' received. Every Premium feature is yours.', '/premium');
    return 'approved';
  end if;
  update public.partner_payments
     set status = 'rejected', decided_at = now(), decided_by = actor, note = left(coalesce(nullif(p_note, ''), note), 500)
   where id = pay.id;
  insert into public.partner_notifications (broker_id, kind, title, body, link)
  values (pay.user_id, 'plan_rejected', 'We couldn''t find your payment',
          'UTR ' || pay.utr || coalesce(' — ' || nullif(p_note, ''), '') || '. Message MovEazy on WhatsApp and we''ll sort it out.', '/premium');
  insert into public.partner_funnel_events (user_id, event, meta)
  values (pay.user_id, 'plan_rejected', jsonb_build_object('plan', pay.plan_id, 'payment', pay.id, 'by', actor));
  return 'rejected';
end;
$$;

-- ── Referrals ───────────────────────────────────────────────────────────────

/** The caller's referral code — made on first ask, for partners on Premium (paid or Trial). */
create or replace function public.partner_referral_code()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  c text;
  i int;
begin
  if not public.is_approved_partner() then
    raise exception 'Only approved partners can refer.' using errcode = '42501';
  end if;
  select referral_code into c from public.broker_partners where user_id = auth.uid();
  if c is not null then return c; end if;
  if not public.partner_has_tier('moveazy_inventory') then
    raise exception 'Refer & Earn comes with Premium.' using errcode = '42501';
  end if;
  for i in 1..25 loop
    select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '')
      into c from generate_series(1, 6);
    begin
      update public.broker_partners set referral_code = c where user_id = auth.uid() and referral_code is null;
      exit;
    exception when unique_violation then
      c := null;
    end;
  end loop;
  select referral_code into c from public.broker_partners where user_id = auth.uid();
  return c;
end;
$$;

/** Who joined with my code, what each earns and when, the rewards per plan, and where I'm paid. */
create or replace function public.partner_my_referrals()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  code text := public.partner_referral_code();
  me   public.broker_partners;
begin
  perform public.partner_referrals_settle();
  select * into me from public.broker_partners where user_id = auth.uid();
  return jsonb_build_object(
    'code', code,
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
               'paid_at', r.paid_at) order by bp.created_at desc)
        from public.broker_partners bp
        left join public.partner_referrals r on r.referee_id = bp.user_id and r.referrer_id = auth.uid()
       where bp.referred_by = code and bp.user_id <> auth.uid()), '[]'::jsonb),
    'pending', coalesce((select sum(amount) from public.partner_referrals where referrer_id = auth.uid() and status = 'pending'), 0),
    'earned', coalesce((select sum(amount) from public.partner_referrals where referrer_id = auth.uid() and status = 'earned'), 0),
    'paid', coalesce((select sum(amount) from public.partner_referrals where referrer_id = auth.uid() and status = 'paid'), 0),
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

/** Where the referral money goes: a UPI ID, or a bank account. */
create or replace function public.partner_set_payout(p_upi text, p_name text default '', p_account text default '', p_ifsc text default '')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  upi  text := lower(btrim(coalesce(p_upi, '')));
  acct text := regexp_replace(coalesce(p_account, ''), '\s', '', 'g');
  ifsc text := upper(btrim(coalesce(p_ifsc, '')));
  nm   text := left(btrim(coalesce(p_name, '')), 80);
begin
  if not public.is_approved_partner() then raise exception 'Only approved partners.' using errcode = '42501'; end if;
  if upi = '' and acct = '' then raise exception 'Add a UPI ID or a bank account.' using errcode = '22023'; end if;
  if upi <> '' and upi !~ '^[a-z0-9._-]{2,200}@[a-z0-9.-]{2,64}$' then
    raise exception 'That UPI ID doesn''t look right.' using errcode = '22023';
  end if;
  if acct <> '' then
    if acct !~ '^[0-9]{6,18}$' then raise exception 'Account number: 6 to 18 digits.' using errcode = '22023'; end if;
    if ifsc !~ '^[A-Z]{4}0[A-Z0-9]{6}$' then raise exception 'That IFSC doesn''t look right (e.g. HDFC0001234).' using errcode = '22023'; end if;
    if nm = '' then raise exception 'Add the account holder''s name.' using errcode = '22023'; end if;
  end if;
  update public.broker_partners
     set payout_upi = upi,
         payout_bank = case when acct = '' then '{}'::jsonb else jsonb_build_object('name', nm, 'account', acct, 'ifsc', ifsc) end,
         updated_at = now()
   where user_id = auth.uid();
end;
$$;

/** The CRM: referral rewards on the way and due, with where to send them. */
create or replace function public.crm_referral_payouts()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.has_admin_scope('partners.manage') then raise exception 'Not allowed.' using errcode = '42501'; end if;
  perform public.partner_referrals_settle();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', r.id, 'status', r.status, 'amount', r.amount, 'earn_after', r.earn_after, 'paid_at', r.paid_at, 'paid_by', r.paid_by,
             'plan', (select pl.label from public.partner_plans pl where pl.id = r.plan_id),
             'referrer', a.name, 'referrer_phone', a.phone, 'referee', b.name,
             'upi', a.payout_upi, 'bank', a.payout_bank)
           order by case r.status when 'earned' then 0 when 'pending' then 1 else 2 end, r.earn_after)
      from public.partner_referrals r
      left join public.broker_partners a on a.user_id = r.referrer_id
      left join public.broker_partners b on b.user_id = r.referee_id
     where r.status in ('pending', 'earned') or r.paid_at > now() - interval '60 days'), '[]'::jsonb);
end;
$$;

create or replace function public.crm_referral_mark_paid(p_referral uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.partner_referrals;
begin
  if not public.has_admin_scope('partners.manage') then raise exception 'Not allowed.' using errcode = '42501'; end if;
  perform public.partner_referrals_settle();
  update public.partner_referrals
     set status = 'paid', paid_at = now(), paid_by = lower(coalesce(auth.jwt() ->> 'email', ''))
   where id = p_referral and status = 'earned'
  returning * into r;
  if r.id is null then raise exception 'Only a reward past its 30 days can be marked paid.' using errcode = '22023'; end if;
  insert into public.partner_notifications (broker_id, kind, title, body, link)
  values (r.referrer_id, 'referral', '₹' || to_char(r.amount, 'FM99,99,999') || ' sent to you',
          'Your referral reward has been paid out. Thank you for bringing brokers to MovEazy.', '/referrals');
end;
$$;

-- Someone joined with a referral link: their referrer hears it.
create or replace function public.partner_referral_joined()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  ref public.broker_partners;
  top int;
begin
  if coalesce(new.referred_by, '') = '' or (tg_op = 'UPDATE' and old.referred_by is not distinct from new.referred_by) then
    return new;
  end if;
  select * into ref from public.broker_partners where referral_code = new.referred_by and user_id <> new.user_id;
  if ref.user_id is null then return new; end if;
  select max(referral_reward) into top from public.partner_plans where active;
  insert into public.partner_notifications (broker_id, kind, title, body, link)
  values (ref.user_id, 'referral', coalesce(nullif(new.name, ''), 'A broker') || ' joined with your link',
          'When they take a Premium plan you earn' || case when coalesce(top, 0) > 0 then ' up to ₹' || to_char(top, 'FM99,99,999') else ' a reward' end || '.',
          '/referrals');
  return new;
exception when others then
  raise warning 'partner_referral_joined(%): %', new.user_id, sqlerrm;
  return new;
end;
$$;
drop trigger if exists broker_partners_referral_joined on public.broker_partners;
create trigger broker_partners_referral_joined after insert or update of referred_by on public.broker_partners
  for each row execute function public.partner_referral_joined();

-- ── Grants ──────────────────────────────────────────────────────────────────
revoke all on function public.partner_referral_joined() from public, anon, authenticated;
revoke all on function public.partner_activate_payment(uuid, text, text, text) from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array[
    'public.partner_plans_list()', 'public.crm_plans_list()', 'public.crm_set_plan_reward(text, int)',
    'public.partner_plan_pay_upi(text)', 'public.partner_plan_submit_utr(uuid, text)',
    'public.crm_premium_payments()', 'public.crm_premium_payment_decide(uuid, boolean, text)',
    'public.partner_referral_code()', 'public.partner_my_referrals()', 'public.partner_set_payout(text, text, text, text)',
    'public.crm_referral_payouts()', 'public.crm_referral_mark_paid(uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

commit;
