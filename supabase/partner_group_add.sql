-- Add a partner to a group by mobile number — from the partner app and from
-- the CRM (Brokers → Unions).
--
-- Run in the Supabase SQL editor AFTER partner_schema.sql,
-- partner_contact_phone.sql (broker_partners.alt_phone), partner_launch.sql
-- (partner_notifications) and crm_schema.sql (is_crm_staff). Safe to re-run.
--
-- Decided 2026-11-18:
--   * Any member of a group may add a partner by number (as with invite links).
--   * An approved partner on that number is in straight away, and told so in
--     the app; the group's owner and admins are told who joined and who added
--     them. They can leave any time.
--   * A number that isn't an approved partner yet (never signed up, or still
--     pending approval) holds a spot — "Invited" — for 30 days, and joins on
--     its own the moment that number is an approved partner.
--   * The CRM (any CRM staff) sees every group with its owner and admins, adds
--     and removes members, changes admins and the owner, creates groups and
--     renames them. It does not delete groups.

begin;

/* ── Invited numbers ─────────────────────────────────────────────────────── */

create table if not exists public.partner_group_pending (
  id             uuid primary key default gen_random_uuid(),
  group_id       uuid not null references public.partner_groups (id) on delete cascade,
  phone          text not null check (phone ~ '^[6-9][0-9]{9}$'),
  added_by       uuid references auth.users (id) on delete set null,
  added_by_label text not null default '',
  created_at     timestamptz not null default now(),
  expires_at     timestamptz not null default now() + interval '30 days',
  unique (group_id, phone)
);
create index if not exists partner_group_pending_phone_idx on public.partner_group_pending (phone);
alter table public.partner_group_pending enable row level security;
revoke all on public.partner_group_pending from public, anon, authenticated;

-- Two new notification kinds: 'group_added' (you were added) and 'group_joined'
-- (to the owner and admins). The kinds already allowed are kept.
do $$
declare
  d    text;
  vals text[];
begin
  select pg_get_constraintdef(oid) into d from pg_constraint where conname = 'partner_notifications_kind_check';
  if d is not null and position('group_joined' in d) = 0 then
    -- The definition reads either ANY (ARRAY['a'::text, …]) or ANY ('{a,b,…}'::text[])
    -- (after an earlier re-write): take every word in it but the SQL ones, plus
    -- every kind already stored, so no existing row can fall outside.
    vals := array(
      select w from (
        select (regexp_matches(d, '[a-z][a-z_]*', 'g'))[1] as w
        union select kind from public.partner_notifications
        union select unnest(array['group_added', 'group_joined'])
      ) x
      where w not in ('kind', 'any', 'array', 'text', 'check')
      order by w);
    alter table public.partner_notifications drop constraint partner_notifications_kind_check;
    execute format('alter table public.partner_notifications add constraint partner_notifications_kind_check check (kind = any (%L::text[]))', vals);
  end if;
end $$;

/* ── Joining ─────────────────────────────────────────────────────────────── */

