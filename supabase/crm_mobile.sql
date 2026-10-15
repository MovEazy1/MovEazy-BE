-- The CRM on a phone (MovEazy-FE pages/crm/mobile): what its Home,
-- Payments, Notifications and Partner usage tabs read. Read-only, CRM staff
-- only; "today" is the day in India.
--
--   crm_mobile_summary()        Home's numbers: today, partner activity, waiting on us
--   crm_liked_no_visit(days)    tenants who liked a flat (website heart, a MovEazy
--                               list, a partner's list) with no visit asked or fixed
--   crm_leads_not_called()      MovEazy leads nobody has contacted after 24 hours,
--                               and partners' MovEazy leads they haven't called
--   crm_visits_today()          MovEazy visits and partners' visits today
--   crm_payments_flow()         every partner: signed up → tapped Pay → UTR sent →
--                               on trial / Premium, and the ₹2,000 lead pack the same way
--   crm_partner_usage(broker)   null: one row per partner with their numbers;
--                               a partner: their flats, MovEazy leads and own leads
--
-- Safe to re-run.

begin;

create or replace function public.crm_today()
returns date
language sql
stable
as $$ select (now() at time zone 'Asia/Kolkata')::date $$;

-- ── Liked a flat, no visit ──────────────────────────────────────────────────
create or replace function public.crm_liked_no_visit(p_days int default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  since timestamptz := now() - make_interval(days => greatest(1, least(coalesce(p_days, 30), 365)));
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.liked_at desc)
      from (
        select distinct on (l.who, l.property_id)
               l.who, l.user_id, l.client_id, l.lead_id, l.property_id, l.liked_at, l.via, l.via_broker,
               coalesce(nullif(l.name, ''), nullif(c.name, ''), nullif(up.name, ''), 'A tenant') as name,
               coalesce(nullif(l.phone, ''), nullif(c.phone, ''), nullif(up.phone, ''), '') as phone,
               coalesce(c.id, l.client_id) as crm_client_id,
               vb.name as via_broker_name,
               i.title, i.area, i.rent, i.flat_type, i.cover_image_url, i.status as flat_status,
               pl.broker_id as flat_broker, fb.name as flat_broker_name
          from (
            -- A heart on the website, or a like on a list we sent by link.
            select 'u:' || r.user_id as who, r.user_id, null::uuid as client_id, null::uuid as lead_id, r.property_id,
                   r.updated_at as liked_at, case when r.source = 'curated_link' then 'moveazy_list' else 'website' end as via,
                   null::uuid as via_broker, '' as name, '' as phone
              from public.listing_reactions r
             where r.reaction = 'like' and r.updated_at >= since
            union all
            -- A like on a MovEazy curated list.
            select coalesce('u:' || cc.user_id, 'c:' || s.client_id), cc.user_id, s.client_id, null, s.property_id,
                   coalesce(s.reacted_at, s.shared_at, s.created_at), 'moveazy_list', null, '', ''
              from public.crm_shortlists s
              join public.crm_clients cc on cc.id = s.client_id
             where s.status = 'liked' and coalesce(s.reacted_at, s.shared_at, s.created_at) >= since
            union all
            -- A like on a partner's curated list: their tenant, maybe never signed in.
            select coalesce('u:' || pc.tenant_id, 'l:' || pc.lead_id, 'k:' || pc.id), pc.tenant_id, null, pc.lead_id, a.property_id,
                   a.at, 'partner_list', pc.broker_id, coalesce(nullif(pc.lead_name, ''), pld.name, ''), coalesce(pld.phone, '')
              from public.partner_curated_actions a
              join public.partner_curated_lists pc on pc.id = a.list_id
              left join public.partner_leads pld on pld.id = pc.lead_id
             where a.action = 'liked' and a.at >= since
          ) l
          left join public.crm_clients c on l.user_id is not null and c.user_id = l.user_id
          left join public.user_profiles up on up.id = l.user_id
          left join public.broker_partners vb on vb.user_id = l.via_broker
          join public.inventory i on i.property_id = l.property_id
          left join public.partner_listings pl on pl.property_id = l.property_id
          left join public.broker_partners fb on fb.user_id = pl.broker_id
         where coalesce(i.status, '') not in ('rented', 'paused')
           -- not staff or a partner liking flats themselves
           and (l.user_id is null or not exists (select 1 from public.broker_partners b where b.user_id = l.user_id))
           -- nor a client we've closed (closed by us or elsewhere)
           and coalesce(c.status, '') not in ('closed_by_us', 'closed_outside')
           and not exists (select 1 from public.crm_clients cx where cx.id = l.client_id and cx.status in ('closed_by_us', 'closed_outside'))
           -- no visit asked for or fixed, by anyone
           and not exists (select 1 from public.visit_bookings v
                            where v.user_id = l.user_id and v.property_id = l.property_id and coalesce(v.status, '') <> 'cancelled')
           and not exists (select 1 from public.crm_shortlists s2 join public.crm_clients c2 on c2.id = s2.client_id
                            where s2.property_id = l.property_id and s2.status = 'visit_scheduled'
                              and (c2.id = l.client_id or (l.user_id is not null and c2.user_id = l.user_id)))
           and not exists (select 1 from public.partner_visits pv
                            where pv.property_id = l.property_id and pv.status = 'fixed'
                              and (pv.lead_id = l.lead_id
                                   or pv.assignment_id in (select pa.id from public.partner_lead_assignments pa
                                                            join public.crm_clients c3 on c3.id = pa.client_id
                                                           where l.user_id is not null and c3.user_id = l.user_id)))
           and not exists (select 1 from public.partner_storefront_visits sv
                            where sv.property_id = l.property_id and l.user_id is not null and sv.user_id = l.user_id)
         order by l.who, l.property_id, l.liked_at desc
      ) x
  ), '[]'::jsonb);
