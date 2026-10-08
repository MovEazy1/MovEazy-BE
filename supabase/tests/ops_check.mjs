/**
 * Run ops_dashboard.sql against a real Postgres (PGlite, in-process), for the
 * same reason marketing_schema.sql gets check.mjs: the Supabase SQL editor is a
 * bad place to find out a migration doesn't apply.
 *
 * Two shapes, because the file's job is surviving a project that hasn't had the
 * other migrations run yet:
 *   bare — only user_profiles, so every metric must report 0 rather than 42P01
 *   full — crm_clients, inventory and visit_bookings present and seeded
 *
 * The arithmetic assertions all use noon IST on a named day. Seeding at
 * midnight would make the expected answers depend on which side of the IST/UTC
 * boundary the test happens to run — a test that passes before 05:30 and fails
 * after is worse than no test.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

const SQL_PATH = new URL("../ops_dashboard.sql", import.meta.url);
const SUPER = "yatharth200018@gmail.com";

const SQL = readFileSync(SQL_PATH, "utf8")
  // PGlite has gen_random_uuid() built in; it has no pgcrypto to install.
  .replace(/create extension if not exists "pgcrypto";/g, "");

/** Supabase-isms PGlite doesn't have, including the default grants it ships. */
const PRELUDE = `
create role anon;
create role authenticated;
alter default privileges in schema public grant all on functions to anon, authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated;
create schema if not exists auth;
create table auth.users (id uuid primary key, email text);
create or replace function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;
`;

const jwtAs = (email) => `
create or replace function auth.jwt() returns jsonb language sql stable
  as $$ select '{"email":"${email}"}'::jsonb $$;
`;

/** Noon IST, `n` days ago — an unambiguous point inside one dashboard day. */
const istNoon = (n) =>
  `((((now() at time zone 'Asia/Kolkata')::date - ${n}) + time '12:00') at time zone 'Asia/Kolkata')`;

const FULL_SETUP = `
  create table public.crm_clients (
    id uuid primary key default gen_random_uuid(),
    user_id uuid, status text not null default 'fresh',
    closed_at timestamptz,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now());
  create table public.inventory (
    property_id text primary key,
    status text not null default 'published',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now());
  create table public.visit_bookings (
    id uuid primary key default gen_random_uuid(),
    user_id uuid, property_id text, slot_at timestamptz,
    status text not null default 'scheduled',
    created_at timestamptz not null default now());
`;

const FULL_SEED = `
  -- Open since D-3.
  insert into public.crm_clients (status, created_at, updated_at)
    values ('fresh', ${istNoon(3)}, ${istNoon(3)});
  -- Created D-2, closed by us on D-1.
  insert into public.crm_clients (status, created_at, updated_at, closed_at)
    values ('closed_by_us', ${istNoon(2)}, ${istNoon(1)}, ${istNoon(1)});
  -- Closed elsewhere on D-1: counts against active leads, never as our closure.
  insert into public.crm_clients (status, created_at, updated_at, closed_at)
    values ('closed_outside', ${istNoon(2)}, ${istNoon(1)}, ${istNoon(1)});

  -- Listed D-2, still live.
  insert into public.inventory (property_id, status, created_at, updated_at)
    values ('MZ-LIVE', 'published', ${istNoon(2)}, ${istNoon(2)});
  -- Listed D-4, rented on D-1: live supply on D-4..D-2, gone from D-1.
  insert into public.inventory (property_id, status, created_at, updated_at)
    values ('MZ-RENTED', 'rented', ${istNoon(4)}, ${istNoon(1)});

  -- Two visits today, one cancelled yesterday, one booked with no slot on D-2.
  insert into public.visit_bookings (property_id, slot_at, created_at)
    values ('MZ-LIVE', ${istNoon(0)}, ${istNoon(2)});
  insert into public.visit_bookings (property_id, slot_at, created_at)
    values ('MZ-RENTED', ${istNoon(0)}, ${istNoon(3)});
  insert into public.visit_bookings (property_id, slot_at, status, created_at)
    values ('MZ-LIVE', ${istNoon(1)}, 'cancelled', ${istNoon(3)});
  insert into public.visit_bookings (property_id, slot_at, created_at)
    values ('MZ-LIVE', null, ${istNoon(2)});
`;

let allPassed = true;
const fail = (msg) => {
  console.log(`  FAIL ${msg}`);
  allPassed = false;
};
const ok = (msg) => console.log(`  ok     ${msg}`);

/** The last seven days, keyed by how many days ago each one is. */
async function readSeries(db) {
  const res = await db.query(`
    select to_char(day, 'YYYY-MM-DD') as day, new_leads, active_leads,
           new_properties, active_properties, visits, closures
      from public.ops_daily_metrics(
             (now() at time zone 'Asia/Kolkata')::date - 6,
             (now() at time zone 'Asia/Kolkata')::date)
  `);
  const today = (
    await db.query(
      "select to_char((now() at time zone 'Asia/Kolkata')::date, 'YYYY-MM-DD') as d",
    )
  ).rows[0].d;
  const byDay = new Map(res.rows.map((r) => [r.day, r]));
  const at = (n) => {
    const d = new Date(`${today}T00:00:00Z`);
    d.setUTCDate(d.getUTCDate() - n);
    return byDay.get(d.toISOString().slice(0, 10));
  };
  return { rows: res.rows, at };
}

function expectDay(at, n, expected) {
  const row = at(n);
  if (!row) return fail(`D-${n}: no row came back`);
  for (const [k, v] of Object.entries(expected)) {
    if (Number(row[k]) !== v) fail(`D-${n} ${k}: expected ${v}, got ${row[k]}`);
  }
}

