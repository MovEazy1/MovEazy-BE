/**
 * Apply find_deals.sql (PGlite, in-process) and check who may change the deals:
 *
 *   - any CRM user sees the Deals and adds or removes this week's Steal Deals
 *     (the Properties section's "Add to Steal Deals"), up to 20, live flats only;
 *   - Deal of the Day still needs crm.properties.write;
 *   - someone without CRM access, or not signed in, is refused;
 *   - the site's feed shows the week's flats in order.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});

// PGlite has no pgcrypto; gen_random_uuid() is built in.
const file = (name) => readFileSync(new URL(`../${name}`, import.meta.url), "utf8")
  .replace(/create extension if not exists "pgcrypto";/g, "");
const ownerCheck = readFileSync(new URL("./owner_check.mjs", import.meta.url), "utf8");
const PRELUDE = ownerCheck.split("const PRELUDE = `")[1].split("`;")[0];

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
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);

const agent = { uid: "c1111111-0000-0000-0000-000000000005", email: "agent@moveazy.co.in", staff: true, scopes: ["crm.clients.read"] };
const editor = { uid: "c1111111-0000-0000-0000-000000000006", email: "ops@moveazy.co.in", staff: true, scopes: ["crm.properties.write"] };
const tenant = { uid: "a1111111-0000-0000-0000-000000000001", email: "ravi@example.com" };
const anon = { role: "anon" };

const db = new PGlite();
await db.exec(PRELUDE);
await db.exec(file("inventory_schema.sql"));
// Columns later migrations add, as much as deal_flat_json reads.
await db.exec(`alter table public.inventory
  add column if not exists nearby_areas text[], add column if not exists landmark text, add column if not exists latitude double precision,
  add column if not exists longitude double precision, add column if not exists max_flatmates int, add column if not exists gender_pref text,
  add column if not exists occupants_allowed text[], add column if not exists maintenance numeric, add column if not exists floor_number int,
  add column if not exists total_floors int, add column if not exists lifestyle text[], add column if not exists house_rules text[],
  add column if not exists is_verified boolean default false, add column if not exists full_address text`);
await db.exec(file("find_deals.sql"));
await db.exec(file("find_deals.sql"));
check(true, "find_deals.sql applies, and re-applies over itself");

for (const [id, type, rent, status] of [["MZ-A1", "2 BHK", 40000, "published"], ["MZ-A2", "1 BHK", 22000, "published"],
  ["MZ-A3", "2 BHK", 42000, "published"], ["MZ-OLD", "2 BHK", 30000, "paused"]]) {
  await db.exec(`insert into public.inventory (property_id, posted_by, area, rent, status, flat_type) values ('${id}', 'owner', 'HSR Layout', ${rent}, '${status}', '${type}')`);
}

console.log("\nany CRM user, Steal Deals of the Week");
let r = await as(db, agent, "select public.crm_deals(null, null, null)");
check(!r.error, "a CRM user without property editing sees the Deals", r.error?.message);
r = await as(db, agent, "select public.crm_deal_steal_add(null, 'MZ-A1')");
check(!r.error && one(r).steal.length === 1, "adds a flat to this week's Steal Deals (the Properties shortcut)", r.error?.message);
r = await as(db, agent, "select public.crm_deal_steal_add(null, 'MZ-A1')");
check(!r.error && one(r).steal.length === 1, "adding it again changes nothing", r.error?.message);
r = await as(db, agent, "select public.crm_deal_steal_add(null, 'MZ-OLD')");
check(r.error && /isn't a live flat/.test(r.error.message), "a paused flat isn't taken", r.error?.message);
r = await as(db, agent, "select public.crm_deal_steal_set(public.deal_this_monday(), array['MZ-A3', 'MZ-A1'])");
check(!r.error && one(r).steal.map((x) => x.property_id).join() === "MZ-A3,MZ-A1", "reorders and removes the week's flats", r.error?.message);
r = await as(db, agent, "select public.crm_deal_day_set(public.deal_this_monday(), '2bhk', 'MZ-A1')");
check(r.error && /permission to edit properties/.test(r.error.message), "Deal of the Day still needs property editing", r.error?.message);
r = await as(db, editor, "select public.crm_deal_day_set(public.deal_this_monday(), '2bhk', 'MZ-A1')");
check(!r.error, "someone who edits properties sets the Deal of the Day", r.error?.message);

console.log("\nnobody else");
r = await as(db, tenant, "select public.crm_deal_steal_add(null, 'MZ-A2')");
check(r.error && /CRM staff only/.test(r.error.message), "a signed-in tenant is refused", r.error?.message);
r = await as(db, tenant, "select public.crm_deals(null, null, null)");
check(Boolean(r.error), "a tenant can't read the CRM's deals");
r = await as(db, anon, "select public.crm_deal_steal_add(null, 'MZ-A2')");
check(Boolean(r.error), "nobody signed out may call it");

console.log("\nthe site");
r = await as(db, anon, "select public.deals_feed()");
check(!r.error && one(r).steal.map((x) => x.listing.property_id).join() === "MZ-A3,MZ-A1", "the feed shows the week's flats, in order", r.error?.message);

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
