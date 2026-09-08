-- Closes the user_engagement exposure for good: the permission check now lives
-- inside the view, so it holds whether or not security_invoker stays set.
create or replace view public.user_engagement as
  select
    user_id,
    count(*)::int                           as session_count,
    coalesce(sum(duration_seconds), 0)::int as total_seconds,
    coalesce(max(duration_seconds), 0)::int as longest_seconds,
    max(coalesce(ended_at, started_at))     as last_seen_at
  from public.user_sessions
  where user_id is not null
    and (user_id = auth.uid() or public.is_crm_staff())
  group by user_id;

alter view public.user_engagement set (security_invoker = on);
grant select on public.user_engagement to authenticated;

-- Proof, in one row. belt = the guard is in the view; braces = the flag is set.
select
  (select count(*) from pg_views
     where viewname = 'user_engagement'
       and definition ilike '%is_crm_staff%')                        as belt,
  (select coalesce(array_to_string(reloptions, ','), 'not set')
     from pg_class where relname = 'user_engagement')                as braces,
  (select count(*) from public.user_sessions)                        as sessions_recorded;
