-- WhatsApp → MovEazy listings: a flat a marked number sends to our WhatsApp
-- Business number becomes a draft listing for the team to approve.
-- (MovEazy-FE api/whatsapp-webhook.js, api/whatsapp-process.js,
-- api/whatsapp-connect.js; pages/crm/CrmWhatsAppPage.jsx; the property form's
-- ?wa=<draft> prefill.)
--
--   wa_connection       our number on Meta's Cloud API (coexistence: the same
--                       number stays on the WhatsApp Business app). Its token is
--                       readable by the service role only.
--   wa_marked_numbers   who we read: this list + every approved partner. A
--                       message from anyone else is never stored.
--   wa_batches          one sender's messages close together — the text and
--                       the photos of a flat arrive as separate messages — read
--                       as one once they have been quiet for 4 minutes. A pasted
--                       message (CRM inbox) is a batch of its own.
--   wa_messages         each message; photos and videos copied into storage.
--   wa_drafts           what AI read from a batch: a flat to list (opened in the
--                       property form, published by a person), or "this one is
--                       rented" with the sender's listings it may mean.
--
-- Nothing is published here: every draft waits for a person. A flat from a
-- partner is listed as theirs when published (partner_listings).
--
-- Safe to re-run.

begin;

-- ── Tables ─────────────────────────────────────────────────────────────────

create table if not exists public.wa_connection (
  id              int primary key default 1 check (id = 1),
  waba_id         text not null default '',
  phone_number_id text not null default '',
  display_phone   text not null default '',
  verified_name   text not null default '',
  access_token    text not null default '',
  connected_by    text not null default '',
  connected_at    timestamptz,
  last_webhook_at timestamptz
);

create table if not exists public.wa_marked_numbers (
  phone10  text primary key check (phone10 ~ '^[6-9][0-9]{9}$'),
  label    text not null default '',
  added_by text not null default '',
  added_at timestamptz not null default now()
);

create table if not exists public.wa_batches (
  id               uuid primary key default gen_random_uuid(),
  source           text not null default 'whatsapp' check (source in ('whatsapp', 'paste')),
  from10           text not null default '',
  sender_name      text not null default '',
  sender_kind      text not null default 'marked' check (sender_kind in ('partner', 'marked', 'team')),
  partner_id       uuid references auth.users (id) on delete set null,
  crm_broker_id    uuid,
  state            text not null default 'collecting'
                     check (state in ('collecting', 'queued', 'parsing', 'parsed', 'error')),
  attempts         int not null default 0,
  last_message_at  timestamptz not null default now(),
  parse_started_at timestamptz,
  parsed_at        timestamptz,
  error            text not null default '',
  created_by       text not null default '',
  created_at       timestamptz not null default now()
);
create index if not exists wa_batches_open_idx on public.wa_batches (state, last_message_at);
create index if not exists wa_batches_sender_idx on public.wa_batches (from10, last_message_at desc);

create table if not exists public.wa_messages (
  id          text primary key,
  batch_id    uuid not null references public.wa_batches (id) on delete cascade,
  kind        text not null check (kind in ('text', 'image', 'video', 'other')),
  body        text not null default '',
  media_id    text not null default '',
  mime        text not null default '',
  media_url   text not null default '',
  media_error text not null default '',
  sent_at     timestamptz not null default now(),
  created_at  timestamptz not null default now()
);
create index if not exists wa_messages_batch_idx on public.wa_messages (batch_id, sent_at, created_at);

create table if not exists public.wa_drafts (
  id          uuid primary key default gen_random_uuid(),
  batch_id    uuid not null references public.wa_batches (id) on delete cascade,
  idx         int not null default 0,
  kind        text not null default 'property' check (kind in ('property', 'rented')),
  fields      jsonb not null default '{}',
  images      text[] not null default '{}',
  missing     text[] not null default '{}',
  candidates  jsonb not null default '[]',
  status      text not null default 'pending'
                check (status in ('pending', 'published', 'dismissed', 'rented_marked')),
  property_id text,
  decided_by  text not null default '',
  decided_at  timestamptz,
  created_at  timestamptz not null default now()
);
create index if not exists wa_drafts_status_idx on public.wa_drafts (status, created_at desc);
create index if not exists wa_drafts_batch_idx on public.wa_drafts (batch_id);

