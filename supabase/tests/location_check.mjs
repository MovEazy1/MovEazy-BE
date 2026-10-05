/**
 * Apply partner_location.sql (PGlite, in-process) and check what a Premium
 * partner sees and who they reach:
 *
 *   - another broker's flat: the area, never the address, landmark or map pin
 *     — until that broker approves the partner's request; the lister and
 *     staff always see it; asking twice does nothing; a no can be asked again;
 *   - only the lister (or partners.manage) decides; both sides are notified;
 *   - an owner's flat: the address, and the owner's own number — or MovEazy's
 *     visits desk once the owner switches brokers' calls off; only that owner
 *     flips the switch;
 *   - a MovEazy flat: the POC and the address, as before.
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

const O1 = "a1111111-0000-0000-0000-000000000001"; // Priya, owner
const O2 = "a2222222-0000-0000-0000-000000000002"; // Om, another owner
const A = "d1111111-0000-0000-0000-000000000006";  // Asha, the listing broker
const B = "d2222222-0000-0000-0000-000000000007";  // Bala, Premium partner asking
const C = "d3333333-0000-0000-0000-000000000008";  // Chetan, partner on no plan
const S = "c1111111-0000-0000-0000-000000000005";  // CRM staff

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
           set_config('test.super', '', false),
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
const asha = { uid: A, email: "asha@broker.in" };
const bala = { uid: B, email: "bala@broker.in" };
const chetan = { uid: C, email: "chetan@broker.in" };
const staff = { uid: S, email: "agent@moveazy.co.in", staff: true };
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
alter table public.crm_clients alter column id set default gen_random_uuid();
alter table public.crm_clients add column if not exists source text default 'app';
`);
await db.exec(file("inventory_schema.sql"));
await db.exec(CRM_INVENTORY);
await db.exec(file("inventory_public_columns.sql"));
await db.exec(file("crm_property_internal.sql").replace(/public\.normalize_mobile\(phone\)/g, "phone"));
await db.exec(file("inventory_private_read.sql"));
await db.exec(file("visits_schema.sql"));
await db.exec(file("tenants_schema.sql"));
await db.exec(file("program_settings.sql"));
await db.exec(file("partner_schema.sql"));
await db.exec(file("owner_schema.sql"));
await db.exec(file("partner_storefront.sql"));
await db.exec(file("partner_launch.sql"));
await db.exec(file("owner_buildings.sql"));
await db.exec(file("partner_location.sql"));
await db.exec(file("partner_location.sql"));
check(true, "partner_location.sql applies over the partner, owner and launch schemas, and re-applies over itself");
const kinds = (await db.query("select pg_get_constraintdef(oid) d from pg_constraint where conname = 'partner_notifications_kind_check'")).rows[0].d;
check(/building_assigned/.test(kinds) && /location_request/.test(kinds) && /sold_out_request/.test(kinds),
  "notification kinds: the new two added, every earlier one kept", kinds);

await db.exec(`
insert into auth.users (id, email) values
  ('${O1}', 'priya@example.com'), ('${O2}', 'om@example.com'), ('${A}', 'asha@broker.in'), ('${B}', 'bala@broker.in'),
  ('${C}', 'chetan@broker.in'), ('${S}', 'agent@moveazy.co.in');
insert into public.user_profiles (id, email, name, phone) values
  ('${O1}', 'priya@example.com', 'Priya Kumar', '9876500001'), ('${O2}', 'om@example.com', 'Om Das', '9876500002'),
  ('${A}', 'asha@broker.in', 'Asha', '9876500006'), ('${B}', 'bala@broker.in', 'Bala', '9876500007'),
  ('${C}', 'chetan@broker.in', 'Chetan', '9876500008');
`);
await as(db, o1, "select public.owner_register(null)");
await as(db, o2, "select public.owner_register(null)");
await as(db, asha, "select public.partner_register('Asha', 'Asha Homes')");
await as(db, bala, "select public.partner_register('Bala', 'Bala Realty')");
await as(db, chetan, "select public.partner_register('Chetan', '')");
await as(db, manager, `select public.partner_admin_grant_tier('${A}', 'moveazy_inventory', 1)`);
await as(db, manager, `select public.partner_admin_grant_tier('${B}', 'moveazy_inventory', 1)`);

// Asha's flat, shared with every MovEazy broker.
await as(db, asha, `
  insert into public.inventory (property_id, posted_by, poster_id, broker_id, poster_name, phone, area, full_address, landmark,
                                latitude, longitude, rent, status, flat_type)
  values ('MZ-ASHA01', 'broker', '${A}', '${A}', 'Asha', '9876500006', 'HSR Layout', '14, 19th Cross, Sector 3', 'Opp. BDA complex',
          12.9116, 77.6474, 32000, 'published', '2 BHK')`);
await as(db, asha, "select public.partner_set_sharing('MZ-ASHA01', 30, '[]')");
// Priya's flat, in the owner app; Om's too.
for (const [id, who] of [["MZ-PRIYA1", o1], ["MZ-OM0001", o2]]) {
  await db.exec(`insert into public.inventory (property_id, posted_by, poster_id, area, full_address, latitude, longitude, rent, status, flat_type, source)
                 values ('${id}', 'owner', '${who.uid}', 'Koramangala', 'Flat 4B, ${id} Towers', 12.93, 77.62, 40000, 'published', '3 BHK', 'owner_app')`);
  await as(db, who, `select public.owner_claim_property('${id}')`);
}
// A MovEazy flat with a tenant as its POC.
await db.exec(`
  insert into public.inventory (property_id, posted_by, area, full_address, latitude, longitude, rent, status, flat_type, poster_name, phone)
  values ('MZ-MOVE01', 'tenant', 'Bellandur', 'Prestige Lakeside, Tower 2', 12.92, 77.67, 28000, 'published', '1 BHK', 'Tara', '9876511111');
  insert into public.inventory_private (property_id, source, poc_name, poc_phone) values ('MZ-MOVE01', 'tenant', 'Tara', '9876511111');
`);

const row = async (who, id) => (await as(db, who, `select * from public.partner_inventory() where property_id = '${id}'`)).rows?.[0];
const contacts = async (who, id) => (await as(db, who, `select * from public.partner_property_contacts_for('${id}')`)).rows ?? [];

console.log("\nanother broker's flat");
const b1 = await row(bala, "MZ-ASHA01");
check(b1?.source === "broker" && b1.area === "HSR Layout", "Bala sees it, and its area", JSON.stringify(b1)?.slice(0, 120));
check(b1?.full_address === "" && b1.landmark === "" && b1.latitude === null && b1.longitude === null,
  "but not the address, landmark or map pin", JSON.stringify({ a: b1?.full_address, l: b1?.landmark, lat: b1?.latitude }));
const a1 = await row(asha, "MZ-ASHA01");
check(a1?.full_address === "14, 19th Cross, Sector 3" && a1.latitude !== null, "Asha, the lister, sees her own in full");
check((await row(staff, "MZ-ASHA01"))?.full_address === "14, 19th Cross, Sector 3", "and so does MovEazy staff");
const bc = await contacts(bala, "MZ-ASHA01");
check(bc[0]?.role === "broker" && bc[0].phone === "9876500006", "Bala can call or WhatsApp Asha, the lister", JSON.stringify(bc));

console.log("\nasking for the location");
check(denied(await as(db, chetan, "select public.partner_request_location('MZ-ASHA01', '')")), "a partner on no plan cannot ask");
check(denied(await as(db, bala, "select public.partner_request_location('MZ-MOVE01', '')")), "nor can anyone ask about a MovEazy flat (it's open already)");
check(denied(await as(db, asha, "select public.partner_request_location('MZ-ASHA01', '')")), "nor the lister about her own");
const r1 = await J(db, bala, "select public.partner_request_location('MZ-ASHA01', 'Client visiting Saturday')");
check(r1?.status === "pending", "Bala asks", JSON.stringify(r1));
check((await J(db, bala, "select public.partner_request_location('MZ-ASHA01', '')"))?.already === true, "asking again does nothing");
check((await db.query("select count(*)::int n from public.partner_location_requests")).rows[0].n === 1, "one request, not two");
const note = (await db.query(`select kind, title, link from public.partner_notifications where broker_id = '${A}' and kind = 'location_request'`)).rows;
check(note.length === 1 && /Bala \(Bala Realty\)/.test(note[0].title) && note[0].link === "/property/MZ-ASHA01",
  "Asha is notified, with who asked", JSON.stringify(note));
check((await row(bala, "MZ-ASHA01"))?.full_address === "", "still hidden while it's pending");
const mineA = await J(db, asha, "select public.partner_location_requests_mine()");
const inc = mineA?.incoming?.[0];
check(inc?.status === "pending" && inc.name === "Bala" && inc.agency === "Bala Realty" && inc.note === "Client visiting Saturday",
  "Asha's list: who asked, their agency and note", JSON.stringify(mineA));
const mineB = await J(db, bala, "select public.partner_location_requests_mine()");
check(mineB?.outgoing?.[0]?.status === "pending" && mineB.incoming.length === 0, "Bala's list: his ask, pending", JSON.stringify(mineB));
check(!!(await as(db, bala, "select * from public.partner_location_requests")).rows?.length === false, "partners read none of the table directly");

console.log("\ndeciding");
check(denied(await as(db, bala, `select public.partner_decide_location('${inc.id}', true)`)), "Bala cannot approve his own ask");
check(denied(await as(db, chetan, `select public.partner_decide_location('${inc.id}', true)`)), "nor can another partner");
const d1 = await J(db, asha, `select public.partner_decide_location('${inc.id}', false)`);
check(d1?.status === "rejected" && (await row(bala, "MZ-ASHA01"))?.full_address === "", "Asha says no: still hidden");
const told = (await db.query(`select title from public.partner_notifications where broker_id = '${B}' and kind = 'location_decided'`)).rows;
check(told.length === 1 && told[0].title === "Location not shared", "Bala is told", JSON.stringify(told));
check((await J(db, bala, "select public.partner_location_requests_mine()"))?.outgoing?.[0]?.status === "rejected", "his list says declined");
const r2 = await J(db, bala, "select public.partner_request_location('MZ-ASHA01', 'Please — serious client')");
check(r2?.status === "pending" && !r2.already, "after a no, he may ask again");
const inc2 = (await J(db, asha, "select public.partner_location_requests_mine()"))?.incoming?.find((x) => x.status === "pending");
const d2 = await J(db, asha, `select public.partner_decide_location('${inc2?.id}', true)`);
check(d2?.status === "approved", "Asha approves");
const b2 = await row(bala, "MZ-ASHA01");
check(b2?.full_address === "14, 19th Cross, Sector 3" && b2.landmark === "Opp. BDA complex" && Number(b2.latitude) === 12.9116,
  "Bala now sees the address, landmark and map pin", JSON.stringify({ a: b2?.full_address, lat: b2?.latitude }));
check((await J(db, bala, "select public.partner_request_location('MZ-ASHA01', '')"))?.already === true, "asking once approved: nothing new");
check((await J(db, asha, `select public.partner_decide_location('${inc2?.id}', false)`))?.already === true, "a decided request stays decided");
// Staff with partners.manage can decide too.
await as(db, manager, `select public.partner_admin_grant_tier('${C}', 'moveazy_inventory', 1)`);
await J(db, chetan, "select public.partner_request_location('MZ-ASHA01', '')");
const inc3 = (await J(db, asha, "select public.partner_location_requests_mine()"))?.incoming?.find((x) => x.status === "pending");
check((await J(db, manager, `select public.partner_decide_location('${inc3?.id}', true)`))?.status === "approved", "MovEazy (partners.manage) can decide too");
check(denied(await as(db, staff, `select public.partner_decide_location('${inc3?.id}', true)`)), "plain staff cannot");

console.log("\nan owner's flat");
const ob = await row(bala, "MZ-PRIYA1");
check(ob?.source === "moveazy" && ob.full_address === "Flat 4B, MZ-PRIYA1 Towers" && ob.latitude !== null, "Bala sees everything, address included");
let oc = await contacts(bala, "MZ-PRIYA1");
check(oc.length === 1 && oc[0].role === "owner" && oc[0].phone === "9876500001" && oc[0].name === "Priya Kumar",
  "and calls Priya herself", JSON.stringify(oc));
check(denied(await as(db, o2, "select public.owner_set_broker_contact('MZ-PRIYA1', false)")), "Om cannot switch Priya's calls off");
check(denied(await as(db, bala, "select public.owner_set_broker_contact('MZ-PRIYA1', false)")), "nor can a broker");
check((await J(db, o1, "select public.owner_set_broker_contact('MZ-PRIYA1', false)")) === false, "Priya switches brokers' calls off");
oc = await contacts(bala, "MZ-PRIYA1");
check(oc.length === 1 && oc[0].role === "moveazy" && oc[0].phone === "8090911024" && !oc.some((c) => c.phone === "9876500001"),
  "now Bala reaches MovEazy's visits desk, never her number", JSON.stringify(oc));
check((await contacts(bala, "MZ-OM0001"))[0]?.phone === "9876500002", "Om's flat is unaffected");
check((await as(db, o1, "select broker_contact from public.owner_property_links where property_id = 'MZ-PRIYA1'")).rows?.[0]?.broker_contact === false,
  "Priya reads her own switch");
await J(db, o1, "select public.owner_set_broker_contact('MZ-PRIYA1', true)");
check((await contacts(bala, "MZ-PRIYA1"))[0]?.phone === "9876500001", "and back on");
check((await contacts(chetan, "MZ-PRIYA1")).length === 1, "any Premium partner gets the same");

console.log("\na MovEazy flat");
const mb = await row(bala, "MZ-MOVE01");
check(mb?.full_address === "Prestige Lakeside, Tower 2" && mb.latitude !== null, "the address and pin, as before");
const mc = await contacts(bala, "MZ-MOVE01");
check(mc[0]?.phone === "9876511111" && mc[0].label === "Current tenant", "and the POC — here the tenant", JSON.stringify(mc));

console.log("\nsigned out");
check(!!(await as(db, anon, "select public.partner_request_location('MZ-ASHA01', '')")).error, "anyone signed out: refused");
check(!!(await as(db, anon, "select public.partner_location_requests_mine()")).error, "nothing to read either");
check(!!(await as(db, anon, "select public.owner_set_broker_contact('MZ-PRIYA1', false)")).error, "nor switch anything");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
