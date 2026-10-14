-- ─────────────────────────────────────────────────────────────────────────────
-- The anonymous pool, upload milestones, lead counts for the CRM, and the
-- one-time referral reward retired (fe: lib/partnerPool.js, InventoryHome,
-- UploadDone, PropertyDetail, CrmPartnersSection, Wallet).
--
-- Run in the Supabase SQL editor AFTER inventory_partner_hidden.sql
-- (inventory_from_crm), partner_location.sql (partner_inventory,
-- partner_property_contacts_for), partner_moveazy_leads.sql (requests,
-- lead_give, lead_candidates*), partner_website_leads.sql (partner_lead_update)
-- and partner_referral_commission.sql (partner_premium_at). Safe to re-run.
--
-- 1. The pool. Partners no longer browse other inventory: their app shows
--    their own flats and a count. AI matching still searches every flat they
--    could see before (other partners' flats shared with all partners, and
--    MovEazy's own), but those come back anonymous — no lister, no number, no
--    exact place — tagged in the app "Different MovEazy Partner Inventory"
--    with the brokerage share the caller would get. Group-shared flats stay
--    open inside the group, as before.
--    When a tenant likes one on the partner's curated list, it unlocks for
--    that partner only, that flat only (partner_pool_unlocks): they see the
--    listing partner's name and number, and both get a bell — the listing
--    partner with the asking partner's name and number.
-- 2. Milestones. A flat counts when it is complete: 6 of the 9 details the
--    app checks, rent, BHK, area and a photo among them. 3 complete flats →
--    10 MovEazy leads at once, picked for their flats (then their areas);
--    only flats the partner uploaded count (not ones the CRM added for them);
--    10 → a milestone with no reward; 20 → 20 fresh leads. Trial and Premium
--    partners only; a free partner's reward waits until they upgrade.
--    MovEazy's usual share applies when these close ("milestone" pack).
--    Then a streak: day 1 is the day they reached 3; each later day with 5+
--    complete uploads keeps it going.
-- 3. The CRM: how many leads each partner has and where each one stands.
-- 4. The one-time referral reward (₹500 / 1,500 / 3,000 on a plan) is gone:
--    only the lifetime 10% commission remains.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

-- ── Tables and kinds ────────────────────────────────────────────────────────
alter table public.partner_lead_requests drop constraint if exists partner_lead_requests_pack_check;
alter table public.partner_lead_requests add constraint partner_lead_requests_pack_check
  check (pack in ('free10', 'paid30', 'premium', 'website', 'milestone'));

/** A pool flat a partner may now see in full: a tenant on their curated list liked it. */
create table if not exists public.partner_pool_unlocks (
  partner_id  uuid not null references auth.users (id) on delete cascade,
  property_id text not null references public.inventory (property_id) on delete cascade,
  list_id     uuid references public.partner_curated_lists (id) on delete set null,
  lister_id   uuid references auth.users (id) on delete set null, -- null: MovEazy's own flat
  created_at  timestamptz not null default now(),
  primary key (partner_id, property_id)
);
create index if not exists partner_pool_unlocks_lister_idx on public.partner_pool_unlocks (lister_id, created_at desc);

create table if not exists public.partner_milestones (
  broker_id   uuid not null references auth.users (id) on delete cascade,
  milestone   int not null check (milestone in (3, 10, 20)),
  reached_at  timestamptz not null default now(),
  awarded_at  timestamptz,
  request_id  uuid references public.partner_lead_requests (id) on delete set null,
  given       int not null default 0,
  primary key (broker_id, milestone)
);

alter table public.partner_pool_unlocks enable row level security;
alter table public.partner_milestones enable row level security;
revoke all on table public.partner_pool_unlocks, public.partner_milestones from anon, authenticated;

do $$
declare
  kinds text[];
begin
  select array_agg(distinct m[1]) into kinds
    from pg_constraint c, regexp_matches(pg_get_constraintdef(c.oid), '''([a-z_]+)''', 'g') m
   where c.conname = 'partner_notifications_kind_check';
  if kinds is null then return; end if;
  kinds := array(select distinct k from unnest(kinds || array['pool_unlocked', 'pool_interest', 'milestone']) k order by 1);
  alter table public.partner_notifications drop constraint partner_notifications_kind_check;
  execute format('alter table public.partner_notifications add constraint partner_notifications_kind_check check (kind in (%s))',
                 (select string_agg(quote_literal(k), ', ') from unnest(kinds) k));
end $$;

-- ── 1. The pool ─────────────────────────────────────────────────────────────
drop function if exists public.partner_inventory();
create function public.partner_inventory()
returns table (
  property_id     text,
  source          text,       -- mine | moveazy | broker
  on_platform     boolean,    -- shared with all MovEazy brokers
  group_ids       uuid[],     -- groups it is shared with that the caller can see
  brokerage_pct   numeric,    -- what the CALLER earns on it (null: not offered)
  locked          boolean,
  status          text,
  title           text,
  city            text,
  area            text,
  nearby_areas    text[],
  full_address    text,
  landmark        text,
  latitude        numeric,
  longitude       numeric,
  rent            numeric,
  deposit         numeric,
  available_from  date,
  property_type   text,
  flat_type       text,
  bedrooms        int,
  bathrooms       int,
  furnishing      text,
  amenities       text[],
  description     text,
  images          text[],
  cover_image_url text,
  is_verified     boolean,
  lister_id       uuid,
  lister_name     text,
  lister_agency   text,
  lister_phone    text,
  created_at      timestamptz,
  updated_at      timestamptz,
  rent_flag       text,
  anonymous       boolean     -- another partner's (or MovEazy's) flat, not yet unlocked: no lister, no exact place
)
language sql
stable
security definer
set search_path = public
as $$
  with me as (
    select auth.uid() as uid,
           public.is_crm_staff() as staff,
           public.is_approved_partner() as partner,
           public.partner_has_tier('moveazy_inventory') as premium,
           (select ps.property_share from public.program_settings ps where ps.id = 1) as property_share
  ),
  my_groups as (
    select m.group_id from public.partner_group_members m, me where m.user_id = me.uid
  ),
  src as (
    select
      i.*,
      pl.broker_id as pl_broker,
      (pl.property_id is not null) as is_partner_listing,
      ps.share_pct as platform_pct,
      (
        select coalesce(array_agg(gs.group_id order by gs.group_id), '{}')
          from public.partner_group_shares gs, me
         where gs.property_id = i.property_id
           and (me.staff or gs.group_id in (select group_id from my_groups)
                or pl.broker_id = me.uid)
      ) as visible_groups,
      (
        select max(gs.share_pct)
          from public.partner_group_shares gs
         where gs.property_id = i.property_id
           and gs.group_id in (select group_id from my_groups)
      ) as best_group_pct,
      -- In the pool, anonymous: not mine, not seen through a group I'm in, and no
      -- tenant of mine has liked it yet (partner_pool_unlocks).
      (not (select staff from me) and pl.broker_id is distinct from (select uid from me)
       and not exists (select 1 from public.partner_pool_unlocks u
                        where u.partner_id = (select uid from me) and u.property_id = i.property_id)
       and not exists (select 1 from public.partner_group_shares gs
                        where gs.property_id = i.property_id and gs.group_id in (select group_id from my_groups))) as anon,
      -- The exact place: the lister, staff, or a broker the lister said yes to.
      (pl.broker_id = (select uid from me) or (select staff from me)
       or exists (select 1 from public.partner_location_requests lr
                   where lr.property_id = i.property_id and lr.requested_by = (select uid from me)
                     and lr.status = 'approved')) as place_open
    from public.inventory i
    left join public.partner_listings pl on pl.property_id = i.property_id
    left join public.partner_platform_shares ps on ps.property_id = i.property_id
  )
  select
    r.property_id,
    case when not r.is_partner_listing then 'moveazy'
         when r.pl_broker = me.uid then 'mine'
         else 'broker' end,
    r.platform_pct is not null,
    r.visible_groups,
    case when not r.is_partner_listing then me.property_share
         when r.pl_broker = me.uid then greatest(r.platform_pct, (select max(gs.share_pct) from public.partner_group_shares gs where gs.property_id = r.property_id))
         else greatest(r.platform_pct, r.best_group_pct) end,
    (not r.is_partner_listing and not me.premium),
    r.status,
    r.title, r.city, r.area, r.nearby_areas,
    -- MovEazy's own flats: on a plan. Another broker's: only once they have
    -- approved this caller's request -- until then, the area and nothing finer.
    case when r.anon or (not r.is_partner_listing and not me.premium) or (r.is_partner_listing and not r.place_open) then '' else r.full_address end,
    case when r.anon or (r.is_partner_listing and not r.place_open) then '' else r.landmark end,
    case when r.anon or (not r.is_partner_listing and not me.premium) or (r.is_partner_listing and not r.place_open) then null else r.latitude end,
    case when r.anon or (not r.is_partner_listing and not me.premium) or (r.is_partner_listing and not r.place_open) then null else r.longitude end,
    r.rent, r.deposit, r.available_from, r.property_type, r.flat_type, r.bedrooms, r.bathrooms,
    r.furnishing, r.amenities, r.description, r.images, r.cover_image_url, r.is_verified,
    case when r.is_partner_listing and not r.anon then r.pl_broker end,
    case when r.is_partner_listing and not r.anon then coalesce(nullif(bp.name, ''), r.poster_name) end,
    case when r.is_partner_listing and not r.anon then bp.agency end,
    case when r.is_partner_listing and not r.anon then coalesce(nullif(bp.phone, ''), r.phone) end,
    r.created_at, r.updated_at, r.rent_flag, r.anon
  from src r
  cross join me
  left join public.broker_partners bp on bp.user_id = r.pl_broker
  where (me.partner or me.staff)
    and (
      -- MovEazy's own inventory, unless the CRM held it back.
      (not r.is_partner_listing and r.status = 'published' and (r.partner_visible or me.staff))
      -- Your own, in any state.
      or (r.is_partner_listing and r.pl_broker = me.uid)
      -- Someone else's, shared with everyone or with a group you are in now —
      -- for partners on a plan.
      or (r.is_partner_listing and r.status = 'published' and me.premium
          and (r.platform_pct is not null or r.best_group_pct is not null))
      -- Staff see every partner listing, group-only and paused ones included.
      or (r.is_partner_listing and me.staff)
    );
