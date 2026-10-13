/**
 * Apply partner_referral_commission.sql (PGlite) over stand-ins of the partner
 * and lead tables, and check the lifetime referral commission end to end:
 *   - MovEazy marking its share received pays the closing partner's referrer
 *     10% of the rent on a direct deal, 6.67% on a shared one, never more than
 *     MovEazy's share; the CRM's own rates win;
 *   - only Premium leads, closed while the closing partner was on Premium
 *     (Trial counts);
 *   - a referrer off Premium: held 30 days, due if they go Premium, else lost;
 *   - undo, marking paid, notifications;
 *   - the Wallet: totals, rates, each referred partner's plan, leads, deals —
 *     and a partner without Premium still gets it;
 *   - who may do what.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});
const read = (f) => readFileSync(new URL(`../${f}`, import.meta.url), "utf8");
const SQL = read("partner_referral_commission.sql");
const LAUNCH = read("partner_launch.sql");
const si = LAUNCH.indexOf("create or replace function public.partner_referrals_settle()");
const SETTLE = LAUNCH.slice(si, LAUNCH.indexOf("$$;", si) + 3);

let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};

const A = "a1111111-0000-0000-0000-000000000001"; // Asha refers
const B = "b2222222-0000-0000-0000-000000000002"; // Bala, referred by Asha
const C = "c3333333-0000-0000-0000-000000000003"; // Chetan, referred by Asha, free
const D = "d4444444-0000-0000-0000-000000000004"; // Deepa, nobody's referral
const F = "f5555555-0000-0000-0000-000000000005"; // Farah, never Premium, referred by Bala

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
create table public.broker_partners (user_id uuid primary key, name text default '', phone text default '', email text default '',
  agency text default '', status text default 'approved', approved_at timestamptz, approved_by text default '',
  client_share_pct numeric, referral_code text unique, referred_by text not null default '',
  payout_upi text not null default '', payout_bank jsonb not null default '{}', created_at timestamptz default now(), updated_at timestamptz default now());
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
create table public.partner_plans (id text primary key, label text, months int, price int, sort int default 0, active boolean default true,
  referral_reward int default 0);
create table public.partner_payments (id uuid primary key default gen_random_uuid(), status text);
create table public.partner_referrals (id uuid primary key default gen_random_uuid(), referrer_id uuid, referee_id uuid unique,
  payment_id uuid, plan_id text default '', amount int default 1500, status text default 'pending', earn_after timestamptz,
  created_at timestamptz default now(), paid_at timestamptz, paid_by text default '');
${SETTLE}
create table public.partner_listings (property_id text, broker_id uuid);
create table public.partner_group_members (group_id uuid, user_id uuid);
create table public.partner_notifications (id bigint generated always as identity primary key, broker_id uuid, kind text
  check (kind in ('welcome', 'referral')), title text, body text default '', link text default '');
create table public.crm_clients (id uuid primary key default gen_random_uuid(), name text default '');
create table public.partner_lead_requests (id uuid primary key default gen_random_uuid(), broker_id uuid, pack text);
create table public.partner_lead_assignments (id uuid primary key default gen_random_uuid(), request_id uuid references public.partner_lead_requests(id),
  client_id uuid references public.crm_clients(id), broker_id uuid, status text default 'assigned', closed_rent numeric, deal_type text,
  due_amount numeric not null default 0, closed_at timestamptz, updated_at timestamptz default now());

insert into auth.users values ('${A}'), ('${B}'), ('${C}'), ('${D}'), ('${F}');
insert into public.broker_partners (user_id, name, phone, referral_code, referred_by, payout_upi) values
  ('${A}', 'Asha', '9876500001', 'ASHA01', '', 'asha@okhdfc'),
  ('${B}', 'Bala', '9876500002', 'BALA02', 'ASHA01', ''),
  ('${C}', 'Chetan', '9876500003', null, 'ASHA01', ''),
  ('${D}', 'Deepa', '9876500004', null, '', ''),
  ('${F}', 'Farah', '9876500005', null, 'BALA02', '');
-- Asha: paid Premium. Bala: on Trial. Chetan, Deepa, Farah: free.
insert into public.partner_entitlements (user_id, tier, plan, starts_at, ends_at) values
  ('${A}', 'moveazy_inventory', 'monthly', now() - interval '10 days', now() + interval '20 days'),
  ('${B}', 'moveazy_inventory', 'trial', now() - interval '5 days', now() + interval '9 days');
`);
await db.exec(SQL);
await db.exec(SQL);
check(true, "partner_referral_commission.sql applies, and re-applies over itself");

async function as(who, sql, params = []) {
  await db.exec(`reset role; select set_config('test.uid', '${who.uid ?? ""}', false), set_config('test.email', '${who.email ?? ""}', false),
    set_config('test.staff', '${who.staff ? "on" : ""}', false), set_config('test.scopes', '${(who.scopes ?? []).join(",")}', false);
    set role ${who.role ?? "authenticated"};`);
  try { return { rows: (await db.query(sql, params)).rows, error: null }; }
  catch (e) { return { rows: null, error: e }; }
  finally { await db.exec("reset role"); }
}
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const asha = { uid: A }, bala = { uid: B }, chetan = { uid: C }, deepa = { uid: D }, farah = { uid: F };
const admin = { uid: "e0000000-0000-0000-0000-000000000001", email: "ops@moveazy.co.in", staff: true, scopes: ["partners.manage"] };

/** A closed MovEazy lead: who closed it, the pack, rent, deal, MovEazy's due, when. */
async function closed(broker, pack, rent, deal, closedAt = "now()") {
  const due = pack === "premium" ? Math.round(rent * (deal === "direct" ? 0.3 : 0.2)) : 0;
  return (await db.query(`
    with c as (insert into public.crm_clients (name) values ('Tenant') returning id),
         q as (insert into public.partner_lead_requests (broker_id, pack) values ('${broker}', '${pack}') returning id)
    insert into public.partner_lead_assignments (request_id, client_id, broker_id, status, closed_rent, deal_type, due_amount, closed_at)
    select q.id, c.id, '${broker}', 'closed', ${rent}, '${deal}', ${due}, ${closedAt} from c, q returning id`)).rows[0].id;
}
const received = (id, undo = false) => as(admin, "select public.crm_lead_closure_received($1, $2)", [id, undo]);
const wallet = async (who) => one(await as(who, "select public.partner_my_referrals()"));
const notes = async (uid) => (await db.query(`select title, body from public.partner_notifications where broker_id = '${uid}' order by id`)).rows;

