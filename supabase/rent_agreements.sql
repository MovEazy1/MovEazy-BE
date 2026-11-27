-- ─────────────────────────────────────────────────────────────────────────────
-- Rent agreements: a request (by an owner, broker or tenant) → routed to the
-- nearest local vendor → vendor prepares and uploads the stamped PDF → owner and
-- tenant e-sign through a link → saved with a renewal date.
--
-- Run in the Supabase SQL editor AFTER crm_schema.sql (is_super_admin,
-- is_crm_staff, has_admin_scope), admin_schema.sql (is_admin_allowlisted),
-- lead_intake.sql (normalize_mobile), customer_schema.sql (user_profiles) and
-- multi_city.sql (cities, normalize_city, city_of_area, crm_city_ok). Safe to
-- re-run.
--
-- Decisions (2026-11-27): simple e-sign (typed/drawn + Google-verified account +
-- timestamp, no Aadhaar e-sign provider); the vendor procures the e-stamp and
-- uploads the final stamped agreement; paid in-app up front (per-city price, with
-- a super-admin manual "mark paid" until the Razorpay gate is wired); requests
-- auto-route to the active vendor nearest the requester's current location, with
-- the city as the fallback; only owner + tenant sign; renewal reminders (owner +
-- tenant, not the broker) 30 days out with one-tap renew.
--
-- Aadhaar is sensitive: it lives in rent_agreements.tenant_aadhaar and is only
-- ever returned by the vendor- and super-admin-only functions, never in a
-- party- or requester-facing read.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

/* ── Settings: the per-city price (CRM-editable) ─────────────────────────────── */

create table if not exists public.rent_agreement_settings (
  city       text primary key references public.cities (name) on update cascade,
  price      int not null default 0 check (price between 0 and 1000000),
  updated_at timestamptz not null default now(),
  updated_by text not null default ''
);
insert into public.rent_agreement_settings (city, price)
  select name, 0 from public.cities on conflict (city) do nothing;
update public.rent_agreement_settings set price = 150 where city = 'Bengaluru' and price = 0;

alter table public.rent_agreement_settings enable row level security;
revoke all on public.rent_agreement_settings from anon, authenticated;

/* ── Vendors: the local agreement shops ──────────────────────────────────────── */

create table if not exists public.rent_vendors (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  email      text not null,                       -- Google sign-in, allow-listed
  phone      text not null default '',
  city       text not null references public.cities (name) on update cascade,
  area       text not null default '',            -- sub-locality label (e.g. HSR Layout)
  lat        numeric,
  lng        numeric,
  active     boolean not null default true,
  note       text not null default '',
  created_at timestamptz not null default now(),
  created_by text not null default ''
);
create unique index if not exists rent_vendors_email_idx on public.rent_vendors (lower(email));
create index if not exists rent_vendors_city_idx on public.rent_vendors (city) where active;

alter table public.rent_vendors enable row level security;
revoke all on public.rent_vendors from anon, authenticated;

/* ── Agreements ──────────────────────────────────────────────────────────────── */