end;
$$;

-- ── Leads nobody has called ─────────────────────────────────────────────────
create or replace function public.crm_leads_not_called()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  return jsonb_build_object(
    -- Ours: a number, 1–30 days old, no call/WhatsApp/status/shortlist from the team.
    'moveazy', coalesce((
      select jsonb_agg(jsonb_build_object('client_id', c.id, 'name', c.name, 'phone', c.phone, 'source', c.source,
                                          'via', c.via, 'created_at', c.created_at, 'status', c.status)
                       order by c.created_at desc)
        from public.crm_clients c
       where coalesce(c.phone, '') <> '' and c.attributed_to = 'moveazy'
         and c.status not in ('closed_by_us', 'closed_outside')
         and c.created_at < now() - interval '24 hours' and c.created_at > now() - interval '30 days'
         and not exists (select 1 from public.crm_activities a
                          where a.client_id = c.id and coalesce(a.actor_email, '') <> ''
                            and a.type in ('whatsapp', 'call', 'shortlist', 'status', 'contacted'))
         and not exists (select 1 from public.crm_shortlists s where s.client_id = c.id and s.shared_at is not null)
    ), '[]'::jsonb),
    -- Partners': a MovEazy lead given to them 24 hours ago, never called or messaged.
    'partners', coalesce((
      select jsonb_agg(jsonb_build_object('assignment_id', a.id, 'client_id', a.client_id, 'name', c.name, 'phone', c.phone,
                                          'broker_id', a.broker_id, 'broker_name', b.name, 'broker_phone', b.phone,
                                          'pack', q.pack, 'assigned_at', a.assigned_at)
                       order by a.assigned_at desc)
        from public.partner_lead_assignments a
        join public.crm_clients c on c.id = a.client_id
        join public.partner_lead_requests q on q.id = a.request_id
        left join public.broker_partners b on b.user_id = a.broker_id
       where a.status = 'assigned' and a.assigned_at < now() - interval '24 hours'
         and c.status not in ('closed_by_us', 'closed_outside')
         and not exists (select 1 from public.partner_lead_reachouts x where x.assignment_id = a.id)
    ), '[]'::jsonb)
  );
end;
$$;