alter table public.wa_connection enable row level security;
alter table public.wa_marked_numbers enable row level security;
alter table public.wa_batches enable row level security;
alter table public.wa_messages enable row level security;
alter table public.wa_drafts enable row level security;
revoke all on public.wa_connection, public.wa_marked_numbers, public.wa_batches, public.wa_messages, public.wa_drafts
  from public, anon, authenticated;

-- ── Who we read ────────────────────────────────────────────────────────────

/** A marked sender — a partner first, then the CRM list — or no row. */
create or replace function public.wa_sender(p_from text)
returns table (kind text, label text, partner_id uuid, crm_broker_id uuid)
language sql
stable
security definer
set search_path = public
as $$
  with n as (select public.normalize_mobile(p_from) p)
  select x.kind, x.label, x.partner_id,
         (select b.id from public.crm_brokers b, n where b.phone_norm = n.p and n.p <> '' order by b.last_used_at desc nulls last limit 1)
    from (
      select 'partner'::text kind, coalesce(nullif(bp.name, ''), nullif(bp.agency, ''), 'Partner') label, bp.user_id partner_id, 0 rank
        from public.broker_partners bp, n
       where bp.status = 'approved' and n.p <> '' and public.normalize_mobile(bp.phone) = n.p
      union all
      select 'marked', coalesce(nullif(m.label, ''), 'Marked number'), null::uuid, 1
        from public.wa_marked_numbers m, n
       where m.phone10 = n.p
    ) x
   order by x.rank
   limit 1;
$$;

-- ── Intake (the webhook, as the service role) ─────────────────────────────

/**
 * One incoming message: { id, from, name, kind: text|image|video|other, body,
 * media_id, mime, sent_at }. Stored only when the sender is marked; added to
 * their open batch (a message within 10 minutes of the last) or a new one.
 * → { stored, message, batch, media } (media: fetch and attach the file).
 */
