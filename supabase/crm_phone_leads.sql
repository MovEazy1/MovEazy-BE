-- Every mobile number entered on the site becomes a CRM lead.
--
-- There are two places a tenant gives us a number:
--
--   1. Before signing up, at the phone gate. save_lead_intake (lead_intake.sql)
--      creates or matches a crm_clients row there and then. That path works.
--
--   2. After signing up with Google, at RequirePhoneModal. That writes only
--      user_profiles.phone -- and nothing carried it on. The CRM row for that
--      person (if one existed at all: they are only created by the manual
--      "sync signups" button, a booking, or the one-time backfill) kept a blank
--      phone. So a tenant who signed in and then typed their number was either
--      missing from the CRM or sitting in it as a lead we could not ring.
--
-- This closes path 2 with a trigger on user_profiles, and backfills everyone
-- it has already missed.
--
-- The rule is "a number makes a lead", never "a sign-in makes a lead": the
-- trigger does nothing until there is a valid Indian mobile on the profile.
-- Owner and broker profiles are skipped -- their numbers are supply, not
-- demand, and the CRM's clients are tenants.
--
-- Run once in the Supabase SQL editor. Safe to re-run.


create or replace function public.crm_lead_from_profile_phone()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phone  text := public.normalize_mobile(new.phone);
  v_client uuid;
begin
  if v_phone = '' then
    return new;
  end if;
  if coalesce(new.role, 'customer') not in ('customer', 'tenant') then
    return new;
  end if;
  -- An update that didn't change the number (a name edit, say) has nothing
  -- to carry across.
  if tg_op = 'UPDATE' and public.normalize_mobile(old.phone) = v_phone then
    return new;
  end if;

  -- Their own row first; then a phone-first lead with the same number, which
  -- is the same person arriving by the other door.
  select id into v_client from public.crm_clients where user_id = new.id;
  if v_client is null then
    select id into v_client
      from public.crm_clients
     where public.normalize_mobile(phone) = v_phone
     order by (user_id is null) desc, created_at
     limit 1;
  end if;

  if v_client is null then
    insert into public.crm_clients (user_id, name, phone, email, source, status)
    values (
      new.id,
      coalesce(nullif(btrim(new.name), ''), split_part(coalesce(new.email, ''), '@', 1), ''),
      v_phone,
      lower(coalesce(new.email, '')),
      'signup',
      'fresh'
    )
    on conflict (user_id) do nothing;
  else
    -- Fill blanks only. A number or name the team has typed in by hand is
    -- theirs, and is never overwritten by what the profile says.
    update public.crm_clients c
       set phone   = case when coalesce(btrim(c.phone), '') = '' then v_phone else c.phone end,
           email   = case when coalesce(btrim(c.email), '') = '' then lower(coalesce(new.email, '')) else c.email end,
           name    = case when coalesce(btrim(c.name), '') = '' then coalesce(nullif(btrim(new.name), ''), c.name) else c.name end,
           -- Link a phone-first lead to the account, unless the account is
           -- already linked to another row (user_id is unique).
           user_id = case
                       when c.user_id is null
                        and not exists (select 1 from public.crm_clients x where x.user_id = new.id)
                       then new.id
                       else c.user_id
                     end
     where c.id = v_client;
  end if;

  return new;
exception when others then
  -- A CRM problem must never stop a tenant saving their own number. Raise it
  -- to the logs and let the profile write through.
  raise warning 'crm_lead_from_profile_phone(%): %', new.id, sqlerrm;
  return new;
end;
$$;

-- Trigger functions are not called over PostgREST, but Supabase's default
-- privileges grant execute to anon explicitly; take it back by name.
revoke all on function public.crm_lead_from_profile_phone() from public, anon, authenticated;

drop trigger if exists crm_lead_from_profile_phone on public.user_profiles;
create trigger crm_lead_from_profile_phone
  after insert or update of phone on public.user_profiles
  for each row execute function public.crm_lead_from_profile_phone();


-- == Backfill ================================================================
-- Everyone path 2 has already missed.

-- a) CRM rows linked to an account whose phone never came across.
update public.crm_clients c
   set phone = public.normalize_mobile(p.phone)
  from public.user_profiles p
 where c.user_id = p.id
   and coalesce(btrim(c.phone), '') = ''
   and public.normalize_mobile(p.phone) <> '';

-- b) Tenants with a number and no CRM row at all -- neither by account nor by
--    the same number arriving through the phone gate.
--
--    created_at is the profile's last change rather than now(), so a backlog
--    of numbers entered weeks ago doesn't all land at the top of Fresh leads
--    as if every one of them had arrived this minute.
insert into public.crm_clients (user_id, name, phone, email, source, status, created_at)
select p.id,
       coalesce(nullif(btrim(p.name), ''), split_part(coalesce(p.email, ''), '@', 1), ''),
       public.normalize_mobile(p.phone),
       lower(coalesce(p.email, '')),
       'signup',
       'fresh',
       coalesce(p.updated_at, p.created_at, now())
  from public.user_profiles p
 where public.normalize_mobile(p.phone) <> ''
   and coalesce(p.role, 'customer') in ('customer', 'tenant')
   and not exists (select 1 from public.crm_clients c where c.user_id = p.id)
   and not exists (
         select 1 from public.crm_clients c
          where public.normalize_mobile(c.phone) = public.normalize_mobile(p.phone)
       )
on conflict (user_id) do nothing;


-- == Verify ==================================================================
-- Tenants with a valid number who are still not reachable in the CRM. Expect
-- zero rows:
--
--   select p.id, p.email, p.phone
--     from public.user_profiles p
--    where public.normalize_mobile(p.phone) <> ''
--      and coalesce(p.role, 'customer') in ('customer', 'tenant')
--      and not exists (
--            select 1 from public.crm_clients c
--             where c.user_id = p.id and coalesce(btrim(c.phone), '') <> ''
--          )
--      and not exists (
--            select 1 from public.crm_clients c
--             where public.normalize_mobile(c.phone) = public.normalize_mobile(p.phone)
--          );
