-- ─────────────────────────────────────────────────────────────────────────────
-- The owner's QR scans, on the owner app's home
-- (fe/src/pages/owners/OwnerHome.jsx, fe/src/pages/owners/QrScans.jsx).
--
-- Run in the Supabase SQL editor AFTER flat_insights.sql, owner_buildings.sql,
-- partner_website_leads.sql, tenant_profile_schema.sql, building_call_desk.sql and
-- building_tenant_tracks.sql. Safe to re-run.
--
-- Every open counts. flat_scans and owner_building_scans keep their one row
-- per visitor per page a day (every "people" number reads that), and now also
-- how many times that visitor opened it that day (hits) and who they are once
-- known (user_id): set as they open it signed in, or when they sign in later
-- on the same phone (owner_scans_claim, called with flat_claim_views).
--
-- The owner sees, across their flats and buildings:
--   scans    every open of the pages, from the QR or a shared link;
--   people   everyone who opened one signed in, booked a visit to a flat,
--            asked to visit a building, or asked a building's QR page for
--            its caretaker's number — name, mobile, tenant profile, which
--            page and when, who they called and what they said after, and
--            where the MovEazy team has them (building_tenant_tracks.sql);
--   visited  those of them who booked or asked for a visit.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

-- ── Every open, and who ─────────────────────────────────────────────────────

alter table public.flat_scans add column if not exists hits int not null default 1;
alter table public.flat_scans add column if not exists last_at timestamptz;
alter table public.flat_scans add column if not exists user_id uuid references auth.users (id) on delete set null;
alter table public.owner_building_scans add column if not exists hits int not null default 1;
alter table public.owner_building_scans add column if not exists last_at timestamptz;
alter table public.owner_building_scans add column if not exists user_id uuid references auth.users (id) on delete set null;

update public.flat_scans set last_at = created_at where last_at is null;
update public.owner_building_scans set last_at = created_at where last_at is null;
alter table public.flat_scans alter column last_at set default now(), alter column last_at set not null;
alter table public.owner_building_scans alter column last_at set default now(), alter column last_at set not null;

-- A signed-in open was already stored under the account's id.
update public.flat_scans s set user_id = u.id
  from auth.users u
 where s.user_id is null and u.id::text = s.visitor;
update public.owner_building_scans s set user_id = u.id
  from auth.users u
 where s.user_id is null and u.id::text = s.visitor;

create index if not exists flat_scans_visitor_idx on public.flat_scans (visitor);
create index if not exists flat_scans_user_idx on public.flat_scans (user_id) where user_id is not null;
create index if not exists owner_building_scans_visitor_idx on public.owner_building_scans (visitor);
create index if not exists owner_building_scans_user_idx on public.owner_building_scans (user_id) where user_id is not null;

/**
 * flat_view inserts "do nothing" on a repeat the same day; this turns the
 * repeat into one more hit on the day's row instead. 500 a day at most per
 * visitor, so a reloading phone can't run the number up.
 */
create or replace function public.flat_scans_count_open()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.flat_scans s
     set hits = least(s.hits + 1, 500), last_at = now(),
         source = case when new.source = 'qr' then 'qr' else s.source end,
         user_id = coalesce(s.user_id, new.user_id, auth.uid())
   where s.property_id = new.property_id and s.visitor = new.visitor and s.day = new.day;
  if found then return null; end if;
  new.user_id := coalesce(new.user_id, auth.uid());
  return new;
end;
$$;
drop trigger if exists flat_scans_count_open on public.flat_scans;
create trigger flat_scans_count_open before insert on public.flat_scans
  for each row execute function public.flat_scans_count_open();

/** The same for a building's page (building_view). */
create or replace function public.owner_building_scans_count_open()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.owner_building_scans s
     set hits = least(s.hits + 1, 500), last_at = now(),
         source = case when new.source = 'qr' then 'qr' else s.source end,
         user_id = coalesce(s.user_id, new.user_id, auth.uid())
   where s.building_id = new.building_id and s.visitor = new.visitor and s.day = new.day;
  if found then return null; end if;
  new.user_id := coalesce(new.user_id, auth.uid());
  return new;
end;
$$;
drop trigger if exists owner_building_scans_count_open on public.owner_building_scans;
create trigger owner_building_scans_count_open before insert on public.owner_building_scans
  for each row execute function public.owner_building_scans_count_open();

