/**
 * Apply visit_ad_pages.sql (PGlite, over stubs and tenant_views.sql) and check
 * the Meta ad pages:
 *
 *   - the page: a flat whatever its status (never "rented"), a building;
 *     never the exact address; the team's slots when there are some;
 *   - slots: 10 am – 5 pm starts on the hour, at least an hour ahead, 7 days;
 *     the team's slots instead when the flat has them; anything else refused;
 *   - booking with just a mobile: a CRM client (found by number, else new,
 *     'meta_ad'), the visit on their history with the UTM, a notification,
 *     client → visit pending; booking again with the number moves it;
 *   - a flat: a tenant view, visit pending, and the partner's website lead;
 *   - a building: a visit request marked 'ad' — the owner sees it without the
 *     number; the building's partner is told;
 *   - the CRM reads them and marks reminders; anon / tenants can't;
 *   - a building's page lists its free flats only; opens and flat taps are
 *     kept with their source (WhatsApp / Meta), and the flats tapped go on
 *     the visit; the phone becomes the client's;
 *   - the call desk opens at the visit's start and closes when that day ends:
 *     the building's caretaker and manager (MovEazy's number where unset; a
 *     flat outside a building: MovEazy as manager), calls and feedback kept,
 *     in the building's call log as 'ad' — the owner sees no number.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});
const read = (f) => readFileSync(new URL(`../${f}`, import.meta.url), "utf8");
const fn = (src, name) => {
  const i = src.indexOf(`create or replace function public.${name}(`);
  return src.slice(i, src.indexOf("$$;", src.indexOf("as $$", i) + 5) + 3);
};
let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};

const OWNER = "a0000000-0000-0000-0000-000000000001";
const BROKER = "b0000000-0000-0000-0000-000000000005";
const BLD = "d0000000-0000-0000-0000-000000000007";

const db = new PGlite();
await db.exec(`
create role anon; create role authenticated;
create schema auth;
grant usage on schema auth to anon, authenticated;
create table auth.users (id uuid primary key, email text);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
create function auth.jwt() returns jsonb language sql stable as $$ select jsonb_build_object('email', current_setting('test.email', true)) $$;
insert into auth.users values ('${OWNER}', 'owner@x.in'), ('${BROKER}', 'b@x.in');
create function public.is_crm_staff() returns boolean language sql stable as $$ select current_setting('test.staff', true) = 'on' $$;
create function public.has_admin_scope(s text) returns boolean language sql stable as $$ select current_setting('test.write', true) = 'on' $$;
create table public.owner_accounts (user_id uuid primary key, status text);
insert into public.owner_accounts values ('${OWNER}', 'approved');
create function public.is_approved_owner() returns boolean language sql stable security definer as $$
  select exists (select 1 from public.owner_accounts where user_id = auth.uid() and status = 'approved') $$;
create table public.broker_partners (user_id uuid primary key, name text default '', phone text default '');
create function public.is_approved_partner() returns boolean language sql stable as $$ select false $$;
create table public.owner_buildings (id uuid primary key, owner_id uuid, broker_id uuid, name text, code text, area text default '',
  landmark text default '', full_address text default '', description text default '', amenities text[] default '{}', photos text[] default '{}',
  total_floors int, latitude numeric, longitude numeric, status text default 'active', updated_at timestamptz default now());
insert into public.owner_buildings (id, owner_id, broker_id, name, code, area, landmark, full_address, latitude)
  values ('${BLD}', '${OWNER}', '${BROKER}', 'BR Homes', 'H33PSH', 'HSR Layout', 'Near 27th Main', '12 Secret Street', 12.91234);
create function public.building_by_code(p_code text) returns uuid language sql stable security definer as $$
  select id from public.owner_buildings where code = upper(trim(p_code)) and status = 'active' $$;
create table public.inventory (property_id text primary key, status text default 'published', building_id uuid, unit_no text default '',
  unit_order int, flat_type text default '2 BHK', area text default 'HSR Layout', landmark text default 'Near BDA Complex', rent numeric default 25000,
  deposit numeric default 100000, maintenance numeric default 2000, furnishing text default 'Semi', bedrooms int default 2, bathrooms int default 2,
  area_sqft int, amenities text[] default '{}', images text[] default '{}', cover_image_url text default '', description text default '',
  title text default '2 BHK in HSR', full_address text default '7 Hidden Lane', latitude numeric default 12.91234, longitude numeric default 77.6,
  property_type text default '', available_from date, floor_number int);
insert into public.inventory (property_id, status) values ('P1', 'published'), ('PR', 'rented');
insert into public.inventory (property_id, building_id, unit_no, rent) values ('B1', '${BLD}', '101', 22000), ('B2', '${BLD}', '102', 26000);
create table public.owner_property_links (owner_id uuid, property_id text);
insert into public.owner_property_links values ('${OWNER}', 'P1'), ('${OWNER}', 'PR');
create table public.property_visit_slots (id uuid primary key default gen_random_uuid(), property_id text, slot_at timestamptz, capacity int default 5);
create table public.crm_clients (id uuid primary key default gen_random_uuid(), user_id uuid unique, name text default '', phone text default '',
  source text default 'app', status text default 'fresh', updated_at timestamptz default now(), created_at timestamptz default now());
insert into public.crm_clients (name, phone) values ('Known Asha', '9845011111');
create table public.crm_activities (id uuid primary key default gen_random_uuid(), client_id uuid, actor_email text default '', type text,
  body text, meta jsonb default '{}', created_at timestamptz default now());
create table public.crm_notifications (id uuid primary key default gen_random_uuid(), for_email text, type text, title text, body text, client_id uuid,
  created_at timestamptz default now());
create table public.partner_notifications (id uuid primary key default gen_random_uuid(), broker_id uuid, kind text, title text, body text, link text);
create table public.website_lead_calls (client_id uuid, property_id text, kind text, detail text);
create function public.website_lead(p_client uuid, p_property text, p_kind text, p_detail text default '') returns void language sql security definer as $$
  insert into public.website_lead_calls values (p_client, p_property, p_kind, p_detail) $$;
create table public.flat_scans (property_id text not null references public.inventory (property_id), visitor text not null,
  day date not null default current_date, source text not null default 'link', created_at timestamptz not null default now(),
  primary key (property_id, visitor, day));
create table public.owner_building_scans (building_id uuid not null, visitor text not null, day date not null default current_date,
  source text not null default 'link', created_at timestamptz not null default now(), primary key (building_id, visitor, day));
create table public.visit_bookings (id uuid primary key default gen_random_uuid(), user_id uuid, property_id text, status text default 'scheduled',
  created_at timestamptz default now());
create table public.owner_building_leads (id uuid primary key default gen_random_uuid(), building_id uuid, name text default '',
  phone text, user_id uuid, property_ids text[] default '{}', visit_at timestamptz, note text default '', broker_id uuid, visitor text default '',
  kind text default 'scheduled', updated_by text default '', status text default 'new', created_at timestamptz default now(), updated_at timestamptz default now());
create table public.owner_building_bookings (property_id text primary key, building_id uuid, booked_by text default '');
create table public.user_profiles (id uuid primary key, email text, name text default '', phone text default '');
create table public.user_requirements (user_id uuid primary key, whatsapp text default '');
create table public.tenant_profiles (user_id uuid primary key, linkedin text default '', current_company text default '', past_company text default '',
  first_job boolean default false, college text default '', graduation_year int, in_bangalore_since text default '', score int default 0);
create function public.website_tenant_ok(p_user uuid, p_property text) returns boolean language sql stable as $$ select p_user is not null $$;
create table public.crm_curated_shares (id uuid primary key default gen_random_uuid(), client_id uuid, token text unique);
create table public.crm_shortlists (id uuid primary key default gen_random_uuid(), client_id uuid not null, property_id text not null,
  status text default 'shortlisted', share_token text, opened_at timestamptz, last_opened_at timestamptz, open_count int not null default 0,
  curated_share_id uuid, reacted_at timestamptz, unique (client_id, property_id));
create table public.listing_reactions (user_id uuid not null, property_id text not null, reaction text not null, updated_at timestamptz default now(),
  source text default 'app', recorded_by text default '', primary key (user_id, property_id));
create table public.partner_listings (property_id text, broker_id uuid);
create table public.partner_lead_requests (id uuid primary key, broker_id uuid, pack text);
create table public.partner_lead_assignments (id uuid primary key default gen_random_uuid(), request_id uuid, client_id uuid, broker_id uuid,
  status text default 'assigned', closed_rent numeric, assigned_at timestamptz default now(), updated_at timestamptz default now());
create table public.partner_lead_reachouts (id bigint generated always as identity primary key, assignment_id uuid, client_id uuid, broker_id uuid,
  channel text, at timestamptz default now());
create table public.partner_website_interest (id uuid primary key default gen_random_uuid(), broker_id uuid, client_id uuid, property_id text,
  kind text, created_at timestamptz default now());
`);
await db.exec(fn(read("lead_intake.sql"), "normalize_mobile"));
await db.exec(read("building_call_desk.sql"));
await db.exec(read("building_tenant_tracks.sql"));
await db.exec(read("building_tenants_board.sql"));
await db.exec(read("owner_qr_overview.sql"));
await db.exec(read("tenant_views.sql"));
await db.exec(fn(read("building_flats_maintenance.sql"), "building_flats"));
const SQL = read("visit_ad_pages.sql");
await db.exec(SQL);
await db.exec(SQL);
check(true, "visit_ad_pages.sql applies, and re-applies over itself");

async function as(who, sql, params = []) {
  await db.exec(`reset role; select set_config('test.uid', '${who.uid ?? ""}', false), set_config('test.staff', '${who.staff ? "on" : ""}', false),
    set_config('test.write', '${who.write ? "on" : ""}', false), set_config('test.email', '${who.email ?? ""}', false); set role ${who.role ?? "authenticated"};`);
  try { return { rows: (await db.query(sql, params)).rows, error: null }; }
  catch (e) { return { rows: null, error: e }; }
  finally { await db.exec("reset role; select set_config('test.uid', '', false)"); }
}
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const q1 = async (sql) => Object.values((await db.query(sql)).rows[0] ?? {})[0];
const anon = { role: "anon" }, agent = { staff: true, write: true, email: "agent@moveazy.co.in" }, viewer = { staff: true };

// Tomorrow 11:00 IST, and other times, as ISO strings.
const istAt = (days, h, m = 0) => q1(`select ((((now() at time zone 'Asia/Kolkata')::date + ${days}) + make_time(${h}, ${m}, 0)) at time zone 'Asia/Kolkata')::text`);
const T11 = await istAt(1, 11), T15 = await istAt(1, 15), T9 = await istAt(1, 9), T18 = await istAt(1, 18), T1130 = await istAt(1, 11, 30), FAR = await istAt(9, 11);
const book = (kind, ref, phone, slot, name = "", utm = {}) =>
  as(anon, "select public.visit_ad_book($1, $2, 'phone-abc-1', $3, $4, $5::timestamptz, $6::jsonb)", [kind, ref, phone, name, slot, JSON.stringify(utm)]);

console.log("\nthe page");
let p = one(await as(anon, "select public.visit_ad_page('flat', 'pr')"));
check(p?.property_id === "PR" && p.rent === 25000 && !("status" in p), "a rented flat still has its page, and never says so", JSON.stringify(p));
check(!JSON.stringify(p).includes("Hidden Lane") && Number(p.latitude) === 12.912, "no exact address; the pin rounded");
p = one(await as(anon, "select public.visit_ad_page('building', 'h33psh')"));
check(p?.name === "BR Homes" && p.rent_from === 22000 && p.rent_to === 26000 && p.flats === 2 && !JSON.stringify(p).includes("Secret"), "a building's page", JSON.stringify(p));
check(one(await as(anon, "select public.visit_ad_page('flat', 'NOPE')")) == null, "no page for a flat that isn't there");

console.log("\nslots");
for (const [slot, why] of [[T9, "before 10"], [T18, "6 pm start"], [T1130, "not on the hour"], [FAR, "beyond 7 days"]]) {
  check(Boolean((await book("flat", "P1", "9876500001", slot)).error), `refused: ${why}`);
}
await db.exec(`insert into public.property_visit_slots (property_id, slot_at) values ('PR', '${T15}')`);
check(one(await as(anon, "select public.visit_ad_page('flat', 'PR')")).slots.length === 1, "the team's slots on the page");
check(Boolean((await book("flat", "PR", "9876500001", T11)).error), "a flat with team slots: only those");
check((await book("flat", "PR", "9876500001", T15)).error == null, "…which book");

console.log("\nbooking a flat");
let r = await book("flat", "P1", "+91 98450 11111", T11, "", { utm_source: "facebook", utm_campaign: "P1", utm_medium: "paid_social", evil: "x" });
const b1 = one(r);
const asha = await q1("select id::text from public.crm_clients where name = 'Known Asha'");
check(r.error == null && b1.moved === false && b1.area === "HSR Layout", "booked with just a mobile", r.error?.message);
check(await q1(`select client_id::text from public.ad_visit_bookings where id = '${b1.id}'`) === asha, "a known number is its client");
check(await q1(`select utm::text from public.ad_visit_bookings where id = '${b1.id}'`) === '{"utm_medium": "paid_social", "utm_source": "facebook", "utm_campaign": "P1"}',
  "the UTM saved (known keys only)");
check(await q1(`select status from public.crm_clients where id = '${asha}'`) === "visit_pending", "the client: visit pending");
check(/Booked a visit from the ad page · P1 \(2 BHK, HSR Layout\) · .* · facebook \/ P1/.test(await q1(`select body from public.crm_activities where client_id = '${asha}'`)),
  "on their history with where they came from");
check(await q1(`select count(*)::int from public.crm_notifications where client_id = '${asha}'`) === 1, "a CRM notification");
const v = (await db.query(`select * from public.property_tenant_views where property_id = 'P1' and client_id = '${asha}'`)).rows[0];
check(v?.visit === "pending" && v.sources.includes("ad"), "a tenant view, visit pending", JSON.stringify(v));
check(await q1(`select kind from public.website_lead_calls where client_id = '${asha}'`) === "visit", "the partner's website lead");
r = await book("flat", "P1", "9845011111", T15, "Asha R");
check(one(r)?.moved === true && await q1("select count(*)::int from public.ad_visit_bookings where ref = 'P1'") === 1, "the same number moves the visit");
check(await q1(`select name from public.crm_clients where id = '${asha}'`) === "Known Asha", "a name the team has stays");
r = await book("flat", "P1", "9811122233", T11, "New Person");
check(await q1("select source from public.crm_clients where phone = '9811122233'") === "meta_ad", "a new number: a new client from the ad");
check(Boolean((await book("flat", "P1", "12345", T11)).error), "a bad mobile refused");

console.log("\nbooking a building");
r = await book("building", "H33PSH", "9822200000", T11, "Vik", { utm_source: "facebook" });
const lead = (await db.query("select * from public.owner_building_leads")).rows[0];
check(r.error == null && lead?.source === "ad" && lead.phone === "9822200000" && lead.broker_id === BROKER, "a visit request on the building, marked ad", r.error?.message);
check(await q1("select count(*)::int from public.partner_notifications") === 1, "its partner told");
await book("building", "H33PSH", "9822200000", T15);
check(await q1("select count(*)::int from public.owner_building_leads") === 1 && await q1("select extract(hour from visit_at at time zone 'Asia/Kolkata')::int from public.owner_building_leads") === 15,
  "booking again moves the same request");
const o = one(await as({ uid: OWNER }, "select public.owner_qr_overview()"));
const vik = (o?.list ?? []).find((x) => x.name === "Vik");
check(vik?.via === "moveazy" && vik.phone === "", "the owner sees the visit, without the number", JSON.stringify(vik));
const ashaO = (o?.list ?? []).find((x) => x.name === "Known Asha");
check(ashaO?.via === "moveazy" && ashaO.visit === true && ashaO.phone === "", "and the flat visit too", JSON.stringify(ashaO));

console.log("\nthe CRM");
const list = one(await as(viewer, "select public.crm_ad_visits(30)"));
check(list?.length === 4 && list.some((x) => x.kind === "building" && x.building?.name === "BR Homes") && list.every((x) => x.phone), "the CRM's ad visits", list?.length);
r = await as(agent, "select public.crm_ad_visit_stamp($1, 'reminder')", [b1.id]);
check(r.error == null && await q1(`select reminder_sent_by from public.ad_visit_bookings where id = '${b1.id}'`) === "agent@moveazy.co.in", "a reminder marked sent");
await book("flat", "P1", "9845011111", T11);
check(await q1(`select reminder_sent_at from public.ad_visit_bookings where id = '${b1.id}'`) == null, "moving the visit clears it");

console.log("\nwho");
check(Boolean((await as(anon, "select public.crm_ad_visits(30)")).error), "anon can't read ad visits");
check(Boolean((await as({}, "select public.crm_ad_visits(30)")).error), "nor a tenant");
check(Boolean((await as(viewer, "select public.crm_ad_visit_stamp($1, 'reminder')", [b1.id])).error), "staff without write can't mark");
check(Boolean((await as(anon, "select public.visit_ad_slot_ok('P1', now())")).error), "the internals aren't callable");
check(Boolean((await as(anon, "select * from public.ad_visit_bookings")).error), "the table is closed");

console.log("\nthe building page, what they did, the call desk");
await db.exec(`insert into public.owner_building_bookings values ('B2', '${BLD}', 'owner')`);
p = one(await as(anon, "select public.visit_ad_page('building', 'H33PSH')"));
check(p.available.length === 1 && p.available[0].property_id === "B1" && p.available[0].unit_no === "101", "only free flats listed", JSON.stringify(p.available?.map((f) => f.property_id)));
const ev = (event, extra = []) => as(anon, "select public.visit_ad_event('building', 'H33PSH', 'wa-phone-77', $1, $2, $3, $4::jsonb)", [event, ...extra]);
await ev("open", [null, 0, JSON.stringify({ utm_source: "whatsapp" })]);
await ev("flat_open", ["B1", 42, JSON.stringify({ utm_source: "whatsapp" })]);
await ev("flat_open", ["P1", 5, "{}"]);
check(await q1("select count(*)::int from public.ad_page_events where visitor = 'wa-phone-77'") === 2, "an open and a flat tap kept; a flat of another building isn't");
check(await q1("select source || ':' || seconds from public.ad_page_events where event = 'flat_open'") === "whatsapp:42", "with where they came from and how long");
r = await as(anon, "select public.visit_ad_book('building', 'H33PSH', 'wa-phone-77', '9833300000', 'Wa Tenant', $1::timestamptz, $2::jsonb)",
  [T11, JSON.stringify({ utm_source: "whatsapp", utm_campaign: "H33PSH" })]);
const wb = one(r);
check(r.error == null && wb.calls_from && wb.calls_until, "booked from the WhatsApp page", r.error?.message);
check(await q1(`select array_to_string(property_ids, ',') from public.ad_visit_bookings where id = '${wb.id}'`) === "B1", "the flat they tapped is on the visit");
const waCid = await q1("select id::text from public.crm_clients where phone = '9833300000'");
check(await q1("select count(*)::int from public.ad_page_events where visitor = 'wa-phone-77' and client_id is null") === 0
  && await q1(`select client_id::text from public.visitor_clients where visitor = 'wa-phone-77'`) === waCid, "the phone is the client's now");
check(await q1("select note from public.owner_building_leads where phone = '9833300000'") === "Booked from the WhatsApp page", "the request says WhatsApp");
const desk = (kind = "contacts", target = "", fb = "", note = "", phone = "9833300000") =>
  as(anon, "select public.visit_ad_desk($1, $2, 'wa-phone-77', $3, $4, $5, $6)", [wb.id, phone, kind, target, fb, note]);
r = await desk();
check(one(r)?.open === false && one(r).opens_at, "before the visit: closed, and when it opens", JSON.stringify(one(r)));
check(Boolean((await desk("contacts", "", "", "", "9999999999")).error), "the wrong mobile gets nothing");
await db.exec(`update public.ad_visit_bookings set slot_at = now() - interval '5 minutes' where id = '${wb.id}'`);
await db.exec(`update public.owner_buildings set caretaker_name = 'Raju', caretaker_phone = '9812312312' where id = '${BLD}'`);
r = await desk();
const c = one(r);
check(c?.open === true && c.caretaker.phone === "9812312312" && c.caretaker.name === "Raju" && c.manager.phone === "9146969162",
  "from the visit's start: the caretaker, and MovEazy as manager where unset", JSON.stringify(c) + (r.error?.message || ""));
await desk("call", "caretaker");
await desk("feedback", "", "call_not_picked");
await desk("call", "manager");
check(Boolean((await desk("feedback", "", "loved")).error), "an unknown answer is refused");
check(await q1(`select count(*)::int from public.building_call_events where phone = '9833300000' and source = 'ad'`) === 4, "in the building's call log, as from the ad page");
check(/Called the caretaker from the ad page · BR Homes/.test(await q1(`select string_agg(body, ' | ') from public.crm_activities where client_id = '${waCid}'`)), "on the client's history");
const crm = one(await as(viewer, "select public.crm_ad_visits(30)")).find((x) => x.id === wb.id);
check(crm?.source === "whatsapp" && JSON.stringify(crm.flats) === '["101"]' && crm.called.length === 2 && crm.feedback[0].kind === "call_not_picked",
  "the CRM sees the source, the flat, the calls and what they said", JSON.stringify(crm));
const ov = one(await as({ uid: OWNER }, "select public.owner_qr_overview()"));
const wa = (ov?.list ?? []).find((x) => x.name === "Wa Tenant");
check(wa?.via === "moveazy" && wa.phone === "", "the owner: no number, even after calling", JSON.stringify(wa));
const ob = one(await as({ uid: OWNER }, `select public.owner_building_tenants('${BLD}')`));
const row = (ob?.tenants ?? []).find((x) => x.qr?.source === "ad");
check(row && row.phone == null && row.via === "moveazy", "the owner's board too", JSON.stringify(row));
await db.exec(`update public.ad_visit_bookings set slot_at = now() - interval '2 days' where id = '${wb.id}'`);
check(one(await desk())?.open === false, "the next day: closed");
r = await book("flat", "P1", "9844400000", T11, "Flat Only");
await db.exec(`update public.ad_visit_bookings set slot_at = now() - interval '1 minute' where id = '${one(r).id}'`);
const fd = one(await as(anon, "select public.visit_ad_desk($1, '9844400000', 'x-phone-1', 'contacts')", [one(r).id]));
check(fd?.open === true && fd.caretaker == null && fd.manager.phone === "9146969162", "a flat outside a building: MovEazy as manager", JSON.stringify(fd));
check(Boolean((await as(anon, "select * from public.ad_page_events")).error), "the events table is closed");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