-- ── Visits today ────────────────────────────────────────────────────────────
create or replace function public.crm_visits_today()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  d date := public.crm_today();
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'moveazy', coalesce((
      select jsonb_agg(jsonb_build_object('id', v.id, 'slot_at', v.slot_at, 'status', v.status, 'property_id', v.property_id,
                                          'title', i.title, 'area', i.area, 'rent', i.rent,
                                          'name', coalesce(nullif(c.name, ''), nullif(up.name, ''), 'A tenant'),
                                          'phone', coalesce(nullif(c.phone, ''), nullif(up.phone, ''), ''), 'client_id', c.id)
                       order by v.slot_at)
        from public.visit_bookings v
        left join public.inventory i on i.property_id = v.property_id
        left join public.crm_clients c on c.user_id = v.user_id
        left join public.user_profiles up on up.id = v.user_id
       where v.slot_at is not null and (v.slot_at at time zone 'Asia/Kolkata')::date = d
         and coalesce(v.status, '') not in ('cancelled')
    ), '[]'::jsonb),
    'partners', coalesce((
      select jsonb_agg(jsonb_build_object('id', pv.id, 'visit_at', pv.visit_at, 'property_id', pv.property_id,
                                          'title', i.title, 'area', i.area, 'rent', i.rent,
                                          'broker_id', pv.broker_id, 'broker_name', b.name, 'broker_phone', b.phone,
                                          'name', coalesce(pl.name, c.name, 'A tenant'), 'moveazy_lead', pv.assignment_id is not null)
                       order by pv.visit_at)
        from public.partner_visits pv
        left join public.inventory i on i.property_id = pv.property_id
        left join public.broker_partners b on b.user_id = pv.broker_id
        left join public.partner_leads pl on pl.id = pv.lead_id
        left join public.partner_lead_assignments pa on pa.id = pv.assignment_id
        left join public.crm_clients c on c.id = pa.client_id
       where pv.status = 'fixed' and (pv.visit_at at time zone 'Asia/Kolkata')::date = d
    ), '[]'::jsonb)
  );
end;
$$;

-- ── Home's numbers ──────────────────────────────────────────────────────────
create or replace function public.crm_mobile_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  d      date := public.crm_today();
  liked  jsonb;
  quiet  jsonb;
  visits jsonb;
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  liked  := public.crm_liked_no_visit(30);
  quiet  := public.crm_leads_not_called();
  visits := public.crm_visits_today();
  return jsonb_build_object(
    'today', jsonb_build_object(
      'new_leads', (select count(*) from public.crm_clients c
                     where c.attributed_to = 'moveazy' and (c.created_at at time zone 'Asia/Kolkata')::date = d),
      'visits_moveazy', jsonb_array_length(visits -> 'moveazy'),
      'visits_partner', jsonb_array_length(visits -> 'partners'),
      'qr_scans', (select count(*) from public.partner_qr_checkins q where q.day = d),
      'new_flats', (select count(*) from public.inventory i where (i.created_at at time zone 'Asia/Kolkata')::date = d)
    ),
    'partners', jsonb_build_object(
      'active_today', (select count(distinct x.user_id) from (
                         select s.user_id from public.user_sessions s
                          where s.app = 'partner' and s.user_id is not null and (s.started_at at time zone 'Asia/Kolkata')::date = d
                         union
                         select e.user_id from public.app_events e
                          where e.app = 'partner' and e.user_id is not null and (e.at at time zone 'Asia/Kolkata')::date = d) x),
      'signed_up', (select count(*) from public.broker_partners),
      'signed_up_today', (select count(*) from public.broker_partners b where (b.created_at at time zone 'Asia/Kolkata')::date = d),
      'on_trial', (select count(distinct e.user_id) from public.partner_entitlements e
                    where e.tier = 'moveazy_inventory' and now() >= e.starts_at and now() < e.ends_at and e.source = 'trial'),
      'on_premium', (select count(distinct e.user_id) from public.partner_entitlements e
                      where e.tier = 'moveazy_inventory' and now() >= e.starts_at and now() < e.ends_at
                        and coalesce(e.source, '') <> 'trial'),
      'flats_today', (select count(*) from public.partner_listings pl join public.inventory i on i.property_id = pl.property_id
                       where (pl.created_at at time zone 'Asia/Kolkata')::date = d and not public.inventory_from_crm(i.source)),
      'milestone_leads_today', (select count(*) from public.partner_lead_assignments a
                                  join public.partner_lead_requests q on q.id = a.request_id
                                 where q.pack = 'milestone' and (a.assigned_at at time zone 'Asia/Kolkata')::date = d)
    ),
    'waiting', jsonb_build_object(
      'slots_required', (select count(*) from public.visit_bookings v
                          where v.slot_at is null and coalesce(v.status, '') not in ('cancelled', 'done')),
      'payments_to_check', (select count(*) from public.partner_payments p where p.status = 'payment_check')
                         + (select count(*) from public.partner_lead_requests q where q.status = 'payment_check'),
      'lead_requests', (select count(*) from public.partner_lead_requests q
                         where q.status in ('needs_approval', 'open') and q.pack in ('free10', 'paid30', 'premium')),
      'messages', (select count(*) from public.site_contact_messages m where m.status = 'new'),
      'liked_no_visit', jsonb_array_length(liked),
      'not_called_moveazy', jsonb_array_length(quiet -> 'moveazy'),
      'not_called_partner', jsonb_array_length(quiet -> 'partners'),
      'tapped_not_paid', (select count(distinct p.user_id) from public.partner_payments p
                           where p.status = 'started' and p.created_at > now() - interval '30 days'
                             and not exists (select 1 from public.partner_payments p2
                                              where p2.user_id = p.user_id and p2.created_at >= p.created_at
                                                and p2.status in ('payment_check', 'paid', 'approved')))
    ),
    'at', now()
  );
