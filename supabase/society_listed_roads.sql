-- ─────────────────────────────────────────────────────────────────────────────
-- Every society on the six roads around HSR (HSR Layout, Sarjapur, Haralur,
-- Silver County, Hosa, Kudlu) on the tenant site, researched or not
-- (2026-11-17). Changes sp_listed and the page-code trigger in
-- society_partners.sql. Re-runnable.
-- ─────────────────────────────────────────────────────────────────────────────
begin;

create or replace function public.sp_listed(s public.society_prospects)
returns boolean
language sql
immutable
as $$
  select not s.hidden and (s.live or cardinality(s.amenities) > 0 or coalesce(s.rents, '{}'::jsonb) <> '{}'::jsonb
                          or s.road in ('hsr', 'sarjapur', 'haralur', 'silver', 'hosa', 'kudlu'));
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
  if new.public_code is null and (new.live or cardinality(new.amenities) > 0 or coalesce(new.rents, '{}'::jsonb) <> '{}'::jsonb
                                  or new.road in ('hsr', 'sarjapur', 'haralur', 'silver', 'hosa', 'kudlu')) then
    for i in 1..25 loop
      select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '') into code from generate_series(1, 6);
      exit when not exists (select 1 from public.society_prospects where public_code = code);
    end loop;
    new.public_code := code;
  end if;
  return new;
end;
$$;

-- Page codes for the six roads' societies (the trigger fills them in).
update public.society_prospects set updated_at = updated_at
 where public_code is null and road in ('hsr', 'sarjapur', 'haralur', 'silver', 'hosa', 'kudlu');

commit;