console.log("\nthe default rates");
let w = await wallet(asha);
check(Number(w.rates.direct) === 10 && Number(w.rates.shared) === 6.67, "a third of MovEazy's share, at most 10%: 10% direct, 6.67% shared", JSON.stringify(w.rates));

console.log("\nMovEazy has its share → the referrer earns");
const d1 = await closed(B, "premium", 40000, "direct");
w = await wallet(asha);
const bala1 = w.joined.find((j) => j.name === "Bala");
check(bala1.deals.length === 1 && bala1.deals[0].status === "waiting" && bala1.deals[0].amount === 4000,
  "before MovEazy is paid: 'waiting', ₹4,000 expected", JSON.stringify(bala1.deals));
let r = await received(d1);
check(!r.error && one(r).commission?.amount === 4000 && one(r).commission.status === "due",
  "direct ₹40,000 deal by a Trial partner: Asha earns ₹4,000, due", r.error?.message ?? JSON.stringify(one(r)));
check((await notes(A)).some((n) => /4,000 earned/.test(n.title) && /Bala closed a deal/.test(n.body)), "Asha is told", JSON.stringify(await notes(A)));
r = await received(d1);
check(!r.error && (await db.query("select count(*)::int n from public.partner_referral_commissions")).rows[0].n === 1, "marking again doesn't pay twice");
const s1 = await closed(B, "premium", 30000, "shared");
r = await received(s1);
check(one(r)?.commission?.amount === 2001, "shared ₹30,000 deal: 6.67% = ₹2,001 (MovEazy keeps the rest of its ₹6,000)", JSON.stringify(one(r)));

