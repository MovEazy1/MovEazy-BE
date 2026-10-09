-- ─────────────────────────────────────────────────────────────────────────────
-- A deposit for every listing: 3.5 × the rent, rounded to the nearest ₹5,000,
-- whenever the poster leaves it blank (fe/src/lib/deposit.js shows the same
-- figure in the forms).
--
-- Run in the Supabase SQL editor AFTER inventory_schema.sql. Safe to re-run.
--
--   inventory.deposit_auto   true while the deposit is the automatic one. It
--                            then follows the rent: change the rent and the
--                            deposit moves with it. Typing a real deposit turns
--                            it off for good; clearing it turns it back on.
--
-- Every channel (CRM, owner app, partner app, List my flat, the owner-app RPCs)
-- writes through the table, so one trigger covers them all. Listings saved
-- before this with no deposit are filled in at the end.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

alter table public.inventory add column if not exists deposit_auto boolean not null default false;
-- Public, like the deposit itself.
grant select (deposit_auto) on public.inventory to anon, authenticated;

create or replace function public.inventory_auto_deposit_amount(p_rent numeric)
returns numeric
language sql
immutable
as $$
  select case when coalesce(p_rent, 0) > 0 then round(p_rent * 3.5 / 5000) * 5000 end;
$$;

create or replace function public.inventory_auto_deposit()
returns trigger
language plpgsql
as $$
declare
  auto numeric := public.inventory_auto_deposit_amount(new.rent);
begin
  if tg_op = 'UPDATE' and new.deposit is distinct from old.deposit and coalesce(new.deposit, 0) > 0 then
    -- Somebody typed a deposit: it is theirs now, whatever the rent does.
    new.deposit_auto := false;
  elsif coalesce(new.deposit, 0) <= 0 then
    -- Blank (or cleared): the automatic one.
    new.deposit := auto;
    new.deposit_auto := auto is not null;
  elsif tg_op = 'UPDATE' and old.deposit_auto and new.rent is distinct from old.rent then
    -- Still automatic and the rent moved: follow it.
    new.deposit := coalesce(auto, new.deposit);
  elsif tg_op = 'INSERT' then
    new.deposit_auto := false;
  end if;
  return new;
end;
$$;

revoke all on function public.inventory_auto_deposit() from public, anon, authenticated;

drop trigger if exists inventory_auto_deposit on public.inventory;
create trigger inventory_auto_deposit before insert or update of deposit, rent on public.inventory
  for each row execute function public.inventory_auto_deposit();

-- Listings already up without a deposit.
update public.inventory set deposit = null where coalesce(deposit, 0) <= 0 and coalesce(rent, 0) > 0;

commit;
