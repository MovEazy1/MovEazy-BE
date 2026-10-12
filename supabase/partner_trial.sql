-- Trial Premium: every Premium feature, free, for brokers MovEazy onboards —
-- except unlimited MovEazy leads (partner_has_paid_premium in
-- partner_moveazy_leads.sql), where a trial partner is treated like a free one.
--
--   · The CRM adds a broker by email (Brokers → Partners → Trial Premium).
--     Already signed up: the trial starts now. Not yet: it waits, and starts —
--     and the broker is approved — the moment they sign in with that email.
--   · 30 days by default. The CRM sees days left, can set them to any number,
--     add +10 / +20, or end it. Any increase is told to the partner once, in
--     one pop-up with the total.
--   · The trial is an ordinary Premium entitlement with plan 'trial', so every
--     Premium check already lets it through. partner_status() tells the app
--     about it apart from a paid plan (plan = paid only).
--   · Paying during a trial: paid Premium starts at once and the unused trial
--     days are added on at the end.
--
-- Replaces partner_status / partner_activate_payment (partner_launch.sql) and
-- partner_admin_grant_tier / partner_admin_list (partner_schema.sql): run this
-- after both, and after partner_moveazy_leads.sql. Safe to re-run.

begin;

create table if not exists public.partner_trials (
  email           text primary key check (email = lower(email) and email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  user_id         uuid references auth.users (id) on delete set null,
  days            int not null default 30 check (days between 1 and 365),  -- for an invite not started yet
  entitlement_id  uuid references public.partner_entitlements (id) on delete set null,
  started_at      timestamptz,
  ends_at         timestamptz,
  converted_at    timestamptz,       -- paid Premium took over
  welcome_seen_at timestamptz,
  extended_unseen int not null default 0,
  ended_seen_at   timestamptz,
  added_by        text not null default '',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create unique index if not exists partner_trials_user_uq on public.partner_trials (user_id) where user_id is not null;
alter table public.partner_trials enable row level security;
revoke all on table public.partner_trials from anon, authenticated;

-- ── Internal ────────────────────────────────────────────────────────────────

/** Start an invite's trial, if its broker has signed up. Approves them too. */
create or replace function public.partner_trial_start(p_email text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  t   public.partner_trials;
  uid uuid;
  ent uuid;
begin
  select * into t from public.partner_trials where email = lower(p_email) for update;
  if t.email is null or t.started_at is not null or t.converted_at is not null then return; end if;
  uid := coalesce(t.user_id, (select bp.user_id from public.broker_partners bp where lower(bp.email) = t.email limit 1));
  if uid is null then return; end if;

  update public.broker_partners
     set status = 'approved', approved_at = now(), approved_by = 'trial', updated_at = now()
   where user_id = uid and status = 'pending';

  -- Already paying: nothing to try.
  if exists (select 1 from public.partner_entitlements e where e.user_id = uid and e.tier = 'moveazy_inventory'
               and e.plan <> 'trial' and now() < e.ends_at) then
    update public.partner_trials set user_id = uid, converted_at = now(), updated_at = now() where email = t.email;
    return;
  end if;

  insert into public.partner_entitlements (user_id, tier, plan, starts_at, ends_at, source, source_ref, granted_by)
  values (uid, 'moveazy_inventory', 'trial', now(), now() + make_interval(days => t.days), 'trial', t.email, t.added_by)
  returning id into ent;
  update public.partner_trials
     set user_id = uid, entitlement_id = ent, started_at = now(), ends_at = now() + make_interval(days => t.days), updated_at = now()
   where email = t.email;
end;
$$;

/** Move a started trial's end. An increase is remembered for the partner's pop-up. */
create or replace function public.partner_trial_move_end(p_email text, p_end timestamptz)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  t    public.partner_trials;
  gain int;
begin
  select * into t from public.partner_trials where email = p_email for update;
  if t.converted_at is not null then
    raise exception 'They have paid Premium now — the trial is over.' using errcode = '22023';
  end if;
  gain := floor(extract(epoch from (p_end - greatest(t.ends_at, now()))) / 86400 + 0.01)::int;
  -- Ending exactly then, even moments after it started (a row must start before it ends).
  update public.partner_entitlements
     set starts_at = least(starts_at, p_end - interval '1 second'), ends_at = p_end
   where id = t.entitlement_id;
  update public.partner_trials
     set ends_at = p_end,
         extended_unseen = extended_unseen + greatest(gain, 0),
         -- Back on after it had ended: the "ended" pop-up can show again next time.
         ended_seen_at = case when p_end > now() then null else ended_seen_at end,
         updated_at = now()
   where email = p_email;
end;
$$;

/** Paid Premium is starting: end the trial now. → the trial time that was left. */
create or replace function public.partner_trial_convert(p_user uuid)
returns interval
language plpgsql
security definer
set search_path = public
as $$
declare
  t    public.partner_trials;
  left_over interval := interval '0';
begin
  select * into t from public.partner_trials where user_id = p_user and converted_at is null for update;
  if t.email is null then return left_over; end if;
  if t.started_at is not null and t.ends_at > now() then
    left_over := t.ends_at - now();
    update public.partner_entitlements set starts_at = least(starts_at, now() - interval '1 second'), ends_at = now()
     where id = t.entitlement_id;
  end if;
  update public.partner_trials
     set converted_at = now(), ends_at = least(coalesce(ends_at, now()), now()), updated_at = now()
   where email = t.email;
  return left_over;
end;
$$;

revoke all on function public.partner_trial_start(text) from public, anon, authenticated;
revoke all on function public.partner_trial_move_end(text, timestamptz) from public, anon, authenticated;
revoke all on function public.partner_trial_convert(uuid) from public, anon, authenticated;

-- A broker invited by email signs up: their trial starts.
create or replace function public.partner_trial_on_signup()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(new.email, '') <> '' and exists (select 1 from public.partner_trials t where t.email = lower(new.email) and t.started_at is null) then
    perform public.partner_trial_start(lower(new.email));
  end if;
  return new;
end;
$$;
revoke all on function public.partner_trial_on_signup() from public, anon, authenticated;
drop trigger if exists broker_partners_trial on public.broker_partners;
create trigger broker_partners_trial after insert or update of email on public.broker_partners
  for each row execute function public.partner_trial_on_signup();

-- ── CRM (partners.manage) ───────────────────────────────────────────────────

create or replace function public.crm_trial_list()
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
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'email', t.email, 'user_id', t.user_id, 'name', bp.name, 'phone', bp.phone, 'agency', bp.agency,
             'status', case when t.converted_at is not null then 'paid'
                            when t.started_at is null then 'invited'
                            when t.ends_at > now() then 'active' else 'ended' end,
             'started_at', t.started_at, 'ends_at', t.ends_at,
             'days_left', case when t.started_at is null then t.days
                               when t.ends_at > now() then ceil(extract(epoch from (t.ends_at - now())) / 86400)::int else 0 end,
             'added_by', t.added_by, 'created_at', t.created_at)
           order by (t.started_at is null) desc, t.ends_at nulls first, t.created_at desc)
      from public.partner_trials t
      left join public.broker_partners bp on bp.user_id = t.user_id), '[]'::jsonb);
