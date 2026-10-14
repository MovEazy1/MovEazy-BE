-- ─────────────────────────────────────────────────────────────────────────────
-- Website leads — tenants on moveazy.co.in who show interest in a partner's
-- flat become that partner's MovEazy lead (fe: lib/websiteLeads.js; the broker
-- sees them under Leads → MovEazy leads tagged "MovEazy Website", on the flat,
-- and as a "New lead" card on Home; the CRM on the client and in Broker leads).
--
-- Run in the Supabase SQL editor AFTER partner_moveazy_leads.sql,
-- partner_referral_commission.sql (partner_premium_at), flat_insights.sql,
-- partner_tenant_care.sql and partner_qr_leads.sql. Safe to re-run.
--
-- What counts as interest in a partner's (published) flat, from a tenant —
-- never a partner, CRM staff or the flat's owner:
--   liked    ♥ on a curated list or on the first 5 after the preferences
--            (crm_shortlists 'liked', listing_reactions 'like')
--   visit    a visit booked or asked for on the flat (visit_bookings,
--            crm_shortlists 'visit_scheduled')
--   opened   the flat's page opened while signed in (flat_view), or earlier
--            on the same phone and claimed on sign-in (flat_claim_views)
--   contact  "Ask the broker to call me" on the flat's page, or WhatsApp / Call
--            tapped there (flat_contact_tap)
--   (A requirement that only fits a flat is not interest: no lead for that.)
-- The tenant needs a mobile number on their CRM client, and must be MovEazy's
-- (attributed_to 'moveazy'): a tenant another broker brought stays theirs.
--
-- The partner on trial or paid Premium gets them as a MovEazy lead (a "website"
-- pack request per broker holds them): MovEazy's usual share when it closes
-- (30% direct / 20% shared, as for Premium leads), not exclusive — it counts as
-- one of the brokers a MovEazy lead can go to. A free-plan partner gets a
-- teaser ("go Premium to see who"); the lead is kept for them 7 days and
-- unlocks the moment they start a trial or Premium.
--
-- Also: partner_flat_ids() for ranking (trial/Premium partners' flats float up
-- in the first 5 and the CRM's curation), partner_flat_leads() for the flat's
-- page in the partner app, crm_website_leads() for the CRM, and the broker's
-- calls/WhatsApps on a MovEazy lead logged on the CRM client.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

-- ── Columns, tables, kinds ──────────────────────────────────────────────────
alter table public.partner_lead_requests drop constraint if exists partner_lead_requests_pack_check;
alter table public.partner_lead_requests add constraint partner_lead_requests_pack_check
  check (pack in ('free10', 'paid30', 'premium', 'website'));

create table if not exists public.partner_website_interest (
  id            uuid primary key default gen_random_uuid(),
  broker_id     uuid not null references auth.users (id) on delete cascade,
  client_id     uuid not null references public.crm_clients (id) on delete cascade,
  assignment_id uuid references public.partner_lead_assignments (id) on delete set null,
  property_id   text not null references public.inventory (property_id) on delete cascade,
  kind          text not null check (kind in ('liked', 'opened', 'visit', 'contact', 'match')),
  held          boolean not null default false, -- free plan: kept 7 days for an upgrade
  detail        text not null default '',
  created_at    timestamptz not null default now(),
  unique (broker_id, client_id, property_id, kind)
);
create index if not exists partner_website_interest_broker_idx on public.partner_website_interest (broker_id, created_at desc);
create index if not exists partner_website_interest_property_idx on public.partner_website_interest (property_id);
alter table public.partner_website_interest enable row level security;
revoke all on table public.partner_website_interest from anon, authenticated;

do $$
declare
  kinds text[];
begin
  select array_agg(distinct m[1]) into kinds
    from pg_constraint c, regexp_matches(pg_get_constraintdef(c.oid), '''([a-z_]+)''', 'g') m
   where c.conname = 'partner_notifications_kind_check';
  if kinds is null then return; end if;
  kinds := array(select distinct k from unnest(kinds || array['website_lead', 'website_teaser']) k order by 1);
  alter table public.partner_notifications drop constraint partner_notifications_kind_check;
  execute format('alter table public.partner_notifications add constraint partner_notifications_kind_check check (kind in (%s))',
                 (select string_agg(quote_literal(k), ', ') from unnest(kinds) k));
end $$;

-- ── Internal ────────────────────────────────────────────────────────────────

/** A tenant, not a partner, CRM staff or the flat's owner. */
create or replace function public.website_tenant_ok(p_user uuid, p_property text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_user is not null
     and not exists (select 1 from public.broker_partners b where b.user_id = p_user)
     and not exists (select 1 from auth.users u
                      where u.id = p_user
                        and (lower(coalesce(u.email, '')) = 'yatharth200018@gmail.com'
                             or exists (select 1 from public.admin_roles r
                                         where lower(r.email) = lower(coalesce(u.email, '')) and cardinality(r.scopes) > 0)))
     and not exists (select 1 from public.owner_property_links l where l.property_id = p_property and l.owner_id = p_user);
$$;

/** The broker's "website leads" request, made on first use: it holds their website leads. */
create or replace function public.website_request_for(p_broker uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  rid uuid;
begin
  select id into rid from public.partner_lead_requests where broker_id = p_broker and pack = 'website' order by created_at limit 1;
  if rid is null then
    insert into public.partner_lead_requests (broker_id, pack, lead_count, status, note, decided_by, decided_at)
    values (p_broker, 'website', 100, 'fulfilled', 'Leads from the MovEazy website on this partner''s flats', 'website', now())
    returning id into rid;
  end if;
  return rid;
end;
$$;

/**
 * One tenant's interest in one partner flat. Makes or tops up the partner's
 * MovEazy lead (trial/Premium) or a 7-day teaser (free plan), rings the bell
 * once per flat and kind, and logs it on the CRM client.
 */
create or replace function public.website_lead(p_client uuid, p_property text, p_kind text, p_detail text default '')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  bid    uuid;
  c      public.crm_clients;
  h      public.inventory;
  bname  text;
  tname  text;
  flat   text;
  verb   text;
  cverb  text;
  aid    uuid;
  fresh_asg boolean := false;
  got    uuid;
  prem   boolean;
begin
  if p_kind not in ('liked', 'opened', 'visit', 'contact', 'match') then return; end if;
  select i.* into h from public.inventory i where i.property_id = p_property and i.status = 'published';
  if h.property_id is null then return; end if;
  select pl.broker_id into bid from public.partner_listings pl where pl.property_id = p_property limit 1;
  if bid is null then return; end if;
  select * into c from public.crm_clients where id = p_client;
  if c.id is null or public.normalize_mobile(coalesce(c.phone, '')) = '' then return; end if;
  if c.user_id is not null and (c.user_id = bid or not public.website_tenant_ok(c.user_id, p_property)) then return; end if;
  if coalesce(c.attributed_to, 'moveazy') <> 'moveazy' then return; end if; -- a broker's own tenant stays theirs
  if coalesce(c.via, '') = 'qr' and c.via_broker = bid then return; end if;   -- from this broker's own QR poster

  select coalesce(nullif(b.name, ''), 'a partner') into bname from public.broker_partners b where b.user_id = bid;
  tname := coalesce(nullif(btrim(c.name), ''), 'A tenant');
  flat := concat_ws(' in ', nullif(h.flat_type, ''), nullif(h.area, ''));
  if flat = '' then flat := 'flat'; end if;
  verb := case p_kind when 'liked' then ' liked your ' when 'opened' then ' viewed your ' when 'visit' then ' wants to visit your '
                      when 'contact' then ' messaged about your ' else ' is looking for a flat like your ' end;
  cverb := case p_kind when 'liked' then 'Liked' when 'opened' then 'Viewed' when 'visit' then 'Wants to visit'
                       when 'contact' then 'Messaged about' else 'Matches' end;
  prem := public.partner_premium_at(bid);

  if prem then
    select id into aid from public.partner_lead_assignments where client_id = c.id and broker_id = bid;
    if aid is null then
      insert into public.partner_lead_assignments (request_id, client_id, broker_id, assigned_by)
      values (public.website_request_for(bid), c.id, bid, 'website')
      returning id into aid;
      fresh_asg := true;
    end if;
    insert into public.partner_website_interest as w (broker_id, client_id, assignment_id, property_id, kind, detail)
    values (bid, c.id, aid, p_property, p_kind, left(coalesce(p_detail, ''), 200))
    on conflict (broker_id, client_id, property_id, kind) do update
      set assignment_id = excluded.assignment_id, held = false, created_at = now()
      where w.held
    returning w.id into got;
    if got is null then return; end if; -- already told about this flat and kind
    insert into public.partner_notifications (broker_id, kind, title, body, link)
    values (bid, 'website_lead',
            case when fresh_asg then 'New lead: ' else '' end || tname || verb || flat,
            concat_ws(' · ', case when h.rent > 0 then '₹' || to_char(h.rent, 'FM99,99,99,999') || '/month' end,
                      nullif(p_detail, ''), 'from the MovEazy website — call them now'),
            '/tenants/asg-' || aid);
    insert into public.crm_activities (client_id, actor_email, type, body, meta)
    values (c.id, 'system', 'system',
            cverb || ' ' || bname || '''s ' || flat || ' (' || p_property || ')'
              || case when nullif(p_detail, '') is not null then ' · ' || p_detail else '' end
              || case when fresh_asg then ' — shared with ' || bname || ' as a website lead' else ' — sent to ' || bname end,
            jsonb_build_object('broker_id', bid, 'assignment_id', aid, 'property_id', p_property, 'kind', p_kind, 'via', 'website'));
  else
    insert into public.partner_website_interest (broker_id, client_id, property_id, kind, held, detail)
    values (bid, c.id, p_property, p_kind, true, left(coalesce(p_detail, ''), 200))
    on conflict (broker_id, client_id, property_id, kind) do nothing
    returning id into got;
    if got is null then return; end if;
    -- One teaser per tenant and flat, whatever they did.
    if (select count(*) from public.partner_website_interest
         where broker_id = bid and client_id = c.id and property_id = p_property) = 1 then
      insert into public.partner_notifications (broker_id, kind, title, body, link)
      values (bid, 'website_teaser', 'A tenant is interested in your ' || flat,
              'Go Premium (or start your free trial) within 7 days to see who it is and call them.', '/premium');
    end if;
    insert into public.crm_activities (client_id, actor_email, type, body, meta)
    values (c.id, 'system', 'system',
            cverb || ' ' || bname || '''s ' || flat || ' (' || p_property || ') — '
              || bname || ' is on the free plan: kept 7 days for an upgrade',
            jsonb_build_object('broker_id', bid, 'property_id', p_property, 'kind', p_kind, 'via', 'website', 'held', true));
  end if;
exception when others then
  -- Telling the broker must never stop the tenant's own action.
  raise warning 'website_lead(%, %): %', p_client, p_property, sqlerrm;
end;
$$;

/** The same, from a tenant's account (their CRM client, if they have one with a number). */
create or replace function public.website_lead_for_user(p_user uuid, p_property text, p_kind text, p_detail text default '')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  cid uuid;
begin
  if p_user is null then return; end if;
  select id into cid from public.crm_clients where user_id = p_user;
  if cid is not null then perform public.website_lead(cid, p_property, p_kind, p_detail); end if;
end;
$$;

revoke all on function public.website_tenant_ok(uuid, text) from public, anon, authenticated;
revoke all on function public.website_request_for(uuid) from public, anon, authenticated;
revoke all on function public.website_lead(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.website_lead_for_user(uuid, text, text, text) from public, anon, authenticated;

-- ── Triggers: where interest already lands ──────────────────────────────────

-- ♥ on a curated list, and a visit the CRM files against the client.
create or replace function public.website_lead_from_shortlist()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  slot timestamptz;
begin
  if new.status not in ('liked', 'visit_scheduled') then return new; end if;
  if tg_op = 'UPDATE' and old.status is not distinct from new.status then return new; end if;
  if new.status = 'liked' then
    perform public.website_lead(new.client_id, new.property_id, 'liked', '');
  else
    select b.slot_at into slot from public.visit_bookings b join public.crm_clients c on c.user_id = b.user_id
     where c.id = new.client_id and b.property_id = new.property_id order by b.created_at desc limit 1;
    perform public.website_lead(new.client_id, new.property_id, 'visit',
      case when slot is not null then 'visit booked for ' || to_char(slot at time zone 'Asia/Kolkata', 'Dy DD Mon, HH12:MI AM') end);
  end if;
  return new;
end;
$$;
drop trigger if exists website_lead_from_shortlist on public.crm_shortlists;
create trigger website_lead_from_shortlist after insert or update of status on public.crm_shortlists
  for each row execute function public.website_lead_from_shortlist();

-- ♥ on the first 5 (and anywhere else a signed-in tenant reacts).
create or replace function public.website_lead_from_reaction()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.reaction = 'like' and (tg_op = 'INSERT' or old.reaction is distinct from new.reaction) then
    perform public.website_lead_for_user(new.user_id, new.property_id, 'liked', '');
  end if;
  return new;
end;
$$;
drop trigger if exists website_lead_from_reaction on public.listing_reactions;
create trigger website_lead_from_reaction after insert or update of reaction on public.listing_reactions
  for each row execute function public.website_lead_from_reaction();

-- A visit booked on the flat (the CRM's own trigger files the client first).
create or replace function public.website_lead_from_visit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.website_lead_for_user(new.user_id, new.property_id, 'visit',
    case when new.slot_at is not null then 'visit booked for ' || to_char(new.slot_at at time zone 'Asia/Kolkata', 'Dy DD Mon, HH12:MI AM')
         else 'asked for a visit' end);
  return new;
end;
$$;
drop trigger if exists website_lead_from_visit on public.visit_bookings;
create trigger website_lead_from_visit after insert on public.visit_bookings
  for each row execute function public.website_lead_from_visit();

-- Free plan → trial or Premium: the teasers of the last 7 days become leads.
create or replace function public.website_leads_unlock()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  w record;
begin
  if new.tier <> 'moveazy_inventory' or not (now() between new.starts_at and new.ends_at) then return new; end if;
  for w in select * from public.partner_website_interest
            where broker_id = new.user_id and held and created_at > now() - interval '7 days'
            order by created_at loop
    perform public.website_lead(w.client_id, w.property_id, w.kind, w.detail);
  end loop;
  return new;
end;
$$;
drop trigger if exists website_leads_unlock on public.partner_entitlements;
create trigger website_leads_unlock after insert on public.partner_entitlements
  for each row execute function public.website_leads_unlock();

-- The broker's calls and WhatsApps on a MovEazy lead, on the CRM client.
create or replace function public.crm_log_partner_reachout()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  who text;
begin
  select coalesce(nullif(b.name, ''), 'A partner broker') into who from public.broker_partners b where b.user_id = new.broker_id;
  insert into public.crm_activities (client_id, actor_email, type, body, meta)
  values (new.client_id, '', case when new.channel = 'whatsapp' then 'whatsapp' else 'call' end,
          coalesce(who, 'A partner broker') || case when new.channel = 'whatsapp' then ' WhatsApped them' else ' called them' end,
          jsonb_build_object('broker_id', new.broker_id, 'assignment_id', new.assignment_id, 'channel', new.channel));
  return new;
exception when others then
  return new;
end;
$$;
drop trigger if exists crm_log_partner_reachout on public.partner_lead_reachouts;
create trigger crm_log_partner_reachout after insert on public.partner_lead_reachouts
  for each row execute function public.crm_log_partner_reachout();

revoke all on function public.website_lead_from_shortlist() from public, anon, authenticated;
revoke all on function public.website_lead_from_reaction() from public, anon, authenticated;
revoke all on function public.website_lead_from_visit() from public, anon, authenticated;
revoke all on function public.website_leads_unlock() from public, anon, authenticated;
revoke all on function public.crm_log_partner_reachout() from public, anon, authenticated;

-- ── The tenant's side (calls from moveazy.co.in) ────────────────────────────

/** Opens of partner flats on this phone (last 7 days, before signing in) → leads now. → how many flats. */
create or replace function public.flat_claim_views(p_visitor text)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  pid text;
  n   int := 0;
begin
  if uid is null or length(coalesce(p_visitor, '')) < 8 then return 0; end if;
  for pid in select distinct s.property_id from public.flat_scans s
              join public.partner_listings pl on pl.property_id = s.property_id
             where s.visitor = left(trim(p_visitor), 64)
               and s.day >= (now() at time zone 'Asia/Kolkata')::date - 7
             limit 20 loop
    perform public.website_lead_for_user(uid, pid, 'opened', '');
    n := n + 1;
  end loop;
  return n;
end;
$$;

/** A signed-in tenant on a flat's page: "Ask the broker to call me" (callback), or WhatsApp / Call tapped. */
create or replace function public.flat_contact_tap(p_property text, p_channel text default 'whatsapp')
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then return; end if;
  perform public.website_lead_for_user(auth.uid(), upper(trim(coalesce(p_property, ''))), 'contact',
    case p_channel when 'callback' then 'asked you to call them' when 'call' then 'tapped Call' else 'tapped WhatsApp' end);
end;
$$;

/** The first-5 screen: partner flats that fit this tenant at 70+ (best first, at most 3). */
-- Retired: a requirement that merely fits a partner's flat is not interest, and
-- never gives the partner a lead. Kept (doing nothing) for any open tab that
-- still calls it.
create or replace function public.website_match_flats(p_properties text[])
returns int
language sql
stable
as $$ select 0; $$;

/** Partners' live flats, and those of partners on trial or Premium (ranked up). Public: ids only. */
create or replace function public.partner_flat_ids()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with f as (
    select pl.property_id, pl.broker_id from public.partner_listings pl
      join public.inventory i on i.property_id = pl.property_id
      join public.broker_partners b on b.user_id = pl.broker_id and b.status = 'approved'
     where i.status = 'published'),
  p as (select distinct broker_id from f where public.partner_premium_at(broker_id))
  select jsonb_build_object(
    'partner', coalesce((select jsonb_agg(property_id) from f), '[]'::jsonb),
    'boosted', coalesce((select jsonb_agg(f.property_id) from f join p using (broker_id)), '[]'::jsonb));
$$;

-- ── The partner's side ──────────────────────────────────────────────────────

/**
 * One of the partner's flats: who's interested from the website (tenant,
 * what they did, their lead), and how many people opened it.
 * → { views: { today, week }, held, tenants: [{ name, phone, slug, kinds, detail, at }] }
 */
create or replace function public.partner_flat_leads(p_property text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with mine as (select 1 from public.partner_listings where property_id = p_property and broker_id = auth.uid()),
  w as (
    select w.*, c.name, c.phone from public.partner_website_interest w join public.crm_clients c on c.id = w.client_id
     where w.broker_id = auth.uid() and w.property_id = p_property)
  select case when not exists (select 1 from mine) then null else jsonb_build_object(
    'views', jsonb_build_object(
       'today', (select count(*) from public.flat_scans s where s.property_id = p_property and s.day = (now() at time zone 'Asia/Kolkata')::date),
       'week', (select count(*) from public.flat_scans s where s.property_id = p_property and s.day > (now() at time zone 'Asia/Kolkata')::date - 7)),
    'held', (select count(distinct client_id) from w where w.held),
    'tenants', coalesce((
       select jsonb_agg(t order by t ->> 'at' desc) from (
         select jsonb_build_object('name', coalesce(nullif(max(w.name), ''), 'Tenant'), 'phone', public.normalize_mobile(max(w.phone)),
                  'slug', 'asg-' || w.assignment_id, 'assignment_id', w.assignment_id,
                  'kinds', jsonb_agg(distinct w.kind), 'detail', max(nullif(w.detail, '')), 'at', max(w.created_at)) as t
           from w where not w.held and w.assignment_id is not null
          group by w.assignment_id) z), '[]'::jsonb)) end
   where public.is_approved_partner();
$$;

/** Per MovEazy lead of this partner: the website interest behind it (flats and what they did). */
create or replace function public.partner_website_interest_mine()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object('assignment_id', z.assignment_id, 'flats', z.flats)), '[]'::jsonb)
    from (select w.assignment_id,
                 jsonb_agg(jsonb_build_object('property_id', w.property_id, 'kind', w.kind, 'detail', w.detail, 'at', w.created_at,
                                              'flat_type', i.flat_type, 'area', i.area, 'rent', i.rent)
                           order by w.created_at desc) as flats
            from public.partner_website_interest w join public.inventory i on i.property_id = w.property_id
           where w.broker_id = auth.uid() and not w.held and w.assignment_id is not null
           group by w.assignment_id) z
   where public.is_approved_partner();
$$;

-- ── The CRM ─────────────────────────────────────────────────────────────────

/** Every website lead: tenant → partner, which flat, what they did, and where the lead stands. */
create or replace function public.crm_website_leads()
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
             'client_id', w.client_id, 'tenant', c.name, 'phone', c.phone, 'broker_id', w.broker_id, 'broker', b.name,
             'broker_phone', b.phone, 'property_id', w.property_id, 'flat_type', i.flat_type, 'area', i.area, 'rent', i.rent,
             'kind', w.kind, 'detail', w.detail, 'held', w.held, 'at', w.created_at,
             'status', a.status, 'last_reach_at', (select max(x.at) from public.partner_lead_reachouts x where x.assignment_id = a.id))
             order by w.created_at desc)
      from (select * from public.partner_website_interest order by created_at desc limit 1000) w
      join public.crm_clients c on c.id = w.client_id
      join public.inventory i on i.property_id = w.property_id
      left join public.broker_partners b on b.user_id = w.broker_id
      left join public.partner_lead_assignments a on a.id = w.assignment_id), '[]'::jsonb);
