/**
 * Apply owner_qr_overview.sql (PGlite, over stubs of what it builds on, with
 * production's flat_view and building_view) and check the owner's QR scans:
 *
 *   - every open counts — a repeat the same day is one more hit on the day's
 *     row, so the people counts don't move; 500 a day at most per visitor;
 *   - a signed-in open is that account's; opens before signing in on the same
 *     phone become theirs on sign-in (the last week, never the owner's own);
 *   - the owner sees totals, this week, each flat and building, and the people:
 *     signed-in openers, flat visit bookings and building visit requests —
 *     with name, mobile, email and tenant profile; never the owner themselves;
 *   - another owner, a renter, anon: nothing.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});
const read = (f) => readFileSync(new URL(`../${f}`, import.meta.url), "utf8");
/** One function's definition, as production has it. */
const fn = (src, name) => {
  const i = src.indexOf(`create or replace function public.${name}(`);
  const body = src.indexOf("as $$", i);
  return src.slice(i, src.indexOf("$$;", body + 5) + 3);
};
const SQL = read("owner_qr_overview.sql");

let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};

const OWNER = "a0000000-0000-0000-0000-000000000001";
const OTHER = "a0000000-0000-0000-0000-000000000002";
const RAVI = "c0000000-0000-0000-0000-000000000003"; // signs in after scanning, has a profile
const NEHA = "c0000000-0000-0000-0000-000000000004"; // books a visit, number only on her requirement
const OLDIE = "c0000000-0000-0000-0000-000000000005"; // opened signed in before this file (visitor = her id)
const BLD = "d0000000-0000-0000-0000-000000000006";
const BLD2 = "d0000000-0000-0000-0000-000000000007";

const db = new PGlite();
await db.exec(`
create role anon; create role authenticated;
create schema auth;
grant usage on schema auth to anon, authenticated;
create table auth.users (id uuid primary key, email text);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
insert into auth.users values ('${OWNER}', 'owner@x.in'), ('${OTHER}', 'other@x.in'), ('${RAVI}', 'ravi@x.in'),
  ('${NEHA}', 'neha.s@x.in'), ('${OLDIE}', 'oldie@x.in');

create table public.owner_accounts (user_id uuid primary key, status text);
insert into public.owner_accounts values ('${OWNER}', 'approved'), ('${OTHER}', 'approved');
create function public.is_approved_owner() returns boolean language sql stable security definer as $$
  select auth.uid() is not null and exists (select 1 from public.owner_accounts o where o.user_id = auth.uid() and o.status = 'approved') $$;

create table public.inventory (property_id text primary key, status text default 'published');
insert into public.inventory values ('P1'), ('P2'), ('PX');
create table public.owner_property_links (owner_id uuid, property_id text, linked_at timestamptz default now());
insert into public.owner_property_links values ('${OWNER}', 'P1'), ('${OWNER}', 'P2'), ('${OTHER}', 'PX');
create table public.owner_buildings (id uuid primary key, owner_id uuid, broker_id uuid, name text, code text);
insert into public.owner_buildings values ('${BLD}', '${OWNER}', null, 'Sunrise Residency', 'SUNRS2'), ('${BLD2}', '${OTHER}', null, 'Other Towers', 'OTHER2');
create function public.building_by_code(p_code text) returns uuid language sql stable as $$
  select id from public.owner_buildings where code = upper(trim(p_code)) $$;

create table public.flat_scans (
  property_id text not null references public.inventory (property_id) on delete cascade,
  visitor text not null check (length(visitor) between 8 and 64),
  day date not null default (now() at time zone 'Asia/Kolkata')::date,
  source text not null default 'link' check (source in ('qr', 'link')),
  created_at timestamptz not null default now(),
  primary key (property_id, visitor, day));
create table public.owner_building_scans (
  building_id uuid not null references public.owner_buildings (id) on delete cascade,
  visitor text not null check (length(visitor) between 8 and 64),
  day date not null default (now() at time zone 'Asia/Kolkata')::date,
  source text not null default 'link' check (source in ('qr', 'link')),
  created_at timestamptz not null default now(),
  primary key (building_id, visitor, day));
create table public.visit_bookings (id uuid primary key default gen_random_uuid(), user_id uuid, property_id text,
  status text default 'scheduled', created_at timestamptz default now());
create table public.owner_building_leads (id uuid primary key default gen_random_uuid(), building_id uuid, name text default '',
  phone text, user_id uuid, status text default 'new', created_at timestamptz default now());
create table public.user_profiles (id uuid primary key, email text, name text default '', phone text default '');
insert into public.user_profiles values ('${RAVI}', 'ravi@x.in', 'Ravi Kumar', '9845012345'), ('${NEHA}', 'neha.s@x.in', '', ''),
  ('${OWNER}', 'owner@x.in', 'The Owner', '9000000000');
create table public.user_requirements (user_id uuid primary key, whatsapp text default '');
insert into public.user_requirements values ('${NEHA}', '9900011122');
create table public.tenant_profiles (user_id uuid primary key, linkedin text default '', current_company text default '',
  past_company text default '', first_job boolean default false, college text default '', graduation_year int,
  in_bangalore_since text default '', score int default 0);
insert into public.tenant_profiles (user_id, linkedin, current_company, college, score)
  values ('${RAVI}', 'https://www.linkedin.com/in/ravi-k', 'Flipkart', 'IIT Madras', 82);
create table public.broker_partners (user_id uuid primary key);
create function public.website_tenant_ok(p_user uuid, p_property text) returns boolean language sql stable as $$
  select p_user is not null and not exists (select 1 from public.broker_partners b where b.user_id = p_user)
     and not exists (select 1 from public.owner_property_links l where l.property_id = p_property and l.owner_id = p_user) $$;
create function public.website_lead_for_user(p_user uuid, p_property text, p_kind text, p_detail text) returns void language sql as $$ select $$;

-- Before this file: an open signed in was stored under the account's id.
insert into public.flat_scans (property_id, visitor, day, source, created_at) values ('P2', '${OLDIE}', current_date - 3, 'link', now() - interval '3 days');
`);
await db.exec(fn(read("partner_website_leads.sql"), "flat_view"));
await db.exec(fn(read("owner_buildings.sql"), "building_view"));
await db.exec(`grant select, insert, update, delete on all tables in schema public to anon, authenticated;
  grant execute on all functions in schema public to anon, authenticated;`);
