-- A tenant's requirement is theirs: only they and the CRM staff read it.
--
-- "authenticated read requirements for matching" let every signed-in
-- account read every row — email, WhatsApp, age and office included — so
-- List my Flat could show a poster who their new flat suits. That screen
-- shows seekers anonymously ("Seeker #3F9A1C") and needs none of the contact
-- details, so it now calls requirements_for_matching(): the fields matching
-- reads (lib/inventoryMatch.js) and a short handle, nothing that identifies
-- anyone.
--
-- Unchanged: a tenant reads and writes their own row ("users manage own
-- requirement"); functions that read the table (lead intake, partner leads)
-- run as its owner. Safe to re-run.

begin;

drop policy if exists "authenticated read requirements for matching" on public.user_requirements;

drop policy if exists "crm staff read requirements" on public.user_requirements;
create policy "crm staff read requirements"
  on public.user_requirements for select
  to authenticated
  using (public.is_crm_staff());

/** What matching a new flat needs from every seeker: preferences and a handle, no contact. */
create or replace function public.requirements_for_matching(p_limit int default 1000)
returns table (
  handle text, localities text[], budget_min numeric, budget_max numeric, flat_types text[],
  must_haves text[], deal_breakers text[], occupants text[]
)
language sql
stable
security definer
set search_path = public
as $$
  select upper(left(replace(r.user_id::text, '-', ''), 6)),
         r.localities::text[], r.budget_min::numeric, r.budget_max::numeric, r.flat_types::text[],
         r.must_haves::text[], r.deal_breakers::text[], r.occupants::text[]
    from public.user_requirements r
   where auth.uid() is not null
   order by r.updated_at desc nulls last
   limit least(greatest(coalesce(p_limit, 1000), 1), 1000);
$$;
revoke all on function public.requirements_for_matching(int) from public, anon;
grant execute on function public.requirements_for_matching(int) to authenticated;

commit;