end;
$$;

revoke all on function public.flat_claim_views(text) from public, anon;
revoke all on function public.flat_contact_tap(text, text) from public, anon;
revoke all on function public.website_match_flats(text[]) from public, anon;
revoke all on function public.partner_flat_leads(text) from public, anon;
revoke all on function public.partner_website_interest_mine() from public, anon;
revoke all on function public.crm_website_leads() from public, anon;
revoke all on function public.partner_flat_ids() from public;
grant execute on function public.flat_claim_views(text) to authenticated;
grant execute on function public.flat_contact_tap(text, text) to authenticated;
grant execute on function public.website_match_flats(text[]) to authenticated;
grant execute on function public.partner_flat_leads(text) to authenticated;
grant execute on function public.partner_website_interest_mine() to authenticated;
grant execute on function public.crm_website_leads() to authenticated;
grant execute on function public.partner_flat_ids() to anon, authenticated;

-- ── Existing functions, extended (bodies otherwise as in their files) ────────

/** (partner_moveazy_leads.sql) The website-leads holder isn't a request the CRM decides on. */
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
   where q.pack <> 'website'
   order by (q.status in ('payment_check', 'needs_approval', 'open')) desc, q.created_at desc
   limit 300;
end;
$$;

/** (partner_moveazy_leads.sql) …nor one the broker made. */
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
   where q.broker_id = auth.uid() and q.pack <> 'website'
   order by q.created_at desc
   limit 50;
