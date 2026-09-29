/**
 * Apply partner_launch.sql over the partner schema (PGlite, in-process) and
 * check the partners launch rules, section by section (see the file's header).
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

const A = "aaaaaaaa-0000-0000-0000-000000000001"; // partner before the launch
const B = "bbbbbbbb-0000-0000-0000-000000000002"; // new partner, came via "Become Partner"
const T = "dddddddd-0000-0000-0000-000000000004"; // tenant
const S = "eeeeeeee-0000-0000-0000-000000000005"; // CRM staff

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

const anon = { role: "anon" };
const a = { uid: A, email: "a@broker.in" };
const b = { uid: B, email: "b@broker.in" };
const tenant = { uid: T, email: "tenant@example.com" };
const staff = { uid: S, email: "agent@moveazy.co.in", staff: true };

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

await db.exec(`
insert into auth.users (id, email) values
  ('${A}', 'a@broker.in'), ('${B}', 'b@broker.in'), ('${T}', 'tenant@example.com'), ('${S}', 'agent@moveazy.co.in');
insert into public.user_profiles (id, email, name, phone) values
  ('${A}', 'a@broker.in', 'Asha', '9876500001'), ('${B}', 'b@broker.in', 'Bala', '9876500002'),
  ('${T}', 'tenant@example.com', 'Tara', '');
`);
// A partner who joined before the launch.
await as(db, a, "select public.partner_register('Asha', '')");

await db.exec(file("partner_launch.sql"));
await db.exec(file("partner_launch.sql"));
check(true, "partner_launch.sql applies, and re-applies over itself");

console.log("\n§ 1 sign-up funnel");
const pre = await db.query(`select event from public.partner_funnel_events where user_id = '${A}' order by event`);
check(pre.rows.map((r) => r.event).join() === "number_filled,signed_up", "a partner from before the launch is back-filled: number filled, signed up", JSON.stringify(pre.rows));
check(one(await db.query(`select signup_channel from public.broker_partners where user_id = '${A}'`)) === "direct", "…with channel 'direct'");

check(!!(await as(db, anon, "select public.partner_prospect('12345', 'direct')")).error, "a malformed number is refused");
const pr = await as(db, anon, `select public.partner_prospect('+91 98765 00002', 'referral', 'ab12cd', '{"utm_source":"whatsapp","utm_campaign":"launch<script>","junk":"x"}')`);
check(!pr.error, "anon can leave a number (the Become Partner sheet)", pr.error?.message);
await as(db, anon, "select public.partner_prospect('9876500002', 'instagram', 'zzz', '{}')");
const p = (await db.query("select * from public.partner_prospects")).rows[0];
check(p?.phone === "9876500002" && p.channel === "referral" && p.referred_by === "AB12CD", "stored normalised; the first channel and referral code stick", JSON.stringify(p));
check(JSON.stringify(p?.utm) === '{"utm_source":"whatsapp","utm_campaign":"launchscript"}', "UTM keeps only utm_* keys, cleaned", JSON.stringify(p?.utm));
check(Number(one(await db.query("select count(*) from public.partner_funnel_events where event = 'number_filled' and phone = '9876500002'"))) === 1, "'number filled' is logged once, before any account exists");

// Google, then the gate: register, then stamp the sign-up.
await as(db, b, "select public.partner_register('Bala', '')");
const meta = await as(db, b, `select public.partner_signup_meta('direct', '', '{}')`);
check(!meta.error, "partner_signup_meta runs for the new partner", meta.error?.message);
await as(db, b, `select public.partner_signup_meta('other', 'X', '{}')`);
const bp = (await db.query(`select signup_channel, referred_by, utm from public.broker_partners where user_id = '${B}'`)).rows[0];
check(bp.signup_channel === "referral" && bp.referred_by === "AB12CD" && bp.utm.utm_source === "whatsapp", "the partner inherits the prospect's channel, code and UTM, and a later call changes nothing", JSON.stringify(bp));
const ev = (await db.query(`select event from public.partner_funnel_events where user_id = '${B}' order by event`)).rows.map((r) => r.event).join();
check(ev === "number_filled,signed_up", "the pre-Google number is now this account's, plus 'signed up' once", ev);
check(one(await db.query("select user_id::text from public.partner_prospects where phone = '9876500002'")) === B, "the prospect row points at the account");
check(!(await as(db, tenant, "select public.partner_signup_meta('x')")).error, "for a non-partner it is a quiet no-op");

console.log("\n§ 1 access");
for (const t of ["partner_prospects", "partner_funnel_events"]) {
  check(denied(await as(db, anon, `select * from public.${t}`)), `anon: ${t} refused`);
  check((await as(db, b, `select * from public.${t}`)).rows?.length === 0, `a partner reads nothing from ${t}`);
  check((await as(db, staff, `select * from public.${t}`)).rows?.length > 0, `CRM staff read ${t}`);
}
check(denied(await as(db, anon, "select public.partner_signup_meta('x')")), "anon cannot stamp a sign-up");

await db.close();
console.log(`\n${passed ? "ALL CHECKS PASS" : "SOMETHING FAILED"}`);
process.exit(passed ? 0 : 1);
