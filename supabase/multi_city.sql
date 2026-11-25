-- MovEazy in seven cities: Bengaluru, Mumbai, Hyderabad, Pune, Noida,
-- Gurugram and Delhi.
--
-- Run in the Supabase SQL editor after everything else (it builds on the live
-- definitions of areas.sql, find_deals.sql, program_settings.sql,
-- partner_schema.sql, partner_group_privacy.sql, partner_moveazy_leads.sql and
-- partner_referral_mapping.sql). Safe to re-run.
--
-- Decided 2026-11-25:
--   * Every record carries a city; everything that existed is Bengaluru.
--   * A tenant's city is the city they are SEARCHING in (not where they are):
--     crm_clients.city. Where they are now, when it differs, is current_city.
--     Their account says it (user_requirements.city), else the areas they
--     picked do; switching moves the one CRM record and notes it.
--   * The areas list is per city; each new city starts with 20–30 areas.
--   * A broker belongs to one city (picked at sign-up): they get leads and
--     see flats of that city only. A lead is never given to a broker of
--     another city (the website's own flat-interest leads follow the flat).
--   * Steal Deals and Deal of the Day are per city.
--   * Premium price and brokerage shares are per city (program_city_settings),
--     each new city starting from Bengaluru's.
--   * In the CRM each team member is given cities (admin_roles.cities; empty
--     = every city); clients of other cities are hidden from them.

begin;

/* ── The cities ──────────────────────────────────────────────────────────── */

create table if not exists public.cities (
  name   text primary key,
  slug   text not null unique,
  ncr    boolean not null default false,
  sort   int not null default 0,
  active boolean not null default true
);
insert into public.cities (name, slug, ncr, sort) values
  ('Bengaluru', 'bangalore', false, 10), ('Mumbai', 'mumbai', false, 20), ('Hyderabad', 'hyderabad', false, 30),
  ('Pune', 'pune', false, 40), ('Noida', 'noida', true, 50), ('Gurugram', 'gurugram', true, 60), ('Delhi', 'delhi', true, 70)
on conflict (name) do nothing;
alter table public.cities enable row level security;
drop policy if exists "anyone reads cities" on public.cities;
create policy "anyone reads cities" on public.cities for select using (true);
revoke all on public.cities from anon, authenticated;
grant select on public.cities to anon, authenticated;

/** A city as people write it ("Bangalore", "gurgaon", "New Delhi") → its name here, or ''. */
create or replace function public.normalize_city(p text)
returns text
language sql
immutable
as $$
  select case
    when s = '' then ''
    when s in ('bengaluru', 'bangalore', 'blr', 'bengaluru urban', 'bangalore urban') then 'Bengaluru'
    when s in ('mumbai', 'bombay', 'navi mumbai', 'thane', 'mumbai suburban') then 'Mumbai'
    when s in ('hyderabad', 'secunderabad', 'hyd', 'cyberabad') then 'Hyderabad'
    when s in ('pune', 'pimpri', 'pimpri-chinchwad', 'pimpri chinchwad', 'chinchwad') then 'Pune'
    when s in ('noida', 'greater noida', 'gautam buddha nagar', 'noida extension') then 'Noida'
    when s in ('gurugram', 'gurgaon', 'ggn') then 'Gurugram'
    when s in ('delhi', 'new delhi', 'ncr delhi', 'national capital territory of delhi') then 'Delhi'
    else '' end
  from (select lower(regexp_replace(trim(coalesce(p, '')), '\s+', ' ', 'g')) as s) x;
$$;

/* ── Areas, per city ─────────────────────────────────────────────────────── */

alter table public.areas add column if not exists city text not null default 'Bengaluru';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'areas_city_fkey') then
    alter table public.areas add constraint areas_city_fkey foreign key (city) references public.cities (name) on update cascade;
  end if;
end $$;
-- A name is unique within its city ("Sector 15" is in Noida and in Gurugram).
drop index if exists public.areas_name_key;
create unique index if not exists areas_city_name_key on public.areas (city, lower(trim(name)));
create index if not exists areas_city_idx on public.areas (city, sort);

/** The city an area is in: the hint city if it has that area, else the one city that does, else ''. */
create or replace function public.city_of_area(p_area text, p_hint text default '')
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select a.city from public.areas a where lower(trim(a.name)) = lower(trim(coalesce(p_area, '')))
        and a.city = public.normalize_city(p_hint) limit 1),
    (select min(a.city) from public.areas a where lower(trim(a.name)) = lower(trim(coalesce(p_area, '')))
      having count(distinct a.city) = 1),
    '');
$$;

/** The city most of these areas are in ('' when none is known). */
create or replace function public.city_of_areas(p_areas text[], p_hint text default '')
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select c from (select public.city_of_area(x, p_hint) c from unnest(coalesce(p_areas, '{}')) x) y
     where c <> '' group by c order by count(*) desc, (c = public.normalize_city(p_hint)) desc limit 1), '');
$$;

-- The new cities' areas: the popular rental areas, the first dozen as chips.
insert into public.areas (city, name, chip, sort)
select x.city, x.name, x.n <= 12, x.n * 10
  from (
    select 'Mumbai' city, name, n from unnest(array[
      'Andheri West', 'Andheri East', 'Powai', 'Bandra West', 'Goregaon East', 'Malad West', 'Lower Parel', 'Worli',
      'Chembur', 'Ghatkopar', 'Thane West', 'Kandivali West', 'Bandra East', 'Khar West', 'Santacruz West', 'Juhu',
      'Vile Parle', 'Goregaon West', 'Borivali West', 'Chandivali', 'Vikhroli', 'Kanjurmarg', 'Mulund', 'Kurla',
      'Dadar', 'Prabhadevi', 'Vashi', 'Kharghar']) with ordinality u(name, n)
    union all
    select 'Hyderabad', name, n from unnest(array[
      'Gachibowli', 'HITEC City', 'Madhapur', 'Kondapur', 'Kukatpally', 'Manikonda', 'Financial District', 'Nanakramguda',
      'Jubilee Hills', 'Banjara Hills', 'Begumpet', 'Miyapur', 'Narsingi', 'Kokapet', 'Tellapur', 'Bachupally',
      'Ameerpet', 'Somajiguda', 'Secunderabad', 'Uppal', 'LB Nagar', 'Kompally', 'Raidurg', 'Puppalaguda']) with ordinality u(name, n)
    union all
    select 'Pune', name, n from unnest(array[
      'Hinjewadi', 'Wakad', 'Baner', 'Balewadi', 'Kharadi', 'Viman Nagar', 'Hadapsar', 'Magarpatta',
      'Aundh', 'Pimple Saudagar', 'Koregaon Park', 'Kalyani Nagar', 'Wagholi', 'Kothrud', 'Shivaji Nagar', 'Bavdhan',
      'Pashan', 'Undri', 'NIBM Road', 'Wanowrie', 'Pimpri', 'Chinchwad', 'Ravet', 'Tathawade']) with ordinality u(name, n)
    union all
    select 'Noida', name, n from unnest(array[
      'Sector 62', 'Sector 18', 'Sector 63', 'Sector 50', 'Sector 75', 'Sector 76', 'Sector 78', 'Sector 137',
      'Sector 128', 'Noida Extension', 'Sector 168', 'Greater Noida', 'Sector 15', 'Sector 44', 'Sector 93', 'Sector 100',
      'Sector 104', 'Sector 110', 'Sector 120', 'Sector 121', 'Sector 74', 'Sector 79']) with ordinality u(name, n)
    union all
    select 'Gurugram', name, n from unnest(array[
      'Cyber City', 'DLF Phase 1', 'DLF Phase 2', 'DLF Phase 3', 'DLF Phase 4', 'DLF Phase 5', 'Golf Course Road', 'Golf Course Extension Road',
      'Sohna Road', 'Sushant Lok', 'Sector 56', 'MG Road', 'Sector 14', 'Sector 15', 'Sector 43', 'Sector 45',
      'Sector 49', 'Sector 57', 'South City', 'Nirvana Country', 'Palam Vihar', 'Udyog Vihar', 'Sector 82', 'New Gurgaon']) with ordinality u(name, n)
    union all
    select 'Delhi', name, n from unnest(array[
      'Saket', 'Malviya Nagar', 'Hauz Khas', 'Green Park', 'Lajpat Nagar', 'Kalkaji', 'Greater Kailash', 'Vasant Kunj',
      'Dwarka', 'Laxmi Nagar', 'Mayur Vihar', 'Rajouri Garden', 'Defence Colony', 'Munirka', 'Karol Bagh', 'Janakpuri',
      'Patel Nagar', 'Pitampura', 'Rohini', 'Kamla Nagar', 'Mukherjee Nagar', 'Okhla', 'Sarita Vihar', 'Connaught Place']) with ordinality u(name, n)
  ) x
 where not exists (select 1 from public.areas a where a.city = x.city and lower(trim(a.name)) = lower(x.name));