create or replace function public.wa_intake_message(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  f10  text := public.normalize_mobile(p->>'from');
  s    record;
  b    uuid;
  at   timestamptz := coalesce(nullif(p->>'sent_at', '')::timestamptz, now());
  k    text := case when p->>'kind' in ('text', 'image', 'video') then p->>'kind' else 'other' end;
  mid  text := left(coalesce(p->>'id', ''), 200);
begin
  update public.wa_connection set last_webhook_at = now() where id = 1;
  if mid = '' or f10 = '' then return jsonb_build_object('stored', false, 'reason', 'no id or sender'); end if;
  select * into s from public.wa_sender(f10);
  if s.kind is null then return jsonb_build_object('stored', false, 'reason', 'not marked'); end if;
  if exists (select 1 from public.wa_messages where id = mid) then
    return jsonb_build_object('stored', false, 'reason', 'duplicate');
  end if;

  select id into b from public.wa_batches
   where source = 'whatsapp' and from10 = f10 and state = 'collecting'
     and last_message_at > at - interval '10 minutes'
   order by last_message_at desc limit 1
   for update;
  if b is null then
    insert into public.wa_batches (source, from10, sender_name, sender_kind, partner_id, crm_broker_id, last_message_at)
    values ('whatsapp', f10, left(coalesce(nullif(p->>'name', ''), s.label), 120), s.kind, s.partner_id, s.crm_broker_id, at)
    returning id into b;
  else
    update public.wa_batches set last_message_at = greatest(last_message_at, at) where id = b;
  end if;

  insert into public.wa_messages (id, batch_id, kind, body, media_id, mime, sent_at)
  values (mid, b, k, left(coalesce(p->>'body', ''), 8000), left(coalesce(p->>'media_id', ''), 200), left(coalesce(p->>'mime', ''), 100), at);

  return jsonb_build_object('stored', true, 'message', mid, 'batch', b,
    'media', k in ('image', 'video') and coalesce(p->>'media_id', '') <> '');
end;
$$;

/** The copied file for a photo / video message, or why it couldn't be. */
create or replace function public.wa_set_media(p_message text, p_url text, p_error text default '')
returns void
language sql
security definer
set search_path = public
as $$
  update public.wa_messages
     set media_url = left(coalesce(p_url, ''), 1000), media_error = left(coalesce(p_error, ''), 300)
   where id = p_message;
$$;

/** The token and number id, for downloading media (service role only). */
create or replace function public.wa_connection_get()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select to_jsonb(c) from public.wa_connection c where c.id = 1;
$$;

/** After Meta's sign-up (api/whatsapp-connect.js). */
create or replace function public.wa_connection_save(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.wa_connection (id, waba_id, phone_number_id, display_phone, verified_name, access_token, connected_by, connected_at)
  values (1, coalesce(p->>'waba_id', ''), coalesce(p->>'phone_number_id', ''), coalesce(p->>'display_phone', ''),
          coalesce(p->>'verified_name', ''), coalesce(p->>'access_token', ''), lower(coalesce(p->>'connected_by', '')), now())
  on conflict (id) do update
    set waba_id = excluded.waba_id, phone_number_id = excluded.phone_number_id, display_phone = excluded.display_phone,
        verified_name = excluded.verified_name, access_token = excluded.access_token,
        connected_by = excluded.connected_by, connected_at = now();
  return jsonb_build_object('ok', true);
end;
$$;

-- ── Reading (api/whatsapp-process.js, as the service role) ────────────────

/**
 * Up to p_limit batches ready to read, claimed: pasted ones, ones quiet for 4
 * minutes (with their files copied, or 5 minutes given up on), and reads that
 * died midway (after 5 minutes, 3 tries at most).
 */
create or replace function public.wa_claim_ready(p_limit int default 4)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  ids uuid[];
begin
  select coalesce(array_agg(id), '{}') into ids from (
    select b.id from public.wa_batches b
     where (b.state = 'queued'
            or (b.state = 'collecting' and b.last_message_at < now() - interval '4 minutes'
                and not exists (select 1 from public.wa_messages m
                                 where m.batch_id = b.id and m.kind in ('image', 'video')
                                   and m.media_url = '' and m.media_error = '' and m.created_at > now() - interval '5 minutes'))
            or (b.state = 'parsing' and b.parse_started_at < now() - interval '5 minutes'))
       and b.attempts < 3
     order by b.last_message_at
     limit greatest(1, least(coalesce(p_limit, 4), 10))
     for update skip locked
  ) x;
  update public.wa_batches set state = 'parsing', parse_started_at = now(), attempts = attempts + 1 where id = any (ids);

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', b.id, 'attempts', b.attempts, 'source', b.source, 'from10', b.from10, 'sender_name', b.sender_name, 'sender_kind', b.sender_kind,
      'messages', (select coalesce(jsonb_agg(jsonb_build_object('kind', m.kind, 'body', m.body, 'media_url', m.media_url, 'sent_at', m.sent_at)
                                             order by m.sent_at, m.created_at), '[]'::jsonb)
                     from public.wa_messages m where m.batch_id = b.id)) order by b.last_message_at)
      from public.wa_batches b where b.id = any (ids)), '[]'::jsonb);
end;
$$;

