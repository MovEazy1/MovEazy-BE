-- A partner's curated list, start to finish inside the partner's flow.
--
-- The tenant on moveazy.co.in/c/<token> used to tap "See all photos &
-- details" and land on MovEazy's own property page — whose "Book a visit"
-- took them out of the partner's hands. Now:
--
--   · partner_curated_open gives everything the details screen shows (photos,
--     size, floor, amenities, rules, landmark) — and an approximate spot, never
--     the address: the partner shares that when fixing the visit.
--   · Like / dislike can be changed any time. A like tells the partner when
--     it is new — not again when the same like is saved twice.
--   · partner_curated_siblings: every list the same partner sent the same
--     tenant — the "My homes" view of the link.
--   · tenant_my_partners: a signed-in moveazy.co.in account sees its partner
--     and their lists — when it opened the link while signed in (the list is
--     claimed), or its number is the one the partner has.
--
-- Replaces partner_curated_open / _act from partner_matcher_history.sql: run
-- this after it. Safe to re-run.

begin;

alter table public.partner_curated_lists
  add column if not exists claimed_by uuid references auth.users (id) on delete set null;
create index if not exists partner_curated_lists_claimed_idx
  on public.partner_curated_lists (claimed_by) where claimed_by is not null;

-- ── One list's homes, as the tenant sees them ────────────────────────────────
create or replace function public.partner_curated_homes(p_list uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'property_id', i.property_id, 'title', i.title, 'area', i.area, 'rent', i.rent, 'deposit', i.deposit,
           'flat_type', i.flat_type, 'bedrooms', i.bedrooms, 'bathrooms', i.bathrooms, 'furnishing', i.furnishing,
           'property_type', i.property_type, 'available_from', i.available_from, 'images', i.images,
           'cover_image_url', i.cover_image_url, 'description', i.description, 'status', i.status,
           'let_out', i.status <> 'published' or i.rent_flag <> '',
           'area_sqft', i.area_sqft, 'floor_number', i.floor_number, 'landmark', i.landmark,
           'amenities', i.amenities, 'house_rules', i.house_rules, 'occupants_allowed', i.occupants_allowed,
           'gender_pref', i.gender_pref, 'max_flatmates', i.max_flatmates,
           -- About half a kilometre off: enough to judge the commute, not to find the door.
           'approx_lat', round(i.latitude * 200) / 200, 'approx_lng', round(i.longitude * 200) / 200,
           'action', (select a.action from public.partner_curated_actions a where a.list_id = l.id and a.property_id = i.property_id))
         order by array_position(l.property_ids, i.property_id)), '[]'::jsonb)
    from public.partner_curated_lists l
    join public.inventory i on i.property_id = any (l.property_ids)
   where l.id = p_list;
$$;

