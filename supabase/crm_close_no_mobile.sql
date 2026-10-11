-- Leads we can't ring: closed outside, until they give us a number.
--
-- Signed-up tenants who never entered a mobile sat in the CRM as open leads
-- nobody could call. This closes them once — CRM only (their site profile is
-- left searching) — with the reason "No mobile number".
--
-- And it undoes itself per person: the moment one of them has a valid mobile
-- (typed on the site, which crm_phone_leads.sql copies onto the blank CRM row,
-- or entered by the team), they're a Fresh lead again. Only leads closed for
-- this reason reopen; anything closed by hand stays closed.
--
-- The one-time close runs only on the first apply; re-running leaves later
-- sign-ups without a number open for the team to follow up.

begin;

create temp table _no_mobile_first on commit drop as
  select to_regprocedure('public.crm_reopen_when_mobile()') is null as first;

create or replace function public.crm_reopen_when_mobile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'closed_outside'
     and coalesce(new.closed_reason, '') = 'No mobile number'
     and public.normalize_mobile(new.phone) <> ''
     and public.normalize_mobile(old.phone) = '' then
    new.status        := 'fresh';
    new.closed_at     := null;
    new.closed_reason := '';
    new.updated_at    := now();
    insert into public.crm_activities (client_id, actor_email, type, body, meta)
    values (new.id, 'system', 'status', 'Closed outside → Fresh · gave a mobile number',
            jsonb_build_object('source', 'no_mobile_reopen'));
  end if;
  return new;
end;
$$;
revoke all on function public.crm_reopen_when_mobile() from public, anon, authenticated;

drop trigger if exists crm_clients_reopen_when_mobile on public.crm_clients;
create trigger crm_clients_reopen_when_mobile
  before update of phone on public.crm_clients
  for each row execute function public.crm_reopen_when_mobile();

-- Once: every open lead with no usable mobile.
do $$
begin
  if (select first from _no_mobile_first) then
    with closed as (
      update public.crm_clients c
         set status = 'closed_outside', closed_at = now(), closed_reason = 'No mobile number', updated_at = now()
       where public.normalize_mobile(c.phone) = ''
         and coalesce(c.status, '') not in ('closed_by_us', 'closed_outside')
      returning c.id
    )
    insert into public.crm_activities (client_id, actor_email, type, body, meta)
    select id, 'system', 'status', 'Closed outside · No mobile number',
           jsonb_build_object('source', 'no_mobile_close')
      from closed;
  end if;
end $$;

commit;
