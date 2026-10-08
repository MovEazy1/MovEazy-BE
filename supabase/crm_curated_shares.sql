-- ─────────────────────────────────────────────────────────────────────────────
-- Curated shares: one link carrying the whole shortlist, not 23 links.
--
-- Run once in the Supabase SQL editor, after crm_schema.sql and
-- crm_share_tracking.sql. Idempotent.
--
-- Sending 23 properties used to mean pasting 23 tracked links into one WhatsApp
-- message. Nobody taps 23 links, and the ones they do tap arrive with no sense
-- of the set they came from. A curated share is the set itself: one row, one
-- token, one link. The recipient swipes through it the same way they swiped
-- the first five, and every swipe comes back here — so "did not like" and
-- "visit scheduled" are facts the CRM holds rather than things an agent has to
-- ask about and type in.
--
-- The recipient is signed out when they tap a WhatsApp link, so all three
-- entry points are security-definer functions taking the opaque token. They can
-- only ever touch the one client and the one property set that token names.
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.crm_curated_shares (
  id            uuid primary key default gen_random_uuid(),
  client_id     uuid not null references public.crm_clients(id) on delete cascade,
  token         text not null unique,
  property_ids  text[] not null default '{}',
  shared_by     text default '',
  agent_name    text default '',
  created_at    timestamptz not null default now(),
  opened_at     timestamptz,
  last_opened_at timestamptz,
  open_count    int not null default 0
);

create index if not exists crm_curated_shares_client_idx
  on public.crm_curated_shares (client_id, created_at desc);

alter table public.crm_curated_shares enable row level security;

drop policy if exists "crm read curated shares" on public.crm_curated_shares;
create policy "crm read curated shares"
  on public.crm_curated_shares for select
  to authenticated
  using (public.is_crm_staff());

drop policy if exists "crm write curated shares" on public.crm_curated_shares;
create policy "crm write curated shares"
  on public.crm_curated_shares for all
  to authenticated
  using (public.has_admin_scope('crm.clients.write'))
  with check (public.has_admin_scope('crm.clients.write'));

grant select, insert, update, delete on public.crm_curated_shares to authenticated;

-- A visit the client booked themselves is a different fact from "shortlisted",
-- and the pane that reads this column is what an agent works from.
alter table public.crm_shortlists drop constraint if exists crm_shortlists_status_check;
alter table public.crm_shortlists add constraint crm_shortlists_status_check
  check (status in ('shortlisted','shared','liked','okay','disliked','visited','visit_scheduled','rejected'));

-- Which curated batch a reply came from, so the CRM can say "of the 23 you
-- sent on Tuesday, she liked 4" rather than only ever showing a flat list.
alter table public.crm_shortlists add column if not exists curated_share_id uuid
  references public.crm_curated_shares(id) on delete set null;
alter table public.crm_shortlists add column if not exists reacted_at timestamptz;

