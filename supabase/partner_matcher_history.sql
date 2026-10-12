-- AI Property Matcher, with memory.
--
--   · MovEazy tenants assigned to a broker (partner_moveazy_leads.sql) get
--     curated lists too — from any approved partner, not only Premium. A free
--     partner's lists to their own clients carry their own flats and MovEazy's
--     (other brokers' flats are Premium). A MovEazy tenant's list opens without
--     the phone gate: MovEazy already knows who they are.
--   · Never suggest a flat twice. partner_matcher_seen() gives, per tenant,
--     every flat this broker already sent them; every flat the same mobile
--     liked or skipped on ANY partner's list; and, from MovEazy, every flat
--     they disliked or MovEazy passed on for them. Ids only — a broker never
--     learns who else sent what.
--   · Visits: a broker fixes a visit for a liked flat (partner_visit_set); on
--     the day, the first open of the app drops "N visits today" in the bell.
--   · MovEazy's CRM sees it on the client's timeline: lists sent, likes,
--     visits fixed — and a fixed visit moves the assignment to 'visit'.
--
-- Replaces partner_curated_open / _act / _mine from partner_launch.sql (open and
-- _act are replaced again by partner_curated_tenant.sql, run after this): run
-- this after it (and after partner_moveazy_leads.sql). Safe to re-run.

begin;

-- ── Lists for MovEazy tenants ───────────────────────────────────────────────
alter table public.partner_curated_lists
  add column if not exists assignment_id uuid references public.partner_lead_assignments (id) on delete set null;
create index if not exists partner_curated_lists_assignment_idx
  on public.partner_curated_lists (assignment_id) where assignment_id is not null;

-- ── Visits ──────────────────────────────────────────────────────────────────
create table if not exists public.partner_visits (
  id            uuid primary key default gen_random_uuid(),
  broker_id     uuid not null references auth.users (id) on delete cascade,
  lead_id       uuid references public.partner_leads (id) on delete cascade,
  assignment_id uuid references public.partner_lead_assignments (id) on delete cascade,
  property_id   text not null,
  visit_at      timestamptz not null,
  status        text not null default 'fixed' check (status in ('fixed', 'cancelled')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (num_nonnulls(lead_id, assignment_id) = 1)
);
create unique index if not exists partner_visits_lead_uq on public.partner_visits (lead_id, property_id) where lead_id is not null;
create unique index if not exists partner_visits_asg_uq on public.partner_visits (assignment_id, property_id) where assignment_id is not null;
create index if not exists partner_visits_broker_idx on public.partner_visits (broker_id, visit_at);
alter table public.partner_visits enable row level security;
revoke all on table public.partner_visits from anon, authenticated;

-- Notification kinds: keep whatever is there, add the reminder.
do $$
declare
  kinds text[];
begin
  select array_agg(distinct m[1]) into kinds
    from pg_constraint c, regexp_matches(pg_get_constraintdef(c.oid), '''([a-z_]+)''', 'g') m
   where c.conname = 'partner_notifications_kind_check';
  if kinds is null then return; end if;  -- no constraint, nothing to widen
  kinds := array(select distinct k from unnest(kinds || array['visit_reminder']) k order by 1);
  alter table public.partner_notifications drop constraint partner_notifications_kind_check;
  execute format('alter table public.partner_notifications add constraint partner_notifications_kind_check check (kind in (%s))',
                 (select string_agg(quote_literal(k), ', ') from unnest(kinds) k));
end $$;

-- ── Helpers (internal) ──────────────────────────────────────────────────────

/** One flat in a line: "2 BHK · HSR Layout · ₹40,000 (MZ-123)". */
create or replace function public.partner_flat_line(p_property text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select concat_ws(' · ', nullif(i.flat_type, ''), nullif(i.area, ''),
                     case when i.rent > 0 then '₹' || to_char(i.rent, 'FM99,99,999') end) || ' (' || i.property_id || ')'
      from public.inventory i where i.property_id = p_property), p_property);
$$;

/** The broker's name for MovEazy's timeline. */
create or replace function public.partner_display_name(p_broker uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select nullif(bp.name, '') || coalesce(' (' || nullif(bp.agency, '') || ')', '')
                     from public.broker_partners bp where bp.user_id = p_broker), 'A partner');
$$;

