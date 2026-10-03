/**
 * Apply owner_buildings.sql (PGlite, in-process) and check instant visits:
 *
 *   - only the building's owner (or MovEazy staff) turns it on, and only with
 *     a POC name and a real mobile; a partner or another owner cannot;
 *   - the public page says it's on — never the POC;
 *   - a tenant must be signed in; they get the POC and the address back;
 *   - the visit is a lead of kind 'instant', confirmed, in the tenant's own
 *     visits (one per free flat when none were picked), a client in the CRM,
 *     and the partner is told at once;
 *   - an open scheduled request from the same tenant becomes the instant one;
 *   - the QR's counts include it, and the owner's notifications show it once;
 *   - turned off, the page stops offering it and a request is refused.
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


const made = await J(db, o1, `select public.owner_building_save('{"name":"Sunrise Residency","area":"HSR Layout","landmark":"Near Agara Lake","full_address":"12, 27th Main, Sector 2"}')`);
const bid = made?.id;
const code = made?.code;
for (const [id, floor] of [["MZ-F001", 0], ["MZ-F101", 1], ["MZ-F102", 1], ["MZ-F201", 2]]) {
  const r = await as(db, o1, `select public.owner_building_set_flat('${id}', '${bid}', ${floor})`);
  if (r.error) check(false, `put ${id} in`, r.error.message);
}
await as(db, staff, `select public.crm_building_assign_broker('${bid}', '${B}')`);

console.log("\nturning it on");
check((await J(db, anon, `select public.building_page('${code}')`))?.instant_visit === false, "off to begin with");
check(denied(await as(db, broker, `select public.building_set_instant_visit('${bid}', true, 'Raju', '9876511111')`)), "the partner cannot turn it on");
check(denied(await as(db, o2, `select public.building_set_instant_visit('${bid}', true, 'Raju', '9876511111')`)), "nor another owner");
check(!!(await as(db, anon, `select public.building_set_instant_visit('${bid}', true, 'Raju', '9876511111')`)).error, "nor anyone signed out");
check((await as(db, o1, `select public.building_set_instant_visit('${bid}', true, '', '9876511111')`)).error?.code === "22023", "a POC name is needed");
check((await as(db, o1, `select public.building_set_instant_visit('${bid}', true, 'Raju', '12345')`)).error?.code === "22023", "and a real mobile");
const on = await J(db, o1, `select public.building_set_instant_visit('${bid}', true, ' Raju (caretaker) ', '+91 98765 11111')`);
check(on?.instant_visit === true && on.poc_name === "Raju (caretaker)" && on.poc_phone === "9876511111", "Priya turns it on with Raju", JSON.stringify(on));
const page = await J(db, anon, `select public.building_page('${code}')`);
check(page?.instant_visit === true && !JSON.stringify(page).includes("9876511111") && !JSON.stringify(page).includes("Raju"),
  "the page offers it — without Raju's name or number");

console.log("\nan instant visit");
check(denied(await as(db, anon, `select public.building_instant_visit('${code}', 'visitor-0001', 'Ravi Kumar', '9876533333', '{}')`)),
  "signed out: asked to sign in with Google first");
check((await as(db, ravi, `select public.building_instant_visit('${code}', 'visitor-0001', 'Ravi', '123', '{}')`)).error?.code === "22023", "a bad number: refused");
const iv = await J(db, ravi, `select public.building_instant_visit('${code}', 'visitor-0001', 'Ravi Kumar', '98765 33333', '{}')`);
check(iv?.poc_name === "Raju (caretaker)" && iv.poc_phone === "9876511111" && iv.address?.includes("27th Main") && iv.updated === false,
  "Ravi gets Raju's name and number and the address", JSON.stringify(iv));
const lead = (await db.query(`select * from public.owner_building_leads where id = '${iv?.id}'`)).rows[0];
check(lead?.kind === "instant" && lead.status === "confirmed" && lead.user_id === R1 && lead.visit_at,
  "it's an instant, confirmed visit on his account", JSON.stringify(lead));
check(lead?.property_ids?.sort().join() === "MZ-F001,MZ-F101,MZ-F102", "no flat picked: every free flat (not the rented one)", lead?.property_ids?.join());
const visits = (await db.query(`select property_id, kind, status, slot_at from public.visit_bookings where user_id = '${R1}' order by property_id`)).rows;
check(visits.length === 3 && visits.every((v) => v.kind === "instant" && v.status === "scheduled" && v.slot_at),
  "each is in his own visits as an instant visit", JSON.stringify(visits));
const client = (await db.query(`select source, phone from public.crm_clients where user_id = '${R1}'`)).rows;
check(client.length === 1 && client[0].source === "instant_visit" && client[0].phone === "9876533333", "he's a client in the CRM", JSON.stringify(client));
const note = (await J(db, broker, "select public.partner_notifications_list()"))?.items?.[0];
check(note?.kind === "building_visit" && note.title.startsWith("Instant visit") && note.body.includes("9876533333"),
  "Bala, the partner, is told at once", JSON.stringify(note));
check(Number((await db.query("select count(*) n from public.partner_tenants where phone = '9876533333'")).rows[0].n) === 1, "and gets him as a tenant");

console.log("\nan open request becomes instant");
const sched = await J(db, meera, `select public.building_request_visit('${code}', 'visitor-0002', 'Meera Nair', '9876544444', '{MZ-F101}', now() + interval '2 days', '')`);
const iv2 = await J(db, meera, `select public.building_instant_visit('${code}', 'visitor-0002', 'Meera Nair', '9876544444', '{MZ-F102,MZ-OM001}')`);
check(iv2?.id === sched?.id && iv2.updated === true, "Meera's scheduled request becomes her instant visit — one lead, not two", JSON.stringify(iv2));
const l2 = (await db.query(`select kind, property_ids from public.owner_building_leads where id = '${sched?.id}'`)).rows[0];
check(l2?.kind === "instant" && l2.property_ids.sort().join() === "MZ-F101,MZ-F102", "with the flats she picked (only this building's)", JSON.stringify(l2));
const mv = (await db.query(`select property_id, kind from public.visit_bookings where user_id = '${R2}' order by property_id`)).rows;
check(mv.map((v) => `${v.property_id}:${v.kind}`).join() === "MZ-F101:instant,MZ-F102:instant", "her visits: both flats, now instant", JSON.stringify(mv));

console.log("\ncounts and the owner");
const detail = await J(db, o1, `select public.owner_building_detail('${bid}')`);
check(detail?.stats?.instant === 2 && detail.stats.scheduled === 2 && detail.stats.numbers === 2,
  "the QR's counts: two instant visits, both counted as visits", JSON.stringify(detail?.stats));
check(detail?.instant_visit === true && detail.instant_poc_name === "Raju (caretaker)" && detail.leads?.every((l) => l.kind === "instant"),
  "her building shows the setting and marks each visit instant");
check(!JSON.stringify(detail?.leads).includes("98765"), "still no tenant numbers for the owner");
const act = (await as(db, o1, "select kind, building_id, message, who from public.owner_activity(30)")).rows ?? [];
const inst = act.filter((a) => a.kind === "instant_visit");
check(inst.length === 2 && inst.every((a) => a.building_id === bid && a.message === "Sunrise Residency") && inst.some((a) => a.who === "Ravi K."),
  "her notifications: two instant visits, named by first name and initial", JSON.stringify(act));
check(!act.some((a) => a.kind === "visit_booked" || a.kind === "visit_requested"), "— once each, not again for every flat", JSON.stringify(act.map((a) => a.kind)));
check(((await as(db, o2, "select kind from public.owner_activity(30)")).rows ?? []).length === 0, "Om hears nothing of it");

console.log("\nthe CRM and the partner");
const crm = await J(db, staff, "select public.crm_buildings()");
const cb = crm?.buildings?.find((x) => x.id === bid);
check(cb?.instant_visit === true && cb.instant_poc_phone === "9876511111" && cb.instant_updated_by === "owner",
  "staff see it's on, Raju's number, and that the owner set it", JSON.stringify(cb)?.slice(0, 200));
check(crm?.leads?.filter((l) => l.kind === "instant").length === 2, "and both visits marked instant");
check((await J(db, broker, "select public.partner_building_leads()"))?.leads?.every((l) => l.kind === "instant"), "so does the partner");
const omB = await J(db, o2, `select public.owner_building_save('{"name":"Om Villa"}')`);
check(!(await as(db, staff, `select public.building_set_instant_visit('${omB?.id}', true, 'Om', '9876500002')`)).error, "staff can set it up for an owner");

console.log("\nturning it off");
const off = await J(db, o1, `select public.building_set_instant_visit('${bid}', false)`);
check(off?.instant_visit === false && off.poc_phone === "9876511111", "off — Raju is kept for next time", JSON.stringify(off));
check((await J(db, anon, `select public.building_page('${code}')`))?.instant_visit === false, "the page stops offering it");
check((await as(db, ravi, `select public.building_instant_visit('${code}', 'visitor-0001', 'Ravi Kumar', '9876533333', '{}')`)).error?.code === "22023",
  "and an instant visit is refused");

console.log("\nlocked down");
check(!!(await as(db, anon, "select instant_poc_phone from public.owner_buildings")).error, "nobody reads the POC from the table");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