end;
$$;

/** Add brokers by email. → { added, started, skipped: [{email, why}] } */
create or replace function public.crm_trial_add(p_emails text[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  e       text;
  added   int := 0;
  started int := 0;
  skipped jsonb := '[]'::jsonb;
  actor   text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if not public.has_admin_scope('partners.manage') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  foreach e in array coalesce(p_emails, '{}') loop
    e := lower(btrim(e));
    continue when e = '';
    if e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
      skipped := skipped || jsonb_build_object('email', e, 'why', 'not an email');
    elsif exists (select 1 from public.partner_trials t where t.email = e) then
      skipped := skipped || jsonb_build_object('email', e, 'why', 'already on the list — use +10 / +20');
    else
      insert into public.partner_trials (email, added_by) values (e, actor);
      added := added + 1;
      perform public.partner_trial_start(e);
      if exists (select 1 from public.partner_trials t where t.email = e and t.started_at is not null) then started := started + 1; end if;
    end if;
  end loop;
  return jsonb_build_object('added', added, 'started', started, 'skipped', skipped);
end;
$$;

/** Set the days left (an invite: the days it will start with). */
create or replace function public.crm_trial_set_days(p_email text, p_days int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.partner_trials;
begin
  if not public.has_admin_scope('partners.manage') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  if p_days is null or p_days < 0 or p_days > 365 then
    raise exception 'Days left must be between 0 and 365.' using errcode = '22023';
  end if;
  select * into t from public.partner_trials where email = lower(p_email);
  if t.email is null then raise exception 'Not on the trial list.' using errcode = '22023'; end if;
  if t.started_at is null then
    if p_days = 0 then raise exception 'An invite needs at least 1 day — or remove it.' using errcode = '22023'; end if;
    update public.partner_trials set days = p_days, updated_at = now() where email = t.email;
  else
    perform public.partner_trial_move_end(t.email, now() + make_interval(days => p_days));
  end if;
end;
$$;

/** +10 / +20: on top of what's left (from today if it had ended). */
create or replace function public.crm_trial_add_days(p_email text, p_days int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.partner_trials;
begin
  if not public.has_admin_scope('partners.manage') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  if p_days is null or p_days < 1 or p_days > 365 then
    raise exception 'Add between 1 and 365 days.' using errcode = '22023';
  end if;
  select * into t from public.partner_trials where email = lower(p_email);
  if t.email is null then raise exception 'Not on the trial list.' using errcode = '22023'; end if;
  if t.started_at is null then
    update public.partner_trials set days = least(days + p_days, 365), updated_at = now() where email = t.email;
  else
    perform public.partner_trial_move_end(t.email, greatest(t.ends_at, now()) + make_interval(days => p_days));
  end if;
end;
$$;

/** End a trial now (an invite not started: removed). */
create or replace function public.crm_trial_end(p_email text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.partner_trials;
begin
  if not public.has_admin_scope('partners.manage') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  select * into t from public.partner_trials where email = lower(p_email);
  if t.email is null then return; end if;
  if t.started_at is null then
    delete from public.partner_trials where email = t.email;
  elsif t.converted_at is null and t.ends_at > now() then
    perform public.partner_trial_move_end(t.email, now());
  end if;
end;
$$;

-- ── The partner ─────────────────────────────────────────────────────────────

/** A pop-up was shown: 'welcome', 'extended' or 'ended'. */
create or replace function public.partner_trial_seen(p_what text)
returns void
language sql
security definer
set search_path = public
as $$
  update public.partner_trials
     set welcome_seen_at = case when p_what = 'welcome' then coalesce(welcome_seen_at, now()) else welcome_seen_at end,
         -- The welcome already says how many days there are.
         extended_unseen = case when p_what in ('welcome', 'extended') then 0 else extended_unseen end,
         ended_seen_at   = case when p_what = 'ended' then now() else ended_seen_at end
   where user_id = auth.uid();
$$;

/** Plan (paid only), trial, latest payment, profile and whether the congratulations page is due. */
create or replace function public.partner_status()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with cur as (
    select e.* from public.partner_entitlements e
     where e.user_id = auth.uid() and e.tier = 'moveazy_inventory' and e.plan <> 'trial' and now() >= e.starts_at and now() < e.ends_at
     order by e.ends_at desc limit 1
  ), last_ent as (
    select max(e.created_at) as at, max(e.ends_at) as until from public.partner_entitlements e
     where e.user_id = auth.uid() and e.tier = 'moveazy_inventory' and e.plan <> 'trial' and e.ends_at > now()
  ), tr as (
    select t.* from public.partner_trials t where t.user_id = auth.uid() and t.started_at is not null
  )
  select jsonb_build_object(
    'plan', jsonb_build_object(
      'active', exists (select 1 from cur),
      'plan_id', (select c.plan from cur c),
      'label', (select pl.label from cur c join public.partner_plans pl on pl.id = c.plan),
      'until', (select until from last_ent)),
    'trial', (select jsonb_build_object(
                'active', t.converted_at is null and t.ends_at > now(),
                'ends_at', t.ends_at,
                'days_left', case when t.converted_at is null and t.ends_at > now()
                                  then ceil(extract(epoch from (t.ends_at - now())) / 86400)::int else 0 end,
                'welcome_due', t.converted_at is null and t.ends_at > now() and t.welcome_seen_at is null,
                'extended_days', case when t.converted_at is null and t.ends_at > now() then t.extended_unseen else 0 end,
                'ended_due', t.converted_at is null and t.ends_at <= now() and not exists (select 1 from cur)
                             and (t.ended_seen_at is null or t.ended_seen_at < t.ends_at))
                from tr t),
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

-- ── Paid Premium takes over a trial ─────────────────────────────────────────

-- Replaced again by partner_premium_upi.sql (per-plan referral rewards); run that after this file.
/** As in partner_launch.sql, plus: a running trial ends and its unused days are added on. */
create or replace function public.partner_activate_payment(p_payment uuid, p_source text, p_gateway_payment text, p_actor text)
returns public.partner_payments
language plpgsql
security definer
set search_path = public
as $$
declare
  pay   public.partner_payments;
  start timestamptz;
  extra interval;
  ent   uuid;
  bp    public.broker_partners;
  ref   public.broker_partners;
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

/** As in partner_schema.sql (CRM "Give Premium" / "+1 month" / "End Premium"), trial-aware. */
create or replace function public.partner_admin_grant_tier(p_user uuid, p_tier text, p_months int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  from_ts timestamptz;
  extra   interval := interval '0';
begin
  if not public.has_admin_scope('partners.manage') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  if p_months <= 0 then
    delete from public.partner_entitlements
     where user_id = p_user and tier = p_tier and starts_at > now();
    update public.partner_entitlements set starts_at = least(starts_at, now() - interval '1 second'), ends_at = now()
     where user_id = p_user and tier = p_tier and ends_at > now();
    update public.partner_trials set ends_at = least(ends_at, now()), updated_at = now()
     where user_id = p_user and started_at is not null and converted_at is null and ends_at > now();
    return;
  end if;
  select greatest(now(), coalesce(max(ends_at), now())) into from_ts
    from public.partner_entitlements where user_id = p_user and tier = p_tier and plan <> 'trial';
  if p_tier = 'moveazy_inventory' then extra := public.partner_trial_convert(p_user); end if;
  insert into public.partner_entitlements (user_id, tier, plan, starts_at, ends_at, source, granted_by)
  values (p_user, p_tier, 'monthly', from_ts, from_ts + make_interval(months => least(p_months, 24)) + extra,
          'manual', lower(coalesce(auth.jwt() ->> 'email', '')));
end;
$$;

/** As in partner_schema.sql, with Premium split into paid and trial. */
drop function if exists public.partner_admin_list();
create function public.partner_admin_list()
returns table (user_id uuid, name text, phone text, email text, agency text, status text,
               created_at timestamptz, approved_at timestamptz, approved_by text,
               listing_count int, group_count int, premium_until timestamptz, client_share_pct numeric,
               trial_until timestamptz)
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
           where e.user_id = p.user_id and e.tier = 'moveazy_inventory' and e.plan = 'trial' and now() < e.ends_at)
    from public.broker_partners p
   where public.is_crm_staff()
   order by case p.status when 'pending' then 0 when 'approved' then 1 else 2 end, p.created_at desc;
$$;

-- ── Grants ──────────────────────────────────────────────────────────────────
revoke all on function public.crm_trial_list() from public, anon;
revoke all on function public.crm_trial_add(text[]) from public, anon;
revoke all on function public.crm_trial_set_days(text, int) from public, anon;
revoke all on function public.crm_trial_add_days(text, int) from public, anon;
revoke all on function public.crm_trial_end(text) from public, anon;
revoke all on function public.partner_trial_seen(text) from public, anon;
revoke all on function public.partner_status() from public, anon;
revoke all on function public.partner_activate_payment(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.partner_admin_grant_tier(uuid, text, int) from public, anon;
revoke all on function public.partner_admin_list() from public, anon;
grant execute on function public.crm_trial_list() to authenticated;
grant execute on function public.crm_trial_add(text[]) to authenticated;
grant execute on function public.crm_trial_set_days(text, int) to authenticated;
grant execute on function public.crm_trial_add_days(text, int) to authenticated;
grant execute on function public.crm_trial_end(text) to authenticated;
grant execute on function public.partner_trial_seen(text) to authenticated;
grant execute on function public.partner_status() to authenticated;
grant execute on function public.partner_admin_grant_tier(uuid, text, int) to authenticated;
grant execute on function public.partner_admin_list() to authenticated;

commit;
