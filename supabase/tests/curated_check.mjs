/**
 * Apply crm_curated_shares.sql to a real Postgres (PGlite, in-process) and
 * exercise the three functions a recipient's browser calls.
 *
 * The whole point of a curated share is that the person using it is signed out
 * and holding nothing but a token, so the interesting cases are the hostile
 * ones: a token that doesn't exist, a property that isn't in the batch, and a
 * swipe arriving after a visit was already booked.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

const SQL_PATH = new URL("../crm_curated_shares.sql", import.meta.url);
const CLIENT = "22222222-2222-2222-2222-222222222222";
const USER = "11111111-1111-1111-1111-111111111111";

/** Just enough of crm_schema.sql for the migration to have something to attach to. */
const PRELUDE = `
create role anon;
create role authenticated;
alter default privileges in schema public grant all on functions to anon, authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated;

create schema if not exists auth;
create table auth.users (id uuid primary key, email text);
create or replace function auth.uid() returns uuid language sql stable as $$ select current_setting('test.uid', true)::uuid $$;

create or replace function public.is_crm_staff() returns boolean language sql stable as $$ select true $$;
create or replace function public.has_admin_scope(s text) returns boolean language sql stable as $$ select true $$;

create table public.user_profiles (
  id uuid primary key, email text not null, name text default '', phone text default ''
);

create table public.crm_clients (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique,
  name text default '', phone text default '', email text default '',
  source text default 'manual', status text default 'fresh',
  updated_at timestamptz not null default now()
);

create table public.crm_shortlists (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.crm_clients(id) on delete cascade,
  property_id text not null,
  status text not null default 'shortlisted'
    check (status in ('shortlisted','shared','liked','okay','disliked','visited','rejected')),
  score_at_share int, shared_by text default '', shared_at timestamptz,
  created_at timestamptz not null default now(),
  unique (client_id, property_id)
);

create table public.crm_activities (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.crm_clients(id) on delete cascade,
  actor_email text default '', type text default 'note', body text default '',
  meta jsonb default '{}'::jsonb, created_at timestamptz not null default now()
);

create table public.crm_notifications (
  id uuid primary key default gen_random_uuid(),
  for_email text, type text, title text, body text, client_id uuid
);

create table public.listing_reactions (
  user_id uuid not null, property_id text not null, reaction text not null,
  recorded_by text default '', source text default 'app',
  updated_at timestamptz not null default now(),
  primary key (user_id, property_id)
);

create table public.visit_bookings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid, property_id text not null, slot_at timestamptz,
  kind text default 'individual', group_id uuid, amount int default 0,
  status text default 'scheduled'
);
`;

let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};

const db = new PGlite();
await db.exec(PRELUDE);
await db.exec(readFileSync(SQL_PATH, "utf8"));
console.log("crm_curated_shares.sql applied\n");

// Applying twice is how this reaches a project that already ran an older copy.
await db.exec(readFileSync(SQL_PATH, "utf8"));
check(true, "re-applying the migration over itself");

await db.exec(`
  insert into auth.users (id, email) values ('${USER}', 'her@example.com');
  insert into public.user_profiles (id, email, name, phone) values ('${USER}', 'her@example.com', 'Asha', '9876500000');
  insert into public.crm_clients (id, user_id, name, phone, email)
    values ('${CLIENT}', '${USER}', 'Asha', '9876500000', 'her@example.com');
  insert into public.crm_curated_shares (client_id, token, property_ids, shared_by, agent_name)
    values ('${CLIENT}', 'mzcurated0123456789', array['MZ-1','MZ-2','MZ-3'], 'agent@moveazy.co.in', 'Rishav');
`);

const open = (await db.query(`select public.curated_share_open('mzcurated0123456789') as r`)).rows[0].r;
check(open.ok === true, "a real token opens");
check(JSON.stringify(open.property_ids) === '["MZ-1","MZ-2","MZ-3"]', "it returns the batch in the order it was picked");
check(open.client_name === "Asha", "and who it was sent to");

const bad = (await db.query(`select public.curated_share_open('mznotatokenatall') as r`)).rows[0].r;
check(bad.ok === false, "an unknown token says nothing either way");

const opens = (await db.query(`select open_count, opened_at is not null as first from public.crm_curated_shares`)).rows[0];
check(opens.open_count === 1 && opens.first, "the open is counted once");
await db.query(`select public.curated_share_open('mzcurated0123456789')`);
const again = (await db.query(`select open_count from public.crm_curated_shares`)).rows[0];
check(again.open_count === 2, "a second open bumps the counter");
const sysRows = (await db.query(
  `select count(*)::int as n from public.crm_activities where type = 'system'`,
)).rows[0].n;
check(sysRows === 1, "but only the first one writes to the timeline", `${sysRows} entries`);

