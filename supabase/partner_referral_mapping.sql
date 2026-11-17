-- Who brought a partner in — made to stick — and what the partners they
-- brought are doing; plus the CRM mapping a listing to a partner.
--
--   · The ?ref= code lived only in the browser it was opened in, so brokers
--     who opened an invite inside WhatsApp and signed up in Chrome (or were
--     onboarded by the partner desk) were never mapped. Now:
--       1. a code typed on the referral landing is kept against the mobile
--          number (partner_prospects) and picked up whatever device they
--          sign up on (partner_signup_meta, as before) — and the route is
--          recorded (broker_partners.referred_via: link | phone);
--       2. "Who invited you?" in the partner app: a referrer's code or mobile,
--          only within 20 minutes of first sign-in, once. It waits for the
--          CRM to approve or reject (partner_referral_claims; via = claim);
--       3. the CRM sets or changes any partner's referrer (via = crm).
--     A referrer without a code (codes came with Premium) gets one made.
--   · partner_my_referrals (the Wallet) adds, per partner brought in: flats
--     uploaded, visits they did, visits on their flats, MovEazy-lead
--     closures; and team totals. partner_my_team() is the light version for
--     the Home dashboard, with the "Who invited you?" state.
--   · crm_listing_set_partner: the CRM maps a listing to any approved partner
--     — it becomes theirs (partner_listings), shared with all brokers at the
--     program's property share so it stays in everyone's pool. Flats a
--     partner added themself stay theirs; CRM-made mappings can be changed or
--     cleared. Mappings never end with Premium.
--
-- Replaces partner_signup_meta (partner_launch.sql) and partner_my_referrals
-- (partner_referral_commission.sql): run after those. Safe to re-run.

begin;

-- ── Columns and tables ──────────────────────────────────────────────────────
alter table public.broker_partners add column if not exists referred_via text not null default '';
alter table public.partner_listings
  add column if not exists mapped_by text not null default '',   -- CRM email when the CRM mapped it; '' = the partner added it
  add column if not exists prev_broker_id uuid;                   -- inventory.broker_id before the CRM mapped it

create table if not exists public.partner_referral_claims (
  user_id     uuid primary key references auth.users (id) on delete cascade,
  referrer_id uuid not null references auth.users (id) on delete cascade,
  entered     text not null default '',
  status      text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  created_at  timestamptz not null default now(),
  decided_at  timestamptz,
  decided_by  text not null default ''
);
alter table public.partner_referral_claims enable row level security;
revoke all on public.partner_referral_claims from anon, authenticated;

-- A notification kind for a flat the CRM gave a partner; the rest are kept.
do $$
declare
  d    text;
  vals text[];
