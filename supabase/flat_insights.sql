-- ─────────────────────────────────────────────────────────────────────────────
-- Every flat's QR, its numbers, and what renters said about it
-- (fe/src/pages/owners/RentDashboard.jsx, fe/src/pages/owners/FlatLeads.jsx,
-- fe/src/pages/crm/CrmFlatQr.jsx, fe/src/pages/PropertyPage.jsx).
--
-- Run in the Supabase SQL editor AFTER owner_schema.sql, visits_schema.sql,
-- partner_storefront.sql and owner_buildings.sql. Safe to re-run.
--
-- A flat on rent gets a QR for its door: moveazy.co.in/property/<id>?s=qr, the
-- public page that already takes a renter's mobile, likes and visit bookings.
-- Each open is counted here (once per visitor a day). The owner sees, per
-- flat: leads (QR scans), likes and visits — and the feedback the MovEazy team
-- records from renters (how they found the rent, a rating, what they said).
--
--   flat_scans      one row per visitor per flat per day, QR or shared link.
--   flat_feedback   a renter's feedback on one flat, written by CRM staff.
--
-- Owners never see a renter's number; the team writes feedback, owners read it.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

create table if not exists public.flat_scans (
  property_id text not null references public.inventory (property_id) on delete cascade,
  visitor     text not null check (length(visitor) between 8 and 64),
  day         date not null default (now() at time zone 'Asia/Kolkata')::date,
  source      text not null default 'link' check (source in ('qr', 'link')),
  created_at  timestamptz not null default now(),
  primary key (property_id, visitor, day)
);

create table if not exists public.flat_feedback (
  id          uuid primary key default gen_random_uuid(),
  property_id text not null references public.inventory (property_id) on delete cascade,
  renter_name text not null default '',
  price_view  text not null default '' check (price_view in ('', 'too_high', 'bit_high', 'fair', 'good_value')),
  rating      int check (rating between 1 and 5),
  comment     text not null default '' check (length(comment) <= 1000),
  source      text not null default 'visit' check (source in ('visit', 'call', 'whatsapp', 'qr', 'other')),
  created_by  text not null default '',
  created_at  timestamptz not null default now()
);
create index if not exists flat_feedback_property_idx on public.flat_feedback (property_id, created_at desc);

alter table public.flat_scans enable row level security;
alter table public.flat_feedback enable row level security;
revoke all on public.flat_scans, public.flat_feedback from anon, authenticated;

-- ── Counting ─────────────────────────────────────────────────────────────────

/** Count one open of a live flat's page. Once per visitor a day; the owner's own opens don't count. */
create or replace function public.flat_view(p_property text, p_visitor text, p_source text default 'link')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  pid text := upper(trim(coalesce(p_property, '')));
  who text := coalesce(auth.uid()::text, left(trim(coalesce(p_visitor, '')), 64));
begin
  if length(who) < 8 or not exists (select 1 from public.inventory where property_id = pid and status = 'published') then return; end if;
  if auth.uid() is not null and exists (select 1 from public.owner_property_links l where l.property_id = pid and l.owner_id = auth.uid()) then
    return;
  end if;
  insert into public.flat_scans (property_id, visitor, source)
  values (pid, who, case when p_source = 'qr' then 'qr' else 'link' end)
  on conflict (property_id, visitor, day) do nothing;
end;
$$;

/** Leads (QR scans), opens, likes, visits and feedback for one flat. Internal. */
create or replace function public.flat_stats(p_property text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'scans',    (select count(distinct s.visitor) from public.flat_scans s where s.property_id = p_property and s.source = 'qr'),
    'opens',    (select count(distinct s.visitor) from public.flat_scans s where s.property_id = p_property),
    'likes',    (select count(*) from public.listing_reactions r where r.property_id = p_property and r.reaction = 'like')
              + (select count(*) from public.partner_storefront_likes sl where sl.property_id = p_property),
    'visits',   (select count(*) from public.visit_bookings b
                  where b.property_id = p_property and coalesce(b.status, '') not ilike 'cancel%')
              + (select count(*) from public.owner_building_leads bl
                  where p_property = any(bl.property_ids) and bl.status <> 'cancelled' and bl.visit_at is not null
                    -- A signed-in request is also in the tenant's own visits: counted there, once.
                    and not exists (select 1 from public.visit_bookings b
                                      where b.user_id = bl.user_id and b.property_id = p_property)),
    'feedback', (select count(*) from public.flat_feedback f where f.property_id = p_property),
    'rating',   (select round(avg(f.rating)::numeric, 1) from public.flat_feedback f where f.property_id = p_property and f.rating is not null),
    'price_views', (select coalesce(jsonb_object_agg(v.price_view, v.n), '{}'::jsonb) from (
                      select f.price_view, count(*) n from public.flat_feedback f
                       where f.property_id = p_property and f.price_view <> '' group by f.price_view) v)
  );
$$;

