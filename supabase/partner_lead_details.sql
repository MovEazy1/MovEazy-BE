-- Leads in the partner app: the facts on every row, and everything a MovEazy
-- tenant filled in, on their page.
--
-- Run in the Supabase SQL editor AFTER partner_qr_leads.sql (the board this
-- replaces) and partner_moveazy_leads.sql (partner_my_assigned_leads,
-- lead_move_in_date). Safe to re-run.
--
-- Decided 2026-11-18:
--   * Every row in My leads (MovEazy's and the broker's own) shows who is
--     moving in (family / bachelor / roommates), flat type, budget, areas and
--     the move-in date. The date is exact where it can be: the day they filled
--     the form plus what they picked (Immediately = that day, 15 days, 1 month
--     = +30). "Flexible" shows as flexible; a date already gone is marked.
--   * Opening a MovEazy lead shows what they told us: the basics, office and
--     commute, and their preferences (must-haves, deal breakers, lifestyle,
--     priorities, about them). Where the MovEazy team corrected a requirement
--     in the CRM, only the team's version shows. Age and source are not shown.

begin;

/** The board (partner_qr_leads.sql), plus 'household' and 'move_in_flexible' on every row. */
create or replace function public.partner_tenants_board()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with t as (
    select l.id as lead_id, null::uuid as assignment_id, 'own'::text as kind,
           l.name, public.normalize_mobile(l.phone) as phone, l.localities, l.flat_types, l.budget_min, l.budget_max,
           l.furnishing, case when l.move_in_label = 'immediate' then 'Immediate move-in' else '' end as move_in_raw,
           null::date as req_move_in, l.created_at,
           l.last_contacted_at as contact_at, l.status as own_status, null::text as asg_status, null::text as pack,
           l.source as via, l.tentative, l.household, false as mi_flexible
      from public.partner_leads l where l.broker_id = auth.uid()
    union all
    select null, m.id, 'moveazy', m.name, public.normalize_mobile(m.phone), m.localities, m.flat_types, m.budget_min, m.budget_max,
           '', m.move_in_raw, m.move_in, m.assigned_at, m.last_reach_at, null, m.status, m.pack, '', false,
           array_to_string(m.occupants, ', '), coalesce(m.move_in_raw, '') ~* 'flexib|not sure|any ?time|undecided'
      from public.partner_my_assigned_leads() m
  ), x as (
    select t.*, tr.outcome, tr.outcome_at, tr.lost_reason, tr.move_in, tr.deal_property_id, tr.deal_rent, tr.deal_move_in, tr.actions_seen_at,
           (select array_agg(cl.id) from public.partner_curated_lists cl
             where cl.broker_id = auth.uid()
               and ((t.lead_id is not null and cl.lead_id = t.lead_id) or (t.assignment_id is not null and cl.assignment_id = t.assignment_id))) as list_ids
      from t
      left join public.partner_tenant_track tr
        on (t.lead_id is not null and tr.lead_id = t.lead_id) or (t.assignment_id is not null and tr.assignment_id = t.assignment_id)
  ), y as (
    select x.*,
           coalesce(cardinality(x.list_ids), 0) as lists,
           (select count(distinct a.property_id)::int from public.partner_curated_actions a where a.list_id = any (coalesce(x.list_ids, '{}')) and a.action = 'liked') as liked,
           (select count(*)::int from public.partner_curated_actions a where a.list_id = any (coalesce(x.list_ids, '{}'))
              and a.at > coalesce(x.actions_seen_at, '-infinity')) as new_actions,
           (select max(a.at) from public.partner_curated_actions a where a.list_id = any (coalesce(x.list_ids, '{}'))) as last_action_at,
           exists (select 1 from public.partner_curated_lists cl where cl.id = any (coalesce(x.list_ids, '{}')) and cl.opened_at is not null) as opened,
           (select min(v.visit_at) from public.partner_visits v where v.status = 'fixed' and v.visit_at > now() - interval '12 hours'
              and ((x.lead_id is not null and v.lead_id = x.lead_id) or (x.assignment_id is not null and v.assignment_id = x.assignment_id))) as next_visit,
           exists (select 1 from public.partner_visits v where v.status = 'fixed'
              and ((x.lead_id is not null and v.lead_id = x.lead_id) or (x.assignment_id is not null and v.assignment_id = x.assignment_id))) as has_visit,
           (select jsonb_build_object('id', r.id, 'due_at', r.due_at, 'note', r.note, 'kind', r.kind)
              from public.partner_reminders r where r.done_at is null and r.broker_id = auth.uid()
               and ((x.lead_id is not null and r.lead_id = x.lead_id) or (x.assignment_id is not null and r.assignment_id = x.assignment_id))
             order by r.due_at limit 1) as next_reminder,
           (select count(*)::int from public.partner_storefront_visits sv where x.lead_id is not null and sv.lead_id = x.lead_id) as qr_visits
      from x
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', case when y.lead_id is not null then 'lead:' || y.lead_id else 'asg:' || y.assignment_id end,
           'slug', case when y.lead_id is not null then 'lead-' || y.lead_id else 'asg-' || y.assignment_id end,
           'kind', y.kind, 'lead_id', y.lead_id, 'assignment_id', y.assignment_id, 'pack', y.pack,
           'name', y.name, 'phone', y.phone, 'localities', y.localities, 'flat_types', y.flat_types,
           'budget_min', y.budget_min, 'budget_max', y.budget_max, 'furnishing', y.furnishing, 'move_in_raw', y.move_in_raw,
           'move_in', coalesce(y.move_in, y.req_move_in),
           'stage', case
              when y.outcome = 'done' or y.asg_status = 'closed' then 'done'
              when y.outcome = 'lost' or y.asg_status = 'not_interested' or (y.kind = 'own' and y.own_status = 'closed') then 'lost'
              when y.has_visit then 'visit'
              when y.liked > 0 then 'liked'
              when y.lists > 0 then 'list_sent'
              when y.contact_at is not null or y.asg_status in ('contacted', 'visit') then 'contacted'
              else 'new' end,
           'lost_reason', y.lost_reason, 'outcome_at', y.outcome_at,
           'deal', case when y.deal_property_id <> '' or y.deal_rent is not null then
                     jsonb_build_object('property_id', y.deal_property_id, 'rent', y.deal_rent, 'move_in', y.deal_move_in) end,
           'lists', y.lists, 'opened', y.opened, 'liked', y.liked, 'new_actions', y.new_actions, 'last_action_at', y.last_action_at,
           'last_contact_at', y.contact_at, 'next_visit', y.next_visit, 'next_reminder', y.next_reminder, 'created_at', y.created_at,
           'via', y.via, 'tentative', y.tentative, 'qr_visits', y.qr_visits,
           'household', y.household, 'move_in_flexible', y.mi_flexible)
           order by y.created_at desc), '[]'::jsonb)
    from y
   where public.is_approved_partner();
