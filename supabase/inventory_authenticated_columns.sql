-- Step 2 of 2: take the poster's contact columns away from `authenticated`.
--
-- RUN ONLY AFTER
--   * inventory_private_read.sql (and recommend_inventory.sql re-run), and
--   * the frontend that reads private columns through inventory_full() is live.
-- Before that deploy, the CRM, My Properties and the admin panel still select
-- phone / poster_name / poster_id off the table and would come back empty.
--
-- What this does is what inventory_public_columns.sql did for anon: revoke the
-- table-wide SELECT, re-grant a column list. The list is not typed out here --
-- it is copied from what anon holds right now, so a signed-in tenant can read
-- exactly what a signed-out visitor can and nothing more. Every column added
-- since (maintenance, floor_number, total_floors) was granted to both roles
-- together; copying anon keeps that pairing true without a second list to
-- drift.
--
-- Staff, owners and admins lose nothing: inventory_full() returns them the full
-- row. INSERT / UPDATE / DELETE are untouched, and the row policies on
-- inventory still reference poster_id freely -- a policy's own expression is
-- not subject to the caller's column grants.
--
-- Run once in the Supabase SQL editor. Safe to re-run.

begin;

do $$
declare
  private_cols constant text[] := array[
    'phone', 'poster_email', 'poster_name',
    'poster_id', 'owner_id', 'tenant_id', 'broker_id'
  ];
  public_cols text[];
  leaked      text[];
  blocker     text;
begin
  -- Refuse to run out of order. Without the function, this file would lock
  -- staff out of the columns they need with no other way to reach them.
  if to_regprocedure('public.inventory_full()') is null then
    raise exception 'Run inventory_private_read.sql first: public.inventory_full() does not exist.';
  end if;

  -- Any policy elsewhere that looks up a poster by reading inventory directly
  -- would start failing with 42501 -- for every signed-in reader of that
  -- table, not only posters. inventory_private_read.sql moves the one we know
  -- of (property_visit_slots) onto is_inventory_poster(); this catches any the
  -- repository doesn't know about.
  select string_agg(format('%I.%I', p.tablename, p.policyname), ', ')
    into blocker
    from pg_policies p
   where p.schemaname = 'public'
     and p.tablename <> 'inventory'
     and (coalesce(p.qual, '') || ' ' || coalesce(p.with_check, '')) ~* '\minventory\M'
     and (coalesce(p.qual, '') || ' ' || coalesce(p.with_check, ''))
         ~* '\m(phone|poster_email|poster_name|poster_id|owner_id|tenant_id|broker_id)\M';
  if blocker is not null then
    raise exception 'These policies read private inventory columns as the caller and would break: %. Rewrite them over public.is_inventory_poster() first.', blocker;
  end if;

  select array_agg(column_name::text order by column_name)
    into public_cols
    from information_schema.column_privileges
   where table_schema = 'public'
     and table_name = 'inventory'
     and grantee = 'anon'
     and privilege_type = 'SELECT';

  -- anon still holding the whole table means inventory_public_columns.sql never
  -- ran; copying that would copy the leak.
  if public_cols is null
     or has_table_privilege('anon', 'public.inventory', 'select') then
    raise exception 'anon has no column list on inventory (or still holds the whole table). Run inventory_public_columns.sql first.';
  end if;

  leaked := array(select unnest(public_cols) intersect select unnest(private_cols));
  if cardinality(leaked) > 0 then
    raise exception 'anon is granted private columns % -- fix that before copying its list.', leaked;
  end if;

  -- A table-level revoke also removes every column-level SELECT grant, so this
  -- starts from nothing each time it runs.
  revoke select on public.inventory from authenticated;
  execute format(
    'grant select (%s) on public.inventory to authenticated',
    (select string_agg(quote_ident(c), ', ') from unnest(public_cols) c)
  );

  raise notice 'authenticated may now select % inventory columns: %',
    cardinality(public_cols), array_to_string(public_cols, ', ');
end $$;

commit;


-- == Verify ==================================================================
--
-- 1. Both roles can read the same columns, and none of the private ones
--    (expect zero rows):
--
--      select column_name, grantee
--        from information_schema.column_privileges
--       where table_schema = 'public' and table_name = 'inventory'
--         and privilege_type = 'SELECT'
--         and grantee in ('anon', 'authenticated')
--         and column_name in ('phone','poster_email','poster_name',
--                             'poster_id','owner_id','tenant_id','broker_id');
--
--      select has_table_privilege('authenticated', 'public.inventory', 'select');  -- false
--
-- 2. From outside, as a signed-in tenant (their access token from the browser
--    session) -- every one of these must FAIL with 42501, not return rows:
--
--      curl "$URL/rest/v1/inventory?select=*&limit=1"                -H "apikey: $ANON" -H "Authorization: Bearer $TENANT_JWT"
--      curl "$URL/rest/v1/inventory?select=phone,poster_email&limit=1" -H "apikey: $ANON" -H "Authorization: Bearer $TENANT_JWT"
--
--    and inventory_full must return only that tenant's own listings:
--
--      curl "$URL/rest/v1/rpc/inventory_full?select=property_id,poster_id" -H "apikey: $ANON" -H "Authorization: Bearer $TENANT_JWT"
--
--    MovEazy-FE/scripts/verify-inventory-pii.mjs runs all of this.
--
-- To undo (reopens the leak): grant select on public.inventory to authenticated;
