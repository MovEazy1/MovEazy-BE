/**
 * Apply owner_schema.sql to a real Postgres (PGlite, in-process) and check what
 * the owner app rests on:
 *
 *   - an owner sees, edits and files tenants and requests against only the flats
 *     linked to them — posted-as-owner flats link themselves, CRM uploads do not;
 *   - interested renters reach an owner as "Rahul M." and a requirement, never a
 *     phone, email or account id;
 *   - the area rent guide is computed from comparable stock, with a fallback;
 *   - quotes at or above the threshold wait for the owner; internal notes never
 *     reach them;
 *   - a Premium broker asking for an owner-app flat's contact gets MovEazy.
 *
 * The files are applied over the inventory, visits, tenants and partner files in
 * production's order, as the other checks here do.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});

const file = (name) =>
  readFileSync(new URL(`../${name}`, import.meta.url), "utf8")
    .replace(/create extension if not exists "pgcrypto";/g, "");

const O1 = "a1111111-0000-0000-0000-000000000001"; // Priya, the owner under test
const O2 = "a2222222-0000-0000-0000-000000000002"; // another owner
const R1 = "b1111111-0000-0000-0000-000000000003"; // renter who booked a visit
const R2 = "b2222222-0000-0000-0000-000000000004"; // renter who asked + liked, email for a name, no phone
const S = "c1111111-0000-0000-0000-000000000005";  // CRM staff
const B = "d1111111-0000-0000-0000-000000000006";  // Premium broker partner
const K1 = "e1111111-0000-0000-0000-000000000007"; // CRM client with no account

const PRELUDE = `
create role anon;
create role authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant all on functions to anon, authenticated;

create schema auth;
grant usage on schema auth to anon, authenticated;
create table auth.users (id uuid primary key, email text);
create function auth.uid() returns uuid language sql stable
  as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
create function auth.jwt() returns jsonb language sql stable
  as $$ select jsonb_build_object('email', current_setting('test.email', true)) $$;

create function public.is_admin_allowlisted() returns boolean language sql stable as $$ select false $$;
create function public.is_super_admin() returns boolean language sql stable
  as $$ select coalesce(current_setting('test.super', true), '') = 'on' $$;
create function public.is_crm_staff() returns boolean language sql stable
  as $$ select coalesce(current_setting('test.staff', true), '') = 'on' $$;
create function public.has_admin_scope(s text) returns boolean language sql stable
  as $$ select public.is_super_admin()
            or s = any(string_to_array(coalesce(current_setting('test.scopes', true), ''), ',')) $$;

create table public.admin_roles (email text primary key, role text, scopes text[] not null default '{}');
insert into public.admin_roles values ('yatharth200018@gmail.com', 'super_admin', '{crm.clients.write}');

create table public.user_profiles (
  id uuid primary key references auth.users(id), email text not null, name text default '', phone text default ''
);
grant select, insert, update on public.user_profiles to authenticated;

create table public.user_requirements (
  user_id uuid primary key, occupants text[] default '{}', budget_max numeric, flat_types text[] default '{}'
);

-- The CRM tables the candidates function reads, as crm_schema.sql shapes them.
create table public.crm_clients (id uuid primary key, user_id uuid, name text default '', phone text default '');
create table public.crm_shortlists (
  id uuid primary key default gen_random_uuid(), client_id uuid not null references public.crm_clients(id),
  property_id text not null, status text not null default 'shortlisted', shared_at timestamptz,
  created_at timestamptz not null default now()
);
create table public.crm_client_requirements (
  client_id uuid primary key, occupants text[] default '{}', budget_max numeric, flat_types text[] default '{}'
);
create table public.crm_notifications (
  id uuid primary key default gen_random_uuid(), for_email text not null, type text not null default 'payment',
  title text not null default '', body text default '', actor_email text default '', read_at timestamptz,
  created_at timestamptz not null default now()
);
`;

const CRM_INVENTORY = `
alter table public.inventory add column if not exists source text default '';
alter table public.inventory add column if not exists source_url text default '';
create policy "crm staff read all inventory" on public.inventory for select
  to authenticated using (public.is_crm_staff());
create policy "crm staff write inventory" on public.inventory for all
  to authenticated using (public.has_admin_scope('crm.properties.write'))
  with check (public.has_admin_scope('crm.properties.write'));
`;

const SEED = `
insert into auth.users (id, email) values
  ('${O1}', 'priya@example.com'), ('${O2}', 'om@example.com'), ('${R1}', 'rahul@example.com'),
  ('${R2}', 'sneha@example.com'), ('${S}', 'agent@moveazy.co.in'), ('${B}', 'broker@example.com');
insert into public.user_profiles (id, email, name, phone) values
  ('${O1}', 'priya@example.com', 'Priya Kumar', '9876500001'),
  ('${O2}', 'om@example.com', 'Om Das', '9876500002'),
  ('${R1}', 'rahul@example.com', 'Rahul  Mehta', '9876500003'),
  ('${R2}', 'sneha@example.com', 'sneha@example.com', ''),
  ('${S}', 'agent@moveazy.co.in', 'Agent', '9876500005'),
  ('${B}', 'broker@example.com', 'Bala Broker', '9876500006');

insert into public.inventory (property_id, posted_by, poster_id, poster_name, phone, area, full_address, rent, status, flat_type, bedrooms, source)
values
  ('MZ-OWN001', 'owner',  '${O1}', 'Priya', '9876500001', 'HSR Layout', '27th Main', 32000, 'published', '2 BHK', 2, ''),
  ('MZ-OWN002', 'owner',  '${O1}', 'Priya', '9876500001', 'HSR Layout', '14th Main', 28000, 'published', '1 BHK', 1, 'crm'),
  ('MZ-BRK001', 'broker', '${O1}', 'Priya', '9876500001', 'HSR Layout', '1st Main',  25000, 'published', '1 BHK', 1, ''),
  ('MZ-O2FLAT', 'owner',  '${O2}', 'Om',    '9876500002', 'Whitefield', 'ITPL Road', 15000, 'published', '1 RK', 1, ''),
  ('MZ-CRM010', 'owner',  '${S}',  'Staff', '9000000010', 'Koramangala', '5th Block', 45000, 'rented', '3 BHK', 3, 'crm'),
  ('MZ-PEER01', 'owner',  null, 'X', '9000000001', 'HSR Layout', '', 30000, 'published', '2 BHK', 2, 'crm'),
  ('MZ-PEER02', 'owner',  null, 'X', '9000000001', 'HSR Layout', '', 34000, 'published', '2BHK', 2, 'crm'),
  ('MZ-PEER03', 'broker', null, 'X', '9000000001', 'HSR Layout', '', 36000, 'rented', '2 BHK', 2, 'crm'),
  ('MZ-PEER04', 'owner',  null, 'X', '9000000001', 'Kudlu Gate', '', 40000, 'published', '2 BHK', 2, 'crm'),
  ('MZ-PEER05', 'owner',  null, 'X', '9000000001', 'HSR Layout', '', 60000, 'published', '3 BHK', 3, 'crm'),
  ('MZ-PEER06', 'owner',  null, 'X', '9000000001', 'HSR Layout', '', 99000, 'paused', '2 BHK', 2, 'crm');
-- Kudlu Gate sits inside HSR (withParentArea): a 2 BHK there counts for HSR Layout via nearby_areas.
update public.inventory set nearby_areas = '{HSR Layout}' where property_id = 'MZ-PEER04';

insert into public.visit_bookings (user_id, property_id, slot_at, status) values
  ('${R1}', 'MZ-OWN001', now() + interval '1 day', 'scheduled'),
  ('${R2}', 'MZ-OWN001', null, 'preference'),
  ('${R1}', 'MZ-O2FLAT', now() + interval '2 days', 'scheduled');
insert into public.listing_reactions (user_id, property_id, reaction) values ('${R2}', 'MZ-OWN001', 'like');
insert into public.crm_clients (id, user_id, name, phone) values ('${K1}', null, 'Kiran Rao', '9123400000');
insert into public.crm_shortlists (client_id, property_id, status, shared_at) values ('${K1}', 'MZ-OWN001', 'shared', now());
insert into public.user_requirements (user_id, occupants, budget_max, flat_types) values ('${R1}', '{Family}', 40000, '{2 BHK}');
insert into public.crm_client_requirements (client_id, occupants, budget_max, flat_types) values ('${K1}', '{Couple}', 35000, '{2 BHK}');
`;

let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};

async function as(db, who, sql) {
  await db.exec(`
    reset role;
    select set_config('test.uid', '${who.uid ?? ""}', false),
           set_config('test.email', '${who.email ?? ""}', false),
           set_config('test.staff', '${who.staff ? "on" : ""}', false),
           set_config('test.super', '${who.super ? "on" : ""}', false),
           set_config('test.scopes', '${(who.scopes ?? []).join(",")}', false);
    set role ${who.role ?? "authenticated"};
  `);
  try {
    const res = await db.query(sql);
    return { rows: res.rows, error: null };
  } catch (e) {
    return { rows: null, error: e };
  } finally {
    await db.exec("reset role");
  }
}
const denied = (r) => r.error?.code === "42501";
const rlsDenied = (r) => /row-level security/i.test(r.error?.message || "");
const ids = (r) => (r.rows ?? []).map((x) => x.property_id).sort().join(",");

const anon = { role: "anon" };
const o1 = { uid: O1, email: "priya@example.com" };
const o2 = { uid: O2, email: "om@example.com" };
const r2 = { uid: R2, email: "sneha@example.com" };
const staff = { uid: S, email: "agent@moveazy.co.in", staff: true };
const ops = { ...staff, scopes: ["inventory.ops", "partners.manage"] };
const broker = { uid: B, email: "broker@example.com" };

const db = new PGlite();
await db.exec(PRELUDE);
await db.exec(file("inventory_schema.sql"));
await db.exec(CRM_INVENTORY);
await db.exec(file("inventory_public_columns.sql"));
await db.exec(file("crm_property_internal.sql").replace(/public\.normalize_mobile\(phone\)/g, "phone"));
await db.exec(file("visits_schema.sql"));
await db.exec(file("poster_visit_slots.sql"));
await db.exec(file("tenants_schema.sql"));
await db.exec(file("partner_schema.sql"));
await db.exec(file("owner_schema.sql"));
await db.exec(file("owner_schema.sql"));
check(true, "owner_schema.sql applies over production's files, and re-applies over itself");
await db.exec(file("partner_schema.sql"));
check(true, "partner_schema.sql re-applies after it (the owner contact hook compiles)");
await db.exec(SEED);

console.log("\nsign-up");
check(/mobile number/.test((await as(db, r2, "select public.owner_register('Sneha')")).error?.message || ""),
  "no number on the profile: refused");
const reg1 = await as(db, o1, "select (public.owner_register(null)).status");
check(reg1.rows?.[0]?.status === "approved", "auto-approve is on: approved straight away", reg1.error?.message);
const links1 = await as(db, o1, "select property_id from public.owner_property_links order by 1");
check(ids(links1) === "MZ-OWN001",
  "their own posted-as-owner flat links itself; a CRM-sourced one and a broker listing do not", ids(links1));
await as(db, staff, "select public.owner_register('Agent')");
check((await as(db, staff, "select count(*)::int n from public.owner_property_links where owner_id = '" + S + "'")).rows?.[0]?.n === 0,
  "a staff member opening the app inherits none of the flats they uploaded");
check(denied(await as(db, staff, "select public.owner_admin_settings(false, null)")), "auto-approve needs inventory.ops");
await as(db, ops, "select public.owner_admin_settings(false, null)");
const reg2 = await as(db, o2, "select (public.owner_register('Om')).status");
check(reg2.rows?.[0]?.status === "pending", "switched off: the next owner waits", reg2.error?.message);
check((await as(db, o2, "select * from public.owner_properties()")).rows?.length === 0, "a pending owner sees no properties");
await as(db, ops, `select public.owner_admin_set_status('${O2}', 'approved')`);
await as(db, ops, "select public.owner_admin_settings(true, null)");
check((await as(db, o2, "select (public.owner_register(null)).status")).rows?.[0]?.status === "approved",
  "approval sticks when they open the app again");

console.log("\nproperties");
const p1 = await as(db, o1, "select * from public.owner_properties()");
const own1 = p1.rows?.find((r) => r.property_id === "MZ-OWN001");
check(ids(p1) === "MZ-OWN001", "Priya sees exactly her linked flat", ids(p1) || p1.error?.message);
check(own1?.visits_booked === 1 && own1?.visit_requests === 1 && own1?.likes === 1 && own1?.shortlisted === 1 && own1?.upcoming_visits === 1,
  "with its interest counted: a booking, a request, a like, a MovEazy shortlist", JSON.stringify(own1));
check(ids(await as(db, o2, "select * from public.owner_properties()")) === "MZ-O2FLAT", "Om sees only his");
check(!(await as(db, o1, `select public.owner_update_property('MZ-OWN001', '{"rent": 34000, "area_sqft": 1200}')`)).error,
  "Priya edits her own flat");
check(denied(await as(db, o1, `select public.owner_update_property('MZ-O2FLAT', '{"rent": 1}')`)), "but not Om's");
check((await as(db, o1, `select public.owner_update_property('MZ-OWN001', '{"status": "sold"}')`)).error?.code === "22023",
  "and only to the three statuses the app offers");
check(denied(await as(db, o1, "select public.owner_admin_link_property('MZ-CRM010', '" + O1 + "')")), "linking a flat is an ops action");
await as(db, ops, `select public.owner_admin_link_property('mz-crm010', '${O1}')`);
check(ids(await as(db, o1, "select * from public.owner_properties()")) === "MZ-CRM010,MZ-OWN001",
  "once the team links a CRM upload, it is hers");
await as(db, o1, `insert into public.inventory (property_id, posted_by, poster_id, area, rent, status, source)
                  values ('MZ-OWN003', 'owner', '${O1}', 'Bellandur', 22000, 'paused', 'owner_app')`);
check(!(await as(db, o1, "select public.owner_claim_property('MZ-OWN003')")).error, "a flat added in the app is claimed");
check(denied(await as(db, o2, "select public.owner_claim_property('MZ-OWN003')")), "nobody else can claim it");

console.log("\ntenants and ratings");
const t1 = await as(db, o1, `insert into public.tenants (property_id, name, phone, occupation, company, move_in_date, status)
                             values ('MZ-OWN001', 'Rahul Mehta', '9876543210', 'Engineer', 'Google', '2025-01-15', 'active') returning id`);
check(t1.rows?.length === 1, "Priya adds a tenant to her flat", t1.error?.message);
check(!(await as(db, o1, "insert into public.tenants (property_id, name, status) values ('MZ-CRM010', 'Sneha Iyer', 'active')")).error,
  "and to the flat the team linked to her (not her upload)");
check(rlsDenied(await as(db, o1, "insert into public.tenants (property_id, name) values ('MZ-O2FLAT', 'Intruder')")),
  "but not to Om's flat — before this, any account could file a tenant on any property");
check((await as(db, o2, "select * from public.tenants")).rows?.length === 0, "Om cannot read Priya's tenants");
check((await as(db, staff, "select * from public.tenants")).rows?.length === 2, "staff can (a repair visit needs the number)");
const tid = t1.rows?.[0]?.id;
check(!(await as(db, o1, `insert into public.owner_tenant_ratings (tenant_id, stars, comment) values ('${tid}', 5, 'Great')`)).error,
  "Priya rates her tenant");
check(rlsDenied(await as(db, o2, `insert into public.owner_tenant_ratings (tenant_id, stars) values ('${tid}', 1)`)),
  "Om cannot rate Priya's tenant");
check((await as(db, o2, "select * from public.owner_tenant_ratings")).rows?.length === 0, "nor read her rating");

console.log("\nfind a tenant: interested renters");
const cand = await as(db, o1, "select * from public.owner_property_candidates('MZ-OWN001')");
const names = (cand.rows ?? []).map((c) => `${c.display_name}:${c.best}`).join(", ");
check(names === "Rahul M.:visit_booked, MovEazy renter:visit_requested, Kiran R.:shortlisted",
  "booked first, then asked, then shortlisted by MovEazy — first name and initial only", names || cand.error?.message);
const rahul = cand.rows?.[0];
check(rahul?.occupants?.[0] === "Family" && Number(rahul?.budget_max) === 40000 && rahul?.next_visit,
  "with what they are looking for and when they are coming", JSON.stringify(rahul));
const kiran = cand.rows?.find((c) => c.best === "shortlisted");
check(kiran?.occupants?.[0] === "Couple", "a CRM client with no account carries the CRM requirement");
const leaked = Object.keys(rahul ?? {}).filter((k) => /phone|email|user_id|client_id/.test(k));
const values = JSON.stringify(cand.rows ?? []);
check(leaked.length === 0 && !/98765|9123400000|@example|b1111111|e1111111/.test(values),
  "no phone, email or account id anywhere in the answer", leaked.join(",") || values.slice(0, 120));
check(/^[0-9a-f]{32}$/.test(rahul?.key || ""), "people are told apart by an opaque hash");
check((await as(db, o2, "select * from public.owner_property_candidates('MZ-OWN001')")).rows?.length === 0,
  "Om asking about Priya's flat gets nothing");
check(denied(await as(db, anon, "select * from public.owner_property_candidates('MZ-OWN001')")), "anon cannot ask at all");
const slotLinked = await as(db, o1, "insert into public.property_visit_slots (property_id, slot_at) values ('MZ-CRM010', now() + interval '3 days') returning id");
check(slotLinked.rows?.length === 1, "Priya sets visit times on the flat linked to her", slotLinked.error?.message);
check(rlsDenied(await as(db, o2, "insert into public.property_visit_slots (property_id, slot_at) values ('MZ-CRM010', now() + interval '4 days')")),
  "Om cannot");

console.log("\nincrease rent: the area guide");
const guide = (await as(db, o1, "select public.owner_area_rent('MZ-OWN001') g")).rows?.[0]?.g;
check(guide?.scope === "HSR Layout" && guide?.count === 4 && guide?.low === 33000 && guide?.median === 35000 && guide?.high === 37000,
  "2 BHKs in and inside HSR (live and rented, not paused, not 3 BHK, not itself): ₹33k–₹37k, median ₹35k", JSON.stringify(guide));
const thin = (await as(db, o2, "select public.owner_area_rent('MZ-O2FLAT') g")).rows?.[0]?.g;
check(thin?.scope === "Bengaluru", "too few nearby: widened to the city, and says so", JSON.stringify(thin));
check((await as(db, o2, "select public.owner_area_rent('MZ-OWN001') g")).rows?.[0]?.g === null, "Om cannot price Priya's flat");

console.log("\nrepairs, services and the designer call");
const rep = await as(db, o1, `select public.owner_create_request('{"kind":"repair","category":"plumbing","property_id":"MZ-OWN001","description":"Kitchen tap leaking","photos":["${O1}/requests/tap.jpg"]}') id`);
check(Boolean(rep.rows?.[0]?.id), "a repair on her own flat", rep.error?.message);
check(denied(await as(db, o1, `select public.owner_create_request('{"kind":"repair","property_id":"MZ-O2FLAT"}')`)), "not on Om's");
check((await as(db, o1, `select public.owner_create_request('{"kind":"repair","property_id":"MZ-OWN001","photos":["${O2}/requests/x.jpg"]}')`)).error?.code === "22023",
  "a photo path outside her own folder is refused");
check((await as(db, o1, `select public.owner_create_request('{"kind":"service","service_id":"nope","property_id":"MZ-OWN001"}')`)).error?.code === "22023",
  "an unknown service is refused");
const svc = await as(db, o1, `select public.owner_create_request('{"kind":"service","service_id":"ac-service","property_id":"MZ-OWN001","preferred_slot":"morning"}') id`);
const dc = await as(db, o1, `select public.owner_create_request('{"kind":"designer_call"}') id`);
check(Boolean(svc.rows?.[0]?.id) && Boolean(dc.rows?.[0]?.id), "a booked service, and a designer call", svc.error?.message || dc.error?.message);
const list1 = (await as(db, o1, "select * from public.owner_requests_list()")).rows ?? [];
const dcRow = list1.find((r) => r.kind === "designer_call");
check(dcRow?.property_ids?.length === 3, "the designer call covers her whole portfolio by default", JSON.stringify(dcRow?.property_ids));
check(list1.find((r) => r.kind === "service")?.title === "AC Service", "a service takes the catalogue's name");
const inbox = await as(db, { ...staff, super: true }, "select count(*)::int n from public.crm_notifications where type = 'owner_request'");
check(inbox.rows?.[0]?.n === 3, "each request lands in the CRM inbox", inbox.error?.message);
check((await as(db, o1, "select * from public.owner_requests")).rows?.length === 0, "the table itself gives an owner nothing");
check(denied(await as(db, anon, "select * from public.owner_requests")), "anon: refused");

const rid = rep.rows?.[0]?.id;
const sid = svc.rows?.[0]?.id;
check(denied(await as(db, staff, `select public.ops_update_request('${rid}', '{"status":"in_progress"}')`)),
  "working a request needs inventory.ops");
await as(db, ops, `select public.ops_update_request('${rid}', '{"quote_amount":"3500","vendor_name":"Ravi Plumbing","internal_note":"vendor charges us 2800","message":"call vendor back","message_internal":true}')`);
let mine = (await as(db, o1, "select * from public.owner_requests_list()")).rows?.find((r) => r.id === rid);
check(mine?.status === "awaiting_approval" && mine?.quote_status === "pending",
  "a ₹3,500 quote (over ₹2,000) waits for the owner", JSON.stringify({ s: mine?.status, q: mine?.quote_status }));
check(!("internal_note" in (mine ?? {})) && !("assigned_to" in (mine ?? {})) && !JSON.stringify(mine?.events).includes("2800")
  && !JSON.stringify(mine?.events).includes("call vendor back"),
  "the internal note and internal messages never reach her", JSON.stringify(mine?.events));
check(/₹3,500 is waiting/.test(JSON.stringify(mine?.events)), "the quote itself does");
check((await as(db, o2, `select public.owner_respond_quote('${rid}', true)`)).error != null, "Om cannot approve Priya's quote");
await as(db, o1, `select public.owner_respond_quote('${rid}', true)`);
mine = (await as(db, o1, "select * from public.owner_requests_list()")).rows?.find((r) => r.id === rid);
check(mine?.quote_status === "approved" && mine?.status === "in_progress", "she approves; work goes ahead", mine?.status);
await as(db, ops, `select public.ops_update_request('${sid}', '{"quote_amount":"1500","scheduled_at":"2026-10-03T11:00:00+05:30","message":"Technician Ravi will call before arriving"}')`);
const svcRow = (await as(db, o1, "select * from public.owner_requests_list()")).rows?.find((r) => r.id === sid);
check(svcRow?.quote_status === "approved" && /approved automatically/.test(JSON.stringify(svcRow?.events)),
  "a ₹1,500 quote is approved on the spot", JSON.stringify(svcRow?.events));
check(/Technician Ravi/.test(JSON.stringify(svcRow?.events)) && /Visit scheduled/.test(JSON.stringify(svcRow?.events)),
  "and a message meant for her, and the visit time, do reach her");
await as(db, ops, `select public.ops_update_request('${rid}', '{"status":"resolved","final_cost":"3500"}')`);
check((await as(db, o1, `select public.owner_cancel_request('${rid}')`)).error?.code === "22023", "a resolved request cannot be cancelled");
check(!(await as(db, o1, `select public.owner_cancel_request('${dc.rows?.[0]?.id}')`)).error, "an open one can");

console.log("\nnotifications");
const act = (await as(db, o1, "select * from public.owner_activity(30)")).rows ?? [];
check(act.some((a) => a.kind === "visit_booked" && a.who === "Rahul M." && a.property_id === "MZ-OWN001"),
  "a booked visit on her flat, by first name", JSON.stringify(act.slice(0, 2)));
check(act.some((a) => a.kind === "request_update" && /Resolved/.test(a.message)), "and the team's updates");
check(!act.some((a) => a.property_id === "MZ-O2FLAT"), "never activity on someone else's flat");
check(!JSON.stringify(act).includes("call vendor back"), "and never an internal message");

console.log("\ndocuments and catalogue");
check(!(await as(db, o1, `insert into public.owner_documents (property_id, kind, title, storage_path) values ('MZ-OWN001', 'agreement', 'Lease', '${O1}/docs/lease.pdf')`)).error,
  "Priya files a document in her own folder");
check(rlsDenied(await as(db, o1, `insert into public.owner_documents (kind, title, storage_path) values ('other', 'x', '${O2}/docs/x.pdf')`)),
  "not in someone else's");
check(rlsDenied(await as(db, o1, `insert into public.owner_documents (property_id, kind, title, storage_path) values ('MZ-O2FLAT', 'other', 'x', '${O1}/docs/y.pdf')`)),
  "nor against someone else's flat");
check((await as(db, o2, "select * from public.owner_documents")).rows?.length === 0, "Om cannot read hers");
check((await as(db, staff, "select * from public.owner_documents")).rows?.length === 0, "nor can ordinary staff");
check((await as(db, o1, "select count(*)::int n from public.owner_service_catalogue where active")).rows?.[0]?.n === 8, "an owner reads the catalogue");
check(rlsDenied(await as(db, o1, "insert into public.owner_service_catalogue (id, title) values ('hack', 'Free stuff')")), "but cannot edit it");
check(!(await as(db, ops, "update public.owner_service_catalogue set from_price = 549 where id = 'ac-service' returning id")).error, "ops can");
check(denied(await as(db, anon, "select * from public.owner_service_catalogue")), "anon: refused");

console.log("\nthe broker partner app");
await as(db, broker, "select public.partner_register('Bala', '')");
await as(db, ops, `select public.partner_admin_grant_tier('${B}', 'moveazy_inventory', 1)`);
const ownerContact = (await as(db, broker, "select name, phone from public.partner_property_contacts_for('MZ-OWN001')")).rows ?? [];
check(ownerContact.length === 1 && ownerContact[0].name === "MovEazy team" && ownerContact[0].phone !== "9876500001",
  "a Premium broker asking about an owner-app flat reaches MovEazy, never the owner", JSON.stringify(ownerContact));
const peerContact = (await as(db, broker, "select phone from public.partner_property_contacts_for('MZ-PEER01')")).rows ?? [];
check(peerContact[0]?.phone === "9000000001", "other MovEazy stock still shows its contact", JSON.stringify(peerContact));
check(!(await as(db, broker, "select property_id from public.partner_inventory()")).rows?.some((r) => r.property_id === "MZ-CRM010"),
  "an occupied owner flat (rented) is not in the broker app at all");

console.log("\nsuspension and anon");
await as(db, ops, `select public.owner_admin_set_status('${O1}', 'suspended')`);
check((await as(db, o1, "select * from public.owner_properties()")).rows?.length === 0, "a suspended owner sees nothing");
check((await as(db, o1, "select (public.owner_register(null)).status")).rows?.[0]?.status === "suspended",
  "and opening the app again does not reinstate them");
check(denied(await as(db, o1, `select public.owner_update_property('MZ-OWN001', '{"rent": 50000}')`)), "nor edit");
for (const t of ["owner_accounts", "owner_property_links", "owner_documents", "owner_tenant_ratings", "owner_request_events"]) {
  check(denied(await as(db, anon, `select * from public.${t}`)), `anon: ${t} refused`);
}
const list = (await as(db, staff, "select name, property_count, open_requests from public.owner_admin_list() order by name")).rows ?? [];
check(list.find((r) => r.name === "Priya Kumar")?.property_count === 3, "the CRM list counts an owner's flats", JSON.stringify(list));

await db.close();
console.log(`\n${passed ? "ALL CHECKS PASS" : "SOMETHING FAILED"}`);
process.exit(passed ? 0 : 1);
