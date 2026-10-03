/**
 * Apply app_analytics.sql (PGlite, in-process) and check partner & owner app
 * analytics:
 *
 *   - anyone records taps for their own session through app_track — signed in
 *     or not yet — and nobody writes or reads app_events directly;
 *   - bad batches are dropped, times far off are pinned to now, labels capped;
 *   - only CRM staff with dashboards read the analytics; others are refused;
 *   - the people list has each owner / partner with last sign-in, time spent,
 *     sessions and taps — from their own app only;
 *   - one person's sessions come newest first with every tap in order, the
 *     taps made before they signed in included.
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
const P1 = "d1111111-0000-0000-0000-000000000006"; // Bala, partner
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

const anon = { role: "anon" };
const priya = { uid: O1, email: "priya@example.com" };
const bala = { uid: P1, email: "bala@broker.in" };
const viewer = { uid: S, email: "agent@moveazy.co.in", staff: true, scopes: ["crm.analytics.read"] };
const plainStaff = { uid: S, email: "agent@moveazy.co.in", staff: true };

const db = new PGlite();
await db.exec(PRELUDE);
await db.exec(`
alter table auth.users add column last_sign_in_at timestamptz;
-- crm_schema.sql's user_sessions, owner_schema.sql's owner_accounts and partner_schema.sql's broker_partners, as this needs them.
create table public.user_sessions (
  id uuid primary key default gen_random_uuid(), user_id uuid references auth.users(id), anon_id text default '', email text default '',
  started_at timestamptz not null default now(), ended_at timestamptz, duration_seconds int not null default 0,
  page_count int not null default 0, pages jsonb default '[]'::jsonb, device text default '', os text default '',
  referrer text default '', created_at timestamptz not null default now()
);
create table public.owner_accounts (
  user_id uuid primary key references auth.users(id), name text not null default '', phone text not null default '',
  email text not null default '', status text not null default 'pending', created_at timestamptz not null default now()
);
create table public.broker_partners (
  user_id uuid primary key references auth.users(id), name text not null default '', phone text not null default '',
  email text not null default '', agency text not null default '', status text not null default 'pending',
  created_at timestamptz not null default now()
);
`);
await db.exec(file("app_analytics.sql"));
await db.exec(file("app_analytics.sql"));
check(true, "app_analytics.sql applies, and re-applies over itself");

await db.exec(`
insert into auth.users (id, email, last_sign_in_at) values
  ('${O1}', 'priya@example.com', now() - interval '2 hours'), ('${P1}', 'bala@broker.in', now() - interval '1 day'),
  ('${S}', 'agent@moveazy.co.in', now());
insert into public.owner_accounts (user_id, name, phone, email, status) values ('${O1}', 'Priya Kumar', '9876500001', 'priya@example.com', 'approved');
insert into public.broker_partners (user_id, name, phone, email, agency, status) values ('${P1}', 'Bala', '9876500006', 'bala@broker.in', 'Bala Homes', 'approved');
-- Priya: one owner-app session of 5 minutes; Bala: one partner-app session; a main-site session of Priya's doesn't count.
insert into public.user_sessions (user_id, started_at, ended_at, duration_seconds, device, app, session_key) values
  ('${O1}', now() - interval '30 minutes', now() - interval '25 minutes', 300, 'mobile', 'owner', 'session_owner_1'),
  ('${O1}', now() - interval '3 days', now() - interval '3 days', 999, 'desktop', '', 'session_site_1'),
  ('${P1}', now() - interval '1 day', now() - interval '1 day' + interval '2 minutes', 120, 'desktop', 'partner', 'session_partner_1');
`);

console.log("\nrecording taps");
const ev = (label, extra = {}) => ({ kind: "click", label, target: "button", path: "/properties", at: new Date().toISOString(), ...extra });
// Before she signs in, then after: both in the same session.
const n0 = await J(db, anon, `select public.app_track('owner', 'session_owner_1', 'a_anon1', '${JSON.stringify([{ kind: "page", label: "/", path: "/", at: new Date(Date.now() - 1800e3).toISOString() }, ev("Sign in with Google", { path: "/" })])}'::jsonb)`);
check(n0 === 2, "signed out: two events recorded", String(n0));
const n1 = await J(db, priya, `select public.app_track('owner', 'session_owner_1', 'a_anon1', '${JSON.stringify([ev("Add property"), ev("x".repeat(300)), ev("Instant visit", { at: "2001-01-01T00:00:00Z" })])}'::jsonb)`);
check(n1 === 3, "signed in: three more", String(n1));
const caps = (await db.query("select max(length(label)) n, count(*) filter (where at < now() - interval '2 days') old from public.app_events")).rows[0];
check(Number(caps.n) === 120 && Number(caps.old) === 0, "labels capped at 120; a time far off pinned to now", JSON.stringify(caps));
const who = (await db.query("select label, user_id from public.app_events where label = 'Add property'")).rows[0];
check(who?.user_id === O1, "taps carry the signed-in account");
await as(db, bala, `select public.app_track('partner', 'session_partner_1', 'a_anon2', '${JSON.stringify([ev("Post a flat", { path: "/add" }), ev("Publish", { path: "/add" })])}'::jsonb)`);
check((await J(db, priya, `select public.app_track('tenant', 'session_owner_1', '', '[]'::jsonb)`)) === 0, "an unknown app: nothing");
check((await J(db, priya, `select public.app_track('owner', 'short', '', '[]'::jsonb)`)) === 0, "a bad session id: nothing");
check(!!(await as(db, priya, "insert into public.app_events (app, session_key, kind) values ('owner', 'session_owner_9', 'click')")).error, "nobody writes the table directly");
check(!!(await as(db, priya, "select * from public.app_events")).error, "or reads it");

console.log("\nwho may look");
check((await as(db, priya, "select public.app_analytics_people('owner')")).error?.code === "42501", "an owner cannot");
check((await as(db, plainStaff, "select public.app_analytics_people('owner')")).error?.code === "42501", "nor staff without dashboards");
check(!!(await as(db, anon, "select public.app_analytics_people('owner')")).error, "nor anyone signed out");
check(!!(await as(db, viewer, "select public.app_analytics_people('tenant')")).error, "owners or partners only");

console.log("\nthe people");
const owners = await J(db, viewer, "select public.app_analytics_people('owner')");
const p = owners?.[0];
check(owners?.length === 1 && p.name === "Priya Kumar" && p.phone === "9876500001" && p.status === "approved", "owners: Priya, with her details", JSON.stringify(owners));
check(p?.last_login && p.sessions === 1 && p.seconds === 300 && p.clicks === 4 && p.last_seen,
  "her last sign-in, one owner-app session of 5 minutes (not her main-site one), four taps", JSON.stringify(p));
const partners = await J(db, viewer, "select public.app_analytics_people('partner')");
check(partners?.length === 1 && partners[0].agency === "Bala Homes" && partners[0].seconds === 120 && partners[0].clicks === 2,
  "partners: Bala, his agency, two minutes, two taps", JSON.stringify(partners));

console.log("\none person's sessions");
const ses = await J(db, viewer, `select public.app_analytics_user('owner', '${O1}', 30)`);
check(ses?.length === 1 && ses[0].session_key === "session_owner_1" && ses[0].seconds === 300 && ses[0].device === "mobile",
  "Priya: her one owner-app session, its length and device", JSON.stringify(ses)?.slice(0, 200));
const labels = (ses?.[0]?.events ?? []).map((e) => e.label);
check(labels[0] === "/" && labels[1] === "Sign in with Google" && labels.includes("Add property") && labels.includes("Instant visit"),
  "every tap and screen in order, the ones before she signed in included", JSON.stringify(labels));
check((ses?.[0]?.events ?? []).every((e) => e.at), "each with its time");
check((await J(db, viewer, `select public.app_analytics_user('partner', '${O1}', 30)`))?.length === 0, "she has no partner-app sessions");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
