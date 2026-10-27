-- ════════════════════════════════════════════════════════════════════════════
-- View as a user — the super admin's private portal
-- (moveazy.co.in/unique-login-link-master-data-super-admin).
--
-- The super admin signs in as any account (api/view-as.js makes the session)
-- and sees exactly what that person sees in the tenant site, the owner,
-- partner and society apps and the CRM. Every request the browser makes while
-- viewing as someone carries an `x-mz-view-as: <session id>` header, and the
-- database does the rest:
--
--   view-only (the default)  every insert, update and delete is silently
--                            dropped, and the response says so (HTTP 203), so
--                            the page shows "View-only — not saved". Pages that
--                            write a counter while loading still load.
--   actions allowed          writes go through and each one is recorded — the
--                            row before and after — so Revert can put every
--                            row back the way it was when actions were allowed.
--                            Rows someone else changed since are left alone
--                            and listed.
--
-- A header naming a session that has ended, gone quiet for 35 minutes, isn't
-- in actions mode, or is for another account, drops the write too — so a
-- forgotten tab can never write as the user.
--
--   view_as_sessions   one per "view as": who, whom, mode, how it ended
--   view_as_changes    each row changed while actions were allowed
--   view_as_uploads    each file uploaded then (removed on revert by the API)
--
-- Every table in public gets two triggers (view_as_protect_all), including
-- tables created later (an event trigger, or run view_as_protect_all()).
-- Idempotent; run after crm_schema.sql (is_super_admin).
-- ════════════════════════════════════════════════════════════════════════════

create table if not exists public.view_as_sessions (
  id            uuid primary key default gen_random_uuid(),
  admin_id      uuid references auth.users (id) on delete set null,
  admin_email   text not null default '',
  target_id     uuid not null references auth.users (id) on delete cascade,
  target_email  text not null default '',
  target_name   text not null default '',
  key_hash      text not null,
  mode          text not null default 'view' check (mode in ('view', 'act')),
  acted         boolean not null default false,
  prior_sign_in timestamptz,
  started_at    timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  ended_at      timestamptz,
  end_reason    text not null default '',
  outcome       text not null default '' check (outcome in ('', 'kept', 'reverted', 'partly')),
  reverted_at   timestamptz
);
create index if not exists view_as_sessions_started_idx on public.view_as_sessions (started_at desc);

create table if not exists public.view_as_changes (
  id         bigserial primary key,
  session_id uuid not null references public.view_as_sessions (id) on delete cascade,
  at         timestamptz not null default clock_timestamp(),
  tbl        text not null,
  op         text not null check (op in ('INSERT', 'UPDATE', 'DELETE')),
  old_row    jsonb,
  new_row    jsonb,
  state      text not null default '' check (state in ('', 'reverted', 'skipped')),
  note       text not null default ''
);
create index if not exists view_as_changes_session_idx on public.view_as_changes (session_id, id);

create table if not exists public.view_as_uploads (
  id         bigserial primary key,
  session_id uuid not null references public.view_as_sessions (id) on delete cascade,
  bucket     text not null,
  path       text not null,
  at         timestamptz not null default now(),
  removed    boolean not null default false
);
create index if not exists view_as_uploads_session_idx on public.view_as_uploads (session_id);

alter table public.view_as_sessions enable row level security;
alter table public.view_as_changes enable row level security;
alter table public.view_as_uploads enable row level security;
revoke all on public.view_as_sessions, public.view_as_changes, public.view_as_uploads from public, anon, authenticated;

-- ── This request: not view-as, view-as with actions, or view-as and blocked ──

/**
 * 'none' (no view-as header), 'act:<session>' (actions allowed, recorded) or
 * 'block' (drop the write). Worked out once per transaction and cached.
 */
create or replace function public.view_as_state()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  cached text := current_setting('mz.view_as', true);
  h      text;
  sid    uuid;
  s      public.view_as_sessions%rowtype;
