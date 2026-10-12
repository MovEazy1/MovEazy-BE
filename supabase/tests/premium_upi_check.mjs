/**
 * Apply partner_trial.sql then partner_premium_upi.sql (PGlite) over stand-ins
 * of the partner tables, and check: per-plan referral rewards (editable, kept
 * on re-apply), paying by UPI → UTR → the CRM approving or rejecting, the
 * referrer hearing of the sign-up and the reward, the 30-day countdown,
 * payout details, marking paid, and who may do what.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});
const read = (f) => readFileSync(new URL(`../${f}`, import.meta.url), "utf8");
const TRIAL = read("partner_trial.sql");
const SQL = read("partner_premium_upi.sql");
const SCHEMA = read("partner_schema.sql");
const ti = SCHEMA.indexOf("create or replace function public.partner_has_tier(p_tier text)");
const HAS_TIER = SCHEMA.slice(ti, SCHEMA.indexOf("$$;", ti) + 3);
const LAUNCH = read("partner_launch.sql");
const si = LAUNCH.indexOf("create or replace function public.partner_referrals_settle()");
const SETTLE = LAUNCH.slice(si, LAUNCH.indexOf("$$;", si) + 3);

let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};

const R = "a1111111-0000-0000-0000-000000000001"; // referrer, on Trial Premium
const N = "b2222222-0000-0000-0000-000000000002"; // joins with R's link, pays
const F = "c3333333-0000-0000-0000-000000000003"; // free partner
const M = "d4444444-0000-0000-0000-000000000004"; // pays with a UTR that's wrong

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
create table public.broker_partners (user_id uuid primary key, name text default '', phone text default '', email text default '',
  agency text default '', status text default 'approved', approved_at timestamptz, approved_by text default '', updated_at timestamptz,
  created_at timestamptz default now(), congrats_seen_at timestamptz, operational_areas text[] default '{}', rera_id text default '',
  profile_completed_at timestamptz, referral_code text unique, referred_by text not null default '', client_share_pct numeric);
create function public.is_approved_partner() returns boolean language sql stable security definer as $$
  select exists (select 1 from public.broker_partners where user_id = auth.uid() and status = 'approved') $$;
create table public.program_settings (id int primary key, lead_upi_id text default '8090911024@pthdfc');
insert into public.program_settings (id) values (1);
create table public.partner_plans (id text primary key, label text not null, months int not null, price int not null,
  refund_days int not null default 0, note text not null default '', sort int not null default 0, active boolean not null default true,
  payment_link text not null default '', updated_at timestamptz not null default now());
insert into public.partner_plans (id, label, months, price, refund_days, sort) values
  ('trial_1m', '1 month', 1, 1500, 0, 1), ('pro_5m', '5 months', 5, 4999, 30, 2), ('pro_12m', '12 months', 12, 9999, 30, 3);
create table public.partner_payments (id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users (id),
  plan_id text not null references public.partner_plans (id), amount int not null, months int not null,
  status text not null default 'started' check (status in ('started', 'paid', 'approved', 'rejected', 'refunded')),
  link_id text not null default '', link_url text not null default '', gateway_payment_id text not null default '', entitlement_id uuid,
  note text not null default '', decided_by text not null default '', created_at timestamptz not null default now(),
  paid_at timestamptz, decided_at timestamptz);
create table public.partner_funnel_events (user_id uuid, phone text, event text, meta jsonb);
create table public.partner_referrals (id uuid primary key default gen_random_uuid(), referrer_id uuid not null references auth.users (id),
  referee_id uuid not null unique references auth.users (id), payment_id uuid references public.partner_payments (id) on delete set null,
  plan_id text not null default '', amount int not null default 1500,
  status text not null default 'pending' check (status in ('pending', 'earned', 'paid', 'void')),
  earn_after timestamptz not null, created_at timestamptz not null default now(), paid_at timestamptz, paid_by text not null default '');
${SETTLE}
create table public.partner_notifications (id bigint generated always as identity primary key, broker_id uuid, kind text
  constraint partner_notifications_kind_check check (kind in ('tenant_liked', 'list_done', 'visit_reminder')),
  title text, body text default '', link text default '', created_at timestamptz default now(), read_at timestamptz);
create table public.partner_listings (broker_id uuid);
create table public.partner_group_members (user_id uuid);

insert into auth.users values ('${R}'), ('${N}'), ('${F}'), ('${M}');
insert into public.broker_partners (user_id, name, email, phone) values
  ('${R}', 'Rita', 'rita@x.com', '9800000001'), ('${F}', 'Firoz', 'firoz@x.com', '9800000003'), ('${M}', 'Manu', 'manu@x.com', '9800000004');
`);
await db.exec(TRIAL);
await db.exec(SQL);
check(true, "partner_premium_upi.sql applies after partner_trial.sql");

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
const rita = { uid: R, email: "rita@x.com" }, neel = { uid: N, email: "neel@x.com" }, firoz = { uid: F }, manu = { uid: M };
const notes = async (uid, kind) => (await db.query(`select * from public.partner_notifications where broker_id = '${uid}' and kind = '${kind}' order by id`)).rows;

console.log("\nplans and rewards");
let plans = Object.fromEntries((await db.query("select id, referral_reward from public.partner_plans")).rows.map((p) => [p.id, p.referral_reward]));
check(plans.trial_1m === 500 && plans.pro_5m === 1500 && plans.pro_12m === 3000, "rewards start at ₹500 / ₹1,500 / ₹3,000", JSON.stringify(plans));
let r = await as(admin, "select public.crm_set_plan_reward('pro_12m', 3500)");
check(!r.error, "the CRM edits a reward", r.error?.message);
await db.exec(SQL);
plans = Object.fromEntries((await db.query("select id, referral_reward from public.partner_plans")).rows.map((p) => [p.id, p.referral_reward]));
check(plans.pro_12m === 3500, "re-applying keeps the CRM's edit", JSON.stringify(plans));
await as(admin, "select public.crm_set_plan_reward('pro_12m', 3000)");
r = await as(agent, "select public.crm_set_plan_reward('pro_12m', 1)");
check(/Not allowed/.test(r.error?.message ?? ""), "staff without partners.manage can't", r.error?.message);
r = await as(neel, "select public.partner_plans_list()");
check(one(r)?.find((p) => p.id === "pro_5m")?.referral_reward === 1500, "the plans list carries each reward");

console.log("\nwho gets a link");
await as(admin, "select public.crm_trial_add($1)", [["rita@x.com"]]);
r = await as(rita, "select public.partner_referral_code()");
const code = one(r);
check(/^[A-Z2-9]{6}$/.test(code ?? ""), "a Trial Premium partner gets a referral code", r.error?.message ?? code);
r = await as(firoz, "select public.partner_referral_code()");
check(/comes with Premium/.test(r.error?.message ?? ""), "a free partner doesn't", r.error?.message);

console.log("\na broker joins with the link");
await db.exec(`insert into public.broker_partners (user_id, name, email, phone) values ('${N}', '', 'neel@x.com', '9800000002');
  update public.broker_partners set name = 'Neel', referred_by = '${code}' where user_id = '${N}';`);
let n = await notes(R, "referral");
check(n.length === 1 && n[0].title === "Neel joined with your link" && /up to ₹3,000/.test(n[0].body), "the referrer hears at once", JSON.stringify(n));
r = await as(rita, "select public.partner_my_referrals()");
let my = one(r);
check(my?.joined?.[0]?.name === "Neel" && my.joined[0].status === "signed_up", "and sees them on Refer & Earn", JSON.stringify(my?.joined));
check(my?.rewards?.map((x) => x.reward).join(",") === "500,1500,3000", "with the reward for each plan", JSON.stringify(my?.rewards));

console.log("\npaying by UPI");
r = await as(neel, "select public.partner_plan_pay_upi('pro_5m')");
const pay = one(r);
check(pay?.amount === 4999 && pay.upi_id === "8090911024@pthdfc", "a payment for ₹4,999, to MovEazy's UPI ID", r.error?.message ?? JSON.stringify(pay));
r = await as(neel, "select public.partner_plan_submit_utr($1, 'abc')", [pay.id]);
check(/UTR/.test(r.error?.message ?? ""), "a junk UTR is refused", r.error?.message);
r = await as(neel, "select public.partner_plan_submit_utr($1, ' 4123 4567 8901 ')", [pay.id]);
check(one(r)?.status === "payment_check", "the UTR goes in for checking", r.error?.message);
r = await as(neel, "select public.partner_plan_pay_upi('pro_12m')");
check(/being checked/.test(r.error?.message ?? ""), "no second payment while one is being checked", r.error?.message);
r = await as(manu, "select public.partner_plan_pay_upi('trial_1m')");
const mpay = one(r);
r = await as(manu, "select public.partner_plan_submit_utr($1, '412345678901')", [mpay.id]);
check(/already been used/.test(r.error?.message ?? ""), "the same UTR can't be used twice", r.error?.message);
r = await as(firoz, "select public.partner_plan_submit_utr($1, '999999999999')", [pay.id]);
check(/not yours/.test(r.error?.message ?? ""), "nobody can send a UTR for someone else's payment", r.error?.message);
r = await as(neel, "select public.partner_has_tier('moveazy_inventory')");
check(one(r) === false, "Premium doesn't start before the CRM checks");

console.log("\nthe CRM checks it");
r = await as(agent, "select public.crm_premium_payments()");
check(/Not allowed/.test(r.error?.message ?? ""), "staff without partners.manage can't see the list", r.error?.message);
r = await as(admin, "select public.crm_premium_payments()");
let list = one(r);
check(list?.todo?.length === 1 && list.todo[0].utr === "412345678901" && list.todo[0].plan === "5 months" && list.todo[0].referred_by === "Rita",
  "the payment to check: who, plan, amount, UTR, referred by", JSON.stringify(list?.todo));
r = await as(agent, "select public.crm_premium_payment_decide($1, true)", [pay.id]);
check(Boolean(r.error), "only partners.manage approves");
r = await as(admin, "select public.crm_premium_payment_decide($1, true)", [pay.id]);
check(one(r) === "approved", "approved", r.error?.message);
const paidCheck = await as(neel, "select public.partner_has_tier('moveazy_inventory')");
check(one(paidCheck) === true, "Premium starts for the new partner");
const ent = (await db.query(`select * from public.partner_entitlements where user_id = '${N}'`)).rows[0];
check(ent?.plan === "pro_5m" && ent.source === "upi", "a 5-month plan, from UPI");
check((await notes(N, "plan_approved")).length === 1, "and they're told");
r = await as(admin, "select public.crm_premium_payment_decide($1, true)", [pay.id]);
check(/Already decided/.test(r.error?.message ?? ""), "a payment is decided once", r.error?.message);

console.log("\nthe referrer's reward");
let ref = (await db.query(`select * from public.partner_referrals where referee_id = '${N}'`)).rows[0];
const days = (new Date(ref?.earn_after).getTime() - Date.now()) / 86400000;
check(ref?.amount === 1500 && ref.status === "pending" && days > 29.9 && days < 30.1, "₹1,500 for the ₹4,999 plan, redeemable in 30 days", JSON.stringify(ref));
n = await notes(R, "referral");
check(n.length === 2 && n[1].title === "₹1,500 on the way" && /Redeemable in 30 days/.test(n[1].body), "the referrer is told", JSON.stringify(n[1]));
r = await as(rita, "select public.partner_my_referrals()");
my = one(r);
check(my.joined[0].status === "pending" && my.joined[0].amount === 1500 && my.joined[0].days_left === 30 && my.pending === 1500,
  "Refer & Earn: ₹1,500, 30 days to go", JSON.stringify(my.joined[0]));

console.log("\nwhere the money goes");
r = await as(rita, "select public.partner_set_payout('', '', '', '')");
check(/UPI ID or a bank account/.test(r.error?.message ?? ""), "nothing given is refused", r.error?.message);
r = await as(rita, "select public.partner_set_payout('not a upi')");
check(/UPI ID/.test(r.error?.message ?? ""), "a bad UPI ID is refused", r.error?.message);
r = await as(rita, "select public.partner_set_payout('', 'Rita K', '12345', 'HDFC0001234')");
check(/6 to 18 digits/.test(r.error?.message ?? ""), "a short account number is refused", r.error?.message);
r = await as(rita, "select public.partner_set_payout('', 'Rita K', '50100123456789', 'hdfc0001234')");
check(!r.error, "a bank account is saved", r.error?.message);
my = one(await as(rita, "select public.partner_my_referrals()"));
check(my.payout.bank_last4 === "6789" && my.payout.ifsc === "HDFC0001234" && my.payout.bank_name === "Rita K", "shown back masked", JSON.stringify(my.payout));
await as(rita, "select public.partner_set_payout('Rita@okhdfc')");
my = one(await as(rita, "select public.partner_my_referrals()"));
check(my.payout.upi === "rita@okhdfc" && my.payout.bank_last4 === "", "or a UPI ID instead", JSON.stringify(my.payout));

console.log("\npaying it out");
r = await as(admin, "select public.crm_referral_payouts()");
let po = one(r);
check(po?.length === 1 && po[0].status === "pending" && po[0].referrer === "Rita" && po[0].referee === "Neel" && po[0].upi === "rita@okhdfc",
  "the CRM sees it coming, with where to pay", JSON.stringify(po));
r = await as(admin, "select public.crm_referral_mark_paid($1)", [ref.id]);
check(/past its 30 days/.test(r.error?.message ?? ""), "not payable before the 30 days", r.error?.message);
await db.exec(`update public.partner_referrals set earn_after = now() - interval '1 minute' where id = '${ref.id}'`);
po = one(await as(admin, "select public.crm_referral_payouts()"));
check(po[0].status === "earned", "after 30 days, uncancelled: due");
r = await as(agent, "select public.crm_referral_mark_paid($1)", [ref.id]);
check(Boolean(r.error), "only partners.manage marks it paid");
r = await as(admin, "select public.crm_referral_mark_paid($1)", [ref.id]);
check(!r.error, "marked paid", r.error?.message);
n = await notes(R, "referral");
check(n.length === 3 && n[2].title === "₹1,500 sent to you", "and the referrer is told", JSON.stringify(n[2]));
my = one(await as(rita, "select public.partner_my_referrals()"));
check(my.paid === 1500 && my.pending === 0 && my.joined[0].status === "paid", "Refer & Earn shows it paid");

console.log("\na renewal, and a rejected UTR");
r = await as(neel, "select public.partner_plan_pay_upi('pro_12m')");
const p2 = one(r);
await as(neel, "select public.partner_plan_submit_utr($1, 'RENEW000001')", [p2.id]);
await as(admin, "select public.crm_premium_payment_decide($1, true)", [p2.id]);
check((await db.query(`select count(*)::int n from public.partner_referrals where referee_id = '${N}'`)).rows[0].n === 1, "a renewal doesn't earn again");
await as(manu, "select public.partner_plan_submit_utr($1, 'WRONG0000001')", [mpay.id]);
r = await as(admin, "select public.crm_premium_payment_decide($1, false, 'Not in our bank statement')", [mpay.id]);
check(one(r) === "rejected", "the CRM rejects a UTR it can't find", r.error?.message);
n = await notes(M, "plan_rejected");
check(n.length === 1 && /WRONG0000001 — Not in our bank statement/.test(n[0].body), "the partner is told why");
r = await as(manu, "select public.partner_has_tier('moveazy_inventory')");
check(one(r) === false, "no Premium");
list = one(await as(admin, "select public.crm_premium_payments()"));
check(list.todo.length === 0 && list.done.length === 3, "the CRM's list moves them to done", JSON.stringify(list.done.map((d) => d.status)));

console.log("\nsigned out");
for (const f of ["public.partner_plan_pay_upi('pro_5m')", "public.crm_premium_payments()", "public.partner_my_referrals()", "public.crm_referral_payouts()"]) {
  r = await as({ role: "anon" }, `select ${f}`);
  check(Boolean(r.error), `anon can't call ${f.split("(")[0]}`);
}

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