create table if not exists public.rent_agreements (
  id               uuid primary key default gen_random_uuid(),
  city             text not null references public.cities (name) on update cascade,
  property_id      text,                           -- optional link to a listing
  requester_uid    uuid,
  requester_role   text not null check (requester_role in ('owner','broker','tenant')),
  req_lat          numeric,
  req_lng          numeric,
  vendor_id        uuid references public.rent_vendors (id) on delete set null,
  status           text not null default 'unpaid'
                     check (status in ('unpaid','with_vendor','ready_to_sign','partially_signed','completed','cancelled')),
  price            int not null default 0,
  paid             boolean not null default false,
  paid_at          timestamptz,
  paid_by          text not null default '',
  payment_ref      text not null default '',
  -- the deal terms we need as columns (routing, display, renewal); the rest in details
  rent             int,
  deposit          int,
  start_date       date,
  duration_months  int not null default 11,
  renewal_date     date,
  details          jsonb not null default '{}'::jsonb,
  tenant_aadhaar   text not null default '',       -- SENSITIVE — vendor/super only
  document_path    text not null default '',
  document_name    text not null default '',
  document_at      timestamptz,
  document_by      text not null default '',
  stamped          boolean not null default false,
  registered       boolean not null default false,
  renewed_from     uuid references public.rent_agreements (id) on delete set null,
  renewed_to       uuid references public.rent_agreements (id) on delete set null,
  renewal_reminded_at timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists rent_agreements_vendor_idx   on public.rent_agreements (vendor_id, status);
create index if not exists rent_agreements_city_idx     on public.rent_agreements (city, status);
create index if not exists rent_agreements_requester_idx on public.rent_agreements (requester_uid);
create index if not exists rent_agreements_renewal_idx  on public.rent_agreements (renewal_date) where status = 'completed';

alter table public.rent_agreements enable row level security;
revoke all on public.rent_agreements from anon, authenticated;

create or replace function public.rent_touch()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end;
$$;
drop trigger if exists rent_agreements_touch on public.rent_agreements;
create trigger rent_agreements_touch before update on public.rent_agreements
  for each row execute function public.rent_touch();

/* ── Parties: the signers (owner, tenant) ────────────────────────────────────── */

create table if not exists public.rent_agreement_parties (
  id            uuid primary key default gen_random_uuid(),
  agreement_id  uuid not null references public.rent_agreements (id) on delete cascade,
  role          text not null check (role in ('owner','tenant')),
  name          text not null default '',
  mobile        text not null default '',
  email         text not null default '',
  uid           uuid,
  sign_token    text not null default md5(gen_random_uuid()::text || gen_random_uuid()::text),
  signed        boolean not null default false,
  signed_at     timestamptz,
  signature_type text not null default '',          -- 'typed' | 'drawn'
  signature_data text not null default '',
  signed_ip     text not null default '',
  unique (agreement_id, role)
);
create unique index if not exists rent_parties_token_idx on public.rent_agreement_parties (sign_token);
create index if not exists rent_parties_agreement_idx on public.rent_agreement_parties (agreement_id);
create index if not exists rent_parties_uid_idx on public.rent_agreement_parties (uid);
create index if not exists rent_parties_email_idx on public.rent_agreement_parties (lower(email));
create index if not exists rent_parties_mobile_idx on public.rent_agreement_parties (mobile);

alter table public.rent_agreement_parties enable row level security;
revoke all on public.rent_agreement_parties from anon, authenticated;

/* ── Events: an audit trail ──────────────────────────────────────────────────── */

create table if not exists public.rent_agreement_events (
  id           uuid primary key default gen_random_uuid(),
  agreement_id uuid not null references public.rent_agreements (id) on delete cascade,
  kind         text not null,
  actor        text not null default '',
  meta         jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now()
);
create index if not exists rent_events_agreement_idx on public.rent_agreement_events (agreement_id, created_at);

alter table public.rent_agreement_events enable row level security;
revoke all on public.rent_agreement_events from anon, authenticated;

create or replace function public.rent_log(p_id uuid, p_kind text, p_meta jsonb default '{}'::jsonb)
returns void language sql security definer set search_path = public as $$
  insert into public.rent_agreement_events (agreement_id, kind, actor, meta)
  values (p_id, p_kind, lower(coalesce(auth.jwt() ->> 'email', '')), coalesce(p_meta, '{}'::jsonb));
$$;

commit;

-- ─────────────────────────────────────────────────────────────────────────────
-- Identity, pricing and routing helpers
-- ─────────────────────────────────────────────────────────────────────────────

/** The caller's OTP-verified mobile, from their profile (for matching parties). */
create or replace function public.rent_my_mobile()
returns text language sql stable security definer set search_path = public as $$
  select public.normalize_mobile(coalesce((select phone from public.user_profiles where id = auth.uid()), ''));
$$;

/** A city's agreement price (0 if unset; no Bengaluru fallback — price is local). */
create or replace function public.rent_price(p_city text)
returns int language sql stable security definer set search_path = public as $$
  select coalesce((select price from public.rent_agreement_settings
                    where city = coalesce(nullif(public.normalize_city(p_city), ''), 'Bengaluru')), 0);
$$;

/** Is the caller an active vendor? */
create or replace function public.rent_is_vendor()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.rent_vendors
                  where active and lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')));
$$;

/** The caller's vendor id, or null. */
create or replace function public.rent_vendor_id()
returns uuid language sql stable security definer set search_path = public as $$
  select id from public.rent_vendors
   where active and lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')) limit 1;
$$;

/** The active vendor nearest p_lat/p_lng in the city; the earliest in the city
    if coordinates are missing; null if the city has no active vendor. */
create or replace function public.rent_nearest_vendor(p_city text, p_lat numeric, p_lng numeric)
returns uuid language sql stable security definer set search_path = public as $$
  select v.id from public.rent_vendors v
   where v.active and v.city = coalesce(nullif(public.normalize_city(p_city), ''), p_city)
   order by
     case when p_lat is null or p_lng is null or v.lat is null or v.lng is null then 1 else 0 end,
     case when p_lat is null or p_lng is null or v.lat is null or v.lng is null then null
          else (v.lat - p_lat)^2 + ((v.lng - p_lng) * cos(radians(p_lat)))^2 end,
     v.created_at
   limit 1;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- JSON shaping
-- ─────────────────────────────────────────────────────────────────────────────

/** Parties as JSON. p_contact includes mobile/email; p_token includes sign tokens. */
create or replace function public.rent_parties_json(p_id uuid, p_contact boolean, p_token boolean)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'role', role, 'name', name, 'signed', signed, 'signed_at', signed_at,
           'signature_type', signature_type,
           'mobile', case when p_contact then mobile else null end,
           'email',  case when p_contact then email  else null end,
           'sign_token', case when p_token then sign_token else null end,
           'sign_url', case when p_token then '/rent/sign/' || sign_token else null end
         ) order by (role = 'owner') desc), '[]'::jsonb)
  from public.rent_agreement_parties where agreement_id = p_id;
