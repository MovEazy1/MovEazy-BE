-- ─────────────────────────────────────────────────────────────────────────────
-- Societies on the tenant site before a partner onboards them (2026-11-17).
-- Changes to society_partners.sql:
--   * listed = onboarded by a partner (live) OR researched (amenities or rents);
--     not hidden. Gets a page code the moment it can be listed (trigger).
--   * the cards say which are verified (a partner onboarded it) and carry every
--     amenity for the site's filters; numbers are never shown
--   * an enquiry on a researched society becomes a CRM society lead with no
--     partner ("no partner yet, follow up"); only an approved partner (live)
--     ever gets a society's tenants
-- Re-runnable.
-- ─────────────────────────────────────────────────────────────────────────────
begin;

create or replace function public.sp_listed(s public.society_prospects)
returns boolean
language sql
immutable
as $$
  select not s.hidden and (s.live or cardinality(s.amenities) > 0 or coalesce(s.rents, '{}'::jsonb) <> '{}'::jsonb);
$$;

create or replace function public.sp_code_trg()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  code text;
  i    int;
begin
  if new.public_code is null and (new.live or cardinality(new.amenities) > 0 or coalesce(new.rents, '{}'::jsonb) <> '{}'::jsonb) then
    for i in 1..25 loop
      select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '') into code from generate_series(1, 6);
      exit when not exists (select 1 from public.society_prospects where public_code = code);
    end loop;
    new.public_code := code;
  end if;
  return new;
end;
$$;

create or replace function public.society_live_card(s public.society_prospects)
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'code', s.public_code, 'name', s.name, 'area', s.area, 'road', s.road,
    'lat', round(s.lat, 3), 'lng', round(s.lng, 3), 'cover', coalesce(s.photos[1], ''), 'photos', cardinality(s.photos),
    'amenities', to_jsonb(s.amenities[1:6]), 'amenity_count', cardinality(s.amenities),
    'amenity_tags', to_jsonb(s.amenities), 'verified', s.live,
    'rents', case when s.partner_rents <> '{}'::jsonb then s.partner_rents else s.rents end,
    'facts', jsonb_build_object('builder', s.facts ->> 'builder', 'towers', s.facts ->> 'towers', 'total_flats', s.facts ->> 'total_flats'));
$$;

create or replace function public.societies_live(p_lat numeric default null, p_lng numeric default null)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(public.society_live_card(s) || jsonb_build_object('metres',
           case when p_lat is null or s.lat is null then null else round(public.sp_metres(p_lat, p_lng, s.lat, s.lng)) end)
         order by case when p_lat is null or s.lat is null then null else public.sp_metres(p_lat, p_lng, s.lat, s.lng) end nulls last, s.name), '[]'::jsonb)
    from public.society_prospects s
   where public.sp_listed(s) and s.public_code is not null;
$$;

