-- Capture a tenant before they have an account.
--
-- The funnel used to open with a Google wall: the first meaningful click threw
-- up an OAuth popup, and everyone who wasn't ready to hand over an account
-- left without a trace. This table is what replaces that wall — a phone number
-- up front, the preference questionnaire next, and the signup gate moved to
-- the end, after the work is done and there is something to show for it.
--
-- Identity before signup is the browser, not the phone. A number typed into a
-- form is unverified: keying resumable state to it would let anyone type a
-- stranger's number and read their answers back. So the row is keyed by
-- lead_key, a 128-bit random value the browser generates and keeps in
-- localStorage, which is unguessable and never leaves that device. The phone
-- is data we collect, not a credential we trust.
--
-- Nothing reaches this table directly. RLS grants no access to anon or
-- authenticated; every read and write goes through the security-definer
-- functions below, the same shape as record_share_open, which exists for the
-- same reason: the person doing the writing has no session.

create table if not exists public.lead_intake (
  -- 32 hex characters from crypto.getRandomValues, minted in the browser.
  lead_key      text primary key,

  -- The analytics id from sessionSync.js. Not the key: it is short, seeded
  -- from Math.random and already written to user_sessions, so it is carried
  -- only so a lead can be lined up against that visitor's sessions.
  anon_id       text default '',

  name          text default '',
  phone         text default '',            -- normalized to 10 digits
  prefs         jsonb not null default '{}'::jsonb,
  step          int not null default 0,     -- how far through the questionnaire
  completed     boolean not null default false,

  -- Where this person came from, so a lead that never signs up is still
  -- attributable. Mirrors what lib/attribution.js stamps onto an account.
  utm           jsonb default '{}'::jsonb,

  crm_client_id uuid references public.crm_clients(id) on delete set null,
  claimed_by    uuid references auth.users(id) on delete set null,
  claimed_at    timestamptz,

  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists lead_intake_phone_idx
  on public.lead_intake (phone) where phone <> '';
create index if not exists lead_intake_unclaimed_idx
  on public.lead_intake (updated_at desc) where claimed_by is null;

alter table public.lead_intake enable row level security;

-- Deliberately only one policy, and it is read-only for staff. No anon or
-- authenticated policy exists, so the table is unreachable from PostgREST and
-- the functions below are the only way in.
drop policy if exists "crm staff read leads" on public.lead_intake;
create policy "crm staff read leads"
  on public.lead_intake for select
  to authenticated
  using (public.is_crm_staff());


/**
 * 10-digit Indian mobile, or '' if it isn't one.
 * Same rule as normalizeIndianMobile in the frontend, kept here because this
 * is the last point before storage and the client cannot be trusted with it.
 */
create or replace function public.normalize_mobile(raw text)
returns text
language plpgsql
immutable
as $$
declare
  digits text := regexp_replace(coalesce(raw, ''), '\D', '', 'g');
  local  text;
begin
  local := case
             when length(digits) > 10 and left(digits, 2) = '91' then right(digits, 10)
             else digits
           end;
  return case when local ~ '^[6-9]\d{9}$' then local else '' end;
end;
$$;


/**
 * Create or update one browser's lead, and mirror it into the CRM.
 *
 * Called on every step of the questionnaire, so it has to be cheap and
 * idempotent. Null arguments mean "leave this alone" rather than "clear it",
 * so a later step saving only its own answer cannot wipe the name captured
 * three steps earlier.
 *
 * The CRM row is the entire point of the restructure: a lead with a phone
 * number is visible to the team the moment the number is typed, whether or not
 * that person ever comes back to finish. Staff-owned fields — status,
 * temperature, assigned_to, notes — are never touched after the row exists,
 * because a person may have worked the lead since.
 */
create or replace function public.save_lead_intake(
  p_lead_key  text,
  p_anon_id   text    default null,
  p_name      text    default null,
  p_phone     text    default null,
  p_prefs     jsonb   default null,
  p_step      int     default null,
  p_completed boolean default null,
  p_utm       jsonb   default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phone  text;
  v_name   text;
  v_client uuid;
  v_source text;
begin
  -- A short key means a caller that isn't our browser code; refuse rather than
  -- create a row nobody can ever read back.
  if p_lead_key is null or length(p_lead_key) < 24 or length(p_lead_key) > 128 then
    raise exception 'invalid lead key';
  end if;

  v_phone := public.normalize_mobile(p_phone);
  v_name  := nullif(btrim(coalesce(p_name, '')), '');

  insert into public.lead_intake as l
    (lead_key, anon_id, name, phone, prefs, step, completed, utm)
  values
    (p_lead_key,
     coalesce(left(p_anon_id, 120), ''),
     coalesce(v_name, ''),
     v_phone,
     coalesce(p_prefs, '{}'::jsonb),
     coalesce(p_step, 0),
     coalesce(p_completed, false),
     coalesce(p_utm, '{}'::jsonb))
  on conflict (lead_key) do update set
    anon_id    = coalesce(nullif(left(p_anon_id, 120), ''), l.anon_id),
    name       = coalesce(v_name, l.name),
    phone      = case when v_phone <> '' then v_phone else l.phone end,
    prefs      = coalesce(p_prefs, l.prefs),
    step       = greatest(coalesce(p_step, l.step), l.step),
    -- Only ever latches true: re-opening the questionnaire to change an
    -- answer must not un-complete a lead the CRM has already acted on.
    completed  = l.completed or coalesce(p_completed, false),
    utm        = case when p_utm is not null and p_utm <> '{}'::jsonb then p_utm else l.utm end,
    updated_at = now();

  select phone, name, crm_client_id into v_phone, v_name, v_client
  from public.lead_intake where lead_key = p_lead_key;

  -- No number yet: nothing worth showing a salesperson.
  if v_phone = '' then
    return;
  end if;

  -- Attribution decides the source, so a lead from the Facebook share lands in
  -- the CRM already labelled facebook rather than as anonymous web traffic.
  select coalesce(nullif(utm ->> 'source', ''), 'website')
    into v_source from public.lead_intake where lead_key = p_lead_key;

  if v_client is null then
    select id into v_client from public.crm_clients
    where phone = v_phone order by created_at limit 1;
  end if;

  if v_client is null then
    insert into public.crm_clients (name, phone, source, status)
    values (coalesce(v_name, ''), v_phone, v_source, 'fresh')
    returning id into v_client;
  else
    -- Fill blanks only. Never overwrite what the team has entered by hand.
    update public.crm_clients
       set name       = case when coalesce(btrim(name), '') = '' then coalesce(v_name, '') else name end,
           updated_at = now()
     where id = v_client;
  end if;

  update public.lead_intake set crm_client_id = v_client where lead_key = p_lead_key;
end;
$$;


/**
 * Read one browser's lead back, so a returning visitor resumes mid-questionnaire
 * instead of starting over. Guarded by the key alone, which is why the key has
 * to be long and random.
 */
create or replace function public.get_lead_intake(p_lead_key text)
returns table (
  name text, phone text, prefs jsonb, step int, completed boolean, claimed boolean
)
language sql
security definer
set search_path = public
as $$
  select l.name, l.phone, l.prefs, l.step, l.completed, (l.claimed_by is not null)
  from public.lead_intake l
  where l.lead_key = p_lead_key
    and length(p_lead_key) >= 24;
$$;


/**
 * Attach a finished lead to the account that just signed up.
 *
 * The preferences themselves are copied into user_requirements by the client,
 * which already owns that mapping (lib/userRequirements.js) and is covered by
 * its own tests. This does the parts the client cannot: marking the lead
 * claimed, and pointing the CRM row at the new account so the lead and the
 * customer stop being two separate people in the pipeline.
 */
create or replace function public.claim_lead_intake(p_lead_key text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_client uuid;
  v_phone  text;
  v_name   text;
begin
  if v_uid is null then
    raise exception 'must be signed in to claim a lead';
  end if;

  update public.lead_intake
     set claimed_by = v_uid, claimed_at = now(), updated_at = now()
   where lead_key = p_lead_key and claimed_by is null
   returning crm_client_id, phone, name into v_client, v_phone, v_name;

  if not found then
    return;                       -- unknown key, or already claimed
  end if;

  -- crm_clients.user_id is unique, so a second lead resolving to an account
  -- that already has a client row must not try to claim it as well.
  if v_client is not null
     and not exists (select 1 from public.crm_clients where user_id = v_uid) then
    update public.crm_clients set user_id = v_uid, updated_at = now()
     where id = v_client and user_id is null;
  end if;

  -- The number was the price of admission before signup; don't make them type
  -- it again into RequirePhoneModal after it.
  update public.user_profiles
     set phone      = case when coalesce(btrim(phone), '') = '' then coalesce(v_phone, '') else phone end,
         name       = case when coalesce(btrim(name), '')  = '' then coalesce(v_name, '')  else name  end,
         updated_at = now()
   where id = v_uid;
end;
$$;


revoke all on function public.save_lead_intake(text, text, text, text, jsonb, int, boolean, jsonb) from public;
revoke all on function public.get_lead_intake(text) from public;
revoke all on function public.claim_lead_intake(text) from public;

-- anon needs both of these: the whole point is a visitor with no session.
grant execute on function public.save_lead_intake(text, text, text, text, jsonb, int, boolean, jsonb) to anon, authenticated;
grant execute on function public.get_lead_intake(text) to anon, authenticated;
-- Claiming requires auth.uid(), so anon would only ever raise.
grant execute on function public.claim_lead_intake(text) to authenticated;


-- Leads with a number, newest first — what the CRM lists. A lead that never
-- typed a phone is excluded: there is nothing a salesperson can do with it.
create or replace view public.crm_lead_intake as
  select l.lead_key, l.name, l.phone, l.prefs, l.step, l.completed,
         l.utm ->> 'source' as utm_source,
         l.crm_client_id, l.claimed_by, l.created_at, l.updated_at
  from public.lead_intake l
  where l.phone <> ''
  order by l.updated_at desc;
