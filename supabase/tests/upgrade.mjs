/**
 * Can this file be applied over an older version of itself?
 *
 * check.mjs and fuzz.mjs both build from an empty database, so both passed
 * while the real migration was failing on production. Postgres refuses to
 * `create or replace` a function whose RETURNS TABLE shape changed, and the
 * Supabase SQL editor runs the script in ONE transaction — so adding a single
 * column to one function rolled the entire migration back, silently undoing an
 * access rule and a column that had nothing to do with it. The symptom was
 * "this person still can't open /marketing/rishav", four steps removed from the
 * cause.
 *
 * So: stand up each reporting function with a deliberately different shape,
 * then apply the file and require it to succeed. That is the invariant — a
 * newer file must be able to replace an older one, whatever changed.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

const SQL = readFileSync(new URL("../marketing_schema.sql", import.meta.url), "utf8")
  .replace(/create extension if not exists "pgcrypto";/g, "");

const PRELUDE = `
create role anon; create role authenticated;
alter default privileges in schema public grant all on functions to anon, authenticated;
create schema if not exists auth;
create table auth.users (id uuid primary key, email text);
create or replace function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;
create or replace function auth.jwt() returns jsonb language sql stable
  as $$ select '{"email":"yatharth200018@gmail.com"}'::jsonb $$;
create table public.user_profiles (
  id uuid primary key, email text not null, name text default '', phone text default '',
  role text default 'customer',
  created_at timestamptz default now(), updated_at timestamptz default now());
`;

/**
 * Yesterday's shapes: each one column short of what the file now returns, which
 * is the single most likely way this file changes between two runs.
 */
const OLD_SHAPES = `
create function public.my_marketing_channels()
  returns table (slug text, label text, description text, is_overview boolean)
  language sql stable as $$ select null::text, null::text, null::text, null::boolean $$;

create function public.marketing_overview()
  returns table (slug text, label text)
  language sql stable as $$ select null::text, null::text $$;

create function public.marketing_channel_stats(p_slug text)
  returns table (slug text, signups int)
  language sql stable as $$ select null::text, null::int $$;

create function public.marketing_channel_leads(p_slug text)
  returns table (user_id uuid, email text)
  language sql stable as $$ select null::uuid, null::text $$;

create function public._marketing_leads(p_slug text default null)
  returns table (channel_slug text, user_id uuid)
  language sql stable as $$ select null::text, null::uuid $$;

create function public._marketing_stats(p_slug text default null)
  returns table (slug text, link_clicks int)
  language sql stable as $$ select null::text, null::int $$;
`;

let failed = false;

for (const [name, seed] of [
  ["over an empty database", ""],
  ["over the file's own previous run", SQL],
  ["over older, differently-shaped functions", OLD_SHAPES],
]) {
  const db = new PGlite();
  await db.exec(PRELUDE);
  if (seed) {
    try {
      await db.exec(seed);
    } catch (e) {
      console.log(`  setup failed for "${name}": ${e.message}`);
      failed = true;
      await db.close();
      continue;
    }
  }

  try {
    // One exec, one implicit transaction — the same all-or-nothing the Supabase
    // SQL editor gives it.
    await db.exec(SQL);
    const r = await db.query("select count(*)::int as n from public.my_marketing_channels()");
    console.log(`  ok   applies ${name} (${r.rows[0].n} channels visible)`);
  } catch (e) {
    console.log(`  FAIL applies ${name}: ${e.message}`);
    if (e.hint) console.log(`       hint: ${e.hint}`);
    failed = true;
  }
  await db.close();
}

console.log(failed ? "\nUPGRADE TESTS FAILED" : "\nUPGRADE TESTS PASS");
process.exit(failed ? 1 : 0);
