-- ─────────────────────────────────────────────────────────────────────────────
-- Who looks at the deals (MovEazy-FE pages/find/StealDeals + DealOfTheDay,
-- lib/deals.js; CRM → Deals; agreed 2026-11-17).
--
-- Run in the Supabase SQL editor AFTER find_deals.sql, tenant_views.sql,
-- lead_intake_direct.sql, partner_launch.sql, crm_follow_ups.sql and
-- crm_payments.sql. Safe to re-run.
--
-- The deals pages are shared as one general link (CRM → Deals, and "Send" on a
-- client). They show at once; the visitor's mobile number is asked the first
-- time they open a flat, tap ♥ or book (lead_intake: that browser's key → the
-- CRM client). What they do is kept here, per browser:
--
--   deal_events   page (once a day), open (a flat), like, unlike — for the
--                 Steal Deals week or the Deal of the Day's day they saw it in
--
-- A like or an open from a known client also lands on the client's tenant
-- views (source "deal"), so the client record shows it like any other flat
-- they looked at. A like — and a visit booked for a flat that is a deal right
-- now — tells the team (crm_notifications) and the partner whose flat it is
-- (partner_notifications; the flat, never the tenant's number).
--
-- The CRM reads, per deal flat: opens, likes, visits booked that week (that
-- day, for the Deal of the Day — from anywhere), and who: crm_deal_stats,
-- crm_deal_people. Any CRM user (crm_deal_staff).
-- ─────────────────────────────────────────────────────────────────────────────

begin;

create table if not exists public.deal_events (
  id          bigint generated always as identity primary key,
  lead_key    text not null check (length(lead_key) between 16 and 64),
  client_id   uuid references public.crm_clients (id) on delete set null,
  deal        text not null check (deal in ('steal', 'day')),
  deal_key    date not null, -- the week's Monday (steal) or the day (day)
  property_id text,
  kind        text not null check (kind in ('page', 'open', 'like', 'unlike')),
  at          timestamptz not null default now()
);
create index if not exists deal_events_deal_idx on public.deal_events (deal, deal_key, kind);
create index if not exists deal_events_flat_idx on public.deal_events (property_id, deal, deal_key) where property_id is not null;
create index if not exists deal_events_key_idx on public.deal_events (lead_key, deal, deal_key);
create index if not exists deal_events_client_idx on public.deal_events (client_id) where client_id is not null;

alter table public.deal_events enable row level security;
revoke all on public.deal_events from anon, authenticated;

-- Partner notifications gain 'deal' (the kinds already allowed are kept).
do $$
declare
  d    text;
  vals text[];
begin
  select pg_get_constraintdef(oid) into d from pg_constraint where conname = 'partner_notifications_kind_check';
  if d is not null and d !~ '''deal''' then
    vals := array(select m[1] from regexp_matches(d, '([a-z_]{3,})', 'g') m
                   where m[1] not in ('kind', 'any', 'array', 'text', 'check'));
    vals := array(select distinct x from unnest(vals || array['deal']) x);
    alter table public.partner_notifications drop constraint partner_notifications_kind_check;
    execute format('alter table public.partner_notifications add constraint partner_notifications_kind_check check (kind = any (%L::text[]))', vals);
  end if;
end $$;

-- ── Internal ────────────────────────────────────────────────────────────────

/** The period the site shows now: the Steal Deals week on screen, or today. */
create or replace function public.deal_shown_key(p_deal text)
returns date
language sql
stable
security definer
set search_path = public
as $$
  select case when p_deal = 'steal'
    then coalesce((select max(s.week_start) from public.steal_deals s where s.week_start <= public.deal_this_monday()), public.deal_this_monday())
    else (now() at time zone 'Asia/Kolkata')::date end;
$$;

/** Is this flat a deal on screen right now? Its period, else null. */
create or replace function public.deal_live_key(p_deal text, p_property text)
returns date
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  k date := public.deal_shown_key(p_deal);
begin
  if p_deal = 'steal' then
    return case when exists (select 1 from public.steal_deals s where s.week_start = k and s.property_id = p_property) then k end;
  end if;
  -- Deal of the Day: today's flat for its type, or the last one rolled over.
  return case when exists (
    select 1 from (
      select distinct on (x.kind) x.property_id from public.day_deals x where x.day <= k order by x.kind, x.day desc
    ) d where d.property_id = p_property) then k end;
end;
$$;

/** Which deal (if any) a flat is right now: 'steal', 'day' or null — for a visit's notification. */
create or replace function public.deal_live_kind(p_property text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case when public.deal_live_key('steal', p_property) is not null then 'steal'
              when public.deal_live_key('day', p_property) is not null then 'day' end;
$$;

/** The client behind a browser: the number it gave (lead_intake), or the signed-in account. */
create or replace function public.deal_client_for(p_lead_key text)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select l.crm_client_id from public.lead_intake l where l.lead_key = p_lead_key),
    (select c.id from public.crm_clients c where auth.uid() is not null and c.user_id = auth.uid() limit 1));
