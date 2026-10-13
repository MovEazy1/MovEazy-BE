/**
 * Apply inventory_partner_hidden.sql (PGlite) over a stand-in inventory and
 * check which MovEazy flats partners stop seeing:
 *   - the first run hides every CRM flat (by hand or imported from a link) and
 *     every flat from the listed accounts — never a partner broker's own;
 *   - re-running doesn't hide a flat the CRM ticked back on;
 *   - new flats from those accounts, posted outside the CRM, start hidden;
 *     a CRM flat keeps whatever the CRM chose; anyone else's is unchanged.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});
const SQL = readFileSync(new URL("../inventory_partner_hidden.sql", import.meta.url), "utf8");

let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};

const Y = "a0000000-0000-0000-0000-000000000001", AM = "a0000000-0000-0000-0000-000000000002";
const O = "a0000000-0000-0000-0000-000000000003", B = "a0000000-0000-0000-0000-000000000004";
const db = new PGlite();
await db.exec(`
create role anon; create role authenticated;
create schema auth;
create table auth.users (id uuid primary key, email text);
insert into auth.users values ('${Y}', 'Yatharth200018@gmail.com'), ('${AM}', 'amansolanki262@gmail.com'), ('${O}', 'owner@x.com'), ('${B}', 'broker@x.com');
create table public.inventory (property_id text primary key, source text default '', poster_id uuid, poster_email text default '',
  status text default 'published', partner_visible boolean not null default true, updated_at timestamptz default now());
create table public.partner_listings (property_id text primary key, broker_id uuid);
insert into public.inventory (property_id, source, poster_id, poster_email) values
  ('CRM-1', 'crm', '${AM}', ''), ('CRM-2', 'portal', '${O}', ''), ('CRM-3', 'crm', '${O}', ''),
  ('Y-WEB', '', '${Y}', ''), ('AM-WEB', '', null, 'AmanSolanki262@gmail.com'),
  ('OWNER', '', '${O}', 'owner@x.com'), ('TENANT', '', null, ''),
  ('PARTNER-CRM', 'crm', '${B}', '');
insert into public.partner_listings values ('PARTNER-CRM', '${B}');
`);
const vis = async () => Object.fromEntries((await db.query("select property_id, partner_visible from public.inventory")).rows.map((r) => [r.property_id, r.partner_visible]));

await db.exec(SQL);
let v = await vis();
check(["CRM-1", "CRM-2", "CRM-3"].every((k) => v[k] === false), "every CRM flat hidden — by hand or imported from a link, whoever posted it");
check(v["Y-WEB"] === false && v["AM-WEB"] === false, "flats the two accounts posted on the site hidden (account or typed email, any case)");
check(v.OWNER && v.TENANT, "an owner's and a tenant's flat stay");
check(v["PARTNER-CRM"] === true, "a partner broker's own listing is never touched");

await db.exec("update public.inventory set partner_visible = true where property_id = 'CRM-1'"); // the CRM ticks it on
await db.exec(SQL);
check((await vis())["CRM-1"] === true, "re-running doesn't hide a flat the CRM ticked back on");

console.log("\nnew flats");
await db.exec(`insert into public.inventory (property_id, source, poster_id) values ('Y-NEW', '', '${Y}')`);
await db.exec(`insert into public.inventory (property_id, source, poster_email) values ('AM-NEW', '', 'amansolanki262@gmail.com')`);
await db.exec(`insert into public.inventory (property_id, source, poster_id, partner_visible) values ('CRM-SHOW', 'crm', '${AM}', true)`);
await db.exec(`insert into public.inventory (property_id, source, poster_id, partner_visible) values ('CRM-HIDE', 'crm', '${O}', false)`);
await db.exec(`insert into public.inventory (property_id, source, poster_id) values ('OWNER-NEW', '', '${O}')`);
v = await vis();
check(v["Y-NEW"] === false && v["AM-NEW"] === false, "posted outside the CRM by those accounts: starts hidden");
check(v["CRM-SHOW"] === true && v["CRM-HIDE"] === false, "a CRM flat keeps what the CRM chose");
check(v["OWNER-NEW"] === true, "anyone else's new flat: shown as before");
await db.exec("update public.inventory set partner_visible = true where property_id = 'Y-NEW'");
check((await vis())["Y-NEW"] === true, "the CRM can tick one of theirs on later");

console.log("\nwho may see what");
await db.exec("set role authenticated");
let denied = false;
try { await db.query("select * from public.partner_hidden_posters"); } catch { denied = true; }
await db.exec("reset role");
check(denied, "the list of accounts isn't readable by app users");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
