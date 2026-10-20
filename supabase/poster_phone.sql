-- The two phone numbers printed on the red To-Let poster (MovEazy-FE
-- lib/qrPoster.js "redtolet", components/QrPosterBlock.jsx), one per line.
--
-- They aren't the owner's numbers: whoever makes the poster sets them — the
-- MovEazy team in the CRM, or the owner in the owner app. A building's poster
-- and each flat's poster have their own pair; nothing carries over from one
-- to the other.
--
--   poster_phone_get(property, building)   { phone, phone2 }: the saved pair,
--                                          the flat's when a property is
--                                          given, else the building's.
--   poster_phone_set(property, building, phone, phone2)
--                                          save the pair — both ten digits
--                                          (a leading +91 or 0 is dropped),
--                                          or both '' to clear.
--
-- Who may: CRM staff read, crm.properties.write saves; an approved owner reads
-- and saves their own flats and buildings. The columns aren't granted to
-- anyone (inventory is read column by column), so these are the only way in.
--
-- Safe to re-run.

begin;

alter table public.owner_buildings add column if not exists poster_phone text not null default '';
alter table public.owner_buildings add column if not exists poster_phone2 text not null default '';
alter table public.inventory add column if not exists poster_phone text not null default '';
alter table public.inventory add column if not exists poster_phone2 text not null default '';

/** May the caller see or set this flat's / building's poster numbers? `write` asks for saving. */
create or replace function public.poster_phone_allowed(p_property text, p_building uuid, write boolean)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and (
    (case when write then public.has_admin_scope('crm.properties.write') else public.is_crm_staff() end)
    or (public.is_approved_owner() and (
      (p_property is not null and public.owner_has_property(p_property))
      or (p_property is null and exists (select 1 from public.owner_buildings b where b.id = p_building and b.owner_id = auth.uid())))));
$$;
revoke all on function public.poster_phone_allowed(text, uuid, boolean) from public, anon, authenticated;

/** "+91 98765 43210" → "9876543210"; null when it isn't ten digits. '' stays ''. */
create or replace function public.poster_phone_clean(p text)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
  d text := regexp_replace(coalesce(p, ''), '\D', '', 'g');
begin
  if length(d) = 12 and d like '91%' then d := substr(d, 3);
  elsif length(d) = 11 and d like '0%' then d := substr(d, 2);
  end if;
  return case when d = '' or d ~ '^[0-9]{10}$' then d end;
end;
$$;
revoke all on function public.poster_phone_clean(text) from public, anon, authenticated;

/** { phone, phone2 }: the flat's pair, or the building's. */
create or replace function public.poster_phone_get(p_property text default null, p_building uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  pid text := nullif(upper(trim(coalesce(p_property, ''))), '');
begin
  if pid is null and p_building is null then raise exception 'Which flat or building?' using errcode = '22023'; end if;
  if not public.poster_phone_allowed(pid, case when pid is null then p_building end, false) then
    raise exception 'Not yours.' using errcode = '42501';
  end if;
  if pid is not null then
    return (select jsonb_build_object('phone', i.poster_phone, 'phone2', i.poster_phone2) from public.inventory i where i.property_id = pid);
  end if;
  return (select jsonb_build_object('phone', b.poster_phone, 'phone2', b.poster_phone2) from public.owner_buildings b where b.id = p_building);
end;
$$;

-- The one-number version this replaces.
drop function if exists public.poster_phone_set(text, uuid, text);

/** Save the pair: both ten digits, or both '' to clear. Returns { phone, phone2 } as saved. */
create or replace function public.poster_phone_set(p_property text default null, p_building uuid default null, p_phone text default '', p_phone2 text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  pid text := nullif(upper(trim(coalesce(p_property, ''))), '');
  a   text := public.poster_phone_clean(p_phone);
  b   text := public.poster_phone_clean(p_phone2);
begin
  if pid is null and p_building is null then raise exception 'Which flat or building?' using errcode = '22023'; end if;
  if not public.poster_phone_allowed(pid, case when pid is null then p_building end, true) then
    raise exception 'Not yours.' using errcode = '42501';
  end if;
  if a is null or b is null then raise exception 'Enter 10-digit phone numbers.' using errcode = '22023'; end if;
  if (a = '') <> (b = '') then raise exception 'Enter both phone numbers.' using errcode = '22023'; end if;
  if pid is not null then
    update public.inventory set poster_phone = a, poster_phone2 = b where property_id = pid;
  else
    update public.owner_buildings set poster_phone = a, poster_phone2 = b where id = p_building;
  end if;
  if not found then raise exception 'Not found.' using errcode = '22023'; end if;
  return jsonb_build_object('phone', a, 'phone2', b);
end;
$$;

revoke all on function public.poster_phone_get(text, uuid) from public, anon;
grant execute on function public.poster_phone_get(text, uuid) to authenticated;
revoke all on function public.poster_phone_set(text, uuid, text, text) from public, anon;
grant execute on function public.poster_phone_set(text, uuid, text, text) to authenticated;

commit;
