/**
 * Apply society_app.sql (PGlite) over stand-ins of the buildings, inventory
 * and CRM tables and check MovEazy Society end to end:
 *   - a manager sets up a society: pending, off the site, but flats and
 *     invites work; a rejected one goes back for review when edited;
 *   - flats: validation, duplicates, never shown to partners, the owner's
 *     number for the owner app, occupied → available needs a confirmation;
 *   - members: invite links (wrong society, expired, revoked), roles, the
 *     last manager, one society per account, not a tenant lead;
 *   - approval puts available flats live;
 *   - earnings: one month's rent, the society's pool, the manager's split
 *     (equal until set, reset when people join), locked per deal, UPI, paid
 *     with a UTR, cancellation without deleting history;
 *   - move-out reminders; Explore societies behind the live switch;
 *   - who may call what.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});
const read = (f) => readFileSync(new URL(`../${f}`, import.meta.url), "utf8");
const SQL = read("society_app.sql");
const INTAKE = read("lead_intake.sql");
const at = INTAKE.indexOf("create or replace function public.normalize_mobile");
const NORMALIZE = INTAKE.slice(at, INTAKE.indexOf("$$;", at) + 3);

let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};

const U = (n) => `e0000000-0000-0000-0000-0000000000${String(n).padStart(2, "0")}`;
const MGR = U(1), GRD = U(2), STF = U(3), OUT = U(4), MGR2 = U(5), ADMIN = U(9), NOPHONE = U(6);

const db = new PGlite();
await db.exec(`
create role anon; create role authenticated;
grant usage on schema public to anon, authenticated;
create schema auth; grant usage on schema auth to anon, authenticated;
create table auth.users (id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
create function auth.jwt() returns jsonb language sql stable as $$ select jsonb_build_object('email', current_setting('test.email', true)) $$;
${NORMALIZE}
create function public.has_admin_scope(s text) returns boolean language sql stable as $$ select auth.uid() = '${ADMIN}'::uuid $$;
create function public.is_admin_allowlisted() returns boolean language sql stable as $$ select false $$;
create function public.is_crm_staff() returns boolean language sql stable as $$ select auth.uid() = '${ADMIN}'::uuid $$;
create table public.program_settings (id int primary key, property_share numeric default 50);
insert into public.program_settings (id) values (1);
create table public.user_profiles (id uuid primary key, name text default '', email text default '', phone text default '', role text default 'customer');
create table public.user_requirements (user_id uuid primary key, localities text[] default '{}', flat_types text[] default '{}', budget_min numeric, budget_max numeric);
create table public.broker_partners (user_id uuid primary key);
create table public.partner_listings (property_id text, broker_id uuid);
create table public.owner_property_links (property_id text primary key, owner_id uuid);
create table public.dropped (user_id uuid);
create function public.crm_drop_partner_signup_lead(p uuid) returns int language sql security definer as $$ insert into public.dropped values (p); select 1 $$;
create table public.owner_buildings (id uuid primary key default gen_random_uuid(), owner_id uuid, code text unique, name text,
  area text default '', landmark text default '', full_address text default '', latitude numeric, longitude numeric, total_floors int,
  description text default '', amenities text[] default '{}', photos text[] default '{}', kind text default 'building',
  status text default 'active' check (status in ('active', 'paused')), created_by text default '', updated_at timestamptz default now());
create table public.inventory (property_id text primary key, posted_by text, poster_id uuid, broker_id uuid, owner_id uuid, poster_name text,
  city text, area text, landmark text, full_address text, latitude numeric, longitude numeric, rent numeric not null, deposit numeric,
  available_from date, flat_type text, bedrooms int, bathrooms int default 1, furnishing text, amenities text[], title text, description text,
  images text[] default '{}', cover_image_url text default '', status text default 'published', building_id uuid, unit_no text default '',
  area_sqft int, source text default '', partner_visible boolean default true, updated_at timestamptz default now());
create table public.inventory_private (property_id text primary key, source text default 'owner', poc_name text default '', poc_phone text default '',
  owner_onboarded boolean default false, owner_phone text default '', owner_email text default '', created_by text default '', updated_at timestamptz default now());
insert into auth.users values ('${MGR}'), ('${GRD}'), ('${STF}'), ('${OUT}'), ('${MGR2}'), ('${ADMIN}'), ('${NOPHONE}');
insert into public.user_profiles (id, name, email, phone) values
  ('${MGR}', 'Suresh Kumar', 'suresh@x', '9876543210'), ('${GRD}', 'Ramesh Yadav', 'ramesh@x', '9876500002'),
  ('${STF}', 'Anil Singh', 'anil@x', '9876500003'), ('${OUT}', 'Other Manager', 'other@x', '9876500004'),
  ('${MGR2}', 'Deepak', 'deepak@x', '9876500005'), ('${NOPHONE}', 'No Phone', 'np@x', '');
`);
await db.exec(SQL);
await db.exec(SQL);
check(true, "society_app.sql applies, and re-applies over itself");

async function as(who, sql, params = []) {
  await db.exec(`reset role; select set_config('test.uid', '${who ?? ""}', false), set_config('test.email', 'x@x', false);
    set role ${who ? "authenticated" : "anon"};`);
  try { return { rows: (await db.query(sql, params)).rows, error: null }; }
  catch (e) { return { rows: null, error: e }; }
  finally { await db.exec("reset role"); }
}
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const q1 = async (sql) => (await db.query(sql)).rows[0];
const SETUP = {
  name: "Sunrise Residency", area: "HSR Layout", full_address: "27th Main, HSR Layout", latitude: 12.9116, longitude: 77.6389,
  place_id: "ChIJsunrise", google_url: "https://maps.app.goo.gl/abc", towers: ["Tower A", "Tower B"], total_floors: 14, total_flats: 128,
  amenities: ["Gym", "Lift"], rules: { bachelors: true, families: true, pets: false, veg_only: false, notes: "No loud music after 10" },
  maintenance: 4500, year_built: 2016, photos: ["https://x/gate.jpg"],
};
const flat = (o = {}) => ({ block: "Tower A", flat_no: "1203", bhk: "2 BHK", rent: 45000, furnishing: "Fully Furnished",
  occupancy: "available", owner_name: "Rohit Mehta", owner_phone: "+91 98765 43210", notes: "Modular kitchen", ...o });
const save = (who, f) => as(who, "select public.society_flat_save($1::jsonb)", [JSON.stringify(f)]);

console.log("\nsetting up");
let r = await as(NOPHONE, "select public.society_setup_save($1::jsonb)", [JSON.stringify(SETUP)]);
check(/mobile number first/.test(r.error?.message ?? ""), "a number is needed first", r.error?.message);
r = await as(MGR, "select public.society_setup_save($1::jsonb)", [JSON.stringify({ ...SETUP, name: "" })]);
check(/society's name/.test(r.error?.message ?? ""), "the name is required", r.error?.message);
r = await as(MGR, "select public.society_setup_save($1::jsonb)", [JSON.stringify(SETUP)]);
const soc = one(r);
check(soc?.status === "pending" && soc.towers.length === 2 && soc.rules.notes && soc.pool_pct === 70 && /^[A-HJ-NP-Z2-9]{6}$/.test(soc.code),
  "a manager sets up a society: pending, 70% pool, towers and rules saved", r.error?.message ?? JSON.stringify(soc));
const BID = soc?.id;
check((await q1(`select status, kind from public.owner_buildings where id = '${BID}'`)).status === "paused", "…and it stays off the site until approved");
let me = one(await as(MGR, "select public.society_me()"));
check(me?.member?.role === "manager" && me.society?.name === "Sunrise Residency", "they are its manager");
check((await q1(`select count(*)::int n from public.dropped where user_id = '${MGR}'`)).n === 1, "and their number is taken out of tenant leads");
r = await as(MGR, "select public.crm_partner_not_searching($1)", [MGR]);
check(Boolean(r.error), "(the lead check isn't callable by members)");
check((await q1(`select public.crm_partner_not_searching('${MGR}') v`)).v === true, "a member who hasn't searched for a flat isn't a lead");

console.log("\nflats");
r = await save(MGR, flat({ block: "Tower C" }));
check(/building \/ block/.test(r.error?.message ?? ""), "the block must be one of the society's towers", r.error?.message);
r = await save(MGR, flat({ rent: 200 }));
check(/expected rent/.test(r.error?.message ?? ""), "rent is checked", r.error?.message);
r = await save(MGR, flat({ owner_phone: "123" }));
check(/owner's 10-digit/.test(r.error?.message ?? ""), "the owner's number is checked", r.error?.message);
r = await save(MGR, flat({ flat_no: "12 03!" }));
check(/flat number/.test(r.error?.message ?? ""), "the flat number is checked", r.error?.message);
r = await save(MGR, flat({ property_id: "MZ-ABC234" }));
let f1 = one(r);
check(f1?.property_id === "MZ-ABC234" && f1.label === "A-1203" && f1.owner_phone === "9876543210" && f1.live === false,
  "added with the id its photos were uploaded under — labelled A-1203, not live yet", r.error?.message ?? JSON.stringify(f1));
let inv = await q1(`select * from public.inventory where property_id = 'MZ-ABC234'`);
check(inv.status === "paused" && inv.partner_visible === false && inv.source === "society" && inv.building_id === BID
  && inv.area === "HSR Layout" && inv.amenities.join() === "Gym,Lift" && inv.title === "2 BHK in Sunrise Residency",
  "an inventory row: never for partners, the society's place and amenities", JSON.stringify(inv));
let ip = await q1(`select * from public.inventory_private where property_id = 'MZ-ABC234'`);
check(ip.owner_phone === "9876543210" && ip.owner_onboarded === true && ip.poc_name === "Rohit Mehta", "the owner's number goes where the owner app finds it");
r = await save(MGR, flat({ block: "Tower A", flat_no: "1203", rent: 50000 }));
check(one(r)?.duplicate === "MZ-ABC234", "the same block + flat number offers the existing flat instead", JSON.stringify(one(r)));
r = await save(MGR, flat({ flat_no: "804", block: "Tower B", occupancy: "occupied", date: "2026-11-01", bhk: "3 BHK", rent: 62000 }));
const f2 = one(r);
check(f2?.occupancy === "occupied" && f2.move_out_date === "2026-11-01", "an occupied flat is recorded with its move-out date", r.error?.message);
check((await q1(`select status from public.inventory where property_id = '${f2.property_id}'`)).status === "rented", "…and never advertised");

console.log("\nmembers");
r = await as(MGR, "select public.society_invite_create('guard')");
const inv1 = one(r);
check(inv1?.token && inv1.role === "guard", "a manager makes a guard invite link", r.error?.message);
check(one(await as(MGR, "select public.society_invite_create('guard')"))?.token === inv1.token, "asking again shares the same live link");
const peek = one(await as(null, "select public.society_invite_peek($1)", [inv1.token]));
check(peek?.valid === true && peek.society === "Sunrise Residency" && peek.role === "guard", "anyone can see which society a link is for");
r = await as(NOPHONE, "select public.society_invite_accept($1)", [inv1.token]);
check(/mobile number first/.test(r.error?.message ?? ""), "joining needs a number", r.error?.message);
r = await as(GRD, "select public.society_invite_accept($1)", [inv1.token]);
check(one(r)?.joined === true, "a guard joins with the link", r.error?.message);
check(one(await as(GRD, "select public.society_me()"))?.member?.role === "guard", "…as a guard of that society");
r = await as(GRD, "select public.society_invite_create('staff')");
check(/Only a manager/.test(r.error?.message ?? ""), "a guard can't invite", r.error?.message);
r = await as(GRD, "select public.society_setup_save($1::jsonb)", [JSON.stringify(SETUP)]);
check(/Only a manager/.test(r.error?.message ?? ""), "nor change the society's details", r.error?.message);
r = await save(GRD, flat({ flat_no: "502", block: "Tower B", rent: 40000 }));
const f3 = one(r);
check(f3?.label === "B-502", "a guard adds flats", r.error?.message);
let ml = one(await as(GRD, "select public.society_members_list()"));
check(ml.members.length === 2 && ml.members.find((x) => x.role === "manager").phone === "" && ml.can_manage === false,
  "a guard sees the members, not their numbers", JSON.stringify(ml));
await db.exec(`update public.society_invites set expires_at = now() - interval '1 day' where token = '${inv1.token}'`);
r = await as(STF, "select public.society_invite_accept($1)", [inv1.token]);
check(/expired/.test(r.error?.message ?? ""), "an expired link explains itself", r.error?.message);
const inv2 = one(await as(MGR, "select public.society_invite_create('staff')"));
r = await as(STF, "select public.society_invite_accept($1, 'Anil')", [inv2.token]);
check(one(r)?.joined, "staff join with a staff link", r.error?.message);

// Another society, and its manager tries a Sunrise link.
await as(OUT, "select public.society_setup_save($1::jsonb)", [JSON.stringify({ ...SETUP, name: "Green Glen", place_id: "ChIJglen" })]);
r = await as(OUT, "select public.society_invite_accept($1)", [inv2.token]);
check(/already a member of another society/.test(r.error?.message ?? ""), "nobody joins a second society by accident", r.error?.message);
r = await as(OUT, "select public.society_flat($1)", ["MZ-ABC234"]);
check(/isn't in your society/.test(r.error?.message ?? ""), "nor sees another society's flats", r.error?.message);

console.log("\napproval");
r = await as(MGR, "select public.crm_society_decide($1, true)", [BID]);
check(/permission/.test(r.error?.message ?? ""), "only MovEazy approves", r.error?.message);
r = await as(ADMIN, "select public.crm_society_decide($1, false, '')", [BID]);
check(/Say why/.test(r.error?.message ?? ""), "turning down needs a reason", r.error?.message);
await as(ADMIN, "select public.crm_society_decide($1, false, 'Add the tower names properly')", [BID]);
check((await q1(`select status from public.society_accounts where building_id = '${BID}'`)).status === "rejected", "turned down, with the reason");
await as(MGR, "select public.society_setup_save($1::jsonb)", [JSON.stringify(SETUP)]);
check((await q1(`select status from public.society_accounts where building_id = '${BID}'`)).status === "pending", "editing sends it back for review");
await as(ADMIN, "select public.crm_society_decide($1, true)", [BID]);
check((await q1(`select status from public.owner_buildings where id = '${BID}'`)).status === "active"
  && (await q1(`select status from public.inventory where property_id = 'MZ-ABC234'`)).status === "published"
  && (await q1(`select status from public.inventory where property_id = '${f2.property_id}'`)).status === "rented",
  "approved: the society and its available flats go live; occupied ones don't");
check((await q1(`select count(*)::int n from public.society_notifications where user_id = '${MGR}' and kind = 'approved'`)).n === 1, "the manager is told");
r = await save(GRD, flat({ flat_no: "1101", block: "Tower B", rent: 58000 }));
check(one(r)?.live === true, "after approval a new available flat is live at once");

console.log("\noccupied → available");
r = await save(MGR, { ...flat({ flat_no: "804", block: "Tower B", bhk: "3 BHK", rent: 62000 }), property_id: f2.property_id });
check(/Confirm the flat is free/.test(r.error?.message ?? ""), "marking an occupied flat available needs a confirmation", r.error?.message);
r = await save(MGR, { ...flat({ flat_no: "804", block: "Tower B", bhk: "3 BHK", rent: 62000 }), property_id: f2.property_id, confirm_available: true });
check(one(r)?.live === true && one(r).updated_by === "Suresh Kumar", "confirmed: live, and who changed it is recorded", r.error?.message);
const evs = (await db.query(`select action from public.society_events where building_id = '${BID}' and action = 'flat_updated'`)).rows;
check(evs.length === 1, "every edit is in the audit log");
let lst = one(await as(GRD, "select public.society_flats_list('available', 'a-12')"));
check(lst.flats.length === 1 && lst.flats[0].label === "A-1203" && lst.counts.all === 1, "search by flat number, filtered", JSON.stringify(lst?.counts));
lst = one(await as(GRD, "select public.society_flats_list('all', 'ROHIT')"));
check(lst.counts.all === 4, "…or by owner name", JSON.stringify(lst?.counts));
lst = one(await as(GRD, "select public.society_flats_list('all', '')"));
check(lst.counts.all === 4 && lst.counts.available === 4, "counts: all / available / occupied", JSON.stringify(lst.counts));

console.log("\nthe split");
ml = one(await as(MGR, "select public.society_members_list()"));
check(ml.members.every((x) => Math.abs(x.pct - 33.3333) < 0.001), "equal until the manager sets it", JSON.stringify(ml.members.map((x) => x.pct)));
const ids = Object.fromEntries(ml.members.map((x) => [x.role, x.id]));
r = await as(MGR, "select public.society_split_set($1::jsonb)", [JSON.stringify([{ member_id: ids.manager, pct: 50 }, { member_id: ids.guard, pct: 30 }])]);
check(/every member/.test(r.error?.message ?? ""), "every member needs a share", r.error?.message);
r = await as(MGR, "select public.society_split_set($1::jsonb)", [JSON.stringify([{ member_id: ids.manager, pct: 50 }, { member_id: ids.guard, pct: 30 }, { member_id: ids.staff, pct: 10 }])]);
check(/add up to 100/.test(r.error?.message ?? ""), "shares add up to 100%", r.error?.message);
r = await as(GRD, "select public.society_split_set('[]'::jsonb)");
check(/Only a manager/.test(r.error?.message ?? ""), "only a manager sets it", r.error?.message);
r = await as(MGR, "select public.society_split_set($1::jsonb)", [JSON.stringify([{ member_id: ids.manager, pct: 50 }, { member_id: ids.guard, pct: 30 }, { member_id: ids.staff, pct: 20 }])]);
check(one(r)?.split_custom === true, "50 / 30 / 20 set", r.error?.message);
check((await db.query(`select 1 from public.society_events where action = 'split_changed'`)).rows.length === 1, "and logged");

console.log("\na closed deal");
r = await as(MGR, "select public.crm_society_deal_close('MZ-ABC234')");
check(/permission/.test(r.error?.message ?? ""), "only MovEazy records a deal", r.error?.message);
r = await as(ADMIN, "select public.crm_society_deal_close('MZ-ABC234', 45001, null, 'CRM-778')");
const deal = one(r);
check(deal?.pool === 31500, "brokerage = one month's rent; the society's pool is 70% of it (whole rupees)", r.error?.message ?? JSON.stringify(deal));
let pays = (await db.query(`select m.role, p.amount::int, p.share_pct::int from public.society_payouts p join public.society_members m on m.id = p.member_id where p.deal_id = '${deal.id}' order by p.amount desc`)).rows;
check(pays.map((x) => `${x.role}:${x.amount}`).join() === "manager:15750,guard:9450,staff:6300", "shared by the manager's split", JSON.stringify(pays));
check((await q1(`select occupancy from public.society_flats where property_id = 'MZ-ABC234'`)).occupancy === "occupied"
  && (await q1(`select status from public.inventory where property_id = 'MZ-ABC234'`)).status === "rented", "the flat is now occupied, off the site");
r = await as(ADMIN, "select public.crm_society_deal_close('MZ-ABC234')");
check(/last 30 days/.test(r.error?.message ?? ""), "the same flat isn't recorded twice by mistake", r.error?.message);
const note = await q1(`select body from public.society_notifications where user_id = '${GRD}' and kind = 'earning'`);
check(/₹9,450 — add your UPI ID/.test(note?.body ?? ""), "each member is told their share", note?.body);

// Someone new joins: the split goes back to equal, but the deal keeps its split.
const inv3 = one(await as(MGR, "select public.society_invite_create('manager')"));
await as(MGR2, "select public.society_invite_accept($1)", [inv3.token]);
ml = one(await as(MGR, "select public.society_members_list()"));
check(ml.split_custom === false && ml.members.length === 4, "a new member resets the split to equal (managers are told)");
check((await q1(`select count(*)::int n from public.society_payouts where deal_id = '${deal.id}'`)).n === 3, "a closed deal keeps the split it was locked with");

console.log("\npaying");
let e = one(await as(GRD, "select public.society_earnings()"));
check(e.total === 9450 && e.pending === 9450 && e.paid === 0 && e.entries[0].flat === "A-1203" && e.entries[0].pool_amount === 31500 && e.entries[0].deal_ref.length === 8,
  "a member's earnings: total, pending, and the deal behind it", JSON.stringify(e));
const gp = (await q1(`select id from public.society_payouts where deal_id = '${deal.id}' and user_id = '${GRD}'`)).id;
r = await as(ADMIN, "select public.crm_society_payout_paid($1, 'UTR12345678')", [gp]);
check(/hasn't added a UPI/.test(r.error?.message ?? ""), "no UPI ID, no payout", r.error?.message);
r = await as(GRD, "select public.society_profile_save(null, 'ramesh')");
check(/UPI ID/.test(r.error?.message ?? ""), "a UPI ID's format is checked", r.error?.message);
await as(GRD, "select public.society_profile_save(null, 'Ramesh@OKAXIS')");
r = await as(ADMIN, "select public.crm_society_payout_paid($1, 'abc')", [gp]);
check(/UTR/.test(r.error?.message ?? ""), "paying needs the UTR", r.error?.message);
r = await as(ADMIN, "select public.crm_society_payout_paid($1, ' 4123 5678 9012 ')", [gp]);
check(!r.error, "paid with the UTR", r.error?.message);
e = one(await as(GRD, "select public.society_earnings()"));
check(e.paid === 9450 && e.pending === 0 && e.entries[0].utr === "412356789012" && e.upi_id === "ramesh@okaxis", "the member sees it paid, with the reference");
e = one(await as(STF, "select public.society_earnings()"));
check(e.total === 6300 && e.entries.length === 1, "everyone sees only their own payouts");

console.log("\na cancelled deal");
r = await as(ADMIN, "select public.crm_society_deal_cancel($1, 'Tenant backed out')", [deal.id]);
check(!r.error, "a deal can be cancelled", r.error?.message);
const rows = (await db.query(`select p.kind, p.status, p.amount::int, m.role from public.society_payouts p join public.society_members m on m.id = p.member_id where p.deal_id = '${deal.id}' order by m.role, p.kind`)).rows;
check(rows.length === 4 && rows.filter((x) => x.status === "cancelled").length === 2
  && rows.some((x) => x.kind === "adjustment" && x.amount === -9450 && x.role === "guard"),
  "unpaid shares are cancelled, the paid one gets an adjustment — nothing deleted", JSON.stringify(rows));
e = one(await as(GRD, "select public.society_earnings()"));
check(e.total === 0 && e.paid === 0, "the guard's totals net out");

console.log("\npeople leaving");
const mids = Object.fromEntries(one(await as(MGR, "select public.society_members_list()")).members.map((x) => [x.name, x.id]));
r = await as(MGR2, "select public.society_member_update($1, 'guard')", [mids["Deepak"]]);
check(!r.error, "a manager can change a role", r.error?.message);
r = await as(MGR, "select public.society_member_update($1, null, true)", [mids["Suresh Kumar"]]);
check(/at least one manager/.test(r.error?.message ?? ""), "the last manager can't be removed", r.error?.message);
r = await as(MGR, "select public.society_member_update($1, null, true)", [mids["Ramesh Yadav"]]);
check(!r.error && one(await as(GRD, "select public.society_me()"))?.member === null, "a removed guard loses access", r.error?.message);
check((await q1(`select count(*)::int n from public.society_payouts where user_id = '${GRD}'`)).n === 2, "…but their history stays");

console.log("\nmove-out reminders");
await db.exec(`update public.society_flats set occupancy = 'occupied', move_out_date = (now() at time zone 'Asia/Kolkata')::date + 10, created_by = '${STF}' where property_id = '${f3.property_id}'`);
check(one(await as(MGR, "select public.society_tick()")) === 1, "a flat freeing up within 15 days reminds whoever added it");
check(one(await as(MGR, "select public.society_tick()")) === 0, "once");
const rem = await q1(`select title, link from public.society_notifications where user_id = '${STF}' and kind = 'move_out'`);
check(/^B-502 frees up on/.test(rem?.title ?? "") && rem.link === `/flats/${f3.property_id}`, "…pointing at the flat", JSON.stringify(rem));

console.log("\nExplore societies");
let x = one(await as(null, "select public.societies_explore(12.91, 77.64, 10)"));
check(x.live === false && x.societies.length === 0, "off until the CRM switches it live");
x = one(await as(ADMIN, "select public.societies_explore(12.91, 77.64, 10)"));
check(x.societies.length === 1, "staff can preview it");
r = await as(MGR, "select public.crm_society_settings(true)");
check(/permission/.test(r.error?.message ?? ""), "only MovEazy switches it on", r.error?.message);
await as(ADMIN, "select public.crm_society_settings(true, 65)");
x = one(await as(null, "select public.societies_explore(12.91, 77.64, 10)"));
const s0 = x.societies[0];
check(x.live && x.societies.length === 1 && s0.name === "Sunrise Residency" && s0.flats === 2 && s0.min_rent === 58000 && s0.max_rent === 62000
  && s0.km < 1 && s0.latitude === 12.912, "live: approved societies with flats to rent, the neighbourhood not the gate", JSON.stringify(s0));
x = one(await as(null, "select public.societies_explore(13.10, 77.60, 5)"));
check(x.societies.length === 0, "only those near the office");
check(one(await as(null, "select public.society_public($1)", [soc.code]))?.rules?.notes === "No loud music after 10", "the society page shows its rules");
check(one(await as(null, "select public.society_place_known('ChIJsunrise')")) === true && one(await as(null, "select public.society_place_known('ChIJnope')")) === false,
  "the Google proxy only looks up places we list");
const glen = one(await as(OUT, "select public.society_me()")).society;
check(glen.pool_pct === 70, "a society keeps the pool it started with");
await as(ADMIN, "select public.crm_society_set_pool($1, 60)", [BID]);
check(one(await as(MGR, "select public.society_earnings()")).pool_pct === 60, "MovEazy can change one society's pool");

console.log("\nwho may call what");
r = await as(null, "select public.society_me()");
check(Boolean(r.error), "signed out: no app functions");
r = await as(MGR, "select public.crm_societies()");
check(/permission/.test(r.error?.message ?? ""), "members can't open the CRM view", r.error?.message);
r = await as(MGR, "select public.society_json($1)", [BID]);
check(Boolean(r.error), "internal helpers aren't callable");
r = await as(MGR, "select count(*) from public.society_flats");
check(Boolean(r.error) || Number(r.rows?.[0]?.count) === 0, "the tables can't be read directly");
const crm = one(await as(ADMIN, "select public.crm_societies()"));
check(crm.societies.length === 2 && crm.live === true && crm.default_pool_pct === 65 && crm.societies.find((s) => s.name === "Sunrise Residency").no_photos === 2,
  "the CRM sees every society, and which available flats need photos", JSON.stringify(crm.societies.map((s) => [s.name, s.no_photos])));

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
