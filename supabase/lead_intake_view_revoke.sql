-- Finish the lockdown: take the SELECT grant off anon.
--
-- The previous file revoked first and then recreated the views, which is the
-- wrong way round. Supabase carries ALTER DEFAULT PRIVILEGES on `public`
-- granting SELECT to anon and authenticated, so every newly created view picks
-- that grant up — and a `create view` after a `revoke` simply re-granted what
-- had just been taken away.
--
-- The leak itself is already closed: those views now carry
-- security_invoker = true, so they read as the caller and the staff-only policy
-- on lead_intake applies. anon queries return no rows. This removes the grant
-- as well, so the two protections are independent — if anyone later rebuilds a
-- view and forgets security_invoker, the missing grant still holds the line.

begin;

revoke all on public.crm_lead_intake from anon;
revoke all on public.crm_direct_property_leads from anon;

-- PUBLIC is a separate grantee from anon and is easy to miss: a grant here
-- reaches every role, including anon, whatever anon's own grants say.
revoke all on public.crm_lead_intake from public;
revoke all on public.crm_direct_property_leads from public;

grant select on public.crm_lead_intake to authenticated;
grant select on public.crm_direct_property_leads to authenticated;

commit;


-- ── Verify ───────────────────────────────────────────────────────────────────
-- Both false now.
--
--   select has_table_privilege('anon', 'public.crm_lead_intake', 'select')
--       as anon_can_read_leads,
--          has_table_privilege('anon', 'public.crm_direct_property_leads', 'select')
--       as anon_can_read_direct;
--
-- Worth running once across the whole schema: every view anon can read that
-- sits on top of a table relying on row-level security. Each one is the same
-- trap — the policy protects the table, and the view walks around it unless it
-- was created with security_invoker.
--
--   select v.relname as view_name, t.relname as reads_table
--     from pg_class v
--     join pg_namespace n on n.oid = v.relnamespace
--     join pg_depend d on d.objid = v.oid
--     join pg_class t on t.oid = d.refobjid and t.relrowsecurity
--    where n.nspname = 'public' and v.relkind = 'v'
--      and has_table_privilege('anon', v.oid, 'select')
--    group by 1, 2
--    order by 1;
