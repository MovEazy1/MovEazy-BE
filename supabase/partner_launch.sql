-- ─────────────────────────────────────────────────────────────────────────────
-- MovEazy Partners — launch (fe/docs/PARTNERS_LAUNCH_PRD.md).
--
-- Run in the Supabase SQL editor AFTER partner_schema.sql and
-- partner_storefront.sql. Safe to re-run; grows section by section as the
-- launch ships.
--
-- § 1  Sign-up funnel: the number a visitor gives before Google (so an
--      abandoned sign-up still counts as "number filled"), where they came
--      from (channel, referral code, UTM), and one event row per funnel step.
-- § 2  Tenant (lead) capture: only the mobile required; bachelor / family;
--      male / female / co-ed.
-- § 3  Plans (CRM-editable) and payments: Razorpay links, the webhook's
--      activation, the super admin's approve / reject.
-- § 4  Referrals: a code per partner; ₹1,500 per referred broker's first
--      plan, earned after a month, paid out by hand.
-- § 5  Complete profile: operational areas and RERA ID.
-- § 6  partner_status(): plan, payment, profile, congratulations due.
-- § 7  partner_funnel(): the sales funnel for CRM staff.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

-- ── § 1 Sign-up funnel ───────────────────────────────────────────────────────

-- Where a partner came from. Set once, at sign-up; never overwritten.
alter table public.broker_partners add column if not exists signup_channel text not null default '';
alter table public.broker_partners add column if not exists referred_by    text not null default '';
alter table public.broker_partners add column if not exists utm            jsonb not null default '{}'::jsonb;

-- A number typed into "Become Partner", before any account exists. Keyed by
-- the number: typing it again only refreshes it. user_id is filled in when that
-- number signs up, which is how the funnel tells "gave a number, never signed
-- in" from "signed up".
create table if not exists public.partner_prospects (
  phone      text primary key check (phone ~ '^[6-9][0-9]{9}$'),
  channel    text not null default '',
  referred_by text not null default '',
  utm        jsonb not null default '{}'::jsonb,
  user_id    uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.partner_funnel_events (
  id      bigint generated always as identity primary key,
  user_id uuid references auth.users (id) on delete cascade,
  phone   text not null default '',
  event   text not null check (event in ('number_filled', 'signed_up', 'payment_tried', 'payment_paid',
                                         'plan_approved', 'plan_rejected', 'profile_completed')),
  meta    jsonb not null default '{}'::jsonb,
  at      timestamptz not null default now()
);
create index if not exists partner_funnel_events_at_idx on public.partner_funnel_events (event, at desc);
create index if not exists partner_funnel_events_user_idx on public.partner_funnel_events (user_id, at desc);
-- One-time steps happen once per account.
create unique index if not exists partner_funnel_events_once
  on public.partner_funnel_events (user_id, event)
  where event in ('signed_up', 'profile_completed') and user_id is not null;

/** Clean text for a channel / code / UTM value: short, printable. */
create or replace function public.partner_clean_tag(v text, n int default 60)
returns text
language sql
immutable
as $$ select left(regexp_replace(trim(coalesce(v, '')), '[^A-Za-z0-9 _.:/-]', '', 'g'), n) $$;

create or replace function public.partner_clean_utm(p jsonb)
returns jsonb
language sql
immutable
as $$
  select coalesce(jsonb_object_agg(k, public.partner_clean_tag(p ->> k, 100)), '{}'::jsonb)
    from unnest(array['utm_source', 'utm_medium', 'utm_campaign', 'utm_content', 'utm_term']) k
   where jsonb_typeof(coalesce(p, '{}'::jsonb)) = 'object' and coalesce(p ->> k, '') <> '';
$$;

/**
 * "Become Partner", step one: a signed-out visitor's number, before Google.
 * Anyone may call it; it only ever records a well-formed mobile number.
 */
create or replace function public.partner_prospect(p_phone text, p_channel text default '', p_ref text default '', p_utm jsonb default '{}')
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  ph text := public.normalize_mobile(p_phone);
begin
  if ph = '' then
    raise exception 'Enter a valid 10-digit mobile number.' using errcode = '22023';
  end if;
  insert into public.partner_prospects as p (phone, channel, referred_by, utm)
  values (ph, public.partner_clean_tag(p_channel, 40), upper(public.partner_clean_tag(p_ref, 12)), public.partner_clean_utm(p_utm))
  on conflict (phone) do update
     set updated_at = now(),
         channel = case when p.channel = '' then excluded.channel else p.channel end,
         referred_by = case when p.referred_by = '' then excluded.referred_by else p.referred_by end,
         utm = case when p.utm = '{}'::jsonb then excluded.utm else p.utm end;
  if not exists (select 1 from public.partner_funnel_events e where e.event = 'number_filled' and e.phone = ph) then
    insert into public.partner_funnel_events (phone, event, meta)
    values (ph, 'number_filled', jsonb_build_object('channel', public.partner_clean_tag(p_channel, 40)));
  end if;
  return true;
end;
$$;

/**
 * Right after a partner's first sign-in: stamp where they came from (only if
 * not already stamped), link their prospect row, and log the funnel steps.
 * Call after partner_register. A no-op for callers who are not partners.
 */
create or replace function public.partner_signup_meta(p_channel text default '', p_ref text default '', p_utm jsonb default '{}')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  bp  public.broker_partners;
  pr  public.partner_prospects;
begin
  select * into bp from public.broker_partners where user_id = uid;
  if bp.user_id is null then return; end if;

  select * into pr from public.partner_prospects where phone = bp.phone;
  if pr.phone is not null and pr.user_id is null then
    update public.partner_prospects set user_id = uid, updated_at = now() where phone = pr.phone;
  end if;

  update public.broker_partners
     set signup_channel = case when signup_channel = ''
                               then coalesce(nullif(pr.channel, ''), nullif(public.partner_clean_tag(p_channel, 40), ''), 'direct')
                               else signup_channel end,
         referred_by = case when referred_by = '' then coalesce(nullif(pr.referred_by, ''), upper(public.partner_clean_tag(p_ref, 12))) else referred_by end,
         utm = case when utm = '{}'::jsonb then coalesce(nullif(pr.utm, '{}'::jsonb), public.partner_clean_utm(p_utm)) else utm end
   where user_id = uid;

  -- A number typed before Google now belongs to this account.
  update public.partner_funnel_events set user_id = uid
   where user_id is null and phone = bp.phone and bp.phone <> '';
  if bp.phone <> '' and not exists (select 1 from public.partner_funnel_events e where e.user_id = uid and e.event = 'number_filled') then
    insert into public.partner_funnel_events (user_id, phone, event, at) values (uid, bp.phone, 'number_filled', bp.created_at);
  end if;
  insert into public.partner_funnel_events (user_id, phone, event, at)
  values (uid, bp.phone, 'signed_up', bp.created_at)
  on conflict do nothing;
end;
$$;

-- Partners who signed up before the funnel existed: their two steps, back-dated.
insert into public.partner_funnel_events (user_id, phone, event, at)
select p.user_id, p.phone, 'signed_up', p.created_at from public.broker_partners p
on conflict do nothing;
insert into public.partner_funnel_events (user_id, phone, event, at)
select p.user_id, p.phone, 'number_filled', p.created_at from public.broker_partners p
 where p.phone <> ''
   and not exists (select 1 from public.partner_funnel_events e where e.user_id = p.user_id and e.event = 'number_filled');
update public.broker_partners set signup_channel = 'direct' where signup_channel = '';

-- ── § 2 Tenant (lead) capture ────────────────────────────────────────────────
-- Only the mobile is required now; the name can come later. Two new facts
-- about who is moving: bachelor or family, and male / female / co-ed.
alter table public.partner_leads drop constraint if exists partner_leads_name_check;
alter table public.partner_leads add column if not exists household   text not null default '';
alter table public.partner_leads add column if not exists gender_pref text not null default '';
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'partner_leads_household_check') then
    alter table public.partner_leads add constraint partner_leads_household_check check (household in ('', 'bachelor', 'family'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'partner_leads_gender_pref_check') then
    alter table public.partner_leads add constraint partner_leads_gender_pref_check check (gender_pref in ('', 'male', 'female', 'coed'));
  end if;
  -- Leads saved before this all have a number; NOT VALID skips re-checking them.
  if not exists (select 1 from pg_constraint where conname = 'partner_leads_phone_present') then
    alter table public.partner_leads add constraint partner_leads_phone_present check (length(trim(phone)) >= 10) not valid;
  end if;
end $$;

-- ── Row access ───────────────────────────────────────────────────────────────
alter table public.partner_prospects     enable row level security;
alter table public.partner_funnel_events enable row level security;

drop policy if exists "staff read" on public.partner_prospects;
create policy "staff read" on public.partner_prospects for select to authenticated using (public.is_crm_staff());
drop policy if exists "staff read" on public.partner_funnel_events;
create policy "staff read" on public.partner_funnel_events for select to authenticated using (public.is_crm_staff());

revoke all on public.partner_prospects, public.partner_funnel_events from public, anon, authenticated;
grant select on public.partner_prospects, public.partner_funnel_events to authenticated;

revoke all on function public.partner_clean_tag(text, int) from public, anon;
revoke all on function public.partner_clean_utm(jsonb) from public, anon;
revoke all on function public.partner_prospect(text, text, text, jsonb) from public, anon;
revoke all on function public.partner_signup_meta(text, text, jsonb) from public, anon;
grant execute on function public.partner_prospect(text, text, text, jsonb) to anon, authenticated;
grant execute on function public.partner_signup_meta(text, text, jsonb) to authenticated;

commit;

-- ═════════════════════════════════════════════════════════════════════════════
-- § 3–7: plans and payment, referrals, profile, status, the sales funnel.
-- ═════════════════════════════════════════════════════════════════════════════

begin;

-- ── § 3 Plans and payment ────────────────────────────────────────────────────
-- Three plans, editable in the CRM. Paying through Razorpay grants the
-- moveazy_inventory tier (the premium the whole app checks) for the plan's
-- months, stacked after any time already paid for.
--
-- A payment's life:  started  → Razorpay link created, broker sent to pay
--                    paid     → Razorpay's webhook confirmed it; plan active
--                    approved → a super admin activated it by hand
--                    rejected / refunded → a super admin undid it; plan ended
create table if not exists public.partner_plans (
  id           text primary key check (id ~ '^[a-z0-9_]{2,30}$'),
  label        text not null,
  months       int  not null check (months between 1 and 36),
  price        int  not null check (price between 1 and 1000000),
  refund_days  int  not null default 0 check (refund_days between 0 and 90),
  note         text not null default '',
  sort         int  not null default 0,
  active       boolean not null default true,
  -- A static Razorpay Payment Page for when the server can't create links (no keys yet).
  payment_link text not null default '' check (payment_link = '' or payment_link ~ '^https://'),
  updated_at   timestamptz not null default now()
);
insert into public.partner_plans (id, label, months, price, refund_days, note, sort) values
  ('trial_1m', '1 month trial', 1, 1500, 0, 'Every premium feature for a month.', 1),
  ('pro_5m', '5 months', 5, 4999, 30, 'Fully refundable if you don''t like it within the first month.', 2),
  ('pro_12m', '12 months', 12, 9999, 30, 'Fully refundable within the first month — no questions asked.', 3)
on conflict (id) do nothing;

create table if not exists public.partner_payments (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users (id) on delete cascade,
  plan_id            text not null references public.partner_plans (id),
  amount             int  not null,
  months             int  not null,
  status             text not null default 'started'
                       check (status in ('started', 'paid', 'approved', 'rejected', 'refunded')),
  link_id            text not null default '',
  link_url           text not null default '',
  gateway_payment_id text not null default '',
  entitlement_id     uuid,
  note               text not null default '',
  decided_by         text not null default '',
  created_at         timestamptz not null default now(),
  paid_at            timestamptz,
  decided_at         timestamptz
);
create index if not exists partner_payments_user_idx on public.partner_payments (user_id, created_at desc);
create index if not exists partner_payments_status_idx on public.partner_payments (status, created_at desc);
create unique index if not exists partner_payments_link_once on public.partner_payments (link_id) where link_id <> '';

/** The plans a broker can buy, cheapest first. */
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
           'note', p.note, 'has_link', p.payment_link <> '') order by p.sort, p.price), '[]'::jsonb)
    from public.partner_plans p where p.active;