create or replace function public.partner_curated_broker(p_broker uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('name', bp.name, 'agency', bp.agency, 'phone', bp.phone,
                            'photo_url', coalesce((select s.photo_url from public.partner_storefronts s where s.broker_id = bp.user_id), ''))
    from public.broker_partners bp where bp.user_id = p_broker;
$$;

-- ── The tenant's page ────────────────────────────────────────────────────────
/** The tenant's page, by the link's token. A MovEazy tenant's list needs no phone gate. */
create or replace function public.partner_curated_open(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  l   public.partner_curated_lists;
  uid uuid := auth.uid();
begin
  select * into l from public.partner_curated_lists where token = p_token;
  if l.id is null then return null; end if;
  update public.partner_curated_lists
     set open_count = open_count + 1, opened_at = coalesce(opened_at, now()),
         -- Opened while signed in to moveazy.co.in: their partner shows there
         -- too. Never the partner previewing their own link, a partner, or staff.
         claimed_by = case
                        when claimed_by is null and uid is not null and uid <> l.broker_id
                         and not exists (select 1 from public.broker_partners b where b.user_id = uid)
                         and not public.is_crm_staff()
                        then uid else claimed_by
                      end
   where id = l.id;
  if l.opened_at is null then
    insert into public.partner_notifications (broker_id, kind, title, body, link)
    values (l.broker_id, 'list_opened', coalesce(nullif(l.lead_name, ''), 'Your tenant') || ' opened your list',
            cardinality(l.property_ids) || ' homes — likes and dislikes will show up here.', '/curated/' || l.id::text);
  end if;
  return jsonb_build_object(
    'lead_name', l.lead_name,
    'has_contact', l.tenant_id is not null or l.assignment_id is not null,
    'known', l.assignment_id is not null,
    'created_at', l.created_at,
    'broker', public.partner_curated_broker(l.broker_id),
    'homes', public.partner_curated_homes(l.id)
  );
end;
$$;

/** A like or a dislike, changeable any time. A new like tells the partner. */
create or replace function public.partner_curated_act(p_token text, p_property text, p_action text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  l  public.partner_curated_lists;
  v_name  text;
  v_phone text;
  cid uuid;
  h  public.inventory;
  prev text;
  was_done boolean;
  n_liked int;
  n_skipped int;
begin
  select * into l from public.partner_curated_lists where token = p_token;
  if l.id is null then raise exception 'This list is no longer available.' using errcode = '22023'; end if;
  if l.tenant_id is null and l.assignment_id is null then raise exception 'Add your mobile number first.' using errcode = '42501'; end if;
  if not (p_property = any (l.property_ids)) then raise exception 'That home is not on this list.' using errcode = '22023'; end if;
  if p_action not in ('liked', 'skipped') then raise exception 'Unknown action.' using errcode = '22023'; end if;

  if l.tenant_id is not null then
    select t.name, t.phone into v_name, v_phone from public.partner_tenants t where t.id = l.tenant_id;
  else
    select c.id, c.name, public.normalize_mobile(c.phone) into cid, v_name, v_phone
      from public.partner_lead_assignments a join public.crm_clients c on c.id = a.client_id where a.id = l.assignment_id;
  end if;
  v_name := coalesce(nullif(v_name, ''), nullif(l.lead_name, ''), 'Your tenant');

  select a.action into prev from public.partner_curated_actions a where a.list_id = l.id and a.property_id = p_property;
  select count(*) = cardinality(l.property_ids) into was_done from public.partner_curated_actions where list_id = l.id;
  insert into public.partner_curated_actions as a (list_id, property_id, action)
  values (l.id, p_property, p_action)
  on conflict (list_id, property_id) do update set action = excluded.action, at = now();

  if p_action = 'liked' and prev is distinct from 'liked' then
    select * into h from public.inventory where property_id = p_property;
    insert into public.partner_notifications (broker_id, kind, title, body, link)
    values (l.broker_id, 'tenant_liked', v_name || ' liked a home',
            concat_ws(' · ', nullif(h.flat_type, ''), nullif(h.area, ''), case when h.rent > 0 then '₹' || to_char(h.rent, 'FM99,99,999') end)
              || ' — ' || coalesce(v_phone, ''),
            '/curated/' || l.id::text);
    if cid is not null then
      -- The tenant did it, so no actor: it reads as their own activity in the CRM.
      insert into public.crm_activities (client_id, actor_email, type, body, meta)
      values (cid, '', 'partner', 'Liked ' || public.partner_flat_line(p_property) || ' on ' ||
                public.partner_display_name(l.broker_id) || '''s list',
              jsonb_build_object('source', 'partner_like', 'broker_id', l.broker_id, 'list_id', l.id, 'property_id', p_property));
    end if;
  end if;

  if not was_done then
    select count(*) filter (where action = 'liked'), count(*) filter (where action = 'skipped'), count(*) = cardinality(l.property_ids)
      into n_liked, n_skipped, was_done
      from public.partner_curated_actions where list_id = l.id;
    if was_done then
      insert into public.partner_notifications (broker_id, kind, title, body, link)
      values (l.broker_id, 'list_done', v_name || ' finished your list',
              '♥ ' || n_liked || ' liked · ✕ ' || n_skipped || ' disliked — ' || coalesce(v_phone, ''),
              '/curated/' || l.id::text);
    end if;
  end if;
  return true;
end;
$$;

-- ── My homes: every list from this partner to this tenant ────────────────────
/**
 * The other lists the same partner sent the same person, newest first: by the
 * number they gave, the MovEazy assignment, or the partner's own lead. A list
 * sent to the same lead that they haven't opened yet is theirs to answer too.
 */
create or replace function public.partner_curated_siblings(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  l public.partner_curated_lists;
begin
  select * into l from public.partner_curated_lists where token = p_token;
  if l.id is null or (l.tenant_id is null and l.assignment_id is null) then
    return '[]'::jsonb;
  end if;
  if l.tenant_id is not null and l.lead_id is not null then
    update public.partner_curated_lists s set tenant_id = l.tenant_id
     where s.broker_id = l.broker_id and s.lead_id = l.lead_id and s.tenant_id is null and s.assignment_id is null;
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('token', s.token, 'created_at', s.created_at, 'homes', public.partner_curated_homes(s.id))
                     order by s.created_at desc)
      from (select * from public.partner_curated_lists s
             where s.broker_id = l.broker_id and s.id <> l.id
               and ((l.tenant_id is not null and s.tenant_id = l.tenant_id)
                    or (l.assignment_id is not null and s.assignment_id = l.assignment_id))
             order by s.created_at desc
             limit 10) s), '[]'::jsonb);
end;
$$;

-- ── On moveazy.co.in ─────────────────────────────────────────────────────────
/**
 * A signed-in tenant's partners: each with their card, their lists and the
 * homes liked. A list is theirs when they opened it signed in, or their number
 * is the one the partner has (given on the link, the partner's own lead, or
 * MovEazy's lead the partner was given).
 */
create or replace function public.tenant_my_partners()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  ph  text;
begin
  if uid is null then return '[]'::jsonb; end if;
  select public.normalize_mobile(coalesce(p.phone, '')) into ph from public.user_profiles p where p.id = uid;
  ph := coalesce(ph, '');
  return coalesce((
    with mine as (
      select l.* from public.partner_curated_lists l
       where l.broker_id <> uid
         and (l.claimed_by = uid
              or (ph <> '' and l.tenant_id in (select t.id from public.partner_tenants t where t.phone = ph))
              or (ph <> '' and l.lead_id in (select pl.id from public.partner_leads pl where public.normalize_mobile(pl.phone) = ph))
              or l.assignment_id in (select a.id from public.partner_lead_assignments a join public.crm_clients c on c.id = a.client_id
                                      where c.user_id = uid or (ph <> '' and public.normalize_mobile(c.phone) = ph)))
    ),
    per as (
      select m.broker_id, max(m.created_at) as last_at,
             jsonb_agg(jsonb_build_object(
               'token', m.token, 'created_at', m.created_at, 'count', cardinality(m.property_ids),
               'liked', (select count(*) from public.partner_curated_actions a where a.list_id = m.id and a.action = 'liked'),
               'decided', (select count(*) from public.partner_curated_actions a where a.list_id = m.id))
               order by m.created_at desc) as lists,
             coalesce((select jsonb_agg(x.h) from (
                 select distinct on (i.property_id) jsonb_build_object(
                          'property_id', i.property_id, 'token', m2.token, 'flat_type', i.flat_type, 'area', i.area, 'rent', i.rent,
                          'cover_image_url', i.cover_image_url, 'images', i.images[1:1],
                          'let_out', i.status <> 'published' or i.rent_flag <> '') as h
                   from mine m2
                   join public.partner_curated_actions a on a.list_id = m2.id and a.action = 'liked'
                   join public.inventory i on i.property_id = a.property_id
                  where m2.broker_id = m.broker_id
                  order by i.property_id, a.at desc) x), '[]'::jsonb) as liked
        from mine m
       group by m.broker_id
    )
    select jsonb_agg(jsonb_build_object('broker', public.partner_curated_broker(per.broker_id), 'lists', per.lists, 'liked', per.liked)
                     order by per.last_at desc)
      from per), '[]'::jsonb);
end;
$$;

revoke all on function public.partner_curated_homes(uuid) from public, anon, authenticated;
revoke all on function public.partner_curated_broker(uuid) from public, anon, authenticated;
revoke all on function public.partner_curated_siblings(text) from public;
revoke all on function public.tenant_my_partners() from public, anon;
grant execute on function public.partner_curated_open(text) to anon, authenticated;
grant execute on function public.partner_curated_act(text, text, text) to anon, authenticated;
grant execute on function public.partner_curated_siblings(text) to anon, authenticated;
grant execute on function public.tenant_my_partners() to authenticated;

commit;
