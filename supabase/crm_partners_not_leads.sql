-- Partners are not tenants: a partner sign-up never makes a CRM lead.
--
-- Joining the partner app saves the broker's mobile on their user_profiles row
-- (role 'customer' by default), and crm_lead_from_profile_phone
-- (crm_phone_leads.sql) turned that number into a Fresh lead -- in the same
-- minute partner_register made them a partner. The CRM's "sync sign-ups"
-- button (crmClients.js) had the same gap.
--
-- The rule now:
--   * An account that is a partner and has not searched for a flat
--     (user_requirements with an area, budget or flat type) is never added as
--     a sign-up lead -- whichever path tries: the profile trigger, its
--     backfill, or the sync button. A guard on crm_clients skips the row.
--   * Becoming a partner removes the lead their sign-up just made, if nobody
--     has worked it: still Fresh, no call / note / status from the team, no
--     CRM requirements, never shortlisted or given to a partner.
--   * Someone who searched as a tenant first keeps their lead, history and
--     all; and a partner who later saves a flat search on moveazy.co.in
--     becomes a lead then.
--
-- Run in the Supabase SQL editor AFTER crm_phone_leads.sql, partner_schema.sql
-- and partner_moveazy_leads.sql. Safe to re-run.
-- society_app.sql (run after this) extends crm_partner_not_searching to
-- society members; re-run it after this file.

begin;

-- ── Who counts ───────────────────────────────────────────────────────────────
/** A partner account that has never saved a flat search of its own. */
create or replace function public.crm_partner_not_searching(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.broker_partners b where b.user_id = p_user)
     and not exists (
           select 1 from public.user_requirements r
            where r.user_id = p_user
              and (cardinality(coalesce(r.localities, '{}')) > 0
                   or cardinality(coalesce(r.flat_types, '{}')) > 0
                   or r.budget_min is not null or r.budget_max is not null));
$$;

-- ── The guard ────────────────────────────────────────────────────────────────
-- Only sign-up rows: a lead the team types in by hand, or one from the tenant
-- phone gate, a booking or a contact message, is always kept.
create or replace function public.crm_clients_skip_partner_signup()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.source = 'signup' and new.user_id is not null
     and public.crm_partner_not_searching(new.user_id) then
    return null;
  end if;
  return new;
end;
$$;

drop trigger if exists crm_clients_skip_partner_signup on public.crm_clients;
create trigger crm_clients_skip_partner_signup
  before insert on public.crm_clients
  for each row execute function public.crm_clients_skip_partner_signup();

-- ── Becoming a partner ───────────────────────────────────────────────────────
-- The phone is saved (and the lead made) a moment before partner_register, so
-- the guard can't see them yet: tidy up as the partner row lands.
create or replace function public.crm_drop_partner_signup_lead(p_user uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare n int;
begin
  if not public.crm_partner_not_searching(p_user) then
    return 0;
  end if;
  delete from public.crm_clients c
   where c.user_id = p_user
     and c.source = 'signup'
     and c.status = 'fresh'
     and not exists (select 1 from public.crm_activities a where a.client_id = c.id and a.type <> 'system')
     and not exists (select 1 from public.crm_client_requirements q where q.client_id = c.id)
     and not exists (select 1 from public.crm_shortlists s where s.client_id = c.id)
     and not exists (select 1 from public.partner_lead_assignments x where x.client_id = c.id);
  get diagnostics n = row_count;
  return n;
end;
$$;

create or replace function public.broker_partners_drop_signup_lead()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.crm_drop_partner_signup_lead(new.user_id);
  return new;
exception when others then
  -- Never stand between a broker and joining.
  raise warning 'broker_partners_drop_signup_lead(%): %', new.user_id, sqlerrm;
  return new;
end;
$$;

drop trigger if exists broker_partners_drop_signup_lead on public.broker_partners;
create trigger broker_partners_drop_signup_lead
  after insert on public.broker_partners
  for each row execute function public.broker_partners_drop_signup_lead();

-- ── A partner who searches for a flat ────────────────────────────────────────
-- The phone trigger skipped them; once they save an area, budget or flat type
-- they are a tenant lead like anyone else (linked to a phone-first lead with
-- the same number when there is one).
create or replace function public.crm_lead_when_searching()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  prof     public.user_profiles;
  v_phone  text;
  v_client uuid;
begin
  if not (cardinality(coalesce(new.localities, '{}')) > 0
          or cardinality(coalesce(new.flat_types, '{}')) > 0
          or new.budget_min is not null or new.budget_max is not null) then
    return new;
  end if;
  if exists (select 1 from public.crm_clients c where c.user_id = new.user_id) then
    return new;
  end if;

  select * into prof from public.user_profiles where id = new.user_id;
  v_phone := public.normalize_mobile(coalesce(prof.phone, ''));
  if v_phone = '' or coalesce(prof.role, 'customer') not in ('customer', 'tenant') then
    return new;
  end if;

  select id into v_client
    from public.crm_clients
   where public.normalize_mobile(phone) = v_phone and user_id is null
   order by created_at
   limit 1;
  if v_client is not null then
    update public.crm_clients set user_id = new.user_id where id = v_client;
  else
    insert into public.crm_clients (user_id, name, phone, email, source, status)
    values (new.user_id,
            coalesce(nullif(btrim(prof.name), ''), split_part(coalesce(prof.email, ''), '@', 1), ''),
            v_phone, lower(coalesce(prof.email, '')), 'signup', 'fresh')
    on conflict (user_id) do nothing
    returning id into v_client;
  end if;
  if v_client is not null then
    insert into public.crm_activities (client_id, actor_email, type, body)
    values (v_client, 'system', 'system', 'Saved a flat search on the site');
  end if;
  return new;
exception when others then
  -- A CRM problem must never stop someone saving their search.
  raise warning 'crm_lead_when_searching(%): %', new.user_id, sqlerrm;
  return new;
end;
$$;

drop trigger if exists crm_lead_when_searching on public.user_requirements;
create trigger crm_lead_when_searching
  after insert or update on public.user_requirements
  for each row execute function public.crm_lead_when_searching();

revoke all on function public.crm_partner_not_searching(uuid) from public, anon, authenticated;
revoke all on function public.crm_clients_skip_partner_signup() from public, anon, authenticated;
revoke all on function public.crm_drop_partner_signup_lead(uuid) from public, anon, authenticated;
revoke all on function public.broker_partners_drop_signup_lead() from public, anon, authenticated;
revoke all on function public.crm_lead_when_searching() from public, anon, authenticated;

-- ── Partners already in Fresh leads ──────────────────────────────────────────
select public.crm_drop_partner_signup_lead(b.user_id) from public.broker_partners b;

commit;