/**
 * Someone just signed in: the pages they opened on this phone in the last
 * week, before signing in, are theirs. Partners, CRM staff and the page's own
 * owner or broker aren't renters, and stay out.
 */
create or replace function public.owner_scans_claim(p_visitor text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid   uuid := auth.uid();
  v     text := left(trim(coalesce(p_visitor, '')), 64);
  since date := (now() at time zone 'Asia/Kolkata')::date - 7;
begin
  if uid is null or length(v) < 8 then return; end if;
  update public.flat_scans s set user_id = uid
   where s.visitor = v and s.user_id is null and s.day >= since
     and public.website_tenant_ok(uid, s.property_id);
  update public.owner_building_scans s set user_id = uid
   where s.visitor = v and s.user_id is null and s.day >= since
     and public.website_tenant_ok(uid, '')
     and not exists (select 1 from public.owner_buildings b
                      where b.id = s.building_id and (b.owner_id = uid or b.broker_id = uid));
end;
$$;

-- ── The owner's side ─────────────────────────────────────────────────────────

/**
 * The owner's scans and the people behind them, across their flats and
 * buildings:
 *   { scans, week, people, visited,
 *     by_place: [{ kind: flat|building, ref, name, scans, week, people }],
 *     list: [{ key, user_id, name, phone, email, at, visit, profile,
 *              places: [{ kind, ref, at, hits, visit, called: [caretaker|manager] }],
 *              feedback: [{ kind, note, at, ref }],
 *              status: { visit, liked, liked_status, reasons, at } | null }] }
 * null for anyone who isn't an approved owner.
 */
create or replace function public.owner_qr_overview()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with me as (select auth.uid() as uid where public.is_approved_owner()),
  today as (select (now() at time zone 'Asia/Kolkata')::date as d),
  flats as (select l.property_id from public.owner_property_links l join me on l.owner_id = me.uid),
  blds as (select b.id, b.name from public.owner_buildings b join me on b.owner_id = me.uid),
  scans as (
    select 'flat'::text as kind, s.property_id as ref, s.day, s.hits, s.last_at, s.user_id
      from public.flat_scans s join flats f on f.property_id = s.property_id
    union all
    select 'building', s.building_id::text, s.day, s.hits, s.last_at, s.user_id
      from public.owner_building_scans s join blds b on b.id = s.building_id),
  touches as (
    select s.user_id, null::text as phone, null::text as name, s.kind, s.ref, s.last_at as at, s.hits, false as visit,
           null::text as called, null::text as fb, null::text as note, null::uuid as trk
      from scans s where s.user_id is not null
    union all
    select v.user_id, null, null, 'flat', v.property_id, v.created_at, 0, true, null, null, null, null
      from public.visit_bookings v join flats f on f.property_id = v.property_id
     where coalesce(v.status, '') not ilike 'cancel%'
    union all
    select bl.user_id, bl.phone, bl.name, 'building', bl.building_id::text, bl.created_at, 0, true, null, null, null, null
      from public.owner_building_leads bl join blds b on b.id = bl.building_id
     where bl.status <> 'cancelled'
    union all
    -- Call Caretaker on the building's QR page (building_call_desk.sql).
    select e.user_id, e.phone, nullif(e.name, ''), 'building', e.building_id::text, e.created_at, 0, false,
           nullif(e.target, ''), nullif(e.feedback, ''), nullif(e.note, ''), null
      from public.building_call_events e join blds b on b.id = e.building_id
    union all
    -- Tenants the MovEazy team brought, and where each stands (building_tenant_tracks.sql).
    select null, k.phone, nullif(k.name, ''), 'building', k.building_id::text, k.updated_at, 0, k.visit = 'done',
           null, null, null, k.id
      from public.building_tenant_tracks k join blds b on b.id = k.building_id),
  t as (
    select x.*, coalesce(x.user_id::text, 'tel:' || x.phone) as who
      from touches x, me
     where x.user_id is distinct from me.uid and (x.user_id is not null or x.phone is not null)),
  places as (
    select who, kind, ref, max(at) as at, sum(hits)::int as hits, bool_or(visit) as visit,
           coalesce(array_agg(distinct called) filter (where called is not null), '{}') as called
      from t group by who, kind, ref),
  people as (
    select p.who, max(p.at) as at, bool_or(p.visit) as visit,
           jsonb_agg(jsonb_build_object('kind', p.kind, 'ref', p.ref, 'at', p.at, 'hits', p.hits, 'visit', p.visit, 'called', p.called)
                     order by p.at desc) as places
      from places p group by p.who)
  select case when exists (select 1 from me) then jsonb_build_object(
    'scans',   (select coalesce(sum(s.hits), 0) from scans s),
    'week',    (select coalesce(sum(s.hits), 0) from scans s, today where s.day > today.d - 7),
    'people',  (select count(*) from people),
    'visited', (select count(*) from people where visit),
    'by_place', (
      select coalesce(jsonb_agg(x order by (x ->> 'scans')::int desc), '[]'::jsonb) from (
        select jsonb_build_object('kind', 'flat', 'ref', f.property_id, 'name', null,
                 'scans',  (select coalesce(sum(s.hits), 0) from scans s where s.kind = 'flat' and s.ref = f.property_id),
                 'week',   (select coalesce(sum(s.hits), 0) from scans s, today
                             where s.kind = 'flat' and s.ref = f.property_id and s.day > today.d - 7),
                 'people', (select count(*) from places pl where pl.kind = 'flat' and pl.ref = f.property_id)) as x
          from flats f
        union all
        select jsonb_build_object('kind', 'building', 'ref', b.id::text, 'name', b.name,
                 'scans',  (select coalesce(sum(s.hits), 0) from scans s where s.kind = 'building' and s.ref = b.id::text),
                 'week',   (select coalesce(sum(s.hits), 0) from scans s, today
                             where s.kind = 'building' and s.ref = b.id::text and s.day > today.d - 7),
                 'people', (select count(*) from places pl where pl.kind = 'building' and pl.ref = b.id::text))
          from blds b) q),
    'list', (
      select coalesce(jsonb_agg(row order by row ->> 'at' desc), '[]'::jsonb) from (
        select jsonb_build_object(
                 'key', pe.who, 'user_id', u.id, 'at', pe.at, 'visit', pe.visit, 'places', pe.places,
                 'status', (select jsonb_build_object('visit', k.visit, 'liked', k.liked, 'liked_status', k.liked_status,
                                                       'reasons', k.reasons, 'at', k.updated_at)
                              from public.building_tenant_tracks k
                             where k.id = (select t.trk from t where t.who = pe.who and t.trk is not null order by t.at desc limit 1)),
                 'feedback', coalesce((select jsonb_agg(jsonb_build_object('kind', t.fb, 'note', t.note, 'at', t.at, 'ref', t.ref) order by t.at desc)
                                        from t where t.who = pe.who and t.fb is not null), '[]'::jsonb),
                 'name', coalesce(nullif(trim(up.name), ''),
                                  (select t.name from t where t.who = pe.who and coalesce(t.name, '') <> '' order by t.at desc limit 1),
                                  split_part(coalesce(up.email, u.email, ''), '@', 1), ''),
                 'phone', coalesce(nullif(trim(up.phone), ''), nullif(trim(ur.whatsapp), ''),
                                   (select t.phone from t where t.who = pe.who and t.phone is not null order by t.at desc limit 1), ''),
                 'email', coalesce(nullif(up.email, ''), u.email, ''),
                 'profile', (select jsonb_build_object(
                                'company', tp.current_company, 'past_company', tp.past_company, 'first_job', tp.first_job,
                                'college', tp.college, 'graduation_year', tp.graduation_year, 'linkedin', tp.linkedin,
                                'in_bangalore_since', tp.in_bangalore_since, 'score', tp.score)
                               from public.tenant_profiles tp where tp.user_id = u.id)) as row
          from people pe
          left join auth.users u on pe.who not like 'tel:%' and u.id::text = pe.who
          left join public.user_profiles up on up.id = u.id
          left join public.user_requirements ur on ur.user_id = u.id
         order by pe.at desc
         limit 300) l)
  ) end;
$$;

-- ── Grants ───────────────────────────────────────────────────────────────────
revoke all on function public.flat_scans_count_open() from public, anon, authenticated;
revoke all on function public.owner_building_scans_count_open() from public, anon, authenticated;
revoke all on function public.owner_scans_claim(text) from public, anon;
grant execute on function public.owner_scans_claim(text) to authenticated;
revoke all on function public.owner_qr_overview() from public, anon;
grant execute on function public.owner_qr_overview() to authenticated;

commit;
