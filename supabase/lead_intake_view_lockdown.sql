-- URGENT: close public read access to the lead views.
--
-- crm_lead_intake and crm_direct_property_leads were readable with the anon
-- key — the one that ships inside the browser bundle and is therefore public.
-- Anyone could list every lead's name, phone number and, worst of all,
-- lead_key.
--
-- lead_key is not an identifier, it is a credential: get_lead_intake takes it
-- alone and returns that person's answers. Publishing it handed out the keys,
-- not just the data behind them.
--
-- Two separate mistakes, either of which alone was enough:
--
--   1. A view is owned by the role that created it and, without
--      security_invoker, runs with that owner's rights — so it read straight
--      past the row-level policy on lead_intake that was doing its job
--      correctly underneath. The base table refused anon; the view did not.
--
--   2. Supabase grants SELECT on everything in `public` to anon and
--      authenticated by default. A view added to that schema is exposed
--      through PostgREST the moment it exists, without anything saying so.
--
-- Fixed here in that order, plus dropping lead_key from the views entirely —
-- the CRM never needed it, and a credential should not be sitting in a
-- reporting view at all. crm_client_id is the link that belongs there.

begin;

-- 1. Shut the door first, before anything else, so the window closes even if
--    a later statement in this file fails.
revoke all on public.crm_lead_intake from anon, authenticated;
revoke all on public.crm_direct_property_leads from anon, authenticated;

-- 2. Rebuild both without lead_key.
drop view if exists public.crm_lead_intake;
drop view if exists public.crm_direct_property_leads;

create view public.crm_lead_intake
  -- Runs as whoever queries it, so the staff-only policy on lead_intake
  -- applies to the view as well. Without this a view is a hole straight
  -- through row-level security.
  with (security_invoker = true)
as
  select l.name, l.phone, l.prefs, l.step, l.completed,
         l.lead_type, l.property_id,
         l.utm ->> 'source' as utm_source,
         l.crm_client_id, l.claimed_by, l.created_at, l.updated_at
  from public.lead_intake l
  where l.phone <> ''
  order by l.updated_at desc;

create view public.crm_direct_property_leads
  with (security_invoker = true)
as
  select l.name, l.phone, l.property_id,
         l.utm ->> 'source' as utm_source,
         l.crm_client_id, l.claimed_by, l.created_at, l.updated_at
  from public.lead_intake l
  where l.lead_type = 'direct_property' and l.phone <> ''
  order by l.updated_at desc;

-- 3. Staff only, and only through their own session. anon is never granted:
--    a signed-out visitor has no business reading anybody's lead, including
--    their own — that is what get_lead_intake and the lead_key are for.
grant select on public.crm_lead_intake to authenticated;
grant select on public.crm_direct_property_leads to authenticated;

commit;


-- ── Verify ───────────────────────────────────────────────────────────────────
-- Both should come back false. If either is true the door is still open.
--
--   select has_table_privilege('anon', 'public.crm_lead_intake', 'select')
--       as anon_can_read_leads,
--          has_table_privilege('anon', 'public.crm_direct_property_leads', 'select')
--       as anon_can_read_direct;
--
-- And no view in public should be readable by anon while reading a table that
-- has row-level security on it:
--
--   select c.relname, c.relrowsecurity
--     from pg_class c join pg_namespace n on n.oid = c.relnamespace
--    where n.nspname = 'public' and c.relkind = 'v'
--      and has_table_privilege('anon', c.oid, 'select');
