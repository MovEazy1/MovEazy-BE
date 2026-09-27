-- Read-only. Did anyone new give us a number recently, and did they reach the
-- CRM's Fresh leads? Paste the single result table back.
--
-- One row per source, newest first, last 7 days:
--   phone_gate   a number typed at the phone gate (lead_intake)
--   crm_client   a row created in the CRM
--   profile      a signed-in account holding a number
-- with whether each made it into the CRM and whether staff have contacted it.

with recent_leads as (
  select 'phone_gate'::text as source,
         l.created_at        as at,
         coalesce(nullif(l.name, ''), '(no name)') as who,
         l.phone,
         l.crm_client_id is not null as in_crm,
         l.lead_type as detail
    from public.lead_intake l
   where l.phone <> '' and l.created_at > now() - interval '7 days'
),
recent_clients as (
  select 'crm_client'::text,
         c.created_at,
         coalesce(nullif(c.name, ''), '(no name)'),
         c.phone,
         true,
         c.source || ' · ' || c.status
           || case when exists (
                select 1 from public.crm_activities a
                 where a.client_id = c.id and coalesce(a.actor_email, '') <> ''
                   and a.type in ('whatsapp', 'call', 'shortlist', 'status', 'contacted'))
              then ' · CONTACTED' else ' · fresh' end
    from public.crm_clients c
   where c.created_at > now() - interval '7 days'
),
recent_profiles as (
  select 'profile'::text,
         p.created_at,
         coalesce(nullif(p.name, ''), p.email),
         p.phone,
         exists (select 1 from public.crm_clients c
                  where c.user_id = p.id
                     or public.normalize_mobile(c.phone) = public.normalize_mobile(p.phone)),
         coalesce(p.role, '')
    from public.user_profiles p
   where public.normalize_mobile(p.phone) <> '' and p.created_at > now() - interval '7 days'
)
select source, to_char(at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI') as at_ist,
       round(extract(epoch from now() - at) / 3600) as hours_ago,
       who, phone, in_crm, detail
  from (select * from recent_leads
        union all select * from recent_clients
        union all select * from recent_profiles) x
 order by at desc
 limit 60;
