-- The areas: one list, kept in the CRM (MovEazy-FE pages/crm/CrmAreasPage.jsx),
-- that every area picker reads (lib/areas.js) — the tenant's questionnaire,
-- List my Flat, the owner and partner apps, and the CRM's own forms.
--
--   name      as people pick it: "HSR", "Kudlu Gate".
--   chip      a quick chip on the tenant's "Which localities?" step; the rest
--             are found by searching.
--   parent_id the wider area it sits inside ("Kudlu Gate" in "HSR Extension"):
--             asking for the parent reaches its flats. One level only.
--   sort      the order you arranged; chips follow it.
--   active    false = removed: gone from every picker, while the flats and
--             clients already in it keep it.
--
-- Everyone reads (a tenant picks areas before signing in). Only the super
-- admin changes it, through area_save / area_reorder below.
--
-- Seeded with the list the app carried in code (data/preferenceOptions.js):
-- 16 chips, 7 searchable, the HSR Extension group — and, hidden, every other
-- area a live flat already uses, to review. Safe to re-run: the seed only
-- adds names that aren't there.

begin;

create table if not exists public.areas (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (length(trim(name)) between 2 and 60),
  chip       boolean not null default false,
  parent_id  uuid references public.areas (id) on delete set null,
  sort       int not null default 0,
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (parent_id is distinct from id)
);
create unique index if not exists areas_name_key on public.areas (lower(trim(name)));

alter table public.areas enable row level security;
drop policy if exists "anyone reads areas" on public.areas;
create policy "anyone reads areas" on public.areas for select using (true);
revoke all on public.areas from anon, authenticated;
grant select on public.areas to anon, authenticated;

-- The seed: the list in code, in its order.
insert into public.areas (name, chip, sort)
select x.name, x.n <= 16, x.n * 10
  from unnest(array[
    'HSR', 'HSR Extension', 'Koramangala', 'Indiranagar', 'Bellandur',
    'Kudlu Gate', 'Kudlu Road', 'Harlur Road', 'Silver County Road',
    'Whitefield', 'Hoodi', 'Electronic City', 'Sarjapur', 'BTM', 'JP Nagar', 'Marathahalli',
    'ITI Layout', 'Jayanagar', 'Hebbal', 'Mahadevpura', 'Bannerghatta Rd', 'Yelahanka', 'Rajajinagar'
  ]) with ordinality as x(name, n)
 where not exists (select 1 from public.areas a where lower(trim(a.name)) = lower(x.name));

update public.areas c set parent_id = p.id
  from public.areas p
 where lower(p.name) = 'hsr extension'
   and lower(c.name) in ('kudlu gate', 'kudlu road', 'harlur road', 'silver county road', 'iti layout')
   and c.parent_id is null;

-- Every other area a live flat is in: hidden, after the rest, to review.
insert into public.areas (name, chip, sort, active)
select v.name, false, 1000 + row_number() over (order by v.name) * 10, false
  from (select distinct on (lower(trim(i.area))) trim(i.area) as name
          from public.inventory i
         where i.status = 'published' and length(trim(coalesce(i.area, ''))) between 2 and 60
         order by lower(trim(i.area)), trim(i.area)) v
 where not exists (select 1 from public.areas a where lower(trim(a.name)) = lower(v.name));

/**
 * Add (no id) or change an area: { id?, name?, chip?, parent_id?, active? }.
 * Keys left out stay as they are. Returns the row.
 */
create or replace function public.area_save(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  aid uuid := nullif(p ->> 'id', '')::uuid;
  nm  text := regexp_replace(trim(coalesce(p ->> 'name', '')), '\s+', ' ', 'g');
  par uuid := nullif(p ->> 'parent_id', '')::uuid;
begin
  if not public.is_super_admin() then raise exception 'Only the super admin can change the areas.' using errcode = '42501'; end if;
  if (aid is null or p ? 'name') and length(nm) not between 2 and 60 then
    raise exception 'Give the area a name (2 to 60 letters).' using errcode = '22023';
  end if;
  if (aid is null or p ? 'name') and exists (select 1 from public.areas a where lower(trim(a.name)) = lower(nm) and a.id is distinct from aid) then
    raise exception '% is already on the list.', nm using errcode = '23505';
  end if;
  if p ? 'parent_id' and par is not null then
    if par = aid then raise exception 'An area can''t be inside itself.' using errcode = '22023'; end if;
    if not exists (select 1 from public.areas a where a.id = par) then raise exception 'That wider area isn''t on the list.' using errcode = '22023'; end if;
    if exists (select 1 from public.areas a where a.id = par and a.parent_id is not null) then
      raise exception 'That area is itself inside another; pick the wider one.' using errcode = '22023';
    end if;
    if aid is not null and exists (select 1 from public.areas a where a.parent_id = aid) then
      raise exception 'Other areas sit inside this one, so it can''t go inside another.' using errcode = '22023';
    end if;
  end if;

  if aid is null then
    insert into public.areas (name, chip, parent_id, sort, active)
    values (nm, coalesce((p ->> 'chip')::boolean, false), par,
            coalesce((select max(a.sort) from public.areas a where a.active), 0) + 10, coalesce((p ->> 'active')::boolean, true))
    returning id into aid;
  else
    update public.areas a set
      name       = case when p ? 'name' then nm else a.name end,
      chip       = case when p ? 'chip' then coalesce((p ->> 'chip')::boolean, false) else a.chip end,
      parent_id  = case when p ? 'parent_id' then par else a.parent_id end,
      active     = case when p ? 'active' then coalesce((p ->> 'active')::boolean, true) else a.active end,
      -- Brought back: to the end of the shown list.
      sort       = case when p ? 'active' and (p ->> 'active')::boolean and not a.active
                        then coalesce((select max(b.sort) from public.areas b where b.active), 0) + 10 else a.sort end,
      updated_at = now()
    where a.id = aid;
    if not found then raise exception 'That area isn''t on the list.' using errcode = '22023'; end if;
  end if;
  return (select to_jsonb(a) from public.areas a where a.id = aid);
end;
$$;

/** Put the areas in this order (the ids as listed); the rest keep theirs after. */
create or replace function public.area_reorder(p_ids uuid[])
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_super_admin() then raise exception 'Only the super admin can change the areas.' using errcode = '42501'; end if;
  update public.areas a set sort = x.n * 10, updated_at = now()
    from unnest(p_ids) with ordinality as x(id, n)
   where a.id = x.id;
end;
$$;

revoke all on function public.area_save(jsonb) from public, anon;
grant execute on function public.area_save(jsonb) to authenticated;
revoke all on function public.area_reorder(uuid[]) from public, anon;
grant execute on function public.area_reorder(uuid[]) to authenticated;

commit;
