/**
 * Fuzz marketing_schema.sql against randomly drifted schemas.
 *
 * Four separate failures got through hand-picked scenarios (42P01, 42703,
 * 42804, and the array-literal one before them), each found by a user pasting
 * the file into the Supabase SQL editor. Every one was a shape I hadn't thought
 * to write a test for, which is the argument against thinking of shapes myself.
 *
 * So: generate schemas at random — which tables exist, which column spelling
 * each uses, and what type each column is — and assert the file applies and the
 * reporting functions answer. Anything that fails prints the exact DDL to
 * reproduce it.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

const SQL = readFileSync(
  new URL("../marketing_schema.sql", import.meta.url),
  "utf8",
).replace(/create extension if not exists "pgcrypto";/g, "");

const ROUNDS = Number(process.argv[2] || 40);
const SEED = Number(process.argv[3] || 1);

/** Deterministic PRNG, so a failing round can be replayed by its seed. */
let state = SEED;
const rnd = () => ((state = (state * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);
const pick = (xs) => xs[Math.floor(rnd() * xs.length) % xs.length];
const maybe = (p = 0.5) => rnd() < p;

const OWNER_TYPES = ["uuid", "text"];
const PROP_TYPES = ["uuid", "text"];
const TIME_TYPES = ["timestamptz", "timestamp"];

/**
 * The spellings the migration says it handles. Deliberately includes names it
 * does NOT know about, so "silently produces no usable source" is exercised
 * too — that path must also not throw.
 */
const TABLES = {
  user_requirements: {
    owner: ["user_id", "id", "member_id"],
    time: ["created_at", "updated_at", "logged_at"],
  },
  customer_search_profiles: {
    owner: ["user_id", "customer_id", "id", "who"],
    time: ["updated_at", "created_at", "touched_at"],
  },
  user_actions: {
    owner: ["user_id", "customer_id", "actor"],
    time: ["created_at", "inserted_at", "at"],
    prop: ["property_id", "listing_id", "subject"],
    act: ["action", "event", "type", "verb"],
  },
  saved_properties: {
    owner: ["customer_id", "user_id", "profile_id", "uid", "owner"],
    time: ["created_at", "saved_at", "inserted_at", "updated_at", "when_saved"],
    prop: ["listing_id", "property_id", "flat_id", "target"],
  },
  listing_reactions: {
    owner: ["user_id", "customer_id", "who"],
    time: ["updated_at", "created_at", "at"],
    prop: ["property_id", "listing_id", "target"],
  },
  visit_bookings: {
    owner: ["user_id", "customer_id", "booked_by"],
    time: ["created_at", "inserted_at", "at"],
  },
  visit_requests: {
    owner: ["customer_id", "user_id", "asker"],
    time: ["created_at", "inserted_at", "at"],
  },
  crm_clients: {
    owner: ["user_id", "account_id"],
    time: ["closed_at"],
  },
};

const PRELUDE = `
create role anon;
create role authenticated;
create schema if not exists auth;
create table auth.users (id uuid primary key, email text);
create or replace function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;
create or replace function auth.jwt() returns jsonb language sql stable
  as $$ select '{"email":"yatharth200018@gmail.com"}'::jsonb $$;
create table public.user_profiles (
  id uuid primary key, email text not null, name text default '', phone text default '',
  role text not null default 'customer',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
`;

function randomSchema() {
  const ddl = [];
  for (const [table, spec] of Object.entries(TABLES)) {
    if (!maybe(0.6)) continue; // table absent entirely

    const cols = ["id uuid primary key default gen_random_uuid()"];
    if (spec.owner && maybe(0.9)) cols.push(`${pick(spec.owner)} ${pick(OWNER_TYPES)}`);
    if (spec.time && maybe(0.9)) cols.push(`${pick(spec.time)} ${pick(TIME_TYPES)} default now()`);
    if (spec.prop && maybe(0.8)) cols.push(`${pick(spec.prop)} ${pick(PROP_TYPES)}`);
    if (spec.act && maybe(0.9)) cols.push(`${pick(spec.act)} text`);
    if (table === "listing_reactions" && maybe(0.9)) cols.push("reaction text");
    if (table === "crm_clients") {
      if (maybe(0.9)) cols.push("status text");
      if (maybe(0.9)) cols.push("closed_reason text");
    }
    ddl.push(`create table public.${table} (${cols.join(", ")});`);
  }
  return ddl.join("\n");
}

let failures = 0;

for (let round = 1; round <= ROUNDS; round++) {
  const ddl = randomSchema();
  const db = new PGlite();
  try {
    await db.exec(PRELUDE);
    if (ddl.trim()) await db.exec(ddl);
  } catch (e) {
    // A schema PGlite itself rejects isn't a finding about our file.
    await db.close();
    continue;
  }

  try {
    await db.exec(SQL);

    // Applying isn't enough — the generated functions must also run.
    await db.exec(`
      insert into auth.users (id, email) values
        ('11111111-1111-1111-1111-111111111111','lead@example.com');
      insert into public.user_profiles (id, email, signup_attribution)
      values ('11111111-1111-1111-1111-111111111111','lead@example.com',
              '{"source":"rishav","campaign":"mkt_rishav"}'::jsonb);
    `);
    await db.query("select public.record_marketing_click('mkt_rishav','a1','/','')");
    const leads = await db.query("select * from public.marketing_channel_leads('rishav')");
    const stats = await db.query("select * from public.marketing_channel_stats('rishav')");
    await db.query("select * from public.marketing_overview()");

    if (leads.rows.length !== 1) throw new Error(`expected 1 lead, got ${leads.rows.length}`);
    if (stats.rows[0].signups !== 1) throw new Error("signup not counted");

    // And a second application over live data must stay a no-op.
    await db.exec(SQL);
  } catch (e) {
    failures++;
    console.log(`\n--- round ${round} FAILED: ${e.message}`);
    console.log(ddl || "(no optional tables)");
  }
  await db.close();
}

console.log(
  `\n${ROUNDS} random schemas, ${failures} failure${failures === 1 ? "" : "s"}` +
    `${failures ? "" : " — file applies and answers on every shape tried"}`,
);
process.exit(failures ? 1 : 0);