$$;


/**
 * Everything a MovEazy tenant told us, for the broker the lead was given to.
 * The team's requirement (crm_client_requirements) wins field by field over
 * the tenant's own answers (user_requirements). null if not theirs.
 */
create or replace function public.partner_lead_profile(p_assignment uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
           'answered', u.user_id is not null or r.client_id is not null,
           'occupants', coalesce(nullif(r.occupants, '{}'), u.occupants, '{}'),
           'flat_types', coalesce(nullif(r.flat_types, '{}'), u.flat_types, '{}'),
           'localities', coalesce(nullif(r.localities, '{}'), u.localities, '{}'),
           'budget_min', coalesce(r.budget_min, u.budget_min),
           'budget_max', coalesce(r.budget_max, u.budget_max),
           'stretch', coalesce(u.stretch, false) and r.budget_max is null,
           'furnishing', coalesce(r.furnishing, ''),
           'move_in_raw', mi.raw,
           'move_in', public.lead_move_in_date(mi.raw, mi.said),
           'move_in_said_at', case when mi.raw <> '' then mi.said end,
           'move_in_flexible', mi.raw ~* 'flexib|not sure|any ?time|undecided',
           'office', coalesce(nullif(u.office ->> 'display', ''), nullif(u.office ->> 'label', ''), ''),
           'commute_minutes', case when u.office is not null then (u.notes ->> 'commuteMinutes') end,
           'commute_flexible', coalesce((u.notes ->> 'commuteFlexible')::boolean, true),
           'must_haves', coalesce(nullif(r.must_haves, '{}'), u.must_haves, '{}'),
           'deal_breakers', coalesce(nullif(r.deal_breakers, '{}'), u.deal_breakers, '{}'),
           'lifestyle', coalesce(u.lifestyle, '{}'),
           'priority', coalesce(u.priority, '{}'),
           'profile', coalesce(u.notes ->> 'profile', ''),
           'move_reason', coalesce(u.notes ->> 'moveReason', ''),
           'about', case when jsonb_typeof(u.notes -> 'aboutMe') = 'array' then u.notes -> 'aboutMe' else '[]'::jsonb end,
           'filled_at', u.updated_at)
    from public.partner_lead_assignments a
    join public.crm_clients c on c.id = a.client_id
    left join public.crm_client_requirements r on r.client_id = c.id
    left join public.user_requirements u on u.user_id = c.user_id
   cross join lateral (
     select case when coalesce(r.move_in, '') <> '' then r.move_in else coalesce(u.notes ->> 'moveInDate', '') end as raw,
            case when coalesce(r.move_in, '') <> '' then r.updated_at else u.updated_at end as said) mi
   where a.id = p_assignment and a.broker_id = auth.uid() and public.is_approved_partner();
$$;

revoke all on function public.partner_tenants_board() from public, anon;
grant execute on function public.partner_tenants_board() to authenticated;
revoke all on function public.partner_lead_profile(uuid) from public, anon;
grant execute on function public.partner_lead_profile(uuid) to authenticated;

commit;
