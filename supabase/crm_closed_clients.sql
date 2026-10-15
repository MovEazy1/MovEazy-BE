-- A closed client (closed by us or elsewhere) is nobody's lead any more.
--
--   · website_lead: a closed client who still likes, opens or asks about a
--     partner's flat on the website no longer becomes that partner's lead.
--     (The MovEazy lead pool, milestone and paid leads already skip them:
--     moveazy_lead_pool in partner_moveazy_leads.sql.)
--
-- Replaces website_lead from partner_website_leads.sql — the same body with
-- the one check added. Run after it. Safe to re-run.

begin;

create or replace function public.website_lead(p_client uuid, p_property text, p_kind text, p_detail text default '')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  bid    uuid;
  c      public.crm_clients;
  h      public.inventory;
  bname  text;
  tname  text;
  flat   text;
  verb   text;
  cverb  text;
  aid    uuid;
  fresh_asg boolean := false;
  got    uuid;
  prem   boolean;
begin
  if p_kind not in ('liked', 'opened', 'visit', 'contact', 'match') then return; end if;
  select i.* into h from public.inventory i where i.property_id = p_property and i.status = 'published';
  if h.property_id is null then return; end if;
  select pl.broker_id into bid from public.partner_listings pl where pl.property_id = p_property limit 1;
  if bid is null then return; end if;
  select * into c from public.crm_clients where id = p_client;
  if c.id is null or public.normalize_mobile(coalesce(c.phone, '')) = '' then return; end if;
  if c.user_id is not null and (c.user_id = bid or not public.website_tenant_ok(c.user_id, p_property)) then return; end if;
  if coalesce(c.attributed_to, 'moveazy') <> 'moveazy' then return; end if; -- a broker's own tenant stays theirs
  if c.status in ('closed_by_us', 'closed_outside') then return; end if;   -- closed: nobody is still looking
  if coalesce(c.via, '') = 'qr' and c.via_broker = bid then return; end if;   -- from this broker's own QR poster

  select coalesce(nullif(b.name, ''), 'a partner') into bname from public.broker_partners b where b.user_id = bid;
  tname := coalesce(nullif(btrim(c.name), ''), 'A tenant');
  flat := concat_ws(' in ', nullif(h.flat_type, ''), nullif(h.area, ''));
  if flat = '' then flat := 'flat'; end if;
  verb := case p_kind when 'liked' then ' liked your ' when 'opened' then ' viewed your ' when 'visit' then ' wants to visit your '
                      when 'contact' then ' messaged about your ' else ' is looking for a flat like your ' end;
  cverb := case p_kind when 'liked' then 'Liked' when 'opened' then 'Viewed' when 'visit' then 'Wants to visit'
                       when 'contact' then 'Messaged about' else 'Matches' end;
  prem := public.partner_premium_at(bid);

  if prem then
    select id into aid from public.partner_lead_assignments where client_id = c.id and broker_id = bid;
    if aid is null then
      insert into public.partner_lead_assignments (request_id, client_id, broker_id, assigned_by)
      values (public.website_request_for(bid), c.id, bid, 'website')
      returning id into aid;
      fresh_asg := true;
    end if;
    insert into public.partner_website_interest as w (broker_id, client_id, assignment_id, property_id, kind, detail)
    values (bid, c.id, aid, p_property, p_kind, left(coalesce(p_detail, ''), 200))
    on conflict (broker_id, client_id, property_id, kind) do update
      set assignment_id = excluded.assignment_id, held = false, created_at = now()
      where w.held
    returning w.id into got;
    if got is null then return; end if; -- already told about this flat and kind
    insert into public.partner_notifications (broker_id, kind, title, body, link)
    values (bid, 'website_lead',
            case when fresh_asg then 'New lead: ' else '' end || tname || verb || flat,
            concat_ws(' · ', case when h.rent > 0 then '₹' || to_char(h.rent, 'FM99,99,99,999') || '/month' end,
                      nullif(p_detail, ''), 'from the MovEazy website — call them now'),
            '/tenants/asg-' || aid);
    insert into public.crm_activities (client_id, actor_email, type, body, meta)
    values (c.id, 'system', 'system',
            cverb || ' ' || bname || '''s ' || flat || ' (' || p_property || ')'
              || case when nullif(p_detail, '') is not null then ' · ' || p_detail else '' end
              || case when fresh_asg then ' — shared with ' || bname || ' as a website lead' else ' — sent to ' || bname end,
            jsonb_build_object('broker_id', bid, 'assignment_id', aid, 'property_id', p_property, 'kind', p_kind, 'via', 'website'));
  else
    insert into public.partner_website_interest (broker_id, client_id, property_id, kind, held, detail)
    values (bid, c.id, p_property, p_kind, true, left(coalesce(p_detail, ''), 200))
    on conflict (broker_id, client_id, property_id, kind) do nothing
    returning id into got;
    if got is null then return; end if;
    -- One teaser per tenant and flat, whatever they did.
    if (select count(*) from public.partner_website_interest
         where broker_id = bid and client_id = c.id and property_id = p_property) = 1 then
      insert into public.partner_notifications (broker_id, kind, title, body, link)
      values (bid, 'website_teaser', 'A tenant is interested in your ' || flat,
              'Go Premium (or start your free trial) within 7 days to see who it is and call them.', '/premium');
    end if;
    insert into public.crm_activities (client_id, actor_email, type, body, meta)
    values (c.id, 'system', 'system',
            cverb || ' ' || bname || '''s ' || flat || ' (' || p_property || ') — '
              || bname || ' is on the free plan: kept 7 days for an upgrade',
            jsonb_build_object('broker_id', bid, 'property_id', p_property, 'kind', p_kind, 'via', 'website', 'held', true));
  end if;
exception when others then
  -- Telling the broker must never stop the tenant's own action.
  raise warning 'website_lead(%, %): %', p_client, p_property, sqlerrm;
end;
$$;

revoke all on function public.website_lead(uuid, text, text, text) from public, anon, authenticated;

commit;