/** Put a partner in a group and tell them and the group's owner/admins. True when they were not in it already. Internal. */
create or replace function public.partner_group_join(p_group uuid, p_user uuid, p_added_by uuid, p_by text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  gname text;
  who   text;
  n     int;
begin
  insert into public.partner_group_members (group_id, user_id, role, added_by)
  values (p_group, p_user, 'member', p_added_by)
  on conflict (group_id, user_id) do nothing;
  get diagnostics n = row_count;
  if n = 0 then return false; end if;

  update public.broker_partners
     set joined_via_group = coalesce(joined_via_group, p_group), updated_at = now()
   where user_id = p_user;
  select g.name into gname from public.partner_groups g where g.id = p_group;
  select coalesce(nullif(b.name, ''), 'A partner') into who from public.broker_partners b where b.user_id = p_user;

  insert into public.partner_notifications (broker_id, kind, title, body, link)
  values (p_user, 'group_added', coalesce(nullif(p_by, ''), 'A partner') || ' added you to ' || gname,
          'You now see the flats its members share. You can leave the group any time.', '/groups/' || p_group);
  insert into public.partner_notifications (broker_id, kind, title, body, link)
  select m.user_id, 'group_joined', coalesce(who, 'A partner') || ' joined ' || gname,
         'Added by ' || coalesce(nullif(p_by, ''), 'a partner') || '.', '/groups/' || p_group
    from public.partner_group_members m
   where m.group_id = p_group and m.role in ('owner', 'admin')
     and m.user_id <> p_user and m.user_id is distinct from p_added_by;
  return true;
end;
$$;

/**
 * Add the partner on this number, or hold a spot for the number. Internal:
 * the caller has checked who may. → { status: 'added' | 'already' | 'invited',
 * name, phone, signed_up }.
 */
create or replace function public.partner_group_add_phone(p_group uuid, p_phone text, p_by_uid uuid, p_by text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  ph text := public.normalize_mobile(p_phone);
  bp public.broker_partners;
begin
  if ph = '' then
    raise exception 'Enter a valid 10-digit mobile number.' using errcode = '22023';
  end if;
  if not exists (select 1 from public.partner_groups where id = p_group) then
    raise exception 'That group no longer exists.' using errcode = '22023';
  end if;

  select * into bp from public.broker_partners b
   where b.phone = ph or b.alt_phone = ph
   order by (b.status = 'approved') desc, (b.phone = ph) desc, b.created_at
   limit 1;

  if bp.user_id is not null and bp.status = 'suspended' then
    raise exception 'This number can''t be added to a group.' using errcode = '22023';
  end if;

  if bp.user_id is not null and bp.status = 'approved' then
    if public.partner_group_join(p_group, bp.user_id, p_by_uid, p_by) then
      delete from public.partner_group_pending where group_id = p_group and phone = ph;
      return jsonb_build_object('status', 'added', 'name', bp.name, 'phone', ph, 'signed_up', true);
    end if;
    return jsonb_build_object('status', 'already', 'name', bp.name, 'phone', ph, 'signed_up', true);
  end if;

  insert into public.partner_group_pending (group_id, phone, added_by, added_by_label)
  values (p_group, ph, p_by_uid, left(coalesce(p_by, ''), 120))
  on conflict (group_id, phone) do update
     set added_by = excluded.added_by, added_by_label = excluded.added_by_label,
         created_at = now(), expires_at = now() + interval '30 days';
  return jsonb_build_object('status', 'invited', 'name', coalesce(bp.name, ''), 'phone', ph, 'signed_up', bp.user_id is not null);
end;
$$;

/** Any member of a group may add a partner by number. */
create or replace function public.partner_add_member_by_phone(p_group uuid, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid  uuid := auth.uid();
  me   text;
begin
  if not (public.is_approved_partner() and public.is_partner_group_member(p_group)) then
    raise exception 'Only members of this group can add partners.' using errcode = '42501';
  end if;
  -- A brake on a runaway or abused account, far above real use.
  if (select count(*) from public.partner_group_pending where added_by = uid and created_at > now() - interval '1 day') >= 100 then
    raise exception 'That''s a lot of numbers for one day — try again tomorrow.' using errcode = '22023';
  end if;
  select coalesce(nullif(b.name, ''), 'A partner') into me from public.broker_partners b where b.user_id = uid;
  return public.partner_group_add_phone(p_group, p_phone, uid, me);
end;
$$;

/** Numbers waiting to join: all of them for the owner, admins and CRM; the ones you added for everyone else. */
create or replace function public.partner_group_pending_list(p_group uuid)
returns table (id uuid, phone text, added_by_label text, mine boolean, created_at timestamptz, expires_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select p.id, p.phone, p.added_by_label, p.added_by = auth.uid(), p.created_at, p.expires_at
    from public.partner_group_pending p
   where p.group_id = p_group and p.expires_at > now()
     and (public.is_crm_staff()
          or exists (select 1 from public.partner_group_members m
                      where m.group_id = p_group and m.user_id = auth.uid() and m.role in ('owner', 'admin'))
          or (p.added_by = auth.uid() and public.is_partner_group_member(p_group)))
   order by p.created_at desc;
$$;

create or replace function public.partner_cancel_pending(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare r public.partner_group_pending;
begin
  select * into r from public.partner_group_pending where id = p_id;
  if not found then return; end if;
  if not (r.added_by = auth.uid() or public.is_crm_staff()
          or exists (select 1 from public.partner_group_members m
                      where m.group_id = r.group_id and m.user_id = auth.uid() and m.role in ('owner', 'admin'))) then
    raise exception 'Only the group''s admins, or whoever added this number, can cancel it.' using errcode = '42501';
  end if;
  delete from public.partner_group_pending where id = p_id;
end;
$$;

/** A number becomes an approved partner (sign-up, CRM approval, a new number): it joins the groups holding a spot for it. */
create or replace function public.partner_group_pending_join()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare r record;
begin
  if new.status <> 'approved' then return new; end if;
  for r in
    select p.* from public.partner_group_pending p
     where p.phone in (new.phone, nullif(new.alt_phone, '')) and p.expires_at > now()
  loop
    perform public.partner_group_join(r.group_id, new.user_id, r.added_by, r.added_by_label);
    delete from public.partner_group_pending where id = r.id;
  end loop;
  return new;
exception when others then
  -- Joining a group must never stand between a broker and their approval.
  raise warning 'partner_group_pending_join(%): %', new.user_id, sqlerrm;
  return new;
end;
$$;

drop trigger if exists partner_group_pending_join on public.broker_partners;
create trigger partner_group_pending_join
  after insert or update of status, phone, alt_phone on public.broker_partners
  for each row execute function public.partner_group_pending_join();

/* ── CRM: Brokers → Unions ───────────────────────────────────────────────── */

create or replace function public.crm_partner_groups()
returns table (id uuid, name text, description text, city text, created_at timestamptz, created_by_name text,
               member_count int, property_count int, invited_count int, admins jsonb)
language sql
stable
security definer
set search_path = public
as $$
  select g.id, g.name, g.description, g.city, g.created_at, coalesce(cb.name, ''),
         (select count(*)::int from public.partner_group_members x where x.group_id = g.id),
         (select count(*)::int from public.partner_group_shares s
            join public.inventory i on i.property_id = s.property_id
           where s.group_id = g.id and i.status = 'published'),
         (select count(*)::int from public.partner_group_pending p where p.group_id = g.id and p.expires_at > now()),
         coalesce((select jsonb_agg(jsonb_build_object('user_id', m.user_id, 'name', coalesce(b.name, ''), 'phone', coalesce(b.phone, ''), 'role', m.role)
                                    order by case m.role when 'owner' then 0 else 1 end, m.joined_at)
                     from public.partner_group_members m
                     left join public.broker_partners b on b.user_id = m.user_id
                    where m.group_id = g.id and m.role in ('owner', 'admin')), '[]'::jsonb)
    from public.partner_groups g
    left join public.broker_partners cb on cb.user_id = g.created_by
   where public.is_crm_staff()
   order by g.created_at desc;
$$;

create or replace function public.crm_group_add_member(p_group uuid, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then
    raise exception 'Only the MovEazy team can do this.' using errcode = '42501';
  end if;
  return public.partner_group_add_phone(p_group, p_phone, auth.uid(), 'MovEazy');
end;
$$;

create or replace function public.crm_group_remove_member(p_group uuid, p_user uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then
    raise exception 'Only the MovEazy team can do this.' using errcode = '42501';
  end if;
  if exists (select 1 from public.partner_group_members where group_id = p_group and user_id = p_user and role = 'owner') then
    raise exception 'Make someone else the owner before removing this one.' using errcode = '22023';
  end if;
  delete from public.partner_group_members where group_id = p_group and user_id = p_user;
end;
$$;

/** 'admin' | 'member' — or 'owner', which hands the group over (the old owner stays as an admin). */
create or replace function public.crm_group_set_role(p_group uuid, p_user uuid, p_role text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare cur text;
begin
  if not public.is_crm_staff() then
    raise exception 'Only the MovEazy team can do this.' using errcode = '42501';
  end if;
  if p_role not in ('owner', 'admin', 'member') then
    raise exception 'Role must be owner, admin or member.' using errcode = '22023';
  end if;
  select role into cur from public.partner_group_members where group_id = p_group and user_id = p_user;
  if cur is null then raise exception 'They are not in this group.' using errcode = '22023'; end if;
  if cur = p_role then return; end if;
  if cur = 'owner' then
    raise exception 'Make someone else the owner first.' using errcode = '22023';
  end if;
  if p_role = 'owner' then
    update public.partner_group_members set role = 'admin' where group_id = p_group and role = 'owner';
  end if;
  update public.partner_group_members set role = p_role where group_id = p_group and user_id = p_user;
end;
$$;

/** A new group, owned by the approved partner on p_owner_phone. */
create or replace function public.crm_create_group(p_name text, p_description text, p_owner_phone text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  ph  text := public.normalize_mobile(p_owner_phone);
  own uuid;
  gid uuid;
begin
  if not public.is_crm_staff() then
    raise exception 'Only the MovEazy team can do this.' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_name, ''))) not between 2 and 80 then
    raise exception 'Give the union a name (2–80 letters).' using errcode = '22023';
  end if;
  select b.user_id into own from public.broker_partners b
   where (b.phone = ph or b.alt_phone = ph) and b.status = 'approved' and ph <> ''
   order by (b.phone = ph) desc limit 1;
  if own is null then
    raise exception 'The owner must be an approved MovEazy partner — no approved partner has that number.' using errcode = '22023';
  end if;
  insert into public.partner_groups (name, description, created_by)
  values (trim(p_name), left(coalesce(trim(p_description), ''), 400), own)
  returning id into gid;
  insert into public.partner_group_members (group_id, user_id, role, added_by) values (gid, own, 'owner', auth.uid());
  insert into public.partner_notifications (broker_id, kind, title, body, link)
  values (own, 'group_added', 'MovEazy made you the owner of ' || trim(p_name),
          'Add partners by mobile number or invite link, and share flats with the group.', '/groups/' || gid);
  return gid;
end;
$$;

create or replace function public.crm_update_group(p_group uuid, p_name text, p_description text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_crm_staff() then
    raise exception 'Only the MovEazy team can do this.' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_name, ''))) not between 2 and 80 then
    raise exception 'Give the union a name (2–80 letters).' using errcode = '22023';
  end if;
  update public.partner_groups set name = trim(p_name), description = left(coalesce(trim(p_description), ''), 400)
   where id = p_group;
end;
$$;

/* ── Grants ──────────────────────────────────────────────────────────────── */

revoke all on function public.partner_group_join(uuid, uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.partner_group_add_phone(uuid, text, uuid, text) from public, anon, authenticated;
revoke all on function public.partner_group_pending_join() from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array[
    'public.partner_add_member_by_phone(uuid, text)', 'public.partner_group_pending_list(uuid)', 'public.partner_cancel_pending(uuid)',
    'public.crm_partner_groups()', 'public.crm_group_add_member(uuid, text)', 'public.crm_group_remove_member(uuid, uuid)',
    'public.crm_group_set_role(uuid, uuid, text)', 'public.crm_create_group(text, text, text)', 'public.crm_update_group(uuid, text, text)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

commit;