/**
 * Add (no id) or change an area: { id?, city?, name?, chip?, parent_id?, active? }.
 * The city is set when the area is added (Bengaluru if not given). Keys left
 * out stay as they are. Returns the row. (areas.sql's, per city.)
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
  cty text;
begin
  if not public.is_super_admin() then raise exception 'Only the super admin can change the areas.' using errcode = '42501'; end if;
  if aid is null then
    cty := coalesce(nullif(public.normalize_city(p ->> 'city'), ''), 'Bengaluru');
  else
    select a.city into cty from public.areas a where a.id = aid;
  end if;
  if (aid is null or p ? 'name') and length(nm) not between 2 and 60 then
    raise exception 'Give the area a name (2 to 60 letters).' using errcode = '22023';
  end if;
  if (aid is null or p ? 'name') and exists (select 1 from public.areas a where a.city = cty and lower(trim(a.name)) = lower(nm) and a.id is distinct from aid) then
    raise exception '% is already on the % list.', nm, cty using errcode = '23505';
  end if;
  if p ? 'parent_id' and par is not null then
    if par = aid then raise exception 'An area can''t be inside itself.' using errcode = '22023'; end if;
    if not exists (select 1 from public.areas a where a.id = par) then raise exception 'That wider area isn''t on the list.' using errcode = '22023'; end if;
    if exists (select 1 from public.areas a where a.id = par and a.city <> cty) then
      raise exception 'That wider area is in another city.' using errcode = '22023';
    end if;
    if exists (select 1 from public.areas a where a.id = par and a.parent_id is not null) then
      raise exception 'That area is itself inside another; pick the wider one.' using errcode = '22023';
    end if;
    if aid is not null and exists (select 1 from public.areas a where a.parent_id = aid) then
      raise exception 'Other areas sit inside this one, so it can''t go inside another.' using errcode = '22023';
    end if;
  end if;

  if aid is null then
    insert into public.areas (city, name, chip, parent_id, sort, active)
    values (cty, nm, coalesce((p ->> 'chip')::boolean, false), par,
            coalesce((select max(a.sort) from public.areas a where a.active and a.city = cty), 0) + 10, coalesce((p ->> 'active')::boolean, true))
    returning id into aid;
  else
    update public.areas a set
      name       = case when p ? 'name' then nm else a.name end,
      chip       = case when p ? 'chip' then coalesce((p ->> 'chip')::boolean, false) else a.chip end,
      parent_id  = case when p ? 'parent_id' then par else a.parent_id end,
      active     = case when p ? 'active' then coalesce((p ->> 'active')::boolean, true) else a.active end,
      -- Brought back: to the end of the shown list.
      sort       = case when p ? 'active' and (p ->> 'active')::boolean and not a.active
                        then coalesce((select max(b.sort) from public.areas b where b.active and b.city = a.city), 0) + 10 else a.sort end,
      updated_at = now()
    where a.id = aid;
    if not found then raise exception 'That area isn''t on the list.' using errcode = '22023'; end if;
  end if;
  return (select to_jsonb(a) from public.areas a where a.id = aid);
end;
$$;

/* ── Flats ───────────────────────────────────────────────────────────────── */

update public.inventory set city = coalesce(nullif(public.normalize_city(city), ''), 'Bengaluru')
 where city is null or city <> coalesce(nullif(public.normalize_city(city), ''), 'Bengaluru');
alter table public.inventory alter column city set default 'Bengaluru';
create index if not exists inventory_city_status_idx on public.inventory (city, status);

/** A flat's city follows its area (in the city given, if that city has the area); else what was given; else Bengaluru. */
create or replace function public.inventory_city_fill()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  given text := public.normalize_city(new.city);
  by_area text := public.city_of_area(new.area, given);
begin
  new.city := coalesce(nullif(by_area, ''), nullif(given, ''), 'Bengaluru');
  return new;
end;
$$;
drop trigger if exists inventory_city_fill on public.inventory;
create trigger inventory_city_fill before insert or update of city, area on public.inventory
  for each row execute function public.inventory_city_fill();

/* ── Tenants: the city they are searching in ─────────────────────────────── */

alter table public.crm_clients add column if not exists city text not null default 'Bengaluru';
alter table public.crm_clients add column if not exists current_city text not null default '';
create index if not exists crm_clients_city_idx on public.crm_clients (city);
alter table public.user_requirements add column if not exists city text not null default '';
alter table public.user_requirements add column if not exists current_city text not null default '';

/** The CRM keeps a line when a client's search city changes. */
create or replace function public.crm_client_city_log()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.city := coalesce(nullif(public.normalize_city(new.city), ''), coalesce(old.city, 'Bengaluru'));
  new.current_city := coalesce(public.normalize_city(new.current_city), '');
  if tg_op = 'UPDATE' and new.city is distinct from old.city then
    insert into public.crm_activities (client_id, actor_email, type, body, meta)
    values (new.id, coalesce(nullif(lower(auth.jwt() ->> 'email'), ''), 'system'), 'system',
            'Search city changed from ' || old.city || ' to ' || new.city,
            jsonb_build_object('from_city', old.city, 'to_city', new.city));
  end if;
  return new;