console.log("\nwhat doesn't count");
const free = await closed(B, "free10", 30000, "direct");
r = await received(free);
check(/Nothing is due/.test(r.error?.message ?? ""), "a free-pack lead owes MovEazy nothing — nothing to share", r.error?.message);
const own = await closed(D, "premium", 30000, "direct");
r = await received(own);
check(!r.error && one(r).commission === null, "a partner nobody referred: MovEazy keeps its share", r.error?.message);
await db.exec(`insert into public.partner_entitlements (user_id, tier, plan, starts_at, ends_at) values
  ('${C}', 'moveazy_inventory', 'monthly', now() - interval '90 days', now() - interval '60 days')`);
const lapsed = await closed(C, "premium", 30000, "direct");
r = await received(lapsed);
check(!r.error && one(r).commission === null, "closed while the referred partner wasn't on Premium: no commission", r.error?.message);
const back = await closed(C, "premium", 50000, "direct", "now() - interval '70 days'");
r = await received(back);
check(one(r)?.commission?.amount === 5000, "…but a deal closed while they were on Premium counts, whenever MovEazy is paid", JSON.stringify(one(r)));

console.log("\nthe referrer off Premium: held 30 days");
const f1 = await closed(F, "premium", 20000, "direct");
await db.exec(`update public.partner_entitlements set ends_at = now() - interval '1 day' where user_id = '${B}'`); // Bala's trial ends
await db.exec(`insert into public.partner_entitlements (user_id, tier, plan, starts_at, ends_at) values
  ('${F}', 'moveazy_inventory', 'monthly', now() - interval '3 days', now() + interval '27 days')`);
await db.exec(`update public.partner_lead_assignments set closed_at = now() where id = '${f1}'`);
r = await received(f1);
check(one(r)?.commission?.status === "held" && one(r).commission.amount === 2000, "Farah's deal; Bala, her referrer, isn't on Premium: ₹2,000 held", JSON.stringify(one(r)));
check((await notes(B)).some((n) => /waiting for you/.test(n.title) && /within 30 days/.test(n.body)), "Bala is told to go Premium within 30 days");
w = await wallet(bala);
check(w.premium === false && w.commission.held === 2000 && w.commission.due === 0 && w.commission.held_until,
  "Bala's Wallet: ₹2,000 held, with its deadline", JSON.stringify(w.commission));
await db.exec(`insert into public.partner_entitlements (user_id, tier, plan, starts_at, ends_at) values
  ('${B}', 'moveazy_inventory', 'monthly', now(), now() + interval '30 days')`);
w = await wallet(bala);
check(w.commission.held === 0 && w.commission.due === 2000, "Bala goes Premium in time: it's due");
const f2 = await closed(F, "premium", 25000, "direct");
await db.exec(`update public.partner_entitlements set ends_at = now() - interval '1 minute' where user_id = '${B}' and ends_at > now()`);
r = await received(f2);
check(one(r)?.commission?.status === "held", "another held one");
await db.exec(`update public.partner_referral_commissions set hold_until = now() - interval '1 minute' where status = 'held'`);
w = await wallet(bala);
check(w.commission.lost === 2500 && w.commission.held === 0, "30 days pass without Premium: lost", JSON.stringify(w.commission));

console.log("\nthe CRM's own rates");
r = await as(admin, `select public.partner_admin_set_referral_rate('${A}', 12, null)`);
check(!r.error, "the team sets Asha's direct rate to 12%", r.error?.message);
const d2 = await closed(B, "premium", 50000, "direct");
await db.exec(`insert into public.partner_entitlements (user_id, tier, plan, starts_at, ends_at) values
  ('${B}', 'moveazy_inventory', 'monthly', now() - interval '1 day', now() + interval '30 days')`);
await db.exec(`update public.partner_lead_assignments set closed_at = now() where id = '${d2}'`);
r = await received(d2);
check(one(r)?.commission?.amount === 6000, "12% of ₹50,000 = ₹6,000", JSON.stringify(one(r)));
r = await as(admin, `select public.partner_admin_set_referral_rate('${A}', 35, null)`);
check(/between 0 and 30%/.test(r.error?.message ?? ""), "never more than MovEazy's share", r.error?.message);
r = await as(admin, `select public.partner_admin_set_referral_rate('${A}', null, null)`);
check(!r.error && Number((await wallet(asha)).rates.direct) === 10, "back to the default");
const list = (await as(admin, "select * from public.partner_admin_list()")).rows;
check(list.find((p) => p.name === "Asha")?.referred_count === 2, "the CRM's partner list shows rates and how many each referred", JSON.stringify(list.find((p) => p.name === "Asha")));