/** Is this assignment the caller's, and still open? → the CRM client, else an error. */
create or replace function public.partner_my_open_assignment(p_assignment uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  cid uuid;
begin
  select a.client_id into cid from public.partner_lead_assignments a
   where a.id = p_assignment and a.broker_id = auth.uid() and a.status not in ('closed', 'not_interested');
  if cid is null then raise exception 'That MovEazy lead is not open with you.' using errcode = '42501'; end if;
  return cid;
end;
$$;

revoke all on function public.partner_flat_line(text) from public, anon, authenticated;
revoke all on function public.partner_display_name(uuid) from public, anon, authenticated;
revoke all on function public.partner_my_open_assignment(uuid) from public, anon, authenticated;

-- ── Sending ─────────────────────────────────────────────────────────────────

/**
 * A curated list for one tenant: the broker's own client (p_lead, Premium) or
 * a MovEazy tenant assigned to them (p_assignment, any approved partner).
 */
create or replace function public.partner_curated_send(p_lead uuid, p_assignment uuid, p_properties text[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  ids   text[];
  lname text;
  cid   uuid;
  rec   public.partner_curated_lists;
begin
  if not public.is_approved_partner() then
    raise exception 'Only MovEazy partners can send lists.' using errcode = '42501';
  end if;
  if num_nonnulls(p_lead, p_assignment) <> 1 then
    raise exception 'Pick one tenant.' using errcode = '22023';
  end if;
  select coalesce(array_agg(distinct p), '{}') into ids from unnest(coalesce(p_properties, '{}')) p where coalesce(p, '') <> '';
  if cardinality(ids) = 0 or cardinality(ids) > 30 then
    raise exception 'Pick between 1 and 30 homes.' using errcode = '22023';
  end if;
  if exists (select unnest(ids) except select property_id from public.partner_inventory()) then
    raise exception 'One of those homes is not in your inventory.' using errcode = '42501';
  end if;

  if p_lead is not null then
    -- Free partners send their own flats and MovEazy's; other brokers' flats come with Premium.
    if not public.partner_has_tier('moveazy_inventory')
       and exists (select 1 from public.partner_inventory() i where i.property_id = any (ids) and i.source not in ('mine', 'moveazy')) then
      raise exception 'Other brokers'' flats come with Premium — send your own flats and MovEazy''s.' using errcode = '42501';
    end if;
    select name into lname from public.partner_leads where id = p_lead and broker_id = auth.uid();
    if not found then raise exception 'That lead is not yours.' using errcode = '42501'; end if;
  else
    cid := public.partner_my_open_assignment(p_assignment);
    select coalesce(c.name, '') into lname from public.crm_clients c where c.id = cid;
  end if;

  insert into public.partner_curated_lists (broker_id, lead_id, assignment_id, lead_name, property_ids)
  values (auth.uid(), p_lead, p_assignment, coalesce(lname, ''), ids)
  returning * into rec;

  if p_assignment is not null then
    -- Sending them flats is reaching out.
    update public.partner_lead_assignments set status = 'contacted', updated_at = now()
     where id = p_assignment and status = 'assigned';
    insert into public.crm_activities (client_id, actor_email, type, body, meta)
    values (cid, coalesce(nullif(auth.jwt() ->> 'email', ''), 'partner'), 'partner',
            public.partner_display_name(auth.uid()) || ' sent ' || cardinality(ids) || ' flat' ||
              case when cardinality(ids) = 1 then '' else 's' end || ': ' || array_to_string(ids, ', '),
            jsonb_build_object('source', 'partner_list', 'broker_id', auth.uid(), 'list_id', rec.id, 'property_ids', to_jsonb(ids)));
  end if;
  return jsonb_build_object('id', rec.id, 'token', rec.token, 'count', cardinality(ids));
end;
$$;

-- ── The tenant's side (replacing partner_launch.sql's) ──────────────────────

/** The tenant's page, by the link's token. A MovEazy tenant's list needs no phone gate. */
create or replace function public.partner_curated_open(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  l public.partner_curated_lists;
begin
  select * into l from public.partner_curated_lists where token = p_token;
  if l.id is null then return null; end if;
  update public.partner_curated_lists
     set open_count = open_count + 1, opened_at = coalesce(opened_at, now())
   where id = l.id;
  if l.opened_at is null then
    insert into public.partner_notifications (broker_id, kind, title, body, link)
    values (l.broker_id, 'list_opened', coalesce(nullif(l.lead_name, ''), 'Your tenant') || ' opened your list',
            cardinality(l.property_ids) || ' homes — likes and skips will show up here.', '/curated/' || l.id::text);
  end if;
  return jsonb_build_object(
    'lead_name', l.lead_name,
    'has_contact', l.tenant_id is not null or l.assignment_id is not null,
    'known', l.assignment_id is not null,
    'broker', (select jsonb_build_object('name', bp.name, 'agency', bp.agency, 'phone', bp.phone,
                                         'photo_url', coalesce((select s.photo_url from public.partner_storefronts s where s.broker_id = bp.user_id), ''))
                 from public.broker_partners bp where bp.user_id = l.broker_id),
    'homes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'property_id', i.property_id, 'title', i.title, 'area', i.area, 'rent', i.rent, 'deposit', i.deposit,
               'flat_type', i.flat_type, 'bedrooms', i.bedrooms, 'bathrooms', i.bathrooms, 'furnishing', i.furnishing,
               'property_type', i.property_type, 'available_from', i.available_from, 'images', i.images,
               'cover_image_url', i.cover_image_url, 'description', i.description, 'status', i.status,
               'action', (select a.action from public.partner_curated_actions a where a.list_id = l.id and a.property_id = i.property_id))
             order by array_position(l.property_ids, i.property_id))
        from public.inventory i where i.property_id = any (l.property_ids)), '[]'::jsonb)
  );
