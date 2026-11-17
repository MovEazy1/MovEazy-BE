-- ─────────────────────────────────────────────────────────────────────────────
-- Standard rents for the deals' "% lower" line (2026-11-17).
--
-- Steal Deals of the Week and Deal of the Day used to say "18% below the 2 BHK
-- average in X", worked out from our own listings — it moved about as listings
-- came and went. Now each flat is compared with a standard rent the CRM sets:
--
--   deal_standard_rents  one row per area ('' = everywhere, seeded with HSR's):
--                        r1 / r2 / r3   standard 1 / 2 / 3 BHK rent
--                        s2 / s3        premium society 2 / 3 BHK flats
--   deal_reason(p)       "18% lower than the standard 2 BHK rent in HSR (₹59k)";
--                        a flat above the standard but under the premium
--                        society rent: "8% lower than premium society 2 BHK
--                        flats (₹65k)". Only when 5% or more lower; 1 RK and
--                        4+ BHK have no standard. An area row (matched within
--                        the flat's area name, longest first) beats ''.
--   crm_deal_standards / crm_deal_standard_save / crm_deal_standard_remove
--                        CRM → Deals → Deal of the Day (editing properties).
-- Re-runnable. On a fresh database run this before find_deals.sql (its deal_flat_json calls deal_reason).
-- ─────────────────────────────────────────────────────────────────────────────
begin;

create table if not exists public.deal_standard_rents (
  area       text primary key check (area = lower(trim(area)) and length(area) <= 60),
  label      text not null default '' check (length(label) <= 60),
  r1         int check (r1 is null or r1 between 1000 and 10000000),
  r2         int check (r2 is null or r2 between 1000 and 10000000),
  r3         int check (r3 is null or r3 between 1000 and 10000000),
  s2         int check (s2 is null or s2 between 1000 and 10000000),
  s3         int check (s3 is null or s3 between 1000 and 10000000),
  updated_at timestamptz not null default now(),
  updated_by text not null default ''
);
alter table public.deal_standard_rents enable row level security;
revoke all on public.deal_standard_rents from anon, authenticated;

-- Everywhere, until an area has its own: HSR's numbers.
insert into public.deal_standard_rents (area, label, r1, r2, r3, s2, s3, updated_by)
values ('', 'HSR', 33000, 59000, 75000, 65000, 95000, 'seed')
on conflict (area) do nothing;

/** "₹59k", "₹1.2L". */
create or replace function public.deal_inr_short(v int)
returns text
language sql
immutable
as $$
  select case when v >= 100000 then '₹' || trim(to_char(v / 100000.0, 'FM999990.0')) || 'L'
              else '₹' || round(v / 1000.0)::int || 'k' end;
$$;

/** Why flat `p` is a deal, against the standard rents. Null when it isn't 5%+ lower. */
create or replace function public.deal_reason(p text)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  f    record;
  st   public.deal_standard_rents;
  bhk  int;
  std  int;
  soc  int;
  pct  int;
  place text;
begin
  select property_id, flat_type, rent, area into f from public.inventory where property_id = p;
  if f.property_id is null or coalesce(f.rent, 0) <= 0 then return null; end if;
  -- 1, 2 or 3 BHK only (not 1 RK, not 4+ or villas).
  bhk := nullif(substring(lower(coalesce(f.flat_type, '')) from '^\s*([123])\s*bhk'), '')::int;
  if bhk is null then return null; end if;

  -- The flat's area's own standards, else everywhere's.
  select * into st from public.deal_standard_rents d
   where d.area <> '' and position(d.area in lower(coalesce(f.area, ''))) > 0
   order by length(d.area) desc limit 1;
  if st.area is null then select * into st from public.deal_standard_rents where area = ''; end if;
  if st.area is null then return null; end if;

  std := case bhk when 1 then st.r1 when 2 then st.r2 else st.r3 end;
  soc := case bhk when 2 then st.s2 when 3 then st.s3 end;
  place := case when st.area <> '' then nullif(trim(st.label), '')
                when lower(coalesce(f.area, '')) like '%' || lower(coalesce(nullif(trim(st.label), ''), '~')) || '%' then trim(st.label) end;

  if std is not null and f.rent <= std * 0.95 then
    pct := floor((1 - f.rent::numeric / std) * 100);
    return format('%s%% lower than the standard %s BHK rent%s (%s)', pct, bhk, coalesce(' in ' || place, ''), public.deal_inr_short(std));
  end if;
  if soc is not null and (std is null or f.rent > std) and f.rent <= soc * 0.95 then
    pct := floor((1 - f.rent::numeric / soc) * 100);
    return format('%s%% lower than premium society %s BHK flats%s (%s)', pct, bhk, coalesce(' in ' || place, ''), public.deal_inr_short(soc));
  end if;
  return null;
end;
$$;

/** The standard rents, everywhere first (CRM staff). */
create or replace function public.crm_deal_standards()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(d) order by d.area <> '', d.area) from public.deal_standard_rents d), '[]'::jsonb);
end;
$$;

/** Add or change one area's standards: { area ('' = everywhere), label, r1, r2, r3, s2, s3 }. */
create or replace function public.crm_deal_standard_save(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  who text := public.crm_deal_guard();
  a   text := lower(trim(coalesce(p ->> 'area', '')));
  num text;
begin
  if length(a) > 60 then raise exception 'Keep the area name short.' using errcode = '22023'; end if;
  foreach num in array array['r1', 'r2', 'r3', 's2', 's3'] loop
    if coalesce(p ->> num, '') <> '' and (p ->> num) !~ '^\d{4,8}$' then
      raise exception 'Rents are whole rupees, e.g. 59000.' using errcode = '22023';
    end if;
  end loop;
  insert into public.deal_standard_rents as d (area, label, r1, r2, r3, s2, s3, updated_at, updated_by)
  values (a, left(trim(coalesce(nullif(p ->> 'label', ''), p ->> 'area', '')), 60),
          nullif(p ->> 'r1', '')::int, nullif(p ->> 'r2', '')::int, nullif(p ->> 'r3', '')::int,
          nullif(p ->> 's2', '')::int, nullif(p ->> 's3', '')::int, now(), who)
  on conflict (area) do update set label = excluded.label, r1 = excluded.r1, r2 = excluded.r2, r3 = excluded.r3,
                                   s2 = excluded.s2, s3 = excluded.s3, updated_at = now(), updated_by = who;
  return public.crm_deal_standards();
end;
$$;

/** Drop an area's own standards (it falls back to everywhere's). Everywhere's stays. */
create or replace function public.crm_deal_standard_remove(p_area text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  who text := public.crm_deal_guard();
begin
  if coalesce(trim(p_area), '') = '' then raise exception 'The standard for everywhere stays — change its numbers instead.' using errcode = '22023'; end if;
  delete from public.deal_standard_rents where area = lower(trim(p_area));
  return public.crm_deal_standards();
end;
$$;

revoke all on function public.deal_reason(text) from public, anon, authenticated;
do $$
declare
  f text;
begin
  foreach f in array array['public.crm_deal_standards()', 'public.crm_deal_standard_save(jsonb)', 'public.crm_deal_standard_remove(text)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

commit;
