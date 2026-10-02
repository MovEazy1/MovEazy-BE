/**
 * Apply flat_insights.sql over the owner, partner and building schemas
 * (PGlite, in-process) and check every flat's QR numbers and feedback:
 *
 *   - a live flat's page counts each visitor once a day, QR apart from links;
 *     a paused flat and the owner's own opens don't count;
 *   - the owner's dashboard has leads (QR scans), likes and visits per flat —
 *     visits from bookings and from the building's QR requests;
 *   - the owner sees renters by first name and initial, never a number; the
 *     CRM sees full names and numbers;
 *   - only CRM staff record or remove feedback; the owner reads it, with the
 *     rent view, rating and comment;
 *   - nobody reads the tables directly.
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
const R1 = "b1111111-0000-0000-0000-000000000003"; // Rahul, renter
const R3 = "b3333333-0000-0000-0000-000000000013"; // Meera, renter who books through the building QR
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
           set_config('test.scopes', '', false);
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
const denied = (r) => r.error?.code === "42501" || /permission denied/.test(r.error?.message || "");
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const J = async (db, who, sql) => one(await as(db, who, sql));

const anon = { role: "anon" };
const o1 = { uid: O1, email: "priya@example.com" };
const o2 = { uid: O2, email: "om@example.com" };
const renter = { uid: R1, email: "rahul@example.com" };
const meera = { uid: R3, email: "meera@example.com" };
const staff = { uid: S, email: "agent@moveazy.co.in", staff: true };

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
await db.exec(file("crm_property_internal.sql"));
await db.exec(file("visits_schema.sql"));
await db.exec(file("tenants_schema.sql"));
await db.exec(file("program_settings.sql"));
await db.exec(file("partner_schema.sql"));
await db.exec(file("owner_schema.sql"));
await db.exec(file("partner_storefront.sql"));
await db.exec(file("partner_launch.sql"));
await db.exec(file("owner_buildings.sql"));
await db.exec(file("flat_insights.sql"));
await db.exec(file("flat_insights.sql"));
check(true, "flat_insights.sql applies over the owner, partner and building schemas, and re-applies over itself");

await db.exec(`
insert into auth.users (id, email) values ('${R3}', 'meera@example.com');
insert into public.user_profiles (id, email, name, phone) values ('${R3}', 'meera@example.com', 'Meera Nair', '9876544444');
insert into auth.users (id, email) values
  ('${O1}', 'priya@example.com'), ('${O2}', 'om@example.com'), ('${R1}', 'rahul@example.com'), ('${S}', 'agent@moveazy.co.in');
insert into public.user_profiles (id, email, name, phone) values
  ('${O1}', 'priya@example.com', 'Priya Kumar', '9876500001'), ('${O2}', 'om@example.com', 'Om Das', '9876500002'),
  ('${R1}', 'rahul@example.com', 'Rahul Mehta', '9876500003'), ('${S}', 'agent@moveazy.co.in', 'Agent', '9876500005');
insert into public.inventory (property_id, posted_by, poster_id, area, full_address, rent, status, flat_type, source) values
  ('MZ-LIVE1', 'owner', '${O1}', 'HSR Layout', 'x', 30000, 'published', '2 BHK', 'owner_app'),
  ('MZ-PAUSE', 'owner', '${O1}', 'HSR Layout', 'x', 25000, 'paused', '1 BHK', 'owner_app'),
  ('MZ-OMFLT', 'owner', '${O2}', 'Whitefield', 'x', 15000, 'published', '1 RK', 'owner_app');
`);
await as(db, o1, "select public.owner_register(null)");
await as(db, o2, "select public.owner_register(null)");

console.log("\ncounting");
await as(db, anon, "select public.flat_view('mz-live1', 'visitor-0001', 'qr')");
await as(db, anon, "select public.flat_view('MZ-LIVE1', 'visitor-0001', 'qr')");
await as(db, anon, "select public.flat_view('MZ-LIVE1', 'visitor-0002', 'qr')");
await as(db, anon, "select public.flat_view('MZ-LIVE1', 'visitor-0003', 'link')");
await as(db, o1, "select public.flat_view('MZ-LIVE1', 'visitor-own1', 'qr')");
await as(db, anon, "select public.flat_view('MZ-PAUSE', 'visitor-0001', 'qr')");
await as(db, anon, "select public.flat_view('MZ-NOPE', 'visitor-0001', 'qr')");
await db.exec(`
insert into public.listing_reactions (user_id, property_id, reaction) values ('${R1}', 'MZ-LIVE1', 'like');
insert into public.visit_bookings (user_id, property_id, slot_at, status) values ('${R1}', 'MZ-LIVE1', now() + interval '1 day', 'scheduled');
`);
const bld = await J(db, o1, `select public.owner_building_save('{"name":"Sunrise"}')`);
await as(db, o1, `select public.owner_building_set_flat('MZ-LIVE1', '${bld.id}', 1)`);
await as(db, meera, `select public.building_request_visit('${bld.code}', 'visitor-0009', 'Meera Nair', '9876544444', '{MZ-LIVE1}', now() + interval '2 days', '')`);

const dash = await J(db, o1, "select public.owner_rent_dashboard()");
const live = dash?.find((d) => d.property_id === "MZ-LIVE1")?.stats;
check(live?.scans === 2 && live.opens === 3, "two QR scans (one visitor twice in a day counts once), three opens; her own don't count", JSON.stringify(live));
check(live?.likes === 1 && live.visits === 2, "a like, and two visits: Rahul's booking and Meera's from the building QR — counted once, not twice", JSON.stringify(live));
check(dash?.find((d) => d.property_id === "MZ-PAUSE")?.stats?.scans === 0, "a paused flat's page counts nothing");
check(dash?.length === 2 && !dash.some((d) => d.property_id === "MZ-OMFLT"), "her dashboard has her two flats, not Om's");
check((await J(db, o2, "select public.owner_rent_dashboard()"))?.length === 1, "Om's has his one");

console.log("\nfeedback");
check(denied(await as(db, o1, `select public.crm_flat_feedback_add('MZ-LIVE1', '{"price_view":"fair"}')`)), "the owner cannot write feedback");
check(denied(await as(db, renter, `select public.crm_flat_feedback_add('MZ-LIVE1', '{"price_view":"fair"}')`)), "nor a renter");
check((await as(db, staff, `select public.crm_flat_feedback_add('MZ-LIVE1', '{}')`)).error?.code === "22023", "empty feedback: refused");
check((await as(db, staff, `select public.crm_flat_feedback_add('MZ-LIVE1', '{"price_view":"cheap"}')`)).error != null, "an unknown rent view: refused");
const f1 = await J(db, staff, `select public.crm_flat_feedback_add('mz-live1', '{"renter_name":"Rahul Mehta","price_view":"bit_high","rating":4,"comment":"Loved the balcony, rent a little high","source":"visit"}')`);
await as(db, staff, `select public.crm_flat_feedback_add('MZ-LIVE1', '{"renter_name":"Meera Nair","price_view":"fair","rating":5,"source":"call"}')`);
check(!!f1, "staff record two renters' feedback");
const s2 = (await J(db, o1, "select public.owner_rent_dashboard()"))?.find((d) => d.property_id === "MZ-LIVE1")?.stats;
check(s2?.feedback === 2 && Number(s2.rating) === 4.5 && s2.price_views?.bit_high === 1 && s2.price_views?.fair === 1,
  "the dashboard counts it: two, 4.5 stars, one 'a bit high', one 'fair'", JSON.stringify(s2));

console.log("\nwho sees what");
const mine = await J(db, o1, "select public.owner_flat_insights('MZ-LIVE1')");
const txt = JSON.stringify(mine);
check(mine?.feedback?.length === 2 && mine.feedback.some((f) => f.name === "Rahul M." && f.comment.includes("balcony") && f.price_view === "bit_high"),
  "the owner reads the feedback, by first name and initial", txt.slice(0, 200));
check(mine?.likes?.[0]?.name === "Rahul M." && mine.visits?.length === 2 && mine.by_day?.length === 14 && mine.building_code === bld.code,
  "and who liked, who visited, 14 days of scans, and the building's QR");
check(!txt.includes("98765") && !txt.includes("agent@moveazy"), "never a renter's number, nor which staff member wrote it");
check((await J(db, o2, "select public.owner_flat_insights('MZ-LIVE1')")) === null, "Om sees nothing of Priya's flat");
const crm = await J(db, staff, "select public.crm_flat_insights('MZ-LIVE1')");
check(crm?.visits?.some((v) => v.phone === "9876544444" && v.name === "Meera Nair") && crm.feedback?.[0]?.created_by === "agent@moveazy.co.in",
  "the CRM sees full names, numbers and who wrote each note", JSON.stringify(crm?.visits));
check(denied(await as(db, o1, "select public.crm_flat_insights('MZ-LIVE1')")), "owners can't use the CRM's view");
await as(db, staff, `select public.crm_flat_feedback_delete('${f1}')`);
check((await J(db, o1, "select public.owner_flat_insights('MZ-LIVE1')"))?.feedback?.length === 1, "staff remove a note made by mistake");

console.log("\nlocked down");
check(!!(await as(db, anon, "select * from public.flat_scans")).error, "anon cannot read scans");
check(!!(await as(db, o1, "select * from public.flat_feedback")).error, "an owner cannot read the feedback table directly");
check(!!(await as(db, anon, "select public.owner_rent_dashboard()")).error, "anon has no dashboard");
check(!!(await as(db, o1, "select public.flat_stats('MZ-LIVE1')")).error, "nor can anyone call the internal helpers");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
