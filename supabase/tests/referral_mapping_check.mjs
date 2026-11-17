/**
 * Apply partner_referral_commission.sql then partner_referral_mapping.sql
 * (PGlite) over stand-ins, and check:
 *   - a referral kept on the mobile number maps the partner (via 'phone'), a
 *     ?ref= on the device (via 'link'), and a stamp never overwrites;
 *   - "Who invited you?": code or mobile, 20 minutes, once, never self or a
 *     loop; the CRM approves (referrer set, via 'claim') or rejects;
 *   - the CRM sets / changes / clears a referrer, making a code if needed;
 *   - the Wallet's per-partner numbers and team totals; partner_my_team;
 *   - CRM listing → partner: shared at the property share, notification,
 *     partner-added flats locked, CRM-made ones changed or cleared;
 *   - who may do what.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});
const read = (f) => readFileSync(new URL(`../${f}`, import.meta.url), "utf8");
const fn = (file, head) => { const s = read(file); const i = s.indexOf(head); return s.slice(i, s.indexOf("$$;", s.indexOf("$$", i) + 2) + 3); };
const COMMISSION = read("partner_referral_commission.sql");
const SQL = read("partner_referral_mapping.sql");

let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};

const A = "a1111111-0000-0000-0000-000000000001"; // Asha: Premium, code ASHA01
const B = "b2222222-0000-0000-0000-000000000002"; // Bala: joined just now, nobody's referral yet
const C = "c3333333-0000-0000-0000-000000000003"; // Chetan: no code, joined long ago
const D = "d4444444-0000-0000-0000-000000000004"; // Deepa: joined just now, number typed on Asha's link
const E = "e5555555-0000-0000-0000-000000000005"; // Esha: joined just now, ?ref= on device

const db = new PGlite();
await db.exec(`
create role anon; create role authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated;
create schema auth;
create table auth.users (id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
create function auth.jwt() returns jsonb language sql stable as $$ select jsonb_build_object('email', current_setting('test.email', true)) $$;
create function public.is_crm_staff() returns boolean language sql stable as $$ select current_setting('test.staff', true) = 'on' $$;
create function public.has_admin_scope(s text) returns boolean language sql stable as $$
  select current_setting('test.staff', true) = 'on' and s = any (string_to_array(coalesce(current_setting('test.scopes', true), ''), ',')) $$;
${fn("lead_intake.sql", "create or replace function public.normalize_mobile(raw text)")}
${fn("partner_launch.sql", "create or replace function public.partner_clean_tag(")}
${fn("partner_launch.sql", "create or replace function public.partner_clean_utm(")}
create table public.broker_partners (user_id uuid primary key, name text default '', phone text default '', alt_phone text, email text default '',
  agency text default '', status text default 'approved', approved_at timestamptz, approved_by text default '',
  client_share_pct numeric, referral_code text unique, referred_by text not null default '', signup_channel text not null default '',
  utm jsonb not null default '{}', payout_upi text not null default '', payout_bank jsonb not null default '{}',
  created_at timestamptz default now(), updated_at timestamptz default now());
create table public.partner_prospects (phone text primary key, channel text default '', referred_by text default '', utm jsonb default '{}',
  user_id uuid, updated_at timestamptz default now());
create table public.partner_funnel_events (id bigint generated always as identity, user_id uuid, phone text, event text, meta jsonb,
  at timestamptz default now(), unique (user_id, event));
create function public.is_approved_partner() returns boolean language sql stable security definer as $$
  select exists (select 1 from public.broker_partners where user_id = auth.uid() and status = 'approved') $$;
create table public.partner_tiers (tier text primary key, is_free boolean default false);
insert into public.partner_tiers values ('moveazy_inventory', false);
create table public.partner_entitlements (id uuid primary key default gen_random_uuid(), user_id uuid, tier text, plan text default 'monthly',
  starts_at timestamptz default now(), ends_at timestamptz);
create function public.partner_has_tier(t text) returns boolean language sql stable security definer as $$
  select exists (select 1 from public.partner_entitlements e where e.user_id = auth.uid() and now() between e.starts_at and e.ends_at) $$;
create function public.partner_referral_code() returns text language plpgsql security definer as $$
declare c text;
begin
  select referral_code into c from public.broker_partners where user_id = auth.uid();
  if c is null and not public.partner_has_tier('moveazy_inventory') then raise exception 'Refer & Earn comes with Premium.'; end if;
  return c;
end $$;
create function public.partner_referrals_settle() returns void language sql as $$ select $$;
create table public.partner_plans (id text primary key, label text, months int, price int, sort int default 0, active boolean default true,
  referral_reward int default 0);
create table public.partner_referrals (id uuid primary key default gen_random_uuid(), referrer_id uuid, referee_id uuid unique,
  plan_id text default '', amount int default 0, status text default 'pending', earn_after timestamptz, paid_at timestamptz);
create table public.inventory (property_id text primary key, area text default '', bedrooms int default 1, rent numeric default 0,
  broker_id uuid, posted_by text default 'owner');
create table public.program_settings (id int primary key, property_share numeric);
insert into public.program_settings values (1, 50);
create table public.partner_listings (property_id text primary key references public.inventory (property_id) on delete cascade,
  broker_id uuid not null, created_at timestamptz default now(), updated_at timestamptz default now());
create table public.partner_platform_shares (property_id text primary key references public.partner_listings (property_id) on delete cascade,
  share_pct numeric not null);
create table public.partner_group_shares (property_id text references public.partner_listings (property_id) on delete cascade,
  group_id uuid, share_pct numeric);
create table public.partner_group_members (group_id uuid, user_id uuid);
create table public.visit_bookings (id uuid primary key default gen_random_uuid(), property_id text, status text default 'scheduled');
create table public.crm_clients (id uuid primary key default gen_random_uuid(), name text default '');
create table public.partner_live_visits (id uuid primary key default gen_random_uuid(), client_id uuid, property_id text, broker_id uuid,
  status text default 'assigned');
create table public.partner_notifications (id bigint generated always as identity primary key, broker_id uuid, kind text,
  title text, body text default '', link text default '');
alter table public.partner_notifications add constraint partner_notifications_kind_check check (kind = any ('{welcome,referral,visit_assigned}'::text[]));
create table public.partner_lead_requests (id uuid primary key default gen_random_uuid(), broker_id uuid, pack text);
create table public.partner_lead_assignments (id uuid primary key default gen_random_uuid(), request_id uuid, client_id uuid, broker_id uuid,
  status text default 'assigned', closed_rent numeric, deal_type text, due_amount numeric not null default 0, closed_at timestamptz,
  updated_at timestamptz default now());

insert into auth.users values ('${A}'), ('${B}'), ('${C}'), ('${D}'), ('${E}');
insert into public.broker_partners (user_id, name, phone, alt_phone, referral_code, created_at) values
  ('${A}', 'Asha Rao', '9876500001', '9876511111', 'ASHA01', now() - interval '60 days'),
  ('${B}', 'Bala', '9876500002', null, null, now() - interval '5 minutes'),
  ('${C}', 'Chetan', '9876500003', null, null, now() - interval '40 days'),
  ('${D}', 'Deepa', '9876500004', null, null, now() - interval '1 minute'),
  ('${E}', 'Esha', '9876500005', null, null, now() - interval '1 minute');
insert into public.partner_entitlements (user_id, tier, plan, starts_at, ends_at) values
  ('${A}', 'moveazy_inventory', 'monthly', now() - interval '10 days', now() + interval '20 days');
insert into public.partner_prospects (phone, channel, referred_by) values ('9876500004', 'referral', 'ASHA01');
insert into public.inventory (property_id, area, bedrooms, rent, broker_id) values
  ('MZ1', 'HSR Layout', 2, 32000, null), ('MZ2', 'Koramangala', 1, 21000, null), ('MZ3', 'BTM', 3, 45000, null);
`);
await db.exec(COMMISSION);
await db.exec(SQL);
await db.exec(SQL);
check(true, "partner_referral_mapping.sql applies after partner_referral_commission.sql, and re-applies");
const kinds = (await db.query("select pg_get_constraintdef(oid) d from pg_constraint where conname = 'partner_notifications_kind_check'")).rows[0].d;
check(/listing_assigned/.test(kinds) && /visit_assigned/.test(kinds) && /referral/.test(kinds), "notification kinds: listing_assigned added, the rest kept", kinds);

async function as(who, sql, params = []) {
  await db.exec(`reset role; select set_config('test.uid', '${who.uid ?? ""}', false), set_config('test.email', '${who.email ?? ""}', false),
    set_config('test.staff', '${who.staff ? "on" : ""}', false), set_config('test.scopes', '${(who.scopes ?? []).join(",")}', false);
    set role ${who.role ?? "authenticated"};`);
  try { return { rows: (await db.query(sql, params)).rows, error: null }; }
  catch (e) { return { rows: null, error: e }; }
  finally { await db.exec("reset role"); }
}
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const asha = { uid: A }, bala = { uid: B }, chetan = { uid: C }, deepa = { uid: D }, esha = { uid: E };
const admin = { uid: "f0000000-0000-0000-0000-000000000001", email: "ops@moveazy.co.in", staff: true, scopes: ["partners.manage", "crm.properties.write"] };
const viewer = { uid: "f0000000-0000-0000-0000-000000000002", email: "view@moveazy.co.in", staff: true, scopes: [] };
const bp = async (uid) => (await db.query(`select referred_by, referred_via from public.broker_partners where user_id = '${uid}'`)).rows[0];
const notes = async (uid) => (await db.query(`select kind, title, body, link from public.partner_notifications where broker_id = '${uid}' order by id`)).rows;

console.log("\nsign-up keeps the referral");
let r = await as(deepa, "select public.partner_signup_meta('', '', '{}')");
let row = await bp(D);
check(!r.error && row.referred_by === "ASHA01" && row.referred_via === "phone", "number typed on Asha's link, signed up elsewhere: mapped via 'phone'", r.error?.message ?? JSON.stringify(row));
r = await as(esha, "select public.partner_signup_meta('referral', 'asha01', '{}')");
row = await bp(E);
check(!r.error && row.referred_by === "ASHA01" && row.referred_via === "link", "?ref= on the device: mapped via 'link'", JSON.stringify(row));
await as(esha, "select public.partner_signup_meta('', 'OTHER9', '{}')");
check((await bp(E)).referred_by === "ASHA01", "a later stamp never overwrites");
r = await as(chetan, "select public.partner_signup_meta('referral', 'ASHA01', '{}')");
row = await bp(C);
check(!r.error && !row.referred_by && !row.referred_via, "a partner of 40 days who opens a link later isn't credited to it (link: 24 hours)", r.error?.message ?? JSON.stringify(row));

console.log("\nWho invited you?");
let t = one(await as(bala, "select public.partner_my_team()"));
check(t.claim_until && !t.invited_by && t.claim === null, "Bala (5 min in, no referrer): can still say who invited him", JSON.stringify(t));
t = one(await as(chetan, "select public.partner_my_team()"));
check(t.claim_until === null, "Chetan (40 days in): the box is gone");
r = await as(chetan, "select public.partner_claim_referrer('ASHA01')");
check(/20 minutes/.test(r.error?.message ?? ""), "Chetan can't claim after 20 minutes", r.error?.message);
t = one(await as(deepa, "select public.partner_my_team()"));
check(t.claim_until === null && t.invited_by === "Asha Rao", "Deepa is already mapped: no box, shows who invited her", JSON.stringify(t));
r = await as(bala, "select public.partner_claim_referrer('NOPE99')");
check(r.error?.code === "P0002", "an unknown code is refused", r.error?.message);
r = await as(bala, "select public.partner_claim_referrer('98765 00002')");
check(r.error?.code === "P0002", "his own number is refused", r.error?.message);
r = await as(bala, "select public.partner_claim_referrer('+91 98765 11111')");
check(!r.error && one(r).referrer === "Asha", "Asha's second number works → 'Asha'", r.error?.message ?? JSON.stringify(one(r)));
check((await bp(B)).referred_by === "", "a claim alone doesn't map him");
r = await as(bala, "select public.partner_claim_referrer('ASHA01')");
check(/already/.test(r.error?.message ?? ""), "only once", r.error?.message);
t = one(await as(bala, "select public.partner_my_team()"));
check(t.claim?.status === "pending" && t.claim.referrer === "Asha Rao" && t.claim_until === null, "Bala sees it waiting for MovEazy", JSON.stringify(t));

console.log("\nthe CRM decides");
r = await as(viewer, "select public.crm_referral_claims()");
check(!r.error && one(r).length === 1 && one(r)[0].partner === "Bala" && one(r)[0].referrer === "Asha Rao" && one(r)[0].entered.includes("11111"),
  "CRM staff see the request: who, whom, what they typed", r.error?.message ?? JSON.stringify(one(r)));
r = await as(viewer, `select public.crm_referral_claim_decide('${B}', true)`);
check(r.error?.code === "42501", "deciding needs partners.manage");
r = await as(bala, "select public.crm_referral_claims()");
check(r.error?.code === "42501", "partners can't list requests");
r = await as(admin, `select public.crm_referral_claim_decide('${B}', true)`);
row = await bp(B);
check(!r.error && row.referred_by === "ASHA01" && row.referred_via === "claim", "approved: Bala is Asha's, via 'claim'", r.error?.message ?? JSON.stringify(row));
check((await notes(B)).some((n) => n.title === "Referrer confirmed"), "Bala is told");
r = await as(admin, `select public.crm_referral_claim_decide('${B}', false)`);
check(/already decided/.test(r.error?.message ?? ""), "can't decide twice");

console.log("\nthe CRM sets referrers");
r = await as(admin, `select public.crm_partner_set_referrer('${A}', '${C}')`);
check(!r.error && (await bp(A)).referred_via === "crm", "Asha ← Chetan (no code yet)", r.error?.message);
const chetanCode = (await db.query(`select referral_code from public.broker_partners where user_id = '${C}'`)).rows[0].referral_code;
check(/^[A-Z2-9]{6}$/.test(chetanCode ?? "") && (await bp(A)).referred_by === chetanCode, "Chetan got a code; Asha points at it", chetanCode);
r = await as(admin, `select public.crm_partner_set_referrer('${C}', '${A}')`);
check(/both ways/.test(r.error?.message ?? ""), "no loops: Chetan can't be Asha's referral now", r.error?.message);
r = await as(admin, `select public.crm_partner_set_referrer('${C}', '${C}')`);
check(/own referrer/.test(r.error?.message ?? ""), "never themself");
r = await as(viewer, `select public.crm_partner_set_referrer('${A}', null)`);
check(r.error?.code === "42501", "setting needs partners.manage");
r = await as(admin, `select public.crm_partner_set_referrer('${A}', null)`);
row = await bp(A);
check(!r.error && row.referred_by === "" && row.referred_via === "", "cleared", JSON.stringify(row));
r = await as(viewer, "select json_agg(x) from public.crm_partner_referrers() x");
check(!r.error && one(r).length === 3 && one(r).every((x) => x.referrer_name === "Asha Rao"), "crm_partner_referrers: Bala, Deepa, Esha → Asha", JSON.stringify(one(r)));
r = await as(bala, "select count(*) from public.crm_partner_referrers()");
check(Number(one(r)) === 0, "partners get nothing from it");

console.log("\nCRM maps listings");
await db.exec(`insert into public.partner_listings (property_id, broker_id) values ('MZ3', '${E}')`);
r = await as(admin, `select public.crm_listing_set_partner('MZ1', '${B}')`);
const pl1 = (await db.query("select l.broker_id, l.mapped_by, s.share_pct, i.broker_id ib from public.partner_listings l left join public.partner_platform_shares s using (property_id) join public.inventory i using (property_id) where l.property_id = 'MZ1'")).rows[0];
check(!r.error && pl1?.broker_id === B && pl1.mapped_by === "ops@moveazy.co.in" && Number(pl1.share_pct) === 50 && pl1.ib === B,
  "MZ1 → Bala: his listing, shared with all brokers at 50%, inventory.broker_id set", r.error?.message ?? JSON.stringify(pl1));
const n1 = (await notes(B)).find((n) => n.kind === "listing_assigned");
check(n1 && /2 BHK · HSR Layout · ₹32,000/.test(n1.body) && n1.link === "/property/MZ1", "Bala is told: 2 BHK · HSR Layout · ₹32,000", JSON.stringify(n1));
r = await as(admin, `select public.crm_listing_set_partner('MZ3', '${B}')`);
check(/Esha added this flat/.test(r.error?.message ?? ""), "a flat the partner added themself stays theirs", r.error?.message);
await db.exec(`update public.partner_entitlements set ends_at = now() - interval '1 day' where user_id = '${A}'`);
r = await as(admin, `select public.crm_listing_set_partner('MZ1', '${A}')`);
check(!r.error && (await db.query("select broker_id from public.partner_listings where property_id = 'MZ1'")).rows[0].broker_id === A,
  "a CRM-made mapping can move — to any approved partner, Premium or not", r.error?.message);
r = await as(admin, "select public.crm_listing_set_partner('MZ1', null)");
const gone = (await db.query("select (select count(*) from public.partner_listings where property_id = 'MZ1') n, (select broker_id from public.inventory where property_id = 'MZ1') b")).rows[0];
check(!r.error && Number(gone.n) === 0 && gone.b === null, "cleared: back to a MovEazy flat", r.error?.message ?? JSON.stringify(gone));
r = await as(viewer, `select public.crm_listing_set_partner('MZ2', '${B}')`);
check(r.error?.code === "42501", "mapping needs crm.properties.write or partners.manage");
r = await as(admin, `select public.crm_listing_set_partner('MZ2', '${B}')`);
check(!r.error, "MZ2 → Bala");

console.log("\nthe Wallet and Home numbers");
await db.exec(`
  insert into public.crm_clients (id) values ('11111111-0000-0000-0000-000000000001'), ('11111111-0000-0000-0000-000000000002');
  insert into public.partner_live_visits (client_id, property_id, broker_id, status) values
    ('11111111-0000-0000-0000-000000000001', 'MZ2', '${B}', 'done'), ('11111111-0000-0000-0000-000000000002', 'MZ2', '${B}', 'cancelled');
  insert into public.partner_lead_assignments (client_id, broker_id, status, closed_rent, deal_type, due_amount, closed_at) values
    ('11111111-0000-0000-0000-000000000001', '${B}', 'closed', 30000, 'direct', 9000, now()),
    ('11111111-0000-0000-0000-000000000002', '${B}', 'visit', null, null, 0, null),
    (null, '${B}', 'assigned', null, null, 0, null);
  insert into public.visit_bookings (property_id, status) values ('MZ2', 'scheduled'), ('MZ2', 'cancelled'), ('MZ2', 'preference');
`);
await db.exec(`update public.partner_entitlements set ends_at = now() + interval '20 days' where user_id = '${A}';
  insert into public.partner_entitlements (user_id, tier, plan, starts_at, ends_at) values ('${B}', 'moveazy_inventory', 'trial', now() - interval '1 day', now() + interval '6 days')`);
await db.exec("update public.partner_lead_assignments set closed_at = now() where status = 'closed'");
const w = one(await as(asha, "select public.partner_my_referrals()"));
const bw = w.joined.find((j) => j.name === "Bala");
check(bw?.stats && bw.stats.listings === 1 && bw.stats.visits_done === 2 && bw.stats.visits_on_flats === 1 && bw.stats.closures === 1,
  "Bala: 1 flat, 2 visits done (live visit + a lead at visit, the closed one not double-counted), 1 visit booked on his flat, 1 closure",
  JSON.stringify(bw?.stats));
check(w.joined.length === 3 && w.team.listings === 2 && w.team.closures === 1 && w.team.visits_done === 2, "team totals (Bala's MZ2 + Esha's MZ3)", JSON.stringify(w.team));
check(bw.deals.length === 1 && bw.deals[0].amount === 3000, "his closure is in Asha's deals (₹3,000 expected)", JSON.stringify(bw.deals));
t = one(await as(asha, "select public.partner_my_team()"));
check(t.team.partners === 3 && t.team.visits_on_flats === 1 && Number(t.lifetime) === 0, "partner_my_team: 3 partners, totals, lifetime ₹0 so far", JSON.stringify(t));
r = await as(admin, "select public.crm_lead_closure_received(id) from public.partner_lead_assignments where status = 'closed'");
t = one(await as(asha, "select public.partner_my_team()"));
check(!r.error && Number(t.lifetime) === 3000, "MovEazy paid: Asha's lifetime commission ₹3,000", r.error?.message ?? JSON.stringify(t));

console.log("\nwho may call what");
for (const f of ["partner_member_stats('" + B + "')", "partner_set_referrer('" + B + "', null, 'crm')", "partner_ensure_referral_code('" + B + "')"]) {
  r = await as(asha, `select public.${f}`);
  check(r.error?.code === "42501", `${f.split("(")[0]} is internal`, r.error?.message);
}
r = await as({ role: "anon" }, "select public.partner_my_team()");
check(r.error?.code === "42501", "anon can't read a team");

console.log(passed ? "\nALL PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