end;
$$;
drop trigger if exists crm_client_city_log on public.crm_clients;
create trigger crm_client_city_log before insert or update of city, current_city on public.crm_clients
  for each row execute function public.crm_client_city_log();

/** The site's requirement form: its city (or its areas') becomes the client's search city. */
create or replace function public.user_requirements_city_sync()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  cur  text := (select c.city from public.crm_clients c where c.user_id = new.user_id limit 1);
  want text := coalesce(nullif(public.normalize_city(new.city), ''), nullif(public.city_of_areas(new.localities, cur), ''));
  here text := public.normalize_city(new.current_city);
begin
  if want is not null then
    update public.crm_clients c set city = want where c.user_id = new.user_id and c.city is distinct from want;
  end if;
  if here <> '' then
    update public.crm_clients c set current_city = here where c.user_id = new.user_id and c.current_city is distinct from here;
  end if;
  return new;
exception when others then
  raise warning 'user_requirements_city_sync(%): %', new.user_id, sqlerrm;
  return new;
end;
$$;
-- Named to run after crm_lead_when_searching, which may have just made the client.
drop trigger if exists zz_user_requirements_city_sync on public.user_requirements;
create trigger zz_user_requirements_city_sync after insert or update on public.user_requirements
  for each row execute function public.user_requirements_city_sync();

/** A phone-gate lead (lead_intake): prefs.city / prefs.currentCity, or its areas, set the client's. */
create or replace function public.lead_intake_city_sync()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  cur  text;
  want text;
  here text := public.normalize_city(new.prefs ->> 'currentCity');
begin
  if new.crm_client_id is null then return new; end if;
  select c.city into cur from public.crm_clients c where c.id = new.crm_client_id;
  want := coalesce(nullif(public.normalize_city(new.prefs ->> 'city'), ''),
                   nullif(public.city_of_areas(array(select jsonb_array_elements_text(
                     case when jsonb_typeof(new.prefs -> 'localities') = 'array' then new.prefs -> 'localities' else '[]'::jsonb end)), cur), ''));
  if want is not null then
    update public.crm_clients c set city = want where c.id = new.crm_client_id and c.city is distinct from want;
  end if;
  if here <> '' then
    update public.crm_clients c set current_city = here where c.id = new.crm_client_id and c.current_city is distinct from here;
  end if;
  return new;
exception when others then
  raise warning 'lead_intake_city_sync(%): %', new.lead_key, sqlerrm;
  return new;
end;
$$;
drop trigger if exists zz_lead_intake_city_sync on public.lead_intake;
create trigger zz_lead_intake_city_sync after insert or update on public.lead_intake
  for each row execute function public.lead_intake_city_sync();

/* ── The CRM team: which cities each person works ────────────────────────── */

alter table public.admin_roles add column if not exists cities text[] not null default '{}';

/** May the signed-in staff member see this city's clients? Super admin and an empty list: every city. */
create or replace function public.crm_city_ok(p_city text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_super_admin()
      or not exists (select 1 from public.admin_roles r
                      where lower(r.email) = lower(coalesce(auth.jwt() ->> 'email', '')) and cardinality(r.cities) > 0)
      or exists (select 1 from public.admin_roles r
                  where lower(r.email) = lower(coalesce(auth.jwt() ->> 'email', '')) and p_city = any (r.cities));
$$;

/** The cities the signed-in staff member works, in the usual order. */
create or replace function public.crm_my_cities()
returns text[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(c.name order by c.sort), '{}') from public.cities c
   where c.active and public.is_crm_staff() and public.crm_city_ok(c.name);
$$;

-- Clients of a city you don't work are not yours to read or change (on top of
-- the CRM's own policies; a tenant reading their own row is untouched).
drop policy if exists "crm city access" on public.crm_clients;
create policy "crm city access" on public.crm_clients as restrictive for all to authenticated
  using (not public.is_crm_staff() or public.crm_city_ok(city))
  with check (not public.is_crm_staff() or public.crm_city_ok(city));

/** Move a client to another search city (the CRM's city field). */
create or replace function public.crm_client_set_city(p_client uuid, p_city text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  c text := public.normalize_city(p_city);
  cur text;
begin
  if not public.is_crm_staff() then raise exception 'Not allowed.' using errcode = '42501'; end if;
  if c = '' then raise exception 'Pick one of the cities.' using errcode = '22023'; end if;
  select city into cur from public.crm_clients where id = p_client;
  if cur is null then raise exception 'No such client.' using errcode = 'P0002'; end if;
  if not public.crm_city_ok(cur) or not public.crm_city_ok(c) then
    raise exception 'You don''t work % clients.', case when public.crm_city_ok(cur) then c else cur end using errcode = '42501';
  end if;
  update public.crm_clients set city = c where id = p_client;
  return c;
end;
$$;

/* ── Brokers: one city each ──────────────────────────────────────────────── */

alter table public.broker_partners add column if not exists city text not null default 'Bengaluru';
create index if not exists broker_partners_city_idx on public.broker_partners (city, status);
alter table public.partner_groups alter column city set default 'Bengaluru';

/** The signed-in broker's city (Bengaluru for anyone else). */
create or replace function public.partner_city(p_user uuid default null)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select b.city from public.broker_partners b where b.user_id = coalesce(p_user, auth.uid())), 'Bengaluru');
$$;