$$;

/**
 * "Pay" pressed: record the attempt (the funnel's "payment tried", with the
 * plan) and hand back what the app needs to send the broker to Razorpay.
 */
create or replace function public.partner_payment_start(p_plan text)
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
  select * into pl from public.partner_plans where id = p_plan and active;
  if pl.id is null then raise exception 'That plan is not available.' using errcode = '22023'; end if;
  insert into public.partner_payments (user_id, plan_id, amount, months)
  values (auth.uid(), pl.id, pl.price, pl.months) returning * into pay;
  insert into public.partner_funnel_events (user_id, phone, event, meta)
  select auth.uid(), bp.phone, 'payment_tried', jsonb_build_object('plan', pl.id, 'amount', pl.price, 'payment', pay.id)
    from public.broker_partners bp where bp.user_id = auth.uid();
  return jsonb_build_object('id', pay.id, 'plan', pl.id, 'label', pl.label, 'amount', pl.price, 'months', pl.months,
                            'payment_link', pl.payment_link);
end;
$$;

/**
 * Turn a payment into premium time. Internal: reached through the Razorpay
 * webhook (partner_razorpay_paid) or a super admin (partner_admin_payment_decide).
 * Idempotent: a payment already active is returned as is.
 */
create or replace function public.partner_activate_payment(p_payment uuid, p_source text, p_gateway_payment text, p_actor text)
returns public.partner_payments
language plpgsql
security definer
set search_path = public
as $$
declare
  pay   public.partner_payments;
  start timestamptz;
  ent   uuid;
  bp    public.broker_partners;
  ref   public.broker_partners;