begin
  if coalesce(cached, '') <> '' then return cached; end if;
  begin
    h := nullif(current_setting('request.headers', true), '')::json ->> 'x-mz-view-as';
  exception when others then
    h := null;
  end;
  if coalesce(h, '') = '' then
    perform set_config('mz.view_as', 'none', true);
    return 'none';
  end if;
  begin
    sid := h::uuid;
  exception when others then
    sid := null;
  end;
  select * into s from public.view_as_sessions where id = sid;
  cached := case
    when s.id is not null and s.ended_at is null and s.mode = 'act' and s.target_id = auth.uid()
         and s.last_seen_at > now() - interval '35 minutes'
      then 'act:' || s.id
    else 'block'
  end;
  perform set_config('mz.view_as', cached, true);
  return cached;
end;
$$;

/** Activity counters: never written while viewing as someone, actions or not. */
create or replace function public.view_as_stat_tables()
returns text[]
language sql
immutable
as $$
  select array['app_events', 'user_sessions', 'flat_scans', 'owner_building_scans', 'partner_storefront_views',
               'partner_storefront_visits', 'partner_funnel_events', 'marketing_clicks', 'partner_qr_checkins'];
$$;

/** Before each write: let it through, or drop it (and tell the browser). */
create or replace function public.view_as_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  st text := public.view_as_state();
begin
  if st = 'none' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  if tg_table_name = any (public.view_as_stat_tables()) then
    return null;
  end if;
  if st = 'block' then
    -- 203: still a success to the page, and the browser knows nothing was kept.
    perform set_config('response.status', '203', true);
    return null;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

/** After each write with actions allowed: record the row before and after. */
create or replace function public.view_as_log()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  st text := current_setting('mz.view_as', true);
begin
  if coalesce(st, '') not like 'act:%' then return null; end if;
  insert into public.view_as_changes (session_id, tbl, op, old_row, new_row)
  values (substr(st, 5)::uuid, tg_table_name, tg_op,
          case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
          case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end);
  return null;
end;
$$;

/** Puts both triggers on every table in public that lacks them. Returns how many it added. */
create or replace function public.view_as_protect_all()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  t record;
  n int := 0;
begin
  for t in
    select c.relname
      from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
     where ns.nspname = 'public' and c.relkind in ('r', 'p') and not c.relispartition
       and c.relname not like 'view\_as\_%'
       and not exists (select 1 from pg_trigger g where g.tgrelid = c.oid and g.tgname = 'zz_view_as_guard')
  loop
    begin
      execute format('create trigger zz_view_as_guard before insert or update or delete on public.%I '
                     'for each row execute function public.view_as_guard()', t.relname);
      execute format('create trigger zz_view_as_log after insert or update or delete on public.%I '
                     'for each row execute function public.view_as_log()', t.relname);
      n := n + 1;
    exception when others then
      raise notice 'view_as: could not protect %: %', t.relname, sqlerrm;
    end;
  end loop;
  return n;
end;
$$;

select public.view_as_protect_all();

-- New tables get them as they're created, where the database allows event triggers.
create or replace function public.view_as_on_new_table()
returns event_trigger
language plpgsql
as $$
begin
  perform public.view_as_protect_all();
exception when others then
  -- Never let this get in the way of creating a table.
  raise notice 'view_as: %', sqlerrm;
end;
$$;

do $$
begin
  if not exists (select 1 from pg_event_trigger where evtname = 'view_as_new_tables') then
    create event trigger view_as_new_tables on ddl_command_end
      when tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      execute function public.view_as_on_new_table();
  end if;
exception when others then
  raise notice 'view_as: no event trigger here (%); run select public.view_as_protect_all() after adding tables', sqlerrm;
end;
$$;

-- ── The browser's controls for its session (it holds the session's key) ─────

/**
 * p_action: 'begin' (just signed in: put back the user's "last signed in"),
 * 'ping' (still here), 'view' / 'act' (switch mode), 'end' (exit).
 */