for (const scenario of ["bare", "full"]) {
  console.log(`\n${scenario === "bare" ? "bare     (no crm/inventory/visits tables)" : "full     (every table present)"}`);
  const db = new PGlite();
  await db.exec(PRELUDE);
  await db.exec(jwtAs(SUPER));
  if (scenario === "full") await db.exec(FULL_SETUP);

  try {
    await db.exec(SQL);
  } catch (e) {
    fail(`FAILED TO APPLY: ${e.message}`);
    await db.close();
    continue;
  }
  ok("applies");

  // The gate is the whole security model — if anon can call the metrics, the
  // publishable key hands the company's numbers to anyone who asks.
  const leaky = await db.query(`
    select p.proname
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('ops_daily_metrics', '_ops_daily_metrics', 'can_view_ops_dashboard')
       and has_function_privilege('anon', p.oid, 'execute')
     order by 1
  `);
  if (leaky.rows.length) fail(`anon can execute: ${leaky.rows.map((r) => r.proname).join(", ")}`);
  else ok("anon can execute none of the dashboard functions");

  const internal = await db.query(
    "select has_function_privilege('authenticated', 'public._ops_daily_metrics(date,date)', 'execute') as yes",
  );
  if (internal.rows[0].yes) fail("authenticated holds execute on the internal _ops_daily_metrics");

  for (const t of ["dashboard_access"]) {
    const anonRead = await db.query(
      `select has_table_privilege('anon', 'public.${t}', 'select') as yes`,
    );
    if (anonRead.rows[0].yes) fail(`anon holds select on ${t}`);
  }

  if (scenario === "full") await db.exec(FULL_SEED);

  const { rows, at } = await readSeries(db);
  if (rows.length !== 7) fail(`expected 7 days, got ${rows.length}`);
  else ok("one row per day, empty days included");

  if (scenario === "bare") {
    const anyNonZero = rows.some(
      (r) =>
        Number(r.new_leads) || Number(r.active_leads) || Number(r.new_properties) ||
        Number(r.active_properties) || Number(r.visits) || Number(r.closures),
    );
    if (anyNonZero) fail("a metric was non-zero with none of its tables present");
    else ok("every metric reports 0 rather than failing");
  } else {
    expectDay(at, 4, { new_leads: 0, active_leads: 0, new_properties: 1, active_properties: 1 });
    expectDay(at, 3, { new_leads: 1, active_leads: 1, new_properties: 0, active_properties: 1 });
    expectDay(at, 2, {
      new_leads: 2, active_leads: 3, new_properties: 1, active_properties: 2,
      visits: 1, closures: 0,
    });
    // Both D-2 clients close on D-1; only one of them closed with us. The
    // rented flat leaves live supply the same day.
    expectDay(at, 1, {
      new_leads: 0, active_leads: 1, new_properties: 0, active_properties: 1,
      visits: 0, closures: 1,
    });
    expectDay(at, 0, { new_leads: 0, active_leads: 1, active_properties: 1, visits: 2, closures: 0 });
    ok("leads, properties, visits and closures land on the right days");
  }

  // Access: a stranger gets an empty set, and a grant turns it on.
  await db.exec(jwtAs("stranger@example.com"));
  const refused = await db.query(
    "select count(*)::int as n from public.ops_daily_metrics(null, null)",
  );
  if (refused.rows[0].n !== 0) fail(`an ungranted email got ${refused.rows[0].n} rows`);
  else ok("an ungranted email gets nothing");

  await db.exec(
    "insert into public.dashboard_access (email, granted_by) values ('Stranger@Example.com', 'x')",
  );
  const allowed = await db.query("select public.can_view_ops_dashboard() as yes");
  if (!allowed.rows[0].yes) fail("a granted email was still refused");
  else ok("a grant is case-insensitive and takes effect immediately");

  const granted = await db.query(
    "select count(*)::int as n from public.ops_daily_metrics(null, null)",
  );
  if (granted.rows[0].n !== 30) fail(`default range: expected 30 days, got ${granted.rows[0].n}`);
  else ok("no arguments means the last 30 days");

  // The range clamp, and a backwards range.
  const clamped = await db.query(`
    select count(*)::int as n from public.ops_daily_metrics(
      (now() at time zone 'Asia/Kolkata')::date - 5000,
      (now() at time zone 'Asia/Kolkata')::date)
  `);
  if (clamped.rows[0].n !== 366) fail(`clamp: expected 366 days, got ${clamped.rows[0].n}`);
  else ok("an absurd range is clamped to a year");

  const backwards = await db.query(`
    select count(*)::int as n from public.ops_daily_metrics(
      (now() at time zone 'Asia/Kolkata')::date,
      (now() at time zone 'Asia/Kolkata')::date - 5)
  `);
  if (backwards.rows[0].n !== 0) fail("a backwards range returned rows");

  // Re-running is how a project picks up a table added later, so it has to be
  // safe on a database that already holds grants and data.
  await db.exec(jwtAs(SUPER));
  try {
    await db.exec(SQL);
    const again = await db.query("select count(*)::int as n from public.dashboard_access");
    if (again.rows[0].n !== 1) fail(`re-run changed the grant count to ${again.rows[0].n}`);
    else ok("re-run is idempotent");
  } catch (e) {
    fail(`re-run: ${e.message}`);
  }

  await db.close();
}

console.log(allPassed ? "\nops_dashboard.sql: all checks passed" : "\nops_dashboard.sql: FAILURES above");
process.exit(allPassed ? 0 : 1);