begin
  select * into pay from public.partner_payments where id = p_payment for update;
  if pay.id is null then raise exception 'No such payment.' using errcode = '22023'; end if;
  if pay.status in ('paid', 'approved') then return pay; end if;

  select coalesce(max(e.ends_at), now()) into start
    from public.partner_entitlements e
   where e.user_id = pay.user_id and e.tier = 'moveazy_inventory' and e.ends_at > now();
  start := greatest(start, now());

  insert into public.partner_entitlements (user_id, tier, plan, starts_at, ends_at, source, source_ref, granted_by)
  values (pay.user_id, 'moveazy_inventory', pay.plan_id, start, start + make_interval(months => pay.months),
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

  -- The first paid plan of a referred broker earns their referrer ₹1,500 after a month.
  if coalesce(bp.referred_by, '') <> '' then
    select * into ref from public.broker_partners where referral_code = bp.referred_by;
    if ref.user_id is not null and ref.user_id <> pay.user_id then
      insert into public.partner_referrals (referrer_id, referee_id, payment_id, plan_id, earn_after)
      values (ref.user_id, pay.user_id, pay.id, pay.plan_id, now() + interval '30 days')
      on conflict (referee_id) do nothing;
    end if;
  end if;
  return pay;
end;
$$;

/**
 * Razorpay's webhook, via /api/razorpay-webhook (service role only): the link
 * for this payment was paid. Checks the link and the amount before activating.
 */
create or replace function public.partner_razorpay_paid(p_payment uuid, p_link_id text, p_gateway_payment text, p_amount_paise bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  pay public.partner_payments;
begin
  select * into pay from public.partner_payments where id = p_payment;
  if pay.id is null then return jsonb_build_object('ok', false, 'why', 'unknown payment'); end if;
  if pay.link_id <> '' and pay.link_id <> coalesce(p_link_id, '') then
    return jsonb_build_object('ok', false, 'why', 'link mismatch');
  end if;
  if coalesce(p_amount_paise, 0) < pay.amount::bigint * 100 then
    update public.partner_payments set note = left(note || ' · underpaid ' || p_amount_paise || ' paise', 500) where id = pay.id;
    return jsonb_build_object('ok', false, 'why', 'amount short');
  end if;
  pay := public.partner_activate_payment(pay.id, 'razorpay', p_gateway_payment, 'razorpay');
  return jsonb_build_object('ok', true, 'status', pay.status);
end;
$$;

/** A super admin approves (activates) or rejects / refunds a payment. Nobody else. */
create or replace function public.partner_admin_payment_decide(p_payment uuid, p_approve boolean, p_note text default '')
returns public.partner_payments
language plpgsql
security definer
set search_path = public
as $$
declare
  pay   public.partner_payments;
  actor text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if not public.is_super_admin() then
    raise exception 'Only the super admin can approve payments.' using errcode = '42501';
  end if;
  select * into pay from public.partner_payments where id = p_payment for update;
  if pay.id is null then raise exception 'No such payment.' using errcode = '22023'; end if;

  if p_approve then
    pay := public.partner_activate_payment(pay.id, 'manual', '', actor);
    if coalesce(p_note, '') <> '' then
      update public.partner_payments set note = left(p_note, 500) where id = pay.id returning * into pay;
    end if;
    return pay;
  end if;

  -- Undo: the plan's time ends now, the referral it earned is void.
  if pay.entitlement_id is not null then
    update public.partner_entitlements
       set starts_at = least(starts_at, now() - interval '1 second'), ends_at = least(ends_at, now())
     where id = pay.entitlement_id;
  end if;
  update public.partner_referrals set status = 'void' where payment_id = pay.id and status <> 'paid';
  update public.partner_payments
     set status = case when pay.status in ('paid', 'approved') then 'refunded' else 'rejected' end,
         decided_at = now(), decided_by = actor, note = left(coalesce(nullif(p_note, ''), note), 500)
   where id = pay.id
   returning * into pay;
  insert into public.partner_funnel_events (user_id, event, meta)
  values (pay.user_id, 'plan_rejected', jsonb_build_object('plan', pay.plan_id, 'payment', pay.id, 'by', actor));
  return pay;
end;
$$;

-- ── § 4 Referrals ────────────────────────────────────────────────────────────
alter table public.broker_partners add column if not exists referral_code text;
create unique index if not exists broker_partners_referral_code on public.broker_partners (referral_code) where referral_code is not null;

create table if not exists public.partner_referrals (
  id          uuid primary key default gen_random_uuid(),
  referrer_id uuid not null references auth.users (id) on delete cascade,
  referee_id  uuid not null unique references auth.users (id) on delete cascade,
  payment_id  uuid references public.partner_payments (id) on delete set null,
  plan_id     text not null default '',
  amount      int  not null default 1500,
  -- pending until earn_after (a month, plan not cancelled); then earned; paid when the super admin has paid it out.
  status      text not null default 'pending' check (status in ('pending', 'earned', 'paid', 'void')),
  earn_after  timestamptz not null,
  created_at  timestamptz not null default now(),
  paid_at     timestamptz,
  paid_by     text not null default ''
);
create index if not exists partner_referrals_referrer_idx on public.partner_referrals (referrer_id, created_at desc);

/** A month has passed and the plan still stands: pending becomes earned. */
create or replace function public.partner_referrals_settle()
returns void
language sql
security definer
set search_path = public
as $$
  update public.partner_referrals r set status = 'earned'
   where r.status = 'pending' and r.earn_after <= now()
     and not exists (select 1 from public.partner_payments p where p.id = r.payment_id and p.status in ('rejected', 'refunded'));
$$;

/** The caller's referral code, made on first ask. */
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

/** Who joined with my code, and what I've earned. */
create or replace function public.partner_my_referrals()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  code text := public.partner_referral_code();
begin
  perform public.partner_referrals_settle();
  return jsonb_build_object(
    'code', code,
    'joined', coalesce((
      select jsonb_agg(jsonb_build_object(
               'name', coalesce(nullif(bp.name, ''), 'A broker'),
               'joined_at', bp.created_at,
               'plan', r.plan_id,
               'status', coalesce(r.status, 'signed_up'),
               'amount', coalesce(r.amount, 0),
               'earn_after', r.earn_after) order by bp.created_at desc)
        from public.broker_partners bp
        left join public.partner_referrals r on r.referee_id = bp.user_id and r.referrer_id = auth.uid()
       where bp.referred_by = code and bp.user_id <> auth.uid()), '[]'::jsonb),
    'pending', coalesce((select sum(amount) from public.partner_referrals where referrer_id = auth.uid() and status = 'pending'), 0),
    'earned', coalesce((select sum(amount) from public.partner_referrals where referrer_id = auth.uid() and status = 'earned'), 0),
    'paid', coalesce((select sum(amount) from public.partner_referrals where referrer_id = auth.uid() and status = 'paid'), 0)
  );
end;
$$;

/** The super admin marks an earned referral as paid out. */
create or replace function public.partner_admin_referral_paid(p_referral uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_super_admin() then
    raise exception 'Only the super admin can mark payouts.' using errcode = '42501';
  end if;
  perform public.partner_referrals_settle();
  update public.partner_referrals
     set status = 'paid', paid_at = now(), paid_by = lower(coalesce(auth.jwt() ->> 'email', ''))
   where id = p_referral and status = 'earned';
  if not found then raise exception 'Only an earned referral can be marked paid.' using errcode = '22023'; end if;
end;
$$;

-- ── § 5 Complete profile ─────────────────────────────────────────────────────
alter table public.broker_partners add column if not exists operational_areas    text[] not null default '{}';
alter table public.broker_partners add column if not exists rera_id              text   not null default '';
alter table public.broker_partners add column if not exists profile_completed_at timestamptz;
alter table public.broker_partners add column if not exists congrats_seen_at     timestamptz;

create or replace function public.partner_complete_profile(p_areas text[], p_rera text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  areas text[];
  rera  text := upper(regexp_replace(trim(coalesce(p_rera, '')), '\s+', '', 'g'));
begin
  if not public.is_approved_partner() then
    raise exception 'Only approved partners have a profile.' using errcode = '42501';
  end if;
  select coalesce(array_agg(distinct left(trim(a), 80)) filter (where trim(a) <> ''), '{}') into areas from unnest(coalesce(p_areas, '{}')) a;
  if cardinality(areas) = 0 then raise exception 'Pick at least one area you work in.' using errcode = '22023'; end if;
  if cardinality(areas) > 40 then raise exception 'Pick up to 40 areas.' using errcode = '22023'; end if;
  if rera !~ '^[A-Z0-9/_.-]{5,40}$' then
    raise exception 'Enter your RERA registration number.' using errcode = '22023';
  end if;
  update public.broker_partners
     set operational_areas = areas, rera_id = rera, profile_completed_at = coalesce(profile_completed_at, now()), updated_at = now()
   where user_id = auth.uid();
  insert into public.partner_funnel_events (user_id, event, meta)
  values (auth.uid(), 'profile_completed', jsonb_build_object('areas', cardinality(areas)))
  on conflict do nothing;
  return jsonb_build_object('areas', areas, 'rera_id', rera);
end;
$$;

-- ── § 6 What the app needs to know about me ─────────────────────────────────
/** Plan, latest payment, profile and whether the congratulations page is due. */
create or replace function public.partner_status()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with cur as (
    select e.* from public.partner_entitlements e
     where e.user_id = auth.uid() and e.tier = 'moveazy_inventory' and now() >= e.starts_at and now() < e.ends_at
     order by e.ends_at desc limit 1
  ), last_ent as (
    select max(e.created_at) as at, max(e.ends_at) as until from public.partner_entitlements e
     where e.user_id = auth.uid() and e.tier = 'moveazy_inventory' and e.ends_at > now()
  )
  select jsonb_build_object(
    'plan', jsonb_build_object(
      'active', exists (select 1 from cur),
      'plan_id', (select c.plan from cur c),
      'label', (select pl.label from cur c join public.partner_plans pl on pl.id = c.plan),
      'until', (select until from last_ent)),
    'payment', (select jsonb_build_object('id', p.id, 'status', p.status, 'plan_id', p.plan_id, 'amount', p.amount, 'created_at', p.created_at)
                  from public.partner_payments p where p.user_id = auth.uid() order by p.created_at desc limit 1),
    'profile', (select jsonb_build_object('areas', bp.operational_areas, 'rera_id', bp.rera_id, 'completed_at', bp.profile_completed_at)
                  from public.broker_partners bp where bp.user_id = auth.uid()),
    'referral_code', (select bp.referral_code from public.broker_partners bp where bp.user_id = auth.uid()),
    'congrats_due', exists (select 1 from cur)
                    and coalesce((select bp.congrats_seen_at from public.broker_partners bp where bp.user_id = auth.uid()), '-infinity')
                        < coalesce((select at from last_ent), '-infinity')
  );
$$;

create or replace function public.partner_congrats_seen()
returns void
language sql
security definer
set search_path = public
as $$ update public.broker_partners set congrats_seen_at = now() where user_id = auth.uid(); $$;

-- ── § 7 The sales funnel (partners.moveazy.co.in/sales-funnel) ────────────────
/**
 * Every broker and every number left before Google, with where they came from
 * and how far they got. CRM staff read it; only the super admin decides
 * payments (partner_admin_payment_decide).
 */
create or replace function public.partner_funnel()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then
    raise exception 'CRM staff only.' using errcode = '42501';
  end if;
  perform public.partner_referrals_settle();
  return jsonb_build_object(
    'can_decide', public.is_super_admin(),
    'brokers', coalesce((
      select jsonb_agg(x order by (x ->> 'created_at') desc) from (
        select jsonb_build_object(
          'user_id', bp.user_id, 'name', bp.name, 'phone', bp.phone, 'email', bp.email, 'agency', bp.agency,
          'status', bp.status, 'channel', bp.signup_channel, 'referred_by', bp.referred_by, 'utm', bp.utm,
          'referral_code', bp.referral_code, 'created_at', bp.created_at,
          'profile_completed_at', bp.profile_completed_at, 'rera_id', bp.rera_id,
          'plan_active', exists (select 1 from public.partner_entitlements e where e.user_id = bp.user_id
                                   and e.tier = 'moveazy_inventory' and now() >= e.starts_at and now() < e.ends_at),
          'plan_until', (select max(e.ends_at) from public.partner_entitlements e where e.user_id = bp.user_id and e.tier = 'moveazy_inventory'),
          'payments', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'plan_id', p.plan_id, 'amount', p.amount,
                                   'status', p.status, 'created_at', p.created_at, 'paid_at', p.paid_at, 'link_id', p.link_id,
                                   'gateway_payment_id', p.gateway_payment_id, 'decided_by', p.decided_by, 'note', p.note)
                                   order by p.created_at desc)
                                 from public.partner_payments p where p.user_id = bp.user_id), '[]'::jsonb)
        ) as x from public.broker_partners bp) q), '[]'::jsonb),
    'prospects', coalesce((
      select jsonb_agg(jsonb_build_object('phone', pr.phone, 'channel', pr.channel, 'referred_by', pr.referred_by,
                                          'utm', pr.utm, 'created_at', pr.created_at) order by pr.created_at desc)
        from public.partner_prospects pr where pr.user_id is null), '[]'::jsonb),
    'referrals', coalesce((
      select jsonb_agg(jsonb_build_object('id', r.id, 'referrer', a.name, 'referrer_phone', a.phone, 'referee', b.name,
                                          'plan_id', r.plan_id, 'amount', r.amount, 'status', r.status,
                                          'earn_after', r.earn_after, 'paid_at', r.paid_at) order by r.created_at desc)
        from public.partner_referrals r
        left join public.broker_partners a on a.user_id = r.referrer_id
        left join public.broker_partners b on b.user_id = r.referee_id), '[]'::jsonb),
    'plans', public.partner_plans_list()
  );
