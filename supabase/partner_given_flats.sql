-- A flat MovEazy gave a partner can be edited by them like their own.
--
-- Run in the Supabase SQL editor AFTER partner_schema.sql,
-- partner_referral_mapping.sql (partner_listings.mapped_by) and society_app.sql
-- (owns_listing). Safe to re-run.
--
-- "Modify details" saves the flat (partner_listing_update — already for any
-- flat that is theirs: posted by them, or given to them in partner_listings),
-- then its sharing and its owner's contact. Those two still asked "did you
-- post it?", so on a flat that came in through MovEazy (a WhatsApp message the
-- team published, a CRM upload) and was given to the partner, saving failed
-- with "You can only share your own listings." Now all three ask the same
-- question (owns_listing).
--
-- A flat MovEazy uploaded that belongs to the partner is theirs to edit in
-- full — details, photos, sharing (all partners and groups) and contacts —
-- exactly like a flat they added themself (decided 2026-11-18).

begin;

/** Who a partner's flat is shared with — replaces the whole sharing (see partner_schema.sql). */
create or replace function public.partner_set_sharing(p_property text, p_platform_pct numeric, p_groups jsonb default '[]')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid   uuid := auth.uid();
  g     jsonb;
  gid   uuid;
  pct   numeric;
begin
  if not public.is_approved_partner() then
    raise exception 'Only approved partners can share listings.' using errcode = '42501';
  end if;
  if not public.owns_listing(p_property, uid) then
    raise exception 'You can only share your own listings.' using errcode = '42501';
  end if;
  if p_platform_pct is not null and (p_platform_pct < 0 or p_platform_pct > 100) then
    raise exception 'Brokerage share must be between 0 and 100.' using errcode = '22023';
  end if;
  insert into public.partner_listings (property_id, broker_id) values (p_property, uid)
  on conflict (property_id) do update set updated_at = now();

  delete from public.partner_platform_shares where property_id = p_property;
  if p_platform_pct is not null then
    insert into public.partner_platform_shares (property_id, share_pct) values (p_property, p_platform_pct);
  end if;

  delete from public.partner_group_shares where property_id = p_property;
  for g in select * from jsonb_array_elements(coalesce(p_groups, '[]'::jsonb)) loop
    gid := (g ->> 'group_id')::uuid;
    pct := coalesce((g ->> 'pct')::numeric, 0);
    if pct < 0 or pct > 100 then
      raise exception 'Brokerage share must be between 0 and 100.' using errcode = '22023';
    end if;
    -- Sharing into a group you are not in would leak the listing to strangers.
    if not public.is_partner_group_member(gid) then
      raise exception 'You are not a member of one of those groups.' using errcode = '42501';
    end if;
    insert into public.partner_group_shares (property_id, group_id, share_pct) values (p_property, gid, pct);
  end loop;
end;
$$;

/** A partner's sharing settings for the edit screen — on any flat that is theirs. */
create or replace function public.partner_listing_sharing(p_property text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select case when public.owns_listing(p_property, auth.uid()) or public.is_crm_staff() then
    jsonb_build_object(
      'platform_pct', (select s.share_pct from public.partner_platform_shares s where s.property_id = p_property),
      'groups', coalesce((select jsonb_agg(jsonb_build_object('group_id', g.group_id, 'pct', g.share_pct))
                            from public.partner_group_shares g where g.property_id = p_property), '[]'::jsonb))
  end;
$$;

-- The owner / tenant contacts on a flat: the partner whose flat it is keeps them.
drop policy if exists "lister manages contacts" on public.partner_property_contacts;
create policy "lister manages contacts" on public.partner_property_contacts
  for all to authenticated
  using (public.owns_listing(property_id, auth.uid()))
  with check (public.owns_listing(property_id, auth.uid()) and public.is_approved_partner());

revoke all on function public.partner_set_sharing(text, numeric, jsonb) from public, anon;
grant execute on function public.partner_set_sharing(text, numeric, jsonb) to authenticated;
revoke all on function public.partner_listing_sharing(text) from public, anon;
grant execute on function public.partner_listing_sharing(text) to authenticated;

commit;
