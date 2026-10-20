-- The phone number printed on the red To-Let poster (MovEazy-FE
-- lib/qrPoster.js "tolet-a1", components/QrPosterBlock.jsx).
--
-- It isn't the owner's number: whoever makes the poster sets it — the MovEazy
-- team in the CRM, or the owner in the owner app — on a building, or on one
-- flat. A flat's poster uses the flat's own number, else its building's.
--
--   poster_phone_get(property, building)   the saved numbers, for the form.
--   poster_phone_set(property, building, phone)
--                                          save one (on the flat when a
--                                          property is given, else on the
--                                          building); '' clears it.
--
-- Who may: CRM staff read, crm.properties.write saves; an approved owner reads
-- and saves their own flats and buildings. The columns aren't granted to
-- anyone (inventory is read column by column), so these are the only way in.
--
-- Safe to re-run.

begin;

alter table public.owner_buildings add column if not exists poster_phone text not null default '';
alter table public.inventory add column if not exists poster_phone text not null default '';

/** May the caller see or set this flat's / building's poster number? `write` asks for saving. */
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

/** { flat, building }: the flat's own number and its building's (or the building's alone). */
create or replace function public.poster_phone_get(p_property text default null, p_building uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  pid text := nullif(upper(trim(coalesce(p_property, ''))), '');
  bid uuid := p_building;
begin
  if pid is null and bid is null then raise exception 'Which flat or building?' using errcode = '22023'; end if;
  if not public.poster_phone_allowed(pid, case when pid is null then bid end, false) then
    raise exception 'Not your flat.' using errcode = '42501';
  end if;
  if pid is not null then
    select i.building_id into bid from public.inventory i where i.property_id = pid;
  end if;
  return jsonb_build_object(
    'flat', case when pid is null then null else (select i.poster_phone from public.inventory i where i.property_id = pid) end,
    'building', (select b.poster_phone from public.owner_buildings b where b.id = bid));
end;
$$;

/** Save the poster number: ten digits (a leading +91 or 0 is dropped), or '' to clear. Returns what was saved. */
create or replace function public.poster_phone_set(p_property text default null, p_building uuid default null, p_phone text default '')
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  pid text := nullif(upper(trim(coalesce(p_property, ''))), '');
  d   text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  if pid is null and p_building is null then raise exception 'Which flat or building?' using errcode = '22023'; end if;
  if not public.poster_phone_allowed(pid, case when pid is null then p_building end, true) then
    raise exception 'Not your flat.' using errcode = '42501';
  end if;
  if length(d) = 12 and d like '91%' then d := substr(d, 3);
  elsif length(d) = 11 and d like '0%' then d := substr(d, 2);
  end if;
  if d <> '' and d !~ '^[0-9]{10}$' then
    raise exception 'Enter a 10-digit phone number.' using errcode = '22023';
  end if;
  if pid is not null then
    update public.inventory set poster_phone = d where property_id = pid;
  else
    update public.owner_buildings set poster_phone = d where id = p_building;
  end if;
  if not found then raise exception 'Not found.' using errcode = '22023'; end if;
  return d;
end;
$$;

revoke all on function public.poster_phone_get(text, uuid) from public, anon;
grant execute on function public.poster_phone_get(text, uuid) to authenticated;
revoke all on function public.poster_phone_set(text, uuid, text) from public, anon;
grant execute on function public.poster_phone_set(text, uuid, text) to authenticated;

commit;