end;
$$;

/** The CRM edits a plan's price, label, refund window or static payment link. */
create or replace function public.partner_admin_set_plan(p_id text, p_label text, p_price int, p_months int, p_refund_days int, p_note text, p_payment_link text, p_active boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_super_admin() then
    raise exception 'Only the super admin can change plans.' using errcode = '42501';
  end if;
  update public.partner_plans
     set label = left(coalesce(nullif(trim(p_label), ''), label), 60), price = p_price, months = p_months,
         refund_days = p_refund_days, note = left(coalesce(p_note, ''), 200), payment_link = trim(coalesce(p_payment_link, '')),
         active = coalesce(p_active, active), updated_at = now()
   where id = p_id;
  if not found then raise exception 'No such plan.' using errcode = '22023'; end if;
end;
$$;

-- ── Row access (§ 3–7) ───────────────────────────────────────────────────────
alter table public.partner_plans     enable row level security;
alter table public.partner_payments  enable row level security;
alter table public.partner_referrals enable row level security;

drop policy if exists "staff read" on public.partner_plans;
create policy "staff read" on public.partner_plans for select to authenticated using (public.is_crm_staff());
drop policy if exists "staff read" on public.partner_payments;
create policy "staff read" on public.partner_payments for select to authenticated using (public.is_crm_staff());
drop policy if exists "partner reads own payments" on public.partner_payments;
create policy "partner reads own payments" on public.partner_payments for select to authenticated using (user_id = auth.uid());
drop policy if exists "staff read" on public.partner_referrals;
create policy "staff read" on public.partner_referrals for select to authenticated using (public.is_crm_staff());

revoke all on public.partner_plans, public.partner_payments, public.partner_referrals from public, anon, authenticated;
grant select on public.partner_plans, public.partner_payments, public.partner_referrals to authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'public.partner_activate_payment(uuid, text, text, text)',
    'public.partner_razorpay_paid(uuid, text, text, bigint)',
    'public.partner_referrals_settle()'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
  foreach f in array array[
    'public.partner_plans_list()',
    'public.partner_payment_start(text)',
    'public.partner_admin_payment_decide(uuid, boolean, text)',
    'public.partner_referral_code()',
    'public.partner_my_referrals()',
    'public.partner_admin_referral_paid(uuid)',
    'public.partner_complete_profile(text[], text)',
    'public.partner_status()',
    'public.partner_congrats_seen()',
    'public.partner_funnel()',
    'public.partner_admin_set_plan(text, text, int, int, int, text, text, boolean)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
-- The webhook's server-side call.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.partner_razorpay_paid(uuid, text, text, bigint) to service_role';
  end if;
end $$;

commit;

-- ═════════════════════════════════════════════════════════════════════════════
-- § 8  Curated lists a broker sends a tenant; the tenant's swipes; broker
--      notifications; tenants brought by brokers, kept out of MovEazy's leads.
-- § 9  Sold out: any group member flags a listing; MovEazy and the listing
--      broker are told; "potentially rented" until the listing broker (or
--      MovEazy) decides. Nothing is ever deleted.
-- ═════════════════════════════════════════════════════════════════════════════

begin;

-- ── § 8 Curated lists ────────────────────────────────────────────────────────
-- Separate from MovEazy's own curated shares (crm_curated_shares): these are a
-- broker's picks for a broker's tenant, and every row carries the broker.
create table if not exists public.partner_curated_lists (
  id           uuid primary key default gen_random_uuid(),
  token        text not null unique default replace(gen_random_uuid()::text, '-', ''),
  broker_id    uuid not null references auth.users (id) on delete cascade,
  lead_id      uuid references public.partner_leads (id) on delete set null,
  lead_name    text not null default '',
  property_ids text[] not null check (cardinality(property_ids) between 1 and 30),
  tenant_id    uuid,
  created_at   timestamptz not null default now(),
  opened_at    timestamptz,
  open_count   int not null default 0
);
create index if not exists partner_curated_lists_broker_idx on public.partner_curated_lists (broker_id, created_at desc);

create table if not exists public.partner_curated_actions (
  list_id     uuid not null references public.partner_curated_lists (id) on delete cascade,
  property_id text not null,
  action      text not null check (action in ('liked', 'skipped')),
  at          timestamptz not null default now(),
  primary key (list_id, property_id)
);

-- A tenant a broker brought: unverified (they typed a number on a broker's
-- link), attributed to that broker, and never a MovEazy lead.
create table if not exists public.partner_tenants (
  id           uuid primary key default gen_random_uuid(),
  broker_id    uuid not null references auth.users (id) on delete cascade,
  phone        text not null check (phone ~ '^[6-9][0-9]{9}$'),
  name         text not null default '',
  source       text not null default 'curated' check (source in ('curated', 'storefront')),
  status       text not null default 'unverified' check (status in ('unverified', 'verified')),
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique (broker_id, phone)
);
create index if not exists partner_tenants_phone_idx on public.partner_tenants (phone);

create table if not exists public.partner_notifications (
  id         bigint generated always as identity primary key,
  broker_id  uuid not null references auth.users (id) on delete cascade,
  kind       text not null,
  title      text not null,
  body       text not null default '',
  link       text not null default '',
  created_at timestamptz not null default now(),
  read_at    timestamptz
);
create index if not exists partner_notifications_broker_idx on public.partner_notifications (broker_id, created_at desc);

-- MovEazy's own leads carry who they belong to: 'moveazy', or the broker's id
-- when the number first came through that broker. The CRM lists 'moveazy' only.
-- (Only where the CRM exists: crm_schema.sql.)
create or replace function public.crm_clients_attribute()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  b uuid;
begin
  if new.attributed_to is distinct from 'moveazy' then return new; end if;
  select t.broker_id into b from public.partner_tenants t
   where t.phone = public.normalize_mobile(new.phone) and public.normalize_mobile(new.phone) <> ''
   order by t.created_at limit 1;
  if b is not null then new.attributed_to := b::text; end if;
  return new;
end;
$$;
do $$
begin
  if to_regclass('public.crm_clients') is not null then
    execute 'alter table public.crm_clients add column if not exists attributed_to text not null default ''moveazy''';
    execute 'drop trigger if exists crm_clients_attribute on public.crm_clients';
    execute 'create trigger crm_clients_attribute before insert on public.crm_clients for each row execute function public.crm_clients_attribute()';
  end if;
end $$;

/** A broker's curated list for one of their leads, from flats they can see. Premium only. */
create or replace function public.partner_curated_create(p_lead uuid, p_properties text[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  ids   text[];
  lname text;
  rec   public.partner_curated_lists;
begin
  if not (public.is_approved_partner() and public.partner_has_tier('moveazy_inventory')) then
    raise exception 'Curated lists come with a Premium plan.' using errcode = '42501';
  end if;
  select coalesce(array_agg(distinct p), '{}') into ids from unnest(coalesce(p_properties, '{}')) p;
  if cardinality(ids) = 0 or cardinality(ids) > 30 then
    raise exception 'Pick between 1 and 30 homes.' using errcode = '22023';
  end if;
  if exists (select unnest(ids) except select property_id from public.partner_inventory()) then
    raise exception 'One of those homes is not in your inventory.' using errcode = '42501';
  end if;
  if p_lead is not null then
    select name into lname from public.partner_leads where id = p_lead and broker_id = auth.uid();
    if not found then raise exception 'That lead is not yours.' using errcode = '42501'; end if;
  end if;
  insert into public.partner_curated_lists (broker_id, lead_id, lead_name, property_ids)
  values (auth.uid(), p_lead, coalesce(lname, ''), ids)
  returning * into rec;
  return jsonb_build_object('id', rec.id, 'token', rec.token, 'count', cardinality(ids));
end;
$$;

/** The tenant's page, by the link's token. Public columns only; opening is counted. */
create or replace function public.partner_curated_open(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  l public.partner_curated_lists;
begin
  select * into l from public.partner_curated_lists where token = p_token;
  if l.id is null then return null; end if;
  update public.partner_curated_lists
     set open_count = open_count + 1, opened_at = coalesce(opened_at, now())
   where id = l.id;
  -- The first open is news: the tenant is looking at the list right now.
  if l.opened_at is null then
    insert into public.partner_notifications (broker_id, kind, title, body, link)
    values (l.broker_id, 'list_opened', coalesce(nullif(l.lead_name, ''), 'Your tenant') || ' opened your list',
            cardinality(l.property_ids) || ' homes — likes and skips will show up here.', '/curated/' || l.id::text);
  end if;
  return jsonb_build_object(
    'lead_name', l.lead_name,
    'has_contact', l.tenant_id is not null,
    'broker', (select jsonb_build_object('name', bp.name, 'agency', bp.agency, 'phone', bp.phone,
                                         'photo_url', coalesce((select s.photo_url from public.partner_storefronts s where s.broker_id = bp.user_id), ''))
                 from public.broker_partners bp where bp.user_id = l.broker_id),
    'homes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'property_id', i.property_id, 'title', i.title, 'area', i.area, 'rent', i.rent, 'deposit', i.deposit,
               'flat_type', i.flat_type, 'bedrooms', i.bedrooms, 'bathrooms', i.bathrooms, 'furnishing', i.furnishing,
               'property_type', i.property_type, 'available_from', i.available_from, 'images', i.images,
               'cover_image_url', i.cover_image_url, 'description', i.description, 'status', i.status,
               'action', (select a.action from public.partner_curated_actions a where a.list_id = l.id and a.property_id = i.property_id))
             order by array_position(l.property_ids, i.property_id))
        from public.inventory i where i.property_id = any (l.property_ids)), '[]'::jsonb)
  );
end;
$$;

/** Before swiping: the tenant's mobile (name optional). They become the broker's unverified tenant. */
create or replace function public.partner_curated_contact(p_token text, p_phone text, p_name text default '')
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  l  public.partner_curated_lists;
  ph text := public.normalize_mobile(p_phone);
  t  uuid;
begin
  if ph = '' then raise exception 'Enter a valid 10-digit mobile number.' using errcode = '22023'; end if;
  select * into l from public.partner_curated_lists where token = p_token;
  if l.id is null then raise exception 'This list is no longer available.' using errcode = '22023'; end if;
  insert into public.partner_tenants as pt (broker_id, phone, name, source)
  values (l.broker_id, ph, left(trim(coalesce(p_name, '')), 120), 'curated')
  on conflict (broker_id, phone) do update
     set last_seen_at = now(), name = coalesce(nullif(left(trim(coalesce(p_name, '')), 120), ''), pt.name)
  returning id into t;
  update public.partner_curated_lists set tenant_id = t where id = l.id;
  return true;
end;
$$;

/** A swipe. A like tells the broker straight away. */
create or replace function public.partner_curated_act(p_token text, p_property text, p_action text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  l  public.partner_curated_lists;
  tn public.partner_tenants;
  h  public.inventory;
  was_done boolean;
  n_liked int;
  n_skipped int;
begin
  select * into l from public.partner_curated_lists where token = p_token;
  if l.id is null then raise exception 'This list is no longer available.' using errcode = '22023'; end if;
  if l.tenant_id is null then raise exception 'Add your mobile number first.' using errcode = '42501'; end if;
  if not (p_property = any (l.property_ids)) then raise exception 'That home is not on this list.' using errcode = '22023'; end if;
  if p_action not in ('liked', 'skipped') then raise exception 'Unknown action.' using errcode = '22023'; end if;

  select count(*) = cardinality(l.property_ids) into was_done from public.partner_curated_actions where list_id = l.id;
  insert into public.partner_curated_actions as a (list_id, property_id, action)
  values (l.id, p_property, p_action)
  on conflict (list_id, property_id) do update set action = excluded.action, at = now();

  if p_action = 'liked' then
    select * into tn from public.partner_tenants where id = l.tenant_id;
    select * into h from public.inventory where property_id = p_property;
    insert into public.partner_notifications (broker_id, kind, title, body, link)
    values (l.broker_id, 'tenant_liked',
            coalesce(nullif(tn.name, ''), nullif(l.lead_name, ''), 'Your tenant') || ' liked a home',
            concat_ws(' · ', nullif(h.flat_type, ''), nullif(h.area, ''), case when h.rent > 0 then '₹' || to_char(h.rent, 'FM99,99,999') end)
              || ' — ' || tn.phone,
            '/curated/' || l.id::text);
  end if;

  -- The whole list done: one summary of likes and skips.
  if not was_done then
    select count(*) filter (where action = 'liked'), count(*) filter (where action = 'skipped'), count(*) = cardinality(l.property_ids)
      into n_liked, n_skipped, was_done
      from public.partner_curated_actions where list_id = l.id;
    if was_done then
      select * into tn from public.partner_tenants where id = l.tenant_id;
      insert into public.partner_notifications (broker_id, kind, title, body, link)
      values (l.broker_id, 'list_done',
              coalesce(nullif(tn.name, ''), nullif(l.lead_name, ''), 'Your tenant') || ' finished your list',
              '♥ ' || n_liked || ' liked · ✕ ' || n_skipped || ' skipped — ' || coalesce(tn.phone, ''),
              '/curated/' || l.id::text);
    end if;
  end if;
  return true;
end;
$$;

/** A broker's lists, with what each tenant did. */
create or replace function public.partner_curated_mine()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', l.id, 'token', l.token, 'lead_id', l.lead_id, 'lead_name', l.lead_name, 'created_at', l.created_at,
           'opened_at', l.opened_at, 'open_count', l.open_count, 'property_ids', l.property_ids,
           'tenant', (select jsonb_build_object('name', t.name, 'phone', t.phone) from public.partner_tenants t where t.id = l.tenant_id),
           'actions', coalesce((select jsonb_object_agg(a.property_id, jsonb_build_object('action', a.action, 'at', a.at))
                                  from public.partner_curated_actions a where a.list_id = l.id), '{}'::jsonb))
           order by l.created_at desc), '[]'::jsonb)
    from public.partner_curated_lists l where l.broker_id = auth.uid();
