-- A partner's second mobile number, and which of the two is their primary
-- contact.
--
--   · broker_partners.phone stays the number they sign in with. A second one
--     goes in broker_partners.alt_phone (one at a time: a new one replaces
--     it), and contact_primary says which is the contact number: 'main' or
--     'alt'. No OTP: a valid 10-digit Indian mobile that isn't the main one.
--   · partner_contact_phone(uid) is the number to show and call: their To-Let
--     poster, their public page (partner_storefront), and first in the CRM's
--     partner list, the other shown as secondary. Their Profile shows both.
--   · partner_set_contact(p_phone, p_primary): add, change or (empty) remove
--     the second number, and pick the primary.
--
-- Replaces partner_storefront and partner_admin_list (partner_display_rating.sql):
-- run this after that. Safe to re-run.

begin;

alter table public.broker_partners
  add column if not exists alt_phone text not null default '',
  add column if not exists contact_primary text not null default 'main' check (contact_primary in ('main', 'alt'));

/** The number to show and call: the second one when they made it primary. */
create or replace function public.partner_contact_phone(p_broker uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case when b.contact_primary = 'alt' and b.alt_phone <> '' then b.alt_phone else coalesce(b.phone, '') end
    from public.broker_partners b where b.user_id = p_broker;
$$;
revoke all on function public.partner_contact_phone(uuid) from public, anon, authenticated;

/**
 * Add, change or remove (empty p_phone) the partner's second number, and pick
 * which one is primary ('main' | 'alt'). → { phone, alt_phone, contact_primary, contact }
 */
create or replace function public.partner_set_contact(p_phone text, p_primary text default 'main')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me    public.broker_partners;
  alt   text := public.normalize_mobile(p_phone);
  prim  text := case when p_primary = 'alt' then 'alt' else 'main' end;
begin
  select * into me from public.broker_partners where user_id = auth.uid();
  if me.user_id is null or not public.is_approved_partner() then
    raise exception 'Only approved partners.' using errcode = '42501';
  end if;
  if btrim(coalesce(p_phone, '')) <> '' and alt = '' then
    raise exception 'Enter a 10-digit mobile number.' using errcode = '22023';
  end if;
  if alt <> '' and alt = public.normalize_mobile(me.phone) then
    raise exception 'That''s already your main number.' using errcode = '22023';
  end if;
  if alt = '' then prim := 'main'; end if;
  update public.broker_partners set alt_phone = alt, contact_primary = prim, updated_at = now()
   where user_id = me.user_id
  returning * into me;
  return jsonb_build_object('phone', me.phone, 'alt_phone', me.alt_phone, 'contact_primary', me.contact_primary,
                            'contact', public.partner_contact_phone(me.user_id));
end;
$$;

-- ── The public page: the primary contact number ─────────────────────────────
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
        'name', p.name, 'agency', p.agency, 'phone', public.partner_contact_phone(p.user_id), 'photo_url', s.photo_url,
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

-- ── The CRM's partner list, with both numbers ───────────────────────────────
drop function if exists public.partner_admin_list();
create function public.partner_admin_list()
returns table (user_id uuid, name text, phone text, email text, agency text, status text,
               created_at timestamptz, approved_at timestamptz, approved_by text,
               listing_count int, group_count int, premium_until timestamptz, client_share_pct numeric,
               trial_until timestamptz, referral_direct_pct numeric, referral_shared_pct numeric, referred_count int,
               display_rating numeric, tenant_ratings int, tenant_rating numeric, alt_phone text, contact_primary text)
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
         (select round(avg(r.stars)::numeric, 1) from public.partner_storefront_ratings r where r.broker_id = p.user_id),
         p.alt_phone, p.contact_primary
    from public.broker_partners p
   where public.is_crm_staff()
   order by case p.status when 'pending' then 0 when 'approved' then 1 else 2 end, p.created_at desc;
$$;

-- ── Grants ──────────────────────────────────────────────────────────────────
do $$
declare f text;
begin
  foreach f in array array['public.partner_set_contact(text, text)', 'public.partner_admin_list()', 'public.partner_storefront(text)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
grant execute on function public.partner_storefront(text) to anon;

commit;
