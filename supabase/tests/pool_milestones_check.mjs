/**
 * Apply partner_pool_milestones.sql (PGlite, over stubs) and check: other
 * partners' and MovEazy's flats come back anonymous (no lister, number or
 * place) and with no contacts; group flats stay open; a tenant's like on the
 * partner's curated list unlocks that one flat and rings both partners; the
 * pool count; complete flats, milestone leads (trial/Premium now, free on
 * upgrade), the streak; MovEazy's share on milestone leads; the CRM's lead
 * counts; and the one-time referral reward gone.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});
const read = (f) => readFileSync(new URL(`../${f}`, import.meta.url), "utf8");
const SQL = read("partner_pool_milestones.sql");

let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};

const A = "a0000000-0000-0000-0000-000000000001"; // trial partner, curating
const B = "b0000000-0000-0000-0000-000000000002"; // lists a flat for all partners
const G = "c0000000-0000-0000-0000-000000000003"; // in A's group
const F = "f0000000-0000-0000-0000-000000000004"; // free plan
const GROUP = "90000000-0000-0000-0000-000000000009";
const db = new PGlite();
await db.exec(`
create role anon; create role authenticated;
create schema auth;
create table auth.users (id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
create function public.is_crm_staff() returns boolean language sql stable as $$ select current_setting('test.staff', true) = 'on' $$;
insert into auth.users values ('${A}'), ('${B}'), ('${G}'), ('${F}');
create table public.broker_partners (user_id uuid primary key, name text, email text default '', phone text default '', agency text default '', status text default 'approved',
  operational_areas text[] default '{}');
insert into public.broker_partners (user_id, name, phone, operational_areas) values
  ('${A}', 'Arjun', '9000000001', '{HSR Layout}'), ('${B}', 'Bina', '9000000002', '{}'), ('${G}', 'Gopal', '9000000003', '{}'), ('${F}', 'Farhan', '9000000004', '{BTM Layout}');
create function public.is_approved_partner() returns boolean language sql stable security definer as $$
  select exists (select 1 from public.broker_partners where user_id = auth.uid() and status = 'approved') $$;
create table public.partner_tiers (tier text, is_free boolean);
insert into public.partner_tiers values ('moveazy_inventory', false);
create table public.partner_entitlements (user_id uuid, tier text, plan text, starts_at timestamptz, ends_at timestamptz);
insert into public.partner_entitlements values ('${A}', 'moveazy_inventory', 'trial', now() - interval '1 day', now() + interval '20 days');
create function public.partner_premium_at(p_user uuid, p_at timestamptz default now()) returns boolean language sql stable security definer as $$
  select exists (select 1 from public.partner_entitlements e where e.user_id = p_user and e.tier = 'moveazy_inventory'
                  and coalesce(p_at, now()) >= e.starts_at and coalesce(p_at, now()) < e.ends_at) $$;
create function public.partner_has_tier(t text) returns boolean language sql stable security definer as $$ select public.partner_premium_at(auth.uid()) $$;
create table public.program_settings (id int primary key, property_share numeric);
insert into public.program_settings values (1, 50);
create table public.inventory (property_id text primary key, status text default 'published', title text default '', city text default 'Bengaluru',
  area text default '', nearby_areas text[] default '{}', full_address text default '', landmark text default '', latitude numeric, longitude numeric,
  rent numeric default 0, deposit numeric default 0, available_from date, property_type text default 'Apartment', flat_type text default '',
  bedrooms int, bathrooms int, furnishing text default '', amenities text[] default '{}', description text default '', images text[] default '{}',
  cover_image_url text default '', is_verified boolean default false, poster_name text default '', phone text default '', posted_by text default 'owner',
  partner_visible boolean default true, rent_flag text default '', source text default '', created_at timestamptz default now(), updated_at timestamptz default now());
create table public.partner_listings (property_id text primary key, broker_id uuid);
create table public.partner_platform_shares (property_id text primary key, share_pct numeric);
create table public.partner_groups (id uuid primary key, name text);
insert into public.partner_groups values ('${GROUP}', 'HSR brokers');
create table public.partner_group_members (group_id uuid, user_id uuid);
insert into public.partner_group_members values ('${GROUP}', '${A}'), ('${GROUP}', '${G}');
create table public.partner_group_shares (property_id text, group_id uuid, share_pct numeric);
create table public.partner_location_requests (property_id text, requested_by uuid, status text);
create table public.partner_property_contacts (property_id text, role text, name text, phone text, availability text default '', verified boolean default false);
create table public.owner_property_links (property_id text, owner_id uuid, broker_contact boolean default true);
create table public.partner_leads (id uuid primary key default gen_random_uuid(), broker_id uuid, name text, phone text default '');
create table public.partner_curated_lists (id uuid primary key default gen_random_uuid(), broker_id uuid, lead_id uuid, assignment_id uuid, lead_name text default '',
  property_ids text[], created_at timestamptz default now());
create table public.partner_curated_actions (list_id uuid, property_id text, action text, at timestamptz default now(), primary key (list_id, property_id));
create table public.partner_notifications (id bigint generated always as identity primary key, broker_id uuid, kind text, title text, body text default '',
  link text default '', constraint partner_notifications_kind_check check (kind in ('leads_assigned')));
create table public.crm_clients (id uuid primary key default gen_random_uuid(), name text, phone text);
create table public.crm_activities (client_id uuid, actor_email text, type text, body text, meta jsonb, created_at timestamptz default now());
create table public.partner_lead_requests (id uuid primary key default gen_random_uuid(), broker_id uuid not null, pack text not null
  constraint partner_lead_requests_pack_check check (pack in ('free10', 'paid30', 'premium', 'website')), lead_count int not null, amount int default 0,
  utr text default '', prefs jsonb default '{}', status text default 'open', note text default '', decided_by text default '', decided_at timestamptz,
  created_at timestamptz default now(), updated_at timestamptz default now());
create table public.partner_lead_assignments (id uuid primary key default gen_random_uuid(), request_id uuid not null, client_id uuid not null, broker_id uuid not null,
  status text default 'assigned', closed_rent numeric, deal_type text, due_amount numeric default 0, closed_at timestamptz, assigned_by text default '',
  assigned_at timestamptz default now(), updated_at timestamptz default now(), unique (client_id, broker_id));
create table public.partner_lead_reachouts (assignment_id uuid, client_id uuid, broker_id uuid, channel text, at timestamptz default now());
-- 30 tenants in the pool; lead_give hands out what it's given, up to the request's room.
insert into public.crm_clients (name, phone) select 'Tenant ' || g, '98450000' || lpad(g::text, 2, '0') from generate_series(1, 30) g;
create function public.lead_candidates_for_flats(p uuid) returns table (client_id uuid, fits int, property_id text) language sql stable as $$
  select c.id, 4, null::text from public.crm_clients c
   where not exists (select 1 from public.partner_lead_assignments a where a.client_id = c.id and a.broker_id = p) order by c.name limit 6 $$;
create function public.lead_candidates(r uuid) returns table (client_id uuid) language sql stable as $$
  select c.id from public.crm_clients c, public.partner_lead_requests q
   where q.id = r and not exists (select 1 from public.partner_lead_assignments a where a.client_id = c.id and a.broker_id = q.broker_id) order by c.name desc $$;
create function public.lead_give(p_request uuid, p_clients uuid[], p_actor text) returns int language plpgsql as $$
declare q public.partner_lead_requests; n int := 0; cid uuid; room int;
begin
  select * into q from public.partner_lead_requests where id = p_request;
  room := q.lead_count - (select count(*) from public.partner_lead_assignments a where a.request_id = q.id);
  foreach cid in array coalesce(p_clients, '{}') loop
    exit when n >= room;
    insert into public.partner_lead_assignments (request_id, client_id, broker_id, assigned_by) values (q.id, cid, q.broker_id, p_actor) on conflict do nothing;
    n := n + 1;
  end loop;
  return n;
end $$;
create function public.inventory_from_crm(p text) returns boolean language sql immutable as $$ select coalesce(p, '') in ('crm', 'facebook', 'whatsapp', 'portal', 'other') $$;
create table public.partner_plans (id text primary key, referral_reward int);
insert into public.partner_plans values ('trial_1m', 500), ('pro_5m', 1500);
create table public.partner_referrals (id uuid primary key default gen_random_uuid(), referrer_id uuid, referee_id uuid unique, amount int default 1500);
`);
await db.exec(SQL);
await db.exec(SQL);
check(true, "partner_pool_milestones.sql applies, and re-applies over itself");

async function as(who, sql) {
  await db.exec(`reset role; select set_config('test.uid', '${who.uid ?? ""}', false), set_config('test.staff', '${who.staff ? "on" : ""}', false);
    set role ${who.role ?? "authenticated"};`);
  try { return { rows: (await db.query(sql)).rows, error: null }; }
  catch (e) { return { rows: null, error: e }; }
  finally { await db.exec("reset role"); }
}
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const q1 = async (sql) => Object.values((await db.query(sql)).rows[0] ?? {})[0];
const arjun = { uid: A };

// Flats: A's own, B's for all partners, G's for the group, MovEazy's own, B's group-only (not A's group).
const full = `rent, flat_type, area, cover_image_url, images, furnishing, deposit, full_address, landmark, latitude, longitude, phone, poster_name`;
await db.exec(`insert into public.inventory (property_id, ${full}) values
  ('A1', 25000, '2 BHK', 'HSR Layout', 'a.jpg', '{b.jpg,c.jpg}', 'Semi', 75000, '12 27th Main', 'Near BDA', 12.91, 77.64, '', ''),
  ('B1', 30000, '2 BHK', 'HSR Layout', 'a.jpg', '{}', '', 0, '5 19th Main', 'Opp park', 12.92, 77.65, '', ''),
  ('G1', 28000, '1 BHK', 'BTM Layout', '', '{}', '', 0, '9 BTM', '', 12.91, 77.61, '', ''),
  ('M1', 40000, '3 BHK', 'Koramangala', 'm.jpg', '{}', '', 0, '1 Kora', 'Forum', 12.93, 77.62, '9111111111', 'Owner Ojas')`);
await db.exec(`insert into public.partner_listings values ('A1', '${A}'), ('B1', '${B}'), ('G1', '${G}');
  insert into public.partner_platform_shares values ('B1', 50);
  insert into public.partner_group_shares values ('G1', '${GROUP}', 40)`);

console.log("\nthe pool is anonymous");
let r = await as(arjun, "select property_id, source, anonymous, lister_name, lister_phone, full_address, latitude, brokerage_pct from public.partner_inventory() order by property_id");
const inv = Object.fromEntries((r.rows ?? []).map((x) => [x.property_id, x]));
check(r.error == null && inv.A1 && !inv.A1.anonymous && inv.A1.full_address === "12 27th Main", "their own flat: everything", r.error?.message);
check(inv.B1 && inv.B1.anonymous && inv.B1.lister_name == null && inv.B1.lister_phone == null && inv.B1.full_address === "" && inv.B1.latitude == null
  && Number(inv.B1.brokerage_pct) === 50, "another partner's flat: anonymous, with the share", JSON.stringify(inv.B1));
check(inv.G1 && !inv.G1.anonymous && inv.G1.lister_name === "Gopal", "a group flat: open, as before", JSON.stringify(inv.G1));
check(inv.M1 && inv.M1.anonymous && inv.M1.full_address === "", "MovEazy's own flat: anonymous", JSON.stringify(inv.M1));
r = await as(arjun, "select count(*)::int from public.partner_property_contacts_for('B1')");
check(r.error == null && one(r) === 0, "no one to call on an anonymous flat", r.error?.message);
r = await as(arjun, "select public.partner_pool_count()");
check(r.error == null && one(r) === 3, "the pool count: everything but their own", r.error?.message);

console.log("\na tenant likes it on their curated list");
const list = await q1(`insert into public.partner_curated_lists (broker_id, lead_name, property_ids) values ('${A}', 'Ravi', '{B1,M1,A1,G1}') returning id`);
await db.exec(`insert into public.partner_curated_actions (list_id, property_id, action) values ('${list}', 'B1', 'liked'), ('${list}', 'A1', 'liked'), ('${list}', 'G1', 'liked')`);
r = await as(arjun, "select anonymous, lister_name, lister_phone, full_address from public.partner_inventory() where property_id = 'B1'");
check(r.error == null && r.rows[0].anonymous === false && r.rows[0].lister_name === "Bina" && r.rows[0].lister_phone === "9000000002" && r.rows[0].full_address === "",
  "unlocked: the listing partner's name and number (the exact place stays theirs)", JSON.stringify(r.rows?.[0]));
r = await as(arjun, "select name, phone from public.partner_property_contacts_for('B1')");
check(r.error == null && r.rows.length === 1 && r.rows[0].phone === "9000000002", "and a contact to call", JSON.stringify(r.rows));
r = await as(arjun, "select anonymous from public.partner_inventory() where property_id = 'M1'");
check(r.rows[0].anonymous === true, "only the liked flat unlocks");
let n = (await db.query(`select * from public.partner_notifications order by id`)).rows;
check(n.length === 2 && n[0].broker_id === A && n[0].kind === "pool_unlocked" && /Ravi liked a partner's 2 BHK in HSR Layout/.test(n[0].title)
  && n[1].broker_id === B && n[1].kind === "pool_interest" && /Arjun \(9000000001\) wants to set up a visit/.test(n[1].body),
  "both partners hear; their own and group flats don't unlock anything", JSON.stringify(n));
await db.exec(`update public.partner_curated_actions set action = 'skipped' where property_id = 'B1'; update public.partner_curated_actions set action = 'liked' where property_id = 'B1'`);
check(await q1("select count(*)::int from public.partner_notifications") === 2, "liking it again: no second bell");
await db.exec(`insert into public.partner_curated_actions (list_id, property_id, action) values ('${list}', 'M1', 'liked')`);
r = await as(arjun, "select count(*)::int from public.partner_property_contacts_for('M1')");
check(r.error == null && one(r) === 1, "MovEazy's flat liked: its contact unlocks", r.error?.message);
await db.exec(`insert into public.partner_entitlements values ('${G}', 'moveazy_inventory', 'trial', now() - interval '1 day', now() + interval '20 days')`);
r = await as({ uid: G }, "select anonymous from public.partner_inventory() where property_id = 'B1'");
check(r.rows[0].anonymous === true, "still anonymous for everyone else");

console.log("\nmilestones");
// A complete flat the CRM added for them: doesn't count.
await db.exec(`insert into public.inventory (property_id, source, ${full}) values ('C1', 'crm', 25000, '2 BHK', 'HSR Layout', 'a.jpg', '{b.jpg,c.jpg}', 'Semi', 75000, '', '', null, null, '', '');
  insert into public.partner_listings values ('C1', '${A}')`);
r = await as(arjun, "select public.partner_upload_progress()");
let pr = one(r);
check(r.error == null && pr.complete === 1 && pr.total === 1 && pr.next === 3 && pr.milestones.length === 0, "1 complete flat: next is 3", r.error?.message ?? JSON.stringify(pr));
check(await q1("select public.partner_flat_complete(i) from public.inventory i where property_id = 'B1'") === false, "a flat with only rent, BHK, area and a photo isn't complete");
await db.exec(`insert into public.inventory (property_id, ${full}) select 'A' || g, 20000, '1 BHK', 'HSR Layout', 'x.jpg', '{y.jpg,z.jpg}', 'Full', 50000, '', '', null, null, '', ''
  from generate_series(2, 3) g; insert into public.partner_listings select 'A' || g, '${A}' from generate_series(2, 3) g`);
r = await as(arjun, "select public.partner_upload_progress()");
pr = one(r);
check(r.error == null && pr.complete === 3 && pr.next === 10 && pr.milestones[0].given === 10, "3 complete: 10 leads given at once", r.error?.message ?? JSON.stringify(pr));
check(await q1(`select count(*)::int from public.partner_lead_assignments where broker_id = '${A}'`) === 10
  && await q1(`select pack from public.partner_lead_requests where broker_id = '${A}'`) === "milestone", "…under a milestone request");
check((await db.query(`select title from public.partner_notifications where kind = 'milestone'`)).rows[0]?.title === "Milestone reached: 3 flats — 10 fresh leads unlocked", "and a bell");
check(pr.streak.days === 1 && pr.streak.active && pr.streak.today_done, "streak day 1: the day they reached 3", JSON.stringify(pr.streak));
r = await as(arjun, "select public.partner_upload_progress()");
check(await q1(`select count(*)::int from public.partner_lead_assignments where broker_id = '${A}'`) === 10, "asking again gives nothing more");
await db.exec(`update public.inventory set created_at = created_at - interval '1 day' where property_id in ('A1', 'A2', 'A3')`);
await db.exec(`insert into public.inventory (property_id, ${full}) select 'A' || g, 20000, '1 BHK', 'HSR Layout', 'x.jpg', '{y.jpg,z.jpg}', 'Full', 50000, '', '', null, null, '', ''
  from generate_series(4, 8) g; insert into public.partner_listings select 'A' || g, '${A}' from generate_series(4, 8) g`);
r = await as(arjun, "select public.partner_upload_progress()");
pr = one(r);
check(r.error == null && pr.today === 5 && pr.streak.days === 2 && pr.streak.today_done, "5 more today: a 2-day streak", JSON.stringify(pr.streak));
await db.exec(`insert into public.inventory (property_id, ${full}) select 'A' || g, 20000, '1 BHK', 'HSR Layout', 'x.jpg', '{y.jpg,z.jpg}', 'Full', 50000, '', '', null, null, '', ''
  from generate_series(9, 20) g; insert into public.partner_listings select 'A' || g, '${A}' from generate_series(9, 20) g`);
r = await as(arjun, "select public.partner_upload_progress()");
pr = one(r);
check(r.error == null && pr.complete === 20 && pr.next == null && pr.milestones.map((m) => m.milestone).join() === "3,10,20"
  && pr.milestones[2].given === 20 && pr.milestones[1].awarded_at == null, "20 complete: 20 more leads; 10 has no reward", JSON.stringify(pr.milestones));

console.log("\na free partner");
await db.exec(`insert into public.inventory (property_id, ${full}) select 'F' || g, 20000, '1 BHK', 'BTM Layout', 'x.jpg', '{y.jpg,z.jpg}', 'Full', 50000, '', '', null, null, '', ''
  from generate_series(1, 3) g; insert into public.partner_listings select 'F' || g, '${F}' from generate_series(1, 3) g`);
r = await as({ uid: F }, "select public.partner_upload_progress()");
pr = one(r);
check(r.error == null && pr.plan_ok === false && pr.milestones[0].awarded_at == null && await q1(`select count(*)::int from public.partner_lead_assignments where broker_id = '${F}'`) === 0,
  "reached 3 on the free plan: kept for later", r.error?.message);
await db.exec(`insert into public.partner_entitlements values ('${F}', 'moveazy_inventory', 'trial', now(), now() + interval '30 days')`);
check(await q1(`select count(*)::int from public.partner_lead_assignments where broker_id = '${F}'`) === 10, "starting a trial gives the 10");

console.log("\nclosing, the CRM, referrals");
const aid = await q1(`select id from public.partner_lead_assignments where broker_id = '${A}' limit 1`);
r = await as(arjun, `select public.partner_lead_update('${aid}', 'closed', 30000, 'direct')`);
check(r.error == null && Number(one(r).due_amount) === 9000, "a milestone lead closes with MovEazy's 30%", r.error?.message);
await db.exec(`insert into public.partner_lead_reachouts (assignment_id, client_id, broker_id, channel) select id, client_id, broker_id, 'whatsapp' from public.partner_lead_assignments where broker_id = '${A}' limit 2`);
r = await as({ uid: A, staff: true }, "select public.crm_partner_leads(null)");
const sum = one(r)?.[A];
check(r.error == null && sum.total === 30 && sum.closed === 1 && sum.untouched === 28, "CRM: each partner's leads by status", r.error?.message ?? JSON.stringify(sum));
r = await as({ uid: A, staff: true }, `select public.crm_partner_leads('${A}')`);
check(r.error == null && one(r).length === 30 && one(r).some((x) => x.pack === "milestone" && x.reach_count === 1 && x.last_channel === "whatsapp"), "CRM: each lead, with the reach-outs");
r = await as({ uid: A }, "select public.crm_partner_leads(null)");
check(Boolean(r.error), "not staff: refused");
await db.exec(`insert into public.partner_referrals (referrer_id, referee_id) values ('${A}', '${F}')`);
check(await q1("select count(*)::int from public.partner_referrals") === 0 && await q1("select max(referral_reward) from public.partner_plans") === 0, "no more one-time referral rewards");
r = await as({ role: "anon" }, "select public.partner_pool_count()");
check(Boolean(r.error), "anon can't call the pool count");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
