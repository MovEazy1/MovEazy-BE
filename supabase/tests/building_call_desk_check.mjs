/**
 * Apply building_call_desk.sql (PGlite, over stubs) and check Call Caretaker:
 *
 *   - a tenant with a valid mobile gets the caretaker's and the manager's
 *     numbers; an unset one is MovEazy's team number; a bad mobile, an unknown
 *     or paused building, an unknown action: refused;
 *   - every step is kept (contacts, call, feedback with its note), 60 an hour
 *     at most per phone or browser;
 *   - CRM staff read the contacts and the log; only CRM writers change them,
 *     with valid mobiles; the log is never readable directly.
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
const SQL = read("building_call_desk.sql");
let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};
const B = "d0000000-0000-0000-0000-000000000001";
const P = "d0000000-0000-0000-0000-000000000002";
const db = new PGlite();
await db.exec(`
create role anon; create role authenticated;
create schema auth;
create table auth.users (id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
create function public.is_crm_staff() returns boolean language sql stable as $$ select current_setting('test.staff', true) = 'on' $$;
create function public.has_admin_scope(s text) returns boolean language sql stable as $$ select current_setting('test.write', true) = 'on' $$;
create table public.owner_buildings (id uuid primary key, code text, name text, status text default 'active', updated_at timestamptz default now());
insert into public.owner_buildings (id, code, name) values ('${B}', 'H33PSH', 'BR Homes');
insert into public.owner_buildings (id, code, name, status) values ('${P}', 'PAUSED', 'Paused', 'paused');
create function public.building_by_code(p_code text) returns uuid language sql stable security definer as $$
  select b.id from public.owner_buildings b where b.code = upper(trim(coalesce(p_code, ''))) and b.status = 'active' $$;
`);
await db.exec(fn(read("lead_intake.sql"), "normalize_mobile"));
await db.exec(SQL);
await db.exec(SQL);
check(true, "building_call_desk.sql applies, and re-applies over itself");

async function as(who, sql) {
  await db.exec(`reset role; select set_config('test.uid', '', false), set_config('test.staff', '${who.staff ? "on" : ""}', false),
    set_config('test.write', '${who.write ? "on" : ""}', false); set role ${who.role ?? "authenticated"};`);
  try { return { rows: (await db.query(sql)).rows, error: null }; }
  catch (e) { return { rows: null, error: e }; }
  finally { await db.exec("reset role"); }
}
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const q1 = async (sql) => Object.values((await db.query(sql)).rows[0] ?? {})[0];
const anon = { role: "anon" }, staff = { staff: true }, writer = { staff: true, write: true };
const desk = (args) => as(anon, `select public.building_call_desk(${args})`);

console.log("\nthe tenant's side");
let r = await desk(`'h33psh', 'browser-0001', '98765 43210', 'Ravi'`);
check(r.error == null && one(r).caretaker.phone === "9146969162" && one(r).manager.phone === "9146969162" && one(r).caretaker.name == null,
  "nothing set: both are MovEazy's team number", r.error?.message || JSON.stringify(one(r)));
r = await as(writer, `select public.crm_building_call_desk('${B}', '{"caretaker_name":"Ramesh","caretaker_phone":"+91 90000 11111","manager_name":"Priya","manager_phone":"9000022222"}')`);
check(r.error == null && one(r).caretaker_phone === "9000011111", "a CRM writer sets both", r.error?.message);
r = await desk(`'H33PSH', 'browser-0001', '9876543210', 'Ravi'`);
check(one(r).caretaker.name === "Ramesh" && one(r).caretaker.phone === "9000011111" && one(r).manager.name === "Priya" && one(r).manager.phone === "9000022222",
  "now the building's own", JSON.stringify(one(r)));
await as(writer, `select public.crm_building_call_desk('${B}', '{"manager_name":"","manager_phone":""}')`);
r = await desk(`'H33PSH', 'browser-0001', '9876543210', 'Ravi'`);
check(one(r).manager.phone === "9146969162" && one(r).manager.name == null && one(r).caretaker.name === "Ramesh", "a cleared manager falls back; the caretaker stays");
for (const [args, why] of [
  [`'H33PSH', 'browser-0001', '12345', 'Ravi'`, "a bad mobile"],
  [`'NOPE00', 'browser-0001', '9876543210', 'Ravi'`, "an unknown building"],
  [`'PAUSED', 'browser-0001', '9876543210', 'Ravi'`, "a paused building"],
  [`'H33PSH', 'browser-0001', '9876543210', 'Ravi', 'hack'`, "an unknown action"],
  [`'H33PSH', 'browser-0001', '9876543210', 'Ravi', 'call', 'owner'`, "a call to someone else"],
  [`'H33PSH', 'browser-0001', '9876543210', 'Ravi', 'feedback', '', 'rude'`, "unknown feedback"],
]) check(Boolean((await desk(args)).error), `refused: ${why}`);

r = await desk(`'H33PSH', 'browser-0001', '9876543210', 'Ravi', 'call', 'caretaker'`);
check(r.error == null && one(r) == null, "a call is kept, nothing handed back", r.error?.message);
await desk(`'H33PSH', 'browser-0001', '9876543210', 'Ravi', 'feedback', '', 'call_not_picked'`);
await desk(`'H33PSH', 'browser-0001', '9876543210', 'Ravi', 'call', 'manager'`);
await desk(`'H33PSH', 'browser-0001', '9876543210', 'Ravi', 'feedback', '', 'other', '  The flat smelled of damp  '`);
const rows = (await db.query(`select kind, target, feedback, note from public.building_call_events order by id`)).rows;
check(rows.filter((x) => x.kind === "contacts").length === 3 && rows.some((x) => x.kind === "call" && x.target === "caretaker")
  && rows.some((x) => x.feedback === "call_not_picked") && rows.some((x) => x.note === "The flat smelled of damp"), "every step kept", JSON.stringify(rows));

await db.exec(`insert into public.building_call_events (building_id, visitor, phone, kind) select '${B}', 'browser-spam', '9811100000', 'contacts' from generate_series(1, 60)`);
check(Boolean((await desk(`'H33PSH', 'browser-spam', '9811100001', 'X'`)).error), "60 an hour per browser, then refused");
check(Boolean((await desk(`'H33PSH', 'browser-new1', '9811100000', 'X'`)).error), "and per phone");

console.log("\nthe CRM's side");
r = await as(staff, `select public.crm_building_call_desk('${B}')`);
check(r.error == null && one(r).events.length >= 7 && one(r).fallback === "9146969162", "CRM staff read the contacts and the log", r.error?.message);
check(Boolean((await as(staff, `select public.crm_building_call_desk('${B}', '{"caretaker_phone":"9000033333"}')`)).error), "staff without write can't change them");
check(Boolean((await as(writer, `select public.crm_building_call_desk('${B}', '{"caretaker_phone":"12345"}')`)).error), "a bad number refused");
check(await q1(`select caretaker_phone from public.owner_buildings where id = '${B}'`) === "9000011111", "and nothing changed");
check(Boolean((await as(anon, `select public.crm_building_call_desk('${B}')`)).error), "anon can't read the log");
check(Boolean((await as({}, `select public.crm_building_call_desk('${B}')`)).error), "a tenant can't either");
check(Boolean((await as(anon, "select * from public.building_call_events")).error), "the table itself is closed");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
