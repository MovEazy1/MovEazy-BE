/**
 * Apply crm_close_no_mobile.sql (PGlite) over a stand-in CRM, with
 * crm_phone_leads.sql's profile trigger, and check:
 *   - the first apply closes every open lead with no usable mobile (and only
 *     those), CRM only, noted on each timeline; a re-apply closes nobody new;
 *   - typing a number on the site — or the team adding one — makes them Fresh
 *     again; a lead closed by hand, or for another reason, stays closed.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});
const read = (f) => readFileSync(new URL(`../${f}`, import.meta.url), "utf8");
const SQL = read("crm_close_no_mobile.sql");
const INTAKE = read("lead_intake.sql");
const at = INTAKE.indexOf("create or replace function public.normalize_mobile");
const NORMALIZE = INTAKE.slice(at, INTAKE.indexOf("$$;", at) + 3);

let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};

const db = new PGlite();
await db.exec(`
create role anon; create role authenticated;
${NORMALIZE}
create table public.user_profiles (id uuid primary key, name text default '', email text default '', phone text default '',
  role text default 'customer', search_status text default 'searching', created_at timestamptz default now(), updated_at timestamptz default now());
create table public.crm_clients (id uuid primary key default gen_random_uuid(), user_id uuid unique, name text default '', phone text default '',
  email text default '', source text default 'app', status text default 'fresh', closed_reason text, closed_at timestamptz,
  created_at timestamptz default now(), updated_at timestamptz default now());
create table public.crm_activities (id uuid primary key default gen_random_uuid(), client_id uuid references public.crm_clients(id),
  actor_email text default '', type text default 'note', body text default '', meta jsonb default '{}', created_at timestamptz default now());
`);
await db.exec(read("crm_phone_leads.sql"));

const U = (n) => `e0000000-0000-0000-0000-00000000000${n}`;
await db.exec(`
insert into public.user_profiles (id, email) values ('${U(1)}', 'asha@x'), ('${U(2)}', 'bala@x'), ('${U(3)}', 'chetan@x');
insert into public.crm_clients (id, user_id, name, phone, status) values
  ('c0000000-0000-0000-0000-000000000001', '${U(1)}', 'Asha',   '',           'fresh'),
  ('c0000000-0000-0000-0000-000000000002', '${U(2)}', 'Bala',   '  ',         'need_inventory'),
  ('c0000000-0000-0000-0000-000000000003', null,      'Has one', '9876543210', 'fresh'),
  ('c0000000-0000-0000-0000-000000000004', '${U(3)}', 'Done',   '',           'closed_by_us'),
  ('c0000000-0000-0000-0000-000000000005', null,      'Junk',   '12345',      'shared');
insert into public.crm_clients (id, name, phone, status, closed_reason) values
  ('c0000000-0000-0000-0000-000000000006', 'Went with a broker', '', 'closed_outside', 'Went with a broker');
`);
const row = async (n) => (await db.query(`select * from public.crm_clients where id = 'c0000000-0000-0000-0000-00000000000${n}'`)).rows[0];

await db.exec(SQL);
check(true, "crm_close_no_mobile.sql applies");
console.log("\nthe one-time close");
for (const n of [1, 2, 5]) {
  const r = await row(n);
  check(r.status === "closed_outside" && r.closed_reason === "No mobile number" && r.closed_at, `${r.name}: no usable mobile → closed outside`, JSON.stringify(r));
}
check((await row(3)).status === "fresh", "a lead with a mobile is left open");
check((await row(4)).status === "closed_by_us", "a deal we closed is left alone");
check((await row(6)).closed_reason === "Went with a broker", "one already closed outside keeps its reason");
const acts = (await db.query("select count(*)::int n from public.crm_activities where meta->>'source' = 'no_mobile_close'")).rows[0].n;
check(acts === 3, "each one noted on its timeline", acts);
const prof = (await db.query("select count(*)::int n from public.user_profiles where search_status <> 'searching'")).rows[0].n;
check(prof === 0, "their site profiles are untouched — CRM only");

await db.exec(`insert into public.user_profiles (id, email) values ('${U(4)}', 'deepa@x');
insert into public.crm_clients (id, user_id, name, phone) values ('c0000000-0000-0000-0000-000000000007', '${U(4)}', 'New signup', '');`);
await db.exec(SQL);
check((await row(7)).status === "fresh", "re-applying doesn't close later sign-ups");

console.log("\ncoming back with a number");
await db.exec(`update public.user_profiles set phone = '+91 91234 56789' where id = '${U(1)}'`);
let r = await row(1);
check(r.status === "fresh" && r.phone === "9123456789" && r.closed_at === null && r.closed_reason === "",
  "typing a mobile on the site makes them a Fresh lead again", JSON.stringify(r));
const back = (await db.query("select body from public.crm_activities where client_id = 'c0000000-0000-0000-0000-000000000001' and meta->>'source' = 'no_mobile_reopen'")).rows;
check(back.length === 1, "…and says so on their timeline");

await db.exec(`update public.crm_clients set phone = '9000000002' where id = 'c0000000-0000-0000-0000-000000000002'`);
check((await row(2)).status === "fresh", "the team adding a number reopens them too");

await db.exec(`update public.crm_clients set phone = '9000000005' where id = 'c0000000-0000-0000-0000-000000000005'`);
check((await row(5)).status === "fresh", "replacing a junk number with a real one reopens");

await db.exec(`update public.crm_clients set phone = '9000000006' where id = 'c0000000-0000-0000-0000-000000000006'`);
check((await row(6)).status === "closed_outside", "a lead closed for another reason stays closed");

await db.exec(`update public.crm_clients set phone = '12' where id = 'c0000000-0000-0000-0000-000000000004'`);
check((await row(4)).status === "closed_by_us", "a closed deal is never reopened");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