$$;

/** One agreement as JSON. p_full = vendor/staff view (contact + Aadhaar). */
create or replace function public.rent_json(a public.rent_agreements, p_full boolean)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', a.id, 'city', a.city, 'property_id', a.property_id,
    'requester_role', a.requester_role, 'status', a.status,
    'price', a.price, 'paid', a.paid, 'paid_at', a.paid_at,
    'rent', a.rent, 'deposit', a.deposit,
    'start_date', a.start_date, 'duration_months', a.duration_months, 'renewal_date', a.renewal_date,
    'details', a.details,
    'tenant_aadhaar', case when p_full then nullif(a.tenant_aadhaar, '') else null end,
    'has_document', (a.document_path <> ''),
    'document_path', case when a.document_path <> '' then a.document_path else null end,
    'document_name', a.document_name, 'document_at', a.document_at,
    'stamped', a.stamped, 'registered', a.registered,
    'vendor', (select jsonb_build_object('id', v.id, 'name', v.name, 'area', v.area,
                        'phone', case when p_full then v.phone else null end)
                 from public.rent_vendors v where v.id = a.vendor_id),
    'parties', public.rent_parties_json(a.id, p_full, false),
    'renew_due', (a.status = 'completed' and a.renewed_to is null and a.renewal_date is not null
                   and a.renewal_date <= current_date + 30),
    'created_at', a.created_at, 'updated_at', a.updated_at
  );
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Requester: create, list, view, sign, renew
-- ─────────────────────────────────────────────────────────────────────────────

/**
 * Create a request. p = { city, property_id, role, lat, lng, aadhaar, rent,
 * deposit, start_date, duration_months, ...all other form fields → details,
 * owner:{name,mobile,email}, tenant:{name,mobile,email} }.
 * Snapshots the city price, computes the renewal date, routes to the nearest
 * vendor, and creates the owner + tenant parties. Payment (or a CRM mark-paid)
 * is what later moves it to the vendor.
 */
