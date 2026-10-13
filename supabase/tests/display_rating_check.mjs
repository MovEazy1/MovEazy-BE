/**
 * Apply partner_display_rating.sql (PGlite) over stand-ins of the partner and
 * storefront tables, and check the rating a partner shows:
 *   - every partner, existing and new, gets 4.6–4.9; re-running keeps it;
 *   - it shows until 10 tenants have rated, then their average does;
 *   - the public page, a tenant's rating, the partner's poster and the CRM;
 *   - who may set it.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});
const SQL = readFileSync(new URL("../partner_display_rating.sql", import.meta.url), "utf8");

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
await db.exec(SQL);
const rating = async (uid) => Number((await db.query(`select display_rating from public.broker_partners where user_id = '${uid}'`)).rows[0].display_rating);
const first = await rating(A);
check([4.6, 4.7, 4.8, 4.9].includes(first), "an existing partner gets 4.6–4.9", String(first));
await db.exec(SQL);
check(await rating(A) === first, "re-running keeps it");
await db.exec(`insert into public.broker_partners (user_id, name) values ('${B}', 'Bala')`);
check([4.6, 4.7, 4.8, 4.9].includes(await rating(B)), "a new partner gets one too");
const seen = new Set();
for (let i = 0; i < 200; i++) seen.add(Number((await db.query("select public.partner_seed_rating() r")).rows[0].r));
check([...seen].sort().join() === "4.6,4.7,4.8,4.9", "the seed spans exactly 4.6, 4.7, 4.8, 4.9", [...seen].join());

async function as(who, sql, params = []) {
  await db.exec(`reset role; select set_config('test.uid', '${who.uid ?? ""}', false),
    set_config('test.staff', '${who.staff ? "on" : ""}', false), set_config('test.scopes', '${(who.scopes ?? []).join(",")}', false);
    set role ${who.role ?? "authenticated"};`);
  try { return { rows: (await db.query(sql, params)).rows, error: null }; }
  catch (e) { return { rows: null, error: e }; }
  finally { await db.exec("reset role"); }
}
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const admin = { uid: "e0000000-0000-0000-0000-000000000001", staff: true, scopes: ["partners.manage"] };

console.log("\nthe CRM's rating, until 10 tenants have rated");
let r = await as(admin, `select public.crm_partner_set_rating('${A}', 4.84)`);
check(!r.error && await rating(A) === 4.8, "the CRM sets 4.8 (one decimal)", r.error?.message);
r = await as(admin, `select public.crm_partner_set_rating('${A}', 5.5)`);
check(/between 1 and 5/.test(r.error?.message ?? ""), "only 1–5");
r = await as({ uid: A }, `select public.crm_partner_set_rating('${A}', 5)`);
check(/Not allowed/.test(r.error?.message ?? ""), "a partner can't set their own");
const tenants = Array.from({ length: 10 }, (_, i) => `c0000000-0000-0000-0000-${String(i + 1).padStart(12, "0")}`);
for (const t of tenants.slice(0, 9)) await as({ uid: t }, "select public.partner_storefront_rate('ASHA01', 3)");
let page = one(await as({ role: "anon" }, "select public.partner_storefront('ASHA01')"));
check(Number(page.broker.rating) === 4.8 && page.broker.ratings === 9 && page.broker.from_tenants === false,
  "9 tenants rated: the public page still shows the CRM's 4.8", JSON.stringify(page.broker));
r = await as({ uid: tenants[9] }, "select public.partner_storefront_rate('ASHA01', 4)");
check(Number(one(r).rating) === 3.1 && one(r).from_tenants === true, "the 10th rating: the tenants' average (3.1) takes over", JSON.stringify(one(r)));
page = one(await as({ role: "anon" }, "select public.partner_storefront('ASHA01')"));
check(Number(page.broker.rating) === 3.1 && page.broker.ratings === 10, "…on the public page too");
const mine = one(await as({ uid: A }, "select public.partner_my_rating()"));
check(Number(mine.rating) === 3.1 && mine.from_tenants, "and on the partner's poster", JSON.stringify(mine));
const bala = one(await as({ uid: B }, "select public.partner_my_rating()"));
check([4.6, 4.7, 4.8, 4.9].includes(Number(bala.rating)) && bala.ratings === 0, "a partner nobody rated: the CRM's");
const list = (await as(admin, "select * from public.partner_admin_list()")).rows;
const a = list.find((p) => p.name === "Asha");
check(Number(a.display_rating) === 4.8 && a.tenant_ratings === 10 && Number(a.tenant_rating) === 3.1, "the CRM's list shows both", JSON.stringify(a));

console.log("\nwho may call what");
r = await as({ role: "anon" }, "select public.partner_my_rating()");
check(Boolean(r.error), "signed out: no poster rating");
r = await as({ uid: A }, `select public.partner_shown_rating('${B}')`);
check(Boolean(r.error), "the helper isn't callable directly");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
