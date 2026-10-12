/**
 * Apply partner_matcher_history.sql (PGlite) over stand-ins of the partner and
 * CRM tables and check the AI matcher's memory end to end:
 *   - lists to MovEazy-assigned tenants from any approved partner (own clients
 *     stay Premium), no phone gate for them, likes on MovEazy's timeline;
 *   - "never suggest again": what this partner sent, what the same mobile
 *     swiped on another partner's list, MovEazy dislikes and passes;
 *   - visits: fix, move, cancel, the assignment moving to 'visit', the
 *     once-a-day reminder;
 *   - who may call what.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});
const read = (f) => readFileSync(new URL(`../${f}`, import.meta.url), "utf8");
const SQL = read("partner_matcher_history.sql");
const INTAKE = read("lead_intake.sql");
const at = INTAKE.indexOf("create or replace function public.normalize_mobile");
const NORMALIZE = INTAKE.slice(at, INTAKE.indexOf("$$;", at) + 3);

let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};

const B1 = "b1111111-0000-0000-0000-000000000001"; // Premium
const B2 = "b2222222-0000-0000-0000-000000000002"; // free pack
const B3 = "b3333333-0000-0000-0000-000000000003"; // pending, not approved
const U1 = "e1111111-0000-0000-0000-000000000001"; // the MovEazy tenant's account
const C1 = "c1111111-0000-0000-0000-000000000001"; // …their CRM row
const L1 = "f1111111-0000-0000-0000-000000000001"; // B1's own client
const A1 = "a1111111-0000-0000-0000-000000000001"; // C1 → B1
const A2 = "a2222222-0000-0000-0000-000000000002"; // C1 → B2

const db = new PGlite();
await db.exec(`
create role anon; create role authenticated;
grant usage on schema public to anon, authenticated;
create schema auth; grant usage on schema auth to anon, authenticated;
create table auth.users (id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
create function auth.jwt() returns jsonb language sql stable as $$ select jsonb_build_object('email', current_setting('test.email', true)) $$;
${NORMALIZE}
create table public.broker_partners (user_id uuid primary key, name text default '', agency text default '', phone text default '', status text default 'approved');
create table public.partner_storefronts (broker_id uuid primary key, photo_url text default '');
create table public.premium (user_id uuid primary key);
create function public.is_approved_partner() returns boolean language sql stable security definer as $$
  select exists (select 1 from public.broker_partners where user_id = auth.uid() and status = 'approved') $$;
create function public.partner_has_tier(t text) returns boolean language sql stable security definer as $$
  select exists (select 1 from public.premium where user_id = auth.uid()) $$;
create table public.inventory (property_id text primary key, title text default '', area text default '', rent numeric, deposit numeric,
  flat_type text default '', bedrooms int, bathrooms int, furnishing text default '', property_type text default '', available_from date,
  images text[] default '{}', cover_image_url text default '', description text default '', status text default 'published',
  src text default 'moveazy');
create function public.partner_inventory() returns table (property_id text, source text) language sql stable security definer as $$
  select i.property_id, i.src from public.inventory i where i.status = 'published' and public.is_approved_partner() $$;
create table public.partner_leads (id uuid primary key default gen_random_uuid(), broker_id uuid, name text, phone text default '',
  status text default 'active');
create table public.partner_tenants (id uuid primary key default gen_random_uuid(), broker_id uuid, phone text, name text default '');
create table public.partner_notifications (id bigint generated always as identity primary key, broker_id uuid, kind text
  constraint partner_notifications_kind_check check (kind in ('tenant_liked', 'list_opened', 'list_done', 'leads_assigned')),
  title text, body text default '', link text default '', created_at timestamptz default now(), read_at timestamptz);
create table public.partner_curated_lists (id uuid primary key default gen_random_uuid(),
  token text not null unique default replace(gen_random_uuid()::text, '-', ''), broker_id uuid not null references auth.users (id),
  lead_id uuid references public.partner_leads (id) on delete set null, lead_name text not null default '',
  property_ids text[] not null, tenant_id uuid, created_at timestamptz not null default now(), opened_at timestamptz, open_count int not null default 0);
create table public.partner_curated_actions (list_id uuid not null references public.partner_curated_lists (id) on delete cascade,
  property_id text not null, action text not null, at timestamptz not null default now(), primary key (list_id, property_id));
create table public.user_profiles (id uuid primary key, phone text default '');
create table public.crm_clients (id uuid primary key, user_id uuid, name text default '', phone text default '');
create table public.crm_activities (id uuid primary key default gen_random_uuid(), client_id uuid references public.crm_clients(id),
  actor_email text default '', type text default 'note', body text default '', meta jsonb default '{}', created_at timestamptz default now());
create table public.crm_shortlists (client_id uuid, property_id text, status text);
create table public.crm_client_passes (client_id uuid, property_id text);
create table public.listing_reactions (user_id uuid, property_id text, reaction text);
create table public.partner_lead_requests (id uuid primary key default gen_random_uuid());
create table public.partner_lead_assignments (id uuid primary key, request_id uuid, client_id uuid references public.crm_clients(id),
  broker_id uuid references auth.users(id), status text not null default 'assigned', updated_at timestamptz default now());

insert into auth.users values ('${B1}'), ('${B2}'), ('${B3}'), ('${U1}');
insert into public.broker_partners (user_id, name, agency, phone) values ('${B1}', 'Asha', 'Asha Homes', '9800000001'), ('${B2}', 'Bala', '', '9800000002');
insert into public.broker_partners (user_id, name, status) values ('${B3}', 'Pending', 'pending');
insert into public.premium values ('${B1}');
insert into public.inventory (property_id, area, rent, flat_type)
  select 'MZ-' || g, 'HSR Layout', 30000 + g * 1000, '2 BHK' from generate_series(1, 8) g;
insert into public.inventory (property_id, area, rent, flat_type, status) values ('MZ-9', 'HSR Layout', 40000, '2 BHK', 'rented');
insert into public.user_profiles values ('${U1}', '9111111111');
insert into public.crm_clients values ('${C1}', '${U1}', 'Riya Sharma', '+91 91111 11111');
insert into public.partner_leads (id, broker_id, name, phone) values ('${L1}', '${B1}', 'Om', '9000000001');
insert into public.partner_lead_requests (id) values ('d0000000-0000-0000-0000-000000000001');
insert into public.partner_lead_assignments (id, request_id, client_id, broker_id) values
  ('${A1}', 'd0000000-0000-0000-0000-000000000001', '${C1}', '${B1}'),
  ('${A2}', 'd0000000-0000-0000-0000-000000000001', '${C1}', '${B2}');
-- What MovEazy already knows about Riya: a dislike, a rejected row, a pass, a dislike on the site, and a like (which is not "never again").
insert into public.crm_shortlists values ('${C1}', 'MZ-4', 'disliked'), ('${C1}', 'MZ-8', 'liked');
insert into public.crm_client_passes values ('${C1}', 'MZ-5');
insert into public.listing_reactions values ('${U1}', 'MZ-6', 'dislike'), ('${U1}', 'MZ-7', 'like');
`);
await db.exec(SQL);
await db.exec(SQL);
check(true, "partner_matcher_history.sql applies, and re-applies over itself");
const kinds = (await db.query("select pg_get_constraintdef(oid) d from pg_constraint where conname = 'partner_notifications_kind_check'")).rows[0].d;
check(/visit_reminder/.test(kinds) && /tenant_liked/.test(kinds) && /leads_assigned/.test(kinds), "notification kinds: visit_reminder added, the rest kept", kinds);

async function as(who, sql, params = []) {
  await db.exec(`reset role; select set_config('test.uid', '${who.uid ?? ""}', false), set_config('test.email', '${who.email ?? ""}', false);
    set role ${who.role ?? "authenticated"};`);
  try { return { rows: (await db.query(sql, params)).rows, error: null }; }
  catch (e) { return { rows: null, error: e }; }
  finally { await db.exec("reset role"); }
}
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const asha = { uid: B1, email: "asha@x" }, bala = { uid: B2, email: "bala@x" }, pending = { uid: B3 }, anon = { role: "anon" };
const send = (who, lead, asg, ids) => as(who, "select public.partner_curated_send($1, $2, $3::text[])", [lead, asg, ids]);

console.log("\nsending");
let r = await send(bala, L1, null, ["MZ-1"]);
check(/Premium|not yours/.test(r.error?.message ?? ""), "a free-pack partner can't send to a client that isn't theirs / without Premium", r.error?.message);
r = await send(bala, null, A1, ["MZ-1"]);
check(/not open with you/.test(r.error?.message ?? ""), "nor to a MovEazy tenant assigned to someone else", r.error?.message);
r = await send(bala, L1, A2, ["MZ-1"]);
check(/one tenant/.test(r.error?.message ?? ""), "one tenant at a time", r.error?.message);
r = await send(bala, null, A2, ["MZ-9"]);
check(/not in your inventory/.test(r.error?.message ?? ""), "only flats they can see", r.error?.message);
r = await send(pending, null, A2, ["MZ-1"]);
check(/Only MovEazy partners/.test(r.error?.message ?? ""), "a partner still pending can't send", r.error?.message);
r = await send(anon, null, A2, ["MZ-1"]);
check(Boolean(r.error), "nor anyone signed out");
r = await send(bala, null, A2, ["MZ-1", "MZ-2", "MZ-3", "MZ-3"]);
const balaList = one(r);
check(balaList?.count === 3 && balaList.token, "a free-pack partner sends a list to their MovEazy tenant (duplicates dropped)", r.error?.message ?? JSON.stringify(balaList));
let asg = (await db.query(`select status from public.partner_lead_assignments where id = '${A2}'`)).rows[0];
check(asg.status === "contacted", "sending moves the assignment to contacted");
let act = (await db.query(`select * from public.crm_activities where meta->>'source' = 'partner_list'`)).rows;
check(act.length === 1 && act[0].type === "partner" && act[0].actor_email === "bala@x" && /Bala sent 3 flats: MZ-1, MZ-2, MZ-3/.test(act[0].body),
  "MovEazy's timeline: who sent which flats (a 'partner' entry, not 'contact')", JSON.stringify(act[0]));

r = await send(asha, L1, null, ["MZ-1", "MZ-7"]);
const ashaOwn = one(r);
check(ashaOwn?.count === 2, "a Premium partner still sends to their own client", r.error?.message);

console.log("\nthe tenant's side");
r = await as(anon, "select public.partner_curated_open($1)", [balaList.token]);
let open = one(r);
check(open?.known === true && open.has_contact === true && open.homes.length === 3, "a MovEazy tenant's list opens without the phone gate", r.error?.message ?? JSON.stringify(open));
r = await as(anon, "select public.partner_curated_open($1)", [ashaOwn.token]);
check(one(r)?.known === false && one(r)?.has_contact === false, "a broker's own client's list still asks for the number");
r = await as(anon, "select public.partner_curated_act($1, 'MZ-1', 'liked')", [ashaOwn.token]);
check(/mobile number first/.test(r.error?.message ?? ""), "…and won't take a swipe before it", r.error?.message);

r = await as(anon, "select public.partner_curated_act($1, 'MZ-1', 'liked')", [balaList.token]);
check(!r.error, "the MovEazy tenant likes a flat", r.error?.message);
await as(anon, "select public.partner_curated_act($1, 'MZ-2', 'skipped')", [balaList.token]);
let note = (await db.query(`select * from public.partner_notifications where broker_id = '${B2}' and kind = 'tenant_liked'`)).rows;
check(note.length === 1 && note[0].title === "Riya Sharma liked a home" && note[0].body.includes("9111111111"), "the partner hears it, with the tenant's number", JSON.stringify(note));
act = (await db.query(`select * from public.crm_activities where meta->>'source' = 'partner_like'`)).rows;
check(act.length === 1 && act[0].actor_email === "" && /Liked 2 BHK · HSR Layout · ₹31,000 \(MZ-1\) on Bala's list/.test(act[0].body),
  "MovEazy's timeline: the like, as the tenant's own activity", JSON.stringify(act[0]));
await as(anon, "select public.partner_curated_act($1, 'MZ-3', 'liked')", [balaList.token]);
note = (await db.query(`select * from public.partner_notifications where broker_id = '${B2}' and kind = 'list_done'`)).rows;
check(note.length === 1 && /♥ 2 liked · ✕ 1 skipped/.test(note[0].body), "and the summary when they finish", JSON.stringify(note));

r = await as(bala, "select public.partner_curated_mine()");
const mine = one(r);
check(mine?.length === 1 && mine[0].assignment_id === A2 && mine[0].tenant?.phone === "9111111111" && mine[0].actions["MZ-1"].action === "liked",
  "the partner's lists carry the MovEazy tenant and what they did", JSON.stringify(mine?.[0]));

console.log("\nnever suggest again");
r = await as(bala, "select public.partner_matcher_seen()");
let seen = one(r);
check(JSON.stringify(seen?.[`asg:${A2}`]) === JSON.stringify(["MZ-1", "MZ-2", "MZ-3", "MZ-4", "MZ-5", "MZ-6"]),
  "for their MovEazy tenant: all 3 they sent, plus MovEazy's dislike, pass and site dislike — not what Riya liked on MovEazy",
  r.error?.message ?? JSON.stringify(seen));
r = await as(asha, "select public.partner_matcher_seen()");
seen = one(r);
check(JSON.stringify(seen?.[`asg:${A1}`]) === JSON.stringify(["MZ-1", "MZ-2", "MZ-3", "MZ-4", "MZ-5", "MZ-6"]),
  "another partner with the same tenant: what Riya swiped on Bala's list (all 3) and MovEazy's no's", JSON.stringify(seen?.[`asg:${A1}`]));
check(JSON.stringify(seen?.[`lead:${L1}`]) === JSON.stringify(["MZ-1", "MZ-7"]), "their own client: what they sent", JSON.stringify(seen?.[`lead:${L1}`]));
await db.exec(`insert into public.partner_tenants (id, broker_id, phone, name) values ('99999999-0000-0000-0000-000000000001', '${B1}', '9000000001', 'Om');
  update public.partner_curated_lists set tenant_id = '99999999-0000-0000-0000-000000000001' where token = '${ashaOwn.token}';`);
await as(anon, "select public.partner_curated_act($1, 'MZ-7', 'skipped')", [ashaOwn.token]);
await db.exec(`insert into public.partner_leads (id, broker_id, name, phone) values ('f2222222-0000-0000-0000-000000000002', '${B2}', 'Om again', '+91 90000 00001')`);
r = await as(bala, "select public.partner_matcher_seen()");
seen = one(r);
check(JSON.stringify(seen?.["lead:f2222222-0000-0000-0000-000000000002"]) === JSON.stringify(["MZ-7"]),
  "same mobile as another partner's client: what they skipped there — and nothing merely sent", JSON.stringify(seen));
r = await as(pending, "select public.partner_matcher_seen()");
check(Boolean(r.error), "a pending partner gets nothing");
r = await as(anon, "select public.partner_matcher_seen()");
check(Boolean(r.error), "nor anyone signed out");

console.log("\nvisits");
const tomorrow = "now() + interval '1 day'";
const visit = (who, lead, a, p, when = tomorrow) => as(who, `select public.partner_visit_set($1, $2, $3, ${when})`, [lead, a, p]);
r = await visit(bala, null, A2, "MZ-1");
const vid = one(r);
check(Boolean(vid), "the partner fixes a visit for a liked flat", r.error?.message);
asg = (await db.query(`select status from public.partner_lead_assignments where id = '${A2}'`)).rows[0];
check(asg.status === "visit", "the assignment moves to visit");
act = (await db.query(`select * from public.crm_activities where meta->>'source' = 'partner_visit'`)).rows;
check(act.length === 1 && /Bala fixed a visit: 2 BHK · HSR Layout · ₹31,000 \(MZ-1\) on \w{3} \d{2} \w{3}, \d{1,2}:\d{2} (am|pm)/.test(act[0].body),
  "MovEazy's timeline: the visit, in IST", JSON.stringify(act[0]?.body));
r = await visit(bala, null, A2, "MZ-1", "now() + interval '2 days'");
check(one(r) === vid, "moving it keeps the same visit");
r = await visit(asha, null, A2, "MZ-1");
check(/not open with you/.test(r.error?.message ?? ""), "another partner can't touch it", r.error?.message);
r = await visit(bala, null, A2, "MZ-1", "now() + interval '200 days'");
check(/three months/.test(r.error?.message ?? ""), "a time months away is refused", r.error?.message);
r = await visit(bala, null, A2, "MZ-9");
check(/no longer in your inventory/.test(r.error?.message ?? ""), "a flat that's gone is refused", r.error?.message);
r = await visit(asha, L1, null, "MZ-7", "date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata' + interval '23 hours'");
check(Boolean(one(r)), "a visit later today for their own client", r.error?.message);

r = await as(asha, "select public.partner_visits_today()");
let today = one(r);
check(today?.length === 1 && today[0].tenant.name === "Om" && today[0].flat.includes("MZ-7"), "today's visits", r.error?.message ?? JSON.stringify(today));
note = (await db.query(`select * from public.partner_notifications where broker_id = '${B1}' and kind = 'visit_reminder'`)).rows;
check(note.length === 1 && note[0].title === "1 visit today" && /Om · 2 BHK/.test(note[0].body), "the first look of the day puts a reminder in the bell", JSON.stringify(note));
await as(asha, "select public.partner_visits_today()");
note = (await db.query(`select count(*)::int n from public.partner_notifications where broker_id = '${B1}' and kind = 'visit_reminder'`)).rows[0].n;
check(note === 1, "only once a day", note);
r = await as(bala, "select public.partner_visits_today()");
check(one(r)?.length === 0, "nothing today for the other partner");
r = await as(bala, "select public.partner_visits_mine()");
check(one(r)?.length === 1 && one(r)[0].tenant.phone === "9111111111", "the partner's upcoming visits");

await as(asha, "select public.partner_visit_cancel($1)", [vid]);
r = await as(bala, "select public.partner_visits_mine()");
check(one(r)?.length === 1, "another partner can't call it off");
await as(bala, "select public.partner_visit_cancel($1)", [vid]);
r = await as(bala, "select public.partner_visits_mine()");
check(one(r)?.length === 0, "the partner calls it off");
act = (await db.query(`select * from public.crm_activities where meta->>'source' = 'partner_visit_cancel'`)).rows;
check(act.length === 1 && /called off the visit to/.test(act[0].body), "and MovEazy sees that too");

r = await as(anon, "select public.partner_visits_mine()");
check(Boolean(r.error), "visits aren't readable signed out");
r = await as(anon, "select * from public.partner_visits");
check(Boolean(r.error), "nor the table");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
