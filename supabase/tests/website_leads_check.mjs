/**
 * Apply partner_website_leads.sql (PGlite, over stubs) and check website
 * leads: a tenant's ♥ (curated list or first 5), visit, signed-in open,
 * claimed anonymous open, WhatsApp tap and match each reach the flat's partner
 * — a MovEazy lead for trial/Premium, a teaser held 7 days for free plan that
 * unlocks on a trial; never from partners, staff, the owner or another
 * broker's tenant; one bell per flat and kind; MovEazy's share on closing;
 * the website holder kept out of request lists; and the CRM's view.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});
const read = (f) => readFileSync(new URL(`../${f}`, import.meta.url), "utf8");
const SQL = read("partner_website_leads.sql");
const INTAKE = read("lead_intake.sql");
const ni = INTAKE.indexOf("create or replace function public.normalize_mobile");
const NORMALIZE = INTAKE.slice(ni, INTAKE.indexOf("$$;", ni) + 3);

let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};

const PREM = "b0000000-0000-0000-0000-000000000001"; // on trial
const FREE = "b0000000-0000-0000-0000-000000000002"; // free plan
const T1 = "c0000000-0000-0000-0000-000000000001";
const T2 = "c0000000-0000-0000-0000-000000000002";
const STAFF = "c0000000-0000-0000-0000-000000000003";
const OWNED = "c0000000-0000-0000-0000-000000000004"; // another broker's tenant
const db = new PGlite();
await db.exec(`
create role anon; create role authenticated;
create schema auth;
create table auth.users (id uuid primary key, email text);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
create function auth.jwt() returns jsonb language sql stable as $$ select jsonb_build_object('email', current_setting('test.email', true)) $$;
insert into auth.users values ('${PREM}', 'p@x.in'), ('${FREE}', 'f@x.in'), ('${T1}', 't1@x.in'), ('${T2}', 't2@x.in'), ('${STAFF}', 'staff@moveazy.in'), ('${OWNED}', 'o@x.in');
create table public.admin_roles (email text, scopes text[]);
insert into public.admin_roles values ('staff@moveazy.in', '{clients.read}');
create function public.is_crm_staff() returns boolean language sql stable as $$ select current_setting('test.staff', true) = 'on' $$;
create function public.has_admin_scope(s text) returns boolean language sql stable as $$ select current_setting('test.staff', true) = 'on' $$;
create table public.broker_partners (user_id uuid primary key, name text, email text default '', agency text default '', phone text default '', status text default 'approved');
insert into public.broker_partners (user_id, name, phone) values ('${PREM}', 'Arjun', '9000000001'), ('${FREE}', 'Kiran', '9000000002');
create function public.is_approved_partner() returns boolean language sql stable security definer as $$
  select exists (select 1 from public.broker_partners where user_id = auth.uid() and status = 'approved') $$;
create table public.partner_tiers (tier text, is_free boolean);
insert into public.partner_tiers values ('moveazy_inventory', false);
create table public.partner_entitlements (user_id uuid, tier text, plan text, starts_at timestamptz, ends_at timestamptz, source text, source_ref text, granted_by text);
insert into public.partner_entitlements values ('${PREM}', 'moveazy_inventory', 'trial', now() - interval '1 day', now() + interval '29 days', 'trial', '', '');
create function public.partner_premium_at(p_user uuid, p_at timestamptz default now()) returns boolean language sql stable security definer as $$
  select exists (select 1 from public.partner_tiers t where t.tier = 'moveazy_inventory' and t.is_free)
      or exists (select 1 from public.partner_entitlements e where e.user_id = p_user and e.tier = 'moveazy_inventory'
                  and coalesce(p_at, now()) >= e.starts_at and coalesce(p_at, now()) < e.ends_at) $$;
create table public.inventory (property_id text primary key, flat_type text, area text, rent numeric, status text default 'published');
insert into public.inventory values ('A1', '2 BHK', 'HSR Layout', 25000, 'published'), ('A2', '1 BHK', 'BTM Layout', 15000, 'published'),
  ('F1', '3 BHK', 'Bellandur', 40000, 'published'), ('M1', '2 BHK', 'Koramangala', 30000, 'published');
create table public.partner_listings (property_id text, broker_id uuid);
insert into public.partner_listings values ('A1', '${PREM}'), ('A2', '${PREM}'), ('F1', '${FREE}');
create table public.owner_property_links (property_id text, owner_id uuid);
create table public.user_requirements (user_id uuid primary key);
insert into public.user_requirements values ('${T1}');
create table public.crm_clients (id uuid primary key default gen_random_uuid(), user_id uuid unique, name text default '', phone text default '',
  attributed_to text not null default 'moveazy', via text not null default '', via_broker uuid, status text default 'fresh');
insert into public.crm_clients (user_id, name, phone) values ('${T1}', 'Ravi', '9845012345'), ('${T2}', 'Meera', ''), ('${STAFF}', 'Staff', '9845000000');
insert into public.crm_clients (user_id, name, phone, attributed_to) values ('${OWNED}', 'Owned', '9845011111', '${FREE}');
create table public.crm_activities (id uuid primary key default gen_random_uuid(), client_id uuid, actor_email text, type text, body text, meta jsonb, created_at timestamptz default now());
create table public.crm_shortlists (client_id uuid, property_id text, status text, reacted_at timestamptz, primary key (client_id, property_id));
create table public.listing_reactions (user_id uuid, property_id text, reaction text, primary key (user_id, property_id));
create table public.visit_bookings (id uuid primary key default gen_random_uuid(), user_id uuid, property_id text, slot_at timestamptz, created_at timestamptz default now());
create table public.flat_scans (property_id text, visitor text, day date default (now() at time zone 'Asia/Kolkata')::date, source text default 'link',
  created_at timestamptz default now(), primary key (property_id, visitor, day));
create table public.partner_notifications (id bigint generated always as identity primary key, broker_id uuid, kind text, title text, body text default '', link text default '',
  created_at timestamptz default now(), constraint partner_notifications_kind_check check (kind in ('leads_assigned')));
create table public.partner_lead_requests (id uuid primary key default gen_random_uuid(), broker_id uuid not null, pack text not null
  constraint partner_lead_requests_pack_check check (pack in ('free10', 'paid30', 'premium')), lead_count int not null, amount int default 0, utr text default '',
  prefs jsonb default '{}', status text default 'open', note text default '', decided_by text default '', decided_at timestamptz, created_at timestamptz default now());
create table public.partner_lead_assignments (id uuid primary key default gen_random_uuid(), request_id uuid not null references public.partner_lead_requests (id),
  client_id uuid not null, broker_id uuid not null, status text default 'assigned', closed_rent numeric, deal_type text, due_amount numeric default 0,
  closed_at timestamptz, assigned_by text default '', assigned_at timestamptz default now(), updated_at timestamptz default now(), unique (client_id, broker_id));
create table public.partner_lead_reachouts (id bigint generated always as identity, assignment_id uuid, client_id uuid, broker_id uuid, channel text, at timestamptz default now());
create function public.partner_lead_allowance(p uuid) returns jsonb language sql stable as $$ select '{"premium_given": 0, "premium_closed": 0}'::jsonb $$;
`);
await db.exec(NORMALIZE);
await db.exec(SQL);
await db.exec(SQL);
check(true, "partner_website_leads.sql applies, and re-applies over itself");

async function as(who, sql) {
  await db.exec(`reset role; select set_config('test.uid', '${who.uid ?? ""}', false), set_config('test.staff', '${who.staff ? "on" : ""}', false),
    set_config('test.email', '${who.email ?? ""}', false); set role ${who.role ?? "authenticated"};`);
  try { return { rows: (await db.query(sql)).rows, error: null }; }
  catch (e) { return { rows: null, error: e }; }
  finally { await db.exec("reset role"); }
}
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const q1 = async (sql) => Object.values((await db.query(sql)).rows[0] ?? {})[0];
const cid = async (u) => q1(`select id from public.crm_clients where user_id = '${u}'`);
const notes = async () => (await db.query(`select * from public.partner_notifications order by id`)).rows;

console.log("\n♥ on a curated list → the trial partner's lead");
await db.exec(`insert into public.crm_shortlists values ('${await cid(T1)}', 'A1', 'liked', now())`);
let asg = (await db.query(`select a.*, q.pack from public.partner_lead_assignments a join public.partner_lead_requests q on q.id = a.request_id`)).rows;
check(asg.length === 1 && asg[0].broker_id === PREM && asg[0].pack === "website" && asg[0].assigned_by === "website", "a MovEazy lead under the website holder");
let n = await notes();
check(n.length === 1 && n[0].kind === "website_lead" && n[0].title === "New lead: Ravi liked your 2 BHK in HSR Layout" && n[0].link === `/tenants/asg-${asg[0].id}`,
  "the bell: New lead, who, which flat, a link", JSON.stringify(n[0]));
const log1 = await q1(`select string_agg(body, ' | ') from public.crm_activities`);
check(/Liked Arjun's 2 BHK in HSR Layout \(A1\) — shared with Arjun as a website lead/.test(log1), "logged on the CRM client", log1);

console.log("\nmore interest from the same tenant");
await db.exec(`insert into public.listing_reactions values ('${T1}', 'A2', 'like')`);
n = await notes();
check(n.length === 2 && n[1].title === "Ravi liked your 1 BHK in BTM Layout" && await q1("select count(*)::int from public.partner_lead_assignments") === 1,
  "another flat: a new bell, the same lead", n[1]?.title);
await db.exec(`update public.listing_reactions set reaction = 'dislike' where property_id = 'A2'; update public.listing_reactions set reaction = 'like' where property_id = 'A2'`);
check((await notes()).length === 2, "liking it again doesn't ring again");
await db.exec(`insert into public.visit_bookings (user_id, property_id, slot_at) values ('${T1}', 'A1', '2026-10-18 10:30:00+00')`);
n = await notes();
check(n.length === 3 && /wants to visit your 2 BHK/.test(n[2].title) && /visit booked for Sun 18 Oct, 04:00 PM/.test(n[2].body), "a visit booked: the time in the bell", n[2]?.body);
let r = await as({ uid: T1, email: "t1@x.in" }, "select public.flat_contact_tap('a1', 'whatsapp')");
check(r.error == null && (await notes()).length === 4 && /messaged about your 2 BHK/.test((await notes())[3].title), "WhatsApp tapped on the flat", r.error?.message);
r = await as({ uid: T1, email: "t1@x.in" }, "select public.website_match_flats(array['M1', 'A2', 'A1', 'A2'])");
check(r.error == null && one(r) === 3 && (await notes()).some((x) => /is looking for a flat like your 1 BHK/.test(x.title)), "a match: only partner flats, at most 3", r.error?.message);

console.log("\nopening a flat");
r = await as({ uid: T1, email: "t1@x.in" }, "select public.flat_view('A2', 'device-0001', 'link')");
check(r.error == null && /viewed your 1 BHK/.test((await notes()).at(-1).title), "signed in: the partner hears", r.error?.message);
r = await as({ role: "anon" }, "select public.flat_view('A1', 'device-9999', 'link')");
check(r.error == null && await q1(`select count(*)::int from public.flat_scans where visitor = 'device-9999'`) === 1, "anonymous: counted only", r.error?.message);
await db.exec(`update public.crm_clients set phone = '9845022222' where user_id = '${T2}'`);
r = await as({ uid: T2, email: "t2@x.in" }, "select public.flat_claim_views('device-9999')");
check(r.error == null && one(r) === 1 && (await notes()).some((x) => x.title === "New lead: Meera viewed your 2 BHK in HSR Layout"), "signing in claims it: a lead", r.error?.message);
r = await as({ uid: STAFF, email: "staff@moveazy.in" }, "select public.flat_view('A1', 'device-5555', 'link')");
check(await q1(`select count(*)::int from public.flat_scans where visitor = '${STAFF}'`) === 0, "CRM staff opening it: not a viewer, not a lead");
r = await as({ uid: PREM, email: "p@x.in" }, "select public.flat_view('A1', 'device-6666', 'link')");
check(await q1(`select count(*)::int from public.flat_scans where visitor = '${PREM}'`) === 0, "a partner opening it: not a viewer");
const before = (await notes()).length;
await db.exec(`insert into public.crm_shortlists values ('${await cid(STAFF)}', 'A1', 'liked', now()), ('${await cid(OWNED)}', 'A1', 'liked', now())`);
check((await notes()).length === before, "staff, and another broker's tenant: no lead");

console.log("\nfree plan: a teaser, kept 7 days");
await db.exec(`insert into public.crm_shortlists values ('${await cid(T1)}', 'F1', 'liked', now())`);
n = await notes();
check(n.at(-1).broker_id === FREE && n.at(-1).kind === "website_teaser" && /interested in your 3 BHK in Bellandur/.test(n.at(-1).title) && !/Ravi/.test(n.at(-1).title + n.at(-1).body),
  "the free partner: interest without the name", n.at(-1).title);
check(await q1(`select count(*)::int from public.partner_lead_assignments where broker_id = '${FREE}'`) === 0, "no lead yet");
await db.exec(`insert into public.listing_reactions values ('${T1}', 'F1', 'like')`);
check((await notes()).filter((x) => x.broker_id === FREE).length === 1, "one teaser per tenant and flat");
await db.exec(`insert into public.partner_entitlements values ('${FREE}', 'moveazy_inventory', 'trial', now(), now() + interval '30 days', 'trial', '', '')`);
check(await q1(`select count(*)::int from public.partner_lead_assignments where broker_id = '${FREE}'`) === 1, "starting a trial unlocks it");
check((await notes()).some((x) => x.broker_id === FREE && x.title === "New lead: Ravi liked your 3 BHK in Bellandur"), "…with the full lead in the bell");

console.log("\nthe partner's side");
const aid = asg[0].id;
r = await as({ uid: PREM }, `select public.partner_lead_update('${aid}', 'closed', 25000, 'direct')`);
check(r.error == null && Number(one(r).due_amount) === 7500, "closing a website lead: MovEazy's 30% due", r.error?.message ?? JSON.stringify(one(r)));
r = await as({ uid: PREM }, "select count(*)::int from public.partner_my_lead_requests()");
check(r.error == null && one(r) === 0, "the website holder isn't in their requests", r.error?.message);
r = await as({ uid: PREM }, "select public.partner_flat_leads('A1')");
const fl = one(r);
check(r.error == null && fl.tenants.length === 2 && fl.views.today >= 1 && fl.tenants.some((t) => t.name === "Ravi" && t.kinds.includes("visit")), "the flat's page: who and what, views",
  r.error?.message ?? JSON.stringify(fl));
r = await as({ uid: FREE }, "select public.partner_flat_leads('A1')");
check(r.error == null && one(r) === null, "not their flat: nothing");
r = await as({ uid: PREM }, "select public.partner_website_interest_mine()");
check(r.error == null && one(r).find((x) => x.assignment_id === aid).flats.length >= 4, "interest per lead", r.error?.message);
await db.exec(`insert into public.partner_lead_reachouts (assignment_id, client_id, broker_id, channel) values ('${aid}', '${await cid(T1)}', '${PREM}', 'call')`);
check(await q1(`select body from public.crm_activities where type = 'call'`) === "Arjun called them", "the broker's call, on the CRM client");

console.log("\nranking and the CRM");
r = await as({ role: "anon" }, "select public.partner_flat_ids()");
check(r.error == null && one(r).partner.length === 3 && one(r).boosted.length === 3, "partner flats; trial partners' boosted", r.error?.message ?? JSON.stringify(one(r)));
r = await as({ uid: T1, staff: true }, "select public.crm_website_leads()");
check(r.error == null && one(r).length >= 8 && one(r).some((x) => x.broker === "Kiran" && x.held === false), "CRM: every website lead", r.error?.message);
r = await as({ uid: T1 }, "select public.crm_website_leads()");
check(Boolean(r.error), "not staff: refused");
r = await as({ uid: T1, staff: true }, "select count(*)::int from public.crm_lead_requests()");
check(r.error == null && one(r) === 0, "CRM lead requests: the website holders left out", r.error?.message);
r = await as({ role: "anon" }, "select public.flat_contact_tap('A1')");
check(Boolean(r.error), "anon can't call the tap");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
