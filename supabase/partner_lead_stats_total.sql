-- Run after partner_moveazy_leads.sql.
--
-- What partners see under "MovEazy leads" (and the home card): every client
-- MovEazy has ever had — its whole book, closed ones too — counted fresh each
-- time the app asks, and the BHK/area, move-in and budget bars over those same
-- clients so they add up to the headline.
--
-- Which clients a partner can actually be given is unchanged:
-- moveazy_lead_pool() (open, active in the last 60 days, something to go on,
-- fewer than 3 brokers) still decides assignments.
--
-- A move-in date already past says nothing about when they move now: those
-- count as "Flexible / not sure", never "within a week".

begin;

create or replace function public.partner_moveazy_lead_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  today      date := (now() at time zone 'Asia/Kolkata')::date;
  next_month date := (date_trunc('month', (now() at time zone 'Asia/Kolkata')) + interval '1 month')::date;
  out        jsonb;
begin
  if not public.is_approved_partner() then
    raise exception 'Only MovEazy partners can see this.' using errcode = '42501';
  end if;
  with book as (
    select c.id as client_id,
           coalesce(nullif(r.localities, '{}'), u.localities, '{}') as localities,
           coalesce(nullif(r.flat_types, '{}'), u.flat_types, '{}') as flat_types,
           coalesce(r.budget_min, u.budget_min) as budget_min,
           coalesce(r.budget_max, u.budget_max) as budget_max,
           public.lead_move_in_date(
             case when coalesce(r.move_in, '') <> '' then r.move_in else coalesce(u.notes ->> 'moveInDate', '') end,
             case when coalesce(r.move_in, '') <> '' then r.updated_at else u.updated_at end) as move_in
      from public.crm_clients c
      left join public.crm_client_requirements r on r.client_id = c.id
      left join public.user_requirements u on u.user_id = c.user_id
     where coalesce(c.attributed_to, 'moveazy') = 'moveazy'
  ),
  pool as (
    select b.client_id, b.localities, b.flat_types, b.budget_min, b.budget_max,
           case when b.move_in >= today then b.move_in end as move_in
      from book b
  ),
  pairs as (
    select f as bhk, a as area, count(distinct p.client_id)::int as n
      from pool p, unnest(case when cardinality(p.flat_types) > 0 then p.flat_types else array['Any'] end) f,
                   unnest(case when cardinality(p.localities) > 0 then p.localities else array['Anywhere'] end) a
     group by 1, 2
  )
  select jsonb_build_object(
    'total', (select count(*) from pool),
    'bhk_area', coalesce((select jsonb_agg(jsonb_build_object('bhk', bhk, 'area', area, 'n', n) order by n desc, bhk, area)
                            from pairs), '[]'::jsonb),
    'move_in', jsonb_build_object(
      'week',     (select count(*) from pool where move_in <= today + 7),
      'before',   (select count(*) from pool where move_in < next_month),
      'before_date', next_month,
      'month',    (select count(*) from pool where move_in > today + 7 and move_in <= today + 30),
      'two_months', (select count(*) from pool where move_in > today + 30 and move_in <= today + 60),
      'later',    (select count(*) from pool where move_in > today + 60),
      'flexible', (select count(*) from pool where move_in is null)),
    'budget', jsonb_build_object(
      'under20', (select count(*) from pool where coalesce(budget_max, budget_min) < 20000),
      'b20_35',  (select count(*) from pool where coalesce(budget_max, budget_min) >= 20000 and coalesce(budget_max, budget_min) < 35000),
      'b35_50',  (select count(*) from pool where coalesce(budget_max, budget_min) >= 35000 and coalesce(budget_max, budget_min) < 50000),
      'b50plus', (select count(*) from pool where coalesce(budget_max, budget_min) >= 50000),
      'unknown', (select count(*) from pool where coalesce(budget_max, budget_min) is null)),
    'pack_price', (select s.lead_pack_price from public.program_settings s where s.id = 1),
    'upi_id', (select s.lead_upi_id from public.program_settings s where s.id = 1),
    'premium', public.partner_has_paid_premium(),
    'flats_live', public.partner_live_flats(auth.uid()),
    'free_given', (select count(*) from public.partner_lead_assignments a join public.partner_lead_requests r on r.id = a.request_id
                    where r.broker_id = auth.uid() and r.pack = 'free10'),
    'allowance', public.partner_lead_allowance(auth.uid())
  ) into out;
  return out;
end;
$$;
revoke all on function public.partner_moveazy_lead_stats() from public, anon;
grant execute on function public.partner_moveazy_lead_stats() to authenticated;

commit;
