/**
 * Apply the inventory access files to a real Postgres (PGlite, in-process) and
 * check the thing they exist for: a signed-in tenant cannot read a poster's
 * contact details, while an owner and CRM staff still can.
 *
 * The schema files are applied as they are in the repo, in the order they were
 * run on production, so this sees the same grants a real request would:
 *
 *   inventory_schema -> inventory_public_columns (anon)
 *   -> maintenance / floor / availability columns -> poster_visit_slots
 *   -> recommend_inventory -> inventory_private_read -> inventory_authenticated_columns
 *
 * Roles are switched with `set role`, and auth.uid() / the staff checks read a
 * setting, so "who is asking" is one line per case.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`
FAILED TO APPLY: ${e?.message}${e?.where ? `
  at ${e.where}` : ""}`);
  process.exit(1);
});

// gen_random_uuid() is core Postgres now; PGlite ships without the extension.
const file = (name) =>
  readFileSync(new URL(`../${name}`, import.meta.url), "utf8")
    .replace(/create extension if not exists "pgcrypto";/g, "");

const OWNER = "11111111-1111-1111-1111-111111111111";
const TENANT = "22222222-2222-2222-2222-222222222222";
const STAFF = "33333333-3333-3333-3333-333333333333";

/** Supabase's shape, as far as these files touch it. */
const PRELUDE = `
create role anon;
create role authenticated;
-- Supabase grants everything in public to both roles by default. The files
-- under test have to undo that, so the test has to start from it.
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant all on functions to anon, authenticated;

create schema auth;
grant usage on schema auth to anon, authenticated;
create table auth.users (id uuid primary key, email text);
create function auth.uid() returns uuid language sql stable
  as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
create function auth.jwt() returns jsonb language sql stable
  as $$ select jsonb_build_object('email', current_setting('test.email', true)) $$;

create function public.is_admin_allowlisted() returns boolean language sql stable
  as $$ select coalesce(current_setting('test.admin', true), '') = 'on' $$;
create function public.is_crm_staff() returns boolean language sql stable
  as $$ select coalesce(current_setting('test.staff', true), '') = 'on' $$;
create function public.has_admin_scope(s text) returns boolean language sql stable
  as $$ select coalesce(current_setting('test.staff', true), '') = 'on' $$;
`;

/** The inventory policies and columns crm_schema.sql adds. */
const CRM_INVENTORY = `
alter table public.inventory add column if not exists source text default '';
alter table public.inventory add column if not exists source_url text default '';
create policy "crm staff read all inventory" on public.inventory for select
  to authenticated using (public.is_crm_staff());
create policy "crm staff write inventory" on public.inventory for all
  to authenticated using (public.has_admin_scope('crm.properties.write'))
  with check (public.has_admin_scope('crm.properties.write'));
`;

/** property_visit_slots as visits_schema.sql + crm_visit_slots.sql leave it. */
const SLOTS = `
create table public.property_visit_slots (
  id uuid primary key default gen_random_uuid(),
  property_id text not null references public.inventory(property_id) on delete cascade,
  slot_at timestamptz not null,
  capacity int not null default 5,
  unique (property_id, slot_at)
);
alter table public.property_visit_slots enable row level security;
create policy "anyone reads slots" on public.property_visit_slots for select using (true);
create policy "crm staff write slots" on public.property_visit_slots for all
  to authenticated using (public.has_admin_scope('crm.properties.write'))
  with check (public.has_admin_scope('crm.properties.write'));
grant select on public.property_visit_slots to anon, authenticated;
grant insert, update, delete on public.property_visit_slots to authenticated;
`;