await db.exec(SQL);
await db.exec(SQL);
check(true, "owner_qr_overview.sql applies, and re-applies over itself");

async function as(who, sql) {
  await db.exec(`reset role; select set_config('test.uid', '${who.uid ?? ""}', false); set role ${who.role ?? "authenticated"};`);
  try { return { rows: (await db.query(sql)).rows, error: null }; }
  catch (e) { return { rows: null, error: e }; }
  finally { await db.exec("reset role; select set_config('test.uid', '', false);"); }
}
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const q1 = async (sql) => Object.values((await db.query(sql)).rows[0] ?? {})[0];
const anon = { role: "anon" }, owner = { uid: OWNER }, other = { uid: OTHER }, ravi = { uid: RAVI }, neha = { uid: NEHA };

console.log("\nevery open counts");
check(await q1(`select user_id::text from public.flat_scans where visitor = '${OLDIE}'`) === OLDIE, "an earlier signed-in open is that account's");
for (let i = 0; i < 3; i++) await as(anon, `select public.flat_view('P1', 'phone-ravi-0001', 'qr')`);
await as(anon, `select public.flat_view('P1', 'phone-walkby-01', 'link')`);
await as(anon, `select public.flat_view('p1', 'phone-walkby-01', 'qr')`);
check(await q1(`select count(*)::int from public.flat_scans where property_id = 'P1'`) === 2, "two people, one row each for the day");
check(await q1(`select hits from public.flat_scans where visitor = 'phone-ravi-0001'`) === 3, "three opens by one phone: 3 hits");
check(await q1(`select source from public.flat_scans where visitor = 'phone-walkby-01'`) === "qr", "a link open then a QR scan: counted as QR");
await as(owner, `select public.flat_view('P1', 'owner-phone-01', 'qr')`);
check(await q1(`select count(*)::int from public.flat_scans where visitor in ('owner-phone-01', '${OWNER}')`) === 0, "the owner's own open doesn't count");
await db.exec(`update public.flat_scans set hits = 499 where visitor = 'phone-walkby-01'`);
await as(anon, `select public.flat_view('P1', 'phone-walkby-01', 'qr')`);
await as(anon, `select public.flat_view('P1', 'phone-walkby-01', 'qr')`);
check(await q1(`select hits from public.flat_scans where visitor = 'phone-walkby-01'`) === 500, "500 a day at most per visitor");
await db.exec(`update public.flat_scans set hits = 2 where visitor = 'phone-walkby-01'`);

await as(anon, `select public.building_view('sunrs2', 'phone-ravi-0001', 'qr')`);
await as(anon, `select public.building_view('SUNRS2', 'phone-ravi-0001', 'qr')`);
await as(neha, `select public.building_view('SUNRS2', 'neha-phone-001', 'link')`);
check(await q1(`select hits from public.owner_building_scans where visitor = 'phone-ravi-0001'`) === 2, "a building's repeat opens count too");
check(await q1(`select user_id::text from public.owner_building_scans where visitor = '${NEHA}'`) === NEHA, "a signed-in open is the account's");
await as(anon, `select public.building_view('OTHER2', 'phone-x-000001', 'qr')`);