console.log("\nundo, and paying out");
r = await received(s1, true);
check(!r.error && one(r).received === false
  && (await db.query(`select count(*)::int n from public.partner_referral_commissions where assignment_id = '${s1}'`)).rows[0].n === 0,
  "undo takes the commission back", r.error?.message);
await received(s1);
const due = one(await as(admin, "select public.crm_referral_commissions()"));
check(due.some((c) => c.referrer === "Asha" && c.status === "due" && c.upi === "asha@okhdfc"), "the CRM lists what's due, with where to pay", JSON.stringify(due.slice(0, 2)));
const cid = (await db.query(`select id from public.partner_referral_commissions where assignment_id = '${d1}'`)).rows[0].id;
r = await as(admin, "select public.crm_referral_commission_paid($1)", [cid]);
check(!r.error && (await notes(A)).some((n) => /sent to you/.test(n.title)), "marked paid; Asha is told", r.error?.message);
r = await as(admin, "select public.crm_referral_commission_paid($1)", [cid]);
check(/that's due/.test(r.error?.message ?? ""), "not twice");
r = await received(d1, true);
check(/already paid out/.test(r.error?.message ?? ""), "a paid commission can't be undone");
const closures = (await as(admin, "select * from public.crm_lead_closures()")).rows;
const c1 = closures.find((c) => c.assignment_id === d1);
check(c1?.received_at && c1.referrer_name === "Asha" && c1.commission === 4000 && c1.commission_status === "paid",
  "closures show received, the referrer and their commission", JSON.stringify(c1));
check(closures.find((c) => c.assignment_id === own)?.referrer_name === null, "…and no referrer where there's none");

console.log("\nthe Wallet");
await db.exec(`with q as (insert into public.partner_lead_requests (broker_id, pack) values ('${B}', 'premium') returning id),
  c as (insert into public.crm_clients (name) values ('Working') returning id)
  insert into public.partner_lead_assignments (request_id, client_id, broker_id, status) select q.id, c.id, '${B}', 'visit' from q, c`);
w = await wallet(asha);
const bw = w.joined.find((j) => j.name === "Bala"), cw = w.joined.find((j) => j.name === "Chetan");
check(w.commission.paid === 4000 && w.commission.due === 2001 + 5000 + 6000, "totals: paid and due", JSON.stringify(w.commission));
check(bw.premium_until && bw.working === 1 && bw.deals.length === 4, "Bala: Premium, 1 lead in hand, 4 deals", JSON.stringify({ p: bw.premium_until, w: bw.working, d: bw.deals.length }));
check(bw.deals.find((d) => Number(d.rent) === 30000 && d.deal_type === "direct")?.status === "none", "the free-pack deal earns nothing, and says so");
check(!cw.premium_until && !cw.trial_until && cw.deals.some((d) => d.amount === 5000), "Chetan: free now, his earlier deal still earned");
check(!JSON.stringify(w).includes("Tenant") && !JSON.stringify(w).includes("Working"), "never a client's name");
w = await wallet(farah);
check(w && w.code === null && w.can_refer === false && w.joined.length === 0, "a partner without Premium still opens their Wallet", JSON.stringify(w));

console.log("\nwho may call what");
r = await as(asha, `select public.crm_lead_closure_received('${d2}')`);
check(/Not allowed/.test(r.error?.message ?? ""), "a partner can't mark a closure received");
r = await as(asha, `select public.partner_admin_set_referral_rate('${A}', 30, 20)`);
check(/Not allowed/.test(r.error?.message ?? ""), "nor set their own rate");
r = await as({ role: "anon" }, "select public.partner_my_referrals()");
check(Boolean(r.error), "signed out: nothing");
r = await as(asha, `select public.partner_premium_at('${B}', now())`);
check(Boolean(r.error), "the helpers aren't callable directly");
r = await as(asha, "select * from public.partner_referral_commissions");
check(Boolean(r.error) || r.rows.length === 0, "the table isn't readable directly");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
