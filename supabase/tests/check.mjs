/**
 * Run marketing_schema.sql against a real Postgres (PGlite, in-process) so the
 * Supabase SQL editor isn't the place we find out it doesn't apply.
 *
 * Four shapes, because the file's whole job is surviving a schema it wasn't
 * written against:
 *   bare     — only user_profiles, which is what production turned out to have
 *   full     — every table the repo's schemas define, spelled their way
 *   drifted  — saved_properties present but under different column names
 *   unusable — saved_properties present with nothing usable in it at all
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

const SQL_PATH = new URL("../marketing_schema.sql", import.meta.url);
const USER = "11111111-1111-1111-1111-111111111111";

/** Supabase-isms PGlite doesn't have. */
const PRELUDE = `
create role anon;
create role authenticated;
create schema if not exists auth;
create table auth.users (id uuid primary key, email text);
create or replace function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;
create or replace function auth.jwt() returns jsonb language sql stable
  as $$ select '{"email":"yatharth200018@gmail.com"}'::jsonb $$;

create table public.user_profiles (
  id uuid primary key,
  email text not null,
  name text default '',
  phone text default '',
  role text not null default 'customer',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
`;

const SCENARIOS = [
  {
    name: "bare     (production: user_profiles only)",
    setup: "",
    seed: "",
    expect: { prefs: false, shortlisted: false, visit: false, closed: true },
  },
  {
    name: "full     (every optional table, repo spelling)",
    setup: `
      create table public.user_requirements (user_id uuid primary key, created_at timestamptz default now());
      create table public.customer_search_profiles (user_id uuid primary key, updated_at timestamptz default now());
      create table public.user_actions (
        id uuid primary key default gen_random_uuid(), user_id uuid, action text,
        property_id text, created_at timestamptz default now());
      create table public.saved_properties (
        id uuid primary key default gen_random_uuid(), customer_id uuid, listing_id text,
        created_at timestamptz default now());
      create table public.listing_reactions (
        user_id uuid, property_id text, reaction text, updated_at timestamptz default now(),
        primary key (user_id, property_id));
      create table public.visit_bookings (
        id uuid primary key default gen_random_uuid(), user_id uuid, property_id text,
        created_at timestamptz default now());
      create table public.crm_clients (
        id uuid primary key default gen_random_uuid(), user_id uuid, status text,
        closed_at timestamptz, closed_reason text);
    `,
    seed: `
      insert into public.user_requirements (user_id) values ('${USER}');
      insert into public.user_actions (user_id, action, property_id)
        values ('${USER}','shortlist_property','MZ-1');
      insert into public.saved_properties (customer_id, listing_id) values ('${USER}','MZ-2');
      insert into public.listing_reactions (user_id, property_id, reaction)
        values ('${USER}','MZ-1','like');
      insert into public.visit_bookings (user_id, property_id) values ('${USER}','MZ-1');
    `,
    expect: { prefs: true, shortlisted: true, visit: true, closed: true, props: 2 },
  },
  {
    name: "drifted  (saved_properties as uid/flat_id/saved_at)",
    setup: `
      create table public.saved_properties (
        id uuid primary key default gen_random_uuid(),
        uid uuid, flat_id text, saved_at timestamptz default now());
      create table public.user_requirements (user_id uuid primary key, created_at timestamptz default now());
    `,
    seed: `
      insert into public.saved_properties (uid, flat_id) values ('${USER}','MZ-9');
      insert into public.user_requirements (user_id) values ('${USER}');
    `,
    expect: { prefs: true, shortlisted: true, visit: false, closed: true, props: 1 },
  },
  {
    // Production's actual shape: saved_properties keyed by user_id with a uuid
    // property_id, alongside listing_reactions whose property_id is text. The
    // union of the two is what produced 42804.
    name: "clashing (uuid property_id vs text property_id)",
    setup: `
      create table public.saved_properties (
        id uuid primary key default gen_random_uuid(),
        user_id uuid, property_id uuid, created_at timestamptz default now());
      create table public.listing_reactions (
        user_id uuid, property_id text, reaction text, updated_at timestamptz default now(),
        primary key (user_id, property_id));
      create table public.visit_bookings (
        id uuid primary key default gen_random_uuid(), user_id text, property_id text,
        created_at timestamptz default now());
    `,
    seed: `
      insert into public.saved_properties (user_id, property_id)
        values ('${USER}','22222222-2222-2222-2222-222222222222');
      insert into public.listing_reactions (user_id, property_id, reaction)
        values ('${USER}','MZ-1','like');
      insert into public.visit_bookings (user_id, property_id) values ('${USER}','MZ-1');
    `,
    // Two distinct property ids across the two tables, and a text user_id on
    // visit_bookings that has to compare against a uuid parameter.
    expect: { prefs: false, shortlisted: true, visit: true, closed: true, props: 2 },
  },
  {
    name: "unusable (saved_properties with no usable column)",
    setup: `create table public.saved_properties (id uuid primary key, note text);`,
    seed: `insert into public.saved_properties (id, note) values (gen_random_uuid(), 'x');`,
    expect: { prefs: false, shortlisted: false, visit: false, closed: true },
  },
];