create or replace function public.rent_request(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_city   text := coalesce(nullif(public.normalize_city(p ->> 'city'), ''), '');
  v_role   text := coalesce(p ->> 'role', 'tenant');
  v_lat    numeric := nullif(p ->> 'lat', '')::numeric;
  v_lng    numeric := nullif(p ->> 'lng', '')::numeric;
  v_start  date := nullif(p ->> 'start_date', '')::date;
  v_dur    int := coalesce(nullif(p ->> 'duration_months', '')::int, 11);
  v_det    jsonb := coalesce(p -> 'details', '{}'::jsonb);
  a        public.rent_agreements;
begin
  if auth.uid() is null then raise exception 'Sign in to request an agreement.'; end if;
  if v_city = '' and (p ->> 'property_id') is not null then
    v_city := public.city_of_area(coalesce(v_det ->> 'area', ''), null);
  end if;
  if v_city = '' then raise exception 'City is required.'; end if;
  if v_role not in ('owner','broker','tenant') then v_role := 'tenant'; end if;

  insert into public.rent_agreements
    (city, property_id, requester_uid, requester_role, req_lat, req_lng, vendor_id,
     status, price, rent, deposit, start_date, duration_months, renewal_date,
     details, tenant_aadhaar)
  values
    (v_city, nullif(p ->> 'property_id', ''), auth.uid(), v_role, v_lat, v_lng,
     public.rent_nearest_vendor(v_city, v_lat, v_lng),
     'unpaid', public.rent_price(v_city),
     nullif(p ->> 'rent', '')::int, nullif(p ->> 'deposit', '')::int,
     v_start, v_dur, case when v_start is not null then v_start + (v_dur || ' months')::interval else null end,
     v_det, coalesce(p ->> 'aadhaar', ''))
  returning * into a;

  insert into public.rent_agreement_parties (agreement_id, role, name, mobile, email)
  values
    (a.id, 'owner',  coalesce(p -> 'owner'  ->> 'name', ''),
       public.normalize_mobile(coalesce(p -> 'owner'  ->> 'mobile', '')), lower(coalesce(p -> 'owner'  ->> 'email', ''))),
    (a.id, 'tenant', coalesce(p -> 'tenant' ->> 'name', ''),
       public.normalize_mobile(coalesce(p -> 'tenant' ->> 'mobile', '')), lower(coalesce(p -> 'tenant' ->> 'email', '')));

  perform public.rent_log(a.id, 'requested', jsonb_build_object('role', v_role, 'price', a.price));
  return public.rent_json(a, false);
end;
$$;

/** Agreements the caller is on — as requester, or as a party (by linked uid,
    email or verified mobile). Includes the caller's own unsigned sign token. */
create or replace function public.rent_my_agreements()
returns jsonb language sql stable security definer set search_path = public as $$
  with mine as (
    select distinct a.* from public.rent_agreements a
    left join public.rent_agreement_parties p on p.agreement_id = a.id
    where a.requester_uid = auth.uid()
       or p.uid = auth.uid()
       or (nullif(p.email,'') is not null and lower(p.email) = lower(coalesce(auth.jwt() ->> 'email','')))
       or (nullif(p.mobile,'') is not null and p.mobile = public.rent_my_mobile())
  )
  select coalesce(jsonb_agg(
    public.rent_json(mine, false) ||
    jsonb_build_object(
      'my_party', (select to_jsonb(x) from (
         select pp.role, pp.signed,
                case when pp.signed then null else pp.sign_token end as sign_token,
                case when pp.signed then null else '/rent/sign/' || pp.sign_token end as sign_url
         from public.rent_agreement_parties pp
         where pp.agreement_id = mine.id
           and (pp.uid = auth.uid()
                or lower(pp.email) = lower(coalesce(auth.jwt() ->> 'email',''))
                or (nullif(pp.mobile,'') is not null and pp.mobile = public.rent_my_mobile()))
         limit 1) x)
    ) order by mine.created_at desc), '[]'::jsonb)
  from mine;
$$;

/** One agreement for a requester/party (no Aadhaar, no other sign tokens). */
create or replace function public.rent_agreement(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare a public.rent_agreements;
begin
  select * into a from public.rent_agreements where id = p_id;
  if a.id is null then raise exception 'Not found.'; end if;
  if not coalesce(a.requester_uid = auth.uid()
          or public.is_crm_staff()
          or exists (select 1 from public.rent_agreement_parties p where p.agreement_id = a.id
                      and (p.uid = auth.uid()
                           or lower(p.email) = lower(coalesce(auth.jwt() ->> 'email',''))
                           or (nullif(p.mobile,'') is not null and p.mobile = public.rent_my_mobile())))
          or (a.vendor_id is not null and a.vendor_id = public.rent_vendor_id() and a.paid), false) then
    raise exception 'Not allowed.';
  end if;
  return public.rent_json(a, public.is_crm_staff() or (a.vendor_id = public.rent_vendor_id() and a.vendor_id is not null));
end;
$$;

/** Open a sign link: bind the signed-in account to the matching party and return
    the agreement to sign (contact shown, Aadhaar hidden). */
create or replace function public.rent_sign_view(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare pt public.rent_agreement_parties; a public.rent_agreements;
begin
  if auth.uid() is null then raise exception 'Sign in to view this agreement.'; end if;
  select * into pt from public.rent_agreement_parties where sign_token = p_token;
  if pt.id is null then raise exception 'This link is not valid.'; end if;
  -- bind this account to the party (first opener wins; email must not conflict)
  if pt.uid is null then
    update public.rent_agreement_parties set uid = auth.uid() where id = pt.id and uid is null;
  end if;
  select * into a from public.rent_agreements where id = pt.agreement_id;
  return public.rent_json(a, false)
    || jsonb_build_object('my_party', jsonb_build_object(
         'role', pt.role, 'signed', pt.signed,
         'sign_token', case when pt.signed then null else pt.sign_token end));
end;
$$;

/** Record a party's e-signature. Completes the agreement when both have signed. */
create or replace function public.rent_sign(p_token text, p_type text, p_data text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare pt public.rent_agreement_parties; a public.rent_agreements; n_unsigned int;
begin
  if auth.uid() is null then raise exception 'Sign in to sign.'; end if;
  select * into pt from public.rent_agreement_parties where sign_token = p_token;
  if pt.id is null then raise exception 'This link is not valid.'; end if;
  select * into a from public.rent_agreements where id = pt.agreement_id;
  if a.status not in ('ready_to_sign','partially_signed') then
    raise exception 'This agreement is not ready to sign yet.';
  end if;
  if pt.signed then raise exception 'You have already signed.'; end if;

  update public.rent_agreement_parties
     set signed = true, signed_at = now(), uid = coalesce(uid, auth.uid()),
         signature_type = coalesce(nullif(p_type,''), 'typed'),
         signature_data = left(coalesce(p_data,''), 200000),
         signed_ip = coalesce(current_setting('request.headers', true)::jsonb ->> 'x-forwarded-for', '')
   where id = pt.id;
  perform public.rent_log(a.id, 'signed', jsonb_build_object('role', pt.role));

  select count(*) into n_unsigned from public.rent_agreement_parties
   where agreement_id = a.id and not signed;
  if n_unsigned = 0 then
    update public.rent_agreements set status = 'completed',
      renewal_date = coalesce(renewal_date,
        case when start_date is not null then start_date + (duration_months || ' months')::interval else null end)
     where id = a.id;
    perform public.rent_log(a.id, 'completed', '{}'::jsonb);
  else
    update public.rent_agreements set status = 'partially_signed' where id = a.id and status = 'ready_to_sign';
  end if;

  select * into a from public.rent_agreements where id = a.id;
  return public.rent_json(a, false);
end;
$$;

/** Start a renewal: clone an old agreement's terms into a fresh request. The
    caller must be a party or the requester of the old one. */
create or replace function public.rent_renew(p_id uuid, p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare old public.rent_agreements; o public.rent_agreement_parties; t public.rent_agreement_parties;
        payload jsonb;
begin
  select * into old from public.rent_agreements where id = p_id;
  if old.id is null then raise exception 'Not found.'; end if;
  if not coalesce(old.requester_uid = auth.uid()
          or exists (select 1 from public.rent_agreement_parties pp where pp.agreement_id = old.id
                      and (pp.uid = auth.uid() or lower(pp.email) = lower(coalesce(auth.jwt() ->> 'email',''))
                           or (nullif(pp.mobile,'') is not null and pp.mobile = public.rent_my_mobile()))), false) then
    raise exception 'Not allowed.';
  end if;
  select * into o from public.rent_agreement_parties where agreement_id = old.id and role = 'owner';
  select * into t from public.rent_agreement_parties where agreement_id = old.id and role = 'tenant';

  payload := jsonb_build_object(
    'city', old.city, 'property_id', old.property_id,
    'role', coalesce(p ->> 'role', old.requester_role),
    'lat', p ->> 'lat', 'lng', p ->> 'lng',
    'rent', old.rent, 'deposit', old.deposit,
    'start_date', coalesce(p ->> 'start_date', to_char(old.renewal_date, 'YYYY-MM-DD')),
    'duration_months', old.duration_months,
    'aadhaar', old.tenant_aadhaar, 'details', old.details,
    'owner',  jsonb_build_object('name', o.name, 'mobile', o.mobile, 'email', o.email),
    'tenant', jsonb_build_object('name', t.name, 'mobile', t.mobile, 'email', t.email));

  return public.rent_request(payload) || jsonb_build_object('renewed_from', old.id);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Vendor app
-- ─────────────────────────────────────────────────────────────────────────────

/** The caller's vendor profile, or null. */
create or replace function public.rent_vendor_me()
returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(v) - 'created_by' from public.rent_vendors v
   where v.active and lower(v.email) = lower(coalesce(auth.jwt() ->> 'email','')) limit 1;
$$;

/** The vendor's queue. p_status: 'pending' (with_vendor), 'in_progress'
    (ready/partially), 'done' (completed), or null for all live ones. */
create or replace function public.rent_vendor_queue(p_status text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v uuid := public.rent_vendor_id();
begin
  if v is null then raise exception 'Not a vendor.'; end if;
  return (
    select coalesce(jsonb_agg(public.rent_json(a, true)
             || jsonb_build_object('parties', public.rent_parties_json(a.id, true, true))
             order by a.updated_at desc), '[]'::jsonb)
    from public.rent_agreements a
    where a.vendor_id = v and a.paid
      and case
            when p_status = 'pending'     then a.status = 'with_vendor'
            when p_status = 'in_progress' then a.status in ('ready_to_sign','partially_signed')
            when p_status = 'done'        then a.status = 'completed'
            else a.status <> 'cancelled'
          end);
end;
$$;

/** One agreement for the vendor (full, with Aadhaar and sign links to share). */
create or replace function public.rent_vendor_agreement(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare a public.rent_agreements;
begin
  select * into a from public.rent_agreements where id = p_id;
  if a.id is null or a.vendor_id is distinct from public.rent_vendor_id() or not a.paid then
    raise exception 'Not allowed.';
  end if;
  return public.rent_json(a, true) || jsonb_build_object('parties', public.rent_parties_json(a.id, true, true));
end;
$$;

/** Vendor edits the deal fields before uploading (fixes errors the requester made). */
create or replace function public.rent_vendor_update(p_id uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a public.rent_agreements; v_start date;
begin
  select * into a from public.rent_agreements where id = p_id;
  if a.id is null or a.vendor_id is distinct from public.rent_vendor_id() or not a.paid then
    raise exception 'Not allowed.';
  end if;
  v_start := coalesce(nullif(p ->> 'start_date','')::date, a.start_date);
  update public.rent_agreements set
     rent = coalesce(nullif(p ->> 'rent','')::int, rent),
     deposit = coalesce(nullif(p ->> 'deposit','')::int, deposit),
     start_date = v_start,
     duration_months = coalesce(nullif(p ->> 'duration_months','')::int, duration_months),
     renewal_date = case when v_start is not null
       then v_start + (coalesce(nullif(p ->> 'duration_months','')::int, duration_months) || ' months')::interval
       else renewal_date end,
     details = coalesce(p -> 'details', details),
     tenant_aadhaar = coalesce(p ->> 'aadhaar', tenant_aadhaar)
   where id = p_id;
  perform public.rent_log(p_id, 'vendor_edited', '{}'::jsonb);
  select * into a from public.rent_agreements where id = p_id;
  return public.rent_json(a, true);
end;
$$;

/** Vendor records the uploaded stamped PDF and opens it for signing. The file
    itself is put in the rent-agreements bucket at <id>/<file> by the client. */
create or replace function public.rent_vendor_upload(p_id uuid, p_path text, p_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a public.rent_agreements;
begin
  select * into a from public.rent_agreements where id = p_id;
  if a.id is null or a.vendor_id is distinct from public.rent_vendor_id() or not a.paid then
    raise exception 'Not allowed.';
  end if;
  if p_path is null or left(p_path, length(a.id::text) + 1) <> (a.id::text || '/') then
    raise exception 'Bad file path.';
  end if;
  update public.rent_agreements
     set document_path = p_path, document_name = coalesce(p_name,'agreement.pdf'),
         document_at = now(), document_by = lower(coalesce(auth.jwt() ->> 'email','')),
         status = case when status in ('with_vendor','ready_to_sign') then 'ready_to_sign' else status end
   where id = p_id;
  perform public.rent_log(p_id, 'document_uploaded', jsonb_build_object('name', p_name));
  select * into a from public.rent_agreements where id = p_id;
  return public.rent_json(a, true) || jsonb_build_object('parties', public.rent_parties_json(a.id, true, true));
end;
$$;

/** Vendor marks stamped / registered (optional status steps). */
create or replace function public.rent_vendor_flag(p_id uuid, p_stamped boolean default null, p_registered boolean default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a public.rent_agreements;
begin
  select * into a from public.rent_agreements where id = p_id;
  if a.id is null or a.vendor_id is distinct from public.rent_vendor_id() or not a.paid then
    raise exception 'Not allowed.';
  end if;
  update public.rent_agreements
     set stamped = coalesce(p_stamped, stamped), registered = coalesce(p_registered, registered)
   where id = p_id;
  perform public.rent_log(p_id, 'vendor_flag', jsonb_build_object('stamped', p_stamped, 'registered', p_registered));
  select * into a from public.rent_agreements where id = p_id;
  return public.rent_json(a, true);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- CRM
-- ─────────────────────────────────────────────────────────────────────────────

/** All agreements, filtered by city (respecting the staff member's cities) and
    status. p_city null/'All' = every city the caller may see. */
create or replace function public.crm_rent_list(p_city text default null, p_status text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_crm_staff() then raise exception 'Not allowed.'; end if;
  return (
    select coalesce(jsonb_agg(public.rent_json(a, true)
             || jsonb_build_object('parties', public.rent_parties_json(a.id, true, false))
             order by a.created_at desc), '[]'::jsonb)
    from public.rent_agreements a
    where public.crm_city_ok(a.city)
      and (p_city is null or p_city = '' or lower(p_city) = 'all' or a.city = public.normalize_city(p_city))
      and (p_status is null or p_status = '' or a.status = p_status));
end;
$$;

/** One agreement for CRM (full, with events). */
create or replace function public.crm_rent_detail(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare a public.rent_agreements;
begin
  if not public.is_crm_staff() then raise exception 'Not allowed.'; end if;
  select * into a from public.rent_agreements where id = p_id;
  if a.id is null or not public.crm_city_ok(a.city) then raise exception 'Not found.'; end if;
  return public.rent_json(a, true)
    || jsonb_build_object('parties', public.rent_parties_json(a.id, true, true))
    || jsonb_build_object('events', (select coalesce(jsonb_agg(jsonb_build_object(
          'kind', e.kind, 'actor', e.actor, 'meta', e.meta, 'at', e.created_at) order by e.created_at), '[]'::jsonb)
        from public.rent_agreement_events e where e.agreement_id = a.id));
end;
$$;

/** Set a city's price (super admin). */
create or replace function public.crm_rent_set_price(p_city text, p_price int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c text := public.normalize_city(p_city);
begin
  if not public.is_super_admin() then raise exception 'Not allowed.'; end if;
  if c = '' then raise exception 'Unknown city.'; end if;
  insert into public.rent_agreement_settings (city, price, updated_at, updated_by)
  values (c, greatest(0, coalesce(p_price,0)), now(), lower(coalesce(auth.jwt() ->> 'email','')))
  on conflict (city) do update set price = excluded.price, updated_at = now(), updated_by = excluded.updated_by;
  return jsonb_build_object('city', c, 'price', greatest(0, coalesce(p_price,0)));
end;
$$;

/** All city prices (staff). */
create or replace function public.crm_rent_prices()
returns jsonb language sql stable security definer set search_path = public as $$
  select case when public.is_crm_staff() then
    (select coalesce(jsonb_object_agg(city, price), '{}'::jsonb) from public.rent_agreement_settings)
  else '{}'::jsonb end;
$$;

/** Mark a request paid and release it to the vendor (super admin — the manual
    path until the aggregator is wired). */
create or replace function public.crm_rent_mark_paid(p_id uuid, p_ref text default 'manual')
returns jsonb language plpgsql security definer set search_path = public as $$
declare a public.rent_agreements;
begin
  if not public.is_super_admin() then raise exception 'Not allowed.'; end if;
  select * into a from public.rent_agreements where id = p_id;
  if a.id is null then raise exception 'Not found.'; end if;
  update public.rent_agreements
     set paid = true, paid_at = coalesce(paid_at, now()), paid_by = lower(coalesce(auth.jwt() ->> 'email','')),
         payment_ref = coalesce(nullif(p_ref,''),'manual'),
         status = case when status = 'unpaid' then 'with_vendor' else status end
   where id = p_id;
  perform public.rent_log(p_id, 'paid', jsonb_build_object('ref', p_ref, 'by', 'crm'));
  select * into a from public.rent_agreements where id = p_id;
  return public.rent_json(a, true);
end;
$$;

/** Assign / override the vendor. */
create or replace function public.crm_rent_assign_vendor(p_id uuid, p_vendor uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a public.rent_agreements;
begin
  if not (public.is_super_admin() or public.has_admin_scope('partners.manage')) then raise exception 'Not allowed.'; end if;
  select * into a from public.rent_agreements where id = p_id;
  if a.id is null or not public.crm_city_ok(a.city) then raise exception 'Not found.'; end if;
  update public.rent_agreements set vendor_id = p_vendor where id = p_id;
  perform public.rent_log(p_id, 'vendor_assigned', jsonb_build_object('vendor', p_vendor));
  select * into a from public.rent_agreements where id = p_id;
  return public.rent_json(a, true);
end;
$$;

/** Cancel an agreement. */
create or replace function public.crm_rent_cancel(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_super_admin() then raise exception 'Not allowed.'; end if;
  update public.rent_agreements set status = 'cancelled' where id = p_id;
  perform public.rent_log(p_id, 'cancelled', '{}'::jsonb);
  return jsonb_build_object('id', p_id, 'status', 'cancelled');
end;
$$;

/** Vendors (staff read). */
create or replace function public.crm_rent_vendors()
returns jsonb language sql stable security definer set search_path = public as $$
  select case when public.is_crm_staff() then
    (select coalesce(jsonb_agg(to_jsonb(v) order by v.city, v.created_at), '[]'::jsonb)
       from public.rent_vendors v where public.crm_city_ok(v.city))
  else '[]'::jsonb end;
$$;

/** Add or edit a vendor (super admin). p = { id?, name, email, phone, city, area, lat, lng, active }. */
create or replace function public.crm_rent_vendor_save(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.rent_vendors; c text := public.normalize_city(p ->> 'city');
begin
  if not public.is_super_admin() then raise exception 'Not allowed.'; end if;
  if c = '' then raise exception 'Unknown city.'; end if;
  if (p ->> 'id') is not null and (p ->> 'id') <> '' then
    update public.rent_vendors set
      name = coalesce(nullif(p ->> 'name',''), name),
      email = coalesce(nullif(p ->> 'email',''), email),
      phone = coalesce(p ->> 'phone', phone),
      city = c, area = coalesce(p ->> 'area', area),
      lat = nullif(p ->> 'lat','')::numeric, lng = nullif(p ->> 'lng','')::numeric,
      active = coalesce((p ->> 'active')::boolean, active)
     where id = (p ->> 'id')::uuid returning * into v;
  else
    insert into public.rent_vendors (name, email, phone, city, area, lat, lng, active, created_by)
    values (coalesce(p ->> 'name',''), coalesce(p ->> 'email',''), coalesce(p ->> 'phone',''),
            c, coalesce(p ->> 'area',''), nullif(p ->> 'lat','')::numeric, nullif(p ->> 'lng','')::numeric,
            coalesce((p ->> 'active')::boolean, true), lower(coalesce(auth.jwt() ->> 'email','')))
    returning * into v;
  end if;
  return to_jsonb(v);
end;
$$;

/** Upcoming + overdue renewals (staff), city-scoped. */
create or replace function public.crm_rent_renewals(p_city text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_crm_staff() then raise exception 'Not allowed.'; end if;
  return (
    select coalesce(jsonb_agg(public.rent_json(a, true)
             || jsonb_build_object('parties', public.rent_parties_json(a.id, true, false))
             order by a.renewal_date), '[]'::jsonb)
    from public.rent_agreements a
    where a.status = 'completed' and a.renewed_to is null and a.renewal_date is not null
      and a.renewal_date <= current_date + 45
      and public.crm_city_ok(a.city)
      and (p_city is null or p_city = '' or lower(p_city) = 'all' or a.city = public.normalize_city(p_city)));
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Storage: the stamped PDF lives in a private bucket; only the agreement's
-- people (staff, its vendor, its parties/requester) may read it, and only the
-- vendor or staff may write it.
-- ─────────────────────────────────────────────────────────────────────────────

insert into storage.buckets (id, name, public) values ('rent-agreements', 'rent-agreements', false)
  on conflict (id) do nothing;

/** May the caller read/write the rent-agreements object at p_name (<id>/<file>)? */
create or replace function public.rent_doc_access(p_name text, p_write boolean)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare aid uuid; a public.rent_agreements;
begin
  if auth.uid() is null then return false; end if;
  begin aid := split_part(coalesce(p_name,''), '/', 1)::uuid; exception when others then return false; end;
  select * into a from public.rent_agreements where id = aid;
  if a.id is null then return false; end if;
  if public.is_crm_staff() then return true; end if;
  if a.vendor_id = public.rent_vendor_id() and a.vendor_id is not null then return true; end if;
  if p_write then return false; end if;
  return a.requester_uid = auth.uid()
    or exists (select 1 from public.rent_agreement_parties p where p.agreement_id = a.id
                and (p.uid = auth.uid()
                     or lower(p.email) = lower(coalesce(auth.jwt() ->> 'email',''))
                     or (nullif(p.mobile,'') is not null and p.mobile = public.rent_my_mobile())));
end;
$$;

drop policy if exists "rent doc read" on storage.objects;
create policy "rent doc read" on storage.objects for select to authenticated
  using (bucket_id = 'rent-agreements' and public.rent_doc_access(name, false));
drop policy if exists "rent doc write" on storage.objects;
create policy "rent doc write" on storage.objects for insert to authenticated
  with check (bucket_id = 'rent-agreements' and public.rent_doc_access(name, true));
drop policy if exists "rent doc update" on storage.objects;
create policy "rent doc update" on storage.objects for update to authenticated
  using (bucket_id = 'rent-agreements' and public.rent_doc_access(name, true));

-- ─────────────────────────────────────────────────────────────────────────────
-- Grants
-- ─────────────────────────────────────────────────────────────────────────────

do $$
declare f text;
begin
  for f in
    select format('public.%I(%s)', p.proname, pg_get_function_identity_arguments(p.oid))
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in (
      'rent_touch','rent_log','rent_my_mobile','rent_price','rent_is_vendor','rent_vendor_id',
      'rent_nearest_vendor','rent_parties_json','rent_json','rent_request','rent_my_agreements',
      'rent_agreement','rent_sign_view','rent_sign','rent_renew','rent_vendor_me','rent_vendor_queue',
      'rent_vendor_agreement','rent_vendor_update','rent_vendor_upload','rent_vendor_flag',
      'rent_doc_access','crm_rent_list','crm_rent_detail','crm_rent_set_price','crm_rent_prices',
      'crm_rent_mark_paid','crm_rent_assign_vendor','crm_rent_cancel','crm_rent_vendors',
      'crm_rent_vendor_save','crm_rent_renewals')
  loop
    execute format('revoke all on function %s from public, anon;', f);
  end loop;
end $$;

-- Caller-facing functions open to signed-in users (each gates itself inside).
grant execute on function
  public.rent_request(jsonb), public.rent_my_agreements(), public.rent_agreement(uuid),
  public.rent_sign_view(text), public.rent_sign(text, text, text), public.rent_renew(uuid, jsonb),
  public.rent_my_mobile(), public.rent_price(text), public.rent_is_vendor(), public.rent_vendor_id(),
  public.rent_nearest_vendor(text, numeric, numeric),
  public.rent_vendor_me(), public.rent_vendor_queue(text), public.rent_vendor_agreement(uuid),
  public.rent_vendor_update(uuid, jsonb), public.rent_vendor_upload(uuid, text, text),
  public.rent_vendor_flag(uuid, boolean, boolean),
  public.crm_rent_list(text, text), public.crm_rent_detail(uuid), public.crm_rent_set_price(text, int),
  public.crm_rent_prices(), public.crm_rent_mark_paid(uuid, text), public.crm_rent_assign_vendor(uuid, uuid),
  public.crm_rent_cancel(uuid), public.crm_rent_vendors(), public.crm_rent_vendor_save(jsonb),
  public.crm_rent_renewals(text)
  to authenticated;

-- Internal helpers used only inside other definers: no external execute.
revoke all on function public.rent_parties_json(uuid, boolean, boolean) from public, anon, authenticated;
revoke all on function public.rent_json(public.rent_agreements, boolean) from public, anon, authenticated;
revoke all on function public.rent_log(uuid, text, jsonb) from public, anon, authenticated;
revoke all on function public.rent_touch() from public, anon, authenticated;
revoke all on function public.rent_doc_access(text, boolean) from public, anon;
grant execute on function public.rent_doc_access(text, boolean) to authenticated;  -- used by storage policies
