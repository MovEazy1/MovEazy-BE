-- The AI matcher's shortlist, in the partner's hands (pages/partners/Shortlist.jsx).
--
--   · Remove a flat from a tenant's shortlist — before it's sent, or from a
--     sent list where the tenant hasn't swiped it yet. A removed flat is never
--     suggested to that tenant again (partner_matcher_removed, folded into
--     partner_matcher_seen).
--   · Add flats to a sent list (the AI's backups, or any match): the tenant's
--     link shows them next time it opens. The partner tells them on WhatsApp.
--   · Mark sold: the partner's own flat is let out; anyone else's (or
--     MovEazy's) is flagged "potentially rented" for everyone until its lister
--     or MovEazy confirms — now for free partners too.
--
-- Replaces partner_matcher_seen (partner_matcher_history.sql) and
-- partner_mark_sold_out (partner_launch.sql): run this after both.
-- Safe to re-run.

begin;

create table if not exists public.partner_matcher_removed (
  broker_id   uuid not null references auth.users (id) on delete cascade,
  tenant_key  text not null check (tenant_key ~ '^(lead|asg):[0-9a-f-]{36}$'),
  property_id text not null,
  reason      text not null default 'removed' check (reason in ('removed', 'sold')),
  at          timestamptz not null default now(),
  primary key (broker_id, tenant_key, property_id)
);
alter table public.partner_matcher_removed enable row level security;
revoke all on public.partner_matcher_removed from public, anon, authenticated;
drop policy if exists "staff read" on public.partner_matcher_removed;
create policy "staff read" on public.partner_matcher_removed for select to authenticated using (public.is_crm_staff());
grant select on public.partner_matcher_removed to authenticated;

/** "lead:<id>" or "asg:<id>" — when the tenant is the caller's (own client, or an open MovEazy assignment). */
create or replace function public.partner_tenant_key(p_lead uuid, p_assignment uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if num_nonnulls(p_lead, p_assignment) <> 1 then
    raise exception 'Pick one tenant.' using errcode = '22023';
  end if;
  if p_lead is not null then
    if not exists (select 1 from public.partner_leads where id = p_lead and broker_id = auth.uid()) then
      raise exception 'That lead is not yours.' using errcode = '42501';
    end if;
    return 'lead:' || p_lead::text;
  end if;
  perform public.partner_my_open_assignment(p_assignment);
  return 'asg:' || p_assignment::text;
end;
$$;

/** Take a flat off a tenant's shortlist for good (or put it back: p_undo). */
create or replace function public.partner_matcher_exclude(p_lead uuid, p_assignment uuid, p_property text, p_undo boolean default false)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  k text;
begin
  if not public.is_approved_partner() then
    raise exception 'Only MovEazy partners can change shortlists.' using errcode = '42501';
  end if;
  k := public.partner_tenant_key(p_lead, p_assignment);
  if coalesce(p_property, '') = '' then raise exception 'Pick a flat.' using errcode = '22023'; end if;
  if p_undo then
    delete from public.partner_matcher_removed where broker_id = auth.uid() and tenant_key = k and property_id = p_property;
  else
    insert into public.partner_matcher_removed (broker_id, tenant_key, property_id)
    values (auth.uid(), k, p_property)
    on conflict (broker_id, tenant_key, property_id) do update set at = now();
  end if;
  return true;
end;
$$;

/**
 * Change a sent list: take out flats the tenant hasn't swiped, add new ones.
 * Taken-out flats are never suggested to them again. The tenant's link shows
 * the new flats next time it opens.
 */
create or replace function public.partner_curated_edit(p_list uuid, p_remove text[] default '{}', p_add text[] default '{}')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  l    public.partner_curated_lists;
  rem  text[];
  adds text[];
  ids  text[];
  k    text;
  cid  uuid;
  swiped text;
begin
  if not public.is_approved_partner() then
    raise exception 'Only MovEazy partners can change lists.' using errcode = '42501';
  end if;
  select * into l from public.partner_curated_lists where id = p_list and broker_id = auth.uid();
  if l.id is null then raise exception 'That list is not yours.' using errcode = '42501'; end if;
  if l.lead_id is null and l.assignment_id is null then raise exception 'This list has no tenant to update.' using errcode = '22023'; end if;
  k := case when l.lead_id is not null then 'lead:' || l.lead_id::text else 'asg:' || l.assignment_id::text end;
  if l.assignment_id is not null then cid := public.partner_my_open_assignment(l.assignment_id); end if;

  select coalesce(array_agg(distinct p), '{}') into rem from unnest(coalesce(p_remove, '{}')) p where p = any (l.property_ids);
  select coalesce(array_agg(distinct p), '{}') into adds from unnest(coalesce(p_add, '{}')) p
   where coalesce(p, '') <> '' and not (p = any (l.property_ids));

  select a.property_id into swiped from public.partner_curated_actions a where a.list_id = l.id and a.property_id = any (rem) limit 1;
  if swiped is not null then
    raise exception 'They''ve already swiped % — it stays on their list. Mark it sold if it''s gone.', swiped using errcode = '22023';
  end if;
  if cardinality(adds) > 0 then
    if exists (select unnest(adds) except select property_id from public.partner_inventory()) then
      raise exception 'One of those homes is not in your inventory.' using errcode = '42501';
    end if;
    if l.lead_id is not null and not public.partner_has_tier('moveazy_inventory')
       and exists (select 1 from public.partner_inventory() i where i.property_id = any (adds) and i.source not in ('mine', 'moveazy')) then
      raise exception 'Other brokers'' flats come with Premium — add your own flats and MovEazy''s.' using errcode = '42501';
    end if;
  end if;

  ids := array(select p from unnest(l.property_ids) with ordinality t(p, o) where not (p = any (rem)) order by o) || adds;
  if cardinality(ids) = 0 then raise exception 'A list needs at least one home.' using errcode = '22023'; end if;
  if cardinality(ids) > 30 then raise exception 'A list holds up to 30 homes.' using errcode = '22023'; end if;
  if cardinality(rem) = 0 and cardinality(adds) = 0 then
    return jsonb_build_object('id', l.id, 'token', l.token, 'count', cardinality(l.property_ids), 'added', 0, 'removed', 0);
  end if;

  update public.partner_curated_lists set property_ids = ids where id = l.id;
  insert into public.partner_matcher_removed (broker_id, tenant_key, property_id)
  select auth.uid(), k, p from unnest(rem) p
  on conflict (broker_id, tenant_key, property_id) do update set at = now();

  if cid is not null then
    insert into public.crm_activities (client_id, actor_email, type, body, meta)
    values (cid, coalesce(nullif(auth.jwt() ->> 'email', ''), 'partner'), 'partner',
            public.partner_display_name(auth.uid()) || ' updated their list'
              || case when cardinality(adds) > 0 then ': added ' || array_to_string(adds, ', ') else '' end
              || case when cardinality(rem) > 0 then case when cardinality(adds) > 0 then '; ' else ': ' end || 'took out ' || array_to_string(rem, ', ') else '' end,
            jsonb_build_object('source', 'partner_list_edit', 'broker_id', auth.uid(), 'list_id', l.id, 'added', to_jsonb(adds), 'removed', to_jsonb(rem)));
  end if;
  return jsonb_build_object('id', l.id, 'token', l.token, 'count', cardinality(ids), 'added', cardinality(adds), 'removed', cardinality(rem));
end;
$$;

-- ── Sold ─────────────────────────────────────────────────────────────────────
/**
 * A partner who sees a listing through a group, the network or MovEazy says
 * it's gone. The listing turns "potentially rented"; its broker is notified;
 * MovEazy sees it in the CRM. Any approved partner (it used to be Premium only).
 */
create or replace function public.partner_mark_sold_out(p_property text, p_note text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  lister uuid;
  h      public.inventory;
  who    text;
  req    public.partner_soldout_requests;
begin
  if not public.is_approved_partner() then
    raise exception 'Only MovEazy partners can mark a flat sold.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.partner_inventory() v where v.property_id = p_property and v.source <> 'mine') then
    raise exception 'You can mark sold out only a listing shared with you.' using errcode = '42501';
  end if;
  select * into h from public.inventory where property_id = p_property;
  if h.status <> 'published' then raise exception 'That listing is already off the market.' using errcode = '22023'; end if;
  select broker_id into lister from public.partner_listings where property_id = p_property;
  select name into who from public.broker_partners where user_id = auth.uid();

  insert into public.partner_soldout_requests (property_id, requested_by, note)
  values (p_property, auth.uid(), left(coalesce(p_note, ''), 300))
  on conflict (property_id) where status = 'pending' do nothing
  returning * into req;
  if req.id is null then
    return jsonb_build_object('ok', true, 'already', true);
  end if;
  update public.inventory set rent_flag = 'potentially_rented' where property_id = p_property;
  if lister is not null then
    insert into public.partner_notifications (broker_id, kind, title, body, link)
    values (lister, 'sold_out_request', coalesce(nullif(who, ''), 'A broker') || ' says your listing is rented',
            concat_ws(' · ', nullif(h.flat_type, ''), nullif(h.area, ''), p_property) || '. Confirm to mark it sold out.',
            '/property/' || p_property);
  end if;
  return jsonb_build_object('ok', true, 'request', req.id);
end;
$$;

/** Mark sold from the shortlist: their own flat is let out; anyone else's is flagged. */
create or replace function public.partner_mark_sold(p_property text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_approved_partner() then
    raise exception 'Only MovEazy partners can mark a flat sold.' using errcode = '42501';
  end if;
  if exists (select 1 from public.partner_listings pl where pl.property_id = p_property and pl.broker_id = auth.uid()) then
    update public.inventory set status = 'rented', updated_at = now() where property_id = p_property and status <> 'rented';
    return jsonb_build_object('ok', true, 'kind', 'let_out');
  end if;
  return public.partner_mark_sold_out(p_property, 'From the AI matcher') || jsonb_build_object('kind', 'flagged');
end;
$$;

-- ── Never again: removed flats join the matcher's memory ─────────────────────
create or replace function public.partner_matcher_seen()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  me  uuid := auth.uid();
  out jsonb := '{}'::jsonb;
  t   record;
begin
  if not public.is_approved_partner() then
    raise exception 'Only MovEazy partners can see this.' using errcode = '42501';
  end if;
  for t in
    select 'lead:' || l.id::text as k, l.id as lead_id, null::uuid as asg_id, public.normalize_mobile(l.phone) as ph
      from public.partner_leads l where l.broker_id = me and l.status <> 'closed'
    union all
    select 'asg:' || a.id::text, null::uuid, a.id, public.normalize_mobile(c.phone)
      from public.partner_lead_assignments a join public.crm_clients c on c.id = a.client_id
     where a.broker_id = me and a.status not in ('closed', 'not_interested')
  loop
    out := out || jsonb_build_object(t.k, coalesce((
      select jsonb_agg(distinct q.p order by q.p) from (
        -- everything this broker already sent them
        select unnest(cl.property_ids) as p from public.partner_curated_lists cl
         where cl.broker_id = me
           and ((t.lead_id is not null and cl.lead_id = t.lead_id) or (t.asg_id is not null and cl.assignment_id = t.asg_id))
        union
        -- what this broker took off their shortlist
        select r.property_id from public.partner_matcher_removed r where r.broker_id = me and r.tenant_key = t.k
        union
        -- what the same mobile liked or skipped on any partner's list
        select a.property_id from public.partner_curated_actions a
          join public.partner_curated_lists cl on cl.id = a.list_id
          left join public.partner_tenants pt on pt.id = cl.tenant_id
          left join public.partner_lead_assignments pa on pa.id = cl.assignment_id
          left join public.crm_clients cc on cc.id = pa.client_id
         where t.ph <> '' and coalesce(pt.phone, public.normalize_mobile(cc.phone)) = t.ph
        union
        -- MovEazy: what they turned down, and what MovEazy passed on for them
        select s.property_id from public.crm_shortlists s join public.crm_clients c on c.id = s.client_id
         where t.ph <> '' and public.normalize_mobile(c.phone) = t.ph and s.status in ('disliked', 'rejected')
        union
        select x.property_id from public.crm_client_passes x join public.crm_clients c on c.id = x.client_id
         where t.ph <> '' and public.normalize_mobile(c.phone) = t.ph
        union
        select r.property_id from public.listing_reactions r
         where t.ph <> '' and r.reaction = 'dislike'
           and r.user_id in (select c.user_id from public.crm_clients c where c.user_id is not null and public.normalize_mobile(c.phone) = t.ph
                             union select p.id from public.user_profiles p where public.normalize_mobile(p.phone) = t.ph)
      ) q), '[]'::jsonb));
  end loop;
  return out;
end;
$$;

revoke all on function public.partner_tenant_key(uuid, uuid) from public, anon, authenticated;
revoke all on function public.partner_matcher_exclude(uuid, uuid, text, boolean) from public, anon;
revoke all on function public.partner_curated_edit(uuid, text[], text[]) from public, anon;
revoke all on function public.partner_mark_sold_out(text, text) from public, anon;
revoke all on function public.partner_mark_sold(text) from public, anon;
revoke all on function public.partner_matcher_seen() from public, anon;
grant execute on function public.partner_matcher_exclude(uuid, uuid, text, boolean) to authenticated;
grant execute on function public.partner_curated_edit(uuid, text[], text[]) to authenticated;
grant execute on function public.partner_mark_sold_out(text, text) to authenticated;
grant execute on function public.partner_mark_sold(text) to authenticated;
grant execute on function public.partner_matcher_seen() to authenticated;

commit;