create or replace function public.society_live(p_code text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.society_live_card(s) || jsonb_build_object(
           'photos_all', to_jsonb(s.photos),
           'amenities_all', to_jsonb(s.amenities),
           'amenity_photos', coalesce((select jsonb_object_agg(a.key, (select jsonb_agg(p ->> 'url') from jsonb_array_elements(a.value) p))
                                         from jsonb_each(s.amenity_photos) a), '{}'::jsonb),
           'flat_photos', coalesce((select jsonb_agg(jsonb_build_object('slot', p ->> 'slot', 'url', p ->> 'url')) from jsonb_array_elements(s.flat_photos) p), '[]'::jsonb),
           'facts_all', s.facts - 'about', 'about', s.facts ->> 'about', 'nearby', s.nearby,
           'partner_first_name', case when s.live then (select split_part(trim(bp.name), ' ', 1) from public.broker_partners bp where bp.user_id = s.onboard_by) end)
    from public.society_prospects s
   where s.public_code = upper(trim(p_code)) and public.sp_listed(s);
$$;

create or replace function public.society_enquire(p_code text, p_lead_key text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s   public.society_prospects;
  cid uuid;
  nm  text := '';
  ph  text := '';
  lid uuid;
  partner record;
  e   text;
  isnew boolean := false;
begin
  select * into s from public.society_prospects where public_code = upper(trim(p_code));
  if s.id is null or not public.sp_listed(s) then raise exception 'This society isn''t listed right now.' using errcode = '22023'; end if;

  if auth.uid() is not null then
    select c.id, c.name, c.phone into cid, nm, ph from public.crm_clients c where c.user_id = auth.uid();
  end if;
  if cid is null and coalesce(p_lead_key, '') ~ '^[0-9a-f]{32}$' then
    select li.crm_client_id, li.name, li.phone into cid, nm, ph from public.lead_intake li where li.lead_key = p_lead_key;
    if cid is not null then select c.name, c.phone into nm, ph from public.crm_clients c where c.id = cid; end if;
  end if;
  if cid is null or coalesce(ph, '') = '' then raise exception 'Verify your mobile number first.' using errcode = '42501'; end if;

  -- Only a partner whose onboarding is approved (the society is live) gets its tenants.
  select bp.user_id, bp.name, bp.phone, bp.status into partner from public.broker_partners bp where bp.user_id = s.onboard_by and s.live;

  -- One lead per tenant per society a day: asking twice doesn't double it.
  select id into lid from public.society_leads
   where prospect_id = s.id and client_id = cid and created_at > now() - interval '1 day' order by created_at desc limit 1;
  if lid is null then
    isnew := true;
    insert into public.society_leads (prospect_id, partner_id, client_id, name, phone)
    values (s.id, partner.user_id, cid, coalesce(nm, ''), ph) returning id into lid;
    insert into public.society_lead_events (lead_id, actor, kind, body)
    values (lid, coalesce(nullif(nm, ''), 'Tenant'), 'enquired',
            case when partner.user_id is null then format('Asked for flats in %s on moveazy.co.in — no partner yet, the MovEazy team follows up', s.name)
                 else format('Asked for flats in %s on moveazy.co.in — sent to %s', s.name, coalesce(nullif(partner.name, ''), 'the partner')) end);
  end if;

  perform public.crm_lead_activate(cid, 'society enquiry');
  if isnew then
    update public.crm_clients set interests = interests || ('society:' || s.public_code) where id = cid and not (('society:' || s.public_code) = any(interests));
    insert into public.crm_activities (client_id, type, body)
    values (cid, 'partner', case when partner.user_id is null then format('Asked for flats in %s — no partner yet, follow up', s.name)
                                 else format('Asked for flats in %s — sent to partner %s (%s)', s.name, coalesce(nullif(partner.name, ''), '—'), coalesce(partner.phone, '')) end);
    if partner.user_id is not null then
      insert into public.partner_notifications (broker_id, kind, title, body, link)
      values (partner.user_id, 'society_lead', format('New tenant for %s', s.name),
              format('%s wants a flat in %s. Call them, and upload a flat in this society for them in Add property.', coalesce(nullif(nm, ''), 'A tenant'), s.name),
              '/societies/leads');
    end if;
    for e in select x from public.crm_team_emails() x loop
      insert into public.crm_notifications (for_email, type, title, body, client_id)
      values (e, 'society_lead', format('Society lead: %s', s.name),
              case when partner.user_id is null then format('%s wants a flat in %s — no partner yet. Follow up.', coalesce(nullif(nm, ''), 'A tenant'), s.name)
                   else format('%s is contacting %s for %s.', coalesce(nullif(nm, ''), 'A tenant'), coalesce(nullif(partner.name, ''), 'the partner'), s.name) end, cid);
    end loop;
  end if;

  return jsonb_build_object('society', s.name,
    'partner_first_name', case when partner.status = 'approved' then split_part(trim(coalesce(partner.name, '')), ' ', 1) end,
    'partner_phone', case when partner.status = 'approved' then partner.phone end);
end;
$$;

drop trigger if exists society_prospects_code on public.society_prospects;
create trigger society_prospects_code before insert or update on public.society_prospects
  for each row execute function public.sp_code_trg();

-- Codes for what's listable today (the trigger fills them in).
update public.society_prospects set updated_at = updated_at
 where public_code is null and (live or cardinality(amenities) > 0 or coalesce(rents, '{}'::jsonb) <> '{}'::jsonb);

revoke all on function public.sp_code_trg() from public, anon, authenticated;
revoke all on function public.sp_listed(public.society_prospects) from public, anon, authenticated;

commit;
