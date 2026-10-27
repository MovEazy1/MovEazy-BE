-- ─────────────────────────────────────────────────────────────────────────────
-- Every tenant of a building in one list — the ones the MovEazy team added
-- (building_tenant_tracks.sql) and the ones whose number came from the QR
-- page (building_call_desk.sql) — for the CRM's tenants page and the
-- building's owner (fe/src/pages/crm/CrmBuildingTenantsPage.jsx,
-- fe/src/pages/owners/BuildingTenants.jsx), and the bar on the CRM's home.
--
-- Run in the Supabase SQL editor AFTER building_tenant_tracks.sql and
-- building_call_desk.sql. Safe to re-run.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

/**
 * One building's tenants, a row per mobile, most recent first:
 *   { phone, name, last_at,
 *     track: the team's card (tenant_track_json) | null,
 *     qr: { first_at, last_at, asked, called: [caretaker|manager], feedback: [{ kind, note, at }] } | null }
 * Internal: the CRM and the owner each call it through their own door.
 */
create or replace function public.building_tenants_board(p_building uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with phones as (
    select phone from public.building_tenant_tracks where building_id = p_building
    union
    select phone from public.building_call_events where building_id = p_building),
  rows as (
    select ph.phone,
           (select t from public.building_tenant_tracks t where t.building_id = p_building and t.phone = ph.phone) as t,
           (select jsonb_build_object(
                     'first_at', min(e.created_at), 'last_at', max(e.created_at),
                     'asked', count(*) filter (where e.kind = 'contacts'),
                     'called', coalesce(to_jsonb(array_agg(distinct e.target) filter (where e.kind = 'call')), '[]'::jsonb),
                     'feedback', coalesce(jsonb_agg(jsonb_build_object('kind', e.feedback, 'note', e.note, 'at', e.created_at) order by e.created_at desc)
                                            filter (where e.kind = 'feedback'), '[]'::jsonb),
                     'name', (array_agg(e.name order by e.created_at desc) filter (where e.name <> ''))[1])
              from public.building_call_events e where e.building_id = p_building and e.phone = ph.phone
            having count(*) > 0) as qr
      from phones ph)
  select coalesce(jsonb_agg(x order by x ->> 'last_at' desc), '[]'::jsonb)
    from (
      select jsonb_build_object(
               'phone', r.phone,
               'name', coalesce(nullif((r.t).name, ''), r.qr ->> 'name', ''),
               'last_at', greatest((r.t).updated_at, (r.qr ->> 'last_at')::timestamptz),
               'track', case when (r.t).id is not null then public.tenant_track_json(r.t) end,
               'qr', r.qr - 'name') as x
        from rows r) z;
$$;

/** The CRM's tenants page for a building: { building: { id, name, code, enabled }, tenants: [...], reasons: [...] }. */
create or replace function public.crm_building_tenants(p_building uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  return (
    select jsonb_build_object(
      'building', jsonb_build_object('id', b.id, 'name', b.name, 'code', b.code, 'enabled', b.tenant_tracker),
      'tenants', public.building_tenants_board(b.id),
      'reasons', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'label', r.label) order by r.created_at)
                             from public.tenant_reason_options r where r.removed_at is null), '[]'::jsonb),
      'flats', coalesce((select jsonb_agg(jsonb_build_object('property_id', i.property_id, 'unit_no', i.unit_no)
                                          order by i.unit_order nulls last, i.unit_no)
                           from public.inventory i where i.building_id = b.id), '[]'::jsonb))
    from public.owner_buildings b where b.id = p_building);
end;
$$;

/** The bar on the CRM's home: each building that tracks tenants, how many, and how many follow-ups are due. */
create or replace function public.crm_tracked_buildings()
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
             'id', b.id, 'name', b.name, 'code', b.code,
             'tenants', (select count(*) from (select phone from public.building_tenant_tracks where building_id = b.id
                                                union select phone from public.building_call_events where building_id = b.id) p),
             'due', (select count(*) from public.building_tenant_tracks t
                      where t.building_id = b.id and t.follow_up_on <= (now() at time zone 'Asia/Kolkata')::date))
           order by b.name)
      from public.owner_buildings b where b.tenant_tracker), '[]'::jsonb);
end;
$$;

/** The owner's view of the same list, for a building of theirs: { building: { id, name, code }, tenants: [...] }. */
create or replace function public.owner_building_tenants(p_building uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select case when public.is_approved_owner() then (
    select jsonb_build_object('building', jsonb_build_object('id', b.id, 'name', b.name, 'code', b.code),
                              'tenants', public.building_tenants_board(b.id))
      from public.owner_buildings b where b.id = p_building and b.owner_id = auth.uid()) end;
$$;

revoke all on function public.building_tenants_board(uuid) from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array['public.crm_building_tenants(uuid)', 'public.crm_tracked_buildings()', 'public.owner_building_tenants(uuid)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

commit;