console.log("\nsigning in after scanning");
await db.exec(`insert into public.flat_scans (property_id, visitor, day, source) values ('P2', 'phone-ravi-0001', current_date - 20, 'qr')`);
let r = await as(anon, `select public.owner_scans_claim('phone-ravi-0001')`);
check(Boolean(r.error) || await q1(`select count(*)::int from public.flat_scans where user_id = '${RAVI}'`) === 0, "anon can't claim");
r = await as(ravi, `select public.owner_scans_claim('phone-ravi-0001')`);
check(r.error == null, "a renter claims their phone's opens", r.error?.message);
check(await q1(`select user_id::text from public.flat_scans where visitor = 'phone-ravi-0001' and property_id = 'P1'`) === RAVI, "this week's flat open is now Ravi's");
check(await q1(`select user_id::text from public.owner_building_scans where visitor = 'phone-ravi-0001'`) === RAVI, "and the building open");
check(await q1(`select user_id is null from public.flat_scans where visitor = 'phone-ravi-0001' and day < current_date - 7`) === true, "not one older than a week");
await db.exec(`insert into public.flat_scans (property_id, visitor, source) values ('P1', 'shared-phone-01', 'qr')`);
await as(owner, `select public.owner_scans_claim('shared-phone-01')`);
check(await q1(`select user_id is null from public.flat_scans where visitor = 'shared-phone-01'`) === true, "the owner signing in doesn't claim their own flat's opens");

console.log("\nvisits");
await db.exec(`insert into public.visit_bookings (user_id, property_id) values ('${NEHA}', 'P1');
  insert into public.visit_bookings (user_id, property_id, status) values ('${RAVI}', 'P2', 'cancelled');
  insert into public.owner_building_leads (building_id, name, phone) values ('${BLD}', 'Walk In', '9811122233');
  insert into public.owner_building_leads (building_id, name, phone, status) values ('${BLD}', 'Gone', '9811100000', 'cancelled');
  insert into public.owner_building_leads (building_id, name, phone) values ('${BLD2}', 'Not yours', '9811199999');`);

console.log("\nthe owner's overview");
r = await as(owner, "select public.owner_qr_overview()");
check(r.error == null, "the owner reads it", r.error?.message);
const o = one(r);
// P1: ravi 3 + walkby 2 + shared 1 = 6; P2: oldie 1 + ravi(20 days ago) 1 = 2; building: ravi 2 + neha 1 = 3
check(o.scans === 11, "scans: every open across flats and the building", String(o.scans));
check(o.week === 10, "this week: all but the open 20 days ago", String(o.week));
const byRef = Object.fromEntries(o.by_place.map((p) => [p.ref, p]));
check(byRef.P1?.scans === 6 && byRef.P2?.scans === 2 && byRef[BLD]?.scans === 3 && byRef[BLD]?.name === "Sunrise Residency",
  "each flat and building", JSON.stringify(o.by_place));
check(!byRef.PX && !byRef[BLD2], "nothing of another owner's");
const list = Object.fromEntries(o.list.map((p) => [p.name, p]));
check(o.people === 4 && o.list.length === 4, "people: Ravi, Neha, the earlier signed-in opener, the walk-in", o.list.map((p) => p.name).join(", "));
check(o.visited === 2, "visited: Neha's booking and the walk-in's request (cancelled ones don't count)", String(o.visited));
const rv = list["Ravi Kumar"];
check(rv?.phone === "9845012345" && rv?.email === "ravi@x.in", "Ravi: name, mobile, email");
check(rv?.profile?.company === "Flipkart" && rv?.profile?.linkedin === "https://www.linkedin.com/in/ravi-k" && rv?.profile?.score === 82,
  "and his tenant profile", JSON.stringify(rv?.profile));
check(rv?.places.some((p) => p.kind === "flat" && p.ref === "P1" && p.hits === 3) && rv?.places.some((p) => p.kind === "building" && p.ref === BLD),
  "which pages he opened, how often", JSON.stringify(rv?.places));
check(rv?.visit === false, "his cancelled visit isn't a visit");
const nh = list["neha.s"];
check(nh?.phone === "9900011122" && nh?.visit === true, "Neha: named from her email, mobile from her requirement, visited", JSON.stringify(nh));
check(list["Walk In"]?.phone === "9811122233" && list["Walk In"]?.user_id == null, "the building walk-in: name and number");
check(list.oldie?.places?.[0]?.ref === "P2", "the earlier signed-in opener is there too");
check(!o.list.some((p) => p.user_id === OWNER || p.name === "Gone" || p.name === "Not yours"), "never the owner, a cancelled request or another owner's lead");

console.log("\nwho can read it");
const ot = one(await as(other, "select public.owner_qr_overview()"));
check(ot.scans === 1 && ot.list.length === 1 && ot.list[0].name === "Not yours" && ot.by_place.every((p) => p.ref === "PX" || p.ref === BLD2), "another owner: only their own", JSON.stringify(ot));
check(one(await as(ravi, "select public.owner_qr_overview()")) == null, "a renter: nothing");
r = await as(anon, "select public.owner_qr_overview()");
check(Boolean(r.error), "anon: refused");
r = await as(ravi, "select public.flat_scans_count_open()");
check(Boolean(r.error), "the trigger functions aren't callable");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