end;
$$;

-- ── Payments: every partner's way to paying ─────────────────────────────────
create or replace function public.crm_payments_flow()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.created_at desc)
      from (
        select b.user_id, b.name, b.phone, b.agency, b.status, b.created_at,
               pe.source as plan_source, pe.plan as plan_name, pe.ends_at as plan_until,
               coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'plan_id', p.plan_id, 'amount', p.amount, 'status', p.status,
                                                             'utr', p.utr, 'created_at', p.created_at, 'paid_at', p.paid_at)
                                          order by p.created_at desc)
                           from public.partner_payments p where p.user_id = b.user_id), '[]'::jsonb) as premium,
               coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'amount', q.amount, 'status', q.status, 'utr', q.utr,
                                                             'lead_count', q.lead_count, 'created_at', q.created_at)
                                          order by q.created_at desc)
                           from public.partner_lead_requests q where q.broker_id = b.user_id and q.pack = 'paid30'), '[]'::jsonb) as lead_pack
          from public.broker_partners b
          left join lateral (
            select e.source, e.plan, e.ends_at from public.partner_entitlements e
             where e.user_id = b.user_id and e.tier = 'moveazy_inventory' and now() >= e.starts_at and now() < e.ends_at
             order by (coalesce(e.source, '') <> 'trial') desc, e.ends_at desc limit 1
          ) pe on true
      ) x
  ), '[]'::jsonb);
end;
$$;

