-- ─────────────────────────────────────────────────────────────────────────────
-- Society numbers, v2 (2026-11-17) — changes to society_partners.sql:
--   * one number of any kind (manager, guard or broker) is enough to submit;
--     the app advises 1 manager, 2–3 guards, 4–5 brokers
--   * a partner can add, change and remove numbers any time the society is
--     theirs, live or not (sp_owned)
--   * removing (or changing) a number keeps the old one for the CRM, marked
--     removed by the partner; the partner's app no longer shows it
--   * counts per kind (sp_contact_counts) for the "add more" nudges
-- Re-runnable.
-- ─────────────────────────────────────────────────────────────────────────────
begin;

alter table public.society_prospect_contacts add column if not exists removed_at timestamptz;
alter table public.society_prospect_contacts add column if not exists removed_by text not null default '';

create or replace function public.sp_contact_counts(p_id uuid, p_partner uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'manager', count(*) filter (where c.kind = 'manager'),
    'guard', count(*) filter (where c.kind = 'guard'),
    'broker', count(*) filter (where c.kind = 'broker'))
  from public.society_prospect_contacts c
  where c.prospect_id = p_id and c.partner_id = p_partner and c.removed_at is null;
$$;

create or replace function public.sp_owned(p_id uuid)
returns public.society_prospects
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := public.sp_require();
  s  public.society_prospects;
begin
  select * into s from public.society_prospects where id = p_id for update;
  if s.id is null then raise exception 'No such society.' using errcode = '22023'; end if;
  if s.onboard_by is distinct from me then raise exception 'Start onboarding this society first.' using errcode = '42501'; end if;
  return s;
end;
$$;

create or replace function public.sp_missing(p_id uuid)
returns text[]
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  s   public.society_prospects;
  out text[] := '{}';
  a   text;
begin
  select * into s from public.society_prospects where id = p_id;
  -- At least one number — the manager's, a guard's or a broker's (more are advised, not required).
  if not exists (select 1 from public.society_prospect_contacts c where c.prospect_id = p_id and c.kind in ('manager', 'guard', 'broker')
                    and c.partner_id = s.onboard_by and c.removed_at is null) then
    out := out || 'At least one number: the society manager, a security guard or a broker'::text;
  end if;
  if cardinality(s.partner_amenities) = 0 then
    out := out || 'The amenities'::text;
  else
    foreach a in array s.partner_amenities loop
      if jsonb_array_length(coalesce(s.amenity_photos -> a, '[]'::jsonb)) = 0 then
        out := out || format('A photo of the %s', lower(a));
      end if;
    end loop;
  end if;
  if jsonb_array_length(s.flat_photos) < 5 then
    out := out || format('%s more photo%s of a sample flat', 5 - jsonb_array_length(s.flat_photos),
                         case when 5 - jsonb_array_length(s.flat_photos) = 1 then '' else 's' end);
  end if;
  return out;
end;
$$;

create or replace function public.sp_json(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', s.id, 'name', s.name, 'area', s.area, 'road', s.road, 'address', s.address, 'lat', s.lat, 'lng', s.lng,
    'status', s.onboard_status, 'mine', s.onboard_by = auth.uid(), 'locked_until', s.onboard_locked_until,
    'started_at', s.onboard_started_at, 'note', s.onboard_note, 'submitted_at', s.submitted_at, 'live', s.live,
    'public_code', s.public_code, 'amenities', s.partner_amenities, 'amenity_photos', s.amenity_photos,
    'flat_photos', s.flat_photos, 'rents', s.partner_rents, 'research_amenities', s.amenities,
    'facts', s.facts, 'added_by_partner', s.added_by_partner,
    'contacts', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'kind', c.kind, 'name', c.name, 'phone', c.phone, 'note', c.note)
                                    order by array_position(array['manager', 'guard', 'broker'], c.kind), c.created_at)
                            from public.society_prospect_contacts c where c.prospect_id = s.id and c.partner_id = auth.uid() and c.removed_at is null), '[]'::jsonb),
    'contact_counts', public.sp_contact_counts(s.id, auth.uid()),
    'missing', public.sp_missing(s.id),
    'leads', (select count(*) from public.society_leads l where l.prospect_id = s.id and l.partner_id = auth.uid()),
    'amenity_list', to_jsonb(public.society_amenity_list()),
    'flat_slots', to_jsonb(public.society_flat_slots()))
  from public.society_prospects s where s.id = p_id;
$$;