-- ─────────────────────────────────────────────────────────────────────────────
-- Opening the link.
--
-- Returns the property ids in the order the agent picked them, plus whatever
-- the client has already said about each, so a half-finished swipe session
-- resumes where it stopped instead of starting over.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.curated_share_open(token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  share public.crm_curated_shares;
  first_open boolean;
  reactions jsonb;
begin
  if token is null or length(token) < 8 then
    return jsonb_build_object('ok', false);
  end if;

  select * into share from public.crm_curated_shares s where s.token = curated_share_open.token;
  if share.id is null then
    return jsonb_build_object('ok', false);
  end if;

  first_open := share.opened_at is null;

  update public.crm_curated_shares
     set open_count = open_count + 1,
         opened_at = coalesce(opened_at, now()),
         last_opened_at = now()
   where id = share.id;

  if first_open then
    insert into public.crm_activities (client_id, actor_email, type, body, meta)
    values (
      share.client_id, '', 'system',
      'Opened the shortlist you sent · ' || coalesce(array_length(share.property_ids, 1), 0) || ' homes',
      jsonb_build_object('curated_share_id', share.id, 'via', 'curated_link')
    );
  end if;

  select coalesce(jsonb_object_agg(sl.property_id, sl.status), '{}'::jsonb)
    into reactions
    from public.crm_shortlists sl
   where sl.client_id = share.client_id
     and sl.property_id = any (share.property_ids);

  return jsonb_build_object(
    'ok', true,
    'client_name', (select coalesce(c.name, '') from public.crm_clients c where c.id = share.client_id),
    'agent_name', coalesce(share.agent_name, ''),
    'shared_at', share.created_at,
    'property_ids', to_jsonb(share.property_ids),
    'reactions', reactions
  );
end;
$$;

revoke all on function public.curated_share_open(text) from public;
grant execute on function public.curated_share_open(text) to anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- A swipe.
--
-- Left is 'disliked', right is 'liked'. Written straight onto the shortlist
-- row, and mirrored into listing_reactions when the client has an account —
-- the recommendation engine should learn from a swipe on a shared link exactly
-- as it learns from one in the app.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.curated_share_react(
  token text,
  p_property_id text,
  p_reaction text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  share public.crm_curated_shares;
  status text;
  uid uuid;
begin
  if token is null or length(token) < 8 or p_property_id is null then
    return jsonb_build_object('ok', false);
  end if;

  status := case p_reaction
              when 'like' then 'liked'
              when 'dislike' then 'disliked'
              when 'okay' then 'okay'
              else null
            end;
  if status is null then
    return jsonb_build_object('ok', false);
  end if;

  select * into share from public.crm_curated_shares s where s.token = curated_share_react.token;
  if share.id is null or not (p_property_id = any (share.property_ids)) then
    return jsonb_build_object('ok', false);
  end if;

  -- A booked visit outranks a swipe: someone who liked a flat enough to book it
  -- must not be downgraded to 'liked' by a later idle swipe through the deck.
  insert into public.crm_shortlists (client_id, property_id, status, curated_share_id, reacted_at)
  values (share.client_id, p_property_id, status, share.id, now())
  on conflict (client_id, property_id) do update
    set status = case when crm_shortlists.status = 'visit_scheduled'
                      then crm_shortlists.status else excluded.status end,
        curated_share_id = coalesce(crm_shortlists.curated_share_id, excluded.curated_share_id),
        reacted_at = now();

  select c.user_id into uid from public.crm_clients c where c.id = share.client_id;
  if uid is not null and p_reaction in ('like', 'dislike') then
    insert into public.listing_reactions (user_id, property_id, reaction, source, updated_at)
    values (uid, p_property_id, p_reaction, 'curated_link', now())
    on conflict (user_id, property_id) do update
      set reaction = excluded.reaction, source = excluded.source, updated_at = now();
  end if;

  insert into public.crm_activities (client_id, actor_email, type, body, meta)
  values (
    share.client_id, '', 'shortlist',
    case p_reaction
      when 'like' then 'Liked ' || p_property_id || ' on the shortlist link'
      when 'dislike' then 'Did not like ' || p_property_id || ' on the shortlist link'
      else 'Marked ' || p_property_id || ' okay on the shortlist link'
    end,
    jsonb_build_object('property_id', p_property_id, 'reaction', p_reaction, 'curated_share_id', share.id)
  );

  return jsonb_build_object('ok', true, 'status', status);
end;
$$;

revoke all on function public.curated_share_react(text, text, text) from public;
grant execute on function public.curated_share_react(text, text, text) to anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- The same shortlist, for a signed-in client who came back without the link.
--
-- Everything the team has ever shared with them, newest batch first. Their own
-- account is the key, so there is no token to leak and nothing to guess.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.my_curated_properties()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  cid uuid;
  ids text[];
  reactions jsonb;
  tok text;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false);
  end if;

  select id into cid from public.crm_clients where user_id = auth.uid();
  if cid is null then
    return jsonb_build_object('ok', true, 'property_ids', '[]'::jsonb, 'reactions', '{}'::jsonb);
  end if;

  -- Order matters: this is a deck someone swipes, and the agent picked the
  -- sequence. Newest batch first, in the order it was sent, then older batches,
  -- then anything shared one-off before curated shares existed. array_agg over
  -- a plain union would have sorted them by id, which is nobody's order.
  select array_agg(pid order by rank, seq) into ids
    from (
      select distinct on (pid) pid, rank, seq
        from (
          select p.pid,
                 row_number() over (order by s.created_at desc) as rank,
                 p.ord as seq
            from public.crm_curated_shares s
            cross join lateral unnest(s.property_ids) with ordinality as p(pid, ord)
           where s.client_id = cid
          union all
          select sl.property_id, 1000000, extract(epoch from sl.created_at)::bigint
            from public.crm_shortlists sl
           where sl.client_id = cid
             and sl.status in ('shared','liked','okay','disliked','visited','visit_scheduled','shortlisted')
        ) everything
       order by pid, rank, seq
    ) ranked;

  select token into tok
    from public.crm_curated_shares
   where client_id = cid
   order by created_at desc
   limit 1;

  select coalesce(jsonb_object_agg(sl.property_id, sl.status), '{}'::jsonb)
    into reactions
    from public.crm_shortlists sl
   where sl.client_id = cid;

  return jsonb_build_object(
    'ok', true,
    'token', coalesce(tok, ''),
    'property_ids', to_jsonb(coalesce(ids, '{}'::text[])),
    'reactions', reactions
  );
end;
$$;

revoke all on function public.my_curated_properties() from public;
grant execute on function public.my_curated_properties() to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- A booked visit now says so on the shortlist row.
--
-- crm_visit_sync.sql already files the booking into the timeline and moves the
-- client along; this replaces its "leave whatever status is there" insert so an
-- agent scanning the shared set sees which of the 23 turned into a visit.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.crm_record_visit_booking()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  cid uuid;
  slot_label text;
begin
  if new.user_id is null then
    return new;
  end if;

  select id into cid from public.crm_clients where user_id = new.user_id;

  if cid is null then
    insert into public.crm_clients (user_id, name, phone, email, source, status)
    select
      p.id,
      coalesce(nullif(p.name, ''), split_part(p.email, '@', 1)),
      coalesce(p.phone, ''),
      p.email,
      'app',
      'visit_pending'
    from public.user_profiles p
    where p.id = new.user_id
    on conflict (user_id) do nothing
    returning id into cid;

    if cid is null then
      select id into cid from public.crm_clients where user_id = new.user_id;
    end if;
  end if;

  if cid is null then
    return new;
  end if;

  slot_label := coalesce(
    to_char(new.slot_at at time zone 'Asia/Kolkata', 'DD Mon, HH12:MI AM'),
    'NO TIME SET — needs scheduling'
  );

  update public.crm_clients
     set status = 'visit_pending',
         updated_at = now()
   where id = cid
     and status not in ('closed_by_us', 'closed_outside');

  insert into public.crm_activities (client_id, actor_email, type, body, meta)
  values (
    cid,
    '',
    'visit',
    case
      when new.slot_at is null
        then 'Wants a visit · ' || new.property_id || ' · ' || slot_label
      else 'Booked a visit · ' || new.property_id || ' · ' || slot_label
    end,
    jsonb_build_object(
      'property_id', new.property_id,
      'slot_at', new.slot_at,
      'kind', new.kind,
      'needs_scheduling', new.slot_at is null
    )
  );

  if new.slot_at is null then
    insert into public.crm_notifications (for_email, type, title, body, client_id)
    values (
      'yatharth200018@gmail.com',
      'visit',
      'Visit needs a time',
      'A tenant asked for the next available slot on ' || new.property_id ||
      ' — the lister has published no visit times.',
      cid
    );
  end if;

  -- 'visit_scheduled' overwrites a like or a dislike, because it is the newer
  -- and stronger signal — the one an agent should act on.
  insert into public.crm_shortlists (client_id, property_id, status, reacted_at)
  values (cid, new.property_id, 'visit_scheduled', now())
  on conflict (client_id, property_id) do update
    set status = 'visit_scheduled', reacted_at = now();

  return new;
end;
$$;

drop trigger if exists on_visit_booking_crm on public.visit_bookings;
create trigger on_visit_booking_crm
  after insert or update of slot_at on public.visit_bookings
  for each row
  execute function public.crm_record_visit_booking();