/** The sender's live listings a "rented" message may mean, best match first. */
create or replace function public.wa_rented_candidates(p_batch uuid, p_fields jsonb)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with b as (select * from public.wa_batches where id = p_batch),
  mine as (
    select i.property_id from public.inventory i, b
     where i.status = 'published'
       and ((b.partner_id is not null and i.broker_id = b.partner_id)
            or (b.from10 <> '' and public.normalize_mobile(i.phone) = b.from10))
    union
    select pl.property_id from public.partner_listings pl, b where b.partner_id is not null and pl.broker_id = b.partner_id
    union
    select ip.property_id from public.inventory_private ip, b where b.from10 <> '' and public.normalize_mobile(ip.poc_phone) = b.from10
    union
    select d.property_id from public.wa_drafts d join public.wa_batches ob on ob.id = d.batch_id, b
     where d.property_id is not null and ob.from10 = b.from10 and b.from10 <> ''
  )
  select coalesce(jsonb_agg(jsonb_build_object('property_id', x.property_id, 'title', x.title, 'area', x.area,
                                               'flat_type', x.flat_type, 'rent', x.rent) order by x.score desc, x.created_at desc), '[]'::jsonb)
    from (
      select i.property_id, i.title, i.area, i.flat_type, i.rent, i.created_at,
             (case when coalesce(p_fields->>'area', '') <> '' and lower(i.area) = lower(p_fields->>'area') then 2 else 0 end
              + case when coalesce(p_fields->>'flat_type', '') <> '' and i.flat_type = p_fields->>'flat_type' then 2 else 0 end
              + case when coalesce(p_fields->>'building_name', '') <> ''
                          and position(lower(p_fields->>'building_name') in lower(coalesce(i.title, '') || ' ' || coalesce(i.full_address, ''))) > 0
                     then 3 else 0 end) score
        from public.inventory i
       where i.status = 'published' and i.property_id in (select property_id from mine)
       order by score desc, i.created_at desc
       limit 6
    ) x;
$$;

/**
 * What AI read: { items: [{ kind: property|rented, fields, images, missing }] }
 * or { error }. A batch of photos alone joins the sender's newest open draft
 * from the last 2 hours (the text came in an earlier batch), or becomes a
 * draft of its own; a batch with nothing in it (a "hi") leaves no draft.
 */
create or replace function public.wa_save_parse(p_batch uuid, p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b      public.wa_batches;
  it     jsonb;
  i      int := 0;
  made   int := 0;
  photos text[];
  target uuid;
  k      text;
begin
  select * into b from public.wa_batches where id = p_batch for update;
  if b.id is null then return jsonb_build_object('ok', false, 'reason', 'no batch'); end if;

  if coalesce(p->>'error', '') <> '' then
    update public.wa_batches
       set state = case when attempts >= 3 then 'error' else 'queued' end, error = left(p->>'error', 500)
     where id = b.id;
    return jsonb_build_object('ok', false, 'retry', b.attempts < 3);
  end if;

  delete from public.wa_drafts where batch_id = b.id and status = 'pending';
  for it in select * from jsonb_array_elements(coalesce(p->'items', '[]'::jsonb)) loop
    k := it->>'kind';
    continue when k not in ('property', 'rented');
    insert into public.wa_drafts (batch_id, idx, kind, fields, images, missing, candidates)
    values (b.id, i, k, coalesce(it->'fields', '{}'::jsonb),
            coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(it->'images', '[]'::jsonb)) x where x <> ''), '{}'),
            coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(it->'missing', '[]'::jsonb)) x), '{}'),
            case when k = 'rented' then public.wa_rented_candidates(b.id, coalesce(it->'fields', '{}'::jsonb)) else '[]'::jsonb end);
    i := i + 1;
    made := made + 1;
  end loop;

  if made = 0 then
    select coalesce(array_agg(m.media_url order by m.sent_at, m.created_at), '{}') into photos
      from public.wa_messages m where m.batch_id = b.id and m.media_url <> '';
    if cardinality(photos) > 0 then
      select d.id into target from public.wa_drafts d join public.wa_batches ob on ob.id = d.batch_id
       where d.status = 'pending' and d.kind = 'property' and ob.id <> b.id and ob.source = b.source
         and ob.from10 = b.from10 and ob.from10 <> '' and d.created_at > now() - interval '2 hours'
       order by d.created_at desc limit 1;
      if target is not null then
        update public.wa_drafts set images = images || photos where id = target;
      else
        insert into public.wa_drafts (batch_id, kind, images, missing)
        values (b.id, 'property', photos, '{Locality,Rent,"Flat type",Furnishing}');
        made := 1;
      end if;
    end if;
  end if;

  update public.wa_batches set state = 'parsed', parsed_at = now(), error = '' where id = b.id;
  return jsonb_build_object('ok', true, 'drafts', made, 'joined', target);
end;
$$;