const SQL = readFileSync(SQL_PATH, "utf8")
  // PGlite has gen_random_uuid() built in; it has no pgcrypto to install.
  .replace(/create extension if not exists "pgcrypto";/g, "");

let allPassed = true;

for (const s of SCENARIOS) {
  const db = new PGlite();
  const fail = (msg) => {
    console.log(`  FAIL ${msg}`);
    allPassed = false;
  };

  await db.exec(PRELUDE);
  if (s.setup.trim()) await db.exec(s.setup);

  console.log(`\n${s.name}`);
  try {
    await db.exec(SQL);
  } catch (e) {
    console.log(`  FAILED TO APPLY: ${e.message}`);
    allPassed = false;
    await db.close();
    continue;
  }

  // What the DO block decided, straight from its own log.
  const built = await db.query("select step, source from public._mkt_build_log order by step");
  for (const r of built.rows) console.log(`  built  ${r.step.padEnd(17)} <- ${r.source}`);

  // Seed one signup credited to the channel, plus whatever activity this shape
  // can record, then read the funnel back.
  await db.exec(`
    insert into auth.users (id, email) values ('${USER}','lead@example.com');
    insert into public.user_profiles (id, email, name, signup_attribution)
    values ('${USER}','lead@example.com','Lead',
            '{"source":"rishav","medium":"group","campaign":"mkt_rishav"}'::jsonb);
    update public.user_profiles
       set search_status = 'closed_by_us', search_closed_at = now(),
           search_closed_reason = 'Moved into MZ-1'
     where id = '${USER}';
  `);
  if (s.seed.trim()) await db.exec(s.seed);
  await db.query("select public.record_marketing_click('mkt_rishav','anon1','/','')");

  const leads = await db.query("select * from public.marketing_channel_leads('rishav')");
  if (leads.rows.length !== 1) fail(`expected 1 lead, got ${leads.rows.length}`);

  const l = leads.rows[0] || {};
  const got = {
    prefs: Boolean(l.prefs_filled_at),
    shortlisted: Boolean(l.shortlisted_at),
    visit: Boolean(l.visit_scheduled_at),
    closed: Boolean(l.closed_at),
  };
  console.log(
    `  funnel prefs=${got.prefs} shortlisted=${got.shortlisted}` +
      ` (${l.shortlist_count} props) visit=${got.visit} closed=${got.closed}`,
  );

  for (const k of ["prefs", "shortlisted", "visit", "closed"]) {
    if (got[k] !== s.expect[k]) fail(`${k}: expected ${s.expect[k]}, got ${got[k]}`);
  }
  if (s.expect.props !== undefined && l.shortlist_count !== s.expect.props) {
    fail(`shortlist_count: expected ${s.expect.props}, got ${l.shortlist_count}`);
  }

  const stats = (
    await db.query(
      "select link_clicks, visitors, signups, prefs_filled, shortlisted, visits_scheduled, closed" +
        " from public.marketing_channel_stats('rishav')",
    )
  ).rows[0];
  console.log(`  stats  ${JSON.stringify(stats)}`);
  if (stats.signups !== 1 || stats.link_clicks !== 1) fail("clicks/signups did not aggregate");

  // Re-running is the documented way to pick up a table added later, so it has
  // to be safe on a database that already holds data.
  try {
    await db.exec(SQL);
    const again = await db.query("select count(*)::int as n from public.marketing_channel_leads('rishav')");
    if (again.rows[0].n !== 1) fail(`re-run changed the lead count to ${again.rows[0].n}`);
    else console.log("  ok     re-run is idempotent");
  } catch (e) {
    fail(`re-run: ${e.message}`);
  }

  await db.close();
}

console.log(`\n${allPassed ? "ALL SCENARIOS PASS" : "SOMETHING FAILED"}`);
process.exit(allPassed ? 0 : 1);
