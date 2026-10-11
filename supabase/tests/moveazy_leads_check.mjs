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
insert into public.premium (user_id) values ('${B2}');
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

console.log("\nasking");
const free = one(await as(asha, `select public.partner_lead_request('free10', '{"areas":["HSR Layout"],"flat_types":["1 BHK"],"budget_max":"35000"}')`));
check(free?.status === "open" && free?.lead_count === 10, "10 free leads: straight to MovEazy to assign", JSON.stringify(free));
check(/already have a request/.test((await as(asha, "select public.partner_lead_request('paid30', '{}', 'UTR123456')")).error?.message || ""), "one request at a time");
const paid = await as(bala, "select public.partner_lead_request('paid30', '{}', '')");
check(/UTR/.test(paid.error?.message || ""), "30 leads need the UTR");
const paidOk = one(await as(bala, "select public.partner_lead_request('paid30', '{}', 'axis 1234 5678')"));
check(paidOk?.status === "payment_check" && paidOk?.lead_count === 30, "with a UTR: waits for MovEazy to check the payment", JSON.stringify(paidOk));
check(/already been used/.test((await as(chetan, "select public.partner_lead_request('paid30', '{}', 'AXIS12345678')")).error?.message || ""), "a UTR pays for one pack only");
check((await as(chetan, "select public.partner_lead_request('premium')")).error?.code === "42501", "unlimited needs Premium");

console.log("\nthe CRM");
check((await as(agent, "select * from public.crm_lead_requests()")).error?.code === "42501", "an agent without partners.manage can't see requests");
const reqs = (await as(admin, "select id, pack, status, broker_name from public.crm_lead_requests()")).rows;
check(reqs?.length === 2, "the admin sees both requests", JSON.stringify(reqs));
const freeId = free.id, paidId = paidOk.id;
check(/Approve the request first/.test((await as(admin, `select public.crm_lead_assign('${paidId}', array['c0000000-0000-0000-0000-000000000001']::uuid[])`)).error?.message || ""), "nothing assigned before the payment is approved");
const cands = (await as(admin, `select client_id, fits from public.crm_lead_candidates('${freeId}')`)).rows;
check(cands?.length === 31 && cands[0].fits === 3 && cands.at(-1).fits < 3, "candidates: fitting ones first", JSON.stringify(cands?.slice(-1)));
const ids = cands.filter((c) => c.fits === 3).slice(0, 12).map((c) => `'${c.client_id}'`).join(",");
const given = one(await as(admin, `select public.crm_lead_assign('${freeId}', array[${ids}]::uuid[])`));
check(given === 10, "12 picked, only 10 given (the pack)", String(given));
check(one(await as(admin, `select status from public.partner_lead_requests where id = '${freeId}'`)) === "fulfilled", "and the request is fulfilled");
check((await db.query(`select count(*)::int n from public.partner_notifications where broker_id = '${B1}' and kind = 'leads_assigned'`)).rows[0].n === 1, "the broker is told");
check((await db.query(`select count(*)::int n from public.crm_activities where body like 'Shared with partner broker Asha%'`)).rows[0].n === 10, "each client's CRM timeline says so");

console.log("\nthe broker's leads");
const mine = (await as(asha, "select id, name, phone, status, flat_types from public.partner_my_assigned_leads()")).rows;
check(mine?.length === 10 && mine[0].phone.startsWith("98765") && mine[0].name.startsWith("Client"), "name and number, once assigned", JSON.stringify(mine?.[0]));
check((await as(bala, "select * from public.partner_my_assigned_leads()")).rows?.length === 0, "nobody else's");
await as(asha, `select public.partner_lead_reach_out('${mine[0].id}', 'whatsapp')`);
check(one(await as(asha, `select status from public.partner_my_assigned_leads() where id = '${mine[0].id}'`)) === "contacted", "tapping WhatsApp logs it and marks contacted");
check((await as(bala, `select public.partner_lead_reach_out('${mine[0].id}', 'call')`)).error?.code === "42501", "can't log a reach-out on someone else's lead");
const cb = (await as(agent, `select broker_name, reach_count from public.crm_client_brokers((select client_id from public.partner_lead_assignments where id = '${mine[0].id}'))`)).rows;
check(cb?.[0]?.broker_name === "Asha" && cb[0].reach_count === 1, "the CRM sees which broker reached out", JSON.stringify(cb));

