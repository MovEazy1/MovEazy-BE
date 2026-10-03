-- ─────────────────────────────────────────────────────────────────────────────
-- Partner & owner app analytics — who uses partners.moveazy.co.in and
-- owners.moveazy.co.in, for how long, when they last signed in, and every
-- button they pressed in each session (fe/src/lib/appAnalytics.js,
-- fe/src/pages/crm/CrmAppAnalyticsPage.jsx).
--
-- Run in the Supabase SQL editor AFTER crm_schema.sql (user_sessions,
-- has_admin_scope), partner_schema.sql and owner_schema.sql. Safe to re-run.
--
--   user_sessions.app / session_key  which app a session was in ('owner' |
--                    'partner'; '' for the main site) and the browser's session
--                    id, so a session's clicks can be laid out under it.
--   app_events       one row per tap in those two apps: a button, link or tab
--                    by its visible label, or a screen opened — with the time.
--                    Never what anyone typed.
--
-- Written only through app_track() (anyone, for their own session); read only
-- through the two app_analytics_* functions, by CRM staff who may see
-- dashboards (crm.analytics.read).
-- ─────────────────────────────────────────────────────────────────────────────

begin;

alter table public.user_sessions add column if not exists app text not null default '';
alter table public.user_sessions add column if not exists session_key text not null default '';
create index if not exists user_sessions_app_idx on public.user_sessions (app, user_id, started_at desc) where app <> '';
create index if not exists user_sessions_key_idx on public.user_sessions (session_key) where session_key <> '';

create table if not exists public.app_events (
  id          bigint generated always as identity primary key,
  app         text not null check (app in ('owner', 'partner')),
  session_key text not null check (length(session_key) between 8 and 80),
  user_id     uuid references auth.users (id) on delete cascade,
  anon_id     text not null default '',
  kind        text not null check (kind in ('click', 'page')),
  label       text not null default '',          -- the button's words, or the screen
  target      text not null default '',          -- button | link | tab | toggle | select
  path        text not null default '',
  at          timestamptz not null default now(),
  created_at  timestamptz not null default now()
);
create index if not exists app_events_user_idx on public.app_events (app, user_id, at desc);
create index if not exists app_events_session_idx on public.app_events (session_key, at);

alter table public.app_events enable row level security;
revoke all on public.app_events from anon, authenticated;

/**
 * Record a batch of taps from one session of the owner or partner app. The
 * account is whoever is signed in (or nobody yet); times outside the last day
 * are pinned to now; a session can't write more than 2,000 rows.
 */
create or replace function public.app_track(p_app text, p_session text, p_anon text, p_events jsonb)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  n int := 0;
  k text := left(trim(coalesce(p_session, '')), 80);
begin
  if p_app not in ('owner', 'partner') or length(k) < 8 or jsonb_typeof(p_events) <> 'array' then return 0; end if;
  if (select count(*) from public.app_events where session_key = k) >= 2000 then return 0; end if;
  insert into public.app_events (app, session_key, user_id, anon_id, kind, label, target, path, at)
  select p_app, k, auth.uid(), left(coalesce(p_anon, ''), 64),
         case when e ->> 'kind' = 'page' then 'page' else 'click' end,
         left(coalesce(e ->> 'label', ''), 120), left(coalesce(e ->> 'target', ''), 20), left(coalesce(e ->> 'path', ''), 200),
         case when (e ->> 'at') ~ '^\d{4}-\d{2}-\d{2}T'
                   and (e ->> 'at')::timestamptz between now() - interval '1 day' and now() + interval '1 minute'
              then (e ->> 'at')::timestamptz else now() end
    from jsonb_array_elements(p_events) e
   limit 100;
  get diagnostics n = row_count;
  -- Signed in now: the taps this session made before sign-in are theirs too.
  if auth.uid() is not null then
    update public.app_events set user_id = auth.uid() where session_key = k and user_id is null;
  end if;
  return n;
end;
$$;

/**
 * Everyone in one app — owners or partners — with their details, last sign-in,
 * time spent, sessions and taps. CRM staff with dashboards only.
 */
