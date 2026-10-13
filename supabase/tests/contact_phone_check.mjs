/**
 * Apply partner_display_rating.sql then partner_contact_phone.sql (PGlite) and
 * check a partner's second number: added, made primary, replaced, removed;
 * the primary one on the public page and in the CRM; and the checks (10 digits,
 * not the main number, approved partners only).
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});
const read = (f) => readFileSync(new URL(`../${f}`, import.meta.url), "utf8");
const RATING = read("partner_display_rating.sql");
const SQL = read("partner_contact_phone.sql");
const INTAKE = read("lead_intake.sql");
const ni = INTAKE.indexOf("create or replace function public.normalize_mobile");
const NORMALIZE = INTAKE.slice(ni, INTAKE.indexOf("$$;", ni) + 3);

let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};

const A = "a0000000-0000-0000-0000-000000000001", B = "b0000000-0000-0000-0000-000000000002";
const db = new PGlite();
await db.exec(`
create role anon; create role authenticated;
create schema auth;
create table auth.users (id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
create function public.is_crm_staff() returns boolean language sql stable as $$ select current_setting('test.staff', true) = 'on' $$;
create function public.has_admin_scope(s text) returns boolean language sql stable as $$
  select current_setting('test.staff', true) = 'on' and s = any (string_to_array(coalesce(current_setting('test.scopes', true), ''), ',')) $$;
create table public.broker_partners (user_id uuid primary key, name text default '', phone text default '', email text default '',
  agency text default '', status text default 'approved', approved_at timestamptz, approved_by text default '', client_share_pct numeric,
  referral_code text, referred_by text default '', referral_direct_pct numeric, referral_shared_pct numeric,
  created_at timestamptz default now(), updated_at timestamptz default now());
create function public.is_approved_partner() returns boolean language sql stable security definer as $$
  select exists (select 1 from public.broker_partners where user_id = auth.uid() and status = 'approved') $$;
create table public.partner_entitlements (user_id uuid, tier text, plan text, starts_at timestamptz, ends_at timestamptz);
create table public.partner_listings (property_id text, broker_id uuid);
create table public.partner_group_members (group_id uuid, user_id uuid);
create table public.partner_storefronts (broker_id uuid primary key, code text unique, photo_url text default '');
create table public.partner_storefront_likes (broker_id uuid, user_id uuid, property_id text);
create table public.partner_storefront_ratings (broker_id uuid, user_id uuid, stars int, updated_at timestamptz default now(), primary key (broker_id, user_id));
create function public.storefront_broker(p_code text) returns uuid language sql stable as $$
  select broker_id from public.partner_storefronts where code = upper(trim(p_code)) $$;
create function public.storefront_homes(p_broker uuid) returns table (property_id text, title text, city text, area text, rent numeric,
  deposit numeric, available_from date, property_type text, flat_type text, bedrooms int, bathrooms int, furnishing text, images text[],
  cover_image_url text, is_verified boolean) language sql stable as $$ select null::text, null, null, null, null::numeric, null::numeric, null::date,
  null, null, null::int, null::int, null, null::text[], null, null::boolean where false $$;
insert into public.broker_partners (user_id, name) values ('${A}', 'Asha');
insert into public.partner_storefronts values ('${A}', 'ASHA01', '');
`);
await db.exec(NORMALIZE);
await db.exec(`update public.broker_partners set phone = '+91 98765 00001' where user_id = '${A}'`);
await db.exec(RATING);
await db.exec(SQL);
await db.exec(SQL);
check(true, "partner_contact_phone.sql applies, and re-applies over itself");

async function as(who, sql, params = []) {
  await db.exec(`reset role; select set_config('test.uid', '${who.uid ?? ""}', false),
    set_config('test.staff', '${who.staff ? "on" : ""}', false), set_config('test.scopes', '${(who.scopes ?? []).join(",")}', false);
    set role ${who.role ?? "authenticated"};`);
  try { return { rows: (await db.query(sql, params)).rows, error: null }; }
  catch (e) { return { rows: null, error: e }; }
  finally { await db.exec("reset role"); }
}
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const asha = { uid: A };
const page = async () => one(await as({ role: "anon" }, "select public.partner_storefront('ASHA01')")).broker.phone;

console.log("\nthe second number");
check(await page() === "+91 98765 00001", "before: the public page shows the main number");
let r = await as(asha, "select public.partner_set_contact('090000 11111', 'main')");
check(/10-digit/.test(r.error?.message ?? ""), "not a mobile number: refused", r.error?.message);
r = await as(asha, "select public.partner_set_contact('9876500001', 'alt')");
check(/already your main/.test(r.error?.message ?? ""), "the main number again: refused", r.error?.message);
r = await as(asha, "select public.partner_set_contact('+91 91234 56789', 'main')");
check(!r.error && one(r).alt_phone === "9123456789" && one(r).contact === "+91 98765 00001", "added as secondary; main stays primary", r.error?.message ?? JSON.stringify(one(r)));
check(await page() === "+91 98765 00001", "the public page keeps the main number");
r = await as(asha, "select public.partner_set_contact('9123456789', 'alt')");
check(one(r)?.contact === "9123456789" && await page() === "9123456789", "made primary: the public page shows it");
r = await as(asha, "select public.partner_set_contact('9000011111', 'alt')");
check(one(r)?.alt_phone === "9000011111" && one(r).contact === "9000011111", "a new one replaces it");
const crm = (await as({ uid: "e0000000-0000-0000-0000-000000000001", staff: true, scopes: ["partners.manage"] }, "select * from public.partner_admin_list()")).rows
  .find((p) => p.name === "Asha");
check(crm.phone === "+91 98765 00001" && crm.alt_phone === "9000011111" && crm.contact_primary === "alt", "the CRM sees both, and which is primary", JSON.stringify(crm));
r = await as(asha, "select public.partner_set_contact('', 'alt')");
check(one(r)?.alt_phone === "" && one(r).contact_primary === "main" && await page() === "+91 98765 00001", "removed: back to the main number");
const me = (await db.query(`select to_jsonb(p) j from public.broker_partners p where user_id = '${A}'`)).rows[0].j;
check("alt_phone" in me && "contact_primary" in me, "the app's own profile (partner_me) carries both fields");

console.log("\nwho may");
r = await as({ role: "anon" }, "select public.partner_set_contact('9123456789', 'main')");
check(Boolean(r.error), "signed out: no");
await db.exec(`update public.broker_partners set status = 'pending' where user_id = '${B}'`);
r = await as({ uid: B }, "select public.partner_set_contact('9123456789', 'main')");
check(/approved/.test(r.error?.message ?? ""), "a partner not yet approved: no", r.error?.message);
r = await as(asha, `select public.partner_contact_phone('${A}')`);
check(Boolean(r.error), "the helper isn't callable directly");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