$$;

/** (partner_moveazy_leads.sql) A website lead closes like a Premium lead: MovEazy's share is due. */
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
    if pk in ('premium', 'website') then due := round(p_rent * case when p_deal = 'direct' then 0.30 else 0.20 end); end if;
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

/** (flat_insights.sql) Viewers are tenants; a signed-in one opening a partner's flat is that partner's lead. */
create or replace function public.flat_view(p_property text, p_visitor text, p_source text default 'link')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  pid text := upper(trim(coalesce(p_property, '')));
  who text := coalesce(auth.uid()::text, left(trim(coalesce(p_visitor, '')), 64));
begin
  if length(who) < 8 or not exists (select 1 from public.inventory where property_id = pid and status = 'published') then return; end if;
  if auth.uid() is not null and exists (select 1 from public.owner_property_links l where l.property_id = pid and l.owner_id = auth.uid()) then
    return;
  end if;
  -- Partners and CRM staff opening a flat aren't viewers.
  if auth.uid() is not null and not public.website_tenant_ok(auth.uid(), pid) then return; end if;
  insert into public.flat_scans (property_id, visitor, source)
  values (pid, who, case when p_source = 'qr' then 'qr' else 'link' end)
  on conflict (property_id, visitor, day) do nothing;
  -- A signed-in tenant opening a partner's flat: that partner's website lead.
  if auth.uid() is not null then perform public.website_lead_for_user(auth.uid(), pid, 'opened', ''); end if;
end;
$$;

commit;