-- partner_register gains the city picked at sign-up (partner_schema.sql's, plus p_city).
drop function if exists public.partner_register(text, text);
create or replace function public.partner_register(p_name text default null, p_agency text default null, p_city text default null)
returns public.broker_partners
language plpgsql
security definer
set search_path = public
as $$
declare
  uid   uuid := auth.uid();
  prof  public.user_profiles;
  phone text;
  auto  boolean;
  rec   public.broker_partners;
  cty   text := coalesce(nullif(public.normalize_city(p_city), ''), 'Bengaluru');
begin
  if uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;

  select * into prof from public.user_profiles where id = uid;
  phone := public.normalize_mobile(coalesce(prof.phone, ''));
  if phone = '' then
    raise exception 'Add your mobile number first.' using errcode = '22023';
  end if;

  select s.auto_approve into auto from public.partner_program_settings s where s.id = 1;

  insert into public.broker_partners as bp (user_id, name, phone, email, agency, status, approved_at, approved_by, city)
  values (
    uid,
    left(coalesce(nullif(trim(p_name), ''), prof.name, split_part(coalesce(auth.jwt() ->> 'email', ''), '@', 1)), 120),
    phone,
    lower(coalesce(auth.jwt() ->> 'email', '')),
    left(coalesce(trim(p_agency), ''), 120),
    case when coalesce(auto, true) then 'approved' else 'pending' end,
    case when coalesce(auto, true) then now() end,
    case when coalesce(auto, true) then 'auto' else '' end,
    cty
  )
  -- Re-registering refreshes the profile but never changes a decision:
  -- a suspended partner stays suspended. The city stays as picked at sign-up.
  on conflict (user_id) do update
     set name = coalesce(nullif(left(trim(p_name), 120), ''), bp.name),
         agency = coalesce(nullif(left(trim(p_agency), 120), ''), bp.agency),
         phone = excluded.phone,
         updated_at = now()
  returning * into rec;
  return rec;
end;
$$;

/** A union (partner group) is in its creator's city. */
create or replace function public.partner_group_city_fill()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.created_by is not null then
    new.city := public.partner_city(new.created_by);
  end if;
  return new;
end;
$$;
drop trigger if exists partner_group_city_fill on public.partner_groups;
create trigger partner_group_city_fill before insert on public.partner_groups
  for each row execute function public.partner_group_city_fill();

/** The CRM moves a broker to another city. */
create or replace function public.crm_partner_set_city(p_user uuid, p_city text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare c text := public.normalize_city(p_city);
begin
  if not public.has_admin_scope('partners.manage') then raise exception 'Not allowed.' using errcode = '42501'; end if;
  if c = '' then raise exception 'Pick one of the cities.' using errcode = '22023'; end if;
  update public.broker_partners set city = c, updated_at = now() where user_id = p_user;
  if not found then raise exception 'No such partner.' using errcode = 'P0002'; end if;
  return c;
end;
$$;

/* ── Leads go to brokers of the tenant's city ────────────────────────────── */

/** Never across cities — except the website's own flat-interest leads, which follow the flat. */
create or replace function public.partner_assignment_city_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  cc text;
  bc text;
begin
  if coalesce(new.assigned_by, '') = 'website' then return new; end if;
  select c.city into cc from public.crm_clients c where c.id = new.client_id;
  select b.city into bc from public.broker_partners b where b.user_id = new.broker_id;
  if cc is not null and bc is not null and cc <> bc then
    raise exception 'This tenant is searching in %, and this partner works in %. Give them to a % partner.', cc, bc, cc
      using errcode = '22023';
  end if;
  return new;
end;
$$;
drop trigger if exists partner_assignment_city_guard on public.partner_lead_assignments;
create trigger partner_assignment_city_guard before insert on public.partner_lead_assignments
  for each row execute function public.partner_assignment_city_guard();

-- lead_candidates (partner_moveazy_leads.sql), only tenants of the broker's city.
create or replace function public.lead_candidates(p_request uuid)
returns table (client_id uuid, name text, phone text, localities text[], flat_types text[], budget_min numeric,
               budget_max numeric, move_in_raw text, move_in date, brokers int, fits int, active_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  q public.partner_lead_requests;
  areas text[];
  types text[];
  bmin numeric;
  bmax numeric;
  bcity text;
begin
  select * into q from public.partner_lead_requests where id = p_request;
  if q.id is null then raise exception 'No such request.' using errcode = '22023'; end if;
  bcity := public.partner_city(q.broker_id);
  areas := array(select lower(jsonb_array_elements_text(coalesce(q.prefs -> 'areas', '[]'))));
  types := array(select lower(jsonb_array_elements_text(coalesce(q.prefs -> 'flat_types', '[]'))));
  bmin := nullif(q.prefs ->> 'budget_min', '')::numeric;
  bmax := nullif(q.prefs ->> 'budget_max', '')::numeric;
  return query
  select p.client_id, p.name, p.phone, p.localities, p.flat_types, p.budget_min, p.budget_max, p.move_in_raw, p.move_in,
         p.brokers,
         (case when cardinality(areas) = 0 or exists (select 1 from unnest(p.localities) l where lower(l) = any (areas)) then 1 else 0 end
        + case when cardinality(types) = 0 or exists (select 1 from unnest(p.flat_types) t where lower(t) = any (types)) then 1 else 0 end
        + case when (bmin is null and bmax is null) or coalesce(p.budget_max, p.budget_min) is null
                    or (coalesce(p.budget_max, p.budget_min) >= coalesce(bmin, 0) and coalesce(p.budget_max, p.budget_min) <= coalesce(bmax, 1e9))
               then 1 else 0 end)::int,
         p.active_at
    from public.moveazy_lead_pool() p
    join public.crm_clients cc on cc.id = p.client_id and cc.city = bcity
   where p.brokers < 3
     and not exists (select 1 from public.partner_lead_assignments a where a.client_id = p.client_id and a.broker_id = q.broker_id)
   order by 11 desc, p.move_in nulls last, p.active_at desc
   limit 300;
end;
$$;

-- lead_candidates_for_flats (partner_moveazy_leads.sql), only tenants of the broker's city.
create or replace function public.lead_candidates_for_flats(p_broker uuid)
returns table (client_id uuid, fits int, property_id text)
language sql
stable
security definer
set search_path = public
as $$
  with flats as (
    select i.property_id, lower(coalesce(i.area, '')) as area,
           array(select lower(x) from unnest(coalesce(i.nearby_areas, '{}')) x) as nearby,
           lower(coalesce(i.flat_type, '')) as flat_type, i.rent
      from public.partner_listings pl join public.inventory i on i.property_id = pl.property_id
     where pl.broker_id = p_broker and i.status = 'published'
  ), scored as (
    select p.client_id, p.move_in, p.active_at, f.property_id,
           (case when exists (select 1 from unnest(p.localities) l where lower(l) = f.area or lower(l) = any (f.nearby)) then 2 else 0 end
          + case when cardinality(p.flat_types) = 0 or exists (select 1 from unnest(p.flat_types) t where lower(t) = f.flat_type) then 1 else 0 end
          + case when f.rent is null or coalesce(p.budget_max, p.budget_min) is null
                      or (f.rent <= coalesce(p.budget_max, p.budget_min * 1.3) * 1.1 and f.rent >= coalesce(p.budget_min, 0) * 0.7)
                 then 1 else 0 end)::int as fits
      from public.moveazy_lead_pool() p
      join public.crm_clients cc on cc.id = p.client_id and cc.city = public.partner_city(p_broker)
      cross join flats f
     where p.brokers < 3
       and not exists (select 1 from public.partner_lead_assignments a where a.client_id = p.client_id and a.broker_id = p_broker)
  ), best as (
    select distinct on (s.client_id) s.client_id, s.fits, s.property_id, s.move_in, s.active_at
      from scored s order by s.client_id, s.fits desc
  )
  select b.client_id, b.fits, b.property_id from best b
   where b.fits >= 3
   order by b.fits desc, b.move_in nulls last, b.active_at desc
   limit 300;
$$;

/* ── Premium price and brokerage shares, per city ────────────────────────── */

create table if not exists public.program_city_settings (
  city           text primary key references public.cities (name) on update cascade,
  premium_price  int     not null check (premium_price between 0 and 1000000),
  property_share numeric not null check (property_share between 0 and 100),
  client_share   numeric not null check (client_share between 0 and 100),
  updated_at     timestamptz not null default now(),
  updated_by     text not null default ''
);
insert into public.program_city_settings (city, premium_price, property_share, client_share)
select c.name, s.premium_price, s.property_share, s.client_share
  from public.cities c cross join public.program_settings s
 where s.id = 1
on conflict (city) do nothing;
alter table public.program_city_settings enable row level security;
revoke all on public.program_city_settings from anon, authenticated;
drop policy if exists "staff read city settings" on public.program_city_settings;
create policy "staff read city settings" on public.program_city_settings for select to authenticated using (public.is_crm_staff());
grant select on public.program_city_settings to authenticated;

/** A city's price and shares (Bengaluru's if the city has none). */
create or replace function public.city_program(p_city text)
returns public.program_city_settings
language sql
stable
security definer
set search_path = public
as $$
  select * from public.program_city_settings s
   where s.city in (coalesce(nullif(public.normalize_city(p_city), ''), 'Bengaluru'), 'Bengaluru')
   order by (s.city = 'Bengaluru') limit 1;
$$;

-- landing_settings (program_settings.sql), with a city's price and shares.
drop function if exists public.landing_settings();
create or replace function public.landing_settings(p_city text default null)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'premiumPrice', c.premium_price, 'premiumListPrice', s.premium_list_price,
    'avgBrokerage', s.avg_brokerage, 'propertyShare', c.property_share, 'clientShare', c.client_share,
    'paintMarket', s.paint_market, 'paintMoveazy', s.paint_moveazy, 'paintCycles', s.paint_cycles,
    'hourlyValue', s.hourly_value, 'vacantDaysWith', s.vacant_days_with,
    'statBrokers', s.stat_brokers, 'statProperties', s.stat_properties, 'statRating', s.stat_rating,
    'videoBroker', s.video_broker, 'videoOwner', s.video_owner,
    'city', c.city,
    'updatedAt', greatest(s.updated_at, c.updated_at)
  )
  from public.program_settings s cross join lateral (select * from public.city_program(p_city)) c
  where s.id = 1;
$$;

-- admin_set_program_settings (program_settings.sql): a "city" key aims the
-- price and shares at that city (Bengaluru also keeps program_settings in step).
create or replace function public.admin_set_program_settings(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  k text;
  allowed text[] := array['premiumPrice', 'premiumListPrice', 'avgBrokerage', 'propertyShare', 'clientShare',
    'paintMarket', 'paintMoveazy', 'paintCycles', 'hourlyValue', 'vacantDaysWith',
    'statBrokers', 'statProperties', 'statRating', 'videoBroker', 'videoOwner', 'city'];
  cty text := coalesce(nullif(public.normalize_city(p ->> 'city'), ''), 'Bengaluru');
begin
  if not public.has_admin_scope('partners.manage') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'Settings must be an object.' using errcode = '22023';
  end if;
  for k in select jsonb_object_keys(p) loop
    if not k = any (allowed) then
      raise exception 'Unknown setting: %', k using errcode = '22023';
    end if;
  end loop;

  update public.program_city_settings c set
    premium_price  = coalesce((p ->> 'premiumPrice')::int, c.premium_price),
    property_share = coalesce((p ->> 'propertyShare')::numeric, c.property_share),
    client_share   = coalesce((p ->> 'clientShare')::numeric, c.client_share),
    updated_at     = now(),
    updated_by     = lower(coalesce(auth.jwt() ->> 'email', ''))
  where c.city = cty and (p ? 'premiumPrice' or p ? 'propertyShare' or p ? 'clientShare');

  update public.program_settings s set
    premium_price      = case when cty = 'Bengaluru' then coalesce((p ->> 'premiumPrice')::int, s.premium_price) else s.premium_price end,
    premium_list_price = coalesce((p ->> 'premiumListPrice')::int, s.premium_list_price),
    avg_brokerage      = coalesce((p ->> 'avgBrokerage')::int, s.avg_brokerage),
    property_share     = case when cty = 'Bengaluru' then coalesce((p ->> 'propertyShare')::numeric, s.property_share) else s.property_share end,
    client_share       = case when cty = 'Bengaluru' then coalesce((p ->> 'clientShare')::numeric, s.client_share) else s.client_share end,
    paint_market       = coalesce((p ->> 'paintMarket')::int, s.paint_market),
    paint_moveazy      = coalesce((p ->> 'paintMoveazy')::int, s.paint_moveazy),
    paint_cycles       = coalesce((p ->> 'paintCycles')::int, s.paint_cycles),
    hourly_value       = coalesce((p ->> 'hourlyValue')::int, s.hourly_value),
    vacant_days_with   = coalesce((p ->> 'vacantDaysWith')::int, s.vacant_days_with),
    stat_brokers       = coalesce(trim(p ->> 'statBrokers'), s.stat_brokers),
    stat_properties    = coalesce(trim(p ->> 'statProperties'), s.stat_properties),
    stat_rating        = coalesce(trim(p ->> 'statRating'), s.stat_rating),
    video_broker       = coalesce(trim(p ->> 'videoBroker'), s.video_broker),
    video_owner        = coalesce(trim(p ->> 'videoOwner'), s.video_owner),
    updated_at         = now(),
    updated_by         = lower(coalesce(auth.jwt() ->> 'email', ''))
  where s.id = 1;

  -- The partner app's plan row carries Bengaluru's price (partner_me gives each broker their city's).
  if to_regclass('public.partner_tiers') is not null and cty = 'Bengaluru' then
    update public.partner_tiers t
       set price_monthly = s.premium_price, trial_price = s.premium_price
      from public.program_settings s
     where s.id = 1 and t.tier = 'moveazy_inventory';
  end if;

  return public.landing_settings(cty);
exception
  when invalid_text_representation then
    raise exception 'Numbers only, please.' using errcode = '22023';
  when check_violation then
    raise exception 'That value is out of range.' using errcode = '22023';
end;
$$;

-- partner_me (partner_schema.sql): the broker's city, and its price and shares.
create or replace function public.partner_me()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with c as (select * from public.city_program(public.partner_city()))
  select jsonb_build_object(
    'partner', (select to_jsonb(p) from public.broker_partners p where p.user_id = auth.uid()),
    'staff', public.is_crm_staff(),
    'can_manage', public.has_admin_scope('partners.manage'),
    'city', (select c.city from c),
    'property_share', (select c.property_share from c),
    'client_share', coalesce((select p.client_share_pct from public.broker_partners p where p.user_id = auth.uid()),
                             (select c.client_share from c)),
    'tiers', coalesce((
      select jsonb_object_agg(t.tier, jsonb_build_object(
        'label', t.label, 'is_free', t.is_free,
        'price_monthly', case when t.tier = 'moveazy_inventory' then (select c.premium_price from c) else t.price_monthly end,
        'trial_price', case when t.tier = 'moveazy_inventory' then (select c.premium_price from c) else t.trial_price end,
        'description', t.description,
        'active', public.partner_has_tier(t.tier),
        'ends_at', (select max(e.ends_at) from public.partner_entitlements e
                     where e.user_id = auth.uid() and e.tier = t.tier and now() < e.ends_at)))
        from public.partner_tiers t), '{}'::jsonb)
  );
$$;

/* ── The partner app's flats ─────────────────────────────────────────────── */

-- partner_inventory (partner_group_privacy.sql): the broker's city only, at that city's property share.
create or replace function public.partner_inventory()
returns table (
  property_id     text,
  source          text,       -- mine | moveazy | broker
  on_platform     boolean,    -- shared with all MovEazy brokers
  group_ids       uuid[],     -- groups it is shared with that the caller can see
  brokerage_pct   numeric,    -- what the CALLER earns on it (null: not offered)
  locked          boolean,
  status          text,
  title           text,
  city            text,
  area            text,
  nearby_areas    text[],
  full_address    text,
  landmark        text,
  latitude        numeric,
  longitude       numeric,
  rent            numeric,
  deposit         numeric,
  available_from  date,
  property_type   text,
  flat_type       text,
  bedrooms        int,
  bathrooms       int,
  furnishing      text,
  amenities       text[],
  description     text,
  images          text[],
  cover_image_url text,
  is_verified     boolean,
  lister_id       uuid,
  lister_name     text,
  lister_agency   text,
  lister_phone    text,
  created_at      timestamptz,
  updated_at      timestamptz,
  rent_flag       text,
  anonymous       boolean     -- another partner's (or MovEazy's) flat, not yet unlocked: no lister, no exact place
)
language sql
stable
security definer
set search_path = public
as $$
  with me as (
    select auth.uid() as uid,
           public.is_crm_staff() as staff,
           public.is_approved_partner() as partner,
           public.partner_has_tier('moveazy_inventory') as premium,
           (select c.property_share from public.city_program(public.partner_city()) c) as property_share,
           public.partner_city() as city
  ),
  my_groups as (
    select m.group_id from public.partner_group_members m, me where m.user_id = me.uid
  ),
  src as (
    select
      i.*,
      pl.broker_id as pl_broker,
      (pl.property_id is not null) as is_partner_listing,
      ps.share_pct as platform_pct,
      (
        select coalesce(array_agg(gs.group_id order by gs.group_id), '{}')
          from public.partner_group_shares gs, me
         where gs.property_id = i.property_id
           and (me.staff or gs.group_id in (select group_id from my_groups)
                or pl.broker_id = me.uid)
      ) as visible_groups,
      (
        select max(gs.share_pct)
          from public.partner_group_shares gs
         where gs.property_id = i.property_id
           and gs.group_id in (select group_id from my_groups)
      ) as best_group_pct,
      -- Anonymous — in the pool and in groups alike: not mine, no tenant of mine
      -- has liked it yet (partner_pool_unlocks), and not listed by a partner I
      -- brought in with my referral link.
      (not (select staff from me) and pl.broker_id is distinct from (select uid from me)
       and not exists (select 1 from public.partner_pool_unlocks u
                        where u.partner_id = (select uid from me) and u.property_id = i.property_id)
       and not exists (select 1 from public.broker_partners rb join public.broker_partners mb on mb.user_id = (select uid from me)
                        where rb.user_id = pl.broker_id and coalesce(mb.referral_code, '') <> '' and rb.referred_by = mb.referral_code)) as anon,
      -- The exact place: the lister, staff, or a broker the lister said yes to.
      (pl.broker_id = (select uid from me) or (select staff from me)
       or exists (select 1 from public.partner_location_requests lr
                   where lr.property_id = i.property_id and lr.requested_by = (select uid from me)
                     and lr.status = 'approved')) as place_open
    from public.inventory i
    left join public.partner_listings pl on pl.property_id = i.property_id
    left join public.partner_platform_shares ps on ps.property_id = i.property_id
  )
  select
    r.property_id,
    case when not r.is_partner_listing then 'moveazy'
         when r.pl_broker = me.uid then 'mine'
         else 'broker' end,
    r.platform_pct is not null,
    r.visible_groups,
    case when not r.is_partner_listing then me.property_share
         when r.pl_broker = me.uid then greatest(r.platform_pct, (select max(gs.share_pct) from public.partner_group_shares gs where gs.property_id = r.property_id))
         else greatest(r.platform_pct, r.best_group_pct) end,
    (not r.is_partner_listing and not me.premium),
    r.status,
    r.title, r.city, r.area, r.nearby_areas,
    -- MovEazy's own flats: on a plan. Another broker's: only once they have
    -- approved this caller's request -- until then, the area and nothing finer.
    case when r.anon or (not r.is_partner_listing and not me.premium) or (r.is_partner_listing and not r.place_open) then '' else r.full_address end,
    case when r.anon or (r.is_partner_listing and not r.place_open) then '' else r.landmark end,
    case when r.anon or (not r.is_partner_listing and not me.premium) or (r.is_partner_listing and not r.place_open) then null else r.latitude end,
    case when r.anon or (not r.is_partner_listing and not me.premium) or (r.is_partner_listing and not r.place_open) then null else r.longitude end,
    r.rent, r.deposit, r.available_from, r.property_type, r.flat_type, r.bedrooms, r.bathrooms,
    r.furnishing, r.amenities, r.description, r.images, r.cover_image_url, r.is_verified,
    case when r.is_partner_listing and not r.anon then r.pl_broker end,
    case when r.is_partner_listing and not r.anon then coalesce(nullif(bp.name, ''), r.poster_name) end,
    case when r.is_partner_listing and not r.anon then bp.agency end,
    case when r.is_partner_listing and not r.anon then coalesce(nullif(bp.phone, ''), r.phone) end,
    r.created_at, r.updated_at, r.rent_flag, r.anon
  from src r
  cross join me
  left join public.broker_partners bp on bp.user_id = r.pl_broker
  where (me.partner or me.staff)
    -- A broker sees their own city's flats (and always their own); staff see every city.
    and (me.staff or r.pl_broker = me.uid or coalesce(r.city, 'Bengaluru') = me.city)
    and (
      -- MovEazy's own inventory, unless the CRM held it back.
      (not r.is_partner_listing and r.status = 'published' and (r.partner_visible or me.staff))
      -- Your own, in any state.
      or (r.is_partner_listing and r.pl_broker = me.uid)
      -- Someone else's, shared with everyone or with a group you are in now —
      -- for partners on a plan.
      or (r.is_partner_listing and r.status = 'published' and me.premium
          and (r.platform_pct is not null or r.best_group_pct is not null))
      -- Staff see every partner listing, group-only and paused ones included.
      or (r.is_partner_listing and me.staff)
    );
$$;

-- crm_listing_set_partner (partner_referral_mapping.sql): only to a partner of the flat's city, at that city's share.
create or replace function public.crm_listing_set_partner(p_property text, p_partner uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  inv   public.inventory;
  pl    public.partner_listings;
  owner text;
  who   public.broker_partners;
  share numeric;
begin
  if not (public.has_admin_scope('crm.properties.write') or public.has_admin_scope('partners.manage')) then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  select * into inv from public.inventory where property_id = p_property for update;
  if inv.property_id is null then raise exception 'No listing %.', p_property using errcode = 'P0002'; end if;
  select * into pl from public.partner_listings where property_id = p_property for update;

  if pl.property_id is not null and pl.mapped_by = '' then
    select coalesce(nullif(name, ''), 'a partner') into owner from public.broker_partners where user_id = pl.broker_id;
    raise exception '% added this flat in the partner app — it stays theirs.', owner using errcode = '22023';
  end if;

  if p_partner is null then
    if pl.property_id is not null then
      delete from public.partner_listings where property_id = p_property;
      update public.inventory set broker_id = pl.prev_broker_id where property_id = p_property and broker_id is not distinct from pl.broker_id;
    end if;
    return jsonb_build_object('partner', null);
  end if;

  select * into who from public.broker_partners where user_id = p_partner and status = 'approved';
  if who.user_id is null then raise exception 'Pick an approved partner.' using errcode = '22023'; end if;
  if pl.broker_id = p_partner then return jsonb_build_object('partner', who.name); end if;
  if coalesce(who.city, 'Bengaluru') <> coalesce(inv.city, 'Bengaluru') then
    raise exception 'This flat is in %, and % works in %.', inv.city, coalesce(nullif(who.name, ''), 'that partner'), who.city using errcode = '22023';
  end if;

  if pl.property_id is null then
    insert into public.partner_listings (property_id, broker_id, mapped_by, prev_broker_id)
    values (p_property, p_partner, lower(coalesce(auth.jwt() ->> 'email', '')), inv.broker_id);
  else
    -- A new partner: the old one's group shares go with them.
    delete from public.partner_group_shares where property_id = p_property;
    update public.partner_listings
       set broker_id = p_partner, mapped_by = lower(coalesce(auth.jwt() ->> 'email', '')), updated_at = now()
     where property_id = p_property;
  end if;
  -- Still in every Premium partner's pool, at the program's property share.
  select c.property_share into share from public.city_program(inv.city) c;
  insert into public.partner_platform_shares (property_id, share_pct)
  values (p_property, coalesce(share, 50))
  on conflict (property_id) do nothing;
  update public.inventory set broker_id = p_partner where property_id = p_property;

  insert into public.partner_notifications (broker_id, kind, title, body, link)
  values (p_partner, 'listing_assigned', 'A flat was added to your listings',
          trim(both ' ·' from concat_ws(' · ',
            nullif(case when coalesce(inv.bedrooms, 0) > 0 then inv.bedrooms || ' BHK' end, ''),
            nullif(inv.area, ''),
            case when coalesce(inv.rent, 0) > 0 then '₹' || to_char(inv.rent, 'FM99,99,999') end))
            || '. MovEazy gave it to you — it''s in My Inventory.',
          '/property/' || p_property);
  return jsonb_build_object('partner', who.name);
end;
$$;

/* ── Steal Deals and Deal of the Day, per city (find_deals.sql's) ────────── */

-- A Steal Deals week holds flats of every city (each flat has one); the Deal
-- of the Day is one flat per type, per day, per city.
alter table public.day_deals add column if not exists city text not null default 'Bengaluru';
do $$ begin
  if exists (select 1 from pg_constraint where conname = 'day_deals_pkey'
              and pg_get_constraintdef(oid) not like '%city%') then
    alter table public.day_deals drop constraint day_deals_pkey;
    alter table public.day_deals add constraint day_deals_pkey primary key (day, kind, city);
  end if;
end $$;

/** A city for the deals: the one given, else Bengaluru. */
create or replace function public.deal_city(p_city text)
returns text
language sql
immutable
as $$
  select coalesce(nullif(public.normalize_city(p_city), ''), 'Bengaluru');
$$;

drop function if exists public.deals_feed();
create or replace function public.deals_feed(p_city text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  mon   date := public.deal_this_monday();
  today date := (now() at time zone 'Asia/Kolkata')::date;
  cty   text := public.deal_city(p_city);
  wk    date;
begin
  select max(s.week_start) into wk
    from public.steal_deals s join public.inventory i on i.property_id = s.property_id
   where s.week_start <= mon and i.city = cty;
  return jsonb_build_object(
    'city', cty,
    'week_start', mon,
    'week_end', mon + 6,
    'today', today,
    -- Each flat drawn once (the list has no cap: an "add all 2 BHK" week can hold a hundred).
    'steal', coalesce((
      select jsonb_agg(x.j order by x.sort, x.created_at)
        from (select s.sort, s.created_at, public.deal_flat_json(s.property_id) j
                from public.steal_deals s join public.inventory i on i.property_id = s.property_id
               where s.week_start = wk and i.city = cty) x
       where x.j is not null), '[]'::jsonb),
    'day', coalesce((
      select jsonb_agg(d.j || jsonb_build_object('kind', d.kind, 'since', d.day) order by array_position(array['1rk', '1bhk', '2bhk', '3bhk'], d.kind))
        from (
          select distinct on (x.kind) x.kind, x.day, public.deal_flat_json(x.property_id) j
            from public.day_deals x
           where x.day <= today and x.city = cty and public.deal_flat_json(x.property_id) is not null
           order by x.kind, x.day desc
        ) d), '[]'::jsonb)
  );
end;
$$;

drop function if exists public.crm_deals(date, date, date);
create or replace function public.crm_deals(p_week date, p_from date, p_to date, p_city text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  wk  date := date_trunc('week', coalesce(p_week, public.deal_this_monday()))::date;
  cty text := public.deal_city(p_city);
begin
  perform public.crm_deal_staff();
  return jsonb_build_object(
    'city', cty,
    'week_start', wk,
    'this_monday', public.deal_this_monday(),
    'today', (now() at time zone 'Asia/Kolkata')::date,
    'steal', coalesce((select jsonb_agg(public.crm_deal_flat(s.property_id) || jsonb_build_object('added_by', s.added_by) order by s.sort, s.created_at)
                         from public.steal_deals s join public.inventory i on i.property_id = s.property_id
                        where s.week_start = wk and i.city = cty), '[]'::jsonb),
    'weeks', coalesce((select jsonb_agg(jsonb_build_object('week_start', w.week_start, 'n', w.n) order by w.week_start desc)
                         from (select s.week_start, count(*) n from public.steal_deals s join public.inventory i on i.property_id = s.property_id
                                where i.city = cty group by s.week_start) w), '[]'::jsonb),
    'days', coalesce((select jsonb_agg(public.crm_deal_flat(d.property_id) || jsonb_build_object('day', d.day, 'slot', d.kind, 'set_by', d.set_by) order by d.day, d.kind)
                        from public.day_deals d
                       where d.city = cty and d.day between coalesce(p_from, current_date) and coalesce(p_to, current_date + 30)), '[]'::jsonb)
  );
end;
$$;

/** Set a city's Steal Deals for a week to exactly these flats, in this order (other cities' weeks untouched). */
drop function if exists public.crm_deal_steal_set(date, text[]);
create or replace function public.crm_deal_steal_set(p_week date, p_ids text[], p_city text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  who text := public.crm_deal_staff();
  wk  date := date_trunc('week', p_week)::date;
  -- Once each, in the order given.
  ids text[] := array(select x from unnest(coalesce(p_ids, '{}')) with ordinality u(x, n) where coalesce(x, '') <> '' group by x order by min(n));
  cty text := public.deal_city(coalesce(p_city, (select i.city from public.inventory i where i.property_id = (coalesce(p_ids, '{}'))[1])));
  bad text;
begin
  if p_week is null then raise exception 'Pick a week.' using errcode = '22023'; end if;
  select x into bad from unnest(ids) x
   where not exists (select 1 from public.inventory i where i.property_id = x and i.status = 'published') limit 1;
  if bad is not null then raise exception '% isn''t a live flat.', bad using errcode = '22023'; end if;
  select x into bad from unnest(ids) x
   where not exists (select 1 from public.inventory i where i.property_id = x and i.city = cty) limit 1;
  if bad is not null then raise exception '% is not a % flat.', bad, cty using errcode = '22023'; end if;

  delete from public.steal_deals s using public.inventory i
   where s.week_start = wk and i.property_id = s.property_id and i.city = cty and not (s.property_id = any(ids));
  insert into public.steal_deals (week_start, property_id, sort, added_by)
  select wk, x, n::int, who from unnest(ids) with ordinality u(x, n)
  on conflict (week_start, property_id) do update set sort = excluded.sort;
  return public.crm_deals(wk, null, null, cty);
end;
$$;

/** Add one flat to its city's Steal Deals for a week (the shortcut on a property). */
create or replace function public.crm_deal_steal_add(p_week date, p_property text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  wk  date := date_trunc('week', coalesce(p_week, public.deal_this_monday()))::date;
  cty text := public.deal_city((select i.city from public.inventory i where i.property_id = p_property));
  cur text[];
begin
  perform public.crm_deal_staff();
  select array_agg(s.property_id order by s.sort, s.created_at) into cur
    from public.steal_deals s join public.inventory i on i.property_id = s.property_id
   where s.week_start = wk and i.city = cty;
  if p_property = any(coalesce(cur, '{}')) then return public.crm_deals(wk, null, null, cty); end if;
  return public.crm_deal_steal_set(wk, coalesce(cur, '{}') || p_property, cty);
end;
$$;

/** Add every live flat of one type in one city to that city's Steal Deals, cheapest first. Any CRM user. */
drop function if exists public.crm_deal_steal_add_kind(date, text);
create or replace function public.crm_deal_steal_add_kind(p_week date, p_kind text, p_city text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  wk  date := date_trunc('week', coalesce(p_week, public.deal_this_monday()))::date;
  cty text := public.deal_city(p_city);
  cur text[];
  more text[];
begin
  perform public.crm_deal_staff();
  if p_kind is null or p_kind not in ('1rk', '1bhk', '2bhk', '3bhk') then
    raise exception 'Pick a flat type.' using errcode = '22023';
  end if;
  select coalesce(array_agg(s.property_id order by s.sort, s.created_at), '{}') into cur
    from public.steal_deals s join public.inventory i on i.property_id = s.property_id
   where s.week_start = wk and i.city = cty;
  select coalesce(array_agg(i.property_id order by i.rent nulls last, i.property_id), '{}') into more
    from public.inventory i
   where i.status = 'published' and i.city = cty and public.deal_kind(i.flat_type) = p_kind and not (i.property_id = any(cur));
  return public.crm_deal_steal_set(wk, cur || more, cty);
end;
$$;

/** Set (or clear, with a null flat) a city's Deal of the Day for one type on one day. */
drop function if exists public.crm_deal_day_set(date, text, text);
create or replace function public.crm_deal_day_set(p_day date, p_kind text, p_property text, p_city text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  who text := public.crm_deal_guard();
  k   text;
  cty text := public.deal_city(coalesce(p_city, (select i.city from public.inventory i where i.property_id = p_property)));
  fc  text;
begin
  if p_day is null or p_kind not in ('1rk', '1bhk', '2bhk', '3bhk') then
    raise exception 'Pick a day and a flat type.' using errcode = '22023';
  end if;
  if coalesce(p_property, '') = '' then
    delete from public.day_deals where day = p_day and kind = p_kind and city = cty;
    return public.crm_deals(null, p_day, p_day, cty);
  end if;
  select public.deal_kind(i.flat_type), i.city into k, fc from public.inventory i where i.property_id = p_property and i.status = 'published';
  if not found then raise exception '% isn''t a live flat.', p_property using errcode = '22023'; end if;
  if fc is distinct from cty then raise exception '% is not a % flat.', p_property, cty using errcode = '22023'; end if;
  if k is distinct from p_kind then
    raise exception 'That flat is not a % — pick one of that type.', case p_kind when '1rk' then '1 RK' when '1bhk' then '1 BHK' when '2bhk' then '2 BHK' else '3 BHK or bigger' end
      using errcode = '22023';
  end if;
  insert into public.day_deals (day, kind, city, property_id, set_by) values (p_day, p_kind, cty, p_property, who)
  on conflict (day, kind, city) do update set property_id = excluded.property_id, set_by = excluded.set_by, set_at = now();
  return public.crm_deals(null, p_day, p_day, cty);
end;
$$;

/* ── Grants ──────────────────────────────────────────────────────────────── */

do $$
declare f text;
begin
  -- Anyone (the site, before sign-in).
  foreach f in array array['public.normalize_city(text)', 'public.city_of_area(text, text)', 'public.city_of_areas(text[], text)',
                           'public.landing_settings(text)', 'public.deals_feed(text)', 'public.deal_city(text)'] loop
    execute format('revoke all on function %s from public', f);
    execute format('grant execute on function %s to anon, authenticated', f);
  end loop;
  -- Signed in (each checks who may).
  foreach f in array array['public.crm_city_ok(text)', 'public.crm_my_cities()', 'public.crm_client_set_city(uuid, text)',
                           'public.partner_city(uuid)', 'public.partner_register(text, text, text)', 'public.crm_partner_set_city(uuid, text)',
                           'public.admin_set_program_settings(jsonb)', 'public.partner_me()', 'public.partner_inventory()',
                           'public.crm_listing_set_partner(text, uuid)', 'public.area_save(jsonb)',
                           'public.crm_deals(date, date, date, text)', 'public.crm_deal_steal_set(date, text[], text)',
                           'public.crm_deal_steal_add(date, text)', 'public.crm_deal_steal_add_kind(date, text, text)',
                           'public.crm_deal_day_set(date, text, text, text)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  -- Internal.
  foreach f in array array['public.inventory_city_fill()', 'public.crm_client_city_log()', 'public.user_requirements_city_sync()',
                           'public.lead_intake_city_sync()', 'public.partner_assignment_city_guard()', 'public.city_program(text)',
                           'public.partner_group_city_fill()',
                           'public.lead_candidates(uuid)', 'public.lead_candidates_for_flats(uuid)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;

commit;
