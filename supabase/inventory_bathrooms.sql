-- Bathrooms default to the number of bedrooms: 1 BHK 1, 2 BHK 2, 3 BHK 3.
--
--   · A flat saved with no bathroom count gets one per bedroom (never 0).
--   · A flat whose BHK changes follows it, while its bathrooms were still the
--     default (1, or equal to the old bedrooms) and weren't changed alongside.
--   · Every flat already saved at the old default of 1 bathroom with 2 or
--     more bedrooms is corrected once. A count somebody chose — 3 BHK with 2
--     bathrooms, 1 BHK with 2 — is left as it is.
--
-- Only bathrooms is written, so the deposit, listing and sold-out triggers
-- (which watch other columns) don't run. Safe to re-run.

begin;

create or replace function public.inventory_default_bathrooms()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'INSERT' then
    if coalesce(new.bathrooms, 0) <= 0 then
      new.bathrooms := greatest(1, coalesce(new.bedrooms, 1));
    end if;
  elsif new.bedrooms is distinct from old.bedrooms
    and new.bathrooms is not distinct from old.bathrooms
    and (coalesce(old.bathrooms, 0) <= 1 or old.bathrooms = old.bedrooms) then
    new.bathrooms := greatest(1, coalesce(new.bedrooms, 1));
  end if;
  return new;
end;
$$;
revoke all on function public.inventory_default_bathrooms() from public, anon, authenticated;

drop trigger if exists inventory_default_bathrooms on public.inventory;
create trigger inventory_default_bathrooms before insert or update of bedrooms, bathrooms on public.inventory
  for each row execute function public.inventory_default_bathrooms();

-- The flats saved at the old default.
update public.inventory
   set bathrooms = greatest(1, coalesce(bedrooms, 1))
 where coalesce(bathrooms, 0) <= 0
    or (bathrooms = 1 and coalesce(bedrooms, 1) > 1);

commit;
