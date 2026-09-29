/**
 * partner_launch.sql § 2–7 on a real Postgres (PGlite): leads, plans and
 * payments, the Razorpay activation, super-admin decisions, referrals,
 * profile completion, partner_status() and the sales funnel.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});

const file = (name) =>
  readFileSync(new URL(`../${name}`, import.meta.url), "utf8")
    .replace(/create extension if not exists "pgcrypto";/g, "");

const A = "aaaaaaaa-0000-0000-0000-000000000001"; // referrer
const B = "bbbbbbbb-0000-0000-0000-000000000002"; // referred broker
const C = "cccccccc-0000-0000-0000-000000000003"; // another broker
const T = "dddddddd-0000-0000-0000-000000000004"; // tenant
const S = "eeeeeeee-0000-0000-0000-000000000005"; // CRM staff
const X = "ffffffff-0000-0000-0000-000000000006"; // super admin

const partnerCheck = readFileSync(new URL("./partner_check.mjs", import.meta.url), "utf8");
const PRELUDE = partnerCheck.split("const PRELUDE = `")[1].split("`;")[0];
const CRM_INVENTORY = partnerCheck.split("const CRM_INVENTORY = `")[1].split("`;")[0];

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
           set_config('test.super', '${who.super ? "on" : ""}', false),
           set_config('test.scopes', '', false);
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
const denied = (r) => r.error?.code === "42501";
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const J = async (db, who, sql) => one(await as(db, who, sql));

const anon = { role: "anon" };
const a = { uid: A, email: "a@broker.in" };
const b = { uid: B, email: "b@broker.in" };
const c = { uid: C, email: "c@broker.in" };
const tenant = { uid: T, email: "tenant@example.com" };
const staff = { uid: S, email: "agent@moveazy.co.in", staff: true };
const boss = { uid: X, email: "yatharth200018@gmail.com", staff: true, super: true };

const db = new PGlite();
await db.exec(PRELUDE.replace(/\\\\/g, "\\"));
await db.exec(file("inventory_schema.sql"));
await db.exec(CRM_INVENTORY);
await db.exec(file("inventory_public_columns.sql"));
await db.exec(file("crm_property_internal.sql"));
await db.exec(file("inventory_private_read.sql"));
await db.exec(file("program_settings.sql"));
await db.exec(file("partner_schema.sql"));
await db.exec(file("partner_storefront.sql"));
await db.exec("create role service_role");
await db.exec(`
insert into auth.users (id, email) values
  ('${A}', 'a@broker.in'), ('${B}', 'b@broker.in'), ('${C}', 'c@broker.in'), ('${T}', 'tenant@example.com'),
  ('${S}', 'agent@moveazy.co.in'), ('${X}', 'yatharth200018@gmail.com');
insert into public.user_profiles (id, email, name, phone) values
  ('${A}', 'a@broker.in', 'Asha', '9876500001'), ('${B}', 'b@broker.in', 'Bala', '9876500002'),
  ('${C}', 'c@broker.in', 'Chetan', '9876500003'), ('${T}', 'tenant@example.com', 'Tara', '');
`);
await db.exec(file("partner_launch.sql"));
await db.exec(file("partner_launch.sql"));
check(true, "partner_launch.sql applies, and re-applies over itself");
for (const who of [a, b, c]) await as(db, who, "select public.partner_register(null, null)");

console.log("\n§ 2 leads");
const lead = await as(db, a, "insert into public.partner_leads (name, phone, household, gender_pref) values ('', '9876511111', 'family', 'coed') returning household, gender_pref");
check(!lead.error && lead.rows[0].household === "family", "a lead with only a mobile, a family, co-ed", lead.error?.message);
check(!!(await as(db, a, "insert into public.partner_leads (name, phone) values ('Ravi', '')")).error, "no mobile: refused");
check(!!(await as(db, a, "insert into public.partner_leads (phone, household) values ('9876511112', 'couple')")).error, "an unknown household: refused");

console.log("\n§ 3 plans and payment");
const plans = await J(db, b, "select public.partner_plans_list()");
check(plans?.map((p) => `${p.id}:${p.price}`).join() === "trial_1m:1500,pro_5m:4999,pro_12m:9999", "three plans: ₹1,500 · ₹4,999 · ₹9,999", JSON.stringify(plans));
check(denied(await as(db, tenant, "select public.partner_payment_start('pro_5m')")), "a tenant cannot start a payment");
check(!!(await as(db, b, "select public.partner_payment_start('gold')")).error, "an unknown plan: refused");
const pay = await J(db, b, "select public.partner_payment_start('pro_5m')");
check(pay?.amount === 4999 && pay?.months === 5, "Pay pressed: the attempt is recorded with the plan", JSON.stringify(pay));
check(Number(await J(db, staff, "select count(*) from public.partner_funnel_events where event = 'payment_tried' and meta ->> 'plan' = 'pro_5m'")) === 1, "…and 'payment tried (pro_5m)' is in the funnel");
check((await J(db, b, "select public.partner_status() -> 'plan' ->> 'active'")) === "false", "not active until it is paid");

// Razorpay: the webhook's call, as the service role.
await db.exec(`update public.partner_payments set link_id = 'plink_1' where id = '${pay.id}'`);
check(!!(await as(db, b, `select public.partner_razorpay_paid('${pay.id}', 'plink_1', 'pay_1', 499900)`)).error, "a broker cannot call the webhook's function");
const short = await J(db, { role: "service_role" }, `select public.partner_razorpay_paid('${pay.id}', 'plink_1', 'pay_1', 100)`);
check(short?.ok === false, "too little paid: not activated", JSON.stringify(short));
const wrong = await J(db, { role: "service_role" }, `select public.partner_razorpay_paid('${pay.id}', 'plink_OTHER', 'pay_1', 499900)`);
check(wrong?.ok === false, "a different link: not activated");
const ok = await J(db, { role: "service_role" }, `select public.partner_razorpay_paid('${pay.id}', 'plink_1', 'pay_1', 499900)`);
check(ok?.ok === true && ok.status === "paid", "the right link, the full amount: paid", JSON.stringify(ok));
await J(db, { role: "service_role" }, `select public.partner_razorpay_paid('${pay.id}', 'plink_1', 'pay_1', 499900)`);
check(Number(await J(db, staff, `select count(*) from public.partner_entitlements where user_id = '${B}'`)) === 1, "a repeated webhook changes nothing (one entitlement)");
const st = await J(db, b, "select public.partner_status()");
check(st?.plan?.active === true && st.plan.plan_id === "pro_5m", "the plan is active", JSON.stringify(st?.plan));
const months = Number(await J(db, staff, `select round(extract(epoch from (ends_at - starts_at)) / 86400) from public.partner_entitlements where user_id = '${B}'`));
check(months >= 150 && months <= 153, "for five months", String(months));
check(st?.congrats_due === true, "congratulations are due");
await as(db, b, "select public.partner_congrats_seen()");
check((await J(db, b, "select public.partner_status() ->> 'congrats_due'")) === "false", "…once");

// A second plan stacks after the first.
const pay2 = await J(db, b, "select public.partner_payment_start('trial_1m')");
await J(db, { role: "service_role" }, `select public.partner_razorpay_paid('${pay2.id}', '', 'pay_2', 150000)`);
const stack = await J(db, staff, `select (select min(starts_at) from public.partner_entitlements e2 where e2.user_id = '${B}' and e2.plan = 'trial_1m') >= (select max(ends_at) - interval '1 minute' from public.partner_entitlements e3 where e3.user_id = '${B}' and e3.plan = 'pro_5m')`);
check(stack === true, "a second plan starts when the first ends");

console.log("\n§ 3 the super admin");
const payC = await J(db, c, "select public.partner_payment_start('trial_1m')");
check(denied(await as(db, staff, `select public.partner_admin_payment_decide('${payC.id}', true)`)), "CRM staff cannot approve a payment");
check(denied(await as(db, c, `select public.partner_admin_payment_decide('${payC.id}', true)`)), "nor can the broker");
const appr = await J(db, boss, `select (public.partner_admin_payment_decide('${payC.id}', true, 'paid by UPI')).status`);
check(appr === "approved", "the super admin approves it by hand", String(appr));
check((await J(db, c, "select public.partner_status() -> 'plan' ->> 'active'")) === "true", "…and the plan is active");
const rej = await J(db, boss, `select (public.partner_admin_payment_decide('${payC.id}', false, 'refund asked')).status`);
check(rej === "refunded", "and can refund it", String(rej));
check((await J(db, c, "select public.partner_status() -> 'plan' ->> 'active'")) === "false", "…which ends the plan now");

console.log("\n§ 4 referrals");
const codeA = await J(db, a, "select public.partner_referral_code()");
check(/^[A-HJ-NP-Z2-9]{6}$/.test(codeA || ""), "a partner gets a referral code", codeA);
check((await J(db, a, "select public.partner_referral_code()")) === codeA, "the same one every time");
// D joins with A's code and pays.
const D = "12345678-0000-0000-0000-000000000007";
const d = { uid: D, email: "d@broker.in" };
await db.exec(`insert into auth.users values ('${D}', 'd@broker.in'); insert into public.user_profiles values ('${D}', 'd@broker.in', 'Dev', '9876500007');`);
await as(db, anon, `select public.partner_prospect('9876500007', 'referral', '${codeA.toLowerCase()}', '{}')`);
await as(db, d, "select public.partner_register(null, null)");
await as(db, d, "select public.partner_signup_meta('direct', '', '{}')");
let mine = await J(db, a, "select public.partner_my_referrals()");
check(mine?.joined?.length === 1 && mine.joined[0].status === "signed_up", "the referrer sees the sign-up", JSON.stringify(mine?.joined));
const payD = await J(db, d, "select public.partner_payment_start('pro_12m')");
await J(db, { role: "service_role" }, `select public.partner_razorpay_paid('${payD.id}', '', 'pay_d', 999900)`);
mine = await J(db, a, "select public.partner_my_referrals()");
check(mine?.joined?.[0]?.status === "pending" && Number(mine.pending) === 1500, "a paid plan: ₹1,500 pending for a month", JSON.stringify(mine));
const refId = await J(db, staff, "select id from public.partner_referrals limit 1");
check(!!(await as(db, boss, `select public.partner_admin_referral_paid('${refId}')`)).error, "not payable while pending");
await db.exec("update public.partner_referrals set earn_after = now() - interval '1 day'");
mine = await J(db, a, "select public.partner_my_referrals()");
check(Number(mine?.earned) === 1500 && mine.joined[0].status === "earned", "after a month it's earned", JSON.stringify(mine));
check(denied(await as(db, staff, `select public.partner_admin_referral_paid('${refId}')`)), "only the super admin marks it paid");
await as(db, boss, `select public.partner_admin_referral_paid('${refId}')`);
check(Number((await J(db, a, "select public.partner_my_referrals()"))?.paid) === 1500, "paid");
// Self-referral earns nothing.
await db.exec(`update public.broker_partners set referred_by = '${codeA}' where user_id = '${A}'`);
const payA = await J(db, a, "select public.partner_payment_start('trial_1m')");
await J(db, { role: "service_role" }, `select public.partner_razorpay_paid('${payA.id}', '', 'pay_a', 150000)`);
check(Number(await J(db, staff, `select count(*) from public.partner_referrals where referee_id = '${A}'`)) === 0, "your own code earns you nothing");

console.log("\n§ 5 profile");
check(!!(await as(db, b, "select public.partner_complete_profile('{}', 'PRM/KA/RERA/1251/309/AG/180620/001234')")).error, "no areas: refused");
check(!!(await as(db, b, "select public.partner_complete_profile('{HSR Layout}', 'x')")).error, "no real RERA number: refused");
const prof = await as(db, b, "select public.partner_complete_profile('{HSR Layout, Koramangala , HSR Layout}', ' prm/ka/rera/1251/309/ag/180620/001234 ')");
check(!prof.error, "areas and RERA saved", prof.error?.message);
const p2 = await J(db, b, "select public.partner_status() -> 'profile'");
check(p2?.areas?.length === 2 && p2.rera_id === "PRM/KA/RERA/1251/309/AG/180620/001234" && p2.completed_at, "cleaned: two areas, RERA upper-cased", JSON.stringify(p2));

console.log("\n§ 7 the sales funnel");
check(denied(await as(db, b, "select public.partner_funnel()")), "a broker cannot read the funnel");
const fun = await J(db, staff, "select public.partner_funnel()");
check(fun?.brokers?.length === 4 && fun.can_decide === false, "CRM staff see every broker (and cannot decide payments)", String(fun?.brokers?.length));
const bRow = fun?.brokers?.find((x) => x.user_id === B);
check(bRow?.plan_active === true && bRow.payments.length === 2, "with their plan and every payment", JSON.stringify(bRow?.payments?.map((p) => p.status)));
check((await J(db, boss, "select public.partner_funnel() ->> 'can_decide'")) === "true", "the super admin can decide");
await as(db, anon, "select public.partner_prospect('9876599999', 'instagram')");
check((await J(db, staff, "select public.partner_funnel()"))?.prospects?.some((p) => p.phone === "9876599999"), "numbers left before Google are listed as prospects");
check(denied(await as(db, staff, "select public.partner_admin_set_plan('trial_1m', '1 month', 1999, 1, 0, '', '', true)")), "only the super admin edits plans");
check(!(await as(db, boss, "select public.partner_admin_set_plan('trial_1m', '1 month trial', 1999, 1, 0, 'x', 'https://rzp.io/l/abc', true)")).error, "the super admin can");
check((await J(db, b, "select public.partner_plans_list()"))?.[0]?.price === 1999, "…and the new price is what brokers see");

console.log("\n§ 3–7 access");
for (const t of ["partner_plans", "partner_payments", "partner_referrals"]) {
  check(denied(await as(db, anon, `select * from public.${t}`)), `anon: ${t} refused`);
}
check((await as(db, c, "select * from public.partner_payments")).rows?.every((r) => r.user_id === C), "a broker reads only their own payments");
check(!!(await as(db, b, `select public.partner_activate_payment('${payC.id}', 'manual', '', 'me')`)).error, "nobody activates a payment directly");

await db.close();
console.log(`\n${passed ? "ALL CHECKS PASS" : "SOMETHING FAILED"}`);
process.exit(passed ? 0 : 1);