create or replace function public.partner_society_contact_save(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  cid uuid := nullif(p ->> 'id', '')::uuid;
  s   public.society_prospects := public.sp_owned(nullif(p ->> 'society_id', '')::uuid);
  ph  text := public.normalize_mobile(coalesce(p ->> 'phone', ''));
  old public.society_prospect_contacts;
begin
  if coalesce(p ->> 'kind', '') not in ('manager', 'guard', 'broker') then raise exception 'Pick who this is.' using errcode = '22023'; end if;
  if coalesce(ph, '') = '' then raise exception 'Give a 10-digit mobile number.' using errcode = '22023'; end if;
  if p ->> 'kind' = 'broker' and length(trim(coalesce(p ->> 'name', ''))) < 2 then raise exception 'Give the broker''s name.' using errcode = '22023'; end if;
  if cid is null then
    insert into public.society_prospect_contacts (prospect_id, kind, name, phone, note, source, partner_id, created_by)
    values (s.id, p ->> 'kind', left(trim(coalesce(p ->> 'name', '')), 80), ph, left(coalesce(p ->> 'note', ''), 300),
            'partner', auth.uid(), 'partner:' || auth.uid());
  else
    select * into old from public.society_prospect_contacts c
     where c.id = cid and c.prospect_id = s.id and c.partner_id = auth.uid() and c.removed_at is null;
    if old.id is null then raise exception 'No such number.' using errcode = '22023'; end if;
    if old.phone is distinct from ph then
      -- A new number: the old one is kept for the CRM, marked replaced.
      update public.society_prospect_contacts set removed_at = now(), removed_by = 'partner:' || auth.uid() || ':changed', updated_at = now()
       where id = old.id;
      insert into public.society_prospect_contacts (prospect_id, kind, name, phone, note, source, partner_id, created_by)
      values (s.id, p ->> 'kind', left(trim(coalesce(p ->> 'name', '')), 80), ph, left(coalesce(p ->> 'note', ''), 300),
              'partner', auth.uid(), 'partner:' || auth.uid());
    else
      update public.society_prospect_contacts c set kind = p ->> 'kind', name = left(trim(coalesce(p ->> 'name', '')), 80),
             note = left(coalesce(p ->> 'note', ''), 300), updated_at = now()
       where c.id = old.id;
    end if;
  end if;
  update public.society_prospects set updated_at = now() where id = s.id;
  return public.sp_json(s.id);
end;
$$;

create or replace function public.partner_society_contact_remove(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  sid uuid;
  s   public.society_prospects;
begin
  select prospect_id into sid from public.society_prospect_contacts where id = p_id and partner_id = auth.uid() and removed_at is null;
  if sid is null then raise exception 'No such number.' using errcode = '22023'; end if;
  s := public.sp_owned(sid);
  -- Kept for the CRM ("removed by partner"); gone from the partner's app.
  update public.society_prospect_contacts set removed_at = now(), removed_by = 'partner:' || auth.uid(), updated_at = now() where id = p_id;
  return public.sp_json(s.id);
end;
$$;

create or replace function public.partner_my_societies()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  me uuid := public.sp_require();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', s.id, 'name', s.name, 'area', s.area, 'status', s.onboard_status, 'locked_until', s.onboard_locked_until,
             'note', s.onboard_note, 'live', s.live, 'public_code', s.public_code,
             'missing', cardinality(public.sp_missing(s.id)),
             'cover', coalesce(s.flat_photos -> 0 ->> 'url', ''),
             'leads', (select count(*) from public.society_leads l where l.prospect_id = s.id and l.partner_id = me),
             'new_leads', (select count(*) from public.society_leads l where l.prospect_id = s.id and l.partner_id = me and l.stage = 'new'),
             'contact_counts', public.sp_contact_counts(s.id, me))
           order by array_position(array['sent_back', 'draft', 'submitted', 'approved'], s.onboard_status), s.onboard_started_at desc)
      from public.society_prospects s where s.onboard_by = me), '[]'::jsonb);
end;
$$;

create or replace function public.partner_societies_nearby(p_lat numeric, p_lng numeric)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  me uuid := public.sp_require();
begin
  return coalesce((
    select jsonb_agg(x.j order by x.d nulls last, x.name)
      from (
        select s.name, case when p_lat is null or s.lat is null then null else public.sp_metres(p_lat, p_lng, s.lat, s.lng) end d,
               jsonb_build_object(
                 'id', s.id, 'name', s.name, 'area', s.area, 'road', s.road, 'lat', s.lat, 'lng', s.lng,
                 'metres', case when p_lat is null or s.lat is null then null else round(public.sp_metres(p_lat, p_lng, s.lat, s.lng)) end,
                 'state', case
                   when s.onboard_status = 'approved' then case when s.onboard_by = me then 'mine_live' else 'onboarded' end
                   when s.onboard_by = me then 'mine'
                   when s.onboard_status = 'submitted' then 'onboarded'
                   when s.onboard_by is not null and s.onboard_locked_until > now() then 'locked'
                   else 'open' end,
                 'status', case when s.onboard_by = me then s.onboard_status end,
                 'by', case when s.onboard_by is not null and s.onboard_by <> me
                             and (s.onboard_status in ('submitted', 'approved') or s.onboard_locked_until > now())
                            then public.sp_partner_name(s.onboard_by) end,
                 'locked_until', case when s.onboard_by <> me then s.onboard_locked_until end,
                 -- For the map's preview card: the first amenities and the rents (the partner's, else research).
                 'amenities', to_jsonb(coalesce(s.amenities[1:6], '{}'::text[])),
                 'amenity_count', coalesce(cardinality(s.amenities), 0),
                 'rents', case when coalesce(s.partner_rents, '{}'::jsonb) <> '{}'::jsonb then s.partner_rents else coalesce(s.rents, '{}'::jsonb) end,
                 'contact_counts', case when s.onboard_by = me then public.sp_contact_counts(s.id, me) end) j
          from public.society_prospects s
         where not s.hidden and s.lat is not null
         order by 2 nulls last, s.name
         limit 120
      ) x), '[]'::jsonb);
end;
$$;

revoke all on function public.sp_contact_counts(uuid, uuid) from public, anon, authenticated;
revoke all on function public.sp_owned(uuid) from public, anon, authenticated;

commit;