end;
$$;

/** A swipe. A like tells the broker straight away — and MovEazy, for its own tenants. */
create or replace function public.partner_curated_act(p_token text, p_property text, p_action text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  l  public.partner_curated_lists;
  v_name  text;
  v_phone text;
  cid uuid;
  h  public.inventory;
  was_done boolean;
  n_liked int;
  n_skipped int;
begin
  select * into l from public.partner_curated_lists where token = p_token;
  if l.id is null then raise exception 'This list is no longer available.' using errcode = '22023'; end if;
  if l.tenant_id is null and l.assignment_id is null then raise exception 'Add your mobile number first.' using errcode = '42501'; end if;
  if not (p_property = any (l.property_ids)) then raise exception 'That home is not on this list.' using errcode = '22023'; end if;
  if p_action not in ('liked', 'skipped') then raise exception 'Unknown action.' using errcode = '22023'; end if;

  if l.tenant_id is not null then
    select t.name, t.phone into v_name, v_phone from public.partner_tenants t where t.id = l.tenant_id;
  else
    select c.id, c.name, public.normalize_mobile(c.phone) into cid, v_name, v_phone
      from public.partner_lead_assignments a join public.crm_clients c on c.id = a.client_id where a.id = l.assignment_id;
  end if;
  v_name := coalesce(nullif(v_name, ''), nullif(l.lead_name, ''), 'Your tenant');

  select count(*) = cardinality(l.property_ids) into was_done from public.partner_curated_actions where list_id = l.id;
  insert into public.partner_curated_actions as a (list_id, property_id, action)
  values (l.id, p_property, p_action)
  on conflict (list_id, property_id) do update set action = excluded.action, at = now();

  if p_action = 'liked' then
    select * into h from public.inventory where property_id = p_property;
    insert into public.partner_notifications (broker_id, kind, title, body, link)
    values (l.broker_id, 'tenant_liked', v_name || ' liked a home',
            concat_ws(' · ', nullif(h.flat_type, ''), nullif(h.area, ''), case when h.rent > 0 then '₹' || to_char(h.rent, 'FM99,99,999') end)
              || ' — ' || coalesce(v_phone, ''),
            '/curated/' || l.id::text);
    if cid is not null then
      -- The tenant did it, so no actor: it reads as their own activity in the CRM.
      insert into public.crm_activities (client_id, actor_email, type, body, meta)
      values (cid, '', 'partner', 'Liked ' || public.partner_flat_line(p_property) || ' on ' ||
                public.partner_display_name(l.broker_id) || '''s list',
              jsonb_build_object('source', 'partner_like', 'broker_id', l.broker_id, 'list_id', l.id, 'property_id', p_property));
    end if;
  end if;

  if not was_done then
    select count(*) filter (where action = 'liked'), count(*) filter (where action = 'skipped'), count(*) = cardinality(l.property_ids)
      into n_liked, n_skipped, was_done
      from public.partner_curated_actions where list_id = l.id;
    if was_done then
      insert into public.partner_notifications (broker_id, kind, title, body, link)
      values (l.broker_id, 'list_done', v_name || ' finished your list',
              '♥ ' || n_liked || ' liked · ✕ ' || n_skipped || ' skipped — ' || coalesce(v_phone, ''),
              '/curated/' || l.id::text);
    end if;
  end if;
  return true;
end;
$$;

/** A broker's lists, with what each tenant did. */
create or replace function public.partner_curated_mine()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', l.id, 'token', l.token, 'lead_id', l.lead_id, 'assignment_id', l.assignment_id, 'lead_name', l.lead_name,
           'created_at', l.created_at, 'opened_at', l.opened_at, 'open_count', l.open_count, 'property_ids', l.property_ids,
           'tenant', coalesce(
             (select jsonb_build_object('name', t.name, 'phone', t.phone) from public.partner_tenants t where t.id = l.tenant_id),
             (select jsonb_build_object('name', c.name, 'phone', public.normalize_mobile(c.phone))
                from public.partner_lead_assignments a join public.crm_clients c on c.id = a.client_id
               where a.id = l.assignment_id and a.broker_id = l.broker_id)),
           'actions', coalesce((select jsonb_object_agg(a.property_id, jsonb_build_object('action', a.action, 'at', a.at))
                                  from public.partner_curated_actions a where a.list_id = l.id), '{}'::jsonb))
           order by l.created_at desc), '[]'::jsonb)
    from public.partner_curated_lists l where l.broker_id = auth.uid();
$$;

-- ── Never suggest twice ─────────────────────────────────────────────────────

/** Per tenant ("lead:<id>" / "asg:<id>"), the flats the matcher must leave out. Ids only. */
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

-- ── Visits ──────────────────────────────────────────────────────────────────

/** Fix (or move) a visit to one flat for one tenant. → the visit's id. */
create or replace function public.partner_visit_set(p_lead uuid, p_assignment uuid, p_property text, p_at timestamptz)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  cid uuid;
  vid uuid;
begin
  if not public.is_approved_partner() then
    raise exception 'Only MovEazy partners can fix visits.' using errcode = '42501';
  end if;
  if num_nonnulls(p_lead, p_assignment) <> 1 then
    raise exception 'Pick one tenant.' using errcode = '22023';
  end if;
  if p_at is null or p_at < now() - interval '1 day' or p_at > now() + interval '90 days' then
    raise exception 'Pick a time in the next three months.' using errcode = '22023';
  end if;
  if not exists (select 1 from public.partner_inventory() i where i.property_id = p_property) then
    raise exception 'That home is no longer in your inventory.' using errcode = '22023';
  end if;

  if p_lead is not null then
    if not exists (select 1 from public.partner_leads where id = p_lead and broker_id = auth.uid()) then
      raise exception 'That lead is not yours.' using errcode = '42501';
    end if;
    insert into public.partner_visits as v (broker_id, lead_id, property_id, visit_at)
    values (auth.uid(), p_lead, p_property, p_at)
    on conflict (lead_id, property_id) where lead_id is not null
      do update set visit_at = excluded.visit_at, status = 'fixed', updated_at = now()
    returning v.id into vid;
  else
    cid := public.partner_my_open_assignment(p_assignment);
    insert into public.partner_visits as v (broker_id, assignment_id, property_id, visit_at)
    values (auth.uid(), p_assignment, p_property, p_at)
    on conflict (assignment_id, property_id) where assignment_id is not null
      do update set visit_at = excluded.visit_at, status = 'fixed', updated_at = now()
    returning v.id into vid;
    update public.partner_lead_assignments set status = 'visit', updated_at = now()
     where id = p_assignment and status in ('assigned', 'contacted');
    insert into public.crm_activities (client_id, actor_email, type, body, meta)
    values (cid, coalesce(nullif(auth.jwt() ->> 'email', ''), 'partner'), 'partner',
            public.partner_display_name(auth.uid()) || ' fixed a visit: ' || public.partner_flat_line(p_property) || ' on ' ||
              to_char(p_at at time zone 'Asia/Kolkata', 'Dy DD Mon, FMHH12:MI am'),
            jsonb_build_object('source', 'partner_visit', 'broker_id', auth.uid(), 'visit_id', vid, 'property_id', p_property, 'at', p_at));
  end if;
  return vid;
end;
$$;

/** Call a visit off. */
create or replace function public.partner_visit_cancel(p_visit uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.partner_visits;
  cid uuid;
begin
  update public.partner_visits set status = 'cancelled', updated_at = now()
   where id = p_visit and broker_id = auth.uid() and status = 'fixed'
  returning * into v;
  if v.id is null then return; end if;
  if v.assignment_id is not null then
    select client_id into cid from public.partner_lead_assignments where id = v.assignment_id;
    insert into public.crm_activities (client_id, actor_email, type, body, meta)
    values (cid, coalesce(nullif(auth.jwt() ->> 'email', ''), 'partner'), 'partner',
            public.partner_display_name(auth.uid()) || ' called off the visit to ' || public.partner_flat_line(v.property_id),
            jsonb_build_object('source', 'partner_visit_cancel', 'broker_id', auth.uid(), 'visit_id', v.id, 'property_id', v.property_id));
  end if;
end;
$$;

/** The broker's visits from yesterday on, soonest first. */
create or replace function public.partner_visits_mine()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', v.id, 'lead_id', v.lead_id, 'assignment_id', v.assignment_id, 'property_id', v.property_id,
           'visit_at', v.visit_at, 'status', v.status,
           'tenant', coalesce(
             (select jsonb_build_object('name', l.name, 'phone', public.normalize_mobile(l.phone)) from public.partner_leads l where l.id = v.lead_id),
             (select jsonb_build_object('name', c.name, 'phone', public.normalize_mobile(c.phone))
                from public.partner_lead_assignments a join public.crm_clients c on c.id = a.client_id where a.id = v.assignment_id)),
           'flat', public.partner_flat_line(v.property_id))
           order by v.visit_at), '[]'::jsonb)
    from public.partner_visits v
   where v.broker_id = auth.uid() and public.is_approved_partner()
     and v.status = 'fixed' and v.visit_at >= date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata' - interval '1 day';
$$;

/**
 * Today's visits (IST). The first call of the day with any visits also puts
 * "N visits today" in the bell — the partner app has no push, so the first
 * open of the day is when a reminder can be seen anyway.
 */
create or replace function public.partner_visits_today()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  day_start timestamptz := date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata';
  rows jsonb;
  n int;
begin
  if not public.is_approved_partner() then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(x order by x ->> 'visit_at'), '[]'::jsonb), count(*) into rows, n
    from jsonb_array_elements(public.partner_visits_mine()) x
   where (x ->> 'visit_at')::timestamptz >= day_start and (x ->> 'visit_at')::timestamptz < day_start + interval '1 day';
  if n > 0 and not exists (select 1 from public.partner_notifications
                            where broker_id = auth.uid() and kind = 'visit_reminder' and created_at >= day_start) then
    insert into public.partner_notifications (broker_id, kind, title, body, link)
    values (auth.uid(), 'visit_reminder', n || ' visit' || case when n = 1 then '' else 's' end || ' today',
            (select string_agg(to_char((x ->> 'visit_at')::timestamptz at time zone 'Asia/Kolkata', 'FMHH12:MI am') || ' · ' ||
                               coalesce(nullif(x -> 'tenant' ->> 'name', ''), 'Tenant') || ' · ' || (x ->> 'flat'), E'\n'
                               order by x ->> 'visit_at')
               from jsonb_array_elements(rows) x),
            '/');
  end if;
  return rows;
end;
$$;

-- ── Grants ──────────────────────────────────────────────────────────────────
revoke all on function public.partner_curated_send(uuid, uuid, text[]) from public, anon;
revoke all on function public.partner_curated_mine() from public, anon;
revoke all on function public.partner_matcher_seen() from public, anon;
revoke all on function public.partner_visit_set(uuid, uuid, text, timestamptz) from public, anon;
revoke all on function public.partner_visit_cancel(uuid) from public, anon;
revoke all on function public.partner_visits_mine() from public, anon;
revoke all on function public.partner_visits_today() from public, anon;
grant execute on function public.partner_curated_send(uuid, uuid, text[]) to authenticated;
grant execute on function public.partner_curated_mine() to authenticated;
grant execute on function public.partner_matcher_seen() to authenticated;
grant execute on function public.partner_visit_set(uuid, uuid, text, timestamptz) to authenticated;
grant execute on function public.partner_visit_cancel(uuid) to authenticated;
grant execute on function public.partner_visits_mine() to authenticated;
grant execute on function public.partner_visits_today() to authenticated;
-- The tenant's link works signed out, as before.
grant execute on function public.partner_curated_open(text) to anon, authenticated;
grant execute on function public.partner_curated_act(text, text, text) to anon, authenticated;

commit;
