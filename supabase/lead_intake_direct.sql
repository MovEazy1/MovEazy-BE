-- Let a shared property link be opened, and record who opened it.
--
-- A link sent to a tenant — WhatsApp, Facebook, a subreddit — used to land on
-- a Google wall. The flat was the thing being offered and it was the one thing
-- they could not see, so the share did the hardest part of the job (getting
-- someone interested enough to tap) and then spent it on an account prompt.
--
-- Now the same mobile number the questionnaire asks for gets asked here, and
-- the flat opens. Booking a visit still needs an account; looking does not.
--
-- These leads are worth telling apart. Someone who answered nine questions
-- told us what they want; someone who tapped one link told us only which flat
-- caught their eye — which is itself the most useful thing about them, and is
-- why property_id is kept. They stay "direct_prop_lead" in the CRM until they
-- sign up, at which point claim_lead_intake attaches the account and an email.

alter table public.lead_intake
  add column if not exists lead_type   text default 'questionnaire',
  add column if not exists property_id text default '';

comment on column public.lead_intake.lead_type is
  'questionnaire = came through the preference flow; direct_property = opened a shared property link.';
comment on column public.lead_intake.property_id is
  'For a direct_property lead, the flat whose link they opened. The one thing we know about what they want.';

create index if not exists lead_intake_type_idx
  on public.lead_intake (lead_type, updated_at desc);


/**
 * Replaces the eight-argument version. Adding parameters would otherwise
 * create an overload rather than replace it, leaving two functions with the
 * same name and the older one still reachable.
 */
drop function if exists public.save_lead_intake(text, text, text, text, jsonb, int, boolean, jsonb);

create or replace function public.save_lead_intake(
  p_lead_key    text,
  p_anon_id     text    default null,
  p_name        text    default null,
  p_phone       text    default null,
  p_prefs       jsonb   default null,
  p_step        int     default null,
  p_completed   boolean default null,
  p_utm         jsonb   default null,
  p_lead_type   text    default null,
  p_property_id text    default null
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
  v_type   text;
  v_prop   text;
begin
  if p_lead_key is null or length(p_lead_key) < 24 or length(p_lead_key) > 128 then
    raise exception 'invalid lead key';
  end if;

  v_phone := public.normalize_mobile(p_phone);
  v_name  := nullif(btrim(coalesce(p_name, '')), '');

  insert into public.lead_intake as l
    (lead_key, anon_id, name, phone, prefs, step, completed, utm, lead_type, property_id)
  values
    (p_lead_key,
     coalesce(left(p_anon_id, 120), ''),
     coalesce(v_name, ''),
     v_phone,
     coalesce(p_prefs, '{}'::jsonb),
     coalesce(p_step, 0),
     coalesce(p_completed, false),
     coalesce(p_utm, '{}'::jsonb),
     coalesce(nullif(p_lead_type, ''), 'questionnaire'),
     coalesce(left(p_property_id, 40), ''))
  on conflict (lead_key) do update set
    anon_id    = coalesce(nullif(left(p_anon_id, 120), ''), l.anon_id),
    name       = coalesce(v_name, l.name),
    phone      = case when v_phone <> '' then v_phone else l.phone end,
    prefs      = coalesce(p_prefs, l.prefs),
    step       = greatest(coalesce(p_step, l.step), l.step),
    completed  = l.completed or coalesce(p_completed, false),
    utm        = case when p_utm is not null and p_utm <> '{}'::jsonb then p_utm else l.utm end,
    -- Answering the questionnaire promotes a direct lead; opening another
    -- shared link never demotes someone who has already told us what they want.
    -- Keyed on actual progress, not on the field itself: a row created by a
    -- phone gate defaults to questionnaire before anyone has answered
    -- anything, and keying on that would make "direct" unreachable.
    lead_type  = case
                   when l.step > 0 or l.completed then 'questionnaire'
                   else coalesce(nullif(p_lead_type, ''), l.lead_type)
                 end,
    -- First flat they opened, kept. It is the one that caught their eye.
    property_id = case
                    when coalesce(l.property_id, '') <> '' then l.property_id
                    else coalesce(left(p_property_id, 40), '')
                  end,
    updated_at = now();

  select phone, name, crm_client_id, lead_type, property_id
    into v_phone, v_name, v_client, v_type, v_prop
  from public.lead_intake where lead_key = p_lead_key;

  if v_phone = '' then
    return;
  end if;

  -- A direct lead is labelled as one. Otherwise attribution names the channel,
  -- so a lead off the Facebook share lands already marked facebook.
  v_source := case
                when v_type = 'direct_property' then 'direct_prop_lead'
                else coalesce((select nullif(utm ->> 'source', '')
                               from public.lead_intake where lead_key = p_lead_key), 'website')
              end;

  if v_client is null then
    select id into v_client from public.crm_clients
    where phone = v_phone order by created_at limit 1;
  end if;

  if v_client is null then
    insert into public.crm_clients (name, phone, source, status, note)
    values (
      coalesce(v_name, ''), v_phone, v_source, 'fresh',
      case when v_type = 'direct_property' and v_prop <> ''
           then 'Opened shared property ' || v_prop else '' end
    )
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

revoke all on function public.save_lead_intake(text, text, text, text, jsonb, int, boolean, jsonb, text, text) from public;
grant execute on function public.save_lead_intake(text, text, text, text, jsonb, int, boolean, jsonb, text, text) to anon, authenticated;


-- get_lead_intake gains the two fields, so a returning visitor's lead comes
-- back whole rather than losing its type on every read.
drop function if exists public.get_lead_intake(text);

create or replace function public.get_lead_intake(p_lead_key text)
returns table (
  name text, phone text, prefs jsonb, step int, completed boolean,
  claimed boolean, lead_type text, property_id text
)
language sql
security definer
set search_path = public
as $$
  select l.name, l.phone, l.prefs, l.step, l.completed,
         (l.claimed_by is not null), l.lead_type, l.property_id
  from public.lead_intake l
  where l.lead_key = p_lead_key
    and length(p_lead_key) >= 24;
$$;

revoke all on function public.get_lead_intake(text) from public;
grant execute on function public.get_lead_intake(text) to anon, authenticated;


-- Direct leads, newest first — the ones who have seen a flat but not an
-- account yet, and what they were looking at.
create or replace view public.crm_direct_property_leads as
  select l.lead_key, l.name, l.phone, l.property_id,
         l.utm ->> 'source' as utm_source,
         l.crm_client_id, l.claimed_by, l.created_at, l.updated_at
  from public.lead_intake l
  where l.lead_type = 'direct_property' and l.phone <> ''
  order by l.updated_at desc;
