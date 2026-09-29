-- ─────────────────────────────────────────────────────────────────────────────
-- Partner storefronts — a broker's QR poster and the page it opens
-- (fe/src/pages/partners/MyQrPage.jsx, fe/src/pages/Storefront.jsx,
-- fe/src/lib/storefront.js).
--
-- Run in the Supabase SQL editor AFTER partner_schema.sql (broker_partners,
-- partner_listings, is_approved_partner) and customer_schema.sql
-- (user_profiles). Safe to re-run.
--
-- A broker prints a poster with a QR code. The code opens
-- moveazy.co.in/b/<code>: the broker, their rating, and every flat they have
-- listed that is live. Tenants who open it are counted; tenants who sign in
-- can like a flat and rate the broker. The broker sees the counts, and who
-- liked what — the page tells a tenant that before they tap the heart.
--
--   partner_storefronts         one per broker: the printed code, the photo.
--   partner_storefront_views    one row per visitor per day (a device id, or
--                               the account when signed in), with whether they
--                               came from the QR or a shared link.
--   partner_storefront_likes    a signed-in tenant's heart on one flat.
--   partner_storefront_ratings  a signed-in tenant's 1–5 stars for the broker.
--
-- Nobody reads these tables directly. The public page reads through
-- partner_storefront(code), which returns only what a poster already shows
-- (the broker's name, agency, number and photo) and the flats that are live
-- on moveazy.co.in anyway; the broker reads their numbers through
-- partner_my_storefront().
-- ─────────────────────────────────────────────────────────────────────────────

begin;

create table if not exists public.partner_storefronts (
  broker_id  uuid primary key references auth.users (id) on delete cascade,
  code       text not null unique check (code ~ '^[A-HJ-NP-Z2-9]{6}$'),
  photo_url  text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.partner_storefront_views (
  broker_id  uuid not null references auth.users (id) on delete cascade,
  visitor    text not null check (length(visitor) between 8 and 64),
  day        date not null default (now() at time zone 'Asia/Kolkata')::date,
  source     text not null default 'link' check (source in ('qr', 'link')),
  user_id    uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (broker_id, visitor, day)
);
create index if not exists partner_storefront_views_day_idx on public.partner_storefront_views (broker_id, day desc);

create table if not exists public.partner_storefront_likes (
  broker_id   uuid not null references auth.users (id) on delete cascade,
  user_id     uuid not null references auth.users (id) on delete cascade,
  property_id text not null references public.inventory (property_id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (broker_id, user_id, property_id)
);
create index if not exists partner_storefront_likes_recent_idx on public.partner_storefront_likes (broker_id, created_at desc);

create table if not exists public.partner_storefront_ratings (
  broker_id  uuid not null references auth.users (id) on delete cascade,
  user_id    uuid not null references auth.users (id) on delete cascade,
  stars      int not null check (stars between 1 and 5),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (broker_id, user_id)
);

-- ── Helpers ──────────────────────────────────────────────────────────────────

/** The approved broker behind a printed code, or null. */
create or replace function public.storefront_broker(p_code text)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select s.broker_id
    from public.partner_storefronts s
    join public.broker_partners p on p.user_id = s.broker_id and p.status = 'approved'
   where s.code = upper(trim(coalesce(p_code, '')));
$$;

/** A broker's live flats: their partner listings that are published. */
create or replace function public.storefront_homes(p_broker uuid)
returns setof public.inventory
language sql
stable
security definer
set search_path = public
as $$
  select i.*
    from public.partner_listings pl
    join public.inventory i on i.property_id = pl.property_id
   where pl.broker_id = p_broker and i.status = 'published'
   order by i.updated_at desc nulls last, i.created_at desc;
$$;

-- ── The public page ──────────────────────────────────────────────────────────
/**
 * What moveazy.co.in/b/<code> shows. Null when the code is unknown or the
 * broker is not an approved partner. The listing columns are the public ones.
 */
create or replace function public.partner_storefront(p_code text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with b as (select public.storefront_broker(p_code) as id)
  select case when b.id is null then null else jsonb_build_object(
    'code', upper(trim(p_code)),
    'broker', (
      select jsonb_build_object(
        'name', p.name, 'agency', p.agency, 'phone', p.phone, 'photo_url', s.photo_url,
        'rating', (select round(avg(r.stars)::numeric, 1) from public.partner_storefront_ratings r where r.broker_id = b.id),
        'ratings', (select count(*) from public.partner_storefront_ratings r where r.broker_id = b.id),
        'since', p.approved_at)
        from public.broker_partners p join public.partner_storefronts s on s.broker_id = p.user_id
       where p.user_id = b.id),
    'homes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'property_id', h.property_id, 'title', h.title, 'city', h.city, 'area', h.area,
        'rent', h.rent, 'deposit', h.deposit, 'available_from', h.available_from,
        'property_type', h.property_type, 'flat_type', h.flat_type, 'bedrooms', h.bedrooms,
        'bathrooms', h.bathrooms, 'furnishing', h.furnishing, 'images', h.images,
        'cover_image_url', h.cover_image_url, 'is_verified', h.is_verified))
        from public.storefront_homes(b.id) h), '[]'::jsonb),
    'liked', coalesce((
      select jsonb_agg(l.property_id) from public.partner_storefront_likes l
       where l.broker_id = b.id and l.user_id = auth.uid()), '[]'::jsonb),
    'my_rating', (select r.stars from public.partner_storefront_ratings r where r.broker_id = b.id and r.user_id = auth.uid()),
    'is_mine', b.id = auth.uid()
  ) end
  from b;