$$;

create or replace function public.partner_notifications_list()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'unread', (select count(*) from public.partner_notifications where broker_id = auth.uid() and read_at is null),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'kind', n.kind, 'title', n.title, 'body', n.body,
                                                          'link', n.link, 'created_at', n.created_at, 'read', n.read_at is not null)
                                        order by n.created_at desc)
                         from (select * from public.partner_notifications where broker_id = auth.uid() order by created_at desc limit 100) n), '[]'::jsonb));
$$;

create or replace function public.partner_notifications_read()
returns void
language sql
security definer
set search_path = public
as $$ update public.partner_notifications set read_at = now() where broker_id = auth.uid() and read_at is null; $$;

-- A like on a broker's QR storefront also becomes their tenant and a notification.
create or replace function public.partner_storefront_like_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  up public.user_profiles;
  h  public.inventory;
  ph text;
begin
  select * into up from public.user_profiles where id = new.user_id;
  ph := public.normalize_mobile(coalesce(up.phone, ''));
  if ph <> '' then
    insert into public.partner_tenants as pt (broker_id, phone, name, source)
    values (new.broker_id, ph, left(coalesce(up.name, ''), 120), 'storefront')
    on conflict (broker_id, phone) do update set last_seen_at = now();
  end if;
  select * into h from public.inventory where property_id = new.property_id;
  insert into public.partner_notifications (broker_id, kind, title, body, link)
  values (new.broker_id, 'storefront_like', coalesce(nullif(up.name, ''), 'A tenant') || ' liked a home on your QR page',
          concat_ws(' · ', nullif(h.flat_type, ''), nullif(h.area, '')) || case when ph <> '' then ' — ' || ph else '' end, '/qr');
  return new;