-- ── Partner usage ───────────────────────────────────────────────────────────
create or replace function public.crm_partner_usage(p_broker uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  d date := public.crm_today();
begin
  if not public.is_crm_staff() then raise exception 'CRM staff only.' using errcode = '42501'; end if;
  if p_broker is null then
    return coalesce((
      select jsonb_agg(to_jsonb(x) order by x.last_seen desc nulls last, x.created_at desc)
        from (
          select b.user_id, b.name, b.phone, b.agency, b.status, b.created_at,
                 pe.source as plan_source, pe.ends_at as plan_until,
                 greatest(s.last_end, ev.last_at) as last_seen,
                 coalesce(s.sessions, 0) as sessions, coalesce(s.seconds, 0) as seconds,
                 coalesce(s.seconds_today, 0) as seconds_today, coalesce(s.seconds_7d, 0) as seconds_7d,
                 coalesce(ev.clicks, 0) as clicks,
                 f.flats, f.flats_complete, f.flats_today,
                 (select count(*) from public.partner_lead_assignments a where a.broker_id = b.user_id) as moveazy_leads,
                 (select count(*) from public.partner_lead_assignments a where a.broker_id = b.user_id and a.status = 'assigned'
                     and not exists (select 1 from public.partner_lead_reachouts r where r.assignment_id = a.id)) as moveazy_untouched,
                 (select count(*) from public.partner_leads l where l.broker_id = b.user_id) as own_leads
            from public.broker_partners b
            left join lateral (
              select e.source, e.ends_at from public.partner_entitlements e
               where e.user_id = b.user_id and e.tier = 'moveazy_inventory' and now() >= e.starts_at and now() < e.ends_at
               order by (coalesce(e.source, '') <> 'trial') desc, e.ends_at desc limit 1
            ) pe on true
            left join lateral (
              select count(*)::int as sessions, coalesce(sum(us.duration_seconds), 0)::int as seconds,
                     max(coalesce(us.ended_at, us.started_at)) as last_end,
                     coalesce(sum(us.duration_seconds) filter (where (us.started_at at time zone 'Asia/Kolkata')::date = d), 0)::int as seconds_today,
                     coalesce(sum(us.duration_seconds) filter (where us.started_at > now() - interval '7 days'), 0)::int as seconds_7d
                from public.user_sessions us where us.user_id = b.user_id and us.app = 'partner'
            ) s on true
            left join lateral (
              select (count(*) filter (where ae.kind = 'click'))::int as clicks, max(ae.at) as last_at
                from public.app_events ae where ae.user_id = b.user_id and ae.app = 'partner'
            ) ev on true
            left join lateral (
              select count(*)::int as flats,
                     (count(*) filter (where public.partner_flat_complete(i)))::int as flats_complete,
                     (count(*) filter (where (pl.created_at at time zone 'Asia/Kolkata')::date = d))::int as flats_today
                from public.partner_listings pl join public.inventory i on i.property_id = pl.property_id
               where pl.broker_id = b.user_id and not public.inventory_from_crm(i.source)
            ) f on true
        ) x
    ), '[]'::jsonb);
  end if;

  return jsonb_build_object(
    'flats', coalesce((
      select jsonb_agg(jsonb_build_object('property_id', i.property_id, 'title', i.title, 'area', i.area, 'rent', i.rent,
                                          'flat_type', i.flat_type, 'status', i.status, 'cover_image_url', i.cover_image_url,
                                          'complete', public.partner_flat_complete(i), 'created_at', pl.created_at)
                       order by pl.created_at desc)
        from public.partner_listings pl join public.inventory i on i.property_id = pl.property_id
       where pl.broker_id = p_broker and not public.inventory_from_crm(i.source)
    ), '[]'::jsonb),
    'moveazy_leads', public.crm_partner_leads(p_broker),
    'own_leads', coalesce((
      select jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name, 'phone', l.phone, 'status', l.status, 'source', l.source,
                                          'flat_types', l.flat_types, 'budget_min', l.budget_min, 'budget_max', l.budget_max,
                                          'localities', l.localities, 'move_in_label', l.move_in_label,
                                          'last_contacted_at', l.last_contacted_at, 'created_at', l.created_at,
                                          'visits', (select count(*) from public.partner_visits pv where pv.lead_id = l.id and pv.status = 'fixed'),
                                          'lists_sent', (select count(*) from public.partner_curated_lists c where c.lead_id = l.id),
                                          'likes', (select count(*) from public.partner_curated_actions a
                                                     join public.partner_curated_lists c on c.id = a.list_id
                                                    where c.lead_id = l.id and a.action = 'liked'))
                       order by l.created_at desc)
        from public.partner_leads l where l.broker_id = p_broker
    ), '[]'::jsonb)
  );
end;
$$;

-- ── Grants ──────────────────────────────────────────────────────────────────
revoke all on function public.crm_today() from public, anon;
revoke all on function public.crm_liked_no_visit(int) from public, anon;
revoke all on function public.crm_leads_not_called() from public, anon;
revoke all on function public.crm_visits_today() from public, anon;
revoke all on function public.crm_mobile_summary() from public, anon;
revoke all on function public.crm_payments_flow() from public, anon;
revoke all on function public.crm_partner_usage(uuid) from public, anon;
grant execute on function public.crm_today() to authenticated;
grant execute on function public.crm_liked_no_visit(int) to authenticated;
grant execute on function public.crm_leads_not_called() to authenticated;
grant execute on function public.crm_visits_today() to authenticated;
grant execute on function public.crm_mobile_summary() to authenticated;
grant execute on function public.crm_payments_flow() to authenticated;
grant execute on function public.crm_partner_usage(uuid) to authenticated;

commit;
