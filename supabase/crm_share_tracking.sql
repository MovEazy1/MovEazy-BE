-- ─────────────────────────────────────────────────────────────────────────────
-- Share attribution: know that a link came from the CRM, for which property,
-- to which client — and whether they actually opened it.
--
-- Run once in the Supabase SQL editor, after crm_schema.sql. Idempotent.
--
-- UTM parameters alone can only say "someone arrived from the CRM". They can't
-- say *who*, because the recipient is usually signed out when they tap a
-- WhatsApp link. So every send also carries an opaque per-share token that maps
-- back to exactly one crm_shortlists row (one client + one property), and the
-- open is recorded through a security-definer function rather than by opening
-- the table to anonymous writes.
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.crm_shortlists add column if not exists share_token     text;
alter table public.crm_shortlists add column if not exists opened_at       timestamptz;
alter table public.crm_shortlists add column if not exists last_opened_at  timestamptz;
alter table public.crm_shortlists add column if not exists open_count      int not null default 0;

create unique index if not exists crm_shortlists_share_token_idx
  on public.crm_shortlists (share_token)
  where share_token is not null;

-- What the visitor arrived with, kept on the session so "came from the CRM" is
-- answerable even for a link that was forwarded and never matched a token.
alter table public.user_sessions add column if not exists utm jsonb default '{}'::jsonb;

/**
 * Record that a shared link was opened.
 *
 * Callable by anyone, including signed-out visitors — that's the whole point,
 * since the person tapping the link in WhatsApp has no session. Safe to expose:
 * it takes an opaque token, returns nothing, and can only ever bump a counter on
 * a row that already exists. An unknown or guessed token is a silent no-op.
 *
 * The first open also writes a timeline entry, so an agent sees "opened the link
 * you sent" on the client's record. Later opens only move the counter — a client
 * refreshing a page shouldn't flood the history.
 */
create or replace function public.record_share_open(token text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  row_client uuid;
  row_property text;
  was_opened timestamptz;
begin
  if token is null or length(token) < 8 then
    return;
  end if;

  select client_id, property_id, opened_at
    into row_client, row_property, was_opened
    from public.crm_shortlists
   where share_token = token;

  if row_client is null then
    return;  -- unknown token; say nothing either way
  end if;

  update public.crm_shortlists
     set open_count     = open_count + 1,
         opened_at      = coalesce(opened_at, now()),
         last_opened_at = now()
   where share_token = token;

  if was_opened is null then
    insert into public.crm_activities (client_id, actor_email, type, body, meta)
    values (
      row_client,
      '',
      'system',
      'Opened the link you sent · ' || row_property,
      jsonb_build_object('property_id', row_property, 'via', 'share_link')
    );
  end if;
end;
$$;

-- Postgres grants EXECUTE to PUBLIC on new functions by default; be explicit
-- about who may call this rather than relying on that.
revoke all on function public.record_share_open(text) from public;
grant execute on function public.record_share_open(text) to anon, authenticated;

-- Backfill tokens for anything already shared, so links sent before today can
-- still be regenerated with tracking rather than staying blind forever.
update public.crm_shortlists
   set share_token = 'mz' || replace(gen_random_uuid()::text, '-', '')
 where share_token is null;
