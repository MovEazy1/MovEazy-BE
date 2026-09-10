-- ─────────────────────────────────────────────────────────────────────────────
-- Brokerage and payment tracking on closed deals, plus admin notifications.
--
-- Run once in the Supabase SQL editor, after crm_schema.sql. Idempotent.
--
-- The rule this encodes: anyone with CRM access can say "payment received", but
-- only the super admin can approve it, and approval is the terminal state. That
-- separation is enforced by two security-definer functions rather than by RLS
-- alone, because a plain UPDATE policy cannot see the value a row is moving
-- *from* — without them, a CRM manager could set 'approved' directly.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── Money on a closed deal ───────────────────────────────────────────────────

alter table public.crm_clients add column if not exists brokerage_amount     numeric;
alter table public.crm_clients add column if not exists expected_credit_date date;
alter table public.crm_clients add column if not exists payment_status       text not null default 'none';
alter table public.crm_clients add column if not exists payment_marked_by    text default '';
alter table public.crm_clients add column if not exists payment_marked_at    timestamptz;
alter table public.crm_clients add column if not exists payment_approved_by  text default '';
alter table public.crm_clients add column if not exists payment_approved_at  timestamptz;
alter table public.crm_clients add column if not exists payment_note         text default '';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'crm_clients_payment_status_check') then
    alter table public.crm_clients
      add constraint crm_clients_payment_status_check
      check (payment_status in ('none', 'awaited', 'received', 'approved'));
  end if;
end $$;

create index if not exists crm_clients_payment_idx
  on public.crm_clients (payment_status)
  where status = 'closed_by_us';

-- ── Notifications ────────────────────────────────────────────────────────────
-- Addressed to one email. The super admin sees everything; anyone else sees
-- only what was sent to them.

create table if not exists public.crm_notifications (
  id         uuid primary key default gen_random_uuid(),
  for_email  text not null,
  type       text not null default 'payment',
  title      text not null default '',
  body       text default '',
  client_id  uuid references public.crm_clients(id) on delete cascade,
  actor_email text default '',
  read_at    timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists crm_notifications_inbox_idx
  on public.crm_notifications (lower(for_email), read_at, created_at desc);

alter table public.crm_notifications enable row level security;

drop policy if exists "read own notifications" on public.crm_notifications;
create policy "read own notifications"
  on public.crm_notifications for select
  to authenticated
  using (
    public.is_super_admin()
    or lower(for_email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );

-- Marking one read is the only write a person does directly; everything else is
-- created by the functions below.
drop policy if exists "update own notifications" on public.crm_notifications;
create policy "update own notifications"
  on public.crm_notifications for update
  to authenticated
  using (
    public.is_super_admin()
    or lower(for_email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  )
  with check (
    public.is_super_admin()
    or lower(for_email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );

grant select, update on public.crm_notifications to authenticated;

-- ── The two transitions ──────────────────────────────────────────────────────

/**
 * "We've been paid." Any CRM user with write access may say this.
 *
 * Security definer so the notification to the super admin is written as part of
 * the same call — a client that forgot to insert it, or wasn't allowed to, would
 * otherwise leave an approval nobody knows to make.
 */
create or replace function public.mark_payment_received(p_client_id uuid, p_note text default '')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  actor text := lower(coalesce(auth.jwt() ->> 'email', ''));
  c record;
begin
  if not public.has_admin_scope('crm.clients.write') then
    raise exception 'not permitted';
  end if;

  select * into c from public.crm_clients where id = p_client_id;
  if c is null then
    raise exception 'no such client';
  end if;
  if c.status <> 'closed_by_us' then
    raise exception 'payment only applies to deals closed by us';
  end if;
  if c.payment_status = 'approved' then
    raise exception 'already approved';
  end if;

  update public.crm_clients
     set payment_status    = 'received',
         payment_marked_by = actor,
         payment_marked_at = now(),
         payment_note      = coalesce(nullif(p_note, ''), payment_note),
         updated_at        = now()
   where id = p_client_id;

  insert into public.crm_activities (client_id, actor_email, type, body, meta)
  values (p_client_id, actor, 'system', 'Marked payment received', jsonb_build_object('payment', 'received'));

  -- Straight to the one address that can approve it.
  insert into public.crm_notifications (for_email, type, title, body, client_id, actor_email)
  values (
    'yatharth200018@gmail.com',
    'payment',
    'Payment marked received',
    coalesce(nullif(c.name, ''), c.email, 'A client') || ' · ' ||
      coalesce('₹' || c.brokerage_amount::text, 'amount not set') || ' · marked by ' || actor,
    p_client_id,
    actor
  );
end;
$$;

/**
 * Approval. Super admin only, and terminal — nothing moves a row out of
 * 'approved'. Checked here rather than in a policy because an UPDATE policy
 * cannot see the previous value, so it could not stop a CRM manager writing
 * 'approved' directly.
 */
create or replace function public.approve_payment(p_client_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  actor text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if not public.is_super_admin() then
    raise exception 'only the super admin can approve a payment';
  end if;

  update public.crm_clients
     set payment_status     = 'approved',
         payment_approved_by = actor,
         payment_approved_at = now(),
         updated_at          = now()
   where id = p_client_id
     and status = 'closed_by_us'
     and payment_status = 'received';

  if not found then
    raise exception 'nothing to approve — the deal must be closed by us and marked received';
  end if;

  insert into public.crm_activities (client_id, actor_email, type, body, meta)
  values (p_client_id, actor, 'system', 'Payment approved', jsonb_build_object('payment', 'approved'));

  update public.crm_notifications
     set read_at = coalesce(read_at, now())
   where client_id = p_client_id and type = 'payment' and read_at is null;
end;
$$;

revoke all on function public.mark_payment_received(uuid, text) from public;
revoke all on function public.approve_payment(uuid) from public;
grant execute on function public.mark_payment_received(uuid, text) to authenticated;
grant execute on function public.approve_payment(uuid) to authenticated;

-- Existing deals closed by us start awaiting payment rather than 'none', so they
-- appear in the payments list instead of silently sitting outside it.
update public.crm_clients
   set payment_status = 'awaited'
 where status = 'closed_by_us' and payment_status = 'none';