/**
 * Is there anything to read? Then ask the site to read it (pg_cron, every 2
 * minutes, through pg_net). Quiet when nothing is waiting.
 */
create or replace function public.wa_process_poke()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.wa_batches b
                  where b.attempts < 3
                    and (b.state = 'queued'
                         or (b.state = 'collecting' and b.last_message_at < now() - interval '4 minutes')
                         or (b.state = 'parsing' and b.parse_started_at < now() - interval '5 minutes'))) then
    return false;
  end if;
  execute $q$select net.http_post(url := 'https://www.moveazy.co.in/api/whatsapp-process',
                                 body := '{}'::jsonb, headers := '{"content-type":"application/json"}'::jsonb)$q$;
  return true;
exception when others then
  raise notice 'whatsapp poke: %', sqlerrm;
  return false;
end;
$$;

-- ── The CRM inbox ─────────────────────────────────────────────────────────

create or replace function public.wa_require_writer()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.has_admin_scope('crm.properties.write') then
    raise exception 'You need permission to add listings.' using errcode = '42501';
  end if;
end;
$$;

/** One draft with its sender and the messages it was read from. */
create or replace function public.wa_draft_json(d public.wa_drafts)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select to_jsonb(d) || jsonb_build_object(
    'source', b.source, 'from10', b.from10, 'sender_name', b.sender_name, 'sender_kind', b.sender_kind,
    'partner_id', b.partner_id, 'crm_broker_id', b.crm_broker_id, 'received_at', b.last_message_at,
    'text', (select coalesce(string_agg(nullif(m.body, ''), E'\n\n' order by m.sent_at, m.created_at), '')
               from public.wa_messages m where m.batch_id = b.id))
    from public.wa_batches b where b.id = d.batch_id;
$$;

/**
 * The inbox: drafts waiting (and the last 14 days of decided ones), batches
 * still being read or that failed, the connection and the counts.
 */
create or replace function public.crm_wa_inbox()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then raise exception 'Not allowed.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'drafts', (select coalesce(jsonb_agg(public.wa_draft_json(d) order by d.created_at desc, d.idx), '[]'::jsonb)
                 from public.wa_drafts d
                where d.status = 'pending' or d.decided_at > now() - interval '14 days'),
    'reading', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'state', b.state, 'sender_name', b.sender_name,
                                                             'from10', b.from10, 'error', b.error, 'last_message_at', b.last_message_at,
                                                             'messages', (select count(*) from public.wa_messages m where m.batch_id = b.id))
                                          order by b.last_message_at desc), '[]'::jsonb)
                  from public.wa_batches b
                 where b.state in ('collecting', 'queued', 'parsing') or (b.state = 'error' and b.created_at > now() - interval '14 days')),
    'connection', (select jsonb_build_object('connected', c.access_token <> '', 'display_phone', c.display_phone,
                                             'verified_name', c.verified_name, 'connected_at', c.connected_at,
                                             'last_webhook_at', c.last_webhook_at)
                     from public.wa_connection c where c.id = 1),
    'pending', (select count(*) from public.wa_drafts where status = 'pending'));
end;
$$;

/** Drafts waiting — the rail's badge. */
create or replace function public.crm_wa_pending_count()
returns int
language sql
stable
security definer
set search_path = public
as $$
  select case when public.is_crm_staff() then (select count(*)::int from public.wa_drafts where status = 'pending') else 0 end;
$$;