console.log("\nat most 3 brokers a lead");
await as(admin, `select public.crm_lead_request_decide('${paidId}', true)`);
check(one(await as(admin, `select status from public.partner_lead_requests where id = '${paidId}'`)) === "open", "payment approved: open");
const first = mine[0].id;
const cid = one(await as(admin, `select client_id from public.partner_lead_assignments where id = '${first}'`));
await as(admin, `select public.crm_lead_assign('${paidId}', array['${cid}']::uuid[])`);
await db.exec(`insert into public.premium (user_id) values ('${B3}')`);
const c3 = one(await as(chetan, "select public.partner_lead_request('premium')"));
await as(admin, `select public.crm_lead_assign('${c3.id}', array['${cid}']::uuid[])`);
const d4 = one(await as(deepa, "select public.partner_lead_request('free10')"));
check(one(await as(admin, `select public.crm_lead_assign('${d4.id}', array['${cid}']::uuid[])`)) === 0, "a fourth broker doesn't get the same client");
check(!(await as(admin, `select client_id from public.crm_lead_candidates('${d4.id}')`)).rows.some((r) => r.client_id === cid), "nor is it offered");
const after = one(await as(asha, "select public.partner_moveazy_lead_stats()"));
check(after.total === 30, "and it drops out of the totals brokers see", String(after.total));

console.log("\nPremium");
check(c3?.status === "open" && c3.lead_count === 10, "Premium: 10 a request, nothing to pay");
check(/already have a request/.test((await as(chetan, "select public.partner_lead_request('premium')")).error?.message || ""), "not while the last one is still being filled");
await db.exec(`update public.partner_lead_requests set status = 'fulfilled' where id = '${c3.id}'`);
check(/ask again/.test((await as(chetan, "select public.partner_lead_request('premium')")).error?.message || ""), "and then only once every 3 days");
// Give Chetan 20 Premium leads with no closure.
await db.exec(`update public.partner_lead_requests set created_at = now() - interval '4 days', status = 'fulfilled' where id = '${c3.id}'`);
await db.exec(`insert into public.partner_lead_assignments (request_id, client_id, broker_id)
  select '${c3.id}', id, '${B3}' from public.crm_clients where name like 'Client %' and id <> '${cid}' limit 19`);
const blocked = one(await as(chetan, "select public.partner_lead_request('premium')"));
check(blocked?.status === "needs_approval", "20 given, no closure: the next request waits for MovEazy", JSON.stringify(blocked));

console.log("\nclosing");
const prem = one(await as(chetan, "select id from public.partner_my_assigned_leads() limit 1"));
check((await as(chetan, `select public.partner_lead_update('${prem}', 'closed', 500, 'direct')`)).error?.code === "22023", "closing needs the rent");
const direct = one(await as(chetan, `select public.partner_lead_update('${prem}', 'closed', 30000, 'direct')`));
check(direct?.due_amount === 9000, "Premium, direct with the owner: 30% of the rent due", JSON.stringify(direct));
const prem2 = one(await as(chetan, "select id from public.partner_my_assigned_leads() where status <> 'closed' limit 1"));
const shared = one(await as(chetan, `select public.partner_lead_update('${prem2}', 'closed', 30000, 'shared')`));
check(shared?.due_amount === 6000, "Premium, more than one broker: 20%", JSON.stringify(shared));
const freeLead = mine[1].id;
const freeClose = one(await as(asha, `select public.partner_lead_update('${freeLead}', 'closed', 30000, 'direct')`));
check(freeClose?.due_amount === 0, "a pack lead was paid for up front: nothing due");
const dues = (await as(admin, "select broker_name, due_amount from public.crm_lead_closures()")).rows;
check(dues?.length === 3 && dues.filter((d) => Number(d.due_amount) > 0).length === 2, "the CRM lists every closure with what's due", JSON.stringify(dues));
check((await db.query(`select count(*)::int n from public.crm_activities where body like '%due to MovEazy%'`)).rows[0].n === 2, "and the client's timeline records it");

console.log("\npaying online (Razorpay)");
const E = "b6666666-0000-0000-0000-000000000006";
await db.exec(`insert into auth.users (id) values ('${E}'); insert into public.broker_partners (user_id, name) values ('${E}', 'Esha')`);
const esha = { uid: E };
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
check(await pr("plink_REAL", 200000) === "paid", "paid in full: open for MovEazy to assign");
check(one(await as(admin, `select status from public.partner_lead_requests where id = '${on2.id}'`)) === "open", "no admin check needed");
check(await pr("plink_REAL", 200000) === "already", "Razorpay retrying changes nothing");

console.log("\npayment settings");
check((await as(agent, "select public.crm_set_lead_settings('x@ybl', 2500)")).error?.code === "42501", "only partners.manage changes them");
check(/UPI ID/.test((await as(admin, "select public.crm_set_lead_settings('not a upi', 2500)")).error?.message || ""), "a UPI ID must look like one");
await as(admin, "select public.crm_set_lead_settings('moveazy@icici', 2500)");
const s2 = one(await as(asha, "select public.partner_moveazy_lead_stats()"));
check(s2.upi_id === "moveazy@icici" && s2.pack_price === 2500, "brokers pay the new UPI ID and price");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
