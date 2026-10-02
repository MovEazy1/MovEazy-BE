/**
 * Apply owner_buildings.sql over the owner, partner and launch schemas
 * (PGlite, in-process) and check the property QR's rules:
 *
 *   - only an approved owner makes a building, gets a printable code, and puts
 *     only their own flats in it, floor by floor;
 *   - the public page (anon) shows the building and its flats — never the
 *     owner, never an address, never a paused building;
 *   - a scan counts once per visitor a day; the owner's own don't count;
 *   - a visit request needs a name and a real mobile; the same number asking
 *     again updates the open request; the assigned broker is notified and gets
 *     the tenant, and MovEazy's CRM gets the number once;
 *   - the broker and staff move a visit along; the owner can say how it went
 *     but not change the time, and never sees the renter's number;
 *   - 'booked' books the flat and takes it off the available list;
 *   - the owner's funnel counts scans → numbers → visits → done → booked;
 *   - the tables give nobody anything directly.
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

const O1 = "a1111111-0000-0000-0000-000000000001"; // Priya, the owner
const O2 = "a2222222-0000-0000-0000-000000000002"; // another owner
const B = "d1111111-0000-0000-0000-000000000006";  // the partner MovEazy assigns
const B2 = "d2222222-0000-0000-0000-000000000007"; // another partner
const S = "c1111111-0000-0000-0000-000000000005";  // CRM staff
const R1 = "f1111111-0000-0000-0000-000000000011"; // Ravi, renter — signed in, no mobile on his profile yet
const R2 = "f2222222-0000-0000-0000-000000000012"; // Meera, renter — already a phone-only CRM lead

const ownerCheck = readFileSync(new URL("./owner_check.mjs", import.meta.url), "utf8");
const PRELUDE = ownerCheck.split("const PRELUDE = `")[1].split("`;")[0];
const CRM_INVENTORY = ownerCheck.split("const CRM_INVENTORY = `")[1].split("`;")[0];

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
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const J = async (db, who, sql) => one(await as(db, who, sql));

const anon = { role: "anon" };
const o1 = { uid: O1, email: "priya@example.com" };
const o2 = { uid: O2, email: "om@example.com" };
const broker = { uid: B, email: "bala@broker.in" };
const broker2 = { uid: B2, email: "chetan@broker.in" };
const staff = { uid: S, email: "agent@moveazy.co.in", staff: true };
const ravi = { uid: R1, email: "ravi@example.com" };
const meera = { uid: R2, email: "meera@example.com" };
const manager = { ...staff, scopes: ["partners.manage"] };

const db = new PGlite();
await db.exec(PRELUDE);
await db.exec(`
create or replace function public.normalize_mobile(raw text) returns text language plpgsql immutable as $$
declare digits text := regexp_replace(coalesce(raw, ''), '\\D', '', 'g');
begin
  digits := case when length(digits) > 10 and left(digits, 2) = '91' then right(digits, 10) else digits end;
  return case when digits ~ '^[6-9][0-9]{9}$' then digits else '' end;
end $$;
-- crm_schema.sql's crm_clients, as much of it as this needs.
alter table public.crm_clients alter column id set default gen_random_uuid();
alter table public.crm_clients add column if not exists source text default 'app';
`);
await db.exec(file("inventory_schema.sql"));
await db.exec(CRM_INVENTORY);
await db.exec(file("inventory_public_columns.sql"));
await db.exec(file("crm_property_internal.sql").replace(/public\.normalize_mobile\(phone\)/g, "phone"));
await db.exec(file("visits_schema.sql"));
await db.exec(file("tenants_schema.sql"));
await db.exec(file("program_settings.sql"));
await db.exec(file("partner_schema.sql"));
await db.exec(file("owner_schema.sql"));
await db.exec(file("partner_storefront.sql"));
await db.exec(file("partner_launch.sql"));
await db.exec(file("owner_buildings.sql"));
await db.exec(file("owner_buildings.sql"));
check(true, "owner_buildings.sql applies over the owner, partner and launch schemas, and re-applies over itself");

await db.exec(`
insert into auth.users (id, email) values
  ('${O1}', 'priya@example.com'), ('${O2}', 'om@example.com'), ('${B}', 'bala@broker.in'), ('${B2}', 'chetan@broker.in'),
  ('${S}', 'agent@moveazy.co.in'), ('${R1}', 'ravi@example.com'), ('${R2}', 'meera@example.com');
insert into public.user_profiles (id, email, name, phone) values
  ('${R1}', 'ravi@example.com', 'Ravi Kumar', ''), ('${R2}', 'meera@example.com', 'Meera Nair', '9876544444'),
  ('${O1}', 'priya@example.com', 'Priya Kumar', '9876500001'), ('${O2}', 'om@example.com', 'Om Das', '9876500002'),
  ('${B}', 'bala@broker.in', 'Bala', '9876500006'), ('${B2}', 'chetan@broker.in', 'Chetan', '9876500007');
`);
await as(db, o1, "select public.owner_register(null)");
await as(db, o2, "select public.owner_register(null)");
await as(db, broker, "select public.partner_register('Bala', 'Bala Homes')");
await as(db, broker2, "select public.partner_register('Chetan', '')");
for (const [id, floor, rent, status, owner] of [["MZ-F001", 0, 22000, "paused", O1], ["MZ-F101", 1, 30000, "published", O1],
  ["MZ-F102", 1, 31000, "paused", O1], ["MZ-F201", 2, 45000, "rented", O1], ["MZ-OM001", 1, 15000, "published", O2]]) {
  await db.exec(`insert into public.inventory (property_id, posted_by, poster_id, area, full_address, rent, status, flat_type, source)
                 values ('${id}', 'owner', '${owner}', 'HSR Layout', 'Flat ${id}, Secret Towers', ${rent}, '${status}', '2 BHK', 'owner_app')`);
  await as(db, owner === O1 ? o1 : o2, `select public.owner_claim_property('${id}')`);
  void floor;
}

console.log("\nthe owner makes a building");
check(denied(await as(db, broker, `select public.owner_building_save('{"name":"Nope"}')`)), "a broker cannot");
check((await as(db, o1, `select public.owner_building_save('{"name":" "}')`)).error?.code === "22023", "a name is required");
const made = await J(db, o1, `select public.owner_building_save('{"name":"Sunrise Residency","area":"HSR Layout","landmark":"Near Agara Lake",
  "full_address":"12, 27th Main, Sector 2","total_floors":4,"amenities":["Lift","Power backup"],
  "photos":["https://x.supabase.co/a.jpg","javascript:alert(1)"]}')`);
check(/^[A-HJ-NP-Z2-9]{6}$/.test(made?.code || "") && made?.id, "she gets a building with a six-character code", JSON.stringify(made));
const bid = made?.id;
const code = made?.code;
for (const [id, floor] of [["MZ-F001", 0], ["MZ-F101", 1], ["MZ-F102", 1], ["MZ-F201", 2]]) {
  const r = await as(db, o1, `select public.owner_building_set_flat('${id}', '${bid}', ${floor})`);
  if (r.error) check(false, `put ${id} in`, r.error.message);
}
check(denied(await as(db, o1, `select public.owner_building_set_flat('MZ-OM001', '${bid}', 1)`)), "she cannot put someone else's flat in it");
const omB = await J(db, o2, `select public.owner_building_save('{"name":"Om Villa"}')`);
check(denied(await as(db, o1, `select public.owner_building_set_flat('MZ-F001', '${omB?.id}', 0)`)), "nor her flat in someone else's building");
check(denied(await as(db, o1, `select public.owner_building_save('{"id":"${omB?.id}","name":"Mine now"}')`)), "nor edit theirs");
const list = await J(db, o1, "select public.owner_buildings_list()");
check(list?.length === 1 && list[0].flats === 4 && list[0].photos?.length === 1, "her list: one building, four flats, only the https photo", JSON.stringify(list));

const props = (await as(db, o1, "select property_id, building_name, floor_number from public.owner_properties()")).rows ?? [];
const f201 = props.find((r) => r.property_id === "MZ-F201");
check(f201?.building_name === "Sunrise Residency" && f201?.floor_number === 2,
  "her flat list says which building and floor each flat is on", JSON.stringify(props));

console.log("\nthe public page");
const page = await J(db, anon, `select public.building_page('${code.toLowerCase()}')`);
check(page?.name === "Sunrise Residency" && page.flats?.length === 4, "anon opens it by code: the building and its four flats", JSON.stringify(page)?.slice(0, 200));
check(page?.flats?.map((f) => f.floor_number).join(",") === "0,1,1,2", "floor by floor", page?.flats?.map((f) => f.floor_number).join(","));
check(page?.flats?.find((f) => f.property_id === "MZ-F201")?.available === false, "the rented flat shows as taken");
const text = JSON.stringify(page);
check(!text.includes("Secret") && !text.includes("27th Main") && !text.includes("9876500001") && !text.includes("Priya"),
  "no address, no owner name or number");
check(page?.has_partner === false, "no partner assigned yet");
check((await J(db, anon, "select public.building_page('ZZZZZZ')")) === null, "an unknown code: nothing");

console.log("\nscans");
await as(db, anon, `select public.building_view('${code}', 'visitor-0001', 'qr')`);
await as(db, anon, `select public.building_view('${code}', 'visitor-0001', 'qr')`);
await as(db, anon, `select public.building_view('${code}', 'visitor-0002', 'link')`);
await as(db, o1, `select public.building_view('${code}', 'visitor-own', 'qr')`);
const st0 = (await J(db, o1, "select public.owner_buildings_list()"))?.[0]?.stats;
check(st0?.scans === 1 && st0?.visitors === 2, "one QR scan, two visitors; a second scan that day and her own don't count", JSON.stringify(st0));

console.log("\nvisit requests");
check(denied(await as(db, anon, `select public.building_request_visit('${code}', 'visitor-0001', 'Ravi Kumar', '9876533333', '{MZ-F101}', null, '')`)),
  "not signed in: asked to sign in with Google first");
check(!!(await as(db, ravi, `select public.building_request_visit('${code}', 'visitor-0001', 'Ravi', '12345', '{}', null, '')`)).error,
  "a bad number: refused");
check(!!(await as(db, ravi, `select public.building_request_visit('${code}', 'visitor-0001', '', '9876533333', '{}', null, '')`)).error,
  "no name: refused");
check(!!(await as(db, ravi, `select public.building_request_visit('${code}', 'visitor-0001', 'Ravi', '9876533333', '{}', now() - interval '2 days', '')`)).error,
  "a time in the past: refused");
const r1 = await J(db, ravi, `select public.building_request_visit('${code}', 'visitor-0001', 'Ravi Kumar', '+91 98765 33333',
  '{MZ-F101,MZ-OM001}', now() + interval '2 days', 'Evening is best')`);
check(r1?.id && r1.updated === false && r1.has_partner === false, "Ravi asks to visit (before a partner is assigned)", JSON.stringify(r1));
const lead1 = (await db.query(`select * from public.owner_building_leads where id = '${r1?.id}'`)).rows[0];
check(lead1?.phone === "9876533333" && lead1.property_ids.join() === "MZ-F101", "his number is cleaned; only flats in this building are kept", JSON.stringify(lead1));
const r1b = await J(db, ravi, `select public.building_request_visit('${code}', 'visitor-0001', 'Ravi Kumar', '9876533333', '{MZ-F102}', null, '')`);
check(r1b?.id === r1?.id && r1b.updated === true, "asking again updates the open request");
const lead1b = (await db.query(`select property_ids, visit_at from public.owner_building_leads where id = '${r1?.id}'`)).rows[0];
check(lead1b?.property_ids?.sort().join() === "MZ-F101,MZ-F102" && lead1b.visit_at, "adding a flat, keeping his time", JSON.stringify(lead1b));
check(lead1?.user_id === R1, "the request is saved against his account");
const ravisClients = (await db.query(`select user_id, phone, source from public.crm_clients where user_id = '${R1}'`)).rows;
check(ravisClients.length === 1 && ravisClients[0].phone === "9876533333" && ravisClients[0].source === "building_qr",
  "he is one client in MovEazy's CRM, under his account", JSON.stringify(ravisClients));
check((await db.query(`select phone from public.user_profiles where id = '${R1}'`)).rows[0].phone === "9876533333",
  "his account keeps the number he gave (it had none)");
const ravisVisits = (await db.query(`select property_id, status from public.visit_bookings where user_id = '${R1}' order by property_id`)).rows;
check(ravisVisits.map((v) => `${v.property_id}:${v.status}`).join() === "MZ-F101:scheduled,MZ-F102:preference",
  "each flat he picked is in his own visits — a time for the first, 'call me' for the second", JSON.stringify(ravisVisits));
check(Number((await db.query("select count(*) n from public.partner_notifications")).rows[0].n) === 0, "no partner yet: nobody to notify");

console.log("\nMovEazy assigns the partner");
check(denied(await as(db, o1, `select public.crm_building_assign_broker('${bid}', '${B}')`)), "the owner cannot pick the partner");
check(denied(await as(db, broker, "select public.crm_buildings()")), "a broker cannot see the CRM view");
check((await as(db, staff, `select public.crm_building_assign_broker('${bid}', '${O2}')`)).error?.code === "22023", "only an approved partner");
{ const ar = await as(db, staff, `select public.crm_building_assign_broker('${bid}', '${B}')`); check(!ar.error, "staff assign Bala", ar.error?.message); }
const n1 = await J(db, broker, "select public.partner_notifications_list()");
check(n1?.items?.[0]?.kind === "building_assigned", "Bala is told", JSON.stringify(n1?.items?.[0]));
const bl = await J(db, broker, "select public.partner_building_leads()");
check(bl?.leads?.length === 1 && bl.leads[0].phone === "9876533333" && bl.buildings?.[0]?.full_address?.includes("27th Main"),
  "Bala sees the open request with the number, and the address to show", JSON.stringify(bl)?.slice(0, 200));
check((await J(db, broker2, "select public.partner_building_leads()"))?.leads?.length === 0, "another partner sees nothing");

await db.exec("insert into public.crm_clients (name, phone, source) values ('Meera', '9876544444', 'whatsapp')");
const r2 = await J(db, meera, `select public.building_request_visit('${code}', 'visitor-0002', 'Meera Nair', '9876544444', '{MZ-F201}', now() + interval '1 day', '')`);
const n2 = await J(db, broker, "select public.partner_notifications_list()");
check(n2?.items?.[0]?.kind === "building_visit" && n2.items[0].body.includes("9876544444") && n2.items[0].link === "/building-leads",
  "a new request reaches Bala at once, with the number", JSON.stringify(n2?.items?.[0]));
const meeraClients = (await db.query("select user_id, source from public.crm_clients where phone = '9876544444'")).rows;
check(meeraClients.length === 1 && meeraClients[0].user_id === R2 && meeraClients[0].source === "whatsapp",
  "her earlier phone-only lead becomes her account's — not a second client", JSON.stringify(meeraClients));
const t2 = (await db.query("select source, status from public.partner_tenants where phone = '9876544444'")).rows[0];
check(t2?.source === "building" && t2.status === "unverified", "and becomes his unverified tenant", JSON.stringify(t2));

console.log("\nworking a visit");
check(!(await as(db, broker, `select public.building_lead_update('${r2?.id}', '{"status":"confirmed","visit_at":"2030-01-05T11:30:00+05:30"}')`)).error,
  "Bala confirms Meera's time");
check(denied(await as(db, broker2, `select public.building_lead_update('${r2?.id}', '{"status":"visited"}')`)), "another partner cannot touch it");
check(denied(await as(db, o1, `select public.building_lead_update('${r2?.id}', '{"visit_at":"2030-01-06T11:30:00+05:30"}')`)), "the owner cannot move the time");
check(denied(await as(db, o1, `select public.building_lead_update('${r2?.id}', '{"status":"confirmed"}')`)), "nor confirm it");
check(!(await as(db, o1, `select public.building_lead_update('${r1?.id}', '{"status":"visited"}')`)).error, "but she can say Ravi visited");
check((await as(db, broker, `select public.building_lead_update('${r1?.id}', '{"status":"booked"}')`)).error?.code === "22023",
  "'booked' with two flats in mind needs the flat");
check(!(await as(db, broker, `select public.building_lead_update('${r1?.id}', '{"status":"booked","booked_property":"MZ-F101"}')`)).error,
  "Bala marks Ravi booked into MZ-F101");
const pageB = await J(db, anon, `select public.building_page('${code}')`);
check(pageB?.flats?.find((f) => f.property_id === "MZ-F101")?.available === false, "MZ-F101 is no longer available on the page");
check(!(await as(db, staff, `select public.building_lead_update('${r1?.id}', '{"status":"visited"}')`)).error
  && Number((await db.query("select count(*) n from public.owner_building_bookings where property_id = 'MZ-F101'")).rows[0].n) === 0,
  "undoing the booking frees the flat");
await as(db, broker, `select public.building_lead_update('${r1?.id}', '{"status":"booked","booked_property":"MZ-F101"}')`);
check(!(await as(db, o1, "select public.owner_building_mark_booked('MZ-F001', true)")).error, "Priya marks the ground-floor flat booked herself");
check(denied(await as(db, o2, "select public.owner_building_mark_booked('MZ-F102', true)")), "Om cannot");

console.log("\nthe owner's dashboard");
const detail = await J(db, o1, `select public.owner_building_detail('${bid}')`);
const s = detail?.stats;
check(s?.scans === 1 && s.numbers === 2 && s.scheduled === 2 && s.visited === 1 && s.booked === 2,
  "scans 1 · numbers 2 · visits asked 2 · visited 1 · booked 2", JSON.stringify(s));
check(detail?.leads?.length === 2 && !JSON.stringify(detail.leads).includes("98765") && detail.leads.some((l) => l.name === "Meera N."),
  "she sees each visit by first name and initial, never the number", JSON.stringify(detail?.leads));
check(detail?.by_day?.length === 14, "and fourteen days of scans");
check((await J(db, o2, `select public.owner_building_detail('${bid}')`)) === null, "Om sees nothing of it");

console.log("\nthe CRM");
const crm = await J(db, staff, "select public.crm_buildings()");
check(crm?.buildings?.length === 2 && crm.leads?.length === 2 && crm.partners?.length === 2
  && crm.buildings.find((x) => x.id === bid)?.owner?.phone === "9876500001",
  "staff see every building, its owner, every visit, and the partners to assign", JSON.stringify(crm)?.slice(0, 160));

console.log("\nlocked down");
check(!!(await as(db, anon, "select * from public.owner_building_leads")).error, "anon cannot read the leads table");
check(!!(await as(db, o1, "select * from public.owner_buildings")).error, "nor can an owner read the buildings table directly");
check(!!(await as(db, broker, "select * from public.owner_building_scans")).error, "nor a broker the scans");
check(denied(await as(db, anon, "select public.owner_buildings_list()")) || !!(await as(db, anon, "select public.owner_buildings_list()")).error,
  "anon cannot call the owner's functions");
check(!!(await as(db, anon, `select public.building_stats('${bid}')`)).error, "nor the internal helpers");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
