-- ─────────────────────────────────────────────────────────────────────────────
-- Deals on /find (MovEazy-FE pages/find/*, lib/deals.js, CRM → Deals).
--
-- Run in the Supabase SQL editor AFTER inventory_schema.sql and crm_schema.sql
-- (has_admin_scope). Safe to re-run.
--
--   steal_deals   Steal Deals of the Week: up to 20 flats the team picks for a
--                 Monday–Sunday week (IST). The site shows this week's list; a
--                 week with nothing picked keeps the last week that had one.
--   day_deals     Deal of the Day: one flat per type (1 RK, 1 BHK, 2 BHK,
--                 3 BHK and above) per day, scheduled ahead. A day with nothing
--                 set for a type rolls the last one over.
--
-- Deals are best-value picks at the flat's own rent. Why it's a steal is worked
-- out here, from our own listings: how far under the average rent for the same
-- flat type in the same area (or across MovEazy when the area has too few).
-- A deal flat rented mid-week stays on the list, marked rented.
--
-- The tables are read through deals_feed() only; the team changes them through
-- the crm_deal_* functions (crm.properties.write).
-- ─────────────────────────────────────────────────────────────────────────────

begin;

create table if not exists public.steal_deals (
  week_start  date not null check (extract(isodow from week_start) = 1),
  property_id text not null references public.inventory (property_id) on delete cascade,
  sort        int  not null default 0,
  added_by    text not null default '',
  created_at  timestamptz not null default now(),
  primary key (week_start, property_id)
);

create table if not exists public.day_deals (
  day         date not null,
  kind        text not null check (kind in ('1rk', '1bhk', '2bhk', '3bhk')),
  property_id text not null references public.inventory (property_id) on delete cascade,
  set_by      text not null default '',
  set_at      timestamptz not null default now(),
  primary key (day, kind)
);

alter table public.steal_deals enable row level security;
alter table public.day_deals enable row level security;
revoke all on public.steal_deals from anon, authenticated;
revoke all on public.day_deals from anon, authenticated;

/** The Deal of the Day slot a flat type fills: '1rk' | '1bhk' | '2bhk' | '3bhk' (3 BHK and above), or null. */
create or replace function public.deal_kind(p_flat_type text)
returns text
language sql
immutable
as $$
  select case
    when p_flat_type ~* '(^|\s)(1\s*rk|studio)' then '1rk'
    when p_flat_type ~* '^\s*1\s*bhk' then '1bhk'
    when p_flat_type ~* '^\s*2\s*bhk' then '2bhk'
    when p_flat_type ~* '^\s*([3-9]|1[0-9])\s*bhk' or p_flat_type ~* 'villa|penthouse' then '3bhk'
  end;
$$;

/** Monday of this week, IST. */
create or replace function public.deal_this_monday()
returns date
language sql
stable
as $$
  select date_trunc('week', now() at time zone 'Asia/Kolkata')::date;
$$;

/**
 * Why flat `p` is a steal, from our own listings: "18% below the 2 BHK
 * average in Kasavanahalli" (3+ like flats there), else across MovEazy (5+).
 * Null when it isn't below either — the site then shows its best facts.
 */
create or replace function public.deal_reason(p text)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  f   record;
  avg_area numeric; n_area int;
  avg_all  numeric; n_all  int;
  pct int;
begin
  select property_id, flat_type, rent, area into f from public.inventory where property_id = p;
  if f.property_id is null or coalesce(f.rent, 0) <= 0 or coalesce(f.flat_type, '') = '' then return null; end if;

  select avg(i.rent), count(*) into avg_area, n_area
    from public.inventory i
   where i.status = 'published' and i.property_id <> p and i.rent > 0
     and lower(trim(i.flat_type)) = lower(trim(f.flat_type))
     and lower(trim(coalesce(i.area, ''))) = lower(trim(coalesce(f.area, ''))) and coalesce(f.area, '') <> '';
  if n_area >= 3 and f.rent < avg_area * 0.95 then
    pct := round((1 - f.rent / avg_area) * 100);
    return format('%s%% below the %s average in %s', pct, trim(f.flat_type), trim(f.area));
  end if;

  select avg(i.rent), count(*) into avg_all, n_all
    from public.inventory i
   where i.status = 'published' and i.property_id <> p and i.rent > 0
     and lower(trim(i.flat_type)) = lower(trim(f.flat_type));
  if n_all >= 5 and f.rent < avg_all * 0.95 then
    pct := round((1 - f.rent / avg_all) * 100);
    return format('%s%% below the average %s on MovEazy', pct, trim(f.flat_type));
  end if;
  return null;
end;
$$;

/** One deal flat as the site draws it: the public listing columns, why it's a steal, and whether it's gone. */
create or replace function public.deal_flat_json(p text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
           'listing', jsonb_build_object(
             'property_id', i.property_id, 'city', i.city, 'area', i.area, 'nearby_areas', i.nearby_areas,
             'landmark', i.landmark, 'latitude', i.latitude, 'longitude', i.longitude, 'rent', i.rent,
             'deposit', i.deposit, 'available_from', i.available_from, 'flat_type', i.flat_type,
             'bedrooms', i.bedrooms, 'bathrooms', i.bathrooms, 'furnishing', i.furnishing,
             'max_flatmates', i.max_flatmates, 'gender_pref', i.gender_pref, 'occupants_allowed', i.occupants_allowed,
             'maintenance', i.maintenance, 'floor_number', i.floor_number, 'total_floors', i.total_floors,
             'amenities', i.amenities, 'lifestyle', i.lifestyle, 'house_rules', i.house_rules, 'title', i.title,
             'description', i.description, 'images', i.images, 'cover_image_url', i.cover_image_url,
             'status', i.status, 'is_verified', i.is_verified, 'created_at', i.created_at, 'updated_at', i.updated_at),
           'reason', public.deal_reason(i.property_id),
           'rented', i.status <> 'published')
    from public.inventory i
   where i.property_id = p and i.status in ('published', 'rented');
$$;

/**
 * Everything /find shows: this week's Steal Deals (with the week's dates) and
 * today's Deal of the Day for each type. Anyone may read it.
 */
create or replace function public.deals_feed()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  mon   date := public.deal_this_monday();
  today date := (now() at time zone 'Asia/Kolkata')::date;
  wk    date;
begin
  select max(s.week_start) into wk from public.steal_deals s where s.week_start <= mon;
  return jsonb_build_object(
    'week_start', mon,
    'week_end', mon + 6,
    'today', today,
    'steal', coalesce((
      select jsonb_agg(public.deal_flat_json(s.property_id) order by s.sort, s.created_at)
        from public.steal_deals s
       where s.week_start = wk and public.deal_flat_json(s.property_id) is not null), '[]'::jsonb),
    'day', coalesce((
      select jsonb_agg(d.j || jsonb_build_object('kind', d.kind, 'since', d.day) order by array_position(array['1rk', '1bhk', '2bhk', '3bhk'], d.kind))
        from (
          select distinct on (x.kind) x.kind, x.day, public.deal_flat_json(x.property_id) j
            from public.day_deals x
           where x.day <= today and public.deal_flat_json(x.property_id) is not null
           order by x.kind, x.day desc
        ) d), '[]'::jsonb)
  );
end;
$$;

/* ── The team ─────────────────────────────────────────────────────────────── */

create or replace function public.crm_deal_guard()
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.has_admin_scope('crm.properties.write') then
    raise exception 'Needs permission to edit properties.' using errcode = '42501';
  end if;
  return lower(coalesce(auth.jwt() ->> 'email', ''));
end;
$$;

/** A flat as the CRM's deal lists show it. */
create or replace function public.crm_deal_flat(p text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('property_id', i.property_id, 'title', i.title, 'area', i.area, 'flat_type', i.flat_type,
                            'rent', i.rent, 'status', i.status, 'cover', coalesce(nullif(i.cover_image_url, ''), i.images[1]),
                            'kind', public.deal_kind(i.flat_type), 'reason', public.deal_reason(i.property_id))
    from public.inventory i where i.property_id = p;
$$;

/** The week's Steal Deals and the Deal of the Day calendar from p_from to p_to. */
create or replace function public.crm_deals(p_week date, p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  wk date := date_trunc('week', coalesce(p_week, public.deal_this_monday()))::date;
begin
  perform public.crm_deal_guard();
  return jsonb_build_object(
    'week_start', wk,
    'this_monday', public.deal_this_monday(),
    'today', (now() at time zone 'Asia/Kolkata')::date,
    'steal', coalesce((select jsonb_agg(public.crm_deal_flat(s.property_id) || jsonb_build_object('added_by', s.added_by) order by s.sort, s.created_at)
                         from public.steal_deals s where s.week_start = wk), '[]'::jsonb),
    'weeks', coalesce((select jsonb_agg(jsonb_build_object('week_start', w.week_start, 'n', w.n) order by w.week_start desc)
                         from (select week_start, count(*) n from public.steal_deals group by week_start) w), '[]'::jsonb),
    'days', coalesce((select jsonb_agg(public.crm_deal_flat(d.property_id) || jsonb_build_object('day', d.day, 'slot', d.kind, 'set_by', d.set_by) order by d.day, d.kind)
                        from public.day_deals d where d.day between coalesce(p_from, current_date) and coalesce(p_to, current_date + 30)), '[]'::jsonb)
  );
end;
$$;

/** Set a week's Steal Deals to exactly these flats, in this order (up to 20, published only). */
create or replace function public.crm_deal_steal_set(p_week date, p_ids text[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  who text := public.crm_deal_guard();
  wk  date := date_trunc('week', p_week)::date;
  -- Once each, in the order given.
  ids text[] := array(select x from unnest(coalesce(p_ids, '{}')) with ordinality u(x, n) where coalesce(x, '') <> '' group by x order by min(n));
  bad text;
begin
  if p_week is null then raise exception 'Pick a week.' using errcode = '22023'; end if;
  if cardinality(ids) > 20 then raise exception 'Up to 20 Steal Deals a week.' using errcode = '22023'; end if;
  select x into bad from unnest(ids) x
   where not exists (select 1 from public.inventory i where i.property_id = x and i.status = 'published') limit 1;
  if bad is not null then raise exception '% isn''t a live flat.', bad using errcode = '22023'; end if;

  delete from public.steal_deals s where s.week_start = wk and not (s.property_id = any(ids));
  insert into public.steal_deals (week_start, property_id, sort, added_by)
  select wk, x, n::int, who from unnest(ids) with ordinality u(x, n)
  on conflict (week_start, property_id) do update set sort = excluded.sort;
  return public.crm_deals(wk, null, null);
end;
$$;

/** Add one flat to a week's Steal Deals (the shortcut on a property). */
create or replace function public.crm_deal_steal_add(p_week date, p_property text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  wk  date := date_trunc('week', coalesce(p_week, public.deal_this_monday()))::date;
  cur text[];
begin
  perform public.crm_deal_guard();
  select array_agg(property_id order by sort, created_at) into cur from public.steal_deals where week_start = wk;
  if p_property = any(coalesce(cur, '{}')) then return public.crm_deals(wk, null, null); end if;
  return public.crm_deal_steal_set(wk, coalesce(cur, '{}') || p_property);
end;
$$;

/** Set (or clear, with a null flat) the Deal of the Day for one type on one day. */
create or replace function public.crm_deal_day_set(p_day date, p_kind text, p_property text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  who text := public.crm_deal_guard();
  k   text;
begin
  if p_day is null or p_kind not in ('1rk', '1bhk', '2bhk', '3bhk') then
    raise exception 'Pick a day and a flat type.' using errcode = '22023';
  end if;
  if coalesce(p_property, '') = '' then
    delete from public.day_deals where day = p_day and kind = p_kind;
    return public.crm_deals(null, p_day, p_day);
  end if;
  select public.deal_kind(i.flat_type) into k from public.inventory i where i.property_id = p_property and i.status = 'published';
  if not found then raise exception '% isn''t a live flat.', p_property using errcode = '22023'; end if;
  if k is distinct from p_kind then
    raise exception 'That flat is not a % — pick one of that type.', case p_kind when '1rk' then '1 RK' when '1bhk' then '1 BHK' when '2bhk' then '2 BHK' else '3 BHK or bigger' end
      using errcode = '22023';
  end if;
  insert into public.day_deals (day, kind, property_id, set_by) values (p_day, p_kind, p_property, who)
  on conflict (day, kind) do update set property_id = excluded.property_id, set_by = excluded.set_by, set_at = now();
  return public.crm_deals(null, p_day, p_day);
end;
$$;

revoke all on function public.deal_kind(text) from public;
grant execute on function public.deal_kind(text) to anon, authenticated;
revoke all on function public.deal_this_monday() from public;
grant execute on function public.deal_this_monday() to anon, authenticated;
revoke all on function public.deal_reason(text) from public, anon, authenticated;
revoke all on function public.deal_flat_json(text) from public, anon, authenticated;
revoke all on function public.deals_feed() from public;
grant execute on function public.deals_feed() to anon, authenticated;
revoke all on function public.crm_deal_guard() from public, anon, authenticated;
revoke all on function public.crm_deal_flat(text) from public, anon, authenticated;
do $$
declare
  f text;
begin
  foreach f in array array[
    'public.crm_deals(date, date, date)', 'public.crm_deal_steal_set(date, text[])',
    'public.crm_deal_steal_add(date, text)', 'public.crm_deal_day_set(date, text, text)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

commit;