/** One draft, for the property form's prefill. */
create or replace function public.crm_wa_draft(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare d public.wa_drafts;
begin
  perform public.wa_require_writer();
  select * into d from public.wa_drafts where id = p_id;
  if d.id is null then raise exception 'That WhatsApp draft is gone.' using errcode = 'P0002'; end if;
  return public.wa_draft_json(d);
end;
$$;

/**
 * The form published the draft as p_property. A partner's flat becomes their
 * listing (partner app → My listings) and they hear it is live.
 */
create or replace function public.crm_wa_draft_published(p_id uuid, p_property text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  d public.wa_drafts;
  b public.wa_batches;
begin
  perform public.wa_require_writer();
  select * into d from public.wa_drafts where id = p_id for update;
  if d.id is null then raise exception 'That WhatsApp draft is gone.' using errcode = 'P0002'; end if;
  if not exists (select 1 from public.inventory where property_id = p_property) then
    raise exception 'No listing %.', p_property using errcode = 'P0002';
  end if;
  select * into b from public.wa_batches where id = d.batch_id;

  update public.wa_drafts
     set status = 'published', property_id = p_property, decided_by = lower(coalesce(auth.jwt() ->> 'email', '')), decided_at = now()
   where id = d.id;

  if b.partner_id is not null then
    insert into public.partner_listings (property_id, broker_id) values (p_property, b.partner_id)
    on conflict (property_id) do nothing;
    update public.inventory set broker_id = b.partner_id, posted_by = 'broker' where property_id = p_property;
    insert into public.partner_notifications (broker_id, kind, title, body, link)
    values (b.partner_id, 'listing_live', 'Your flat is live on MovEazy: ' || p_property,
            'The flat you sent us on WhatsApp is now listed. Enquiries reach you through MovEazy.', '/property/' || p_property);
  end if;
  return jsonb_build_object('ok', true, 'partner', b.partner_id is not null);
end;
$$;

create or replace function public.crm_wa_draft_dismiss(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.wa_require_writer();
  update public.wa_drafts
     set status = 'dismissed', decided_by = lower(coalesce(auth.jwt() ->> 'email', '')), decided_at = now()
   where id = p_id and status = 'pending';
end;
$$;

/** "That flat is rented": mark the listing the team picked. */
create or replace function public.crm_wa_mark_rented(p_id uuid, p_property text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare d public.wa_drafts;
begin
  perform public.wa_require_writer();
  select * into d from public.wa_drafts where id = p_id and kind = 'rented' for update;
  if d.id is null then raise exception 'That WhatsApp draft is gone.' using errcode = 'P0002'; end if;
  update public.inventory set status = 'rented', updated_at = now() where property_id = p_property;
  if not found then raise exception 'No listing %.', p_property using errcode = 'P0002'; end if;
  update public.wa_drafts
     set status = 'rented_marked', property_id = p_property, decided_by = lower(coalesce(auth.jwt() ->> 'email', '')), decided_at = now()
   where id = d.id;
end;
$$;

/** A message pasted into the inbox (photos already uploaded), read like any other. */
create or replace function public.crm_wa_paste(p_text text, p_images text[] default '{}', p_from text default '')
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  s   record;
  f10 text := public.normalize_mobile(p_from);
  b   uuid;
  u   text;
  n   int := 0;
begin
  perform public.wa_require_writer();
  if coalesce(trim(p_text), '') = '' and coalesce(cardinality(p_images), 0) = 0 then
    raise exception 'Paste the message or add photos.' using errcode = '22023';
  end if;
  -- No row (no number, or not marked) leaves every field null.
  select * into s from public.wa_sender(f10);
  insert into public.wa_batches (source, from10, sender_name, sender_kind, partner_id, crm_broker_id, state, created_by)
  values ('paste', f10, coalesce(s.label, ''), coalesce(s.kind, 'team'), s.partner_id,
          coalesce(s.crm_broker_id, (select x.id from public.crm_brokers x where f10 <> '' and x.phone_norm = f10 limit 1)),
          'queued', lower(coalesce(auth.jwt() ->> 'email', '')))
  returning id into b;
  if coalesce(trim(p_text), '') <> '' then
    insert into public.wa_messages (id, batch_id, kind, body) values ('paste-' || gen_random_uuid(), b, 'text', left(p_text, 8000));
  end if;
  foreach u in array coalesce(p_images, '{}') loop
    n := n + 1;
    exit when n > 30;
    insert into public.wa_messages (id, batch_id, kind, media_url, sent_at)
    values ('paste-' || gen_random_uuid(), b, case when u ~* '\.(mp4|mov|m4v|webm|3gp)(\?|$)' then 'video' else 'image' end,
            left(u, 1000), now() + make_interval(secs => n));
  end loop;
  return b;
end;
$$;

/** Read a failed batch again. */
create or replace function public.crm_wa_retry(p_batch uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.wa_require_writer();
  update public.wa_batches set state = 'queued', attempts = 0, error = '' where id = p_batch and state in ('error', 'parsed');
end;
$$;

-- ── Marked numbers ─────────────────────────────────────────────────────────

create or replace function public.crm_wa_numbers()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then raise exception 'Not allowed.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'marked', (select coalesce(jsonb_agg(to_jsonb(m) order by m.added_at desc), '[]'::jsonb) from public.wa_marked_numbers m),
    'partners', (select coalesce(jsonb_agg(jsonb_build_object('name', coalesce(nullif(bp.name, ''), bp.agency), 'phone10', public.normalize_mobile(bp.phone))
                                           order by bp.name), '[]'::jsonb)
                   from public.broker_partners bp where bp.status = 'approved' and public.normalize_mobile(bp.phone) <> ''));
end;
$$;

create or replace function public.crm_wa_number_save(p_phone text, p_label text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare f10 text := public.normalize_mobile(p_phone);
begin
  perform public.wa_require_writer();
  if f10 = '' then raise exception 'Enter a 10-digit Indian mobile number.' using errcode = '22023'; end if;
  insert into public.wa_marked_numbers (phone10, label, added_by)
  values (f10, left(coalesce(trim(p_label), ''), 80), lower(coalesce(auth.jwt() ->> 'email', '')))
  on conflict (phone10) do update set label = excluded.label;
  return (select to_jsonb(m) from public.wa_marked_numbers m where m.phone10 = f10);
end;
$$;

create or replace function public.crm_wa_number_remove(p_phone text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.wa_require_writer();
  delete from public.wa_marked_numbers where phone10 = public.normalize_mobile(p_phone);
end;
$$;

-- ── Grants ────────────────────────────────────────────────────────────────

do $$
declare f text;
begin
  foreach f in array array[
    'wa_sender(text)', 'wa_intake_message(jsonb)', 'wa_set_media(text, text, text)', 'wa_connection_get()',
    'wa_connection_save(jsonb)', 'wa_claim_ready(int)', 'wa_rented_candidates(uuid, jsonb)', 'wa_save_parse(uuid, jsonb)',
    'wa_process_poke()', 'wa_require_writer()', 'wa_draft_json(public.wa_drafts)'
  ] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
  foreach f in array array[
    'wa_intake_message(jsonb)', 'wa_set_media(text, text, text)', 'wa_connection_get()', 'wa_connection_save(jsonb)',
    'wa_claim_ready(int)', 'wa_save_parse(uuid, jsonb)'
  ] loop
    if exists (select 1 from pg_roles where rolname = 'service_role') then
      execute format('grant execute on function public.%s to service_role', f);
    end if;
  end loop;
  foreach f in array array[
    'crm_wa_inbox()', 'crm_wa_pending_count()', 'crm_wa_draft(uuid)', 'crm_wa_draft_published(uuid, text)',
    'crm_wa_draft_dismiss(uuid)', 'crm_wa_mark_rented(uuid, text)', 'crm_wa_paste(text, text[], text)', 'crm_wa_retry(uuid)',
    'crm_wa_numbers()', 'crm_wa_number_save(text, text)', 'crm_wa_number_remove(text)'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end;
$$;

commit;

-- ── Every 2 minutes: read what's waiting (outside the transaction: the
--    extensions may be missing, and that must not undo the rest) ──────────

do $$
begin
  begin
    create extension if not exists pg_net;
  exception when others then
    raise notice 'pg_net unavailable (%); the CRM inbox reads waiting messages when opened.', sqlerrm;
  end;
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      perform cron.unschedule('moveazy-whatsapp-read');
    exception when others then null;
    end;
    execute $q$select cron.schedule('moveazy-whatsapp-read', '*/2 * * * *', 'select public.wa_process_poke()')$q$;
  end if;
exception when others then
  raise notice 'Could not schedule WhatsApp reading (%); the CRM inbox reads waiting messages when opened.', sqlerrm;
end;
$$;
