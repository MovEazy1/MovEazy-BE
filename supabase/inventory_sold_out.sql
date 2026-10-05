-- ─────────────────────────────────────────────────────────────────────────────
-- Sold out — the day a listing went off the market, kept so the CRM can say
-- which flats sold out in which month (fe/src/pages/crm/CrmPropertiesPage.jsx).
--
-- Run in the Supabase SQL editor AFTER inventory_schema.sql and crm_schema.sql
-- (has_admin_scope). Safe to re-run.
--
-- "Sold out" is inventory.status = 'rented', whoever sets it — the CRM's
-- button, the edit form, an owner in owners.moveazy.co.in, a partner's
-- sold-out request being confirmed. A trigger stamps the date on every one of
-- those, so no path can mark a flat gone without it:
--
--   inventory.sold_out_at / sold_out_by   when, and by whom; cleared if the
--                                          flat comes back on the market.
--   inventory_sold_out_log                 one row per sale, never cleared —
--                                          a flat relisted in June and let
--                                          again in September keeps both.
--
-- crm_mark_sold_out() lets staff back-date it ("it went last Tuesday");
-- crm_relist() puts it back. Both need crm.properties.write.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

alter table public.inventory add column if not exists sold_out_at timestamptz;
alter table public.inventory add column if not exists sold_out_by text not null default '';
create index if not exists inventory_sold_out_idx on public.inventory (sold_out_at desc) where sold_out_at is not null;
-- Not private: a date and who pressed the button. Granted with the public
-- columns, so a later column-list copy of anon's grants keeps it.
grant select (sold_out_at, sold_out_by) on public.inventory to anon, authenticated;

create table if not exists public.inventory_sold_out_log (
  id           bigint generated always as identity primary key,
  property_id  text not null references public.inventory (property_id) on delete cascade,
  sold_out_at  timestamptz not null,
  sold_out_by  text not null default '',
  relisted_at  timestamptz,
  relisted_by  text not null default '',
  created_at   timestamptz not null default now()
);
create index if not exists inventory_sold_out_log_at_idx on public.inventory_sold_out_log (sold_out_at desc);
create index if not exists inventory_sold_out_log_prop_idx on public.inventory_sold_out_log (property_id, sold_out_at desc);
alter table public.inventory_sold_out_log enable row level security;
revoke all on public.inventory_sold_out_log from public, anon, authenticated;
drop policy if exists "staff read" on public.inventory_sold_out_log;
create policy "staff read" on public.inventory_sold_out_log for select to authenticated using (public.is_crm_staff());
grant select on public.inventory_sold_out_log to authenticated;

/** Who is doing this: the signed-in email, or 'system' for the SQL editor and jobs. */
create or replace function public.inventory_actor()
returns text
language sql
stable
as $$
  select left(coalesce(nullif(lower(auth.jwt() ->> 'email'), ''), auth.uid()::text, 'system'), 120);
$$;

/** Stamp the date on the way into 'rented'; clear it on the way out. */
create or replace function public.inventory_sold_out_stamp()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'rented' and (tg_op = 'INSERT' or old.status is distinct from 'rented') then
    -- A caller that set its own date (crm_mark_sold_out back-dating) keeps it.
    if tg_op = 'INSERT' or new.sold_out_at is not distinct from old.sold_out_at or new.sold_out_at is null then
      new.sold_out_at := coalesce(case when tg_op = 'INSERT' then new.sold_out_at end, now());
    end if;
    if coalesce(new.sold_out_by, '') = '' or (tg_op = 'UPDATE' and new.sold_out_by is not distinct from old.sold_out_by) then
      new.sold_out_by := public.inventory_actor();
    end if;
  elsif new.status is distinct from 'rented' and tg_op = 'UPDATE' and old.status = 'rented' then
    new.sold_out_at := null;
    new.sold_out_by := '';
  end if;
  return new;
end;
$$;

/** Write the history: a row per sale, closed when the flat is relisted. */
create or replace function public.inventory_sold_out_history()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'rented' and (tg_op = 'INSERT' or old.status is distinct from 'rented') then
    insert into public.inventory_sold_out_log (property_id, sold_out_at, sold_out_by)
    values (new.property_id, new.sold_out_at, new.sold_out_by);
  elsif tg_op = 'UPDATE' and new.status = 'rented' and new.sold_out_at is distinct from old.sold_out_at then
    -- Re-dated while still sold out: the open row follows.
    update public.inventory_sold_out_log set sold_out_at = new.sold_out_at, sold_out_by = new.sold_out_by
     where id = (select id from public.inventory_sold_out_log
                  where property_id = new.property_id and relisted_at is null order by sold_out_at desc limit 1);
  elsif tg_op = 'UPDATE' and old.status = 'rented' and new.status is distinct from 'rented' then
    update public.inventory_sold_out_log set relisted_at = now(), relisted_by = public.inventory_actor()
     where property_id = new.property_id and relisted_at is null;
  end if;
  return null;
