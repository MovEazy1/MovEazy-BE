/**
 * Apply crm_phone_leads.sql then crm_partners_not_leads.sql (PGlite) over a
 * stand-in CRM and check:
 *   - joining the partner app (number saved, then partner_register) leaves no
 *     CRM lead; a partner who changes their number later doesn't become one;
 *   - a tenant who searched first and joined later keeps their lead;
 *   - a worked lead (a call logged) is never removed;
 *   - partners already sitting in Fresh are removed on apply, and only them;
 *   - the sync button's direct insert and the backfill skip partners;
 *   - a partner who saves a flat search becomes a lead, noted on the timeline;
 *   - ordinary tenants are untouched.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});
const read = (f) => readFileSync(new URL(`../${f}`, import.meta.url), "utf8");
const SQL = read("crm_partners_not_leads.sql");
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
  role text default 'customer', created_at timestamptz default now(), updated_at timestamptz default now());
create table public.crm_clients (id uuid primary key default gen_random_uuid(), user_id uuid unique, name text default '', phone text default '',
  email text default '', source text default 'app', status text default 'fresh',
  created_at timestamptz default now(), updated_at timestamptz default now());
create table public.crm_activities (id uuid primary key default gen_random_uuid(), client_id uuid references public.crm_clients(id) on delete cascade,
  actor_email text default '', type text default 'note', body text default '', meta jsonb default '{}', created_at timestamptz default now());
create table public.crm_client_requirements (client_id uuid primary key references public.crm_clients(id) on delete cascade, localities text[] default '{}');
create table public.crm_shortlists (id uuid primary key default gen_random_uuid(), client_id uuid references public.crm_clients(id) on delete cascade, property_id text);
create table public.partner_lead_assignments (id uuid primary key default gen_random_uuid(), client_id uuid references public.crm_clients(id) on delete cascade, broker_id uuid);
create table public.broker_partners (user_id uuid primary key, name text default '', phone text default '', created_at timestamptz default now());
create table public.user_requirements (user_id uuid primary key, localities text[] default '{}', flat_types text[] default '{}',
  budget_min numeric, budget_max numeric, email text default '');
`);
await db.exec(read("crm_phone_leads.sql"));

const U = (n) => `e0000000-0000-0000-0000-0000000000${String(n).padStart(2, "0")}`;
const leadOf = async (n) => (await db.query(`select * from public.crm_clients where user_id = '${U(n)}'`)).rows[0];
const count = async () => (await db.query("select count(*)::int n from public.crm_clients")).rows[0].n;

// Before the fix: two partners whose sign-up made a lead (Mallikarjun, Suresh),
// a tenant-first partner (Aniket), a partner whose lead the team worked (Worked),
// and a plain tenant (Tara).
await db.exec(`
insert into public.user_profiles (id, name, email) values
  ('${U(1)}', 'Mallikarjun', 'm@x'), ('${U(2)}', 'Suresh', 's@x'), ('${U(3)}', 'Aniket', 'a@x'),
  ('${U(4)}', 'Worked', 'w@x'), ('${U(5)}', 'Tara', 't@x');
insert into public.user_requirements (user_id, localities) values ('${U(3)}', '{HSR Layout}');
update public.user_profiles set phone = '8050438884' where id = '${U(1)}';
update public.user_profiles set phone = '7727870837' where id = '${U(2)}';
update public.user_profiles set phone = '7424960090' where id = '${U(3)}';
update public.user_profiles set phone = '9000000004' where id = '${U(4)}';
update public.user_profiles set phone = '9000000005' where id = '${U(5)}';
insert into public.broker_partners (user_id, name) values ('${U(1)}', 'Mallikarjun'), ('${U(2)}', 'Suresh'), ('${U(3)}', 'Aniket'), ('${U(4)}', 'Worked');
insert into public.crm_activities (client_id, actor_email, type, body)
  select id, 'agent@moveazy', 'call', 'Called' from public.crm_clients where user_id = '${U(4)}';
`);
check((await count()) === 5, "before: the phone trigger made a lead for all five (the bug)", await count());

await db.exec(SQL);
check(true, "crm_partners_not_leads.sql applies");
console.log("\nthe one-time clean-up");
check(!(await leadOf(1)) && !(await leadOf(2)), "Mallikarjun and Suresh (partner sign-up only) are removed");
check((await leadOf(3))?.status === "fresh", "Aniket searched as a tenant first — kept");
check(Boolean(await leadOf(4)), "a partner lead the team already called — kept");
check(Boolean(await leadOf(5)), "a plain tenant — untouched");
await db.exec(SQL);
check((await count()) === 3, "re-applying removes nobody else", await count());

console.log("\nnew partner sign-ups");
// The partner app: number saved first, then partner_register.
await db.exec(`
insert into public.user_profiles (id, name, email) values ('${U(6)}', 'Ravi', 'r@x');
update public.user_profiles set phone = '9811111111' where id = '${U(6)}';
`);
check(Boolean(await leadOf(6)), "(the number lands a moment before they're a partner)");
await db.exec(`insert into public.broker_partners (user_id, name) values ('${U(6)}', 'Ravi')`);
check(!(await leadOf(6)), "joining as a partner takes that lead straight back out");
await db.exec(`update public.user_profiles set phone = '9822222222' where id = '${U(6)}'`);
check(!(await leadOf(6)), "a partner changing their number doesn't become a lead");

await db.exec(`insert into public.crm_clients (user_id, name, phone, source, status) values ('${U(6)}', 'Ravi', '9822222222', 'signup', 'fresh')`);
check(!(await leadOf(6)), "the CRM's sync button can't add a partner either");
await db.exec(read("crm_phone_leads.sql"));
check(!(await leadOf(6)) && !(await leadOf(1)), "nor can re-running the phone-leads backfill");
await db.exec(`insert into public.crm_clients (user_id, name, phone, source) values ('${U(6)}', 'Ravi by hand', '9822222222', 'manual')`);
check((await leadOf(6))?.name === "Ravi by hand", "a lead the team adds by hand is always kept");
await db.exec(`delete from public.crm_clients where user_id = '${U(6)}'`);

console.log("\na partner looking for a flat");
await db.exec(`insert into public.user_requirements (user_id, email) values ('${U(1)}', 'm@x')`);
check(!(await leadOf(1)), "an empty requirements row (just signed in on the site) isn't a search");
await db.exec(`update public.user_requirements set localities = '{Koramangala}', budget_max = 30000 where user_id = '${U(1)}'`);
let r = await leadOf(1);
check(r?.status === "fresh" && r.phone === "8050438884" && r.source === "signup", "saving an area and budget makes them a Fresh lead", JSON.stringify(r));
const note = (await db.query(`select type, body from public.crm_activities where client_id = '${r?.id}'`)).rows;
check(note.length === 1 && note[0].type === "system", "…noted on their timeline as a system entry (so it's Fresh, not Contacted)", JSON.stringify(note));
await db.exec(`update public.user_requirements set budget_max = 32000 where user_id = '${U(1)}'`);
check((await db.query(`select count(*)::int n from public.crm_activities where client_id = '${r?.id}'`)).rows[0].n === 1, "editing the search later doesn't add another");

// A phone-first lead (tenant gate) with the same number gets linked, not duplicated.
await db.exec(`
insert into public.crm_clients (name, phone, source) values ('Gate lead', '7727870837', 'google');
insert into public.user_requirements (user_id, flat_types) values ('${U(2)}', '{2BHK}');
`);
r = await leadOf(2);
check(r?.name === "Gate lead" && (await count()) === 5, "a partner who already gave their number at the tenant gate is linked to that lead", JSON.stringify(r));

console.log("\ntenants");
await db.exec(`
insert into public.user_profiles (id, name, email) values ('${U(7)}', 'Uma', 'u@x');
update public.user_profiles set phone = '9833333333' where id = '${U(7)}';
`);
check((await leadOf(7))?.status === "fresh", "a tenant's number still makes a Fresh lead at once");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