create or replace function public.view_as_control(p_session uuid, p_key text, p_action text, p_reason text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.view_as_sessions%rowtype;
  n int;
begin
  select * into s from public.view_as_sessions where id = p_session;
  if s.id is null or s.key_hash <> encode(sha256(convert_to(coalesce(p_key, ''), 'UTF8')), 'hex') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  if s.ended_at is not null and p_action <> 'end' then
    return jsonb_build_object('mode', s.mode, 'ended', true);
  end if;

  if p_action = 'begin' then
    -- Signing in as them moved their "last signed in"; it was the admin, not them.
    begin
      execute 'update auth.users set last_sign_in_at = $1 where id = $2' using s.prior_sign_in, s.target_id;
    exception when others then
      null;
    end;
    update public.view_as_sessions set last_seen_at = now() where id = s.id;
  elsif p_action = 'ping' then
    update public.view_as_sessions set last_seen_at = now() where id = s.id;
  elsif p_action in ('view', 'act') then
    update public.view_as_sessions
       set mode = p_action, acted = acted or p_action = 'act', last_seen_at = now()
     where id = s.id;
  elsif p_action = 'end' then
    update public.view_as_sessions
       set ended_at = coalesce(ended_at, now()), end_reason = case when ended_at is null then left(coalesce(p_reason, ''), 40) else end_reason end
     where id = s.id;
  else
    raise exception 'Unknown action.' using errcode = '22023';
  end if;

  select * into s from public.view_as_sessions where id = p_session;
  select count(*) into n from public.view_as_changes where session_id = s.id;
  return jsonb_build_object('mode', s.mode, 'ended', s.ended_at is not null, 'changes', n);
end;
$$;

/** A file uploaded while actions were allowed — removed again on revert. */
create or replace function public.view_as_note_upload(p_session uuid, p_key text, p_bucket text, p_path text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.view_as_sessions%rowtype;
begin
  select * into s from public.view_as_sessions where id = p_session;
  if s.id is null or s.key_hash <> encode(sha256(convert_to(coalesce(p_key, ''), 'UTF8')), 'hex') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  if s.ended_at is null and s.mode = 'act' and coalesce(p_bucket, '') <> '' and coalesce(p_path, '') <> '' then
    insert into public.view_as_uploads (session_id, bucket, path) values (s.id, left(p_bucket, 100), left(p_path, 500));
  end if;
end;
$$;

-- ── The portal (super admin only) ───────────────────────────────────────────

/** Accounts matching part of an email, name or phone, with what each one is. */
create or replace function public.view_as_search(p_q text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  q      text := lower(trim(coalesce(p_q, '')));
  digits text := regexp_replace(coalesce(p_q, ''), '\D', '', 'g');
  out    jsonb;
begin
  if not public.is_super_admin() then raise exception 'Not allowed.' using errcode = '42501'; end if;
  if length(q) < 2 then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(r order by r.rank, r.last_active desc nulls last), '[]'::jsonb) into out
    from (
      select u.id, lower(u.email) as email,
             coalesce(nullif(p.name, ''), nullif(o.name, ''), nullif(b.name, ''), '') as name,
             coalesce(nullif(p.phone, ''), nullif(o.phone, ''), nullif(b.phone, ''), '') as phone,
             array_remove(array[
               'tenant',
               case when o.user_id is not null then 'owner' end,
               case when b.user_id is not null then 'partner' end,
               case when exists (select 1 from public.society_members m where m.user_id = u.id and m.status = 'active') then 'society' end,
               case when exists (select 1 from public.admin_roles a where lower(a.email) = lower(u.email)) then 'crm' end
             ], null) as roles,
             greatest(u.last_sign_in_at, (select max(us.started_at) from public.user_sessions us where us.user_id = u.id)) as last_active,
             case when lower(u.email) = q then 0 when lower(u.email) like q || '%' then 1 else 2 end as rank
        from auth.users u
        left join public.user_profiles p on p.id = u.id
        left join public.owner_accounts o on o.user_id = u.id
        left join public.broker_partners b on b.user_id = u.id
       where lower(u.email) <> 'yatharth200018@gmail.com'
         and (lower(u.email) like '%' || q || '%'
              or lower(coalesce(p.name, '')) like '%' || q || '%'
              or lower(coalesce(o.name, '')) like '%' || q || '%'
              or lower(coalesce(b.name, '')) like '%' || q || '%'
              or (length(digits) >= 4 and (regexp_replace(coalesce(p.phone, ''), '\D', '', 'g') like '%' || digits || '%'
                                         or regexp_replace(coalesce(o.phone, ''), '\D', '', 'g') like '%' || digits || '%'
                                         or regexp_replace(coalesce(b.phone, ''), '\D', '', 'g') like '%' || digits || '%')))
       order by rank, last_active desc nulls last
       limit 20
    ) r;
  return out;
end;
$$;

/** One change, in words the portal can list: the table and something that names the row. */
create or replace function public.view_as_label(p_row jsonb)
returns text
language sql
immutable
as $$
  select left(coalesce(nullif(p_row ->> 'title', ''), nullif(p_row ->> 'name', ''), nullif(p_row ->> 'property_id', ''),
                       nullif(p_row ->> 'phone', ''), nullif(p_row ->> 'email', ''), p_row ->> 'id', ''), 80);
$$;

/** Recent sessions, newest first, with what was changed and what's left to revert. */
create or replace function public.view_as_history(p_limit int default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_super_admin() then raise exception 'Not allowed.' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(x order by x.started_at desc)
      from (
        select s.id, s.target_id, s.target_email, s.target_name, s.mode, s.acted, s.started_at, s.ended_at, s.end_reason,
               s.outcome, s.reverted_at,
               (select count(*) from public.view_as_changes c where c.session_id = s.id) as changes,
               (select count(*) from public.view_as_changes c where c.session_id = s.id and c.state = '') as pending,
               (select count(*) from public.view_as_changes c where c.session_id = s.id and c.state = 'skipped') as skipped,
               (select count(*) from public.view_as_uploads up where up.session_id = s.id and not up.removed) as uploads
          from public.view_as_sessions s
         order by s.started_at desc
         limit greatest(1, least(coalesce(p_limit, 30), 200))
      ) x
  ), '[]'::jsonb);
end;
$$;

/** The changes one session made, oldest first. */
create or replace function public.view_as_session_changes(p_session uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_super_admin() then raise exception 'Not allowed.' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', c.id, 'at', c.at, 'tbl', c.tbl, 'op', c.op, 'state', c.state, 'note', c.note,
             'label', public.view_as_label(coalesce(c.new_row, c.old_row)),
             'fields', case when c.op = 'UPDATE' then (
               select coalesce(jsonb_agg(k.key), '[]'::jsonb) from jsonb_each(c.new_row) k
                where k.value is distinct from (c.old_row -> k.key) and k.key not in ('updated_at')
             ) end
           ) order by c.id)
      from public.view_as_changes c where c.session_id = p_session
  ), '[]'::jsonb);