begin
  select pg_get_constraintdef(oid) into d from pg_constraint where conname = 'partner_notifications_kind_check';
  if d is not null and position('listing_assigned' in d) = 0 then
    if d ~ '''\{' then
      vals := string_to_array(substring(d from '''\{([^}]*)\}'''), ',');
    else
      vals := array(select m[1] from regexp_matches(d, '''([a-z_]+)''', 'g') m);
    end if;
    vals := vals || array['listing_assigned'];
    alter table public.partner_notifications drop constraint partner_notifications_kind_check;
    execute format('alter table public.partner_notifications add constraint partner_notifications_kind_check check (kind = any (%L::text[]))', vals);
  end if;
end $$;

-- ── Helpers (internal) ──────────────────────────────────────────────────────

/** A partner's referral code, made if they have none (the CRM or a claim names them as a referrer). */
create or replace function public.partner_ensure_referral_code(p_user uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  c text;
  i int;
begin
  select referral_code into c from public.broker_partners where user_id = p_user;
  if c is not null then return c; end if;
  for i in 1..25 loop
    select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '')
      into c from generate_series(1, 6);
    begin
      update public.broker_partners set referral_code = c where user_id = p_user and referral_code is null;
      exit;
    exception when unique_violation then
      c := null;
    end;
  end loop;
  select referral_code into c from public.broker_partners where user_id = p_user;
  return c;
end;
$$;

/** Set (or with null, clear) who brought p_user in. Never themself, never someone they brought in. */
create or replace function public.partner_set_referrer(p_user uuid, p_referrer uuid, p_via text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  code text;
begin
  if not exists (select 1 from public.broker_partners where user_id = p_user) then
    raise exception 'No such partner.' using errcode = 'P0002';
  end if;
  if p_referrer is null then
    update public.broker_partners set referred_by = '', referred_via = '', updated_at = now() where user_id = p_user;
    return;
  end if;
  if p_referrer = p_user then
    raise exception 'A partner can''t be their own referrer.' using errcode = '22023';
  end if;
  if not exists (select 1 from public.broker_partners where user_id = p_referrer and status = 'approved') then
    raise exception 'The referrer must be an approved partner.' using errcode = '22023';
  end if;
  if public.partner_referrer_of(p_referrer) = p_user then
    raise exception 'They were brought in by this partner — a referral can''t go both ways.' using errcode = '22023';
  end if;
  code := public.partner_ensure_referral_code(p_referrer);
  update public.broker_partners set referred_by = code, referred_via = p_via, updated_at = now() where user_id = p_user;
end;
$$;

/** One partner's numbers: flats uploaded, visits they did, visits on their flats, MovEazy-lead closures. */
create or replace function public.partner_member_stats(p_user uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'listings', (select count(*)::int from public.partner_listings l where l.broker_id = p_user),
    'visits_done',
      (select count(*)::int from public.partner_live_visits v where v.broker_id = p_user and v.status = 'done')
      + (select count(*)::int from public.partner_lead_assignments a
          where a.broker_id = p_user and a.status in ('visit', 'closed')
            and not exists (select 1 from public.partner_live_visits v
                             where v.broker_id = p_user and v.client_id = a.client_id and v.status = 'done')),
    'visits_on_flats', (select count(*)::int from public.visit_bookings b
                          join public.partner_listings l on l.property_id = b.property_id
                         where l.broker_id = p_user and b.status not in ('cancelled', 'preference')),
    'closures', (select count(*)::int from public.partner_lead_assignments a where a.broker_id = p_user and a.status = 'closed'));
$$;

-- ── Sign-up: where they came from (now also how the referral got there) ────

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
  ref text := upper(public.partner_clean_tag(p_ref, 12));
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
         referred_via = case when referred_by = '' and coalesce(nullif(pr.referred_by, ''), nullif(ref, '')) is not null
                             then case when coalesce(pr.referred_by, '') <> '' then 'phone' else 'link' end
                             else referred_via end,
         referred_by = case when referred_by = '' then coalesce(nullif(pr.referred_by, ''), ref) else referred_by end,
         utm = case when utm = '{}'::jsonb then coalesce(nullif(pr.utm, '{}'::jsonb), public.partner_clean_utm(p_utm)) else utm end
   where user_id = uid;

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

-- ── "Who invited you?" (partner app, 20 minutes after first sign-in) ───────

/** The caller's team at a glance, and whether they can still say who invited them. */
create or replace function public.partner_my_team()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  uid  uuid := auth.uid();
  me   public.broker_partners;
  cl   public.partner_referral_claims;
  ref  uuid;
  team jsonb;
begin
  if not public.is_approved_partner() then
    raise exception 'Only approved partners.' using errcode = '42501';
  end if;
  select * into me from public.broker_partners where user_id = uid;
  select * into cl from public.partner_referral_claims where user_id = uid;
  ref := public.partner_referrer_of(uid);
  select jsonb_build_object(
           'partners', count(*)::int,
           'listings', coalesce(sum((s ->> 'listings')::int), 0),
           'visits_done', coalesce(sum((s ->> 'visits_done')::int), 0),
           'visits_on_flats', coalesce(sum((s ->> 'visits_on_flats')::int), 0),
           'closures', coalesce(sum((s ->> 'closures')::int), 0))
    into team
    from (select public.partner_member_stats(bp.user_id) s
            from public.broker_partners bp
           where me.referral_code is not null and bp.referred_by = me.referral_code and bp.user_id <> uid) x;
  return jsonb_build_object(
    'team', team,
    'lifetime', coalesce((select sum(amount) from public.partner_referral_commissions
                           where referrer_id = uid and status in ('due', 'paid')), 0),
    'invited_by', (select coalesce(nullif(b.name, ''), 'A partner') from public.broker_partners b where b.user_id = ref),
    'claim', case when cl.user_id is null then null else jsonb_build_object(
               'status', cl.status, 'created_at', cl.created_at,
               'referrer', (select coalesce(nullif(b.name, ''), 'A partner') from public.broker_partners b where b.user_id = cl.referrer_id)) end,
    'claim_until', case when ref is null and coalesce(me.referred_by, '') = '' and cl.user_id is null
                         and now() < me.created_at + interval '20 minutes'
                        then me.created_at + interval '20 minutes' end);
end;
$$;

/**
 * "Who invited you?": a referrer's code or mobile number. Once, within 20
 * minutes of first sign-in; the CRM approves or rejects it.
 * → { referrer: their first name }
 */
create or replace function public.partner_claim_referrer(p_input text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid  uuid := auth.uid();
  me   public.broker_partners;
  raw  text := trim(coalesce(p_input, ''));
  ph   text;
  r    public.broker_partners;
begin
  if not public.is_approved_partner() then
    raise exception 'Only approved partners.' using errcode = '42501';
  end if;
  select * into me from public.broker_partners where user_id = uid;
  if coalesce(me.referred_by, '') <> '' or public.partner_referrer_of(uid) is not null then
    raise exception 'Your referrer is already saved.' using errcode = '22023';
  end if;
  if exists (select 1 from public.partner_referral_claims where user_id = uid) then
    raise exception 'You''ve already told us who invited you.' using errcode = '22023';
  end if;
  if now() >= me.created_at + interval '20 minutes' then
    raise exception 'This can only be added in your first 20 minutes. Ask MovEazy support to add it.' using errcode = '22023';
  end if;
  if raw = '' then
    raise exception 'Enter their referral code or mobile number.' using errcode = '22023';
  end if;

  if regexp_replace(raw, '\D', '', 'g') ~ '^(91)?[6-9][0-9]{9}$' and raw !~ '[A-Za-z]' then
    ph := public.normalize_mobile(raw);
    select * into r from public.broker_partners b
     where b.status = 'approved' and b.user_id <> uid and (b.phone = ph or coalesce(b.alt_phone, '') = ph)
     limit 1;
  else
    select * into r from public.broker_partners b
     where b.status = 'approved' and b.user_id <> uid and b.referral_code = upper(regexp_replace(raw, '\s', '', 'g'))
     limit 1;
  end if;
  if r.user_id is null then
    raise exception 'No MovEazy partner with that code or number. Check it and try again.' using errcode = 'P0002';
  end if;
  if public.partner_referrer_of(r.user_id) = uid then
    raise exception 'That partner joined through you.' using errcode = '22023';
  end if;

  insert into public.partner_referral_claims (user_id, referrer_id, entered)
  values (uid, r.user_id, left(raw, 40));
  return jsonb_build_object('referrer', split_part(coalesce(nullif(trim(r.name), ''), 'Partner'), ' ', 1));
end;
$$;

-- ── CRM: referrers ──────────────────────────────────────────────────────────

/** Every partner's referrer and how it was set, for the partners table. */
create or replace function public.crm_partner_referrers()
returns table (user_id uuid, referrer_id uuid, referrer_name text, via text)
language sql
stable
security definer
set search_path = public
as $$
  select b.user_id, r.user_id, coalesce(nullif(r.name, ''), 'Partner'), b.referred_via
    from public.broker_partners b
    join public.broker_partners r on r.referral_code = nullif(b.referred_by, '') and r.user_id <> b.user_id
   where public.is_crm_staff();
$$;

/** The CRM sets, changes or (null) clears who brought a partner in. A pending claim for them is settled. */
create or replace function public.crm_partner_set_referrer(p_user uuid, p_referrer uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.has_admin_scope('partners.manage') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  perform public.partner_set_referrer(p_user, p_referrer, 'crm');
  update public.partner_referral_claims
     set status = case when referrer_id = p_referrer then 'approved' else 'rejected' end,
         decided_at = now(), decided_by = lower(coalesce(auth.jwt() ->> 'email', ''))
   where user_id = p_user and status = 'pending';
end;
$$;

/** "Added by the incoming partner": claims waiting, and those decided in the last 30 days. */
create or replace function public.crm_referral_claims()
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
             'user_id', c.user_id, 'status', c.status, 'entered', c.entered, 'created_at', c.created_at,
             'decided_at', c.decided_at, 'decided_by', c.decided_by,
             'partner', coalesce(nullif(p.name, ''), 'Partner'), 'partner_phone', coalesce(p.phone, ''), 'joined_at', p.created_at,
             'referrer_id', c.referrer_id, 'referrer', coalesce(nullif(r.name, ''), 'Partner'), 'referrer_phone', coalesce(r.phone, ''))
           order by case c.status when 'pending' then 0 else 1 end, c.created_at desc)
      from public.partner_referral_claims c
      left join public.broker_partners p on p.user_id = c.user_id
      left join public.broker_partners r on r.user_id = c.referrer_id
     where c.status = 'pending' or c.decided_at > now() - interval '30 days'), '[]'::jsonb);
end;
$$;

create or replace function public.crm_referral_claim_decide(p_user uuid, p_approve boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.partner_referral_claims;
  who text;
begin
  if not public.has_admin_scope('partners.manage') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  select * into c from public.partner_referral_claims where user_id = p_user and status = 'pending' for update;
  if c.user_id is null then raise exception 'That request was already decided.' using errcode = '22023'; end if;
  if p_approve then
    perform public.partner_set_referrer(c.user_id, c.referrer_id, 'claim');
  end if;
  update public.partner_referral_claims
     set status = case when p_approve then 'approved' else 'rejected' end,
         decided_at = now(), decided_by = lower(coalesce(auth.jwt() ->> 'email', ''))
   where user_id = c.user_id;
  select coalesce(nullif(name, ''), 'your referrer') into who from public.broker_partners where user_id = c.referrer_id;
  insert into public.partner_notifications (broker_id, kind, title, body, link)
  values (c.user_id, 'referral',
          case when p_approve then 'Referrer confirmed' else 'Referrer not confirmed' end,
          case when p_approve then who || ' is saved as the partner who brought you to MovEazy.'
               else 'We couldn''t confirm ' || who || ' as your referrer. Contact MovEazy support if this is wrong.' end,
          '/');
end;
$$;

-- ── CRM: map a listing to a partner ────────────────────────────────────────

/**
 * Give a listing to an approved partner (or, with null, take a CRM-made
 * mapping back). A flat the partner added themself can't be moved.
 * → { partner: name | null }
 */
create or replace function public.crm_listing_set_partner(p_property text, p_partner uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  inv   public.inventory;
  pl    public.partner_listings;
  owner text;
  who   public.broker_partners;
  share numeric;
begin
  if not (public.has_admin_scope('crm.properties.write') or public.has_admin_scope('partners.manage')) then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  select * into inv from public.inventory where property_id = p_property for update;
  if inv.property_id is null then raise exception 'No listing %.', p_property using errcode = 'P0002'; end if;
  select * into pl from public.partner_listings where property_id = p_property for update;

  if pl.property_id is not null and pl.mapped_by = '' then
    select coalesce(nullif(name, ''), 'a partner') into owner from public.broker_partners where user_id = pl.broker_id;
    raise exception '% added this flat in the partner app — it stays theirs.', owner using errcode = '22023';
  end if;

  if p_partner is null then
    if pl.property_id is not null then
      delete from public.partner_listings where property_id = p_property;
      update public.inventory set broker_id = pl.prev_broker_id where property_id = p_property and broker_id is not distinct from pl.broker_id;
    end if;
    return jsonb_build_object('partner', null);
  end if;

  select * into who from public.broker_partners where user_id = p_partner and status = 'approved';
  if who.user_id is null then raise exception 'Pick an approved partner.' using errcode = '22023'; end if;
  if pl.broker_id = p_partner then return jsonb_build_object('partner', who.name); end if;

  if pl.property_id is null then
    insert into public.partner_listings (property_id, broker_id, mapped_by, prev_broker_id)
    values (p_property, p_partner, lower(coalesce(auth.jwt() ->> 'email', '')), inv.broker_id);
  else
    -- A new partner: the old one's group shares go with them.
    delete from public.partner_group_shares where property_id = p_property;
    update public.partner_listings
       set broker_id = p_partner, mapped_by = lower(coalesce(auth.jwt() ->> 'email', '')), updated_at = now()
     where property_id = p_property;
  end if;
  -- Still in every Premium partner's pool, at the program's property share.
  select ps.property_share into share from public.program_settings ps where ps.id = 1;
  insert into public.partner_platform_shares (property_id, share_pct)
  values (p_property, coalesce(share, 50))
  on conflict (property_id) do nothing;
  update public.inventory set broker_id = p_partner where property_id = p_property;

  insert into public.partner_notifications (broker_id, kind, title, body, link)
  values (p_partner, 'listing_assigned', 'A flat was added to your listings',
          trim(both ' ·' from concat_ws(' · ',
            nullif(case when coalesce(inv.bedrooms, 0) > 0 then inv.bedrooms || ' BHK' end, ''),
            nullif(inv.area, ''),
            case when coalesce(inv.rent, 0) > 0 then '₹' || to_char(inv.rent, 'FM99,99,999') end))
            || '. MovEazy gave it to you — it''s in My Inventory.',
          '/property/' || p_property);
  return jsonb_build_object('partner', who.name);
end;
$$;

-- ── The partner's Wallet, now with each partner's numbers ──────────────────

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
  joined jsonb;
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
  joined := coalesce((
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
               'stats', public.partner_member_stats(bp.user_id),
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
       where me.referral_code is not null and bp.referred_by = me.referral_code and bp.user_id <> uid), '[]'::jsonb);
  return jsonb_build_object(
    'code', code,
    'can_refer', code is not null,
    'premium', public.partner_premium_at(uid, now()),
    'rates', jsonb_build_object('direct', direct, 'shared', shared),
    'joined', joined,
    'team', jsonb_build_object(
      'listings', coalesce((select sum((j -> 'stats' ->> 'listings')::int) from jsonb_array_elements(joined) j), 0),
      'visits_done', coalesce((select sum((j -> 'stats' ->> 'visits_done')::int) from jsonb_array_elements(joined) j), 0),
      'visits_on_flats', coalesce((select sum((j -> 'stats' ->> 'visits_on_flats')::int) from jsonb_array_elements(joined) j), 0),
      'closures', coalesce((select sum((j -> 'stats' ->> 'closures')::int) from jsonb_array_elements(joined) j), 0)),
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
    'public.partner_ensure_referral_code(uuid)', 'public.partner_set_referrer(uuid, uuid, text)', 'public.partner_member_stats(uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
  foreach f in array array[
    'public.partner_signup_meta(text, text, jsonb)', 'public.partner_my_team()', 'public.partner_claim_referrer(text)',
    'public.crm_partner_referrers()', 'public.crm_partner_set_referrer(uuid, uuid)', 'public.crm_referral_claims()',
    'public.crm_referral_claim_decide(uuid, boolean)', 'public.crm_listing_set_partner(text, uuid)', 'public.partner_my_referrals()'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

commit;
