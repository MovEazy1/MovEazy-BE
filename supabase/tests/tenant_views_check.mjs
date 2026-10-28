/**
 * Apply tenant_views.sql (PGlite, over stubs and the files it builds on) and
 * check tenant views:
 *
 *   - a signed-in open is a view (opens add up; seconds add, photos keep the
 *     most); an anonymous one isn't — until that phone opens a link the team
 *     sent, when its opens of the week become that client's, and so do later ones;
 *   - a sent link opened, a swipe, a booking, a ♥ fill the view in as the
 *     tenant's; the team's mark wins and stays; the partner's beats the
 *     tenant's; every answer is in the history; typed reasons are offered after;
 *   - BR Homes: a flat's answer is the building card's, a card's is each flat's;
 *     a visit asked on the QR page is a view of each flat picked;
 *   - partners: their flats the lead viewed, their answer, follow-up, calls,
 *     status — all on the broker's timeline, with the follow-up the team sent;
 *   - owners: MovEazy's viewers listed without number, QR ones with; the board
 *     the same; counts and reasons;
 *   - what's already tracked becomes views once (re-applying adds nothing);
 *   - who may call what.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});
const read = (f) => readFileSync(new URL(`../${f}`, import.meta.url), "utf8");
const fn = (src, name) => {
  const i = src.indexOf(`create or replace function public.${name}(`);
  return src.slice(i, src.indexOf("$$;", src.indexOf("as $$", i) + 5) + 3);
};
let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};

const OWNER = "a0000000-0000-0000-0000-000000000001";
const RAVI = "c0000000-0000-0000-0000-000000000002";
const NEHA = "c0000000-0000-0000-0000-000000000003";
const OLD = "c0000000-0000-0000-0000-000000000004";
const BROKER = "b0000000-0000-0000-0000-000000000005";
const BROKER2 = "b0000000-0000-0000-0000-000000000006";
const BR = "d0000000-0000-0000-0000-000000000007";
const ASHA_C = "e0000000-0000-0000-0000-000000000008";
const REQ = "f0000000-0000-0000-0000-000000000009";

const db = new PGlite();
await db.exec(`
create role anon; create role authenticated;
create schema auth;
grant usage on schema auth to anon, authenticated;
create table auth.users (id uuid primary key, email text);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
create function auth.jwt() returns jsonb language sql stable as $$ select jsonb_build_object('email', current_setting('test.email', true)) $$;
insert into auth.users values ('${OWNER}', 'owner@x.in'), ('${RAVI}', 'ravi@x.in'), ('${NEHA}', 'neha@x.in'), ('${OLD}', 'old@x.in'),
  ('${BROKER}', 'b@x.in'), ('${BROKER2}', 'b2@x.in');
create function public.is_crm_staff() returns boolean language sql stable as $$ select current_setting('test.staff', true) = 'on' $$;
create function public.has_admin_scope(s text) returns boolean language sql stable as $$ select current_setting('test.write', true) = 'on' $$;
create table public.owner_accounts (user_id uuid primary key, status text);
insert into public.owner_accounts values ('${OWNER}', 'approved');
create function public.is_approved_owner() returns boolean language sql stable security definer as $$
  select exists (select 1 from public.owner_accounts where user_id = auth.uid() and status = 'approved') $$;
create table public.broker_partners (user_id uuid primary key, name text default '', phone text default '', email text default '');
insert into public.broker_partners values ('${BROKER}', 'Kiran Realty', '+91 98111 22233'), ('${BROKER2}', 'Other Broker', '9822233344');
create function public.is_approved_partner() returns boolean language sql stable security definer as $$
  select exists (select 1 from public.broker_partners where user_id = auth.uid()) $$;

create table public.owner_buildings (id uuid primary key, owner_id uuid, broker_id uuid, name text, code text,
  status text default 'active', updated_at timestamptz default now());
insert into public.owner_buildings values ('${BR}', '${OWNER}', null, 'BR Homes', 'H33PSH');
create function public.building_by_code(p_code text) returns uuid language sql stable security definer as $$
  select id from public.owner_buildings where code = upper(trim(p_code)) and status = 'active' $$;
create table public.inventory (property_id text primary key, status text default 'published', building_id uuid, unit_no text default '',
  unit_order int, flat_type text default '2 BHK', area text default 'HSR Layout', rent numeric default 25000);
insert into public.inventory (property_id, building_id, unit_no, rent) values ('P1', null, '', 25000), ('P2', null, '', 31000), ('PZ', null, '', 18000),
  ('B1', '${BR}', '101', 22000), ('B2', '${BR}', '102', 23000);
create table public.owner_property_links (owner_id uuid, property_id text, linked_at timestamptz default now());
insert into public.owner_property_links values ('${OWNER}', 'P1'), ('${OWNER}', 'P2'), ('${OWNER}', 'B1'), ('${OWNER}', 'B2');

create table public.crm_clients (id uuid primary key default gen_random_uuid(), user_id uuid unique, name text default '', phone text default '',
  source text default 'app', created_at timestamptz default now());
insert into public.crm_clients (id, user_id, name, phone) values
  ('${ASHA_C}', null, 'Asha', '9845011111'),
  (gen_random_uuid(), '${RAVI}', 'Ravi Kumar', '+91 98450 22222'),
  (gen_random_uuid(), '${OLD}', 'Old Timer', '9845033333');
create table public.crm_activities (id uuid primary key default gen_random_uuid(), client_id uuid, actor_email text default '', type text,
  body text, meta jsonb default '{}', created_at timestamptz default now());

create table public.flat_scans (
  property_id text not null references public.inventory (property_id) on delete cascade,
  visitor text not null check (length(visitor) between 8 and 64),
  day date not null default (now() at time zone 'Asia/Kolkata')::date,
  source text not null default 'link' check (source in ('qr', 'link')),
  created_at timestamptz not null default now(),
  primary key (property_id, visitor, day));
create table public.owner_building_scans (building_id uuid not null, visitor text not null, day date not null default current_date,
  source text not null default 'link', created_at timestamptz not null default now(), primary key (building_id, visitor, day));
create table public.visit_bookings (id uuid primary key default gen_random_uuid(), user_id uuid, property_id text,
  status text default 'scheduled', created_at timestamptz default now());
create table public.owner_building_leads (id uuid primary key default gen_random_uuid(), building_id uuid, name text default '',
  phone text, user_id uuid, property_ids text[] default '{}', visit_at timestamptz, status text default 'new', created_at timestamptz default now());
create table public.owner_building_bookings (property_id text primary key, building_id uuid, booked_by text default '', booked_at timestamptz default now());
create table public.user_profiles (id uuid primary key, email text, name text default '', phone text default '');
insert into public.user_profiles values ('${RAVI}', 'ravi@x.in', 'Ravi Kumar', '9845022222'), ('${NEHA}', 'neha@x.in', 'Neha', '9845044444');
create table public.user_requirements (user_id uuid primary key, whatsapp text default '');
create table public.tenant_profiles (user_id uuid primary key, linkedin text default '', current_company text default '',
  past_company text default '', first_job boolean default false, college text default '', graduation_year int,
  in_bangalore_since text default '', score int default 0);
create function public.website_tenant_ok(p_user uuid, p_property text) returns boolean language sql stable as $$
  select p_user is not null and not exists (select 1 from public.broker_partners b where b.user_id = p_user)
     and not exists (select 1 from public.owner_property_links l where l.property_id = p_property and l.owner_id = p_user) $$;
create function public.website_lead_for_user(p_user uuid, p_property text, p_kind text, p_detail text) returns void language sql as $$ select $$;

create table public.crm_curated_shares (id uuid primary key default gen_random_uuid(), client_id uuid, token text unique);
create table public.crm_shortlists (id uuid primary key default gen_random_uuid(), client_id uuid not null, property_id text not null,
  status text default 'shortlisted', share_token text, opened_at timestamptz, last_opened_at timestamptz, open_count int not null default 0,
  curated_share_id uuid, reacted_at timestamptz, created_at timestamptz default now(), unique (client_id, property_id));
create table public.listing_reactions (user_id uuid not null, property_id text not null, reaction text not null, updated_at timestamptz default now(),
  source text default 'app', recorded_by text default '', primary key (user_id, property_id));

create table public.partner_listings (property_id text, broker_id uuid);
insert into public.partner_listings values ('P1', '${BROKER}'), ('PZ', '${BROKER2}');
create table public.partner_lead_requests (id uuid primary key, broker_id uuid, pack text);
insert into public.partner_lead_requests values ('${REQ}', '${BROKER}', 'website');
create table public.partner_lead_assignments (id uuid primary key default gen_random_uuid(), request_id uuid, client_id uuid, broker_id uuid,
  status text default 'assigned', closed_rent numeric, assigned_at timestamptz default now(), updated_at timestamptz default now(), unique (client_id, broker_id));
create table public.partner_lead_reachouts (id bigint generated always as identity primary key, assignment_id uuid, client_id uuid, broker_id uuid,
  channel text, at timestamptz default now());
create table public.partner_website_interest (id uuid primary key default gen_random_uuid(), broker_id uuid, client_id uuid, property_id text,
  kind text, created_at timestamptz default now());

-- Already tracked before this file: Old Timer opened P2 from a sent link and liked it.
insert into public.crm_shortlists (client_id, property_id, status, share_token, opened_at, open_count, reacted_at)
  select id, 'P2', 'liked', 'tok-old-123', now() - interval '2 days', 3, now() - interval '2 days' from public.crm_clients where user_id = '${OLD}';
`);
await db.exec(fn(read("lead_intake.sql"), "normalize_mobile"));
await db.exec(fn(read("partner_website_leads.sql"), "flat_view"));
await db.exec(fn(read("crm_share_tracking.sql"), "record_share_open"));
await db.exec(read("building_call_desk.sql"));
await db.exec(read("building_tenant_tracks.sql"));
await db.exec(read("building_tenants_board.sql"));
await db.exec(read("owner_qr_overview.sql"));
await db.exec(`grant select, insert, update, delete on all tables in schema public to anon, authenticated;`);
const SQL = read("tenant_views.sql");
await db.exec(SQL);
const hist0 = Object.values((await db.query("select count(*)::int n from public.property_view_responses")).rows[0])[0];
await db.exec(SQL);
check(true, "tenant_views.sql applies, and re-applies over itself");

async function as(who, sql, params = []) {
  await db.exec(`reset role; select set_config('test.uid', '${who.uid ?? ""}', false), set_config('test.staff', '${who.staff ? "on" : ""}', false),
    set_config('test.write', '${who.write ? "on" : ""}', false), set_config('test.email', '${who.email ?? ""}', false); set role ${who.role ?? "authenticated"};`);
  try { return { rows: (await db.query(sql, params)).rows, error: null }; }
  catch (e) { return { rows: null, error: e }; }
  finally { await db.exec("reset role; select set_config('test.uid', '', false)"); }
}
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const q1 = async (sql) => Object.values((await db.query(sql)).rows[0] ?? {})[0];
const agent = { staff: true, write: true, email: "agent@moveazy.co.in" }, viewer = { staff: true }, anon = { role: "anon" };
const ravi = { uid: RAVI }, neha = { uid: NEHA }, broker = { uid: BROKER }, broker2 = { uid: BROKER2 }, owner = { uid: OWNER };
const RAVI_C = await q1(`select id::text from public.crm_clients where user_id = '${RAVI}'`);
const OLD_C = await q1(`select id::text from public.crm_clients where user_id = '${OLD}'`);
const view = (pid, cid) => db.query(`select * from public.property_tenant_views where property_id = $1 and client_id = $2`, [pid, cid]).then((r) => r.rows[0]);

console.log("\nonce: what's already tracked");
let v = await view("P2", OLD_C);
check(v && v.opens === 3 && v.sources.includes("share") && v.liked === "liked" && v.response_by === "tenant", "a sent link opened 3 times and liked", JSON.stringify(v));
check(await q1("select count(*)::int from public.property_view_responses") === hist0, "re-applying adds no history twice");

console.log("\nopens");
await as(ravi, "select public.flat_view('P1', 'ravi-phone-1', 'link')");
await as(ravi, "select public.flat_view('P1', 'ravi-phone-1', 'link')");
v = await view("P1", RAVI_C);
check(v?.opens === 2 && JSON.stringify(v.sources) === '["website"]', "a signed-in open is a view; a second open adds up", JSON.stringify(v));
await as(ravi, "select public.flat_view_engage('P1', 'x', 40, 5)");
await as(ravi, "select public.flat_view_engage('P1', 'x', 20, 3)");
v = await view("P1", RAVI_C);
check(v.seconds === 60 && v.photos === 5, "seconds add up, photos keep the most", `${v.seconds}s ${v.photos}p`);
await as(anon, "select public.flat_view_engage('P1', 'nobody-here', 99999, 999)");
check((await view("P1", RAVI_C)).seconds === 60, "someone else's phone can't add to it");

await as(anon, "select public.flat_view('P2', 'asha-phone-1', 'link')");
check(await q1(`select count(*)::int from public.property_tenant_views where client_id = '${ASHA_C}'`) === 0, "an anonymous open is no view");
await db.exec(`insert into public.crm_shortlists (client_id, property_id, status, share_token) values ('${ASHA_C}', 'P1', 'shared', 'tok-asha-p1')`);
await as(anon, "select public.tenant_visitor_link('tok-asha-p1', 'asha-phone-1')");
v = await view("P2", ASHA_C);
check(v?.opens === 1 && v.sources.includes("website"), "after the sent link: that phone's earlier open is hers", JSON.stringify(v));
await as(anon, "select public.record_share_open('tok-asha-p1')");
v = await view("P1", ASHA_C);
check(v?.opens === 1 && v.sources.includes("share"), "the sent link, opened", JSON.stringify(v));
await as(anon, "select public.flat_view('P1', 'asha-phone-1', 'link')");
await as(anon, "select public.flat_view_engage('P1', 'asha-phone-1', 30, 8)");
v = await view("P1", ASHA_C);
check(v.opens === 2 && v.seconds === 30 && v.photos === 8, "and what that phone opens after", JSON.stringify(v));
await as(anon, "select public.tenant_visitor_link('not-a-token', 'other-phone-9')");
check(await q1("select count(*)::int from public.visitor_clients where visitor = 'other-phone-9'") === 0, "an unknown token links nothing");

console.log("\nresponses");
await db.exec(`update public.crm_shortlists set status = 'disliked', reacted_at = now() where client_id = '${ASHA_C}' and property_id = 'P1'`);
v = await view("P1", ASHA_C);
check(v.liked === "disliked" && v.response_by === "tenant", "a swipe: the tenant's answer", JSON.stringify(v));
await db.exec(`insert into public.listing_reactions (user_id, property_id, reaction) values ('${RAVI}', 'P1', 'dislike')`);
check((await view("P1", RAVI_C)).liked === "disliked", "a ✕ on the website too");
let r = await as(agent, "select public.crm_tenant_view_save('P1', $1, $2::jsonb)",
  [RAVI_C, JSON.stringify({ visit: "done", liked: "liked", liked_status: "will_pay_token", reasons: ["size_small"], note: "Wants June", follow_up_on: "2000-01-02" })]);
check(r.error == null && one(r).response_by === "team" && one(r).liked_status === "will_pay_token" && one(r).reasons.length === 0,
  "the team marks it (no reasons while liked)", r.error?.message ?? JSON.stringify(one(r)));
await db.exec(`update public.listing_reactions set reaction = 'like', updated_at = now() where user_id = '${RAVI}'`);
v = await view("P1", RAVI_C);
check(v.response_by === "team" && v.liked_status === "will_pay_token", "a later swipe doesn't overrule the team");
const hist = one(await as(viewer, "select public.crm_tenant_view_history($1)", [v.id]));
check(hist.length === 3 && hist[0].by === "tenant" && hist[1].by === "team" && hist[1].actor === "agent@moveazy.co.in", "every answer in the history", JSON.stringify(hist.map((h) => h.by)));
r = await as(agent, "select public.crm_tenant_view_save('P2', $1, $2::jsonb)", [ASHA_C, JSON.stringify({ visit: "pending", liked: "disliked", reasons: ["ventilation", "Too noisy"] })]);
check(one(r)?.reasons?.includes("Too noisy") && await q1("select count(*)::int from public.tenant_reason_options where label = 'Too noisy'") === 1,
  "liked or not before a visit; a typed reason is offered after", r.error?.message);
check(/P2 \(2 BHK, HSR Layout\) · Visit pending · Did not like · ventilation, Too noisy/.test(await q1(`select body from public.crm_activities where client_id = '${ASHA_C}' order by created_at desc limit 1`)),
  "on the client's history");
check(Boolean((await as(agent, "select public.crm_tenant_view_save('P1', $1, $2::jsonb)", [RAVI_C, '{"liked": "loved"}'])).error), "an unknown answer is refused");

console.log("\nBR Homes");
r = await as(agent, "select public.crm_tenant_view_save('B1', $1, $2::jsonb)", [ASHA_C, JSON.stringify({ visit: "done", liked: "liked", liked_status: "negotiate" })]);
const card = (await db.query(`select * from public.building_tenant_tracks where building_id = '${BR}' and phone = '9845011111'`)).rows[0];
check(r.error == null && card && card.liked_status === "negotiate" && JSON.stringify(card.property_ids) === '["B1"]', "a flat's answer is the building's card", r.error?.message ?? JSON.stringify(card));
await as(agent, `select public.crm_tenant_track_save('${BR}', $1::jsonb)`,
  [JSON.stringify({ phone: "9845011111", property_ids: ["B1", "B2"], visit: "done", liked: "liked", liked_status: "paid_token" })]);
v = await view("B2", ASHA_C);
check(v?.liked_status === "paid_token" && v.response_by === "team" && (await view("B1", ASHA_C)).liked_status === "paid_token", "a card's answer is each of its flats'", JSON.stringify(v));
await db.exec(`insert into public.owner_building_leads (building_id, name, phone, property_ids, visit_at) values ('${BR}', 'Vikram', '9876500000', array['B2'], now() + interval '1 day')`);
const vik = await q1("select id::text from public.crm_clients where phone = '9876500000'");
v = await view("B2", vik);
check(vik && v?.sources.includes("qr") && v.visit === "pending" && v.response_by === "tenant", "a visit asked on the QR page is a view of the flat", JSON.stringify(v));

console.log("\npartners");
const ASG = await q1(`insert into public.partner_lead_assignments (request_id, client_id, broker_id) values ('${REQ}', '${RAVI_C}', '${BROKER}') returning id::text`);
const ASG_A = await q1(`insert into public.partner_lead_assignments (request_id, client_id, broker_id) values ('${REQ}', '${ASHA_C}', '${BROKER}') returning id::text`);
await db.exec(`insert into public.partner_website_interest (broker_id, client_id, property_id, kind) values ('${BROKER}', '${RAVI_C}', 'P1', 'opened')`);
let pv = one(await as(broker, "select public.partner_lead_views()"));
const mineR = pv.find((x) => x.assignment_id === ASG);
check(mineR?.flats.length === 1 && mineR.flats[0].property_id === "P1" && mineR.flats[0].opens === 2 && mineR.flats[0].liked_status === "will_pay_token",
  "the partner sees which of their flats the lead viewed, and how it went", JSON.stringify(mineR));
r = await as(broker, "select public.partner_view_respond($1, 'P1', $2::jsonb)", [ASG, JSON.stringify({ visit: "done", liked: "disliked", reasons: ["location"] })]);
check(r.error == null && one(r).response_by === "team", "the partner's answer is kept, the team's still stands", r.error?.message);
pv = one(await as(broker, "select public.partner_lead_views()"));
check(pv.find((x) => x.assignment_id === ASG).flats[0].mine?.liked === "disliked", "and the partner sees their own answer");
r = await as(broker, "select public.partner_view_respond($1, 'P1', $2::jsonb)", [ASG_A, JSON.stringify({ visit: "done", liked: "liked", liked_status: "exploring" })]);
check(one(r)?.response_by === "partner" && one(r).liked_status === "exploring", "over the tenant's own, the partner's answer stands", r.error?.message ?? JSON.stringify(one(r)));
check(Boolean((await as(broker, "select public.partner_view_respond($1, 'P2', '{}'::jsonb)", [ASG])).error), "not a flat of theirs");
check(Boolean((await as(broker2, "select public.partner_view_respond($1, 'P1', '{}'::jsonb)", [ASG])).error), "not a lead of theirs");
await db.exec(`insert into public.partner_lead_reachouts (assignment_id, client_id, broker_id, channel) values ('${ASG}', '${RAVI_C}', '${BROKER}', 'call')`);
await db.exec(`update public.partner_lead_assignments set status = 'contacted' where id = '${ASG}'`);
r = await as(broker, "select public.partner_lead_follow_up($1, '2030-05-04', 'Call after 6')", [ASG]);
check(r.error == null && one(r).follow_up_on === "2030-05-04", "the partner sets a follow-up", r.error?.message);
check(Boolean((await as(broker2, "select public.partner_lead_follow_up($1, '2030-05-04', '')", [ASG])).error), "only on their own lead");
await as(viewer, "select public.crm_broker_follow_up_log($1)", [ASG]);
const acts = one(await as(viewer, "select public.crm_client_broker_activity($1)", [RAVI_C]));
const kinds = acts?.[0]?.events.map((e) => e.kind) ?? [];
check(acts?.length === 1 && acts[0].broker_name === "Kiran Realty" && acts[0].broker_phone === "9811122233" && acts[0].follow_up_on === "2030-05-04",
  "the CRM sees the broker who has them", JSON.stringify(acts?.[0] ?? null));
check(["team_follow_up", "follow_up", "status", "call", "response"].every((k) => kinds.includes(k)), "and everything they did, with the team's follow-up", kinds.join(","));
check(acts[0].first_flat?.property_id === "P1" && acts[0].first_flat.rent === 25000 && acts[0].flats_seen === 1, "the flat they came through, for the message", JSON.stringify(acts[0].first_flat));
check(Boolean((await as(ravi, "select public.partner_lead_views()")).error) === false && one(await as(ravi, "select public.partner_lead_views()")).length === 0, "a tenant gets no leads");

console.log("\nowners");
await as(neha, "select public.flat_view('P2', 'neha-phone-1', 'qr')");
let o = one(await as(owner, "select public.owner_qr_overview()"));
const byName = Object.fromEntries((o?.list ?? []).map((p) => [p.name, p]));
check(byName["Old Timer"]?.via === "moveazy" && byName["Old Timer"].phone === "" && byName["Old Timer"].email === "" && byName["Old Timer"].status?.liked === "liked",
  "MovEazy's tenants (a link the team sent): no number", JSON.stringify(byName["Old Timer"]));
check(byName.Asha?.via === "qr" && byName.Asha.phone === "9845011111", "a tenant on the team's building card keeps it, as before", JSON.stringify(byName.Asha));
check(byName["Ravi Kumar"]?.via === "moveazy" && byName["Ravi Kumar"].phone === "" && byName["Ravi Kumar"].status?.liked_status === "will_pay_token",
  "a website viewer too, with where they stand", JSON.stringify(byName["Ravi Kumar"]));
check(byName.Neha?.via === "qr" && byName.Neha.phone === "9845044444", "the owner's QR: name and number as before", JSON.stringify(byName.Neha));
check(o.people === 3 && o.moveazy === 2, "gave contact (Asha, Neha, Vikram) vs via MovEazy (Ravi, Old Timer)", `${o.people} / ${o.moveazy}`);
check(o.liked >= 2 && o.disliked >= 0 && Array.isArray(o.reasons), "liked, not liked, reasons", JSON.stringify({ l: o.liked, d: o.disliked, r: o.reasons }));
await as(ravi, "select public.flat_view('B2', 'ravi-phone-1', 'link')");
const ob = one(await as(owner, `select public.owner_building_tenants('${BR}')`));
const cb = one(await as(viewer, `select public.crm_building_tenants('${BR}')`));
const ownerRavi = ob.tenants.find((x) => x.name === "Ravi Kumar");
const crmRavi = cb.tenants.find((x) => x.name === "Ravi Kumar");
check(ownerRavi?.via === "moveazy" && ownerRavi.phone == null && ownerRavi.views[0].unit_no === "102", "the board: a MovEazy viewer without number for the owner", JSON.stringify(ownerRavi));
check(crmRavi?.phone === "9845022222" && crmRavi.key === ownerRavi.key, "with it for the CRM; the same key", JSON.stringify(crmRavi));
const ashaRow = ob.tenants.find((x) => x.name === "Asha");
check(ashaRow?.via === "team" && ashaRow.phone === "9845011111" && ashaRow.status?.liked_status === "paid_token", "the team's card as before", JSON.stringify(ashaRow));

console.log("\nthe CRM");
const all = one(await as(viewer, "select public.crm_tenant_views()"));
check(all.views.length >= 6 && all.views[0].client?.name && all.views[0].property?.property_id && all.reasons.some((x) => x.label === "Too noisy"), "the Tenant views page", all.views.length);
const s = one(await as(viewer, "select public.crm_tenant_views_summary()"));
check(s.due === 1 && s.open >= 1, "the home bar: open and due", JSON.stringify(s));
const pvw = one(await as(viewer, "select public.crm_property_tenant_views('p1')"));
check(pvw.views.length === 2 && pvw.views.every((x) => x.client.phone), "a property's viewers", pvw.views.length);
const cvw = one(await as(viewer, "select public.crm_client_tenant_views($1)", [ASHA_C]));
check(cvw.views.length === 4 && cvw.views.every((x) => x.property.rent), "a client's views", cvw.views.length);

console.log("\nwho");
for (const [who, name] of [[anon, "anon"], [ravi, "a tenant"], [broker, "a partner"]]) {
  check(Boolean((await as(who, "select public.crm_tenant_views()")).error), `${name} can't read the CRM's views`);
  check(Boolean((await as(who, "select public.crm_tenant_view_save('P1', $1, '{}'::jsonb)", [RAVI_C])).error), `${name} can't mark one`);
}
check(Boolean((await as(viewer, "select public.crm_tenant_view_save('P1', $1, '{}'::jsonb)", [RAVI_C])).error), "staff without client write can't mark one");
check(Boolean((await as(anon, "select public.crm_broker_follow_up_log($1)", [ASG])).error), "anon can't log a follow-up");
check(Boolean((await as(anon, "select public.partner_lead_views()")).error), "anon can't read partner leads");
check(Boolean((await as(viewer, "select public.tenant_view_touch('P1', $1, 'team')", [RAVI_C])).error), "the internals aren't callable");
await db.exec("revoke all on public.property_tenant_views, public.property_view_responses, public.visitor_clients, public.partner_lead_events from anon, authenticated");
check(Boolean((await as(anon, "select * from public.property_tenant_views")).error), "the tables are closed");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
