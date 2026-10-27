-- ─────────────────────────────────────────────────────────────────────────────
-- "Call Caretaker" on a building's QR page (fe/src/pages/BuildingPage.jsx),
-- its contacts in the CRM (fe/src/pages/crm/CrmBuildingEditor.jsx), and what
-- the owner sees (owner_qr_overview.sql, run AFTER this file).
--
-- Run in the Supabase SQL editor AFTER owner_buildings.sql and lead_intake.sql.
-- Safe to re-run.
--
-- A tenant taps Call Caretaker, gives their mobile (not verified — the same
-- gate as the rest of the site), and gets two numbers: the building's
-- caretaker (who can show the flats right away) and its property manager.
-- Either one unset falls back to MovEazy's team number. Everything they do
-- here is kept, one row each, for the CRM and the building's owner:
--
--   contacts   asked for the numbers
--   call       tapped Call (caretaker or manager)
--   feedback   after the call: pay_token, issues, flat_small, ventilation,
--              call_not_picked or other (with what they wrote)
-- ─────────────────────────────────────────────────────────────────────────────

begin;

alter table public.owner_buildings add column if not exists caretaker_name  text not null default '';
alter table public.owner_buildings add column if not exists caretaker_phone text not null default '';
alter table public.owner_buildings add column if not exists manager_name    text not null default '';
alter table public.owner_buildings add column if not exists manager_phone   text not null default '';

create table if not exists public.building_call_events (
  id          bigint generated always as identity primary key,
  building_id uuid not null references public.owner_buildings (id) on delete cascade,
  visitor     text not null default '',
  user_id     uuid references auth.users (id) on delete set null,
  name        text not null default '',
  phone       text not null check (phone ~ '^[6-9][0-9]{9}$'),
  kind        text not null check (kind in ('contacts', 'call', 'feedback')),
  target      text not null default '' check (target in ('', 'caretaker', 'manager')),
  feedback    text not null default ''
                check (feedback in ('', 'pay_token', 'issues', 'flat_small', 'ventilation', 'call_not_picked', 'other')),
  note        text not null default '' check (length(note) <= 1000),
  created_at  timestamptz not null default now()
);
create index if not exists building_call_events_building_idx on public.building_call_events (building_id, created_at desc);
create index if not exists building_call_events_visitor_idx on public.building_call_events (visitor, created_at desc);
alter table public.building_call_events enable row level security;
revoke all on public.building_call_events from anon, authenticated;

/** MovEazy's team number, when a building has no caretaker or manager of its own. */
create or replace function public.building_call_fallback()
returns text language sql immutable as $$ select '9146969162' $$;

/**
 * The tenant's side: log what they did, and for 'contacts' hand back the two
 * numbers. Anyone may call it with a building's code and a mobile; at most 60
 * a visitor an hour. → { caretaker: {name, phone}, manager: {name, phone} } for
 * 'contacts', else null.
 */