end;
$$;

/** Changes kept on purpose: nothing to revert, says the history. */
create or replace function public.view_as_keep(p_session uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_super_admin() then raise exception 'Not allowed.' using errcode = '42501'; end if;
  update public.view_as_sessions set outcome = 'kept', ended_at = coalesce(ended_at, now()) where id = p_session and outcome = '';
end;
$$;

/** The primary-key columns of a table in public, in key order. */
create or replace function public.view_as_pk(p_tbl text)
returns text[]
language sql
stable
security definer
set search_path = public
as $$
  select array_agg(a.attname::text order by array_position(i.indkey::int2[], a.attnum))
    from pg_index i
    join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any (i.indkey::int2[])
   where i.indrelid = to_regclass('public.' || quote_ident(p_tbl)) and i.indisprimary;
$$;

/**
 * Puts back every row the session changed, newest change first, as it was
 * when actions were allowed. A row that has moved on since (someone else
 * changed it) is skipped and listed. Returns { reverted, skipped: [...] }.
 */
create or replace function public.view_as_revert(p_session uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c        record;
  pk       text[];
  cond     text;
  sets     text;
  cols     text;
  cur      jsonb;
  ok       int := 0;
  skipped  jsonb := '[]'::jsonb;
  rel      regclass;
begin
  if not public.is_super_admin() then raise exception 'Not allowed.' using errcode = '42501'; end if;
  if not exists (select 1 from public.view_as_sessions where id = p_session) then
    raise exception 'No such session.' using errcode = '22023';
  end if;
  -- These writes are the admin's own, not a view-as request.
  perform set_config('mz.view_as', 'none', true);

  for c in select * from public.view_as_changes where session_id = p_session and state = '' order by id desc loop
    begin
      rel := to_regclass('public.' || quote_ident(c.tbl));
      if rel is null then raise exception 'the table is gone'; end if;
      pk := public.view_as_pk(c.tbl);
      if pk is null or cardinality(pk) = 0 then raise exception 'the table has no primary key'; end if;
      cond := (select string_agg(format('t.%1$I is not distinct from r.%1$I', k), ' and ') from unnest(pk) k);
      execute format('select to_jsonb(t) from %s t, jsonb_populate_record(null::%s, $1) r where %s', rel, rel, cond)
        into cur using coalesce(c.new_row, c.old_row);

      if c.op = 'INSERT' then
        if cur is not null then
          if cur is distinct from c.new_row then raise exception 'changed since'; end if;
          execute format('delete from %s t using jsonb_populate_record(null::%s, $1) r where %s', rel, rel, cond) using c.new_row;
        end if;
      elsif c.op = 'UPDATE' then
        if cur is null then raise exception 'deleted since'; end if;
        if cur is distinct from c.new_row then raise exception 'changed since'; end if;
        select string_agg(format('%1$I = o.%1$I', a.attname), ', ') into sets
          from pg_attribute a
         where a.attrelid = rel and a.attnum > 0 and not a.attisdropped and a.attgenerated = '' and a.attidentity <> 'a';
        execute format('update %s t set %s from jsonb_populate_record(null::%s, $1) o, jsonb_populate_record(null::%s, $2) r where %s',
                       rel, sets, rel, rel, cond) using c.old_row, c.new_row;
      else -- DELETE
        if cur is not null then raise exception 'added back since'; end if;
        select string_agg(format('%I', a.attname), ', ' order by a.attnum) into cols
          from pg_attribute a
         where a.attrelid = rel and a.attnum > 0 and not a.attisdropped and a.attgenerated = '';
        execute format('insert into %s (%s) overriding system value select %s from jsonb_populate_record(null::%s, $1)',
                       rel, cols, cols, rel) using c.old_row;
      end if;
      update public.view_as_changes set state = 'reverted' where id = c.id;
      ok := ok + 1;
    exception when others then
      update public.view_as_changes set state = 'skipped', note = left(sqlerrm, 200) where id = c.id;
      skipped := skipped || jsonb_build_object('tbl', c.tbl, 'op', c.op, 'label', public.view_as_label(coalesce(c.new_row, c.old_row)),
                                               'why', left(sqlerrm, 200));
    end;
  end loop;

  update public.view_as_sessions
     set outcome = case when jsonb_array_length(skipped) = 0 then 'reverted' else 'partly' end,
         reverted_at = now(), ended_at = coalesce(ended_at, now())
   where id = p_session;
  return jsonb_build_object('reverted', ok, 'skipped', skipped);
end;
$$;

revoke all on function public.view_as_state() from public, anon, authenticated;
revoke all on function public.view_as_stat_tables() from public, anon, authenticated;
revoke all on function public.view_as_guard() from public, anon, authenticated;
revoke all on function public.view_as_log() from public, anon, authenticated;
revoke all on function public.view_as_protect_all() from public, anon, authenticated;
revoke all on function public.view_as_on_new_table() from public, anon, authenticated;
revoke all on function public.view_as_pk(text) from public, anon, authenticated;
revoke all on function public.view_as_label(jsonb) from public, anon, authenticated;
revoke all on function public.view_as_control(uuid, text, text, text) from public;
revoke all on function public.view_as_note_upload(uuid, text, text, text) from public;
revoke all on function public.view_as_search(text) from public, anon;
revoke all on function public.view_as_history(int) from public, anon;
revoke all on function public.view_as_session_changes(uuid) from public, anon;
revoke all on function public.view_as_keep(uuid) from public, anon;
revoke all on function public.view_as_revert(uuid) from public, anon;
-- The session's key is the permission: the browser holds it while signed in as the user.
grant execute on function public.view_as_control(uuid, text, text, text) to anon, authenticated;
grant execute on function public.view_as_note_upload(uuid, text, text, text) to anon, authenticated;
grant execute on function public.view_as_search(text) to authenticated;
grant execute on function public.view_as_history(int) to authenticated;
grant execute on function public.view_as_session_changes(uuid) to authenticated;
grant execute on function public.view_as_keep(uuid) to authenticated;
grant execute on function public.view_as_revert(uuid) to authenticated;
