/**
 * Apply inventory_sold_out.sql (PGlite, in-process) and check sold out:
 *
 *   - any way a listing becomes 'rented' stamps the date and who did it — the
 *     CRM button, a plain status update (the edit form, an owner, a partner
 *     confirmation), a new row inserted as rented;
 *   - staff can back-date it, within the last year and never ahead;
 *   - relisting clears the date on the listing but the history keeps the sale,
 *     and a second sale gets a second row;
 *   - only staff who may edit listings use the CRM functions; nobody writes the
 *     history, and only staff read it.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});

const file = (name) => readFileSync(new URL(`../${name}`, import.meta.url), "utf8");
const ownerCheck = readFileSync(new URL("./owner_check.mjs", import.meta.url), "utf8");
const PRELUDE = ownerCheck.split("const PRELUDE = `")[1].split("`;")[0];

const O1 = "a1111111-0000-0000-0000-000000000001"; // Priya, owner
const S = "c1111111-0000-0000-0000-000000000005";  // CRM staff

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
const J = async (db, who, sql) => one(await as(db, who, sql));

const priya = { uid: O1, email: "priya@example.com" };
const editor = { uid: S, email: "agent@moveazy.co.in", staff: true, scopes: ["crm.properties.write"] };
const reader = { uid: S, email: "agent@moveazy.co.in", staff: true };

const db = new PGlite();
await db.exec(PRELUDE);
await db.exec(`
-- inventory_schema.sql's inventory, as this needs it (owners update their own rows).
create table public.inventory (
  property_id text primary key, poster_id uuid references auth.users(id), area text default '',
  status text not null default 'published', updated_at timestamptz not null default now()
);
alter table public.inventory enable row level security;
create policy "read" on public.inventory for select using (true);
create policy "posters update own inventory" on public.inventory for update to authenticated
  using (poster_id = auth.uid()) with check (poster_id = auth.uid());
create policy "posters create own inventory" on public.inventory for insert to authenticated with check (poster_id = auth.uid());
grant select, insert, update on public.inventory to authenticated;
`);
await db.exec(file("inventory_sold_out.sql"));
await db.exec(file("inventory_sold_out.sql"));
check(true, "inventory_sold_out.sql applies, and re-applies over itself");

await db.exec(`
insert into auth.users (id, email) values ('${O1}', 'priya@example.com'), ('${S}', 'agent@moveazy.co.in');
insert into public.inventory (property_id, poster_id, area) values
  ('MZ-AAAA01', '${O1}', 'HSR'), ('MZ-BBBB02', '${O1}', 'Koramangala'), ('MZ-CCCC03', null, 'Bellandur');
`);
const row = async (id) => (await db.query(`select status, sold_out_at, sold_out_by from public.inventory where property_id = '${id}'`)).rows[0];
const log = async (id) => (await db.query(`select sold_out_at, sold_out_by, relisted_at, relisted_by from public.inventory_sold_out_log where property_id = '${id}' order by id`)).rows;

console.log("\nthe CRM button");
const r1 = await J(db, editor, "select public.crm_mark_sold_out('MZ-AAAA01')");
const a1 = await row("MZ-AAAA01");
check(r1?.status === "rented" && a1.status === "rented" && a1.sold_out_at && a1.sold_out_by === "agent@moveazy.co.in",
  "marked today: rented, dated, and who did it", JSON.stringify(a1));
check((await log("MZ-AAAA01")).length === 1, "one row in the history");

const day = new Date(Date.now() - 20 * 864e5).toISOString().slice(0, 10);
await J(db, editor, `select public.crm_mark_sold_out('MZ-BBBB02', '${day}')`);
const b1 = await row("MZ-BBBB02");
const ist = new Date(new Date(b1.sold_out_at).getTime() + 5.5 * 36e5).toISOString().slice(0, 10);
check(ist === day, "back-dated to the day it went (that day in India)", `${b1.sold_out_at} vs ${day}`);
const day2 = new Date(Date.now() - 25 * 864e5).toISOString().slice(0, 10);
await J(db, editor, `select public.crm_mark_sold_out('MZ-BBBB02', '${day2}')`);
const b2 = await log("MZ-BBBB02");
check(b2.length === 1 && new Date(b2[0].sold_out_at).getTime() < new Date(b1.sold_out_at).getTime(),
  "re-dated while sold out: the same history row moves, no second sale", JSON.stringify(b2));

const tomorrow = new Date(Date.now() + 2 * 864e5).toISOString().slice(0, 10);
check((await as(db, editor, `select public.crm_mark_sold_out('MZ-CCCC03', '${tomorrow}')`)).error?.code === "22023", "not a day in the future");
check((await as(db, editor, "select public.crm_mark_sold_out('MZ-CCCC03', '2020-01-01')")).error?.code === "22023", "nor years back");
check((await as(db, editor, "select public.crm_mark_sold_out('MZ-NOPE99')")).error?.code === "P0002", "an unknown listing: refused");

console.log("\nwho may");
check((await as(db, reader, "select public.crm_mark_sold_out('MZ-CCCC03')")).error?.code === "42501", "staff who can't edit listings cannot");
check((await as(db, priya, "select public.crm_mark_sold_out('MZ-CCCC03')")).error?.code === "42501", "nor an owner, through the CRM function");
check((await as(db, priya, "select public.crm_relist('MZ-AAAA01')")).error?.code === "42501", "nor relist");
check(!!(await as(db, priya, "insert into public.inventory_sold_out_log (property_id, sold_out_at) values ('MZ-CCCC03', now())")).error, "nobody writes the history");
check((await as(db, priya, "select * from public.inventory_sold_out_log")).rows?.length === 0, "an owner reads none of it");
check((await as(db, reader, "select count(*)::int n from public.inventory_sold_out_log")).rows?.[0]?.n === 2, "CRM staff can");

console.log("\nevery other way in");
await as(db, priya, "update public.inventory set status = 'paused' where property_id = 'MZ-AAAA01'");
const a2 = await row("MZ-AAAA01");
check(a2.status === "paused" && a2.sold_out_at === null && a2.sold_out_by === "", "back off the market some other way: the listing's date clears", JSON.stringify(a2));
const al = await log("MZ-AAAA01");
check(al.length === 1 && al[0].relisted_at && al[0].relisted_by === "priya@example.com", "but the history keeps the sale, closed by whoever relisted", JSON.stringify(al));
await as(db, priya, "update public.inventory set status = 'rented' where property_id = 'MZ-AAAA01'");
const a3 = await row("MZ-AAAA01");
check(a3.sold_out_at && a3.sold_out_by === "priya@example.com", "an owner marking it rented in her app: dated too", JSON.stringify(a3));
check((await log("MZ-AAAA01")).length === 2, "a second sale, a second history row");
await as(db, priya, "insert into public.inventory (property_id, poster_id, status) values ('MZ-DDDD04', '" + O1 + "', 'rented')");
check(!!(await row("MZ-DDDD04")).sold_out_at && (await log("MZ-DDDD04")).length === 1, "a listing added already rented: dated and logged");
await db.exec("update public.inventory set area = 'HSR Layout' where property_id = 'MZ-AAAA01'");
check((await log("MZ-AAAA01")).length === 2, "an edit that isn't the status leaves it alone");

console.log("\nrelist");
const rl = await J(db, editor, "select public.crm_relist('MZ-BBBB02')");
const b3 = await row("MZ-BBBB02");
check(rl?.status === "published" && b3.status === "published" && b3.sold_out_at === null, "relisted: published, undated", JSON.stringify(b3));
check((await log("MZ-BBBB02"))[0].relisted_by === "agent@moveazy.co.in", "the history says who relisted it");
check((await as(db, editor, "select public.crm_relist('MZ-BBBB02')")).error?.code === "22023", "relisting what isn't sold out: refused");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