end;
$$;
drop trigger if exists partner_storefront_like_notify on public.partner_storefront_likes;
create trigger partner_storefront_like_notify after insert on public.partner_storefront_likes
  for each row execute function public.partner_storefront_like_notify();

/** CRM: every tenant brought by a broker, with the broker — never mixed into MovEazy's leads. */
create or replace function public.crm_broker_leads()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'tenants', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', t.id, 'name', t.name, 'phone', t.phone, 'source', t.source, 'status', t.status,
               'created_at', t.created_at, 'last_seen_at', t.last_seen_at,
               'broker_id', t.broker_id, 'broker', bp.name, 'broker_phone', bp.phone, 'broker_agency', bp.agency,
               'likes', (select count(*) from public.partner_curated_actions a join public.partner_curated_lists l on l.id = a.list_id
                          where l.tenant_id = t.id and a.action = 'liked')
                        + (select count(*) from public.partner_storefront_likes sl join public.user_profiles up on up.id = sl.user_id
                            where sl.broker_id = t.broker_id and public.normalize_mobile(up.phone) = t.phone))
             order by t.last_seen_at desc)
        from public.partner_tenants t left join public.broker_partners bp on bp.user_id = t.broker_id), '[]'::jsonb),
    'attributed_clients', case when to_regclass('public.crm_clients') is null then 0
                               else (select count(*) from public.crm_clients where attributed_to <> 'moveazy') end
  );
end;
$$;

-- ── § 9 Sold out ─────────────────────────────────────────────────────────────
-- '' or 'potentially_rented'. Public, like the rest of a listing: the site
-- shows the marker until the listing broker (or MovEazy) decides.
alter table public.inventory add column if not exists rent_flag text not null default '';
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'inventory_rent_flag_check') then
    alter table public.inventory add constraint inventory_rent_flag_check check (rent_flag in ('', 'potentially_rented'));
  end if;
end $$;
grant select (rent_flag) on public.inventory to anon, authenticated;

create table if not exists public.partner_soldout_requests (
  id           uuid primary key default gen_random_uuid(),
  property_id  text not null references public.inventory (property_id) on delete cascade,
  requested_by uuid not null references auth.users (id) on delete cascade,
  status       text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  note         text not null default '',
  created_at   timestamptz not null default now(),
  decided_at   timestamptz,
  decided_by   text not null default ''
);
create unique index if not exists partner_soldout_one_pending on public.partner_soldout_requests (property_id) where status = 'pending';

/**
 * A partner who sees a listing through a group (or the network) says it's
 * gone. The listing turns "potentially rented"; its broker is notified; MovEazy
 * sees it in the CRM.
 */
