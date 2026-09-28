-- ─────────────────────────────────────────────────────────────────────────────
-- Program settings — the numbers the team changes without a deploy.
--
-- Run in the Supabase SQL editor AFTER crm_schema.sql (has_admin_scope) and
-- BEFORE partner_schema.sql (partner_inventory reads property_share from here).
-- Safe to re-run: the row is inserted once, the functions are replaced.
--
-- One row, typed and range-checked, so a typo in the CRM can't put a 500%
-- share or a negative price live:
--
--   premium_price / premium_list_price  Broker Premium, ₹/month: the offer and
--                                        the struck-through regular price.
--   avg_brokerage                        Average brokerage per closed rental (₹),
--                                        used by the landing calculator.
--   property_share                       % of the brokerage a Premium broker keeps
--                                        on a MovEazy-posted property. This is
--                                        LIVE: partner_inventory() returns it as
--                                        brokerage_pct on every MovEazy listing.
--   client_share                         % a broker keeps on a client MovEazy
--                                        shares with them (default; each broker
--                                        can be overridden in the CRM).
--   paint_market / paint_moveazy /       Owner repainting cost for a standard
--   paint_cycles                         2 BHK, at market and through MovEazy,
--                                        for the first N tenant cycles.
--   hourly_value, vacant_days_with       Owner calculator assumptions.
--   stat_* , video_*                     Landing page headline stats and videos.
--
-- Anyone may read (landing_settings(), the signed-out landing pages need it);
-- only partners.manage may write (admin_set_program_settings()).
-- ─────────────────────────────────────────────────────────────────────────────

begin;

create table if not exists public.program_settings (
  id                 int primary key default 1 check (id = 1),
  premium_price      int not null default 1499  check (premium_price between 0 and 1000000),
  premium_list_price int not null default 10000 check (premium_list_price between 0 and 1000000),
  avg_brokerage      int not null default 25000 check (avg_brokerage between 0 and 10000000),
  property_share     numeric not null default 50 check (property_share between 0 and 100),
  client_share       numeric not null default 70 check (client_share between 0 and 100),
  paint_market       int not null default 50000 check (paint_market between 0 and 10000000),
  paint_moveazy      int not null default 25000 check (paint_moveazy between 0 and 10000000),
  paint_cycles       int not null default 3     check (paint_cycles between 0 and 100),
  hourly_value       int not null default 2000  check (hourly_value between 0 and 1000000),
  vacant_days_with   int not null default 7     check (vacant_days_with between 0 and 365),
  stat_brokers       text not null default '20+'   check (length(stat_brokers) <= 20),
  stat_properties    text not null default '1000+' check (length(stat_properties) <= 20),
  stat_rating        text not null default '4.8/5' check (length(stat_rating) <= 20),
  video_broker       text not null default '' check (video_broker = '' or video_broker ~* '^https://'),
  video_owner        text not null default '' check (video_owner = '' or video_owner ~* '^https://'),
  updated_at         timestamptz not null default now(),
  updated_by         text not null default ''
);
insert into public.program_settings (id) values (1) on conflict (id) do nothing;

alter table public.program_settings enable row level security;
revoke all on public.program_settings from anon, authenticated;
-- Reads go through landing_settings(); staff may also select the row directly.
drop policy if exists "staff read program settings" on public.program_settings;
create policy "staff read program settings" on public.program_settings
  for select to authenticated using (public.is_crm_staff());
grant select on public.program_settings to authenticated;


/** The public view, in the landing pages' own key names. */
create or replace function public.landing_settings()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'premiumPrice', s.premium_price, 'premiumListPrice', s.premium_list_price,
    'avgBrokerage', s.avg_brokerage, 'propertyShare', s.property_share, 'clientShare', s.client_share,
    'paintMarket', s.paint_market, 'paintMoveazy', s.paint_moveazy, 'paintCycles', s.paint_cycles,
    'hourlyValue', s.hourly_value, 'vacantDaysWith', s.vacant_days_with,
    'statBrokers', s.stat_brokers, 'statProperties', s.stat_properties, 'statRating', s.stat_rating,
    'videoBroker', s.video_broker, 'videoOwner', s.video_owner,
    'updatedAt', s.updated_at
  )
  from public.program_settings s where s.id = 1;
$$;

revoke all on function public.landing_settings() from public;
grant execute on function public.landing_settings() to anon, authenticated;


/**
 * Update any subset of the settings: keys are the landing_settings() names.
 * Unknown keys are refused rather than ignored, so a CRM form bug is loud.
 */
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
    'statBrokers', 'statProperties', 'statRating', 'videoBroker', 'videoOwner'];
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

  update public.program_settings s set
    premium_price      = coalesce((p ->> 'premiumPrice')::int, s.premium_price),
    premium_list_price = coalesce((p ->> 'premiumListPrice')::int, s.premium_list_price),
    avg_brokerage      = coalesce((p ->> 'avgBrokerage')::int, s.avg_brokerage),
    property_share     = coalesce((p ->> 'propertyShare')::numeric, s.property_share),
    client_share       = coalesce((p ->> 'clientShare')::numeric, s.client_share),
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

  -- The partner app's plan row carries the price too; keep it in step.
  if to_regclass('public.partner_tiers') is not null then
    update public.partner_tiers t
       set price_monthly = s.premium_price, trial_price = s.premium_price
      from public.program_settings s
     where s.id = 1 and t.tier = 'moveazy_inventory';
  end if;

  return public.landing_settings();
exception
  when invalid_text_representation then
    raise exception 'Numbers only, please.' using errcode = '22023';
  when check_violation then
    raise exception 'That value is out of range.' using errcode = '22023';
end;
$$;

revoke all on function public.admin_set_program_settings(jsonb) from public;
grant execute on function public.admin_set_program_settings(jsonb) to authenticated;

commit;