end;
$$;

drop trigger if exists inventory_sold_out_stamp on public.inventory;
create trigger inventory_sold_out_stamp before insert or update of status, sold_out_at on public.inventory
  for each row execute function public.inventory_sold_out_stamp();
drop trigger if exists inventory_sold_out_history on public.inventory;
create trigger inventory_sold_out_history after insert or update of status, sold_out_at on public.inventory
  for each row execute function public.inventory_sold_out_history();

-- Flats already sold out before this: the date is known only where a partner's
-- sold-out request was confirmed. The rest stay undated ("not recorded").
do $$
begin
  if to_regclass('public.partner_soldout_requests') is null then return; end if;
  update public.inventory i
     set sold_out_at = q.decided_at, sold_out_by = coalesce(nullif(q.decided_by, ''), 'system')
    from (select distinct on (property_id) property_id, decided_at, decided_by
            from public.partner_soldout_requests
           where status = 'approved' and decided_at is not null
           order by property_id, decided_at desc) q
   where i.property_id = q.property_id and i.status = 'rented' and i.sold_out_at is null;
  insert into public.inventory_sold_out_log (property_id, sold_out_at, sold_out_by)
  select i.property_id, i.sold_out_at, i.sold_out_by from public.inventory i
   where i.status = 'rented' and i.sold_out_at is not null
     and not exists (select 1 from public.inventory_sold_out_log l where l.property_id = i.property_id);
end $$;

/**
 * Mark a listing sold out — today, or on the day it actually went (a date in
 * the last year, not in the future). Already sold out: re-dates it.
 */
create or replace function public.crm_mark_sold_out(p_property text, p_on date default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  today date := (now() at time zone 'Asia/Kolkata')::date;
  stamp timestamptz;
  r     public.inventory;
begin
  if not public.has_admin_scope('crm.properties.write') then
    raise exception 'You need "Add and edit listings" to do this.' using errcode = '42501';
  end if;
  if p_on is not null and (p_on > today or p_on < today - 366) then
    raise exception 'Pick a date in the last year, not in the future.' using errcode = '22023';
  end if;
  -- Today: the moment. Another day: midday in India, so it never slips a month either side.
  stamp := case when p_on is null or p_on = today then now()
             else (p_on + time '12:00') at time zone 'Asia/Kolkata' end;
  update public.inventory
     set status = 'rented', sold_out_at = stamp, sold_out_by = public.inventory_actor(), updated_at = now()
   where property_id = p_property
  returning * into r;
  if r.property_id is null then raise exception 'No such listing.' using errcode = 'P0002'; end if;
  -- A pending "someone says it's rented" request from a partner is answered by this.
  if to_regclass('public.partner_soldout_requests') is not null then
    execute 'update public.partner_soldout_requests set status = ''approved'', decided_at = now(), decided_by = $2
              where property_id = $1 and status = ''pending''' using p_property, public.inventory_actor();
    update public.inventory set rent_flag = '' where property_id = p_property and rent_flag <> '';
  end if;
  return jsonb_build_object('property_id', r.property_id, 'status', r.status,
                            'sold_out_at', r.sold_out_at, 'sold_out_by', r.sold_out_by);
end;
$$;

/** Back on the market: published again; the history keeps the sale. */
create or replace function public.crm_relist(p_property text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.inventory;
begin
  if not public.has_admin_scope('crm.properties.write') then
    raise exception 'You need "Add and edit listings" to do this.' using errcode = '42501';
  end if;
  update public.inventory set status = 'published', updated_at = now()
   where property_id = p_property and status = 'rented'
  returning * into r;
  if r.property_id is null then raise exception 'That listing is not sold out.' using errcode = '22023'; end if;
  return jsonb_build_object('property_id', r.property_id, 'status', r.status);
end;
$$;

revoke all on function public.inventory_actor() from public, anon;
grant execute on function public.inventory_actor() to authenticated;
revoke all on function public.inventory_sold_out_stamp() from public, anon, authenticated;
revoke all on function public.inventory_sold_out_history() from public, anon, authenticated;
revoke all on function public.crm_mark_sold_out(text, date) from public, anon;
grant execute on function public.crm_mark_sold_out(text, date) to authenticated;
revoke all on function public.crm_relist(text) from public, anon;
grant execute on function public.crm_relist(text) to authenticated;

commit;
