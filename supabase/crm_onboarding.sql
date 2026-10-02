-- ─────────────────────────────────────────────────────────────────────────────
-- Properties the MovEazy team adds for owners and partner brokers, handed over
-- when they sign in (fe/src/pages/crm/CrmPropertyForm.jsx).
--
-- Run in the Supabase SQL editor AFTER crm_property_internal.sql,
-- owner_schema.sql, partner_schema.sql and owner_buildings.sql. Safe to re-run.
--
-- The CRM form now asks two things of every upload: is the owner onboarded,
-- and is the flat one of several units in a building. The owner's email and
-- phone can be added then or on any later edit. From that moment:
--
--   Owners    the flat (and the building it is in) shows up in the owner app
--             for the account with that email — at once if they already have
--             one, otherwise the first time they open owners.moveazy.co.in.
--   Brokers   a flat uploaded on a broker's behalf (inventory_private.source
--             'broker', with a crm_brokers entry) becomes that partner's own
--             listing once they are on a paid plan — when the plan starts, or
--             the next time they open the app if it already has.
--
-- Matching is on the Google-verified email first. A mobile number on a profile
-- is typed by its owner and never verified, so it is used only when the CRM
-- has no email on file for that person: otherwise anyone could put an owner's
-- number on their profile and take the flat.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

-- ── What the CRM records ─────────────────────────────────────────────────────
alter table public.inventory_private add column if not exists owner_onboarded boolean not null default false;
alter table public.inventory_private add column if not exists owner_email text not null default '';
alter table public.inventory_private add column if not exists owner_phone text not null default '';
alter table public.inventory_private add column if not exists multi_unit boolean not null default false;

-- (owner_buildings.owner_id may be null, with owner_email/owner_phone until
-- the owner signs in — those columns are added by owner_buildings.sql.)

-- ── Does this contact belong to that account? ────────────────────────────────
/**
 * True when the CRM's (email, phone) for a person names the account with
 * (account_email, account_phone): the email when the CRM has one, else the
 * normalised mobile.
 */
create or replace function public.crm_contact_matches(crm_email text, crm_phone text, account_email text, account_phone text)
returns boolean
language sql
immutable
set search_path = public
as $$
  select case
    when trim(coalesce(crm_email, '')) <> '' then lower(trim(crm_email)) = lower(trim(coalesce(account_email, '')))
    when public.normalize_mobile(crm_phone) <> '' then public.normalize_mobile(crm_phone) = public.normalize_mobile(account_phone)
    else false
  end;
$$;

-- ── Owners ───────────────────────────────────────────────────────────────────
/**
 * Hand an owner every building and flat the CRM put under their contact, and
 * every flat in those buildings. Never takes a flat already linked to someone.
 * Returns how many flats were linked.
 */
