/**
 * Apply building_tenant_tracks.sql (PGlite, over stubs) and check the CRM's
 * "Add tenant" bar:
 *
 *   - only a building with the bar on (BR Homes) takes cards; one card per
 *     mobile, updated in place; a bad mobile or status is refused;
 *   - liked / disliked only once the visit is done; reasons only when
 *     disliked; a typed reason is offered everywhere after, and can be taken
 *     off the list (cards keep it);
 *   - each number is a CRM client (found by number, else new), and every save
 *     is on the client's history;
 *   - "Paid token" books the card's flats, and moving off it frees them;
 *   - CRM staff read; only client writers save; anon and tenants can't;
 *   - a follow-up day on a card; the tenants page merges the team's cards with
 *     the QR page's callers (building_tenants_board.sql); the CRM home's bar
 *     counts tenants and follow-ups due; the building's owner reads the same.
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
const SQL = read("building_tenant_tracks.sql");
const DESK = read("building_call_desk.sql");
const BOARD = read("building_tenants_board.sql");
let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};
const BR = "d0000000-0000-0000-0000-000000000001";
const OTHER = "d0000000-0000-0000-0000-000000000002";
const OWNER = "a0000000-0000-0000-0000-000000000001";
const OTHER_OWNER = "a0000000-0000-0000-0000-000000000002";
const db = new PGlite();
await db.exec(`
create role anon; create role authenticated;
create schema auth;
create table auth.users (id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
create function auth.jwt() returns jsonb language sql stable as $$ select jsonb_build_object('email', current_setting('test.email', true)) $$;
create function public.is_crm_staff() returns boolean language sql stable as $$ select current_setting('test.staff', true) = 'on' $$;
create function public.has_admin_scope(s text) returns boolean language sql stable as $$ select current_setting('test.write', true) = 'on' $$;
create table public.owner_buildings (id uuid primary key, code text, name text, owner_id uuid, status text default 'active', updated_at timestamptz default now());
insert into public.owner_buildings (id, code, name, owner_id) values ('${BR}', 'H33PSH', 'BR Homes', '${OWNER}'), ('${OTHER}', 'OTHER2', 'Other Towers', null);
create function public.building_by_code(p_code text) returns uuid language sql stable security definer as $$
  select b.id from public.owner_buildings b where b.code = upper(trim(coalesce(p_code, ''))) and b.status = 'active' $$;
create table public.owner_accounts (user_id uuid primary key, status text);
insert into public.owner_accounts values ('${OWNER}', 'approved'), ('${OTHER_OWNER}', 'approved');
create function public.is_approved_owner() returns boolean language sql stable security definer as $$
  select exists (select 1 from public.owner_accounts where user_id = auth.uid() and status = 'approved') $$;
create table public.inventory (property_id text primary key, building_id uuid, unit_no text default '', unit_order int);
insert into public.inventory values ('MZ-504', '${BR}', '504', 2), ('MZ-509', '${BR}', '509', 3), ('MZ-X', '${OTHER}', '101', 1);
create table public.owner_building_bookings (property_id text primary key, building_id uuid, booked_by text default '', booked_at timestamptz default now());
insert into public.owner_building_bookings values ('MZ-509', '${BR}', 'owner');
create table public.crm_clients (id uuid primary key default gen_random_uuid(), name text default '', phone text default '', source text default 'app',
  created_at timestamptz default now());
insert into public.crm_clients (name, phone) values ('Known Client', '+91 98450 11111');
create table public.crm_activities (id uuid primary key default gen_random_uuid(), client_id uuid not null references public.crm_clients(id),
  actor_email text default '', type text, body text, meta jsonb, created_at timestamptz default now());
`);
await db.exec(fn(read("lead_intake.sql"), "normalize_mobile"));
await db.exec(DESK);
await db.exec(SQL);
await db.exec(SQL);
await db.exec(BOARD);
await db.exec(BOARD);
check(true, "building_tenant_tracks.sql applies, and re-applies over itself");

async function as(who, sql, params = []) {
  await db.exec(`reset role; select set_config('test.uid', '${who.uid ?? ""}', false), set_config('test.staff', '${who.staff ? "on" : ""}', false), set_config('test.write', '${who.write ? "on" : ""}', false),
    set_config('test.email', '${who.email ?? ""}', false); set role ${who.role ?? "authenticated"};`);
  try { return { rows: (await db.query(sql, params)).rows, error: null }; }
  catch (e) { return { rows: null, error: e }; }
  finally { await db.exec("reset role"); }
}
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const q1 = async (sql) => Object.values((await db.query(sql)).rows[0] ?? {})[0];
const agent = { staff: true, write: true, email: "agent@moveazy.co.in" }, viewer = { staff: true }, anon = { role: "anon" }, tenant = {};
const save = (b, p, who = agent) => as(who, `select public.crm_tenant_track_save('${b}', $1::jsonb)`, [JSON.stringify(p)]);
const list = async (who = viewer) => one(await as(who, `select public.crm_tenant_tracks('${BR}')`));

console.log("\nthe bar");
check(await q1(`select tenant_tracker from public.owner_buildings where id = '${BR}'`) === true, "on for BR Homes");
check(await q1(`select tenant_tracker from public.owner_buildings where id = '${OTHER}'`) === false, "off elsewhere");
let r = await save(OTHER, { phone: "9876543210" });
check(Boolean(r.error), "a building without the bar takes no cards");
check((await list()).enabled === true, "the CRM reads it's on");

console.log("\ncards");
r = await save(BR, { phone: "+91 98765 43210", name: "Ravi", property_ids: ["MZ-504", "MZ-X"], note: "Wants parking", visit: "pending", liked: "liked", reasons: ["size_small"] });
let c = one(r);
check(r.error == null && c.phone === "9876543210" && c.visit === "pending", "a new card", r.error?.message);
check(c.liked === "" && c.liked_status === "" && c.reasons.length === 0, "nothing liked or disliked before the visit");
check(JSON.stringify(c.property_ids) === '["MZ-504"]' && JSON.stringify(c.flats) === '["504"]', "only this building's flats", JSON.stringify(c.flats));
const firstId = c.id;
r = await save(BR, { phone: "9876543210", visit: "done", liked: "liked", liked_status: "negotiate", reasons: ["size_small"], property_ids: ["MZ-504"] });
c = one(r);
check(c.id === firstId && c.name === "Ravi" && c.liked === "liked" && c.liked_status === "negotiate" && c.reasons.length === 0,
  "the same number updates the card; no reasons while liked; the name stays", JSON.stringify(c));
for (const [p, why] of [[{ phone: "12345" }, "a bad mobile"], [{ phone: "9876543210", visit: "maybe" }, "an unknown visit"],
  [{ phone: "9876543210", visit: "done", liked: "loved" }, "an unknown liking"], [{ phone: "9876543210", visit: "done", liked: "liked", liked_status: "sold" }, "an unknown status"]])
  check(Boolean((await save(BR, p)).error), `refused: ${why}`);

console.log("\nreasons");
r = await save(BR, { phone: "9845011111", name: "Asha", visit: "done", liked: "disliked", liked_status: "paid_token",
  reasons: ["ventilation", "  No covered parking  ", "office_distance", "x"] });
c = one(r);
check(r.error == null && c.liked_status === "" && JSON.stringify([...c.reasons].sort()) === JSON.stringify(["No covered parking", "office_distance", "ventilation"]),
  "several reasons; a typed one kept; nothing liked-only", JSON.stringify(c.reasons));
let L = await list();
check(L.reasons.length === 1 && L.reasons[0].label === "No covered parking", "the typed reason is offered from now on");
await save(BR, { phone: "9811100000", visit: "done", liked: "disliked", reasons: ["no covered parking"] });
check((await list()).reasons.length === 1, "the same reason typed again isn't added twice");
r = await as({ staff: true }, `select public.crm_tenant_reason_remove('${L.reasons[0].id}')`);
check(Boolean(r.error), "staff without write can't remove one");
await as(agent, `select public.crm_tenant_reason_remove('${L.reasons[0].id}')`);
L = await list();
check(L.reasons.length === 0 && L.tracks.find((t) => t.phone === "9845011111").reasons.includes("No covered parking"), "removed from the list; the card keeps it");

console.log("\nCRM clients");
check(c.client_id === await q1(`select id::text from public.crm_clients where name = 'Known Client'`), "a known number joins its existing client");
const ravi = (await list()).tracks.find((t) => t.phone === "9876543210");
check(await q1(`select phone from public.crm_clients where id = '${ravi.client_id}'`) === "9876543210", "a new number is a new client");
check(await q1(`select count(*)::int from public.crm_activities where client_id = '${ravi.client_id}'`) === 2, "every save on the client's history");
const last = await q1(`select body from public.crm_activities where client_id = '${ravi.client_id}' order by created_at desc limit 1`);
check(/BR Homes · Visit done · Liked · Negotiating on rent · flats 504/.test(last), "saying what changed", last);
check(await q1(`select actor_email from public.crm_activities limit 1`) === "agent@moveazy.co.in", "and who");

console.log("\npaid token");
await save(BR, { phone: "9876543210", visit: "done", liked: "liked", liked_status: "paid_token", property_ids: ["MZ-504", "MZ-509"] });
check(await q1(`select booked_by from public.owner_building_bookings where property_id = 'MZ-504'`) === `tenant_track:${firstId}`, "the card's flat is booked");
check(await q1(`select booked_by from public.owner_building_bookings where property_id = 'MZ-509'`) === "owner", "an already booked flat stays as it was");
await save(BR, { phone: "9876543210", visit: "done", liked: "liked", liked_status: "will_pay_token", property_ids: ["MZ-504", "MZ-509"] });
check(await q1(`select count(*)::int from public.owner_building_bookings where property_id = 'MZ-504'`) === 0, "off paid token: freed");
check(await q1(`select count(*)::int from public.owner_building_bookings where property_id = 'MZ-509'`) === 1, "but never someone else's booking");

console.log("\nwho");
check(Boolean((await save(BR, { phone: "9811122222" }, viewer)).error), "staff without client write can't save");
check(Boolean((await as(anon, `select public.crm_tenant_tracks('${BR}')`)).error), "anon can't read");
check(Boolean((await as(tenant, `select public.crm_tenant_tracks('${BR}')`)).error), "a tenant can't either");
check(Boolean((await as(anon, "select * from public.building_tenant_tracks")).error), "the table itself is closed");

console.log("\nfollow-up and the tenants page");
r = await save(BR, { phone: "9876543210", visit: "done", liked: "liked", liked_status: "will_pay_token", property_ids: ["MZ-504"], follow_up_on: "2000-01-01" });
check(one(r).follow_up_on === "2000-01-01", "a follow-up day on the card", JSON.stringify(one(r)?.follow_up_on));
r = await save(BR, { phone: "9811100000", visit: "done", liked: "disliked", reasons: ["location"], follow_up_on: "soon" });
check(one(r).follow_up_on == null, "a bad day is no day");
await as(anon, `select public.building_call_desk('H33PSH', 'browser-q1', '9822200000', 'From QR', 'contacts')`);
await as(anon, `select public.building_call_desk('H33PSH', 'browser-q1', '9822200000', 'From QR', 'call', 'caretaker')`);
await as(anon, `select public.building_call_desk('H33PSH', 'browser-q1', '9822200000', 'From QR', 'feedback', '', 'call_not_picked')`);
await as(anon, `select public.building_call_desk('H33PSH', 'browser-q2', '9876543210', '', 'contacts')`);
await as(anon, `select public.building_call_desk('OTHER2', 'browser-q3', '9833300000', 'Elsewhere', 'contacts')`);
r = await as(viewer, `select public.crm_building_tenants('${BR}')`);
const board = one(r);
const byPhone = Object.fromEntries((board?.tenants ?? []).map((t) => [t.phone, t]));
check(r.error == null && board.building.name === "BR Homes" && board.building.enabled === true && board.flats.length === 2, "the CRM's tenants page", r.error?.message);
check(Object.keys(byPhone).length === 4 && !byPhone["9833300000"], "the team's cards and the QR's callers, this building only", Object.keys(byPhone).join(","));
const q = byPhone["9822200000"];
check(q.track == null && q.name === "From QR" && q.qr.asked === 1 && JSON.stringify(q.qr.called) === '["caretaker"]' && q.qr.feedback[0].kind === "call_not_picked",
  "a QR caller: no card yet, what they did", JSON.stringify(q));
const both = byPhone["9876543210"];
check(both.track?.liked_status === "will_pay_token" && both.qr?.asked === 1 && both.name === "Ravi", "a tenant in both: one row, the card and the QR", JSON.stringify(both));
r = await as(viewer, "select public.crm_tracked_buildings()");
const bars = one(r);
check(bars.length === 1 && bars[0].name === "BR Homes" && bars[0].tenants === 4 && bars[0].due === 1, "the home bar: BR Homes, 4 tenants, 1 follow-up due", JSON.stringify(bars));
r = await as({ uid: OWNER }, `select public.owner_building_tenants('${BR}')`);
check(r.error == null && one(r)?.tenants?.length === 4, "the building's owner sees the same list", r.error?.message);
check(one(await as({ uid: OTHER_OWNER }, `select public.owner_building_tenants('${BR}')`)) == null, "another owner sees nothing");
check(Boolean((await as(anon, `select public.crm_building_tenants('${BR}')`)).error), "anon can't read the page");
check(Boolean((await as(tenant, "select public.crm_tracked_buildings()")).error), "nor a tenant the bar");
check(Boolean((await as(viewer, `select public.building_tenants_board('${BR}')`)).error), "the board itself isn't callable");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
