/**
 * Apply building_total_flats.sql (PGlite, over stubs) and check: the public
 * page carries the building's flat count (null until the CRM sets one); CRM
 * staff read it; only CRM writers set or clear it, as a whole number 1–2000.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});
const SQL = readFileSync(new URL("../building_total_flats.sql", import.meta.url), "utf8");
let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};
const B = "d0000000-0000-0000-0000-000000000001";
const db = new PGlite();
await db.exec(`
create role anon; create role authenticated;
create function public.is_crm_staff() returns boolean language sql stable as $$ select current_setting('test.staff', true) = 'on' $$;
create function public.has_admin_scope(s text) returns boolean language sql stable as $$ select current_setting('test.write', true) = 'on' $$;
create table public.owner_buildings (id uuid primary key, code text, name text, area text default '', landmark text default '',
  latitude numeric, longitude numeric, total_floors int, description text default '', amenities text[] default '{}', photos text[] default '{}',
  kind text default 'building', cover_video text default '', broker_id uuid, instant_visit boolean default false, instant_poc_phone text default '',
  updated_at timestamptz default now());
insert into public.owner_buildings (id, code, name) values ('${B}', 'H33PSH', 'BR Homes');
create function public.building_by_code(p text) returns uuid language sql stable as $$ select id from public.owner_buildings where code = upper(p) $$;
create function public.building_flats(p uuid) returns jsonb language sql stable as $$ select '[]'::jsonb $$;
grant execute on all functions in schema public to anon, authenticated;
`);
await db.exec(SQL);
await db.exec(SQL);
check(true, "building_total_flats.sql applies, and re-applies over itself");

async function as(who, sql) {
  await db.exec(`reset role; select set_config('test.staff', '${who.staff ? "on" : ""}', false), set_config('test.write', '${who.write ? "on" : ""}', false);
    set role ${who.role ?? "authenticated"};`);
  try { return { rows: (await db.query(sql)).rows, error: null }; }
  catch (e) { return { rows: null, error: e }; }
  finally { await db.exec("reset role"); }
}
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const anon = { role: "anon" }, staff = { staff: true }, writer = { staff: true, write: true }, tenant = {};

let r = await as(anon, "select public.building_page('h33psh')");
check(r.error == null && one(r).total_flats === null && one(r).name === "BR Homes", "the page: no count until the CRM sets one", r.error?.message);
check(one(await as(staff, `select public.crm_building_total_flats('${B}')`)) === null, "CRM staff read it: unset");
r = await as(staff, `select public.crm_building_total_flats('${B}', '42')`);
check(Boolean(r.error), "staff without write: can't set it");
r = await as(writer, `select public.crm_building_total_flats('${B}', ' 42 ')`);
check(one(r) === 42, "a CRM writer sets 42", r.error?.message);
check(one(await as(anon, "select public.building_page('H33PSH')")).total_flats === 42, "the page says 42");
for (const bad of ["0", "2001", "4x", "-3"]) {
  r = await as(writer, `select public.crm_building_total_flats('${B}', '${bad}')`);
  check(Boolean(r.error), `"${bad}" refused`);
}
check(one(await as(staff, `select public.crm_building_total_flats('${B}')`)) === 42, "a refused value changes nothing");
r = await as(writer, `select public.crm_building_total_flats('${B}', '')`);
check(r.error == null && one(r) === null, "'' clears it");
r = await as(writer, `select public.crm_building_total_flats('d0000000-0000-0000-0000-000000000009', '10')`);
check(Boolean(r.error), "an unknown building: refused");
r = await as(tenant, `select public.crm_building_total_flats('${B}')`);
check(Boolean(r.error), "a tenant can't read it through the CRM call");
r = await as(anon, `select public.crm_building_total_flats('${B}')`);
check(Boolean(r.error), "anon can't call it");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
