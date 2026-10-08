-- Step 1 of 2: a way to read a listing's private columns that is not "have
-- SELECT on the table".
--
-- == The hole ==
--
--     grant select on public.inventory to anon, authenticated;   (inventory_schema.sql)
--
-- inventory_public_columns.sql took that back from anon and handed anon a
-- named list of public columns. It left `authenticated` alone, because column
-- grants are role-wide and CRM staff and flat owners are `authenticated` too:
-- restricting the role would have cut them off from phone / poster_name as
-- well. So every signed-in tenant -- every tenant, the flow requires Google
-- sign-in -- could `select=*` and read the poster's phone, email and account
-- id for the whole board, because the row policy admits every published row.
--
-- == The fix, in two files ==
--
--   this file                          inventory_full() -- the full row, but only
--                                      your own listings, or every listing if you
--                                      are staff. Everything else that has to
--                                      stop reading those columns off the table.
--   inventory_authenticated_columns.sql  the revoke. Run it only once the
--                                      frontend that calls inventory_full() is
--                                      live, or the CRM goes blank until it is.
--
-- This file only adds and tightens; nothing that works today stops working.
-- Run once in the Supabase SQL editor. Safe to re-run.

begin;

-- == 1. The full row, for whoever is entitled to it =========================
--
-- A function, not a view. A view runs as its owner and reads straight past the
-- RLS underneath unless it is declared security_invoker -- which is how the
-- lead views leaked (lead_intake_view_lockdown.sql) -- and security_invoker
-- would be no use here anyway: it would run as `authenticated`, which is
-- exactly the role about to lose the columns.
--
-- security definer, so the entitlement lives in the WHERE below and nowhere
-- else:
--   * your own listings, whatever their status -- My Properties, Tenant and
--     Rent Management, the nav's "you have listings" check;
--   * everything, for CRM staff -- the CRM reads and edits all supply;
--   * everything, for the admin allowlist -- the old row policy already gave
--     them every row, and the admin panel reads poster contacts too.
-- A signed-in tenant gets their own (usually zero) rows. anon gets nothing,
-- and is not granted execute at all.
--
-- Returns the table's own row type, so PostgREST lets a caller pick columns,
-- filter and order on it exactly as on the table:
--   supabase.rpc('inventory_full').select('property_id,phone').eq('status','published')
--
-- The staff checks are wrapped in scalar subqueries so Postgres evaluates each
-- once per call rather than once per row.
create or replace function public.inventory_full()
returns setof public.inventory
language sql
stable
security definer
set search_path = public
as $$
  select i.*
    from public.inventory i
   where (auth.uid() is not null and i.poster_id = auth.uid())
      or (select public.is_crm_staff())
      or (select public.is_admin_allowlisted());
$$;

comment on function public.inventory_full() is
  'Full inventory rows including poster contact columns: the caller''s own listings, or all of them for CRM staff / allowlisted admins. The table itself only grants public columns to anon and authenticated.';

-- `revoke ... from public` because functions are executable by PUBLIC by
-- default; anon named outright because Supabase's default privileges grant it
-- explicitly and a revoke from PUBLIC leaves that standing.
revoke all on function public.inventory_full() from public, anon;
grant execute on function public.inventory_full() to authenticated;


-- == 2. "Is this your listing?" without reading poster_id ====================
--
-- property_visit_slots lets a poster manage their own slots with a policy that
-- runs `select 1 from inventory where ... and inv.poster_id = auth.uid()`. A
-- subquery inside a policy is permission-checked as the caller, so the moment
-- authenticated loses select on poster_id every insert, update and delete on
-- property_visit_slots fails with 42501 -- an owner could no longer offer a
-- visit time on their own flat. (Reads survive only because "anyone reads
-- slots" is `using (true)` and the planner folds the OR away.) Measured in
-- tests/inventory_check.mjs.
--
-- The same question, asked by a function that is allowed to look.
create or replace function public.is_inventory_poster(pid text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and exists (
    select 1 from public.inventory i
     where i.property_id = pid
       and i.poster_id = auth.uid()
  );
$$;

revoke all on function public.is_inventory_poster(text) from public, anon;
grant execute on function public.is_inventory_poster(text) to authenticated;

-- Same rule as poster_visit_slots.sql, same name, now through the function.
do $$
begin
  if to_regclass('public.property_visit_slots') is not null then
    execute 'drop policy if exists "posters manage own slots" on public.property_visit_slots';
    execute $p$
      create policy "posters manage own slots" on public.property_visit_slots
        for all
        to authenticated
        using (
          public.is_admin_allowlisted()
          or public.is_inventory_poster(property_visit_slots.property_id)
        )
        with check (
          public.is_admin_allowlisted()
          or public.is_inventory_poster(property_visit_slots.property_id)
        )
    $p$;
  end if;
end $$;


-- == 3. recommend_inventory handed out the whole row, to anon ================
--
-- It is security definer and granted to anon, and it returned to_jsonb(inv) --
-- every column. Checked from outside with the publishable key before this
-- change: 96 rows, each carrying phone, poster_email, poster_name and
-- poster_id. The column grants never applied to it; a function running as its
-- owner does not consult them.
--
-- The fix is in recommend_inventory.sql itself (it is the one definition of
-- that function): `listing` is now built from only the columns anon may read,
-- decided by has_column_privilege, so it can never carry more than a
-- signed-out `select` on the table could. Re-run that file after this one.

commit;


-- == Verify ==================================================================
--
-- 1. anon cannot call it; authenticated can (expect false, true):
--
--      select has_function_privilege('anon', 'public.inventory_full()', 'execute') as anon,
--             has_function_privilege('authenticated', 'public.inventory_full()', 'execute') as authed;
--
-- 2. The slot policy no longer reads inventory.poster_id itself (expect one row
--    naming is_inventory_poster, and no "poster_id" in either expression):
--
--      select policyname, qual, with_check
--        from pg_policies
--       where tablename = 'property_visit_slots' and policyname = 'posters manage own slots';