$$;

/** Count one visit. A visitor counts once a day; the broker's own visits don't count. */
create or replace function public.partner_storefront_view(p_code text, p_visitor text, p_source text default 'link')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  bid uuid := public.storefront_broker(p_code);
  who text := coalesce(auth.uid()::text, left(trim(coalesce(p_visitor, '')), 64));
begin
  if bid is null or bid = auth.uid() or length(who) < 8 then return; end if;
  insert into public.partner_storefront_views (broker_id, visitor, source, user_id)
  values (bid, who, case when p_source = 'qr' then 'qr' else 'link' end, auth.uid())
  on conflict (broker_id, visitor, day) do nothing;
end;
$$;

/** Like or unlike one of the broker's live flats. Signed in only. */
create or replace function public.partner_storefront_like(p_code text, p_property text, p_on boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  bid uuid := public.storefront_broker(p_code);
begin
  if auth.uid() is null then raise exception 'Sign in to like a home.' using errcode = '42501'; end if;
  if bid is null then raise exception 'This storefront is not available.' using errcode = '22023'; end if;
  if not exists (select 1 from public.storefront_homes(bid) h where h.property_id = p_property) then
    raise exception 'That home is not on this storefront.' using errcode = '22023';
  end if;
  if p_on then
    insert into public.partner_storefront_likes (broker_id, user_id, property_id)
    values (bid, auth.uid(), p_property) on conflict do nothing;
  else
    delete from public.partner_storefront_likes
     where broker_id = bid and user_id = auth.uid() and property_id = p_property;
  end if;
  return p_on;
end;
$$;

/** Rate the broker 1–5. Signed in only, once per tenant (a new rating replaces it), never yourself. */
create or replace function public.partner_storefront_rate(p_code text, p_stars int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  bid uuid := public.storefront_broker(p_code);
begin
  if auth.uid() is null then raise exception 'Sign in to rate.' using errcode = '42501'; end if;
  if bid is null then raise exception 'This storefront is not available.' using errcode = '22023'; end if;
  if bid = auth.uid() then raise exception 'You cannot rate yourself.' using errcode = '42501'; end if;
  if p_stars is null or p_stars not between 1 and 5 then
    raise exception 'A rating is 1 to 5 stars.' using errcode = '22023';
  end if;
  insert into public.partner_storefront_ratings as r (broker_id, user_id, stars)
  values (bid, auth.uid(), p_stars)
  on conflict (broker_id, user_id) do update set stars = excluded.stars, updated_at = now();
  return jsonb_build_object(
    'rating', (select round(avg(r.stars)::numeric, 1) from public.partner_storefront_ratings r where r.broker_id = bid),
    'ratings', (select count(*) from public.partner_storefront_ratings r where r.broker_id = bid));
end;
$$;

-- ── The broker's side ────────────────────────────────────────────────────────
/**
 * The calling partner's storefront — made on first call — with its numbers:
 * visitors (all time, this week), QR scans per day for the last 7 days, likes,
 * and the latest likes with who liked what.
 */
create or replace function public.partner_my_storefront()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid  uuid := auth.uid();
  c    text;
  i    int;
  today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if not public.is_approved_partner() then
    raise exception 'Only approved partners have a storefront.' using errcode = '42501';
  end if;

  if not exists (select 1 from public.partner_storefronts where broker_id = uid) then
    for i in 1..25 loop
      select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '')
        into c from generate_series(1, 6);
      begin
        insert into public.partner_storefronts (broker_id, code) values (uid, c);
        exit;
      exception when unique_violation then
        if exists (select 1 from public.partner_storefronts where broker_id = uid) then exit; end if;
      end;
    end loop;
  end if;

  return (
    select jsonb_build_object(
      'code', s.code,
      'photo_url', s.photo_url,
      'rating', (select round(avg(r.stars)::numeric, 1) from public.partner_storefront_ratings r where r.broker_id = uid),
      'ratings', (select count(*) from public.partner_storefront_ratings r where r.broker_id = uid),
      'homes', (select count(*) from public.storefront_homes(uid)),
      'visitors', (select count(distinct v.visitor) from public.partner_storefront_views v where v.broker_id = uid),
      'visitors_week', (select count(distinct v.visitor) from public.partner_storefront_views v
                         where v.broker_id = uid and v.day > today - 7),
      'scans_week', (select count(*) from public.partner_storefront_views v
                      where v.broker_id = uid and v.source = 'qr' and v.day > today - 7),
      'by_day', (
        select jsonb_agg(jsonb_build_object('day', d::date, 'views', (
                 select count(*) from public.partner_storefront_views v where v.broker_id = uid and v.day = d::date),
                 'scans', (
                 select count(*) from public.partner_storefront_views v where v.broker_id = uid and v.day = d::date and v.source = 'qr'))
                 order by d)
          from generate_series(today - 6, today, interval '1 day') d),
      'likes_total', (select count(*) from public.partner_storefront_likes l where l.broker_id = uid),
      'likes', coalesce((
        select jsonb_agg(x order by (x ->> 'at') desc) from (
          select jsonb_build_object(
                   'name', coalesce(nullif(up.name, ''), 'A tenant'),
                   'phone', coalesce(up.phone, ''),
                   'property_id', l.property_id,
                   'flat_type', inv.flat_type, 'area', inv.area, 'rent', inv.rent,
                   'cover_image_url', inv.cover_image_url, 'images', inv.images,
                   'at', l.created_at) as x
            from public.partner_storefront_likes l
            left join public.user_profiles up on up.id = l.user_id
            join public.inventory inv on inv.property_id = l.property_id
           where l.broker_id = uid
           order by l.created_at desc
           limit 50) q), '[]'::jsonb)
    )
    from public.partner_storefronts s where s.broker_id = uid
  );
end;
$$;

/**
 * Set (or clear, with '') the photo on the poster and the storefront. Only a
 * photo the broker uploaded to their own folder of the partner-photos bucket.
 */
create or replace function public.partner_set_storefront_photo(p_url text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  u text := trim(coalesce(p_url, ''));
begin
  if not public.is_approved_partner() then
    raise exception 'Only approved partners have a storefront.' using errcode = '42501';
  end if;
  if u <> '' and (length(u) > 600
      or u !~ ('^https://[A-Za-z0-9.-]+/storage/v1/object/public/partner-photos/' || auth.uid()::text || '/[^?#]+$')) then
    raise exception 'Upload the photo from the app.' using errcode = '22023';
  end if;
  update public.partner_storefronts set photo_url = u, updated_at = now() where broker_id = auth.uid();
  if not found then
    raise exception 'Open My QR first.' using errcode = '22023';
  end if;
  return u;
end;
$$;

-- ── Row access ──────────────────────────────────────────────────────────────
alter table public.partner_storefronts        enable row level security;
alter table public.partner_storefront_views   enable row level security;
alter table public.partner_storefront_likes   enable row level security;
alter table public.partner_storefront_ratings enable row level security;

do $$
declare t text;
begin
  foreach t in array array['partner_storefronts', 'partner_storefront_views', 'partner_storefront_likes', 'partner_storefront_ratings'] loop
    execute format('drop policy if exists "staff read" on public.%I', t);
    execute format('create policy "staff read" on public.%I for select to authenticated using (public.is_crm_staff())', t);
  end loop;
end $$;

-- Supabase hands anon everything in public by default; take it back. Staff
-- read through the policy above; everyone else goes through the functions.
revoke all on public.partner_storefronts, public.partner_storefront_views,
              public.partner_storefront_likes, public.partner_storefront_ratings
  from public, anon, authenticated;
grant select on public.partner_storefronts, public.partner_storefront_views,
                public.partner_storefront_likes, public.partner_storefront_ratings
  to authenticated;

revoke all on function public.storefront_broker(text) from public, anon, authenticated;
revoke all on function public.storefront_homes(uuid) from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array[
    'public.partner_storefront(text)',
    'public.partner_storefront_view(text, text, text)',
    'public.partner_storefront_like(text, text, boolean)',
    'public.partner_storefront_rate(text, int)',
    'public.partner_my_storefront()',
    'public.partner_set_storefront_photo(text)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
-- The two signed-out calls: opening the page, and counting the visit.
grant execute on function public.partner_storefront(text) to anon;
grant execute on function public.partner_storefront_view(text, text, text) to anon;

commit;

-- ── Photos ───────────────────────────────────────────────────────────────────
-- A public bucket: the photo is printed on a poster and shown on the public
-- page. Paths are <broker uid>/<file>; a broker writes only their own folder.
-- Outside the transaction: on some projects the SQL editor may not create
-- policies on storage.objects, and that must not roll back the rest. If it is
-- refused, create the bucket and the policy from the dashboard.
do $$
begin
  if to_regclass('storage.buckets') is null then
    raise notice 'No storage schema here — skipping the partner-photos bucket.';
    return;
  end if;
  begin
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('partner-photos', 'partner-photos', true, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
    on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit,
                                   allowed_mime_types = excluded.allowed_mime_types;
    execute 'drop policy if exists "partner photos: own folder" on storage.objects';
    execute $p$
      create policy "partner photos: own folder" on storage.objects
        for all to authenticated
        using (bucket_id = 'partner-photos' and (storage.foldername(name))[1] = auth.uid()::text)
        with check (bucket_id = 'partner-photos' and (storage.foldername(name))[1] = auth.uid()::text
                    and public.is_approved_partner())
    $p$;
  exception when insufficient_privilege then
    raise notice 'Could not create the partner-photos policy (%). Create it from the dashboard.', sqlerrm;
  end;
end $$;


-- == Verify ==================================================================
-- 1. anon holds nothing on the storefront tables (expect zero rows):
--      select table_name, privilege_type from information_schema.role_table_grants
--       where grantee = 'anon' and table_name like 'partner_storefront%';
-- 2. tests/storefront_check.mjs covers every rule above.