$$;

/** "2 BHK · HSR · ₹40,000 · MZ-XXXX" */
create or replace function public.deal_flat_line(p_property text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select concat_ws(' · ', nullif(i.flat_type, ''), nullif(i.area, ''),
                   case when i.rent > 0 then '₹' || to_char(i.rent, 'FM99,99,99,999') end, i.property_id)
    from public.inventory i where i.property_id = p_property;
$$;

/** Tell the team, and the partner whose flat it is (the flat only — never the tenant's number). */
create or replace function public.deal_notify(p_client uuid, p_property text, p_deal text, p_what text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  who   text;
  phone text;
  label text := case when p_deal = 'steal' then 'Steal Deal' else 'Deal of the Day' end;
  flat  text := coalesce(public.deal_flat_line(p_property), p_property);
  e     text;
  b     uuid;
begin
  select coalesce(nullif(c.name, ''), c.phone, 'A client'), coalesce(c.phone, '') into who, phone
    from public.crm_clients c where c.id = p_client;
  who := coalesce(who, 'A visitor');
  for e in select * from public.crm_team_emails() loop
    insert into public.crm_notifications (for_email, type, title, body, client_id)
    values (e, 'deal', format('%s %s a %s', who, p_what, label),
            concat_ws(' · ', flat, nullif(phone, '')), p_client);
  end loop;
  for b in select distinct pl.broker_id from public.partner_listings pl where pl.property_id = p_property loop
    insert into public.partner_notifications (broker_id, kind, title, body, link)
    values (b, 'deal', format('A tenant %s your flat — %s', p_what, label),
            flat || ' · MovEazy is following up with them.', '/property/' || p_property);
  end loop;
end;
$$;

-- ── The visitor ─────────────────────────────────────────────────────────────

/** The flats this browser has ♥ on the deal on screen now. */
create or replace function public.deal_my_likes(p_lead_key text, p_deal text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(x.property_id), '[]'::jsonb)
    from (
      select distinct on (e.property_id) e.property_id, e.kind
        from public.deal_events e
       where e.lead_key = p_lead_key and e.deal = p_deal and e.deal_key = public.deal_shown_key(p_deal)
         and e.kind in ('like', 'unlike')
       order by e.property_id, e.at desc, e.id desc
    ) x where x.kind = 'like';
$$;

/**
 * What a visitor did on a deals page: 'page' (opened it — once a day counted),
 * 'open' (a flat), 'like', 'unlike'. Quietly ignores a flat that isn't a deal
 * on screen. → { likes: [property ids liked] }.
 */
create or replace function public.deal_track(p_lead_key text, p_deal text, p_kind text, p_property text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  key  text := trim(coalesce(p_lead_key, ''));
  pid  text := upper(trim(coalesce(p_property, '')));
  k    date;
  cid  uuid;
  last text;
  vid  uuid;
begin
  if key !~ '^[A-Za-z0-9_-]{16,64}$' then raise exception 'Bad visitor key.' using errcode = '22023'; end if;
  if p_deal not in ('steal', 'day') or p_kind not in ('page', 'open', 'like', 'unlike') then
    raise exception 'Unknown deal event.' using errcode = '22023';
  end if;
  cid := public.deal_client_for(key);

  if p_kind = 'page' then
    k := public.deal_shown_key(p_deal);
    if not exists (select 1 from public.deal_events e where e.lead_key = key and e.deal = p_deal and e.deal_key = k and e.kind = 'page'
                     and (e.at at time zone 'Asia/Kolkata')::date = (now() at time zone 'Asia/Kolkata')::date) then
      insert into public.deal_events (lead_key, client_id, deal, deal_key, kind) values (key, cid, p_deal, k, 'page');
    end if;
    return jsonb_build_object('likes', public.deal_my_likes(key, p_deal));
  end if;

  k := public.deal_live_key(p_deal, pid);
  if pid = '' or k is null then return jsonb_build_object('likes', public.deal_my_likes(key, p_deal)); end if;

  if p_kind = 'open' then
    -- A double tap is one open.
    if not exists (select 1 from public.deal_events e where e.lead_key = key and e.property_id = pid and e.deal = p_deal
                     and e.deal_key = k and e.kind = 'open' and e.at > now() - interval '2 minutes') then
      insert into public.deal_events (lead_key, client_id, deal, deal_key, property_id, kind) values (key, cid, p_deal, k, pid, 'open');
      if cid is not null then perform public.tenant_view_touch(pid, cid, 'deal', now(), 1); end if;
    end if;
  else
    select e.kind into last from public.deal_events e
     where e.lead_key = key and e.property_id = pid and e.deal = p_deal and e.deal_key = k and e.kind in ('like', 'unlike')
     order by e.at desc, e.id desc limit 1;
    if coalesce(last, 'unlike') <> p_kind then
      insert into public.deal_events (lead_key, client_id, deal, deal_key, property_id, kind) values (key, cid, p_deal, k, pid, p_kind);
      if cid is not null then
        vid := public.tenant_view_touch(pid, cid, 'deal');
        if vid is not null then
          perform public.tenant_view_respond(vid, 'tenant', '', null,
            jsonb_build_object('liked', case when p_kind = 'like' then 'liked' else '' end));
        end if;
      end if;
      -- Told once per flat per period, however often they toggle.
      if p_kind = 'like' and last is null then
        perform public.deal_notify(cid, pid, p_deal, 'liked');
      end if;
    end if;
  end if;
  return jsonb_build_object('likes', public.deal_my_likes(key, p_deal));
end;
$$;

/** A visit booked for a flat that is a deal right now: the team and its partner are told. */
create or replace function public.deal_visit_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  d   text := public.deal_live_kind(new.property_id);
  cid uuid;
begin
  if d is null then return new; end if;
  select c.id into cid from public.crm_clients c where c.user_id = new.user_id limit 1;
  perform public.deal_notify(cid, new.property_id, d, 'booked a visit for');
  return new;
exception when others then
  return new; -- a notification must never stop a booking
end;
$$;
drop trigger if exists zz_deal_visit_notify on public.visit_bookings;
create trigger zz_deal_visit_notify after insert on public.visit_bookings
  for each row execute function public.deal_visit_notify();

-- ── The CRM ─────────────────────────────────────────────────────────────────

/**
 * Deals' numbers for periods p_from..p_to (Mondays for 'steal', days for
 * 'day'): { periods: [{ key, people, identified }], flats: [{ key,
 * property_id, opens, likes, visits }] }. people = browsers that opened the
 * page; identified = those whose number we have. visits = bookings for the
 * flat made in that period, from anywhere.
 */
create or replace function public.crm_deal_stats(p_deal text, p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  len int := case when p_deal = 'steal' then 7 else 1 end;
begin
  perform public.crm_deal_staff();
  if p_deal not in ('steal', 'day') then raise exception 'Unknown deal.' using errcode = '22023'; end if;
  return jsonb_build_object(
    'periods', coalesce((
      select jsonb_agg(jsonb_build_object('key', x.deal_key, 'people', x.people, 'identified', x.identified) order by x.deal_key)
        from (
          select e.deal_key, count(distinct e.lead_key) people,
                 count(distinct coalesce(e.client_id, l.crm_client_id)) identified
            from public.deal_events e left join public.lead_intake l on l.lead_key = e.lead_key
           where e.deal = p_deal and e.deal_key between p_from and p_to
           group by e.deal_key
        ) x), '[]'::jsonb),
    'flats', coalesce((
      select jsonb_agg(jsonb_build_object('key', f.k, 'property_id', f.pid, 'opens', f.opens, 'likes', f.likes, 'visits', f.visits))
        from (
          select s.k, s.pid,
                 (select count(*) from public.deal_events e where e.deal = p_deal and e.deal_key = s.k and e.property_id = s.pid and e.kind = 'open') opens,
                 (select count(*) from (
                    select distinct on (e.lead_key) e.kind from public.deal_events e
                     where e.deal = p_deal and e.deal_key = s.k and e.property_id = s.pid and e.kind in ('like', 'unlike')
                     order by e.lead_key, e.at desc, e.id desc) z where z.kind = 'like') likes,
                 (select count(*) from public.visit_bookings v
                   where v.property_id = s.pid
                     and (v.created_at at time zone 'Asia/Kolkata')::date between s.k and s.k + (len - 1)) visits
            from (
              select distinct x.k, x.pid from (
                select s.week_start k, s.property_id pid from public.steal_deals s
                 where p_deal = 'steal' and s.week_start between p_from and p_to
                union
                select e.deal_key, e.property_id from public.deal_events e
                 where e.deal = p_deal and e.deal_key between p_from and p_to and e.property_id is not null
                union
                select d.day, d.property_id from public.day_deals d where p_deal = 'day' and d.day between p_from and p_to
              ) x
            ) s
        ) f), '[]'::jsonb));
end;
$$;

/**
 * Who, for one deal flat in one period: everyone who opened or ♥ it from the
 * deals page, and everyone who booked a visit for it then (from anywhere) —
 * one row each: { client_id, name, phone, opens, liked, liked_at, visit_at,
 * visit_status, booked_at, last_at }. Known clients first, likes and visits on top.
 */
create or replace function public.crm_deal_people(p_deal text, p_key date, p_property text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  len int := case when p_deal = 'steal' then 7 else 1 end;
begin
  perform public.crm_deal_staff();
  return coalesce((
    with ev as (
      select coalesce(e.client_id, l.crm_client_id) cid, e.lead_key, e.kind, e.at, e.id
        from public.deal_events e left join public.lead_intake l on l.lead_key = e.lead_key
       where e.deal = p_deal and e.deal_key = p_key and e.property_id = p_property
    ),
    who as (
      select coalesce(ev.cid::text, ev.lead_key) who, max(ev.cid::text)::uuid cid,
             count(*) filter (where ev.kind = 'open') opens,
             (array_agg(ev.kind order by ev.at desc, ev.id desc) filter (where ev.kind in ('like', 'unlike')))[1] = 'like' liked,
             max(ev.at) filter (where ev.kind = 'like') liked_at,
             max(ev.at) last_at
        from ev group by 1
    ),
    vis as (
      select c.id cid, max(v.slot_at) visit_at, max(v.created_at) booked_at, max(v.status) visit_status
        from public.visit_bookings v join public.crm_clients c on c.user_id = v.user_id
       where v.property_id = p_property
         and (v.created_at at time zone 'Asia/Kolkata')::date between p_key and p_key + (len - 1)
       group by c.id
    ),
    allp as (
      select coalesce(w.cid, vis.cid) cid, coalesce(w.who, vis.cid::text) who, coalesce(w.opens, 0) opens, coalesce(w.liked, false) liked,
             w.liked_at, vis.visit_at, vis.visit_status, vis.booked_at, greatest(w.last_at, vis.booked_at) last_at
        from who w full join vis on vis.cid = w.cid
    )
    select jsonb_agg(jsonb_build_object(
             'client_id', a.cid, 'name', coalesce(c.name, ''), 'phone', coalesce(c.phone, ''), 'opens', a.opens,
             'liked', a.liked, 'liked_at', a.liked_at, 'visit_at', a.visit_at, 'visit_status', coalesce(a.visit_status, ''),
             'booked_at', a.booked_at, 'last_at', a.last_at)
           order by (a.cid is null), (a.booked_at is null), (not a.liked), a.last_at desc nulls last)
      from allp a left join public.crm_clients c on c.id = a.cid), '[]'::jsonb);
end;
$$;

-- ── Grants ──────────────────────────────────────────────────────────────────

revoke all on function public.deal_shown_key(text) from public, anon, authenticated;
revoke all on function public.deal_live_key(text, text) from public, anon, authenticated;
revoke all on function public.deal_live_kind(text) from public, anon, authenticated;
revoke all on function public.deal_client_for(text) from public, anon, authenticated;
revoke all on function public.deal_flat_line(text) from public, anon, authenticated;
revoke all on function public.deal_notify(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.deal_visit_notify() from public, anon, authenticated;
revoke all on function public.deal_my_likes(text, text) from public;
grant execute on function public.deal_my_likes(text, text) to anon, authenticated;
revoke all on function public.deal_track(text, text, text, text) from public;
grant execute on function public.deal_track(text, text, text, text) to anon, authenticated;
revoke all on function public.crm_deal_stats(text, date, date) from public, anon;
grant execute on function public.crm_deal_stats(text, date, date) to authenticated;
revoke all on function public.crm_deal_people(text, date, text) from public, anon;
grant execute on function public.crm_deal_people(text, date, text) to authenticated;

commit;