create or replace function public.owner_link_crm_properties(p_owner uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  em text;
  ph text;
  n  int := 0;
  k  int;
begin
  select lower(coalesce(o.email, '')), coalesce(nullif(o.phone, ''), p.phone, '') into em, ph
    from public.owner_accounts o left join public.user_profiles p on p.id = o.user_id
   where o.user_id = p_owner and o.status <> 'suspended';
  if not found then return 0; end if;

  update public.owner_buildings b set owner_id = p_owner, updated_at = now()
   where b.owner_id is null and public.crm_contact_matches(b.owner_email, b.owner_phone, em, ph);

  insert into public.owner_property_links (property_id, owner_id, linked_by)
  select ip.property_id, p_owner, 'crm'
    from public.inventory_private ip
   where public.crm_contact_matches(ip.owner_email, ip.owner_phone, em, ph)
  on conflict (property_id) do nothing;
  get diagnostics k = row_count;
  n := n + k;

  insert into public.owner_property_links (property_id, owner_id, linked_by)
  select i.property_id, p_owner, 'crm'
    from public.inventory i join public.owner_buildings b on b.id = i.building_id
   where b.owner_id = p_owner
  on conflict (property_id) do nothing;
  get diagnostics k = row_count;
  return n + k;
end;
$$;

-- Every time the owner app opens, owner_register() touches owner_accounts.
create or replace function public.owner_accounts_link_crm()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.owner_link_crm_properties(new.user_id);
  return new;
end;
$$;
drop trigger if exists owner_accounts_link_crm on public.owner_accounts;
create trigger owner_accounts_link_crm after insert or update on public.owner_accounts
  for each row execute function public.owner_accounts_link_crm();

-- ── Partner brokers ──────────────────────────────────────────────────────────
/** Is this user on a paid plan for MovEazy inventory (partner_has_tier, for any user)? */
create or replace function public.partner_user_premium(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.broker_partners bp where bp.user_id = p_user and bp.status = 'approved')
     and exists (select 1 from public.partner_entitlements e
                  where e.user_id = p_user and e.tier = 'moveazy_inventory' and now() >= e.starts_at and now() < e.ends_at);
$$;

/**
 * Make the flats the CRM uploaded on this broker's behalf their own listings —
 * on a paid plan only. A flat MovEazy showed to every partner stays shown to
 * every partner, at the share it was offered at. Returns how many were linked.
 */
create or replace function public.partner_link_crm_listings(p_broker uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  em text;
  ph text;
  n  int;
begin
  if not public.partner_user_premium(p_broker) then return 0; end if;
  select lower(coalesce(bp.email, '')), coalesce(nullif(bp.phone, ''), p.phone, '') into em, ph
    from public.broker_partners bp left join public.user_profiles p on p.id = bp.user_id
   where bp.user_id = p_broker;

  with mine as (
    select ip.property_id
      from public.inventory_private ip
      join public.crm_brokers cb on cb.id = ip.broker_id
     where ip.source = 'broker'
       and public.crm_contact_matches(cb.email, cb.phone, em, ph)
       and not exists (select 1 from public.partner_listings pl where pl.property_id = ip.property_id)
  ), linked as (
    insert into public.partner_listings (property_id, broker_id)
    select property_id, p_broker from mine
    on conflict (property_id) do nothing
    returning property_id
  ), shared as (
    insert into public.partner_platform_shares (property_id, share_pct)
    select l.property_id, coalesce(i.partner_share_pct, 50)
      from linked l join public.inventory i on i.property_id = l.property_id
     where coalesce(i.partner_visible, true)
    on conflict (property_id) do nothing
    returning property_id
  )
  select count(*) into n from linked;
  return n;
end;
$$;

-- A plan starting (paid, or granted by staff) hands the listings over.
create or replace function public.partner_entitlements_link_crm()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.tier = 'moveazy_inventory' then perform public.partner_link_crm_listings(new.user_id); end if;
  return new;
end;
$$;
drop trigger if exists partner_entitlements_link_crm on public.partner_entitlements;
create trigger partner_entitlements_link_crm after insert or update on public.partner_entitlements
  for each row execute function public.partner_entitlements_link_crm();

/** The partner app calls this on open: anything the CRM added since lands now. */
create or replace function public.partner_claim_crm_listings()
returns int
language sql
security definer
set search_path = public
as $$
  select case when auth.uid() is null then 0 else public.partner_link_crm_listings(auth.uid()) end;
$$;

-- ── The CRM side: a contact added on an edit links straight away ─────────────
create or replace function public.inventory_private_link_crm()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  u uuid;
begin
  for u in
    select o.user_id from public.owner_accounts o left join public.user_profiles p on p.id = o.user_id
     where o.status <> 'suspended'
       and public.crm_contact_matches(new.owner_email, new.owner_phone, o.email, coalesce(nullif(o.phone, ''), p.phone, ''))
  loop
    perform public.owner_link_crm_properties(u);
  end loop;
  if new.source = 'broker' and new.broker_id is not null then
    for u in
      select bp.user_id from public.broker_partners bp
        join public.crm_brokers cb on cb.id = new.broker_id
        left join public.user_profiles p on p.id = bp.user_id
       where bp.status = 'approved'
         and public.crm_contact_matches(cb.email, cb.phone, bp.email, coalesce(nullif(bp.phone, ''), p.phone, ''))
    loop
      perform public.partner_link_crm_listings(u);
    end loop;
  end if;
  return new;
end;
$$;
drop trigger if exists inventory_private_link_crm on public.inventory_private;
create trigger inventory_private_link_crm after insert or update on public.inventory_private
  for each row execute function public.inventory_private_link_crm();

create or replace function public.owner_buildings_link_crm()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  u uuid;
begin
  if new.owner_id is not null then
    -- A flat the team adds to a building that already has its owner is theirs too.
    insert into public.owner_property_links (property_id, owner_id, linked_by)
    select i.property_id, new.owner_id, 'crm' from public.inventory i where i.building_id = new.id
    on conflict (property_id) do nothing;
    return new;
  end if;
  for u in
    select o.user_id from public.owner_accounts o left join public.user_profiles p on p.id = o.user_id
     where o.status <> 'suspended'
       and public.crm_contact_matches(new.owner_email, new.owner_phone, o.email, coalesce(nullif(o.phone, ''), p.phone, ''))
  loop
    perform public.owner_link_crm_properties(u);
  end loop;
  return new;
end;
$$;
drop trigger if exists owner_buildings_link_crm on public.owner_buildings;
create trigger owner_buildings_link_crm after insert or update of owner_email, owner_phone, owner_id on public.owner_buildings
  for each row execute function public.owner_buildings_link_crm();

-- A flat put into a building with an owner goes to that owner.
create or replace function public.inventory_building_link_owner()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.building_id is not null then
    insert into public.owner_property_links (property_id, owner_id, linked_by)
    select new.property_id, b.owner_id, 'crm' from public.owner_buildings b
     where b.id = new.building_id and b.owner_id is not null
    on conflict (property_id) do nothing;
  end if;
  return new;
end;
$$;
drop trigger if exists inventory_building_link_owner on public.inventory;
create trigger inventory_building_link_owner after insert or update of building_id on public.inventory
  for each row execute function public.inventory_building_link_owner();

-- ── Buildings, from the CRM ──────────────────────────────────────────────────

/** Every building, for the CRM form's picker: id, name, area, its owner's contact and whether they have the app. */
create or replace function public.crm_building_options()
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
             'id', b.id, 'code', b.code, 'name', b.name, 'area', b.area,
             'owner_email', coalesce(nullif(o.email, ''), b.owner_email), 'owner_phone', coalesce(nullif(o.phone, ''), b.owner_phone),
             'owner_name', o.name, 'owner_joined', b.owner_id is not null,
             'flats', (select count(*) from public.inventory i where i.building_id = b.id))
           order by b.name)
      from public.owner_buildings b left join public.owner_accounts o on o.user_id = b.owner_id), '[]'::jsonb);
