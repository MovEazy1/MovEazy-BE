-- The rating a partner shows: on the To-Let poster and their public page.
--
--   · Every partner gets a rating the CRM can edit
--     (broker_partners.display_rating), seeded at random between 4.6 and 4.9.
--   · Once 10 or more tenants have rated them (partner_storefront_ratings),
--     their real average shows instead.
--   · partner_shown_rating(uid) → { rating, ratings, from_tenants }: the one
--     place that decides. The public page (partner_storefront), a tenant's
--     own rating (partner_storefront_rate) and the partner's poster
--     (partner_my_rating) all read it; the CRM's partner list shows both and
--     sets the rating (crm_partner_set_rating).
--
-- Replaces partner_storefront and partner_storefront_rate
-- (partner_storefront.sql) and partner_admin_list
-- (partner_referral_commission.sql): run this after those. Safe to re-run.

begin;

alter table public.broker_partners
  add column if not exists display_rating numeric(2,1) check (display_rating between 1 and 5);

/** 4.6, 4.7, 4.8 or 4.9. */
create or replace function public.partner_seed_rating()
returns numeric
language sql
volatile
as $$
  select (4.6 + floor(random() * 4) / 10)::numeric(2,1);
$$;

update public.broker_partners set display_rating = public.partner_seed_rating() where display_rating is null;

create or replace function public.broker_partners_seed_rating()
returns trigger
language plpgsql
as $$
begin
  if new.display_rating is null then new.display_rating := public.partner_seed_rating(); end if;
  return new;
end;
$$;
drop trigger if exists broker_partners_seed_rating on public.broker_partners;
create trigger broker_partners_seed_rating before insert on public.broker_partners
  for each row execute function public.broker_partners_seed_rating();

/** What a partner's rating reads: the tenants' average once 10+ have rated, the CRM's until then. */
create or replace function public.partner_shown_rating(p_broker uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with t as (select count(*)::int as n, round(avg(r.stars)::numeric, 1) as avg
               from public.partner_storefront_ratings r where r.broker_id = p_broker)
  select jsonb_build_object(
    'rating', case when t.n >= 10 then t.avg else (select b.display_rating from public.broker_partners b where b.user_id = p_broker) end,
    'ratings', t.n,
    'from_tenants', t.n >= 10)
    from t;
$$;
revoke all on function public.partner_shown_rating(uuid) from public, anon, authenticated;
revoke all on function public.partner_seed_rating() from public, anon, authenticated;
revoke all on function public.broker_partners_seed_rating() from public, anon, authenticated;

/** The calling partner's rating, for their poster. */
create or replace function public.partner_my_rating()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_approved_partner() then
    raise exception 'Only approved partners.' using errcode = '42501';
  end if;
  return public.partner_shown_rating(auth.uid());
end;
$$;

/** The CRM sets a partner's rating (1–5, one decimal). */
create or replace function public.crm_partner_set_rating(p_user uuid, p_rating numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.has_admin_scope('partners.manage') then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  if p_rating is null or p_rating < 1 or p_rating > 5 then
    raise exception 'A rating is between 1 and 5.' using errcode = '22023';
  end if;
  update public.broker_partners set display_rating = round(p_rating, 1), updated_at = now() where user_id = p_user;
end;
$$;

-- ── The public page, and a tenant's rating ──────────────────────────────────
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
        'since', p.approved_at) || public.partner_shown_rating(b.id)
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
  return public.partner_shown_rating(bid);
end;
$$;

-- ── The CRM's partner list, now with ratings ────────────────────────────────
drop function if exists public.partner_admin_list();
create function public.partner_admin_list()
returns table (user_id uuid, name text, phone text, email text, agency text, status text,
               created_at timestamptz, approved_at timestamptz, approved_by text,
               listing_count int, group_count int, premium_until timestamptz, client_share_pct numeric,
               trial_until timestamptz, referral_direct_pct numeric, referral_shared_pct numeric, referred_count int,
               display_rating numeric, tenant_ratings int, tenant_rating numeric)
language sql
stable
security definer
set search_path = public
as $$
  select p.user_id, p.name, p.phone, p.email, p.agency, p.status, p.created_at, p.approved_at, p.approved_by,
         (select count(*)::int from public.partner_listings l where l.broker_id = p.user_id),
         (select count(*)::int from public.partner_group_members m where m.user_id = p.user_id),
         (select max(e.ends_at) from public.partner_entitlements e
           where e.user_id = p.user_id and e.tier = 'moveazy_inventory' and e.plan <> 'trial' and now() < e.ends_at),
         p.client_share_pct,
         (select max(e.ends_at) from public.partner_entitlements e
           where e.user_id = p.user_id and e.tier = 'moveazy_inventory' and e.plan = 'trial' and now() < e.ends_at),
         p.referral_direct_pct, p.referral_shared_pct,
         (select count(*)::int from public.broker_partners x
           where p.referral_code is not null and x.referred_by = p.referral_code and x.user_id <> p.user_id),
         p.display_rating,
         (select count(*)::int from public.partner_storefront_ratings r where r.broker_id = p.user_id),
         (select round(avg(r.stars)::numeric, 1) from public.partner_storefront_ratings r where r.broker_id = p.user_id)
    from public.broker_partners p
   where public.is_crm_staff()
   order by case p.status when 'pending' then 0 when 'approved' then 1 else 2 end, p.created_at desc;
$$;

-- ── Grants ──────────────────────────────────────────────────────────────────
do $$
declare f text;
begin
  foreach f in array array[
    'public.partner_my_rating()', 'public.crm_partner_set_rating(uuid, numeric)', 'public.partner_admin_list()',
    'public.partner_storefront_rate(text, integer)', 'public.partner_storefront(text)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
grant execute on function public.partner_storefront(text) to anon;

commit;
