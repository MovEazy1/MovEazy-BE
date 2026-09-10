-- Admin database browser (fe/src/pages/AdminDatabase.jsx → fe/src/lib/adminDb.js).
-- Lets an allowlisted admin enumerate every table in the public schema with a
-- live row count, without hard-coding the list on the client.
--
-- Run once in the Supabase SQL editor, AFTER admin_schema.sql (it depends on
-- public.is_admin_allowlisted()).

-- Returns one row per base table in the public schema, with an exact row count.
-- Admin-gated: non-admins get an empty result rather than an error, so the
-- client can fall back to its static registry cleanly.
create or replace function public.admin_list_tables()
returns table (table_name text, row_count bigint)
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  cnt bigint;
begin
  if not public.is_admin_allowlisted() then
    return;  -- no rows for non-admins
  end if;

  for r in
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind = 'r'          -- ordinary tables only
    order by c.relname
  loop
    execute format('select count(*) from public.%I', r.relname) into cnt;
    table_name := r.relname;
    row_count := cnt;
    return next;
  end loop;
end;
$$;

grant execute on function public.admin_list_tables() to authenticated;
