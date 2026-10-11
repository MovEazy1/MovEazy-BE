-- The website's "Contact us" form, into the CRM.
--
-- The form on /contact used to write to a Firestore collection nobody read.
-- Now a message lands here, shows under CRM → Notifications → Messages until
-- someone marks it done, and — when the number is already a CRM client — is
-- noted on that client's timeline too.
--
-- Anyone can send (signed in or not), so it's bounded: a valid Indian mobile,
-- short fields, five messages a number a day, and a ceiling on the whole form
-- an hour. Nobody reads the table directly; staff go through the functions.
--
-- Safe to re-run.

begin;

create table if not exists public.site_contact_messages (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(name) between 1 and 80),
  phone      text not null check (phone ~ '^[6-9][0-9]{9}$'),
  email      text not null default '' check (char_length(email) <= 120),
  topic      text not null default 'other' check (topic in ('tenant', 'owner', 'partner', 'payment', 'other')),
  message    text not null check (char_length(message) between 1 and 1000),
  client_id  uuid references public.crm_clients(id) on delete set null,
  status     text not null default 'new' check (status in ('new', 'done')),
  done_by    text not null default '',
  done_at    timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists site_contact_messages_inbox_idx on public.site_contact_messages (status, created_at desc);
create index if not exists site_contact_messages_phone_idx on public.site_contact_messages (phone, created_at desc);

alter table public.site_contact_messages enable row level security;
revoke all on table public.site_contact_messages from anon, authenticated;

/** Send a message from the website. → {ok}. */
create or replace function public.submit_contact_message(
  p_name    text,
  p_phone   text,
  p_email   text default '',
  p_topic   text default 'other',
  p_message text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name  text := left(btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g')), 80);
  v_phone text := public.normalize_mobile(p_phone);
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_topic text := coalesce(nullif(btrim(p_topic), ''), 'other');
  v_msg   text := btrim(coalesce(p_message, ''));
  v_cid   uuid;
begin
  if v_name = '' then
    raise exception 'Please tell us your name.' using errcode = '22023';
  end if;
  if v_phone = '' then
    raise exception 'Please enter a valid 10-digit mobile number.' using errcode = '22023';
  end if;
  if v_email <> '' and (char_length(v_email) > 120 or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') then
    raise exception 'That email doesn''t look right.' using errcode = '22023';
  end if;
  if v_topic not in ('tenant', 'owner', 'partner', 'payment', 'other') then
    v_topic := 'other';
  end if;
  if v_msg = '' then
    raise exception 'Please write a message.' using errcode = '22023';
  end if;
  v_msg := left(v_msg, 1000);

  if (select count(*) from public.site_contact_messages
       where phone = v_phone and created_at > now() - interval '1 day') >= 5 then
    raise exception 'We have your messages — our team will get back to you soon.' using errcode = '54000';
  end if;
  if (select count(*) from public.site_contact_messages where created_at > now() - interval '1 hour') >= 300 then
    raise exception 'Too many messages right now — please WhatsApp us instead.' using errcode = '54000';
  end if;

  select c.id into v_cid from public.crm_clients c where c.phone = v_phone order by c.created_at limit 1;

  insert into public.site_contact_messages (name, phone, email, topic, message, client_id)
  values (v_name, v_phone, v_email, v_topic, v_msg, v_cid);

  -- Already someone we know: it belongs on their timeline as well.
  if v_cid is not null then
    insert into public.crm_activities (client_id, actor_email, type, body, meta)
    values (v_cid, '', 'note', 'Message from the website: ' || v_msg,
            jsonb_build_object('source', 'contact_form', 'topic', v_topic, 'email', v_email));
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

/** The CRM's list: new ones (or done ones), newest first. */
create or replace function public.crm_contact_messages(p_status text default 'new')
returns setof public.site_contact_messages
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  return query
    select * from public.site_contact_messages m
     where m.status = coalesce(nullif(p_status, ''), 'new')
     order by m.created_at desc
     limit 300;
end;
$$;

/** Mark a message done (or back to new). */
create or replace function public.crm_contact_message_set(p_id uuid, p_done boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  update public.site_contact_messages
     set status  = case when p_done then 'done' else 'new' end,
         done_by = case when p_done then coalesce(auth.jwt() ->> 'email', '') else '' end,
         done_at = case when p_done then now() end
   where id = p_id;
end;
$$;

revoke all on function public.submit_contact_message(text, text, text, text, text) from public;
revoke all on function public.crm_contact_messages(text) from public, anon;
revoke all on function public.crm_contact_message_set(uuid, boolean) from public, anon;
grant execute on function public.submit_contact_message(text, text, text, text, text) to anon, authenticated;
grant execute on function public.crm_contact_messages(text) to authenticated;
grant execute on function public.crm_contact_message_set(uuid, boolean) to authenticated;

commit;