end;
$$;

/**
 * Create a building (no id) or update one from the CRM, with the owner's
 * contact. Needs crm.properties.write. Returns { id, code }.
 */
create or replace function public.crm_building_save(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  bid uuid := nullif(p ->> 'id', '')::uuid;
  nm  text := trim(coalesce(p ->> 'name', ''));
  c   text;
  i   int;
begin
  if not public.has_admin_scope('crm.properties.write') then
    raise exception 'Needs permission to add properties.' using errcode = '42501';
  end if;
  if bid is null and length(nm) < 2 then raise exception 'Give the building a name.' using errcode = '22023'; end if;
  if bid is null then
    for i in 1..25 loop
      select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '')
        into c from generate_series(1, 6);
      exit when not exists (select 1 from public.owner_buildings where code = c);
    end loop;
    insert into public.owner_buildings (owner_id, code, name, created_by)
    values (null, c, left(nm, 80), lower(coalesce(auth.jwt() ->> 'email', '')))
    returning id into bid;
  elsif not exists (select 1 from public.owner_buildings where id = bid) then
    raise exception 'No such building.' using errcode = '22023';
  end if;

  update public.owner_buildings b set
    name         = case when length(nm) >= 2 then left(nm, 80) else b.name end,
    area         = case when p ? 'area' and trim(coalesce(p ->> 'area', '')) <> '' then left(trim(p ->> 'area'), 80) else b.area end,
    landmark     = case when p ? 'landmark' and coalesce(p ->> 'landmark', '') <> '' then left(p ->> 'landmark', 160) else b.landmark end,
    full_address = case when p ? 'full_address' and coalesce(p ->> 'full_address', '') <> '' then left(p ->> 'full_address', 400) else b.full_address end,
    latitude     = case when b.latitude is null and p ? 'latitude' then nullif(p ->> 'latitude', '')::numeric else b.latitude end,
    longitude    = case when b.longitude is null and p ? 'longitude' then nullif(p ->> 'longitude', '')::numeric else b.longitude end,
    total_floors = case when p ? 'total_floors' and coalesce(p ->> 'total_floors', '') <> '' then (p ->> 'total_floors')::int else b.total_floors end,
    owner_email  = case when p ? 'owner_email' then lower(trim(coalesce(p ->> 'owner_email', ''))) else b.owner_email end,
    owner_phone  = case when p ? 'owner_phone' then trim(coalesce(p ->> 'owner_phone', '')) else b.owner_phone end,
    updated_at   = now()
  where b.id = bid;

  return (select jsonb_build_object('id', b.id, 'code', b.code) from public.owner_buildings b where b.id = bid);