create or replace function public.partner_mark_sold_out(p_property text, p_note text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  lister uuid;
  h      public.inventory;
  who    text;
  req    public.partner_soldout_requests;
begin
  if not (public.is_approved_partner() and public.partner_has_tier('moveazy_inventory')) then
    raise exception 'Marking sold out comes with a Premium plan.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.partner_inventory() v where v.property_id = p_property and v.source <> 'mine') then
    raise exception 'You can mark sold out only a listing shared with you.' using errcode = '42501';
  end if;
  select * into h from public.inventory where property_id = p_property;
  if h.status <> 'published' then raise exception 'That listing is already off the market.' using errcode = '22023'; end if;
  select broker_id into lister from public.partner_listings where property_id = p_property;
  select name into who from public.broker_partners where user_id = auth.uid();

  insert into public.partner_soldout_requests (property_id, requested_by, note)
  values (p_property, auth.uid(), left(coalesce(p_note, ''), 300))
  on conflict (property_id) where status = 'pending' do nothing
  returning * into req;
  if req.id is null then
    return jsonb_build_object('ok', true, 'already', true);
  end if;
  update public.inventory set rent_flag = 'potentially_rented' where property_id = p_property;
  if lister is not null then
    insert into public.partner_notifications (broker_id, kind, title, body, link)
    values (lister, 'sold_out_request', coalesce(nullif(who, ''), 'A broker') || ' says your listing is rented',
            concat_ws(' · ', nullif(h.flat_type, ''), nullif(h.area, ''), p_property) || '. Confirm to mark it sold out.',
            '/property/' || p_property);
  end if;
  return jsonb_build_object('ok', true, 'request', req.id);
end;
$$;

/** The listing broker (or MovEazy staff with partners.manage) confirms or rejects. Never deletes. */
create or replace function public.partner_decide_sold_out(p_property text, p_approve boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  lister uuid;
  req    public.partner_soldout_requests;
  actor  text := coalesce(nullif(lower(auth.jwt() ->> 'email'), ''), auth.uid()::text);
begin
  select broker_id into lister from public.partner_listings where property_id = p_property;
  if not (auth.uid() = lister or public.has_admin_scope('partners.manage') or public.is_super_admin()) then
    raise exception 'Only the listing broker or MovEazy can decide this.' using errcode = '42501';
  end if;
  select * into req from public.partner_soldout_requests where property_id = p_property and status = 'pending';
  if req.id is null then raise exception 'Nothing to decide.' using errcode = '22023'; end if;
  update public.partner_soldout_requests
     set status = case when p_approve then 'approved' else 'rejected' end, decided_at = now(), decided_by = left(actor, 120)
   where id = req.id;
  update public.inventory
     set rent_flag = '', status = case when p_approve then 'rented' else status end, updated_at = now()
   where property_id = p_property;
  insert into public.partner_notifications (broker_id, kind, title, body, link)
  values (req.requested_by, 'sold_out_decided',
          case when p_approve then 'Marked sold out — thanks' else 'Still available' end,
          p_property || case when p_approve then ' is off the market now.' else ' — the listing broker says it is still available.' end,
          '/property/' || p_property);
  return jsonb_build_object('ok', true, 'approved', p_approve);
end;
$$;

/** CRM: sold-out flags waiting for a decision (and recent ones). */
create or replace function public.crm_soldout_requests()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', r.id, 'property_id', r.property_id, 'status', r.status, 'note', r.note, 'created_at', r.created_at,
             'decided_at', r.decided_at, 'decided_by', r.decided_by,
             'by', a.name, 'by_phone', a.phone, 'lister', b.name, 'lister_phone', b.phone,
             'flat_type', i.flat_type, 'area', i.area, 'rent', i.rent) order by r.status = 'pending' desc, r.created_at desc)
      from public.partner_soldout_requests r
      join public.inventory i on i.property_id = r.property_id
      left join public.broker_partners a on a.user_id = r.requested_by
      left join public.partner_listings pl on pl.property_id = r.property_id
      left join public.broker_partners b on b.user_id = pl.broker_id), '[]'::jsonb);
end;
$$;

-- ── Row access (§ 8–9) ───────────────────────────────────────────────────────
alter table public.partner_curated_lists    enable row level security;
alter table public.partner_curated_actions  enable row level security;
alter table public.partner_tenants          enable row level security;
alter table public.partner_notifications    enable row level security;
alter table public.partner_soldout_requests enable row level security;

do $$
declare t text;
begin
  foreach t in array array['partner_curated_lists', 'partner_curated_actions', 'partner_tenants', 'partner_notifications', 'partner_soldout_requests'] loop
    execute format('drop policy if exists "staff read" on public.%I', t);
    execute format('create policy "staff read" on public.%I for select to authenticated using (public.is_crm_staff())', t);
  end loop;
end $$;

revoke all on public.partner_curated_lists, public.partner_curated_actions, public.partner_tenants,
              public.partner_notifications, public.partner_soldout_requests from public, anon, authenticated;
grant select on public.partner_curated_lists, public.partner_curated_actions, public.partner_tenants,
                public.partner_notifications, public.partner_soldout_requests to authenticated;