create or replace function public.app_analytics_people(p_app text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.has_admin_scope('crm.analytics.read') then raise exception 'Not allowed.' using errcode = '42501'; end if;
  if p_app not in ('owner', 'partner') then raise exception 'Owner or partner.' using errcode = '22023'; end if;
  return coalesce((
    select jsonb_agg(row_to_json(x)::jsonb order by x.last_seen desc nulls last, x.joined desc)
      from (
        select p.user_id, p.name, p.phone, p.email, p.agency, p.status, p.joined,
               (select to_jsonb(u) ->> 'last_sign_in_at' from auth.users u where u.id = p.user_id) as last_login,
               greatest(s.last_end, e.last_at) as last_seen,
               coalesce(s.sessions, 0) as sessions,
               coalesce(s.seconds, 0) as seconds,
               coalesce(s.sessions_7d, 0) as sessions_7d,
               coalesce(s.seconds_7d, 0) as seconds_7d,
               coalesce(e.clicks, 0) as clicks
          from (
            select o.user_id, o.name, o.phone, o.email, ''::text as agency, o.status, o.created_at as joined
              from public.owner_accounts o where p_app = 'owner'
            union all
            select b.user_id, b.name, b.phone, b.email, b.agency, b.status, b.created_at
              from public.broker_partners b where p_app = 'partner'
          ) p
          left join lateral (
            select count(*)::int as sessions, sum(us.duration_seconds)::int as seconds, max(coalesce(us.ended_at, us.started_at)) as last_end,
                   (count(*) filter (where us.started_at > now() - interval '7 days'))::int as sessions_7d,
                   (coalesce(sum(us.duration_seconds) filter (where us.started_at > now() - interval '7 days'), 0))::int as seconds_7d
              from public.user_sessions us where us.user_id = p.user_id and us.app = p_app
          ) s on true
          left join lateral (
            select (count(*) filter (where ae.kind = 'click'))::int as clicks, max(ae.at) as last_at
              from public.app_events ae where ae.user_id = p.user_id and ae.app = p_app
          ) e on true
      ) x
  ), '[]'::jsonb);
end;
$$;

/**
 * One person's sessions in one app, newest first: when, how long, the device,
 * and every tap and screen in order with its time.
 */
create or replace function public.app_analytics_user(p_app text, p_user uuid, p_limit int default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.has_admin_scope('crm.analytics.read') then raise exception 'Not allowed.' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'session_key', k.session_key,
             'started_at', least(us.started_at, ev.first_at),
             'ended_at', greatest(us.ended_at, ev.last_at),
             'seconds', coalesce(us.duration_seconds, extract(epoch from (ev.last_at - ev.first_at))::int, 0),
             'device', coalesce(us.device, ''), 'os', coalesce(us.os, ''),
             'pages', coalesce(us.pages, '[]'::jsonb),
             'clicks', coalesce(ev.clicks, 0),
             'events', coalesce(ev.events, '[]'::jsonb))
           order by coalesce(least(us.started_at, ev.first_at), us.started_at, ev.first_at) desc)
      from (
        select session_key from (
          select s.session_key, s.started_at as t from public.user_sessions s
           where s.user_id = p_user and s.app = p_app and s.session_key <> ''
          union all
          select a.session_key, min(a.at) from public.app_events a
           where a.user_id = p_user and a.app = p_app group by a.session_key
        ) all_keys
        group by session_key
        order by max(t) desc
        limit greatest(1, least(coalesce(p_limit, 30), 100))
      ) k
      left join lateral (
        select s.started_at, s.ended_at, s.duration_seconds, s.device, s.os, s.pages
          from public.user_sessions s where s.session_key = k.session_key and s.user_id = p_user
         order by s.started_at limit 1
      ) us on true
      left join lateral (
        select min(a.at) as first_at, max(a.at) as last_at, (count(*) filter (where a.kind = 'click'))::int as clicks,
               jsonb_agg(jsonb_build_object('at', a.at, 'kind', a.kind, 'label', a.label, 'target', a.target, 'path', a.path)
                         order by a.at, a.id) as events
          from public.app_events a where a.session_key = k.session_key and a.app = p_app
      ) ev on true
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.app_track(text, text, text, jsonb) from public;
grant execute on function public.app_track(text, text, text, jsonb) to anon, authenticated;
revoke all on function public.app_analytics_people(text) from public, anon;
grant execute on function public.app_analytics_people(text) to authenticated;
revoke all on function public.app_analytics_user(text, uuid, int) from public, anon;
grant execute on function public.app_analytics_user(text, uuid, int) to authenticated;

commit;
