/**
 * Apply site_contact_messages.sql (PGlite) and check the website's contact form:
 * anyone can send, bad input is refused, a number gets five a day, a known
 * client gets it on their timeline, only CRM staff read and clear the list.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});
const SQL = readFileSync(new URL("../site_contact_messages.sql", import.meta.url), "utf8");
const INTAKE = readFileSync(new URL("../lead_intake.sql", import.meta.url), "utf8");
const NORMALIZE = INTAKE.slice(INTAKE.indexOf("create or replace function public.normalize_mobile"), INTAKE.indexOf("$$;", INTAKE.indexOf("create or replace function public.normalize_mobile")) + 3);

let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};

const db = new PGlite();
await db.exec(`
create role anon; create role authenticated;
grant usage on schema public to anon, authenticated;
create schema auth;
grant usage on schema auth to anon, authenticated;
create function auth.jwt() returns jsonb language sql stable as $$ select jsonb_build_object('email', current_setting('test.email', true)) $$;
create function public.is_crm_staff() returns boolean language sql stable as $$ select current_setting('test.staff', true) = 'on' $$;
create table public.crm_clients (id uuid primary key default gen_random_uuid(), name text default '', phone text default '', created_at timestamptz default now());
create table public.crm_activities (id uuid primary key default gen_random_uuid(), client_id uuid references public.crm_clients(id),
  actor_email text default '', type text default 'note', body text default '', meta jsonb default '{}', created_at timestamptz default now());
${NORMALIZE}
insert into public.crm_clients (id, name, phone) values ('c0000000-0000-0000-0000-000000000001', 'Riya', '9876543210');
`);
await db.exec(SQL);
await db.exec(SQL);
check(true, "site_contact_messages.sql applies, and re-applies over itself");

async function as(who, sql, params = []) {
  await db.exec(`reset role; select set_config('test.email', '${who.email ?? ""}', false),
    set_config('test.staff', '${who.staff ? "on" : ""}', false); set role ${who.role ?? "authenticated"};`);
  try { return { rows: (await db.query(sql, params)).rows, error: null }; }
  catch (e) { return { rows: null, error: e }; }
  finally { await db.exec("reset role"); }
}
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const anon = { role: "anon" };
const user = { email: "someone@x" };
const staff = { email: "ops@moveazy.co.in", staff: true };
const send = (who, name, phone, email, topic, msg) =>
  as(who, "select public.submit_contact_message($1, $2, $3, $4, $5)", [name, phone, email, topic, msg]);

console.log("\nsending");
let r = await send(anon, "  Aman   Gupta ", "+91 91234 56789", "Aman@Mail.com", "owner", "I have a 2 BHK in HSR to list.");
check(one(r)?.ok === true, "signed out, a message goes through", r.error?.message);
let row = (await db.query("select * from public.site_contact_messages order by created_at desc limit 1")).rows[0];
check(row?.name === "Aman Gupta" && row.phone === "9123456789" && row.email === "aman@mail.com" && row.topic === "owner",
  "name tidied, number normalised, email lower-cased", JSON.stringify(row));
check(row?.client_id === null, "a new number isn't anyone's client yet");

r = await send(user, "Riya", "9876543210", "", "payment", "Paid for the lead pack, no leads yet");
check(one(r)?.ok === true, "signed in, too", r.error?.message);
row = (await db.query("select * from public.site_contact_messages where phone = '9876543210'")).rows[0];
check(row?.client_id === "c0000000-0000-0000-0000-000000000001", "a known number is tied to its CRM client");
const act = (await db.query("select * from public.crm_activities")).rows;
check(act.length === 1 && act[0].body.includes("lead pack") && act[0].meta.source === "contact_form", "and lands on their timeline", JSON.stringify(act));

r = await send(anon, "X", "12345", "", "other", "hi");
check(/10-digit/.test(r.error?.message ?? ""), "a bad number is refused", r.error?.message);
r = await send(anon, "", "9123456780", "", "other", "hi");
check(/name/.test(r.error?.message ?? ""), "no name is refused", r.error?.message);
r = await send(anon, "X", "9123456780", "not-an-email", "other", "hi");
check(/email/.test(r.error?.message ?? ""), "a bad email is refused", r.error?.message);
r = await send(anon, "X", "9123456780", "", "other", "   ");
check(/message/.test(r.error?.message ?? ""), "an empty message is refused", r.error?.message);
r = await send(anon, "X", "9123456780", "", "weird", "x".repeat(5000));
check(!r.error, "an unknown topic and a long message are accepted", r.error?.message);
row = (await db.query("select * from public.site_contact_messages where phone = '9123456780'")).rows[0];
check(row?.topic === "other" && row.message.length === 1000, "…as 'other', cut to 1000 characters");

for (let i = 0; i < 4; i += 1) await send(anon, "X", "9123456780", "", "other", `again ${i}`);
r = await send(anon, "X", "9123456780", "", "other", "sixth");
check(/get back to you/.test(r.error?.message ?? ""), "a sixth message from one number in a day is held back", r.error?.message);

console.log("\nwho reads");
r = await as(anon, "select * from public.site_contact_messages");
check(Boolean(r.error), "anon can't read the table");
r = await as(user, "select * from public.site_contact_messages");
check(Boolean(r.error), "a signed-in user can't read the table");
r = await as(user, "select * from public.crm_contact_messages()");
check(/Not allowed/.test(r.error?.message ?? ""), "nor the CRM list", r.error?.message);
r = await as(anon, "select * from public.crm_contact_messages()");
check(Boolean(r.error), "anon can't call the CRM list");
r = await as(staff, "select * from public.crm_contact_messages()");
check(r.rows?.length === 7 && r.rows[0].message === "again 3", "staff see the new ones, newest first", r.error?.message ?? r.rows?.length);

const id = r.rows[0].id;
r = await as(user, "select public.crm_contact_message_set($1, true)", [id]);
check(Boolean(r.error), "only staff mark done");
r = await as(staff, "select public.crm_contact_message_set($1, true)", [id]);
check(!r.error, "staff mark one done", r.error?.message);
r = await as(staff, "select * from public.crm_contact_messages('done')");
check(r.rows?.length === 1 && r.rows[0].done_by === "ops@moveazy.co.in" && r.rows[0].done_at, "it moves to done, with who and when");
r = await as(staff, "select * from public.crm_contact_messages()");
check(r.rows?.length === 6, "and leaves the new list");
await as(staff, "select public.crm_contact_message_set($1, false)", [id]);
r = await as(staff, "select * from public.crm_contact_messages()");
check(r.rows?.length === 7, "undo puts it back");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
