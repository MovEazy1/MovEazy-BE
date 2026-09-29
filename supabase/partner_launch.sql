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