end;
$$;

/** Put a flat in a building (or take it out) from the CRM, on a floor. */
create or replace function public.crm_set_flat_building(p_property text, p_building uuid, p_floor int default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.has_admin_scope('crm.properties.write') then
    raise exception 'Needs permission to change properties.' using errcode = '42501';
  end if;
  if p_building is not null and not exists (select 1 from public.owner_buildings where id = p_building) then
    raise exception 'No such building.' using errcode = '22023';
  end if;
  update public.inventory set building_id = p_building, floor_number = coalesce(p_floor, floor_number), updated_at = now()
   where property_id = p_property;
  if not found then raise exception 'No such listing.' using errcode = '22023'; end if;
end;
$$;

/** Who a CRM listing is linked to now: the owner account and the partner, if any. For the edit form. */
create or replace function public.crm_property_links(p_property text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'owner', (select jsonb_build_object('name', o.name, 'email', o.email, 'phone', o.phone, 'linked_by', l.linked_by, 'linked_at', l.linked_at)
                from public.owner_property_links l join public.owner_accounts o on o.user_id = l.owner_id
               where l.property_id = upper(trim(p_property))),
    'partner', (select jsonb_build_object('name', bp.name, 'email', bp.email, 'phone', bp.phone)
                  from public.partner_listings pl join public.broker_partners bp on bp.user_id = pl.broker_id
                 where pl.property_id = upper(trim(p_property))),
    'building', (select jsonb_build_object('id', b.id, 'name', b.name, 'code', b.code)
                   from public.inventory i join public.owner_buildings b on b.id = i.building_id
                  where i.property_id = upper(trim(p_property)))
  );
end;
$$;

-- ── Grants ───────────────────────────────────────────────────────────────────
do $$
declare f text;
begin
  foreach f in array array[
    'public.crm_contact_matches(text, text, text, text)', 'public.owner_link_crm_properties(uuid)',
    'public.partner_user_premium(uuid)', 'public.partner_link_crm_listings(uuid)',
    'public.owner_accounts_link_crm()', 'public.partner_entitlements_link_crm()',
    'public.inventory_private_link_crm()', 'public.owner_buildings_link_crm()', 'public.inventory_building_link_owner()'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
  foreach f in array array[
    'public.partner_claim_crm_listings()', 'public.crm_building_options()', 'public.crm_building_save(jsonb)',
    'public.crm_set_flat_building(text, uuid, int)', 'public.crm_property_links(text)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

commit;
