/**
 * Apply partner_trial.sql (PGlite) over stand-ins of the partner tables and
 * check Trial Premium end to end: adding by email (signed up or not yet),
 * starting on sign-up, days left / +10 / +20 / end, the partner's pop-ups,
 * Premium features on but paid-only leads off, and paid Premium taking over
 * with the unused days kept.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});
const read = (f) => readFileSync(new URL(`../${f}`, import.meta.url), "utf8");
const SQL = read("partner_trial.sql");
const LEADS = read("partner_moveazy_leads.sql");
const pi = LEADS.indexOf("create or replace function public.partner_has_paid_premium()");
const PAID = LEADS.slice(pi, LEADS.indexOf("$$;", pi) + 3);
const SCHEMA = read("partner_schema.sql");
const ti = SCHEMA.indexOf("create or replace function public.partner_has_tier(p_tier text)");
const HAS_TIER = SCHEMA.slice(ti, SCHEMA.indexOf("$$;", ti) + 3);

let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};

const A = "a1111111-0000-0000-0000-000000000001"; // signed up, pending
const B = "b2222222-0000-0000-0000-000000000002"; // signs up later
const C = "c3333333-0000-0000-0000-000000000003"; // signs up later, days set first
const P = "d4444444-0000-0000-0000-000000000004"; // already paying

const db = new PGlite();
await db.exec(`
create role anon; create role authenticated;
grant usage on schema public to anon, authenticated;
create schema auth; grant usage on schema auth to anon, authenticated;
create table auth.users (id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
create function auth.jwt() returns jsonb language sql stable as $$ select jsonb_build_object('email', current_setting('test.email', true)) $$;
create function public.is_crm_staff() returns boolean language sql stable as $$ select current_setting('test.staff', true) = 'on' $$;
create function public.has_admin_scope(s text) returns boolean language sql stable as $$
  select current_setting('test.staff', true) = 'on' and s = any (string_to_array(coalesce(current_setting('test.scopes', true), ''), ',')) $$;
create table public.partner_tiers (tier text primary key, is_free boolean not null default false);
insert into public.partner_tiers values ('moveazy_inventory', false);
create table public.partner_entitlements (id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users (id),
  tier text not null references public.partner_tiers (tier), plan text not null default 'monthly', starts_at timestamptz not null default now(),
  ends_at timestamptz not null, source text not null default 'manual', source_ref text not null default '', granted_by text not null default '',
  created_at timestamptz not null default now(), check (ends_at > starts_at));
${HAS_TIER}
${PAID}
create table public.broker_partners (user_id uuid primary key, name text default '', phone text default '', email text default '',
  agency text default '', status text default 'pending', approved_at timestamptz, approved_by text default '', updated_at timestamptz,
  created_at timestamptz default now(), congrats_seen_at timestamptz, operational_areas text[] default '{}', rera_id text default '',
  profile_completed_at timestamptz, referral_code text, referred_by text, client_share_pct numeric);
create table public.partner_plans (id text primary key, label text);
insert into public.partner_plans values ('pro_5m', '5 months'), ('trial_1m', '1 month trial');
create table public.partner_payments (id uuid primary key default gen_random_uuid(), user_id uuid, plan_id text, amount int, months int,
  status text default 'pending', paid_at timestamptz, decided_at timestamptz, decided_by text default '', gateway_payment_id text default '',
  entitlement_id uuid, note text default '', link_id text default '', created_at timestamptz default now());
create table public.partner_funnel_events (user_id uuid, phone text, event text, meta jsonb);
create table public.partner_referrals (referrer_id uuid, referee_id uuid unique, payment_id uuid, plan_id text, earn_after timestamptz);
create table public.partner_listings (broker_id uuid);
create table public.partner_group_members (user_id uuid);

insert into auth.users values ('${A}'), ('${B}'), ('${C}'), ('${P}');
insert into public.broker_partners (user_id, name, email, status) values ('${A}', 'Asha', 'asha@x.com', 'pending'), ('${P}', 'Payal', 'payal@x.com', 'approved');
insert into public.partner_entitlements (user_id, tier, plan, ends_at) values ('${P}', 'moveazy_inventory', 'pro_5m', now() + interval '60 days');
`);
await db.exec(SQL);
await db.exec(SQL);
check(true, "partner_trial.sql applies, and re-applies over itself");

async function as(who, sql, params = []) {
  await db.exec(`reset role; select set_config('test.uid', '${who.uid ?? ""}', false), set_config('test.email', '${who.email ?? ""}', false),
    set_config('test.staff', '${who.staff ? "on" : ""}', false), set_config('test.scopes', '${(who.scopes ?? []).join(",")}', false);
    set role ${who.role ?? "authenticated"};`);
  try { return { rows: (await db.query(sql, params)).rows, error: null }; }
  catch (e) { return { rows: null, error: e }; }
  finally { await db.exec("reset role"); }
}
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const admin = { uid: "e0000000-0000-0000-0000-000000000001", email: "ops@moveazy.co.in", staff: true, scopes: ["partners.manage"] };
const agent = { uid: "e0000000-0000-0000-0000-000000000002", email: "agent@moveazy.co.in", staff: true };
const asha = { uid: A, email: "asha@x.com" }, bina = { uid: B, email: "bina@x.com" }, payal = { uid: P };
const list = async () => Object.fromEntries((one(await as(admin, "select public.crm_trial_list()")) ?? []).map((t) => [t.email, t]));
const status = async (who) => one(await as(who, "select public.partner_status()"));
const days = (ts) => (new Date(ts).getTime() - Date.now()) / 86400000;

console.log("\nadding by email");
let r = await as(admin, "select public.crm_trial_add($1)", [["Asha@X.com ", "bina@x.com", "not-an-email", "asha@x.com", "", "payal@x.com"]]);
let res = one(r);
check(res?.added === 3 && res.started === 1 && res.skipped.length === 2, "3 added (1 started at once), a bad one and a repeat skipped", r.error?.message ?? JSON.stringify(res));
check(res?.skipped.some((s) => /already on the list/.test(s.why)) && res.skipped.some((s) => /not an email/.test(s.why)), "…saying why");
let t = await list();
check(t["asha@x.com"]?.status === "active" && t["asha@x.com"].days_left === 30 && t["asha@x.com"].name === "Asha", "a signed-up broker: active, 30 days left", JSON.stringify(t["asha@x.com"]));
check(t["bina@x.com"]?.status === "invited" && t["bina@x.com"].days_left === 30, "not signed up yet: invited, 30 days waiting", JSON.stringify(t["bina@x.com"]));
check(t["payal@x.com"]?.status === "paid", "already paying: shown as paid, no trial");
let bp = (await db.query(`select status, approved_by from public.broker_partners where user_id = '${A}'`)).rows[0];
check(bp.status === "approved" && bp.approved_by === "trial", "a pending broker on the list is approved");
r = await as(asha, "select public.partner_has_tier('moveazy_inventory') t, public.partner_has_paid_premium() p");
check(r.rows?.[0]?.t === true && r.rows[0].p === false, "the trial unlocks Premium features, but not paid-only leads", JSON.stringify(r.rows));

console.log("\nsigning up later");
await db.exec(`insert into public.broker_partners (user_id, name, email, status) values ('${B}', 'Bina', 'Bina@X.com', 'pending')`);
t = await list();
check(t["bina@x.com"]?.status === "active" && t["bina@x.com"].days_left === 30 && t["bina@x.com"].name === "Bina", "their trial starts the moment they sign up", JSON.stringify(t["bina@x.com"]));
bp = (await db.query(`select status from public.broker_partners where user_id = '${B}'`)).rows[0];
check(bp.status === "approved", "and they're approved");
await as(admin, "select public.crm_trial_add($1)", [["chetan@x.com"]]);
await as(admin, "select public.crm_trial_set_days('chetan@x.com', 15)");
await as(admin, "select public.crm_trial_add_days('chetan@x.com', 10)");
check((await list())["chetan@x.com"].days_left === 25, "an invite's days can be set and added to before they join");
r = await as(admin, "select public.crm_trial_set_days('chetan@x.com', 0)");
check(/at least 1 day/.test(r.error?.message ?? ""), "an invite can't be set to 0 days", r.error?.message);
await db.exec(`insert into public.broker_partners (user_id, name, email) values ('${C}', 'Chetan', 'chetan@x.com')`);
t = await list();
check(t["chetan@x.com"].status === "active" && t["chetan@x.com"].days_left === 25, "…and start with them", JSON.stringify(t["chetan@x.com"]));

console.log("\nthe partner's pop-ups");
let s = await status(asha);
check(s?.trial?.active && s.trial.days_left === 30 && s.trial.welcome_due && s.trial.extended_days === 0, "welcome due, 30 days left", JSON.stringify(s?.trial));
check(s?.plan?.active === false && s.congrats_due === false, "not a paid plan — the paid congratulations page stays away");
await as(asha, "select public.partner_trial_seen('welcome')");
check((await status(asha)).trial.welcome_due === false, "welcome shown once");
await as(admin, "select public.crm_trial_add_days('asha@x.com', 10)");
await as(admin, "select public.crm_trial_add_days('asha@x.com', 20)");
s = await status(asha);
check(s.trial.days_left === 60 && s.trial.extended_days === 30, "+10 then +20: 60 days left, one pop-up for 30", JSON.stringify(s.trial));
await as(asha, "select public.partner_trial_seen('extended')");
check((await status(asha)).trial.extended_days === 0, "extension shown once");
await as(admin, "select public.crm_trial_set_days('asha@x.com', 5)");
s = await status(asha);
check(s.trial.days_left === 5 && s.trial.extended_days === 0, "lowering the days: no pop-up", JSON.stringify(s.trial));
await as(admin, "select public.crm_trial_set_days('asha@x.com', 12)");
s = await status(asha);
check(s.trial.days_left === 12 && s.trial.extended_days === 7, "raising them by typing a number: the gain shows", JSON.stringify(s.trial));
await as(asha, "select public.partner_trial_seen('extended')");

console.log("\nending");
await as(admin, "select public.crm_trial_end('asha@x.com')");
s = await status(asha);
check(s.trial.active === false && s.trial.ended_due === true && s.trial.days_left === 0, "ended: the ended pop-up is due", JSON.stringify(s.trial));
r = await as(asha, "select public.partner_has_tier('moveazy_inventory')");
check(one(r) === false, "and Premium features are off");
check((await list())["asha@x.com"].status === "ended", "the CRM shows it ended");
await as(asha, "select public.partner_trial_seen('ended')");
check((await status(asha)).trial.ended_due === false, "the ended pop-up shows once");
await as(admin, "select public.crm_trial_add_days('asha@x.com', 10)");
s = await status(asha);
check(s.trial.active && s.trial.days_left === 10 && s.trial.extended_days === 10 && !s.trial.ended_due, "+10 after it ended: back on for 10 days, and told so", JSON.stringify(s.trial));
await as(asha, "select public.partner_trial_seen('extended')");

console.log("\npaying during the trial");
await db.exec(`insert into public.partner_payments (id, user_id, plan_id, amount, months) values ('f0000000-0000-0000-0000-000000000001', '${A}', 'pro_5m', 4999, 1)`);
await db.exec(`select public.partner_activate_payment('f0000000-0000-0000-0000-000000000001', 'manual', '', 'ops@moveazy.co.in')`);
const paid = (await db.query(`select * from public.partner_entitlements where user_id = '${A}' and plan = 'pro_5m'`)).rows[0];
const span = days(paid.ends_at);
check(span > 39 && span < 42, "paid Premium starts now, with the 10 unused trial days added on (1 month + 10 days)", span.toFixed(2));
r = await as(asha, "select public.partner_has_paid_premium()");
check(one(r) === true, "unlimited leads unlock");
s = await status(asha);
check(s.plan.active && s.trial.active === false && s.trial.ended_due === false && s.congrats_due === true,
  "the app now shows the paid plan (and its congratulations), not an ended trial", JSON.stringify(s));
check((await list())["asha@x.com"].status === "paid", "the CRM shows paid");
r = await as(admin, "select public.crm_trial_add_days('asha@x.com', 10)");
check(/paid Premium/.test(r.error?.message ?? ""), "a converted trial can't be extended", r.error?.message);

await as(admin, "select public.partner_admin_grant_tier($1, 'moveazy_inventory', 1)", [B]);
const manual = (await db.query(`select * from public.partner_entitlements where user_id = '${B}' and plan = 'monthly'`)).rows[0];
const span2 = days(manual.ends_at);
check(span2 > 58 && span2 < 62, "the CRM's 'Give Premium' also keeps the 30 unused trial days", span2.toFixed(2));
check((await list())["bina@x.com"].status === "paid", "and ends the trial");

console.log("\nthe CRM's partner list");
r = await as(admin, "select user_id, premium_until, trial_until from public.partner_admin_list()");
const rows = Object.fromEntries(r.rows.map((x) => [x.user_id, x]));
check(rows[C].trial_until && !rows[C].premium_until, "a trial partner: trial date, no paid date", JSON.stringify(rows[C]));
check(rows[A].premium_until && !rows[A].trial_until, "a paying one: paid date only", JSON.stringify(rows[A]));

console.log("\nwho may");
r = await as(agent, "select public.crm_trial_list()");
check(/Not allowed/.test(r.error?.message ?? ""), "staff without partners.manage can't see the list", r.error?.message);
r = await as(asha, "select public.crm_trial_add($1)", [["x@y.com"]]);
check(Boolean(r.error), "a partner can't add anyone");
r = await as({ role: "anon" }, "select public.crm_trial_list()");
check(Boolean(r.error), "nor can anyone signed out");
r = await as(asha, "select * from public.partner_trials");
check(Boolean(r.error), "the table itself isn't readable");
await as(admin, "select public.crm_trial_add($1)", [["dev@x.com"]]);
await as(admin, "select public.crm_trial_end('dev@x.com')");
check(!(await list())["dev@x.com"], "ending an invite that never started removes it");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