// Swipes.
await db.query(`select public.curated_share_react('mzcurated0123456789', 'MZ-1', 'like')`);
await db.query(`select public.curated_share_react('mzcurated0123456789', 'MZ-2', 'dislike')`);
const statuses = Object.fromEntries(
  (await db.query(`select property_id, status from public.crm_shortlists`)).rows.map((r) => [r.property_id, r.status]),
);
check(statuses["MZ-1"] === "liked" && statuses["MZ-2"] === "disliked", "a swipe lands on the shortlist row");

const mirrored = (await db.query(`select property_id, reaction, source from public.listing_reactions order by property_id`)).rows;
check(mirrored.length === 2 && mirrored[0].source === "curated_link", "and is mirrored onto the account's own reactions");

const outside = (await db.query(`select public.curated_share_react('mzcurated0123456789', 'MZ-999', 'like') as r`)).rows[0].r;
check(outside.ok === false, "a property outside the batch is refused");

const badReaction = (await db.query(`select public.curated_share_react('mzcurated0123456789', 'MZ-1', 'drop table') as r`)).rows[0].r;
check(badReaction.ok === false, "an invented reaction is refused");

// A booked visit, then an idle swipe over the same card.
await db.query(`insert into public.visit_bookings (user_id, property_id, slot_at) values ('${USER}', 'MZ-3', now() + interval '2 days')`);
const afterBooking = (await db.query(`select status from public.crm_shortlists where property_id = 'MZ-3'`)).rows[0];
check(afterBooking?.status === "visit_scheduled", "booking a visit says so on the shortlist", JSON.stringify(afterBooking));

await db.query(`select public.curated_share_react('mzcurated0123456789', 'MZ-3', 'dislike')`);
const afterSwipe = (await db.query(`select status from public.crm_shortlists where property_id = 'MZ-3'`)).rows[0].status;
check(afterSwipe === "visit_scheduled", "and a later swipe cannot undo it");

// A visit with no time still reaches the CRM as one needing scheduling.
await db.query(`insert into public.visit_bookings (user_id, property_id, slot_at, status) values ('${USER}', 'MZ-1', null, 'preference')`);
const needsTime = (await db.query(
  `select count(*)::int as n from public.crm_notifications where title = 'Visit needs a time'`,
)).rows[0].n;
check(needsTime === 1, "a visit with no slot pings the super admin");

// The signed-in route home.
await db.exec(`select set_config('test.uid', '${USER}', false)`);
const mine = (await db.query(`select public.my_curated_properties() as r`)).rows[0].r;
check(mine.ok === true && mine.property_ids.length === 3, "a signed-in client sees their own shortlist", JSON.stringify(mine.property_ids));
check(mine.token === "mzcurated0123456789", "and gets the latest batch's token back");
check(
  JSON.stringify(mine.property_ids) === '["MZ-1","MZ-2","MZ-3"]',
  "in the order the agent picked, not sorted by id",
  JSON.stringify(mine.property_ids),
);

// A second, newer batch. This is a deck someone swipes, so the newest set leads
// and keeps its own order; the older one follows.
await db.exec(`
  insert into public.crm_curated_shares (client_id, token, property_ids, agent_name)
    values ('${CLIENT}', 'mzcurated9876543210', array['MZ-9','MZ-2','MZ-7'], 'Rishav');
`);
const mine2 = (await db.query(`select public.my_curated_properties() as r`)).rows[0].r;
check(
  JSON.stringify(mine2.property_ids) === '["MZ-9","MZ-2","MZ-7","MZ-1","MZ-3"]',
  "newest batch first, older homes after it, each home once",
  JSON.stringify(mine2.property_ids),
);
check(mine2.token === "mzcurated9876543210", "and the newest batch's token is the one handed back");

await db.exec(`select set_config('test.uid', '${USER.replace(/1/g, "9")}', false)`);
const stranger = (await db.query(`select public.my_curated_properties() as r`)).rows[0].r;
check(stranger.ok === true && stranger.property_ids.length === 0, "someone with no CRM record sees nothing");

await db.close();
console.log(`\n${passed ? "ALL CHECKS PASS" : "SOMETHING FAILED"}`);
process.exit(passed ? 0 : 1);