/** Everything about one flat's interest: the numbers, 14 days of scans, who liked, who visited, and the feedback. Internal. */
create or replace function public.flat_insights(p_property text, p_with_contacts boolean)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'property_id', i.property_id, 'status', i.status, 'building_id', i.building_id,
    'building_code', (select b.code from public.owner_buildings b where b.id = i.building_id),
    'building_name', (select b.name from public.owner_buildings b where b.id = i.building_id),
    'stats', public.flat_stats(i.property_id),
    'by_day', (
      select jsonb_agg(jsonb_build_object('day', d::date,
               'scans', (select count(*) from public.flat_scans s where s.property_id = i.property_id and s.day = d::date and s.source = 'qr'),
               'opens', (select count(*) from public.flat_scans s where s.property_id = i.property_id and s.day = d::date)) order by d)
        from generate_series((now() at time zone 'Asia/Kolkata')::date - 13, (now() at time zone 'Asia/Kolkata')::date, interval '1 day') d),
    'likes', coalesce((
      select jsonb_agg(x order by x ->> 'at' desc) from (
        select jsonb_build_object('name', case when p_with_contacts then coalesce(nullif(p.name, ''), p.email) else public.owner_display_name(coalesce(nullif(p.name, ''), split_part(p.email, '@', 1))) end,
                                  'phone', case when p_with_contacts then p.phone end, 'at', r.updated_at) x
          from public.listing_reactions r left join public.user_profiles p on p.id = r.user_id
         where r.property_id = i.property_id and r.reaction = 'like'
        union all
        select jsonb_build_object('name', case when p_with_contacts then coalesce(nullif(p.name, ''), p.email) else public.owner_display_name(coalesce(nullif(p.name, ''), split_part(p.email, '@', 1))) end,
                                  'phone', case when p_with_contacts then p.phone end, 'at', sl.created_at)
          from public.partner_storefront_likes sl left join public.user_profiles p on p.id = sl.user_id
         where sl.property_id = i.property_id) l), '[]'::jsonb),
    'visits', coalesce((
      select jsonb_agg(x order by x ->> 'created_at' desc) from (
        select jsonb_build_object('name', case when p_with_contacts then coalesce(nullif(p.name, ''), p.email) else public.owner_display_name(coalesce(nullif(p.name, ''), split_part(p.email, '@', 1))) end,
                                  'phone', case when p_with_contacts then p.phone end,
                                  'at', b.slot_at, 'status', coalesce(nullif(b.status, ''), 'scheduled'), 'created_at', b.created_at) x
          from public.visit_bookings b left join public.user_profiles p on p.id = b.user_id
         where b.property_id = i.property_id
        union all
        select jsonb_build_object('name', case when p_with_contacts then bl.name else public.owner_display_name(bl.name) end, 'phone', case when p_with_contacts then bl.phone end,
                                  'at', bl.visit_at, 'status', bl.status, 'created_at', bl.created_at)
          from public.owner_building_leads bl
         where i.property_id = any(bl.property_ids)
           and not exists (select 1 from public.visit_bookings b where b.user_id = bl.user_id and b.property_id = i.property_id)) v), '[]'::jsonb),
    'feedback', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', f.id, 'name', case when p_with_contacts then f.renter_name else public.owner_display_name(f.renter_name) end,
               'price_view', f.price_view, 'rating', f.rating, 'comment', f.comment, 'source', f.source,
               'created_by', case when p_with_contacts then f.created_by end, 'created_at', f.created_at)
             order by f.created_at desc)
        from public.flat_feedback f where f.property_id = i.property_id), '[]'::jsonb)
  )
  from public.inventory i
  where i.property_id = upper(trim(coalesce(p_property, '')));
$$;

-- ── The owner's side ─────────────────────────────────────────────────────────

/** Each of the owner's flats with its numbers — the rent dashboard. */
create or replace function public.owner_rent_dashboard()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object('property_id', l.property_id, 'stats', public.flat_stats(l.property_id))
                            order by l.linked_at desc), '[]'::jsonb)
    from public.owner_property_links l
   where l.owner_id = auth.uid() and public.is_approved_owner();
$$;

/** One flat's leads, likes, visits (first name and initial only) and feedback, for its owner. */
create or replace function public.owner_flat_insights(p_property text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select case when public.is_approved_owner() and public.owner_has_property(upper(trim(coalesce(p_property, ''))))
              then public.flat_insights(p_property, false) end;
$$;

-- ── MovEazy's side ───────────────────────────────────────────────────────────

/** The same, with numbers and full names, for CRM staff. */
create or replace function public.crm_flat_insights(p_property text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  return public.flat_insights(p_property, true);
end;
$$;

/** Record a renter's feedback on a flat. CRM staff only. */
create or replace function public.crm_flat_feedback_add(p_property text, p jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  pid text := upper(trim(coalesce(p_property, '')));
  rid uuid;
  pv  text := coalesce(p ->> 'price_view', '');
  rt  int := nullif(p ->> 'rating', '')::int;
  cm  text := trim(coalesce(p ->> 'comment', ''));
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  if not exists (select 1 from public.inventory where property_id = pid) then raise exception 'No such listing.' using errcode = '22023'; end if;
  if pv = '' and rt is null and cm = '' then
    raise exception 'Add how they found the rent, a rating or what they said.' using errcode = '22023';
  end if;
  insert into public.flat_feedback (property_id, renter_name, price_view, rating, comment, source, created_by)
  values (pid, left(trim(coalesce(p ->> 'renter_name', '')), 80), pv, rt, left(cm, 1000),
          case when p ->> 'source' in ('visit', 'call', 'whatsapp', 'qr', 'other') then p ->> 'source' else 'visit' end,
          lower(coalesce(auth.jwt() ->> 'email', '')))
  returning id into rid;
  return rid;
end;
$$;

/** Remove a feedback entry recorded by mistake. CRM staff only. */
create or replace function public.crm_flat_feedback_delete(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  delete from public.flat_feedback where id = p_id;
end;
$$;

-- ── Grants ───────────────────────────────────────────────────────────────────
do $$
declare f text;
begin
  foreach f in array array['public.flat_stats(text)', 'public.flat_insights(text, boolean)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
  execute 'revoke all on function public.flat_view(text, text, text) from public';
  execute 'grant execute on function public.flat_view(text, text, text) to anon, authenticated';
  foreach f in array array[
    'public.owner_rent_dashboard()', 'public.owner_flat_insights(text)', 'public.crm_flat_insights(text)',
    'public.crm_flat_feedback_add(text, jsonb)', 'public.crm_flat_feedback_delete(uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

commit;
