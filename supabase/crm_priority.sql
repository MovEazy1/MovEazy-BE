-- CRM → Priority closures (MovEazy-FE pages/crm/CrmPriorityPage.jsx).
--
--   · crm_priority_clients: the clients the team works hardest, one row each.
--     A row counts from active_from: adding "from 20 Oct" or removing "until
--     20 Oct" both just set that date, and the client shows again that day.
--   · crm_priority_add(clients[], from) / crm_priority_remove(client, back_on):
--     anyone who can change clients (crm.clients.write).
--   · When the CRM sends a partner's flat to a client (a crm_shortlists row
--     getting shared_at), that partner hears about it — no tenant details.
--
-- Safe to re-run.

begin;

create table if not exists public.crm_priority_clients (
  client_id   uuid primary key references public.crm_clients (id) on delete cascade,
  active_from timestamptz not null default now(),
  added_by    text not null default '',
  added_at    timestamptz not null default now()
);
alter table public.crm_priority_clients enable row level security;
revoke all on table public.crm_priority_clients from anon, authenticated;
grant select on table public.crm_priority_clients to authenticated;
drop policy if exists "crm read priority" on public.crm_priority_clients;
create policy "crm read priority" on public.crm_priority_clients for select to authenticated using (public.is_crm_staff());

/** Add clients (or move their start to p_from). → how many. */
create or replace function public.crm_priority_add(p_clients uuid[], p_from timestamptz default null)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  n int;
begin
  if not public.has_admin_scope('crm.clients.write') then raise exception 'Not allowed.' using errcode = '42501'; end if;
  insert into public.crm_priority_clients (client_id, active_from, added_by)
  select c.id, coalesce(p_from, now()), coalesce(auth.jwt() ->> 'email', '')
    from public.crm_clients c where c.id = any (coalesce(p_clients, '{}'))
  on conflict (client_id) do update set active_from = excluded.active_from, added_by = excluded.added_by, added_at = now();
  get diagnostics n = row_count;
  return n;
end;
$$;

/** Take a client out — for good, or until p_back_on, when they show again. */
create or replace function public.crm_priority_remove(p_client uuid, p_back_on timestamptz default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.has_admin_scope('crm.clients.write') then raise exception 'Not allowed.' using errcode = '42501'; end if;
  if p_back_on is null or p_back_on <= now() then
    delete from public.crm_priority_clients where client_id = p_client;
  else
    update public.crm_priority_clients set active_from = p_back_on, added_by = coalesce(auth.jwt() ->> 'email', ''), added_at = now()
     where client_id = p_client;
  end if;
end;
$$;

-- ── A partner hears when MovEazy sends their flat ───────────────────────────
do $$
declare
  kinds text[];
begin
  select array_agg(distinct m[1]) into kinds
    from pg_constraint c, regexp_matches(pg_get_constraintdef(c.oid), '''([a-z_]+)''', 'g') m
   where c.conname = 'partner_notifications_kind_check';
  if kinds is null then return; end if;
  kinds := array(select distinct k from unnest(kinds || array['moveazy_sent']) k order by 1);
  alter table public.partner_notifications drop constraint partner_notifications_kind_check;
  execute format('alter table public.partner_notifications add constraint partner_notifications_kind_check check (kind in (%s))',
                 (select string_agg(quote_literal(k), ', ') from unnest(kinds) k));
end $$;

create or replace function public.crm_shortlist_partner_sent()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  bid  uuid;
  h    public.inventory;
  flat text;
begin
  if new.shared_at is null then return new; end if;
  if tg_op = 'UPDATE' and old.shared_at is not distinct from new.shared_at then return new; end if;
  select pl.broker_id into bid from public.partner_listings pl where pl.property_id = new.property_id limit 1;
  if bid is null then return new; end if;
  select * into h from public.inventory where property_id = new.property_id;
  flat := coalesce(nullif(concat_ws(' in ', nullif(h.flat_type, ''), nullif(h.area, '')), ''), 'flat');
  insert into public.partner_notifications (broker_id, kind, title, body, link)
  values (bid, 'moveazy_sent', 'MovEazy sent your ' || flat || ' to a client',
          'A MovEazy client is looking at it now. If they like it, MovEazy will connect you for the visit.',
          '/property/' || new.property_id);
  return new;
exception when others then
  return new; -- a missed note must never stop a list going out
end;
$$;
revoke all on function public.crm_shortlist_partner_sent() from public, anon, authenticated;
drop trigger if exists crm_shortlist_partner_sent on public.crm_shortlists;
create trigger crm_shortlist_partner_sent after insert or update of shared_at on public.crm_shortlists
  for each row execute function public.crm_shortlist_partner_sent();

-- ── Grants ──────────────────────────────────────────────────────────────────
revoke all on function public.crm_priority_add(uuid[], timestamptz) from public, anon;
revoke all on function public.crm_priority_remove(uuid, timestamptz) from public, anon;
grant execute on function public.crm_priority_add(uuid[], timestamptz) to authenticated;
grant execute on function public.crm_priority_remove(uuid, timestamptz) to authenticated;

commit;
