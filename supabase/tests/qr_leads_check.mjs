/**
 * Apply partner_qr_leads.sql (PGlite, over stubs of what it builds on) and
 * check the QR flow: a signed-in tenant with a number checks in and becomes
 * the broker's QR lead with a tentative requirement (flat types, budget, the
 * GPS locality, immediate move-in); a visit request notes the lead, rings the
 * bell and tags the CRM client; the broker's own edit ends "tentative"; the
 * board carries via/tentative; the CRM scan report; and who may call what.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});
const read = (f) => readFileSync(new URL(`../${f}`, import.meta.url), "utf8");
const SQL = read("partner_qr_leads.sql");
const INTAKE = read("lead_intake.sql");
const ni = INTAKE.indexOf("create or replace function public.normalize_mobile");
const NORMALIZE = INTAKE.slice(ni, INTAKE.indexOf("$$;", ni) + 3);

let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};

const BROKER = "b0000000-0000-0000-0000-000000000001";
const TEN = "c0000000-0000-0000-0000-000000000002";
const NOPHONE = "c0000000-0000-0000-0000-000000000003";
const OLD = "c0000000-0000-0000-0000-000000000004";
const db = new PGlite();
await db.exec(`
create role anon; create role authenticated;
create schema auth;
create table auth.users (id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
create function public.is_crm_staff() returns boolean language sql stable as $$ select current_setting('test.staff', true) = 'on' $$;
insert into auth.users values ('${BROKER}'), ('${TEN}'), ('${NOPHONE}'), ('${OLD}');
create table public.user_profiles (id uuid primary key, name text, phone text, email text, role text default 'customer');
insert into public.user_profiles values ('${TEN}', 'Ravi Kumar', '98450 12345', 'ravi@x.in'), ('${NOPHONE}', 'No Phone', '', 'np@x.in'),
  ('${OLD}', 'Old Client', '9845099999', 'old@x.in');
create table public.broker_partners (user_id uuid primary key, name text, agency text default '', phone text default '', status text default 'approved');
insert into public.broker_partners values ('${BROKER}', 'Asha', 'Asha Homes', '9000000001');
create function public.is_approved_partner() returns boolean language sql stable security definer as $$
  select exists (select 1 from public.broker_partners where user_id = auth.uid() and status = 'approved') $$;
create function public.partner_contact_phone(p uuid) returns text language sql stable as $$ select phone from public.broker_partners where user_id = p $$;
create table public.inventory (property_id text primary key, flat_type text, area text, rent numeric, available_from date,
  latitude numeric, longitude numeric, status text default 'published');
insert into public.inventory values
  ('P1', '2 BHK', 'HSR Layout', 25000, current_date + 3, 12.9116, 77.6474),
  ('P2', '3 BHK', 'HSR Layout', 38000, current_date + 30, 12.9120, 77.6480),
  ('P3', '1 BHK', 'Koramangala', 18000, null, 12.9352, 77.6245),
  ('PX', '2 BHK', 'Whitefield', 30000, null, 12.9698, 77.7500);
create table public.partner_listings (property_id text, broker_id uuid);
insert into public.partner_listings values ('P1', '${BROKER}'), ('P2', '${BROKER}'), ('P3', '${BROKER}');
create table public.partner_storefronts (broker_id uuid primary key, code text unique, photo_url text default '');
insert into public.partner_storefronts values ('${BROKER}', 'ASHA01');
create function public.storefront_broker(p_code text) returns uuid language sql stable as $$
  select broker_id from public.partner_storefronts where code = upper(trim(p_code)) $$;
create function public.storefront_homes(p_broker uuid) returns setof public.inventory language sql stable as $$
  select i.* from public.partner_listings pl join public.inventory i on i.property_id = pl.property_id
   where pl.broker_id = p_broker and i.status = 'published' $$;
create table public.partner_qr_spots (id uuid primary key default gen_random_uuid(), broker_id uuid, code text, area text, label text default '', active boolean default true);
insert into public.partner_qr_spots (broker_id, code, area) values ('${BROKER}', 'hsr1', 'HSR Layout');
create table public.partner_storefront_views (broker_id uuid, visitor text, day date default current_date, source text, user_id uuid,
  spot_id uuid, created_at timestamptz default now());
insert into public.partner_storefront_views (broker_id, visitor, source, spot_id) select '${BROKER}', 'dev-' || g, 'qr', (select id from public.partner_qr_spots) from generate_series(1, 3) g;
insert into public.partner_storefront_views (broker_id, visitor, source) values ('${BROKER}', 'dev-link', 'link');
create table public.partner_tenants (id uuid primary key default gen_random_uuid(), broker_id uuid, phone text check (phone ~ '^[6-9][0-9]{9}$'),
  name text default '', source text default 'curated' check (source in ('curated', 'storefront', 'building')),
  status text default 'unverified', created_at timestamptz default now(), last_seen_at timestamptz default now(), unique (broker_id, phone));
create table public.partner_notifications (id bigint generated always as identity primary key, broker_id uuid, kind text not null, title text,
  body text default '', link text default '', created_at timestamptz default now(), read_at timestamptz,
  constraint partner_notifications_kind_check check (kind in ('storefront_like', 'reminder')));
create table public.partner_leads (id uuid primary key default gen_random_uuid(), broker_id uuid not null default auth.uid(), name text not null,
  phone text not null default '', status text not null default 'active', flat_types text[] not null default '{}', budget_min numeric,
  budget_max numeric, localities text[] not null default '{}', furnishing text not null default '', notes text not null default '',
  last_contacted_at timestamptz, created_at timestamptz not null default now(), updated_at timestamptz not null default now());
grant select, insert, update, delete on public.partner_leads to authenticated;
create table public.partner_lead_assignments (id uuid primary key default gen_random_uuid(), broker_id uuid, client_id uuid);
create table public.partner_tenant_track (id uuid primary key default gen_random_uuid(), broker_id uuid not null, lead_id uuid, assignment_id uuid,
  outcome text, outcome_at timestamptz, lost_reason text not null default '', move_in date, deal_property_id text not null default '',
  deal_rent numeric, deal_move_in date, actions_seen_at timestamptz, updated_at timestamptz not null default now());
create table public.partner_tenant_notes (id uuid primary key default gen_random_uuid(), broker_id uuid, lead_id uuid, assignment_id uuid,
  body text, created_at timestamptz default now());
create function public.partner_tenant_link(p_lead uuid, p_assignment uuid) returns text language sql immutable as $$
  select '/tenants/' || case when p_lead is not null then 'lead-' || p_lead::text else 'asg-' || p_assignment::text end $$;
create table public.partner_curated_lists (id uuid primary key default gen_random_uuid(), broker_id uuid, lead_id uuid, assignment_id uuid, opened_at timestamptz);
create table public.partner_curated_actions (list_id uuid, property_id text, action text, at timestamptz default now());
create table public.partner_visits (lead_id uuid, assignment_id uuid, visit_at timestamptz, status text);
create table public.partner_reminders (id uuid primary key default gen_random_uuid(), broker_id uuid, lead_id uuid, assignment_id uuid,
  due_at timestamptz, note text, kind text, done_at timestamptz);
create function public.partner_my_assigned_leads() returns table (id uuid, name text, phone text, localities text[], flat_types text[],
  budget_min numeric, budget_max numeric, move_in_raw text, move_in date, assigned_at timestamptz, last_reach_at timestamptz, status text, pack text)
  language sql stable as $$ select null::uuid, null, null, null::text[], null::text[], null::numeric, null::numeric, null, null::date,
  null::timestamptz, null::timestamptz, null, null where false $$;
create table public.crm_clients (id uuid primary key default gen_random_uuid(), user_id uuid unique, name text default '', phone text default '',
  email text default '', source text default 'app', status text default 'fresh', attributed_to text not null default 'moveazy',
  created_at timestamptz default now(), updated_at timestamptz default now());
create table public.crm_activities (id uuid primary key default gen_random_uuid(), client_id uuid not null, actor_email text, type text, body text,
  meta jsonb, created_at timestamptz default now());
-- the sign-up the phone just made (crm_phone_leads.sql), and an old MovEazy client
insert into public.crm_clients (user_id, name, phone, source) values ('${TEN}', 'Ravi Kumar', '9845012345', 'signup');
insert into public.crm_clients (user_id, name, phone, source, created_at) values ('${OLD}', 'Old Client', '9845099999', 'signup', now() - interval '40 days');
`);
await db.exec(NORMALIZE);
await db.exec(SQL);
await db.exec(SQL);
check(true, "partner_qr_leads.sql applies, and re-applies over itself");

async function as(who, sql, params = []) {
  await db.exec(`reset role; select set_config('test.uid', '${who.uid ?? ""}', false), set_config('test.staff', '${who.staff ? "on" : ""}', false);
    set role ${who.role ?? "authenticated"};`);
  try { return { rows: (await db.query(sql, params)).rows, error: null }; }
  catch (e) { return { rows: null, error: e }; }
  finally { await db.exec("reset role"); }
}
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const q1 = async (sql) => Object.values((await db.query(sql)).rows[0] ?? {})[0];
const ravi = { uid: TEN }, asha = { uid: BROKER };

console.log("\nchecking in");
let r = await as({ role: "anon" }, "select public.partner_storefront_checkin('ASHA01')");
check(Boolean(r.error), "anon: refused", r.error?.message);
r = await as({ uid: NOPHONE }, "select public.partner_storefront_checkin('ASHA01')");
check(r.error == null && one(r).lead === false, "signed in without a number: no lead yet", r.error?.message);
r = await as(ravi, `select public.partner_storefront_checkin('ASHA01', 'HSR1', 'qr', 12.9118, 77.6476, 25,
  '{"filters":["2 BHK"],"opened":["P1","P2","PX"]}'::jsonb)`);
check(r.error == null && one(r).lead === true, "signed in with a number: a lead", r.error?.message);
const lead = (await db.query(`select * from public.partner_leads where broker_id = '${BROKER}'`)).rows;
check(lead.length === 1 && lead[0].source === "qr" && lead[0].tentative === true && lead[0].phone === "9845012345", "one QR lead, tentative, with the number");
check(JSON.stringify(lead[0].flat_types) === JSON.stringify(["2 BHK", "3 BHK"]), "flat types: the chip + the flats opened (not another broker's)", JSON.stringify(lead[0].flat_types));
check(Number(lead[0].budget_min) === 25000 && Number(lead[0].budget_max) === 38000, "budget: lowest to highest rent opened", `${lead[0].budget_min}-${lead[0].budget_max}`);
check(JSON.stringify(lead[0].localities) === '["HSR Layout"]', "area: the locality nearest the GPS point", JSON.stringify(lead[0].localities));
check(lead[0].move_in_label === "immediate", "move-in within 7 days (P1, in 3 days): immediate");
check(await q1(`select move_in = current_date + 3 from public.partner_tenant_track where lead_id = '${lead[0].id}'`) === true, "the track carries the earliest move-in");
const ck = (await db.query(`select * from public.partner_qr_checkins`)).rows;
check(ck.length === 1 && ck[0].locality === "HSR Layout" && ck[0].spot_id && ck[0].lead_id === lead[0].id, "the check-in: located, poster spot, lead");
check(await q1(`select count(*)::int from public.partner_tenants where source = 'storefront'`) === 1, "and the broker's tenant (CRM → Broker leads)");
let n = (await db.query(`select * from public.partner_notifications order by id`)).rows;
check(n.length === 1 && n[0].kind === "storefront_lead" && /Ravi Kumar scanned your QR/.test(n[0].title) && /HSR Layout/.test(n[0].body)
  && n[0].link === `/tenants/lead-${lead[0].id}` && !/9845012345/.test(n[0].body), "the bell: scanned your QR, the requirement, a link — not the number", JSON.stringify(n[0]));
let crm = (await db.query(`select * from public.crm_clients where user_id = '${TEN}'`)).rows[0];
check(crm.via === "qr" && crm.via_broker === BROKER && crm.attributed_to === BROKER, "CRM: today's sign-up tagged QR and the broker's (out of the pool)");
check(/Scanned Asha's QR poster/.test(await q1(`select body from public.crm_activities order by created_at limit 1`)), "CRM activity logged");

r = await as(ravi, `select public.partner_storefront_checkin('ASHA01', '', 'qr', null, null, null, '{"opened":["P3"]}'::jsonb)`);
const again = (await db.query(`select * from public.partner_leads where broker_id = '${BROKER}'`)).rows;
check(again.length === 1 && Number(again[0].budget_min) === 18000 && again[0].flat_types.includes("1 BHK"), "checking in again grows the same tentative lead");
check((await db.query(`select * from public.partner_qr_checkins`)).rows[0].locality === "HSR Layout", "a later check-in without location keeps the GPS one");
check(await q1(`select count(*)::int from public.partner_notifications`) === 1, "and doesn't ring the bell twice");

console.log("\nasking for a visit");
r = await as(ravi, "select public.partner_storefront_visit('ASHA01', 'PX')");
check(/not on this storefront/.test(r.error?.message ?? ""), "another broker's flat: refused", r.error?.message);
r = await as({ uid: NOPHONE }, "select public.partner_storefront_visit('ASHA01', 'P2')");
check(/mobile number/.test(r.error?.message ?? ""), "no number: asked for one", r.error?.message);
r = await as(asha, "select public.partner_storefront_visit('ASHA01', 'P2')");
check(/own flat/.test(r.error?.message ?? ""), "the broker on their own page: refused", r.error?.message);
r = await as(ravi, "select public.partner_storefront_visit('ASHA01', 'P2')");
const res = one(r);
check(r.error == null && res.broker.name === "Asha" && res.broker.phone === "9000000001" && res.home.flat_type === "3 BHK", "the thank-you page gets the broker and the flat", r.error?.message);
n = (await db.query(`select * from public.partner_notifications order by id`)).rows;
check(n.length === 2 && n[1].kind === "storefront_visit" && /wants to visit/.test(n[1].title) && /3 BHK · HSR Layout · ₹38,000/.test(n[1].body),
  "the bell: wants to visit, which flat", n[1]?.body);
check(/Asked to visit 3 BHK · HSR Layout/.test(await q1(`select body from public.partner_tenant_notes`)), "a note on the lead");
await as(ravi, "select public.partner_storefront_visit('ASHA01', 'P2')");
check(await q1(`select count(*)::int from public.partner_notifications`) === 2, "asking again for the same flat doesn't ring again");

console.log("\nthe broker's side");
r = await as(asha, "select public.partner_tenants_board()");
const row = one(r)?.[0];
check(r.error == null && row?.via === "qr" && row?.tentative === true && row?.qr_visits === 1 && row?.move_in_raw === "Immediate move-in",
  "the board: QR, tentative, 1 visit asked, immediate", r.error?.message ?? JSON.stringify(row));
await as(asha, `update public.partner_leads set budget_max = 30000 where id = '${lead[0].id}'`);
check(await q1(`select tentative from public.partner_leads`) === false, "the broker edits the requirement: no longer tentative");
await as(ravi, `select public.partner_storefront_checkin('ASHA01', '', 'qr', null, null, null, '{"opened":["P2"]}'::jsonb)`);
check(Number(await q1(`select budget_max from public.partner_leads`)) === 30000, "…and the QR page no longer changes it");
r = await as(asha, "select public.partner_poster_downloaded(false)");
check(r.error == null && one(r) === null, "poster not downloaded yet");
r = await as(asha, "select public.partner_poster_downloaded(true)");
check(r.error == null && one(r) != null, "marked downloaded");
r = await as(ravi, "select public.partner_poster_downloaded(true)");
check(Boolean(r.error), "a tenant can't call it");

console.log("\nan older MovEazy client");
await db.exec(`insert into public.inventory values ('P4', '2 BHK', 'BTM Layout', 22000, current_date + 20, null, null)`);
await db.exec(`insert into public.partner_listings values ('P4', '${BROKER}')`);
r = await as({ uid: OLD }, `select public.partner_storefront_visit('ASHA01', 'P4')`);
crm = (await db.query(`select * from public.crm_clients where user_id = '${OLD}'`)).rows[0];
check(r.error == null && crm.via === "qr" && crm.attributed_to === "moveazy", "tagged QR but stays MovEazy's", r.error?.message);
const oldLead = (await db.query(`select * from public.partner_leads where phone = '9845099999'`)).rows[0];
check(oldLead && oldLead.move_in_label === "" && oldLead.localities.length === 0, "move-in in 20 days isn't immediate; no location, no area");

console.log("\nthe CRM report");
r = await as({ uid: TEN }, "select public.crm_qr_scans(30)");
check(Boolean(r.error), "not staff: refused");
r = await as({ uid: TEN, staff: true }, "select public.crm_qr_scans(30)");
const rep = one(r);
check(r.error == null && rep.totals.scans === 3 && rep.totals.signed_in === 2 && rep.totals.located === 1 && rep.totals.leads === 2 && rep.totals.visits === 2,
  "totals: QR scans only, sign-ins, located, leads, visits", r.error?.message ?? JSON.stringify(rep?.totals));
check(rep.brokers[0].name === "Asha" && rep.brokers[0].scans === 3 && rep.brokers[0].spots === 1, "broker leaderboard");
const hsr = rep.areas.find((a) => a.area === "HSR Layout");
check(hsr && hsr.gps === 1 && hsr.poster === 3 && hsr.scans === 4, "hotspot: GPS check-ins + poster spot scans", JSON.stringify(rep.areas));
check(rep.points.length === 1 && rep.points[0].broker === "Asha" && rep.points[0].lead === true, "map points");
r = await as({ uid: TEN, staff: true }, "select public.crm_qr_scans(null)");
check(r.error == null && one(r).since === null, "all time");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
