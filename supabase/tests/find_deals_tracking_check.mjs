/**
 * Apply find_deals_tracking.sql (PGlite, in-process) over find_deals.sql and
 * check who looked at the deals:
 *
 *   - a page open counts once a day per browser; opens and ♥ only count for a
 *     flat that is a deal on screen right now;
 *   - a browser that gave its number is that CRM client: their open and ♥ reach
 *     the client's tenant views (source "deal"), and a first ♥ tells the team
 *     and the flat's partner (never the tenant's number to the partner);
 *   - a visit booked for a flat that is a deal right now tells them too;
 *   - the CRM sees people / identified, and per flat opens, likes and visits
 *     that week, and who; nobody else does.
 *
 * tenant_views.sql and the partner tables are stubbed to what this file calls.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});

const file = (name) => readFileSync(new URL(`../${name}`, import.meta.url), "utf8")
  .replace(/create extension if not exists "pgcrypto";/g, "");
const ownerCheck = readFileSync(new URL("./owner_check.mjs", import.meta.url), "utf8");
const PRELUDE = ownerCheck.split("const PRELUDE = `")[1].split("`;")[0];

let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};
async function as(db, who, sql) {
  await db.exec(`
    reset role;
    select set_config('test.uid', '${who.uid ?? ""}', false),
           set_config('test.email', '${who.email ?? ""}', false),
           set_config('test.staff', '${who.staff ? "on" : ""}', false),
           set_config('test.super', '', false),
           set_config('test.scopes', '${(who.scopes ?? []).join(",")}', false);
    set role ${who.role ?? "authenticated"};
  `);
  try {
    const res = await db.query(sql);
    return { rows: res.rows, error: null };
  } catch (e) {
    return { rows: null, error: e };
  } finally {
    await db.exec("reset role");
  }
}
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const q = async (db, sql) => (await db.query(sql)).rows;

const anon = { role: "anon" };
const agent = { uid: "c1111111-0000-0000-0000-000000000005", email: "agent@moveazy.co.in", staff: true, scopes: ["crm.clients.read"] };
const tenantUser = { uid: "a1111111-0000-0000-0000-000000000009", email: "meera@example.com" };
const RAVI = "b1111111-0000-0000-0000-000000000001";
const MEERA = "b1111111-0000-0000-0000-000000000002";
const BROKER = "d1111111-0000-0000-0000-000000000006";
const K1 = "a".repeat(32); // Ravi's browser, gave his number
const K2 = "b".repeat(32); // a browser that never did
const K3 = "c".repeat(32); // Meera's browser, signed in

const db = new PGlite();
await db.exec(PRELUDE);
await db.exec(file("inventory_schema.sql"));
await db.exec(`alter table public.inventory
  add column if not exists nearby_areas text[], add column if not exists landmark text, add column if not exists latitude double precision,
  add column if not exists longitude double precision, add column if not exists max_flatmates int, add column if not exists gender_pref text,
  add column if not exists occupants_allowed text[], add column if not exists maintenance numeric, add column if not exists floor_number int,
  add column if not exists total_floors int, add column if not exists lifestyle text[], add column if not exists house_rules text[],
  add column if not exists is_verified boolean default false, add column if not exists full_address text`);
await db.exec(file("find_deals.sql"));
// What this file uses from elsewhere, as small as it can be.
await db.exec(`
alter table public.crm_notifications add column if not exists client_id uuid;
create table public.lead_intake (lead_key text primary key, phone text default '', crm_client_id uuid);
create table public.visit_bookings (id uuid primary key default gen_random_uuid(), user_id uuid not null, property_id text not null,
  slot_at timestamptz, status text not null default 'scheduled', created_at timestamptz not null default now());
create table public.partner_listings (property_id text, broker_id uuid);
create table public.partner_notifications (id bigint generated always as identity primary key, broker_id uuid not null, kind text not null,
  title text not null, body text not null default '', link text not null default '', created_at timestamptz not null default now(), read_at timestamptz,
  constraint partner_notifications_kind_check check (kind = any (array['follow_ups', 'visit_assigned']::text[])));
create table public.tv_calls (fn text, property_id text, client_id uuid, source text, opens int, said jsonb);
create function public.crm_team_emails() returns setof text language sql stable as $$ select unnest(array['a@moveazy.co.in', 'b@moveazy.co.in']) $$;
create function public.tenant_view_touch(p_property text, p_client uuid, p_source text, p_at timestamptz default now(),
  p_opens int default 0, p_seconds int default 0, p_photos int default 0, p_min_opens int default 0)
returns uuid language plpgsql as $$
begin insert into public.tv_calls values ('touch', p_property, p_client, p_source, p_opens, null); return gen_random_uuid(); end $$;
create function public.tenant_view_respond(p_view uuid, p_by text, p_actor text, p_broker uuid, p jsonb, p_at timestamptz default now())
returns void language plpgsql as $$ begin insert into public.tv_calls values ('respond', null, null, p_by, null, p); end $$;
`);
await db.exec(file("find_deals_tracking.sql"));
await db.exec(file("find_deals_tracking.sql"));
check(true, "find_deals_tracking.sql applies, and re-applies over itself");
const kinds = (await q(db, "select pg_get_constraintdef(oid) d from pg_constraint where conname = 'partner_notifications_kind_check'"))[0].d;
check(/deal/.test(kinds) && /follow_ups/.test(kinds) && /visit_assigned/.test(kinds), "partner notifications gain 'deal', keeping their kinds", kinds);

await db.exec(`
insert into public.crm_clients (id, user_id, name, phone) values ('${RAVI}', null, 'Ravi Kumar', '9876500001'), ('${MEERA}', '${tenantUser.uid}', 'Meera Nair', '9876500002');
insert into public.lead_intake (lead_key, phone, crm_client_id) values ('${K1}', '9876500001', '${RAVI}'), ('${K2}', '', null);
insert into public.inventory (property_id, posted_by, area, rent, status, flat_type) values
  ('MZ-S1', 'owner', 'HSR', 40000, 'published', '2 BHK'), ('MZ-S2', 'owner', 'HSR', 25000, 'published', '1 BHK'),
  ('MZ-NOT', 'owner', 'HSR', 30000, 'published', '2 BHK'), ('MZ-D1', 'owner', 'HSR', 18000, 'published', '1 RK');
insert into public.steal_deals (week_start, property_id, sort) values (public.deal_this_monday(), 'MZ-S1', 1), (public.deal_this_monday(), 'MZ-S2', 2);
insert into public.day_deals (day, kind, property_id) values ((now() at time zone 'Asia/Kolkata')::date - 1, '1rk', 'MZ-D1');
insert into public.partner_listings values ('MZ-S1', '${BROKER}');
`);

console.log("\nthe visitor");
let r = await as(db, anon, `select public.deal_track('${K2}', 'steal', 'page')`);
check(!r.error, "anyone opening the page is counted", r.error?.message);
await as(db, anon, `select public.deal_track('${K2}', 'steal', 'page')`);
check((await q(db, "select count(*)::int n from public.deal_events where kind = 'page'"))[0].n === 1, "a second open the same day isn't counted again");
r = await as(db, anon, `select public.deal_track('short', 'steal', 'page')`);
check(Boolean(r.error), "a made-up key is refused");
r = await as(db, anon, `select public.deal_track('${K1}', 'steal', 'open', 'MZ-NOT')`);
check(!r.error && (await q(db, "select count(*)::int n from public.deal_events where property_id = 'MZ-NOT'"))[0].n === 0, "a flat that isn't a deal on screen is ignored");
await as(db, anon, `select public.deal_track('${K1}', 'steal', 'page')`);
await as(db, anon, `select public.deal_track('${K1}', 'steal', 'open', 'MZ-S1')`);
await as(db, anon, `select public.deal_track('${K1}', 'steal', 'open', 'MZ-S1')`);
check((await q(db, "select count(*)::int n from public.deal_events where kind = 'open'"))[0].n === 1, "a double tap is one open");
check((await q(db, `select count(*)::int n from public.tv_calls where fn = 'touch' and client_id = '${RAVI}' and source = 'deal' and opens = 1`))[0].n === 1,
  "Ravi's open reaches his tenant views (source deal)");
r = await as(db, anon, `select public.deal_track('${K1}', 'steal', 'like', 'mz-s1')`);
check(!r.error && JSON.stringify(one(r).likes) === '["MZ-S1"]', "♥ saves without sign-in, and comes back as his likes", r.error?.message || JSON.stringify(one(r)));
check((await q(db, "select count(*)::int n from public.tv_calls where fn = 'respond' and said ->> 'liked' = 'liked'"))[0].n === 1, "…and marks the flat liked on his tenant views");
let notes = await q(db, "select for_email, type, title, body, client_id from public.crm_notifications order by for_email");
check(notes.length === 2 && notes[0].type === "deal" && /Ravi Kumar liked a Steal Deal/.test(notes[0].title) && /9876500001/.test(notes[0].body) && notes[0].client_id === RAVI,
  "the whole team is told, with his name, number and the flat", JSON.stringify(notes[0]));
let pnotes = await q(db, "select broker_id, kind, title, body, link from public.partner_notifications");
check(pnotes.length === 1 && pnotes[0].broker_id === BROKER && pnotes[0].link === "/property/MZ-S1" && !/9876500001/.test(pnotes[0].body + pnotes[0].title),
  "the flat's partner is told — the flat, not his number", JSON.stringify(pnotes[0]));
await as(db, anon, `select public.deal_track('${K1}', 'steal', 'like', 'MZ-S1')`);
r = await as(db, anon, `select public.deal_track('${K1}', 'steal', 'unlike', 'MZ-S1')`);
check(JSON.stringify(one(r).likes) === "[]", "♥ again changes nothing; unlike takes it off");
await as(db, anon, `select public.deal_track('${K1}', 'steal', 'like', 'MZ-S1')`);
check((await q(db, "select count(*)::int n from public.crm_notifications"))[0].n === 2, "liking it back doesn't tell the team twice");
r = await as(db, anon, `select public.deal_track('${K2}', 'day', 'like', 'MZ-D1')`);
check(!r.error && JSON.stringify(one(r).likes) === '["MZ-D1"]', "yesterday's Deal of the Day still on screen (rolled over) can be liked");
check((await q(db, "select count(*)::int n from public.crm_notifications where title like 'A visitor liked a Deal of the Day'"))[0].n === 2,
  "an unknown visitor's like still tells the team");
r = await as(db, anon, "select count(*) from public.deal_events");
check(Boolean(r.error), "nobody reads the events table directly");

console.log("\na visit for a deal flat");
await db.exec(`insert into public.visit_bookings (user_id, property_id, slot_at) values ('${tenantUser.uid}', 'MZ-S1', now() + interval '1 day')`);
check((await q(db, "select count(*)::int n from public.crm_notifications where title = 'Meera Nair booked a visit for a Steal Deal'"))[0].n === 2,
  "a visit booked for a flat on deal tells the team");
await db.exec(`insert into public.visit_bookings (user_id, property_id) values ('${tenantUser.uid}', 'MZ-NOT')`);
check((await q(db, "select count(*)::int n from public.crm_notifications where body like '%MZ-NOT%'"))[0].n === 0, "a visit for any other flat doesn't");

console.log("\nthe CRM");
r = await as(db, agent, "select public.crm_deal_stats('steal', public.deal_this_monday(), public.deal_this_monday())");
const st = one(r);
check(!r.error, "any CRM user reads the Steal Deals numbers", r.error?.message);
check(st?.periods?.[0]?.people === 2 && st.periods[0].identified === 1, "people 2, identified 1", JSON.stringify(st?.periods));
const s1 = st?.flats?.find((f) => f.property_id === "MZ-S1");
check(s1 && s1.opens === 1 && s1.likes === 1 && s1.visits === 1, "MZ-S1: 1 open, 1 like, 1 visit this week", JSON.stringify(s1));
check(Boolean(st?.flats?.find((f) => f.property_id === "MZ-S2" && f.opens === 0)), "a deal flat nobody touched is listed with zeros");
r = await as(db, agent, "select public.crm_deal_people('steal', public.deal_this_monday(), 'MZ-S1')");
const ppl = one(r) ?? [];
const ravi = ppl.find((p) => p.client_id === RAVI);
const meera = ppl.find((p) => p.client_id === MEERA);
check(ravi?.liked === true && ravi.opens === 1 && ravi.phone === "9876500001", "who: Ravi liked and opened it", JSON.stringify(ravi));
check(meera?.booked_at && meera.visit_status === "scheduled" && meera.liked === false, "who: Meera booked a visit", JSON.stringify(meera));
check(ppl[0]?.client_id === MEERA, "a booking comes first");
r = await as(db, agent, "select public.crm_deal_stats('day', (now() at time zone 'Asia/Kolkata')::date - 1, (now() at time zone 'Asia/Kolkata')::date)");
const dt = one(r);
check(!r.error && dt.flats.some((f) => f.property_id === "MZ-D1" && f.likes === 1), "Deal of the Day numbers too", r.error?.message || JSON.stringify(dt));
r = await as(db, tenantUser, "select public.crm_deal_stats('steal', public.deal_this_monday(), public.deal_this_monday())");
check(r.error && /CRM staff only/.test(r.error.message), "a tenant can't read them", r.error?.message);
r = await as(db, anon, `select public.crm_deal_people('steal', public.deal_this_monday(), 'MZ-S1')`);
check(Boolean(r.error), "nobody signed out can");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