const SEED = `
insert into auth.users (id, email) values
  ('${OWNER}', 'owner@example.com'), ('${TENANT}', 'tenant@example.com'), ('${STAFF}', 'agent@moveazy.co.in');
insert into public.inventory (property_id, poster_id, owner_id, poster_name, poster_email, phone, area, rent, status, flat_type) values
  ('MZ-PUB001', '${OWNER}', '${OWNER}', 'Ravi Owner', 'owner@example.com', '9876500001', 'HSR Layout', 30000, 'published', '2BHK'),
  ('MZ-PAUSED', '${OWNER}', '${OWNER}', 'Ravi Owner', 'owner@example.com', '9876500001', 'HSR Layout', 32000, 'paused', '2BHK'),
  ('MZ-OTHER1', null, null, 'Someone Else', 'else@example.com', '9876500002', 'Koramangala', 28000, 'published', '1BHK');
insert into public.property_visit_slots (property_id, slot_at) values ('MZ-OTHER1', now() + interval '1 day');
`;

let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};

/** Run `sql` as `role` with the given identity; returns rows or the error. */
async function as(db, who, sql) {
  const role = who.role ?? "authenticated";
  await db.exec(`
    reset role;
    select set_config('test.uid', '${who.uid ?? ""}', false),
           set_config('test.email', '${who.email ?? ""}', false),
           set_config('test.staff', '${who.staff ? "on" : ""}', false),
           set_config('test.admin', '${who.admin ? "on" : ""}', false);
    set role ${role};
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

const denied = (r) => r.error?.code === "42501";

const anon = { role: "anon" };
const tenant = { uid: TENANT, email: "tenant@example.com" };
const owner = { uid: OWNER, email: "owner@example.com" };
const staff = { uid: STAFF, email: "agent@moveazy.co.in", staff: true };

async function baseDb() {
  const db = new PGlite();
  await db.exec(PRELUDE);
  await db.exec(file("inventory_schema.sql"));
  await db.exec(CRM_INVENTORY);
  // The anon column list first: it opens with a table-level revoke, which
  // would silently take back the column grants the later files add.
  await db.exec(file("inventory_public_columns.sql"));
  await db.exec(file("inventory_maintenance.sql"));
  await db.exec(file("inventory_maintenance_grant.sql"));
  await db.exec(file("inventory_floor.sql"));
  await db.exec(file("inventory_availability_check.sql"));
  await db.exec(SLOTS);
  await db.exec(file("poster_visit_slots.sql"));
  await db.exec(SEED);
  return db;
}

/* ── Before: the hole, as reported ───────────────────────────────────────── */
console.log("before the fix");
{
  const db = await baseDb();
  await db.exec(file("recommend_inventory.sql"));

  check(denied(await as(db, anon, "select * from public.inventory")), "anon select * is already refused");
  const leak = await as(db, tenant, "select phone, poster_email from public.inventory where property_id = 'MZ-OTHER1'");
  check(leak.rows?.[0]?.phone === "9876500002", "a signed-in tenant reads another poster's phone (the reported leak)", leak.error?.message);

  // Order matters: the revoke must refuse to run before the read path exists.
  const early = await db.exec(file("inventory_authenticated_columns.sql")).then(() => null, (e) => e);
  check(/inventory_private_read\.sql first/.test(early?.message || ""), "the revoke refuses to run before inventory_private_read.sql", early?.message);
  await db.exec("rollback");

  // And why the slot policy has to move: revoke by hand with the old policy in place.
  await db.exec(`
    revoke select on public.inventory from authenticated;
    grant select (property_id, status, area, rent) on public.inventory to authenticated;
  `);
  const slotWrite = await as(db, owner, "insert into public.property_visit_slots (property_id, slot_at) values ('MZ-PUB001', now() + interval '5 days')");
  check(denied(slotWrite), "with the old slot policy, the revoke stops an owner adding a visit slot", slotWrite.error?.message ?? "insert succeeded");
  await db.close();
}

/* ── After ───────────────────────────────────────────────────────────────── */
console.log("\nafter inventory_private_read.sql + recommend_inventory.sql");
const db = await baseDb();
await db.exec(file("inventory_private_read.sql"));
await db.exec(file("recommend_inventory.sql"));

{
  const rec = await as(db, anon, `select listing from public.recommend_inventory('{"budgetMax":"100000"}'::jsonb, 0)`);
  const l = rec.rows?.[0]?.listing ?? {};
  check(rec.rows?.length === 2, "recommend_inventory still ranks published flats for anon", rec.error?.message ?? `${rec.rows?.length} rows`);
  const privateKeys = ["phone", "poster_email", "poster_name", "poster_id", "owner_id", "tenant_id", "broker_id", "source_url"]
    .filter((k) => k in l);
  check(privateKeys.length === 0, "and its listing carries no poster PII", privateKeys.join(", "));
  check(l.rent === 30000 || l.rent === 28000, "but keeps the public fields", JSON.stringify(l).slice(0, 120));
}

console.log("\nafter inventory_authenticated_columns.sql");
await db.exec(file("inventory_authenticated_columns.sql"));
// Re-running both is how a later fix reaches a project that already ran them.
await db.exec(file("inventory_private_read.sql"));
await db.exec(file("inventory_authenticated_columns.sql"));
check(true, "both files re-apply over themselves");

// A policy the repo doesn't know about, reading poster_id the old way, must
// stop the revoke rather than break quietly on production.
await db.exec(`
  create policy "stray poster check" on public.property_visit_slots for update to authenticated
    using (exists (select 1 from public.inventory inv where inv.property_id = property_visit_slots.property_id and inv.poster_id = auth.uid()))`);
const stray = await db.exec(file("inventory_authenticated_columns.sql")).then(() => null, (e) => e);
await db.exec("rollback");
await db.exec(`drop policy "stray poster check" on public.property_visit_slots`);
check(/property_visit_slots\."stray poster check"/.test(stray?.message || ""),
  "the revoke refuses to run over a policy that still reads inventory.poster_id", stray?.message ?? "it ran");

// Tenant: the table gives nothing private, however it's asked.
check(denied(await as(db, tenant, "select * from public.inventory")), "tenant: select * is refused");
check(denied(await as(db, tenant, "select phone, poster_email from public.inventory")), "tenant: select phone, poster_email is refused");
check(denied(await as(db, tenant, "select poster_name from public.inventory")), "tenant: select poster_name is refused");
check(denied(await as(db, tenant, "select property_id from public.inventory where poster_id is not null")),
  "tenant: filtering on poster_id is refused (no probing by filter)");
const pub = await as(db, tenant, "select property_id, rent, maintenance, floor_number from public.inventory order by property_id");
check(pub.rows?.length === 2, "tenant: public columns of published flats still read", pub.error?.message ?? `${pub.rows?.length} rows`);
const tFull = await as(db, tenant, "select property_id from public.inventory_full()");
check(tFull.rows?.length === 0, "tenant: inventory_full() returns none of anyone else's rows", tFull.error?.message ?? `${tFull.rows?.length} rows`);

// Anon: unchanged, and cannot call the function at all.
check(denied(await as(db, anon, "select * from public.inventory")), "anon: select * is refused");
check(denied(await as(db, anon, "select phone from public.inventory")), "anon: select phone is refused");
check(denied(await as(db, anon, "select * from public.inventory_full()")), "anon: inventory_full() is not executable");
const anonPub = await as(db, anon, "select property_id from public.inventory");
check(anonPub.rows?.length === 2, "anon: public read unchanged", anonPub.error?.message);

// The two roles see the same columns.
const cols = (await db.query(`
  select grantee, array_agg(column_name::text order by column_name) as cols
    from information_schema.column_privileges
   where table_schema = 'public' and table_name = 'inventory' and privilege_type = 'SELECT'
     and grantee in ('anon', 'authenticated')
   group by grantee`)).rows;
const byRole = Object.fromEntries(cols.map((r) => [r.grantee, r.cols.join(",")]));
check(byRole.anon && byRole.anon === byRole.authenticated, "authenticated's column list is exactly anon's", JSON.stringify(byRole));

// Owner: everything of their own, through the function.
const oFull = await as(db, owner, "select property_id, phone, poster_email, status from public.inventory_full() order by property_id");
check(oFull.rows?.length === 2 && oFull.rows.every((r) => r.phone === "9876500001"),
  "owner: inventory_full() returns their own listings in full, paused included", oFull.error?.message ?? JSON.stringify(oFull.rows));
const oCount = await as(db, owner, "select count(*)::int as n from public.inventory_full() where posted_by = 'owner'");
check(oCount.rows?.[0]?.n === 2, "owner: and can count them there", oCount.error?.message);

// Owner writes: policies read poster_id without the caller needing a grant on it.
const upd = await as(db, owner, "update public.inventory set status = 'rented' where property_id = 'MZ-PUB001' returning property_id");
check(upd.rows?.length === 1, "owner: can still update their own listing", upd.error?.message);
const updOther = await as(db, owner, "update public.inventory set status = 'rented' where property_id = 'MZ-OTHER1' returning property_id");
check(updOther.rows?.length === 0, "owner: and still cannot update someone else's", updOther.error?.message);
const ins = await as(db, owner, `
  insert into public.inventory (property_id, poster_id, owner_id, poster_name, poster_email, phone, area, rent)
  values ('MZ-NEW001', '${OWNER}', '${OWNER}', 'Ravi Owner', 'owner@example.com', '9876500001', 'HSR Layout', 31000)
  returning property_id, status, created_at`);
check(ins.rows?.[0]?.property_id === "MZ-NEW001", "owner: can publish, returning public columns", ins.error?.message);
const insStar = await as(db, owner, `
  insert into public.inventory (property_id, poster_id, area, rent)
  values ('MZ-NEW002', '${OWNER}', 'HSR Layout', 31000) returning *`);
check(denied(insStar), "owner: but `returning *` is refused (why the app no longer asks for it)");

// Staff: every row, every column.
const sFull = await as(db, staff, "select property_id, phone, source_url, availability_checked_at from public.inventory_full()");
check(sFull.rows?.length === 4, "staff: inventory_full() returns every listing", sFull.error?.message ?? `${sFull.rows?.length} rows`);
check(sFull.rows?.some((r) => r.phone === "9876500002"), "staff: with contact details");
const sUpd = await as(db, staff, "update public.inventory set availability_checked_at = now() where property_id = 'MZ-OTHER1' returning property_id");
check(sUpd.rows?.length === 1, "staff: can still record a follow-up on anyone's listing", sUpd.error?.message);
const admin = await as(db, { uid: STAFF, email: "admin@example.com", admin: true }, "select count(*)::int as n from public.inventory_full()");
check(admin.rows?.[0]?.n === 4, "allowlisted admin: inventory_full() returns every listing", admin.error?.message);

// Visit slots: readable by all, writable by the poster, through the helper.
const tSlots = await as(db, tenant, "select count(*)::int as n from public.property_visit_slots");
check(tSlots.rows?.[0]?.n === 1, "tenant: can still read visit slots", tSlots.error?.message);
const aSlots = await as(db, anon, "select count(*)::int as n from public.property_visit_slots");
check(aSlots.rows?.[0]?.n === 1, "anon: can still read visit slots", aSlots.error?.message);
const oSlot = await as(db, owner, "insert into public.property_visit_slots (property_id, slot_at) values ('MZ-PAUSED', now() + interval '2 days') returning id");
check(oSlot.rows?.length === 1, "owner: can add a slot to their own listing", oSlot.error?.message);
const tSlot = await as(db, tenant, "insert into public.property_visit_slots (property_id, slot_at) values ('MZ-OTHER1', now() + interval '3 days') returning id");
check(/row-level security/i.test(tSlot.error?.message || ""), "tenant: cannot add a slot to someone else's listing", tSlot.error?.message ?? "insert succeeded");

// recommend_inventory, once more after the revoke.
const rec2 = await as(db, tenant, `select listing from public.recommend_inventory('{"budgetMax":"100000"}'::jsonb, 0)`);
check(rec2.rows?.length > 0 && rec2.rows.every((r) => !("phone" in r.listing)), "tenant: recommend_inventory carries no phone", rec2.error?.message);

await db.close();
console.log(`\n${passed ? "ALL CHECKS PASS" : "SOMETHING FAILED"}`);
process.exit(passed ? 0 : 1);
