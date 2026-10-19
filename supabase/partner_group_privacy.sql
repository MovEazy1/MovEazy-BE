-- Partners in a group stop seeing each other (partners.moveazy.co.in → Groups).
--
--   · Members tab: an ordinary member sees the member count, themselves, and
--     the partners they brought in with their referral link. The group's
--     owner and admins (and MovEazy staff) still see everyone — they manage it.
--   · Group flats: like the MovEazy pool, a flat shared in a group no longer
--     shows who listed it (name, agency, number, exact place) until a tenant
--     of yours likes it (partner_pool_unlocks), unless you listed it or the
--     lister is a partner you referred. A like on a group flat now unlocks it.
--
-- Replaces partner_inventory and partner_pool_unlock_on_like
-- (partner_pool_milestones.sql) and partner_group_members_list
-- (partner_schema.sql) — the same bodies with these rules changed. Run after
-- them. Safe to re-run.

begin;

create or replace function public.partner_inventory()
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
      -- Anonymous — in the pool and in groups alike: not mine, no tenant of mine
      -- has liked it yet (partner_pool_unlocks), and not listed by a partner I
      -- brought in with my referral link.
      (not (select staff from me) and pl.broker_id is distinct from (select uid from me)
       and not exists (select 1 from public.partner_pool_unlocks u
                        where u.partner_id = (select uid from me) and u.property_id = i.property_id)
       and not exists (select 1 from public.broker_partners rb join public.broker_partners mb on mb.user_id = (select uid from me)
                        where rb.user_id = pl.broker_id and coalesce(mb.referral_code, '') <> '' and rb.referred_by = mb.referral_code)) as anon,
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
  -- Group flats unlock the same way now: a group no longer shows who listed them.
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

/** A group's members: everyone for its owner, admins and staff; the rest see themselves and partners they referred. */
create or replace function public.partner_group_members_list(p_group uuid)
returns table (user_id uuid, name text, phone text, agency text, role text, joined_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  with me as (
    select auth.uid() as uid,
           public.is_crm_staff()
             or exists (select 1 from public.partner_group_members x
                         where x.group_id = p_group and x.user_id = auth.uid() and x.role in ('owner', 'admin')) as manages,
           (select nullif(b.referral_code, '') from public.broker_partners b where b.user_id = auth.uid()) as code
  )
  select m.user_id, coalesce(p.name, ''), coalesce(p.phone, ''), coalesce(p.agency, ''), m.role, m.joined_at
    from public.partner_group_members m
    left join public.broker_partners p on p.user_id = m.user_id
    cross join me
   where m.group_id = p_group
     and (public.is_partner_group_member(p_group) or public.is_crm_staff())
     and (me.manages or m.user_id = me.uid or (me.code is not null and p.referred_by = me.code))
   order by case m.role when 'owner' then 0 when 'admin' then 1 else 2 end, m.joined_at;
$$;

revoke all on function public.partner_inventory() from public, anon;
grant execute on function public.partner_inventory() to authenticated;
revoke all on function public.partner_pool_unlock_on_like() from public, anon, authenticated;
revoke all on function public.partner_group_members_list(uuid) from public, anon;
grant execute on function public.partner_group_members_list(uuid) to authenticated;

commit;
