/**
 * Apply partner_moveazy_leads.sql (PGlite) over a small stand-in of the CRM and
 * partner tables, and check MovEazy leads for brokers end to end:
 * totals only, the three packs and their limits, the CRM approving and
 * assigning (3 brokers a lead at most), reach-outs, and what a closure owes.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});
const SQL = readFileSync(new URL("../partner_moveazy_leads.sql", import.meta.url), "utf8");

let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};

const db = new PGlite();
await db.exec(`
create role anon; create role authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated;
create schema auth;
create table auth.users (id uuid primary key, email text);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
create function auth.jwt() returns jsonb language sql stable as $$ select jsonb_build_object('email', current_setting('test.email', true)) $$;
create function public.is_crm_staff() returns boolean language sql stable as $$ select current_setting('test.staff', true) = 'on' $$;
create function public.has_admin_scope(s text) returns boolean language sql stable as $$
  select current_setting('test.staff', true) = 'on' and s = any (string_to_array(coalesce(current_setting('test.scopes', true), ''), ',')) $$;
create table public.broker_partners (user_id uuid primary key, name text default '', phone text default '', email text default '',
  agency text default '', status text default 'approved');
create function public.is_approved_partner() returns boolean language sql stable security definer as $$
  select exists (select 1 from public.broker_partners where user_id = auth.uid() and status = 'approved') $$;
create table public.premium (user_id uuid primary key);
create table public.inventory (property_id text primary key, area text default '', nearby_areas text[] default '{}', flat_type text default '',
  rent numeric, status text default 'published');
create table public.partner_listings (property_id text primary key references public.inventory (property_id), broker_id uuid not null);
create table public.partner_tiers (tier text primary key, is_free boolean default false);
insert into public.partner_tiers values ('moveazy_inventory', false);
-- Paid Premium, as partner_has_paid_premium() reads it; the test grants it through public.premium.
create view public.partner_entitlements as
  select user_id, 'moveazy_inventory'::text as tier, 'monthly'::text as plan,
         '-infinity'::timestamptz as starts_at, 'infinity'::timestamptz as ends_at from public.premium;
create function public.partner_has_tier(t text) returns boolean language sql stable security definer as $$
  select public.is_crm_staff() or exists (select 1 from public.premium where user_id = auth.uid()) $$;
create table public.partner_notifications (id bigint generated always as identity primary key, broker_id uuid, kind text
  constraint partner_notifications_kind_check check (kind in ('welcome', 'location_request')), title text, body text default '', link text default '');
create table public.program_settings (id int primary key default 1, premium_price int default 1499, updated_at timestamptz default now());
insert into public.program_settings (id) values (1);
create table public.crm_clients (id uuid primary key default gen_random_uuid(), user_id uuid, name text default '', phone text default '',
  status text default 'fresh', attributed_to text not null default 'moveazy', created_at timestamptz default now(), updated_at timestamptz default now());
create table public.crm_client_requirements (client_id uuid primary key references public.crm_clients(id), localities text[] default '{}',
  budget_min numeric, budget_max numeric, flat_types text[] default '{}', occupants text[] default '{}', move_in text default '',
  updated_at timestamptz default now());
create table public.user_requirements (user_id uuid primary key, localities text[] default '{}', budget_min numeric, budget_max numeric,
  flat_types text[] default '{}', occupants text[] default '{}', notes jsonb default '{}', updated_at timestamptz default now());
create table public.crm_activities (id uuid primary key default gen_random_uuid(), client_id uuid references public.crm_clients(id),
  actor_email text default '', type text default 'note', body text default '', meta jsonb default '{}', created_at timestamptz default now());
`);
await db.exec(SQL);
await db.exec(SQL);
check(true, "partner_moveazy_leads.sql applies, and re-applies over itself");
const kinds = (await db.query("select pg_get_constraintdef(oid) d from pg_constraint where conname = 'partner_notifications_kind_check'")).rows[0].d;
check(/welcome/.test(kinds) && /leads_assigned/.test(kinds) && /lead_request/.test(kinds), "notification kinds added, old ones kept", kinds);

console.log("\nmove-in dates");
const mi = async (raw, said = "2026-10-01T10:00:00+05:30") =>
  (await db.query(`select public.lead_move_in_date($1, $2::timestamptz)::text d`, [raw, said])).rows[0].d;
check(await mi("Immediately") === "2026-10-01", "Immediately = the day they said it");
check(await mi("Within 15 days") === "2026-10-16", "Within 15 days");
check(await mi("Within 1 month") === "2026-10-31", "Within 1 month");
check(await mi("Flexible") === null, "Flexible = no date");
check(await mi("2nd Oct") === "2026-10-02", "2nd Oct", await mi("2nd Oct"));
check(await mi("15 Nov 2026") === "2026-11-15", "15 Nov 2026");
check(await mi("2 Jan", "2026-12-10T10:00:00+05:30") === "2027-01-02", "2 Jan said in December is next January", await mi("2 Jan", "2026-12-10T10:00:00+05:30"));
check(await mi("2026-10-20") === "2026-10-20", "an ISO date");
check(await mi("sometime soon") === null, "nonsense = no date");

// People.
const B1 = "b1111111-0000-0000-0000-000000000001", B2 = "b2222222-0000-0000-0000-000000000002";
const B3 = "b3333333-0000-0000-0000-000000000003", B4 = "b4444444-0000-0000-0000-000000000004";
const PEND = "b5555555-0000-0000-0000-000000000005";
await db.exec(`
insert into auth.users (id) values ('${B1}'), ('${B2}'), ('${B3}'), ('${B4}'), ('${PEND}');
insert into public.broker_partners (user_id, name, phone) values ('${B1}', 'Asha', '9876500001'), ('${B2}', 'Bala', '9876500002'),
  ('${B3}', 'Chetan', '9876500003'), ('${B4}', 'Deepa', '9876500004');
insert into public.broker_partners (user_id, name, status) values ('${PEND}', 'Pending', 'pending');
`);
// 30 MovEazy clients in HSR wanting a 1 BHK, ₹20-35k, moving within 15 days; plus the ones that must not count.
await db.exec(`
insert into public.crm_clients (id, name, phone)
  select ('c0000000-0000-0000-0000-' || lpad(g::text, 12, '0'))::uuid, 'Client ' || g, '98765' || lpad(g::text, 5, '0') from generate_series(1, 30) g;
insert into public.crm_client_requirements (client_id, localities, flat_types, budget_max, move_in, updated_at)
  select id, '{HSR Layout}', '{1 BHK}', 30000, 'Within 15 days', now() from public.crm_clients;
insert into public.crm_clients (id, name, phone, attributed_to) values ('d0000000-0000-0000-0000-000000000001', 'Broker''s own', '9000000001', '${B1}');
insert into public.crm_client_requirements (client_id, budget_max) values ('d0000000-0000-0000-0000-000000000001', 30000);
insert into public.crm_clients (id, name, status) values ('d0000000-0000-0000-0000-000000000002', 'Closed one', 'closed_by_us');
insert into public.crm_client_requirements (client_id, budget_max) values ('d0000000-0000-0000-0000-000000000002', 30000);
insert into public.crm_clients (id, name) values ('d0000000-0000-0000-0000-000000000003', 'Nothing to go on');
insert into public.crm_clients (id, name, created_at, updated_at) values ('d0000000-0000-0000-0000-000000000004', 'Gone quiet', now() - interval '90 days', now() - interval '90 days');
insert into public.crm_client_requirements (client_id, budget_max, updated_at) values ('d0000000-0000-0000-0000-000000000004', 30000, now() - interval '90 days');
-- one who answered on the site: 2 BHK in Koramangala, ₹55k, flexible
insert into public.crm_clients (id, user_id, name, phone) values ('d0000000-0000-0000-0000-000000000005', 'e0000000-0000-0000-0000-000000000005', 'Site lead', '9111111111');
insert into public.user_requirements (user_id, localities, flat_types, budget_max, notes) values
  ('e0000000-0000-0000-0000-000000000005', '{Koramangala}', '{2 BHK}', 55000, '{"moveInDate":"Flexible"}');
`);

async function as(who, sql, params = []) {
  await db.exec(`reset role; select set_config('test.uid', '${who.uid ?? ""}', false), set_config('test.email', '${who.email ?? ""}', false),
    set_config('test.staff', '${who.staff ? "on" : ""}', false), set_config('test.scopes', '${(who.scopes ?? []).join(",")}', false);
    set role ${who.role ?? "authenticated"};`);
  try { return { rows: (await db.query(sql, params)).rows, error: null }; }
  catch (e) { return { rows: null, error: e }; }
  finally { await db.exec("reset role"); }
}
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const asha = { uid: B1, email: "asha@x" }, bala = { uid: B2, email: "bala@x" }, chetan = { uid: B3 }, deepa = { uid: B4 };
const admin = { uid: "a0000000-0000-0000-0000-000000000001", email: "ops@moveazy.co.in", staff: true, scopes: ["partners.manage"] };
const agent = { uid: "a0000000-0000-0000-0000-000000000002", email: "agent@moveazy.co.in", staff: true };

console.log("\nwhat brokers see");
const stats = one(await as(asha, "select public.partner_moveazy_lead_stats()"));
check(stats?.total === 31, "31 open MovEazy clients with something to go on, active lately (not a broker's own, closed, empty or quiet ones)", JSON.stringify(stats?.total));
check(stats?.bhk_area?.[0]?.bhk === "1 BHK" && stats.bhk_area[0].area === "HSR Layout" && stats.bhk_area[0].n === 30, "top set: 30 looking for a 1 BHK in HSR Layout", JSON.stringify(stats?.bhk_area?.[0]));
check(stats?.move_in?.week === 0 && stats?.move_in?.month === 30 && stats?.move_in?.flexible === 1, "move-in buckets", JSON.stringify(stats?.move_in));
check(stats?.budget?.b20_35 === 30 && stats?.budget?.b50plus === 1, "budget bands", JSON.stringify(stats?.budget));
check(stats?.pack_price === 2000 && stats?.upi_id === "8090911024@pthdfc", "price and UPI to pay");
check(!JSON.stringify(stats).includes("98765") && !JSON.stringify(stats).includes("Client 1"), "no number, no name anywhere in it");
check((await as({ uid: PEND }, "select public.partner_moveazy_lead_stats()")).error?.code === "42501", "a broker not yet approved can't");
check((await as({ role: "anon" }, "select public.partner_moveazy_lead_stats()")).error?.code === "42501", "anon can't");
check((await as(asha, "select * from public.partner_lead_requests")).rows?.length === 0, "the tables themselves show brokers nothing");

console.log("\nthe free 10: matched to the broker's own flats");
const flat = (id, broker, area, type, rent, status = "published") =>
  db.exec(`insert into public.inventory (property_id, area, flat_type, rent, status) values ('${id}', '${area}', '${type}', ${rent}, '${status}');
           insert into public.partner_listings (property_id, broker_id) values ('${id}', '${broker}');`);
await flat("A-1", B1, "HSR Layout", "1 BHK", 28000);
await flat("A-2", B1, "HSR Layout", "1 BHK", 30000, "rented");
const noFlats = await as(asha, "select public.partner_lead_request('free10')");
check(/at least 3 available flats first \(1 of 3 added\)/.test(noFlats.error?.message || ""), "fewer than 3 available flats: asked to add them (a let-out one doesn't count)", noFlats.error?.message);
check(one(await as(asha, "select public.partner_moveazy_lead_stats()"))?.flats_live === 1, "the stats say how many are live");
await flat("A-3", B1, "Koramangala", "2 BHK", 60000);
await flat("A-4", B1, "Whitefield", "3 BHK", 90000);
const free = one(await as(asha, "select public.partner_lead_request('free10')"));
check(free?.status === "fulfilled" && free?.assigned === 10, "3 live flats: 10 tenants who fit them, at once", JSON.stringify(free));
const ashaFirst = (await db.query(`select c.name, a.assigned_by from public.partner_lead_assignments a join public.crm_clients c on c.id = a.client_id where a.broker_id = '${B1}'`)).rows;
check(ashaFirst.every((r) => r.name.startsWith("Client ")) && ashaFirst.every((r) => r.assigned_by === "auto · fits your flats"),
  "HSR 1 BHK tenants within budget — her HSR flat's fit — marked as matched to her flats", JSON.stringify(ashaFirst.slice(0, 2)));
check(one(await as(asha, "select public.partner_free_leads_topup()")) === 0, "already 10: topping up gives nothing");
check((await db.query(`select count(*)::int n from public.partner_notifications where broker_id = '${B1}' and kind = 'leads_assigned'`)).rows[0].n === 1, "she's told");
check((await db.query(`select count(*)::int n from public.crm_activities where body like 'Shared with partner broker Asha%'`)).rows[0].n === 10, "each client's CRM timeline says so");

console.log("\nasking again, and paying");
const paid = await as(bala, "select public.partner_lead_request('paid30', '{}', '')");
check(/UTR/.test(paid.error?.message || ""), "30 leads need the UTR");
const paidOk = one(await as(bala, "select public.partner_lead_request('paid30', '{}', 'axis 1234 5678')"));
check(paidOk?.status === "payment_check" && paidOk?.lead_count === 30 && paidOk?.assigned === 0,
  "even a first ₹2,000 pack waits for the payment to be checked", JSON.stringify(paidOk));
check(/already have a request/.test((await as(bala, "select public.partner_lead_request('free10')")).error?.message || ""), "one request at a time");
check(/already been used/.test((await as(chetan, "select public.partner_lead_request('paid30', '{}', 'AXIS12345678')")).error?.message || ""), "a UTR pays for one pack only");
check((await as(chetan, "select public.partner_lead_request('premium')")).error?.code === "42501", "unlimited needs Premium");
const again = one(await as(asha, "select public.partner_lead_request('paid30', '{}', 'UTR123456')"));
check(again?.status === "payment_check", "Asha's second ask goes through MovEazy");

console.log("\nthe CRM");
check((await as(agent, "select * from public.crm_lead_requests()")).error?.code === "42501", "an agent without partners.manage can't see requests");
const reqs = (await as(admin, "select id, pack, status, broker_name from public.crm_lead_requests()")).rows;
check(reqs?.length === 3, "the admin sees all three requests", JSON.stringify(reqs));
const paidId = paidOk.id, againId = again.id;
check(/Approve the request first/.test((await as(admin, `select public.crm_lead_assign('${againId}', array['c0000000-0000-0000-0000-000000000001']::uuid[])`)).error?.message || ""), "nothing assigned before the payment is approved");
await as(admin, `select public.crm_lead_request_decide('${paidId}', true)`);
const balaGot = (await db.query(`select count(*)::int n from public.partner_lead_assignments where broker_id = '${B2}'`)).rows[0].n;
check(balaGot === 30 && one(await as(admin, `select status from public.partner_lead_requests where id = '${paidId}'`)) === "fulfilled",
  "Bala's first ask, payment approved: his 30 given at once", String(balaGot));
check((await db.query(`select count(*)::int n from public.partner_lead_assignments where broker_id = '${B2}' and client_id = 'd0000000-0000-0000-0000-000000000005'`)).rows[0].n === 0,
  "the best 30 — the flexible one, with no move-in date, comes last and is left out");
await as(admin, `select public.crm_lead_request_decide('${againId}', true)`);
check(one(await as(admin, `select status from public.partner_lead_requests where id = '${againId}'`)) === "open"
  && (await db.query(`select count(*)::int n from public.partner_lead_assignments where request_id = '${againId}'`)).rows[0].n === 0,
  "a later request, approved: open for the team to pick, nothing given automatically");
const cands = (await as(admin, `select client_id, fits from public.crm_lead_candidates('${againId}')`)).rows;
check(cands?.length === 21 && cands.at(-1).client_id === "d0000000-0000-0000-0000-000000000005", "candidates: not hers already, soonest move-in first", JSON.stringify(cands?.length));
const ids = cands.slice(0, 12).map((c) => `'${c.client_id}'`).join(",");
check(one(await as(admin, `select public.crm_lead_assign('${againId}', array[${ids}]::uuid[])`)) === 12, "the team gives the 12 it picked");

console.log("\nthe broker's leads");
const mine = (await as(asha, "select id, name, phone, status, flat_types, pack from public.partner_my_assigned_leads()")).rows;
check(mine?.length === 22 && mine[0].phone.startsWith("98765") && mine[0].name.startsWith("Client"), "name and number, once assigned", JSON.stringify(mine?.length));
check((await as(deepa, "select * from public.partner_my_assigned_leads()")).rows?.length === 0, "nobody else's");
await as(asha, `select public.partner_lead_reach_out('${mine[0].id}', 'whatsapp')`);
check(one(await as(asha, `select status from public.partner_my_assigned_leads() where id = '${mine[0].id}'`)) === "contacted", "tapping WhatsApp logs it and marks contacted");
check((await as(bala, `select public.partner_lead_reach_out('${mine[0].id}', 'call')`)).error?.code === "42501", "can't log a reach-out on someone else's lead");
const cb = (await as(agent, `select broker_name, reach_count from public.crm_client_brokers((select client_id from public.partner_lead_assignments where id = '${mine[0].id}'))`)).rows;
check(cb?.find((r) => r.broker_name === "Asha")?.reach_count === 1, "the CRM sees which broker reached out", JSON.stringify(cb));

console.log("\nPremium partners don't buy packs");
await db.exec(`insert into public.premium (user_id) values ('${B4}')`);
check(/Premium partner/.test((await as(deepa, "select public.partner_lead_request('paid30', '{}', 'HDFC99887766')")).error?.message || ""), "no ₹2,000 pack for a Premium partner");
check(/Premium partner/.test((await as(deepa, "select public.partner_lead_request('free10')")).error?.message || ""), "nor the free 10");
await db.exec(`delete from public.premium where user_id = '${B4}'`);

console.log("\nat most 3 brokers a lead");
await db.exec(`insert into public.premium (user_id) values ('${B3}')`);
const c3 = one(await as(chetan, "select public.partner_lead_request('premium')"));
check(c3?.status === "fulfilled" && c3.assigned === 10, "Chetan's first Premium ask: 10 at once, nothing to pay", JSON.stringify(c3));
await flat("D-1", B4, "HSR Layout", "1 BHK", 25000);
await flat("D-2", B4, "HSR Layout", "1 BHK", 29000);
await flat("D-3", B4, "BTM Layout", "1 RK", 12000);
const d4 = one(await as(deepa, "select public.partner_lead_request('free10')"));
const maxBrokers = (await db.query("select max(n)::int m from (select count(*) n from public.partner_lead_assignments group by client_id) x")).rows[0].m;
check(maxBrokers === 3, "with four brokers asking, no client went to more than 3", String(maxBrokers));
check(d4?.assigned === 10, "Deepa still gets her 10, all from clients under 3 brokers", JSON.stringify(d4));
const full = one(await as(admin, "select client_id from public.partner_lead_assignments group by client_id having count(*) = 3 limit 1"));
check(one(await as(admin, `select public.crm_lead_assign('${againId}', array['${full}']::uuid[])`)) === 0, "the team can't give a client a fourth broker either");
const after = one(await as(asha, "select public.partner_moveazy_lead_stats()"));
const fullCount = (await db.query("select count(*)::int n from (select client_id from public.partner_lead_assignments group by client_id having count(*) >= 3) x")).rows[0].n;
check(after.total === 31 - fullCount, "clients with 3 brokers drop out of the totals brokers see", `${after.total} vs ${31 - fullCount}`);

console.log("\nPremium");
check(/ask again/.test((await as(chetan, "select public.partner_lead_request('premium')")).error?.message || ""), "one Premium request every 3 days");
// 20 Premium leads and no closure.
await db.exec(`update public.partner_lead_requests set created_at = now() - interval '4 days' where id = '${c3.id}'`);
await db.exec(`insert into public.partner_lead_assignments (request_id, client_id, broker_id)
  select '${c3.id}', c.id, '${B3}' from public.crm_clients c
   where not exists (select 1 from public.partner_lead_assignments a where a.client_id = c.id and a.broker_id = '${B3}') limit 10`);
const blocked = one(await as(chetan, "select public.partner_lead_request('premium')"));
check(blocked?.status === "needs_approval" && blocked.assigned === 0, "20 given, no closure: the next request waits for MovEazy", JSON.stringify(blocked));

console.log("\nclosing");
const prem = one(await as(chetan, "select id from public.partner_my_assigned_leads() limit 1"));
check((await as(chetan, `select public.partner_lead_update('${prem}', 'closed', 500, 'direct')`)).error?.code === "22023", "closing needs the rent");
const direct = one(await as(chetan, `select public.partner_lead_update('${prem}', 'closed', 30000, 'direct')`));
check(direct?.due_amount === 9000, "Premium, direct with the owner: 30% of the rent due", JSON.stringify(direct));
const prem2 = one(await as(chetan, "select id from public.partner_my_assigned_leads() where status <> 'closed' limit 1"));
const shared = one(await as(chetan, `select public.partner_lead_update('${prem2}', 'closed', 30000, 'shared')`));
check(shared?.due_amount === 6000, "Premium, more than one broker: 20%", JSON.stringify(shared));
const freeLead = mine.find((m) => m.pack === "free10").id;
const freeClose = one(await as(asha, `select public.partner_lead_update('${freeLead}', 'closed', 30000, 'direct')`));
check(freeClose?.due_amount === 0, "a pack lead was paid for up front: nothing due");
const dues = (await as(admin, "select broker_name, due_amount from public.crm_lead_closures()")).rows;
check(dues?.length === 3 && dues.filter((d) => Number(d.due_amount) > 0).length === 2, "the CRM lists every closure with what's due", JSON.stringify(dues));
check((await db.query(`select count(*)::int n from public.crm_activities where body like '%due to MovEazy%'`)).rows[0].n === 2, "and the client's timeline records it");

console.log("\nfew fits now, more as flats are added");
const G = "b8888888-0000-0000-0000-000000000008";
await db.exec(`insert into auth.users (id) values ('${G}'); insert into public.broker_partners (user_id, name) values ('${G}', 'Gita')`);
const gita = { uid: G };
await flat("G-1", G, "Koramangala", "2 BHK", 50000);
await flat("G-2", G, "Whitefield", "3 BHK", 90000);
await flat("G-3", G, "Indiranagar", "2 BHK", 70000);
const g1 = one(await as(gita, "select public.partner_lead_request('free10')"));
check(g1?.status === "fulfilled" && g1.assigned === 1, "only the one tenant who fits her flats (the Koramangala 2 BHK) — no filler", JSON.stringify(g1));
check(/already have a request/.test((await as(gita, "select public.partner_lead_request('paid30', '{}', 'GITA12345678')")).error?.message || "") === false,
  "a part-filled free 10 doesn't block buying the ₹2,000 pack");
await db.exec(`delete from public.partner_lead_requests where broker_id = '${G}' and pack = 'paid30'`);
await flat("G-4", G, "HSR Layout", "1 BHK", 27000);
const topped = one(await as(gita, "select public.partner_free_leads_topup()"));
const gTotal = (await db.query(`select count(*)::int n from public.partner_lead_assignments where broker_id = '${G}'`)).rows[0].n;
check(topped > 0 && gTotal <= 10 && gTotal === 1 + topped, "an HSR flat added: more tenants fit, topped up to at most 10", `${topped} / ${gTotal}`);
check(/already used/.test((await as(gita, "select public.partner_lead_request('free10')")).error?.message || ""), "the free 10 stays once");
// Give the pool back, so later scenarios have clients under 3 brokers.
await db.exec(`delete from public.partner_lead_assignments where broker_id = '${G}'`);

console.log("\npaying online (Razorpay)");
const E = "b6666666-0000-0000-0000-000000000006";
await db.exec(`insert into auth.users (id) values ('${E}'); insert into public.broker_partners (user_id, name) values ('${E}', 'Esha')`);
const esha = { uid: E };
// Free some clients up, so there's something left to give.
await db.exec(`delete from public.partner_lead_assignments where broker_id = '${B4}'`);
const on1 = one(await as(esha, "select public.partner_lead_request('paid30', '{}', '', true)"));
check(on1?.status === "awaiting_payment" && on1.amount === 2000, "online: waits for Razorpay, no UTR needed", JSON.stringify(on1));
const on2 = one(await as(esha, "select public.partner_lead_request('paid30', '{}', '', true)"));
check(on2?.status === "awaiting_payment" && one(await as(admin, `select status from public.partner_lead_requests where id = '${on1.id}'`)) === "cancelled",
  "starting again drops the payment they left");
check((await as(esha, `select public.partner_lead_razorpay_paid('${on2.id}', 'plink_X', 'pay_1', 200000)`)).error?.code === "42501", "a broker can't mark it paid");
await db.exec(`update public.partner_lead_requests set link_id = 'plink_REAL' where id = '${on2.id}'`);
const pr = async (link, amt) => (await db.query(`select public.partner_lead_razorpay_paid('${on2.id}', '${link}', 'pay_ABC123', ${amt}) r`)).rows[0].r;
check(await pr("plink_OTHER", 200000) === "wrong_link", "not our link: ignored");
check(await pr("plink_REAL", 150000) === "short", "too little: ignored");
check(await pr("plink_REAL", 200000) === "paid", "paid in full");
check((await db.query(`select count(*)::int n from public.partner_lead_assignments where request_id = '${on2.id}'`)).rows[0].n > 0,
  "her first ask, paid online: leads given at once, no admin check");
check(await pr("plink_REAL", 200000) === "already", "Razorpay retrying changes nothing");

console.log("\nrequests already open when this arrives");
const F = "b7777777-0000-0000-0000-000000000007";
await db.exec(`insert into auth.users (id) values ('${F}'); insert into public.broker_partners (user_id, name) values ('${F}', 'Farah')`);
const waiting = (await db.query(`insert into public.partner_lead_requests (broker_id, pack, lead_count, status) values ('${F}', 'free10', 10, 'open') returning id`)).rows[0].id;
await db.exec(SQL);
check((await db.query(`select count(*)::int n from public.partner_lead_assignments where request_id = '${waiting}'`)).rows[0].n === 0,
  "re-running the file doesn't fill later requests behind the team's back");
await db.exec("drop function public.lead_auto_assign(uuid, text)");
await db.exec(SQL);
check((await db.query(`select count(*)::int n from public.partner_lead_assignments where request_id = '${waiting}' and assigned_by = 'auto · backfill'`)).rows[0].n > 0,
  "but the first time it arrives, every open request gets its leads");

console.log("\npayment settings");
check((await as(agent, "select public.crm_set_lead_settings('x@ybl', 2500)")).error?.code === "42501", "only partners.manage changes them");
check(/UPI ID/.test((await as(admin, "select public.crm_set_lead_settings('not a upi', 2500)")).error?.message || ""), "a UPI ID must look like one");
await as(admin, "select public.crm_set_lead_settings('moveazy@icici', 2500)");
const s2 = one(await as(asha, "select public.partner_moveazy_lead_stats()"));
check(s2.upi_id === "moveazy@icici" && s2.pack_price === 2500, "brokers pay the new UPI ID and price");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