revoke all on function public.crm_clients_attribute() from public, anon, authenticated;
revoke all on function public.partner_storefront_like_notify() from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array[
    'public.partner_curated_create(uuid, text[])',
    'public.partner_curated_open(text)',
    'public.partner_curated_contact(text, text, text)',
    'public.partner_curated_act(text, text, text)',
    'public.partner_curated_mine()',
    'public.partner_notifications_list()',
    'public.partner_notifications_read()',
    'public.crm_broker_leads()',
    'public.partner_mark_sold_out(text, text)',
    'public.partner_decide_sold_out(text, boolean)',
    'public.crm_soldout_requests()'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
-- The tenant's three calls work signed out: the link is the key.
grant execute on function public.partner_curated_open(text) to anon;
grant execute on function public.partner_curated_contact(text, text, text) to anon;
grant execute on function public.partner_curated_act(text, text, text) to anon;

commit;

-- ═════════════════════════════════════════════════════════════════════════════
-- § 10 The broker's leads dashboard: QR poster spots (so scans can be counted
--      by area — a scan can't say where the poster is, the poster can), the
--      insights read, and link-preview reads with no side effects.
-- ═════════════════════════════════════════════════════════════════════════════

begin;

alter table public.partner_notifications drop constraint if exists partner_notifications_kind_check;
alter table public.partner_notifications add constraint partner_notifications_kind_check
  check (kind in ('tenant_liked', 'storefront_like', 'sold_out_request', 'sold_out_decided', 'list_opened', 'list_done',
                  'building_visit', 'building_assigned'));  -- the last two: owner_buildings.sql

-- Where a printed poster is pasted. Each spot gets its own QR (…/b/CODE?s=qr&p=spot).
create table if not exists public.partner_qr_spots (
  id         uuid primary key default gen_random_uuid(),
  broker_id  uuid not null references auth.users (id) on delete cascade,
  code       text not null unique check (code ~ '^[a-z2-9]{5}$'),
  area       text not null check (length(trim(area)) between 2 and 80),
  label      text not null default '' check (length(label) <= 80),
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists partner_qr_spots_broker_idx on public.partner_qr_spots (broker_id, created_at desc);
alter table public.partner_storefront_views add column if not exists spot_id uuid references public.partner_qr_spots (id) on delete set null;

create or replace function public.partner_add_spot(p_area text, p_label text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c   text;
  i   int;
  rec public.partner_qr_spots;
begin
  if not public.is_approved_partner() then raise exception 'Only approved partners have posters.' using errcode = '42501'; end if;
  if length(trim(coalesce(p_area, ''))) < 2 then raise exception 'Pick the area where you will paste it.' using errcode = '22023'; end if;
  for i in 1..25 loop
    select string_agg(substr('abcdefghjkmnpqrstuvwxyz23456789', 1 + floor(random() * 31)::int, 1), '') into c from generate_series(1, 5);
    begin
      insert into public.partner_qr_spots (broker_id, code, area, label)
      values (auth.uid(), c, left(trim(p_area), 80), left(trim(coalesce(p_label, '')), 80))
      returning * into rec;
      exit;
    exception when unique_violation then c := null;
    end;
  end loop;
  return jsonb_build_object('id', rec.id, 'code', rec.code, 'area', rec.area, 'label', rec.label);
end;
$$;

create or replace function public.partner_remove_spot(p_id uuid)
returns void
language sql
security definer
set search_path = public
as $$ update public.partner_qr_spots set active = false where id = p_id and broker_id = auth.uid(); $$;

/** A visit, with the poster spot it was scanned from (if any). Replaces the 3-argument call. */
create or replace function public.partner_storefront_view(p_code text, p_visitor text, p_source text, p_spot text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  bid uuid := public.storefront_broker(p_code);
  who text := coalesce(auth.uid()::text, left(trim(coalesce(p_visitor, '')), 64));
  sp  uuid;
begin
  if bid is null or bid = auth.uid() or length(who) < 8 then return; end if;
  select s.id into sp from public.partner_qr_spots s where s.code = lower(trim(coalesce(p_spot, ''))) and s.broker_id = bid;
  insert into public.partner_storefront_views (broker_id, visitor, source, user_id, spot_id)
  values (bid, who, case when p_source = 'qr' or sp is not null then 'qr' else 'link' end, auth.uid(), sp)
  on conflict (broker_id, visitor, day) do nothing;
end;
$$;

/** The broker's dashboard: QR scans (by day and by area), leads, lists, what tenants like, and the latest activity. */
create or replace function public.partner_insights()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  uid   uuid := auth.uid();
  today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if not public.is_approved_partner() then raise exception 'Only approved partners have a dashboard.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'storefront_code', (select code from public.partner_storefronts where broker_id = uid),
    'scans_total', (select count(*) from public.partner_storefront_views where broker_id = uid and source = 'qr'),
    'scans_week', (select count(*) from public.partner_storefront_views where broker_id = uid and source = 'qr' and day > today - 7),
    'visitors_week', (select count(distinct visitor) from public.partner_storefront_views where broker_id = uid and day > today - 7),
    'by_day', (select jsonb_agg(jsonb_build_object('day', d::date,
                 'scans', (select count(*) from public.partner_storefront_views v where v.broker_id = uid and v.day = d::date and v.source = 'qr'),
                 'visits', (select count(*) from public.partner_storefront_views v where v.broker_id = uid and v.day = d::date)) order by d)
               from generate_series(today - 13, today, interval '1 day') d),
    'by_area', coalesce((
      select jsonb_agg(jsonb_build_object('area', area, 'scans', scans, 'week', week) order by scans desc)
        from (select coalesce(s.area, 'Not tagged') as area, count(*) as scans, count(*) filter (where v.day > today - 7) as week
                from public.partner_storefront_views v
                left join public.partner_qr_spots s on s.id = v.spot_id
               where v.broker_id = uid and v.source = 'qr'
               group by 1) q), '[]'::jsonb),
    'spots', coalesce((
      select jsonb_agg(jsonb_build_object('id', s.id, 'code', s.code, 'area', s.area, 'label', s.label, 'created_at', s.created_at,
               'scans', (select count(*) from public.partner_storefront_views v where v.spot_id = s.id)) order by s.created_at desc)
        from public.partner_qr_spots s where s.broker_id = uid and s.active), '[]'::jsonb),
    'leads', jsonb_build_object(
      'total', (select count(*) from public.partner_leads where broker_id = uid) + (select count(*) from public.partner_tenants where broker_id = uid),
      'new_week', (select count(*) from public.partner_leads where broker_id = uid and created_at > now() - interval '7 days')
                  + (select count(*) from public.partner_tenants where broker_id = uid and created_at > now() - interval '7 days'),
      'via_qr', (select count(*) from public.partner_tenants where broker_id = uid and source = 'storefront'),
      'via_lists', (select count(*) from public.partner_tenants where broker_id = uid and source = 'curated')),
    'lists', (select jsonb_build_object(
                'sent', count(*), 'opened', count(*) filter (where l.opened_at is not null),
                'liked', coalesce(sum((select count(*) from public.partner_curated_actions a where a.list_id = l.id and a.action = 'liked')), 0),
                'skipped', coalesce(sum((select count(*) from public.partner_curated_actions a where a.list_id = l.id and a.action = 'skipped')), 0))
              from public.partner_curated_lists l where l.broker_id = uid),
    'top_liked', coalesce((
      select jsonb_agg(jsonb_build_object('property_id', i.property_id, 'flat_type', i.flat_type, 'area', i.area, 'rent', i.rent,
               'cover_image_url', i.cover_image_url, 'images', i.images, 'likes', q.likes, 'skips', q.skips) order by q.likes desc, q.skips)
        from (select property_id, count(*) filter (where kind = 'like') as likes, count(*) filter (where kind = 'skip') as skips
                from (select a.property_id, case when a.action = 'liked' then 'like' else 'skip' end as kind
                        from public.partner_curated_actions a join public.partner_curated_lists l on l.id = a.list_id where l.broker_id = uid
                      union all
                      select sl.property_id, 'like' from public.partner_storefront_likes sl where sl.broker_id = uid) x
               group by property_id
               order by 2 desc, 3
               limit 8) q
        join public.inventory i on i.property_id = q.property_id), '[]'::jsonb),
    'activity', coalesce((
      select jsonb_agg(e order by e ->> 'at' desc) from (
        select jsonb_build_object('kind', a.action, 'at', a.at, 'who', coalesce(nullif(t.name, ''), nullif(l.lead_name, ''), 'Tenant'),
                                  'phone', t.phone, 'property_id', a.property_id, 'flat_type', i.flat_type, 'area', i.area,
                                  'link', '/curated/' || l.id::text) as e
          from public.partner_curated_actions a
          join public.partner_curated_lists l on l.id = a.list_id and l.broker_id = uid
          left join public.partner_tenants t on t.id = l.tenant_id
          left join public.inventory i on i.property_id = a.property_id
        union all
        select jsonb_build_object('kind', 'liked', 'at', sl.created_at, 'who', coalesce(nullif(up.name, ''), 'Tenant'), 'phone', up.phone,
                                  'property_id', sl.property_id, 'flat_type', i.flat_type, 'area', i.area, 'link', '/qr', 'via', 'qr')
          from public.partner_storefront_likes sl
          left join public.user_profiles up on up.id = sl.user_id
          left join public.inventory i on i.property_id = sl.property_id
         where sl.broker_id = uid
        order by 1 desc
        limit 30) q), '[]'::jsonb)
  );
end;
$$;

/** For link previews (Facebook, WhatsApp): who sent the list and how many homes — no side effects. */
create or replace function public.partner_curated_preview(p_token text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'broker', bp.name, 'count', cardinality(l.property_ids),
    'cover', (select coalesce(nullif(i.cover_image_url, ''), i.images[1]) from public.inventory i where i.property_id = l.property_ids[1]))
    from public.partner_curated_lists l left join public.broker_partners bp on bp.user_id = l.broker_id
   where l.token = p_token;
$$;

alter table public.partner_qr_spots enable row level security;
drop policy if exists "staff read" on public.partner_qr_spots;
create policy "staff read" on public.partner_qr_spots for select to authenticated using (public.is_crm_staff());
revoke all on public.partner_qr_spots from public, anon, authenticated;
grant select on public.partner_qr_spots to authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'public.partner_add_spot(text, text)', 'public.partner_remove_spot(uuid)', 'public.partner_insights()',
    'public.partner_storefront_view(text, text, text, text)', 'public.partner_curated_preview(text)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
grant execute on function public.partner_storefront_view(text, text, text, text) to anon;
grant execute on function public.partner_curated_preview(text) to anon;

commit;