$$;
revoke all on function public.partner_inventory() from public, anon;
grant execute on function public.partner_inventory() to authenticated;

create or replace function public.partner_property_contacts_for(p_property text)
returns table (role text, name text, phone text, label text, availability text, verified boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v record;
  staff boolean := public.is_crm_staff();
begin
  select * into v from public.partner_inventory() pi where pi.property_id = p_property;
  -- Not visible, or visible but locked: no contacts at all.
  if not found or v.locked then
    return;
  end if;
  -- In the pool and not unlocked: nobody to call until a tenant likes it.
  if v.anonymous then
    return;
  end if;

  -- A flat its owner manages in the owner app (owner_schema.sql): brokers
  -- reach MovEazy, never the owner. Nested ifs, not one condition: Postgres
  -- does not promise to evaluate to_regclass first, and planning the exists
  -- against a table that is not there would fail.
  if v.source = 'moveazy' and to_regclass('public.owner_property_links') is not null then
    if exists (select 1 from public.owner_property_links ol where ol.property_id = p_property) then
      -- The owner, directly -- unless they switched brokers' calls off in the
      -- owner app, when MovEazy's visits desk takes them and passes the visit
      -- on (VISITS_DESK in fe/src/lib/partnerContact.js).
      return query
        select case when ol.broker_contact and coalesce(oa.phone, '') <> '' then 'owner' else 'moveazy' end,
               case when ol.broker_contact and coalesce(oa.phone, '') <> '' then coalesce(nullif(oa.name, ''), 'Owner') else 'MovEazy visits desk' end,
               case when ol.broker_contact and coalesce(oa.phone, '') <> '' then oa.phone else '8090911024' end,
               case when ol.broker_contact and coalesce(oa.phone, '') <> '' then 'Owner' else 'Owner takes visits through MovEazy' end,
               ''::text, true
          from public.owner_property_links ol
          left join public.owner_accounts oa on oa.user_id = ol.owner_id
         where ol.property_id = p_property;
      return;
    end if;
  end if;

  if v.source = 'moveazy' and to_regclass('public.inventory_private') is null then
    -- No CRM internal details on this database: the poster is the contact.
    return query
      select 'owner'::text, coalesce(i.poster_name, ''), coalesce(i.phone, ''),
             case i.posted_by when 'broker' then 'Listing broker' when 'tenant' then 'Current tenant' else 'Owner' end,
             ''::text, coalesce(i.is_verified, false)
        from public.inventory i
       where i.property_id = p_property;
    return;
  end if;

  if v.source = 'moveazy' then
    -- Premium (or staff): the person MovEazy deals with on this flat.
    return query
      select 'owner'::text,
             coalesce(nullif(ip.poc_name, ''), i.poster_name, ''),
             coalesce(nullif(ip.poc_phone, ''), i.phone, ''),
             case coalesce(ip.source, i.posted_by)
               when 'broker' then 'Listing broker'
               when 'tenant' then 'Current tenant'
               else 'Owner' end,
             ''::text,
             coalesce(i.is_verified, false)
        from public.inventory i
        left join public.inventory_private ip on ip.property_id = i.property_id
       where i.property_id = p_property;
    return;
  end if;

  -- A partner listing: the listing broker is visible to everyone it is shared with.
  return query
    select 'broker'::text, coalesce(v.lister_name, ''), coalesce(v.lister_phone, ''),
           coalesce(nullif(v.lister_agency, ''), 'Individual broker'), ''::text, false;

  -- Owner / tenant only for the listing broker and staff.
  if v.source = 'mine' or staff then
    return query
      select c.role, c.name, c.phone,
             case c.role when 'owner' then 'Owner' else 'Current tenant' end,
             c.availability, c.verified
        from public.partner_property_contacts c
       where c.property_id = p_property
       order by c.role;
  end if;
end;
$$;

/** How many flats the caller's AI matching searches besides their own (live, shared or MovEazy's). */
create or replace function public.partner_pool_count()
returns int
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::int from public.partner_inventory() pi
   where pi.source <> 'mine' and pi.status = 'published';
$$;

/** A tenant liked a pool flat on a partner's curated list: unlock it for that partner, tell both. */
create or replace function public.partner_pool_unlock_on_like()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  cl     public.partner_curated_lists;
  a      public.broker_partners;
  lister uuid;
  h      public.inventory;
  flat   text;
  tenant text;
  got    uuid;
begin
  if new.action <> 'liked' or (tg_op = 'UPDATE' and old.action is not distinct from new.action) then return new; end if;
  select * into cl from public.partner_curated_lists where id = new.list_id;
  if cl.id is null then return new; end if;
  select pl.broker_id into lister from public.partner_listings pl where pl.property_id = new.property_id;
  if lister = cl.broker_id then return new; end if; -- their own flat
  -- Seen through a group they share: already open, nothing to unlock.
  if lister is not null and exists (
       select 1 from public.partner_group_shares gs join public.partner_group_members m on m.group_id = gs.group_id
        where gs.property_id = new.property_id and m.user_id = cl.broker_id) then
    return new;
  end if;
  insert into public.partner_pool_unlocks (partner_id, property_id, list_id, lister_id)
  values (cl.broker_id, new.property_id, cl.id, lister)
  on conflict (partner_id, property_id) do nothing
  returning partner_id into got;
  if got is null then return new; end if;

  select * into h from public.inventory where property_id = new.property_id;
  select * into a from public.broker_partners where user_id = cl.broker_id;
  flat := coalesce(nullif(concat_ws(' in ', nullif(h.flat_type, ''), nullif(h.area, '')), ''), 'flat');
  tenant := coalesce(nullif(btrim(cl.lead_name), ''), 'Your tenant');
  if lister is not null then
    insert into public.partner_notifications (broker_id, kind, title, body, link)
    values (cl.broker_id, 'pool_unlocked', tenant || ' liked a partner''s ' || flat || ' — contact unlocked',
            'Call ' || coalesce(nullif((select name from public.broker_partners where user_id = lister), ''), 'the listing partner')
              || ' to set up a visit. Only this flat is unlocked.', '/property/' || new.property_id);
    insert into public.partner_notifications (broker_id, kind, title, body, link)
    values (lister, 'pool_interest', 'A partner''s tenant liked your ' || flat,
            coalesce(nullif(a.name, ''), 'A MovEazy partner') || case when coalesce(a.phone, '') <> '' then ' (' || a.phone || ')' else '' end
              || ' wants to set up a visit — they''ll call you.', '/property/' || new.property_id);
  else
    insert into public.partner_notifications (broker_id, kind, title, body, link)
    values (cl.broker_id, 'pool_unlocked', tenant || ' liked MovEazy''s ' || flat || ' — contact unlocked',
            'See who to call to set up the visit. Only this flat is unlocked.', '/property/' || new.property_id);
  end if;
  return new;
exception when others then
  raise warning 'partner_pool_unlock_on_like(%): %', new.list_id, sqlerrm;
  return new;
end;
$$;
drop trigger if exists partner_pool_unlock_on_like on public.partner_curated_actions;
create trigger partner_pool_unlock_on_like after insert or update of action on public.partner_curated_actions
  for each row execute function public.partner_pool_unlock_on_like();
revoke all on function public.partner_pool_unlock_on_like() from public, anon, authenticated;

-- ── 2. Milestones ───────────────────────────────────────────────────────────

/**
 * A complete flat: rent, BHK, area and a photo, and 6 of the 9 details the app
 * checks (3+ photos, rent, BHK, area, furnishing, available from, deposit,
 * description of 40+ letters, amenities) — as in fe lib/partnerTenants.js.
 */
create or replace function public.partner_flat_complete(i public.inventory)
returns boolean
language sql
immutable
as $$
  select coalesce(i.rent, 0) > 0
     and (coalesce(i.flat_type, '') <> '' or coalesce(i.bedrooms, 0) > 0)
     and coalesce(btrim(i.area), '') <> ''
     and (coalesce(i.cover_image_url, '') <> '' or cardinality(coalesce(i.images, '{}')) > 0)
     and ((cardinality(array_remove(array_remove(coalesce(i.images, '{}') || coalesce(i.cover_image_url, ''), ''), null)) >= 3)::int
          + 1 + 1 + 1
          + (coalesce(i.furnishing, '') <> '')::int
          + (i.available_from is not null)::int
          + (coalesce(i.deposit, 0) > 0)::int
          + (length(btrim(coalesce(i.description, ''))) >= 40)::int
          + (cardinality(coalesce(i.amenities, '{}')) > 0)::int) >= 6;
$$;

/** Give a partner a milestone's leads: their own flats' best matches, then their areas. Internal. → how many. */
create or replace function public.partner_milestone_award(p_broker uuid, p_milestone int, p_count int)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  rid   uuid;
  n_given int := 0;
begin
  insert into public.partner_lead_requests (broker_id, pack, lead_count, status, prefs, note, decided_by, decided_at)
  values (p_broker, 'milestone', p_count, 'open',
          jsonb_build_object('areas', coalesce(to_jsonb((select operational_areas from public.broker_partners where user_id = p_broker)), '[]'::jsonb),
                             'milestone', p_milestone),
          format('Milestone: %s complete flats uploaded', p_milestone), 'milestone', now())
  returning id into rid;
  n_given := public.lead_give(rid, array(select c.client_id from public.lead_candidates_for_flats(p_broker) c limit p_count), 'milestone');
  if n_given < p_count then
    n_given := n_given + public.lead_give(rid, array(select c.client_id from public.lead_candidates(rid) c limit p_count - n_given), 'milestone');
  end if;
  update public.partner_milestones set awarded_at = now(), request_id = rid, given = n_given
   where broker_id = p_broker and milestone = p_milestone;
  insert into public.partner_notifications (broker_id, kind, title, body, link)
  values (p_broker, 'milestone', format('Milestone reached: %s flats — %s fresh leads unlocked', p_milestone, p_count),
          case when n_given >= p_count then 'They''re in Leads → MovEazy leads. Call them today.'
               else format('%s are in Leads → MovEazy leads now; the rest follow as new tenants come in.', n_given) end,
          '/leads?tab=moveazy');
  return n_given;
end;
$$;
revoke all on function public.partner_milestone_award(uuid, int, int) from public, anon, authenticated;

/**
 * The caller's upload progress, and any milestone reward now due (given here).
 * → { complete, total, today, milestones: [{ milestone, reached_at, awarded_at, given }],
 *     next, plan_ok, streak: { days, day1, today_done, active } }
 */
create or replace function public.partner_upload_progress()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid   uuid := auth.uid();
  n     int;
  total int;
  today date := (now() at time zone 'Asia/Kolkata')::date;
  prem  boolean;
  day1  date;
  d     date;
  days  int := 0;
  today_n int;
  m     record;
begin
  if not public.is_approved_partner() then raise exception 'Only MovEazy partners.' using errcode = '42501'; end if;
  -- Only flats they uploaded themselves: not ones the CRM added for them.
  select count(*) filter (where public.partner_flat_complete(i)), count(*)
    into n, total
    from public.partner_listings pl join public.inventory i on i.property_id = pl.property_id
   where pl.broker_id = uid and not public.inventory_from_crm(i.source);
  prem := public.partner_premium_at(uid);

  for m in select x.ms, x.cnt from (values (3, 10), (10, 0), (20, 20)) x(ms, cnt) where n >= x.ms loop
    insert into public.partner_milestones (broker_id, milestone) values (uid, m.ms) on conflict do nothing;
    if m.cnt > 0 and prem and exists (select 1 from public.partner_milestones
                                        where broker_id = uid and milestone = m.ms and awarded_at is null) then
      perform public.partner_milestone_award(uid, m.ms, m.cnt);
    end if;
  end loop;

  -- The streak: day 1 is the day the 3rd complete flat went up; then each day with 5+.
  with c as (
    select (i.created_at at time zone 'Asia/Kolkata')::date as day, row_number() over (order by i.created_at) as k
      from public.partner_listings pl join public.inventory i on i.property_id = pl.property_id
     where pl.broker_id = uid and public.partner_flat_complete(i) and not public.inventory_from_crm(i.source))
  select day into day1 from c where k = 3;
  select count(*) into today_n
    from public.partner_listings pl join public.inventory i on i.property_id = pl.property_id
   where pl.broker_id = uid and public.partner_flat_complete(i) and not public.inventory_from_crm(i.source) and (i.created_at at time zone 'Asia/Kolkata')::date = today;
  if day1 is not null then
    d := case when today_n >= 5 or today = day1 then today else today - 1 end;
    loop
      exit when d < day1;
      exit when d <> day1 and (select count(*) from public.partner_listings pl join public.inventory i on i.property_id = pl.property_id
                                 where pl.broker_id = uid and public.partner_flat_complete(i) and not public.inventory_from_crm(i.source)
                                   and (i.created_at at time zone 'Asia/Kolkata')::date = d) < 5;
      days := days + 1;
      d := d - 1;
    end loop;
  end if;

  return jsonb_build_object(
    'complete', n, 'total', total, 'today', today_n, 'plan_ok', prem,
    'next', case when n < 3 then 3 when n < 10 then 10 when n < 20 then 20 end,
    'milestones', coalesce((select jsonb_agg(jsonb_build_object('milestone', pm.milestone, 'reached_at', pm.reached_at,
                              'awarded_at', pm.awarded_at, 'given', pm.given) order by pm.milestone)
                              from public.partner_milestones pm where pm.broker_id = uid), '[]'::jsonb),
    'streak', jsonb_build_object('days', days, 'day1', day1, 'today_done', today_n >= 5 or today = day1,
                                 'active', days > 0));
end;
$$;

-- A free partner who upgrades: the rewards they reached are given then.
create or replace function public.partner_milestones_on_plan()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  m record;
begin
  if new.tier <> 'moveazy_inventory' or not (now() between new.starts_at and new.ends_at) then return new; end if;
  for m in select pm.milestone from public.partner_milestones pm
            where pm.broker_id = new.user_id and pm.awarded_at is null and pm.milestone in (3, 20) loop
    perform public.partner_milestone_award(new.user_id, m.milestone, case m.milestone when 3 then 10 else 20 end);
  end loop;
  return new;
exception when others then
  raise warning 'partner_milestones_on_plan(%): %', new.user_id, sqlerrm;
  return new;
end;
$$;
drop trigger if exists partner_milestones_on_plan on public.partner_entitlements;
create trigger partner_milestones_on_plan after insert on public.partner_entitlements
  for each row execute function public.partner_milestones_on_plan();
revoke all on function public.partner_milestones_on_plan() from public, anon, authenticated;

-- (partner_website_leads.sql) Milestone leads close with MovEazy's share, like Premium.
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
    if pk in ('premium', 'website', 'milestone') then due := round(p_rent * case when p_deal = 'direct' then 0.30 else 0.20 end); end if;
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

-- ── 3. The CRM: each partner's leads ────────────────────────────────────────

/**
 * Without a partner: per partner, their MovEazy leads by status and their own
 * leads. With one: every lead MovEazy gave them — where it came from, its
 * status, when they last called or WhatsApped.
 */
create or replace function public.crm_partner_leads(p_broker uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  if p_broker is null then
    return coalesce((
      select jsonb_object_agg(b.user_id, jsonb_build_object(
               'total', (select count(*) from public.partner_lead_assignments a where a.broker_id = b.user_id),
               'assigned', (select count(*) from public.partner_lead_assignments a where a.broker_id = b.user_id and a.status = 'assigned'),
               'contacted', (select count(*) from public.partner_lead_assignments a where a.broker_id = b.user_id and a.status = 'contacted'),
               'visit', (select count(*) from public.partner_lead_assignments a where a.broker_id = b.user_id and a.status = 'visit'),
               'closed', (select count(*) from public.partner_lead_assignments a where a.broker_id = b.user_id and a.status = 'closed'),
               'not_interested', (select count(*) from public.partner_lead_assignments a where a.broker_id = b.user_id and a.status = 'not_interested'),
               'untouched', (select count(*) from public.partner_lead_assignments a where a.broker_id = b.user_id and a.status = 'assigned'
                               and not exists (select 1 from public.partner_lead_reachouts x where x.assignment_id = a.id)),
               'own', (select count(*) from public.partner_leads l where l.broker_id = b.user_id)))
        from public.broker_partners b), '{}'::jsonb);
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', a.id, 'client_id', a.client_id, 'name', c.name, 'phone', c.phone, 'pack', q.pack, 'status', a.status,
             'assigned_at', a.assigned_at, 'closed_rent', a.closed_rent, 'due_amount', a.due_amount,
             'reach_count', (select count(*) from public.partner_lead_reachouts x where x.assignment_id = a.id),
             'last_reach_at', (select max(x.at) from public.partner_lead_reachouts x where x.assignment_id = a.id),
             'last_channel', (select x.channel from public.partner_lead_reachouts x where x.assignment_id = a.id order by x.at desc limit 1))
             order by a.assigned_at desc)
      from public.partner_lead_assignments a
      join public.crm_clients c on c.id = a.client_id
      join public.partner_lead_requests q on q.id = a.request_id
     where a.broker_id = p_broker), '[]'::jsonb);
end;
$$;

-- ── 4. The one-time referral reward, retired ────────────────────────────────
update public.partner_plans set referral_reward = 0 where coalesce(referral_reward, 0) <> 0;
create or replace function public.partner_referrals_retired()
returns trigger
language plpgsql
as $$ begin return null; end; $$;
drop trigger if exists partner_referrals_retired on public.partner_referrals;
create trigger partner_referrals_retired before insert on public.partner_referrals
  for each row execute function public.partner_referrals_retired();
revoke all on function public.partner_referrals_retired() from public, anon, authenticated;

-- ── Grants ──────────────────────────────────────────────────────────────────
revoke all on function public.partner_pool_count() from public, anon;
revoke all on function public.partner_upload_progress() from public, anon;
revoke all on function public.crm_partner_leads(uuid) from public, anon;
revoke all on function public.partner_flat_complete(public.inventory) from public, anon;
grant execute on function public.partner_pool_count() to authenticated;
grant execute on function public.partner_upload_progress() to authenticated;
grant execute on function public.crm_partner_leads(uuid) to authenticated;
grant execute on function public.partner_flat_complete(public.inventory) to authenticated;

commit;
