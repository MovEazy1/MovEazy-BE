/**
 * Apply multi_city.sql (PGlite) over the real areas, inventory, program
 * settings and deals files plus stand-ins, and check the seven-city rules:
 * areas per city, a flat's city from its area, a tenant's search city from
 * their form and areas (and the switch logged), staff city access, brokers'
 * city at sign-up, no lead across cities, the partner app's flats by city,
 * price and shares per city, and Steal Deals / Deal of the Day per city.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});
const file = (name) => readFileSync(new URL(`../${name}`, import.meta.url), "utf8").replace(/create extension if not exists "pgcrypto";/g, "");
const ownerCheck = readFileSync(new URL("./owner_check.mjs", import.meta.url), "utf8");
const PRELUDE = ownerCheck.split("const PRELUDE = `")[1].split("`;")[0];

let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};
async function as(db, who, sql) {
  await db.exec(`reset role; select set_config('test.uid', '${who.uid ?? ""}', false), set_config('test.email', '${who.email ?? ""}', false),
    set_config('test.staff', '${who.staff ? "on" : ""}', false), set_config('test.super', '${who.super ? "on" : ""}', false),
    set_config('test.scopes', '${who.scopes ?? ""}', false); set role ${who.role ?? "authenticated"};`);
  try { return { rows: (await db.query(sql)).rows, error: null }; } catch (e) { return { rows: null, error: e }; } finally { await db.exec("reset role"); }
}
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const q = async (db, sql) => (await db.query(sql)).rows;
const val = async (db, sql) => Object.values((await q(db, sql))[0] ?? {})[0];

const U = (n) => `d1111111-0000-0000-0000-0000000000${String(n).padStart(2, "0")}`;
const BLR = { uid: U(1), email: "blr@broker.in" };
const MUM = { uid: U(2), email: "mum@broker.in" };
const NEW = { uid: U(3), email: "new@broker.in" };
const T1 = U(11); const T2 = U(12);
const SUPER = { uid: U(20), email: "boss@moveazy.co.in", staff: true, super: true, scopes: "partners.manage,crm.properties.write" };
const MUMSTAFF = { uid: U(21), email: "mumbai@moveazy.co.in", staff: true };
const ALLSTAFF = { uid: U(22), email: "all@moveazy.co.in", staff: true, scopes: "partners.manage" };

const db = new PGlite();
await db.exec(PRELUDE);
await db.exec(file("inventory_schema.sql"));
await db.exec(`alter table public.inventory add column if not exists maintenance numeric, add column if not exists floor_number int,
  add column if not exists total_floors int, add column if not exists broker_id uuid, add column if not exists owner_id uuid,
  add column if not exists partner_visible boolean not null default true, add column if not exists rent_flag text,
  add column if not exists nearby_areas text[] default '{}', add column if not exists latitude numeric, add column if not exists longitude numeric,
  add column if not exists property_type text;`);
await db.exec(`insert into public.inventory (property_id, posted_by, area, rent, status, flat_type, city) values
  ('MZ-B1', 'owner', 'HSR', 30000, 'published', '2 BHK', 'Bangalore'),
  ('MZ-B2', 'owner', 'Koramangala', 22000, 'published', '1 BHK', null);`);
await db.exec(file("areas.sql"));
await db.exec(file("program_settings.sql"));
await db.exec(file("deal_standards.sql"));
await db.exec(file("find_deals.sql"));
await db.exec(`
alter table public.user_requirements add column if not exists localities text[] default '{}';
alter table public.crm_clients add column if not exists created_at timestamptz default now();
create table public.crm_activities (id uuid primary key default gen_random_uuid(), client_id uuid, actor_email text default '', type text default 'note',
  body text default '', meta jsonb default '{}', created_at timestamptz default now());
create table public.lead_intake (lead_key text primary key, prefs jsonb not null default '{}', crm_client_id uuid);
alter table public.crm_clients enable row level security;
grant select, insert, update, delete on public.crm_clients to authenticated;
create policy "crm read clients" on public.crm_clients for all to authenticated using (public.is_crm_staff()) with check (public.is_crm_staff());
create table public.broker_partners (user_id uuid primary key, name text not null default '', phone text not null default '', email text not null default '',
  agency text not null default '', status text not null default 'pending', approved_at timestamptz, approved_by text not null default '',
  joined_via_group uuid, referral_code text, referred_by text, client_share_pct numeric, created_at timestamptz default now(), updated_at timestamptz default now());
create table public.partner_program_settings (id int primary key, auto_approve boolean);
insert into public.partner_program_settings values (1, true);
create table public.partner_tiers (tier text primary key, label text, is_free boolean, price_monthly int, trial_price int, description text);
insert into public.partner_tiers values ('moveazy_inventory', 'Premium', false, 1499, 1499, ''), ('broker_network', 'Network', true, 0, 0, '');
create table public.partner_entitlements (user_id uuid, tier text, ends_at timestamptz);
create function public.partner_has_tier(t text) returns boolean language sql stable as $$ select true $$;
create function public.is_approved_partner() returns boolean language sql stable security definer as $$
  select exists (select 1 from public.broker_partners where user_id = auth.uid() and status = 'approved') $$;
create table public.partner_groups (id uuid primary key default gen_random_uuid(), name text, city text not null default 'Bengaluru', created_by uuid);
create table public.partner_listings (property_id text primary key, broker_id uuid, mapped_by text not null default '', prev_broker_id uuid, updated_at timestamptz default now());
create table public.partner_platform_shares (property_id text primary key, share_pct numeric);
create table public.partner_group_shares (property_id text, group_id uuid, share_pct numeric);
create table public.partner_group_members (group_id uuid, user_id uuid);
create table public.partner_pool_unlocks (partner_id uuid, property_id text);
create table public.partner_location_requests (property_id text, requested_by uuid, status text);
create table public.partner_notifications (broker_id uuid, kind text, title text, body text, link text);
create table public.partner_lead_requests (id uuid primary key, broker_id uuid, prefs jsonb default '{}', status text default 'open', lead_count int default 10);
create table public.partner_lead_assignments (id uuid primary key default gen_random_uuid(), request_id uuid, client_id uuid, broker_id uuid, assigned_by text default '');
create function public.moveazy_lead_pool()
returns table (client_id uuid, name text, phone text, localities text[], flat_types text[], budget_min numeric, budget_max numeric,
               move_in_raw text, move_in date, brokers int, active_at timestamptz)
language sql stable as $$ select c.id, c.name, c.phone, '{}'::text[], '{}'::text[], null::numeric, null::numeric, '', null::date, 0, now() from public.crm_clients c $$;
`);
// Baseline partner functions, from the repo (their live versions).
const grab = (f, name, line) => {
  const s = readFileSync(new URL(`../${f}`, import.meta.url), "utf8").replace(/\r\n/g, "\n");
  const all = [...s.matchAll(new RegExp(`create or replace function public\\.${name}\\(`, "g"))].map((m) => m.index);
  const i = line ? all.find((x) => s.slice(0, x).split("\n").length === line) : all[0];
  return s.slice(i, s.indexOf("\n$$;", i) + 4);
};
await db.exec(grab("lead_intake.sql", "normalize_mobile"));
await db.exec(grab("partner_schema.sql", "partner_register"));
await db.exec(grab("partner_group_privacy.sql", "partner_inventory", 18));
await db.exec(grab("partner_moveazy_leads.sql", "lead_candidates", 739));
await db.exec(`create table public.crm_clients_dummy (x int);`);

await db.exec(file("multi_city.sql"));
await db.exec(file("multi_city.sql"));
check(true, "multi_city.sql applies, and re-applies over itself");

console.log("\ncities and areas");
check((await val(db, "select count(*)::int from public.cities")) === 7, "seven cities");
check((await val(db, "select string_agg(public.normalize_city(x), ',' order by n) from unnest(array['Bangalore','gurgaon','New Delhi','bombay','Greater Noida','xyz']) with ordinality u(x, n)"))
  === "Bengaluru,Gurugram,Delhi,Mumbai,Noida,", "names people write map to the seven");
const per = Object.fromEntries((await q(db, "select city, count(*)::int n from public.areas group by city")).map((r) => [r.city, r.n]));
check(per.Bengaluru > 20 && ["Mumbai", "Hyderabad", "Pune", "Noida", "Gurugram", "Delhi"].every((c) => per[c] >= 20 && per[c] <= 30), "every new city has 20–30 areas; Bengaluru keeps its own", JSON.stringify(per));
check((await val(db, "select count(*)::int from public.areas where lower(name) = 'sector 15'")) === 2, "'Sector 15' is in both Noida and Gurugram");
check((await val(db, "select public.city_of_area('Powai')")) === "Mumbai" && (await val(db, "select public.city_of_area('Sector 15')")) === ""
  && (await val(db, "select public.city_of_area('Sector 15', 'gurgaon')")) === "Gurugram", "an area's city (and a shared name needs the hint)");
let r = await as(db, SUPER, `select public.area_save('{"city": "Pune", "name": "Hinjewadi"}')`);
check(r.error && /already on the Pune list/.test(r.error.message), "no duplicate inside a city", r.error?.message);
r = await as(db, SUPER, `select public.area_save('{"city": "Hyderabad", "name": "Koramangala"}')`);
check(!r.error && one(r)?.city === "Hyderabad", "the same name can be added to another city", r.error?.message);

console.log("\nflats");
check((await val(db, "select string_agg(city, ',' order by property_id) from public.inventory")) === "Bengaluru,Bengaluru", "existing flats are Bengaluru (Bangalore / empty normalised)");
await db.exec(`select set_config('test.uid', '', false); insert into public.inventory (property_id, posted_by, area, rent, status, flat_type) values ('MZ-M1', 'owner', 'Powai', 45000, 'published', '2 BHK'),
  ('MZ-M2', 'owner', 'Andheri West', 38000, 'published', '1 BHK');
  insert into public.inventory (property_id, posted_by, area, rent, status, flat_type, city) values ('MZ-G1', 'owner', 'Sector 15', 40000, 'published', '2 BHK', 'Gurgaon'),
  ('MZ-X1', 'owner', 'Somewhere New', 20000, 'published', '1 BHK', 'pune');`);
const fc = Object.fromEntries((await q(db, "select property_id, city from public.inventory")).map((x) => [x.property_id, x.city]));
check(fc["MZ-M1"] === "Mumbai" && fc["MZ-G1"] === "Gurugram" && fc["MZ-X1"] === "Pune", "a new flat's city follows its area, else what was given", JSON.stringify(fc));

console.log("\ntenants: the city they search in");
await db.exec(`insert into auth.users (id, email) values ('${T1}', 't1@x.in'), ('${T2}', 't2@x.in');
  insert into public.crm_clients (id, user_id, name, phone) values ('c1111111-0000-0000-0000-000000000001', '${T1}', 'Asha', '9000000001'),
    ('c1111111-0000-0000-0000-000000000002', null, 'Ravi', '9000000002'), ('c1111111-0000-0000-0000-000000000003', '${T2}', 'Meera', '9000000003');`);
check((await val(db, "select string_agg(distinct city, ',') from public.crm_clients")) === "Bengaluru", "existing clients are Bengaluru");
await db.exec(`insert into public.user_requirements (user_id, city, current_city) values ('${T1}', 'Pune', 'mumbai');`);
let c1 = (await q(db, "select city, current_city from public.crm_clients where user_id = '" + T1 + "'"))[0];
check(c1.city === "Pune" && c1.current_city === "Mumbai", "form says Pune, they are in Mumbai: searching Pune, currently in Mumbai", JSON.stringify(c1));
check((await val(db, `select body from public.crm_activities where client_id = 'c1111111-0000-0000-0000-000000000001'`)) === "Search city changed from Bengaluru to Pune", "the switch is noted on their record");
await db.exec(`insert into public.user_requirements (user_id, localities) values ('${T2}', '{Powai,"Andheri West"}');`);
check((await val(db, `select city from public.crm_clients where user_id = '${T2}'`)) === "Mumbai", "no city given: their areas decide (Mumbai)");
await db.exec(`insert into public.lead_intake (lead_key, prefs, crm_client_id) values ('k1', '{"city": "Hyderabad", "currentCity": "Delhi"}', 'c1111111-0000-0000-0000-000000000002');`);
const c2 = (await q(db, "select city, current_city from public.crm_clients where id = 'c1111111-0000-0000-0000-000000000002'"))[0];
check(c2.city === "Hyderabad" && c2.current_city === "Delhi", "a phone-gate lead's city from the page", JSON.stringify(c2));

console.log("\nCRM team: cities per person");
await db.exec(`insert into public.admin_roles (email, role, scopes, cities) values ('mumbai@moveazy.co.in', 'crm_manager', '{}', '{Mumbai}'),
  ('all@moveazy.co.in', 'crm_manager', '{}', '{}');`);
r = await as(db, MUMSTAFF, "select name from public.crm_clients order by name");
check(r.rows?.map((x) => x.name).join() === "Meera", "a Mumbai-only teammate reads only Mumbai clients", JSON.stringify(r.rows));
r = await as(db, MUMSTAFF, "select public.crm_my_cities()");
check(one(r)?.join() === "Mumbai", "…and their city picker offers only Mumbai");
r = await as(db, MUMSTAFF, "update public.crm_clients set name = 'Asha!' where name = 'Asha' returning id");
check(!r.error && r.rows.length === 0, "…and can't change a Pune client");
r = await as(db, ALLSTAFF, "select count(*)::int from public.crm_clients");
check(one(r) === 3, "a teammate with no cities set reads every city");
r = await as(db, SUPER, "select cardinality(public.crm_my_cities())");
check(one(r) === 7, "the super admin works all seven");
r = await as(db, ALLSTAFF, "select public.crm_client_set_city('c1111111-0000-0000-0000-000000000002', 'bombay')");
check(one(r) === "Mumbai" && (await val(db, "select city from public.crm_clients where name = 'Ravi'")) === "Mumbai", "the CRM moves a client to another city");
r = await as(db, MUMSTAFF, "select public.crm_client_set_city('c1111111-0000-0000-0000-000000000001', 'Mumbai')");
check(Boolean(r.error), "…but not one from a city they don't work");

console.log("\nbrokers: one city each");
await db.exec(`insert into auth.users (id, email) values ('${BLR.uid}', '${BLR.email}'), ('${MUM.uid}', '${MUM.email}'), ('${NEW.uid}', '${NEW.email}');
  insert into public.user_profiles (id, email, name, phone) values ('${BLR.uid}', '${BLR.email}', 'Blr', '9100000001'), ('${MUM.uid}', '${MUM.email}', 'Mum', '9100000002'),
    ('${NEW.uid}', '${NEW.email}', 'New', '9100000003');
  insert into public.broker_partners (user_id, name, phone, status) values ('${BLR.uid}', 'Blr Broker', '9100000001', 'approved');`);
check((await val(db, `select city from public.broker_partners where user_id = '${BLR.uid}'`)) === "Bengaluru", "existing brokers are Bengaluru");
r = await as(db, MUM, "select (public.partner_register('Mum Broker', 'Bay Homes', 'mumbai')).city");
check(one(r) === "Mumbai", "sign-up with the city picked", r.error?.message);
r = await as(db, MUM, "select (public.partner_register('Mum Broker', 'Bay Homes', 'Pune')).city");
check(one(r) === "Mumbai", "re-registering keeps the city");
r = await as(db, NEW, "select (public.partner_register('New', '')).city");
check(one(r) === "Bengaluru", "an old app (no city) signs up as Bengaluru");
await db.exec(`insert into public.partner_groups (name, created_by) values ('Bay Brokers', '${MUM.uid}')`);
check((await val(db, "select city from public.partner_groups where name = 'Bay Brokers'")) === "Mumbai", "a union a Mumbai broker makes is a Mumbai union");

console.log("\nleads stay in their city");
r = await as(db, SUPER, `insert into public.partner_lead_assignments (client_id, broker_id, assigned_by) values ('c1111111-0000-0000-0000-000000000003', '${BLR.uid}', 'boss') returning id`);
check(r.error && /searching in Mumbai, and this partner works in Bengaluru/.test(r.error.message), "a Mumbai tenant can't be given to a Bengaluru broker", r.error?.message);
r = await as(db, SUPER, `insert into public.partner_lead_assignments (client_id, broker_id, assigned_by) values ('c1111111-0000-0000-0000-000000000003', '${MUM.uid}', 'boss') returning id`);
check(!r.error, "…but to a Mumbai broker, yes", r.error?.message);
r = await as(db, SUPER, `insert into public.partner_lead_assignments (client_id, broker_id, assigned_by) values ('c1111111-0000-0000-0000-000000000001', '${BLR.uid}', 'website') returning id`);
check(!r.error, "the website's flat-interest leads follow the flat", r.error?.message);
await db.exec(`insert into public.partner_lead_requests (id, broker_id) values ('e1111111-0000-0000-0000-000000000001', '${MUM.uid}'), ('e1111111-0000-0000-0000-000000000002', '${BLR.uid}');`);
const candM = (await q(db, "select string_agg(name, ',' order by name) n from public.lead_candidates('e1111111-0000-0000-0000-000000000001')"))[0].n;
const candB = (await q(db, "select string_agg(name, ',' order by name) n from public.lead_candidates('e1111111-0000-0000-0000-000000000002')"))[0].n;
check(candM === "Ravi" && candB === null, "lead candidates: only the broker's city (Mumbai broker: Ravi; Meera already theirs)", `${candM} | ${candB}`);

console.log("\nprice and shares per city");
check((await val(db, "select count(*)::int from public.program_city_settings where premium_price = (select premium_price from public.program_settings)")) === 7,
  "every city starts with Bengaluru's price");
r = await as(db, ALLSTAFF, `select public.admin_set_program_settings('{"city": "Mumbai", "premiumPrice": 2999, "propertyShare": 40}')`);
check(!r.error && one(r)?.premiumPrice === 2999 && one(r)?.city === "Mumbai", "the CRM sets Mumbai's price and share", r.error?.message);
check((await val(db, "select (public.landing_settings('Bengaluru') ->> 'premiumPrice')::int")) === (await val(db, "select premium_price from public.program_settings")),
  "Bengaluru's stays");
check((await val(db, "select (public.landing_settings() ->> 'city')")) === "Bengaluru", "no city asked: Bengaluru");
r = await as(db, MUM, "select public.partner_me()");
check(one(r)?.city === "Mumbai" && one(r)?.tiers?.moveazy_inventory?.price_monthly === 2999 && Number(one(r)?.property_share) === 40 && one(r)?.partner?.city === "Mumbai",
  "a Mumbai broker sees Mumbai's price and share", JSON.stringify(one(r)?.tiers));
r = await as(db, BLR, "select public.partner_me()");
check(one(r)?.tiers?.moveazy_inventory?.price_monthly !== 2999, "a Bengaluru broker doesn't");

console.log("\nthe partner app's flats");
r = await as(db, MUM, "select string_agg(property_id, ',' order by property_id) from public.partner_inventory()");
check(one(r) === "MZ-M1,MZ-M2", "a Mumbai broker sees Mumbai's flats only", one(r));
r = await as(db, MUM, "select max(brokerage_pct) from public.partner_inventory()");
check(Number(one(r)) === 40, "…at Mumbai's property share");
r = await as(db, BLR, "select string_agg(property_id, ',' order by property_id) from public.partner_inventory()");
check(one(r) === "MZ-B1,MZ-B2", "a Bengaluru broker sees Bengaluru's", one(r));
r = await as(db, { ...SUPER, scopes: "crm.properties.write" }, `select public.crm_listing_set_partner('MZ-M1', '${BLR.uid}')`);
check(r.error && /This flat is in Mumbai/.test(r.error.message), "a Mumbai flat can't be given to a Bengaluru partner", r.error?.message);
r = await as(db, { ...SUPER, scopes: "crm.properties.write" }, `select public.crm_listing_set_partner('MZ-M1', '${MUM.uid}')`);
check(!r.error && Number(await val(db, "select share_pct from public.partner_platform_shares where property_id = 'MZ-M1'")) === 40, "…to a Mumbai one, at Mumbai's share", r.error?.message);

console.log("\nSteal Deals and Deal of the Day, per city");
r = await as(db, SUPER, "select public.crm_deal_steal_set(public.deal_this_monday(), '{MZ-B1,MZ-B2}', 'Bengaluru')");
check(!r.error, "Bengaluru's week set", r.error?.message);
r = await as(db, SUPER, "select public.crm_deal_steal_set(public.deal_this_monday(), '{MZ-M1}', 'Mumbai')");
check(!r.error && one(r)?.steal?.length === 1, "Mumbai's week set", r.error?.message);
check((await val(db, "select count(*)::int from public.steal_deals")) === 3, "…without wiping Bengaluru's");
r = await as(db, SUPER, "select public.crm_deal_steal_set(public.deal_this_monday(), '{MZ-B1}', 'Mumbai')");
check(r.error && /not a Mumbai flat/.test(r.error.message), "a Bengaluru flat can't go on Mumbai's list");
r = await as(db, SUPER, "select public.crm_deal_steal_add_kind(public.deal_this_monday(), '1bhk', 'Mumbai')");
check(!r.error && one(r)?.steal?.map((x) => x.property_id ?? x.listing?.property_id).length === 2, "add all 1 BHK: Mumbai's only", JSON.stringify(one(r)?.steal?.length));
r = await as(db, {}, "select public.deals_feed('mumbai')");
check(one(r)?.steal?.length === 2 && one(r)?.city === "Mumbai", "the site's Mumbai deals: Mumbai's flats", r.error?.message);
r = await as(db, {}, "select public.deals_feed()");
check(one(r)?.steal?.length === 2 && one(r)?.steal?.every((x) => x.listing.city === "Bengaluru"), "no city: Bengaluru's");
const today = "(now() at time zone 'Asia/Kolkata')::date";
r = await as(db, SUPER, `select public.crm_deal_day_set(${today}, '2bhk', 'MZ-B1')`);
const r2 = await as(db, SUPER, `select public.crm_deal_day_set(${today}, '2bhk', 'MZ-M1')`);
check(!r.error && !r2.error && (await val(db, "select count(*)::int from public.day_deals")) === 2, "a 2 BHK Deal of the Day in each city, same day", r.error?.message || r2.error?.message);
r = await as(db, {}, "select public.deals_feed('Mumbai')");
check(one(r)?.day?.[0]?.listing?.property_id === "MZ-M1", "Mumbai's Deal of the Day on Mumbai's page");
r = await as(db, SUPER, `select public.crm_deal_day_set(${today}, '2bhk', null, 'Mumbai')`);
check(!r.error && (await val(db, "select string_agg(property_id, ',') from public.day_deals")) === "MZ-B1", "clearing Mumbai's leaves Bengaluru's");

console.log("\nwho can't");
r = await as(db, { role: "anon" }, "select public.crm_my_cities()");
check(Boolean(r.error), "signed out: no CRM cities");
r = await as(db, BLR, "select public.crm_partner_set_city('" + BLR.uid + "', 'Pune')");
check(Boolean(r.error), "a broker can't move themself to another city");
r = await as(db, BLR, "select public.user_requirements_city_sync()");
check(Boolean(r.error), "internal triggers aren't callable");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
