/**
 * Apply partner_listing_edit.sql (PGlite, in-process) and check a partner's
 * delete: their own flat goes to status 'deleted' (kept, not removed); nobody
 * else's; an unknown status is refused. owns_listing is stubbed to its rule
 * (posted by them, or given to them in partner_listings).
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});
const file = (name) => readFileSync(new URL(`../${name}`, import.meta.url), "utf8").replace(/create extension if not exists "pgcrypto";/g, "");
const ownerCheck = readFileSync(new URL("./owner_check.mjs", import.meta.url), "utf8");
const PRELUDE = ownerCheck.split("const PRELUDE = `")[1].split("`;")[0];

let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};
async function as(db, who, sql) {
  await db.exec(`reset role; select set_config('test.uid', '${who.uid ?? ""}', false), set_config('test.email', '${who.email ?? ""}', false),
    set_config('test.staff', '', false), set_config('test.super', '', false), set_config('test.scopes', '', false); set role ${who.role ?? "authenticated"};`);
  try { return { rows: (await db.query(sql)).rows, error: null }; } catch (e) { return { rows: null, error: e }; } finally { await db.exec("reset role"); }
}
const status = async (db, id) => (await db.query(`select status from public.inventory where property_id = '${id}'`)).rows[0]?.status;

const BALA = { uid: "d1111111-0000-0000-0000-000000000006", email: "bala@broker.in" };
const CHETAN = { uid: "d1111111-0000-0000-0000-000000000007", email: "chetan@broker.in" };

const db = new PGlite();
await db.exec(PRELUDE);
await db.exec(file("inventory_schema.sql"));
await db.exec(`
alter table public.inventory add column if not exists property_type text, add column if not exists nearby_areas text[],
  add column if not exists latitude numeric, add column if not exists longitude numeric, add column if not exists occupants_allowed text[],
  add column if not exists maintenance numeric, add column if not exists floor_number int;
create table public.partner_listings (property_id text, broker_id uuid);
create function public.owns_listing(p text, u uuid) returns boolean language sql stable as $$
  select exists (select 1 from public.inventory i where i.property_id = p and i.poster_id = u)
      or exists (select 1 from public.partner_listings l where l.property_id = p and l.broker_id = u) $$;
insert into auth.users (id, email) values ('${BALA.uid}', '${BALA.email}'), ('${CHETAN.uid}', '${CHETAN.email}');
insert into public.inventory (property_id, posted_by, poster_id, area, rent, status, flat_type) values
  ('MZ-B1', 'broker', '${BALA.uid}', 'HSR', 30000, 'published', '2 BHK'),
  ('MZ-B2', 'broker', null, 'HSR', 32000, 'published', '2 BHK');
insert into public.partner_listings values ('MZ-B2', '${BALA.uid}');
`);
await db.exec(file("partner_listing_edit.sql"));
await db.exec(file("partner_listing_edit.sql"));
check(true, "partner_listing_edit.sql applies, and re-applies over itself");

let r = await as(db, BALA, "select public.partner_listing_update('MZ-B1', '{\"status\":\"deleted\"}')");
check(!r.error && (await status(db, "MZ-B1")) === "deleted", "a partner deletes their own flat — kept, as status deleted", r.error?.message);
check(Number((await db.query("select count(*) n from public.inventory where property_id = 'MZ-B1'")).rows[0].n) === 1, "the row is still there for MovEazy");
r = await as(db, BALA, "select public.partner_listing_update('MZ-B2', '{\"status\":\"rented\"}')");
check(!r.error && (await status(db, "MZ-B2")) === "rented", "marks a flat given to them sold out", r.error?.message);
r = await as(db, CHETAN, "select public.partner_listing_update('MZ-B2', '{\"status\":\"deleted\"}')");
check(r.error && /Not your flat/.test(r.error.message) && (await status(db, "MZ-B2")) === "rented", "another partner can't delete it", r.error?.message);
r = await as(db, BALA, "select public.partner_listing_update('MZ-B2', '{\"status\":\"gone\"}')");
check(r.error && /Unknown status/.test(r.error.message), "an unknown status is refused", r.error?.message);
r = await as(db, { role: "anon" }, "select public.partner_listing_update('MZ-B2', '{\"status\":\"deleted\"}')");
check(Boolean(r.error), "nobody signed out may");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