create or replace function public.building_call_desk(
  p_code text, p_visitor text, p_phone text, p_name text default '',
  p_kind text default 'contacts', p_target text default '', p_feedback text default '', p_note text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  bid uuid := public.building_by_code(p_code);
  ph  text := public.normalize_mobile(p_phone);
  v   text := left(trim(coalesce(p_visitor, '')), 64);
  b   public.owner_buildings;
begin
  if bid is null then raise exception 'This building isn''t taking visits right now.' using errcode = '22023'; end if;
  if ph is null or ph !~ '^[6-9][0-9]{9}$' then raise exception 'Enter a valid 10-digit mobile number.' using errcode = '22023'; end if;
  if coalesce(p_kind, '') not in ('contacts', 'call', 'feedback') then raise exception 'Unknown action.' using errcode = '22023'; end if;
  if p_kind = 'call' and coalesce(p_target, '') not in ('caretaker', 'manager') then raise exception 'Call whom?' using errcode = '22023'; end if;
  if p_kind = 'feedback' and coalesce(p_feedback, '') not in ('pay_token', 'issues', 'flat_small', 'ventilation', 'call_not_picked', 'other') then
    raise exception 'Unknown feedback.' using errcode = '22023';
  end if;
  if (select count(*) from public.building_call_events e
       where e.created_at > now() - interval '1 hour'
         and (e.phone = ph or (v <> '' and e.visitor = v))) >= 60 then
    raise exception 'Too many tries — please wait a little.' using errcode = '22023';
  end if;

  insert into public.building_call_events (building_id, visitor, user_id, name, phone, kind, target, feedback, note)
  values (bid, v, auth.uid(), left(trim(coalesce(p_name, '')), 80), ph, p_kind,
          case when p_kind = 'call' then p_target else '' end,
          case when p_kind = 'feedback' then p_feedback else '' end,
          case when p_kind = 'feedback' then left(trim(coalesce(p_note, '')), 1000) else '' end);

  if p_kind <> 'contacts' then return null; end if;
  select * into b from public.owner_buildings where id = bid;
  return jsonb_build_object(
    'caretaker', jsonb_build_object(
      'name',  case when b.caretaker_phone <> '' then nullif(b.caretaker_name, '') end,
      'phone', coalesce(nullif(b.caretaker_phone, ''), public.building_call_fallback())),
    'manager', jsonb_build_object(
      'name',  case when b.manager_phone <> '' then nullif(b.manager_name, '') end,
      'phone', coalesce(nullif(b.manager_phone, ''), public.building_call_fallback())));
end;
$$;

/**
 * The CRM's building editor: read the two contacts and what tenants did
 * (p_patch null), or save the contacts ({caretaker_name, caretaker_phone,
 * manager_name, manager_phone}; '' clears one).
 */
create or replace function public.crm_building_call_desk(p_building uuid, p_patch jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  cp text;
  mp text;
begin
  if p_patch is not null then
    if not public.has_admin_scope('crm.properties.write') then
      raise exception 'Needs permission to change properties.' using errcode = '42501';
    end if;
    cp := case when p_patch ? 'caretaker_phone' then coalesce(public.normalize_mobile(p_patch ->> 'caretaker_phone'), '') end;
    mp := case when p_patch ? 'manager_phone' then coalesce(public.normalize_mobile(p_patch ->> 'manager_phone'), '') end;
    if (p_patch ? 'caretaker_phone' and trim(coalesce(p_patch ->> 'caretaker_phone', '')) <> '' and cp !~ '^[6-9][0-9]{9}$')
       or (p_patch ? 'manager_phone' and trim(coalesce(p_patch ->> 'manager_phone', '')) <> '' and mp !~ '^[6-9][0-9]{9}$') then
      raise exception 'Enter a valid 10-digit mobile number.' using errcode = '22023';
    end if;
    update public.owner_buildings b set
      caretaker_name  = case when p_patch ? 'caretaker_name' then left(trim(coalesce(p_patch ->> 'caretaker_name', '')), 80) else b.caretaker_name end,
      caretaker_phone = coalesce(cp, b.caretaker_phone),
      manager_name    = case when p_patch ? 'manager_name' then left(trim(coalesce(p_patch ->> 'manager_name', '')), 80) else b.manager_name end,
      manager_phone   = coalesce(mp, b.manager_phone),
      updated_at      = now()
    where b.id = p_building;
    if not found then raise exception 'No such building.' using errcode = '22023'; end if;
  elsif not public.is_crm_staff() then
    raise exception 'CRM staff only.' using errcode = '42501';
  end if;

  return (
    select jsonb_build_object(
      'caretaker_name', b.caretaker_name, 'caretaker_phone', b.caretaker_phone,
      'manager_name', b.manager_name, 'manager_phone', b.manager_phone,
      'fallback', public.building_call_fallback(),
      'events', coalesce((
        select jsonb_agg(jsonb_build_object('at', e.created_at, 'name', e.name, 'phone', e.phone, 'kind', e.kind,
                                            'target', e.target, 'feedback', e.feedback, 'note', e.note) order by e.created_at desc)
          from (select * from public.building_call_events where building_id = b.id order by created_at desc limit 300) e), '[]'::jsonb))
    from public.owner_buildings b where b.id = p_building);
end;
$$;

revoke all on function public.building_call_fallback() from public;
grant execute on function public.building_call_fallback() to anon, authenticated;
revoke all on function public.building_call_desk(text, text, text, text, text, text, text, text) from public;
grant execute on function public.building_call_desk(text, text, text, text, text, text, text, text) to anon, authenticated;
revoke all on function public.crm_building_call_desk(uuid, jsonb) from public, anon;
grant execute on function public.crm_building_call_desk(uuid, jsonb) to authenticated;

commit;
