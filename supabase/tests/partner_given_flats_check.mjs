/**
 * Apply partner_given_flats.sql (PGlite) over stand-ins and check "Modify
 * details" on a flat MovEazy gave a partner: its sharing and owner contact
 * save (they used to fail with "You can only share your own listings.") — the
 * partner edits it in full, like a flat they added; a flat that isn't theirs
 * still refuses.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});
const file = (name) => readFileSync(new URL(`../${name}`, import.meta.url), "utf8").replace(/create extension if not exists "pgcrypto";/g, "");
const ownerCheck = readFileSync(new URL("./owner_check.mjs", import.meta.url), "utf8");
const PRELUDE = ownerCheck.split("const PRELUDE = `")[1].split("`;")[0];

let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};
async function as(db, who, sql) {
  await db.exec(`reset role; select set_config('test.uid', '${who.uid ?? ""}', false), set_config('test.email', '${who.email ?? ""}', false),
    set_config('test.staff', '', false), set_config('test.super', '', false), set_config('test.scopes', '', false); set role ${who.role ?? "authenticated"};`);
  try { return { rows: (await db.query(sql)).rows, error: null }; } catch (e) { return { rows: null, error: e }; } finally { await db.exec("reset role"); }
}
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const q = async (db, sql) => (await db.query(sql)).rows;

const BALA = { uid: "d1111111-0000-0000-0000-000000000006", email: "bala@broker.in" };
const CHETAN = { uid: "d1111111-0000-0000-0000-000000000007", email: "chetan@broker.in" };
const G1 = "e1111111-0000-0000-0000-000000000001";

const db = new PGlite();
await db.exec(PRELUDE);
await db.exec(file("inventory_schema.sql"));
await db.exec(`
alter table public.inventory add column if not exists broker_id uuid, add column if not exists owner_id uuid;
create table public.broker_partners (user_id uuid primary key, status text not null default 'approved');
create table public.partner_listings (property_id text primary key, broker_id uuid not null, mapped_by text not null default '', updated_at timestamptz default now());
create table public.partner_platform_shares (property_id text primary key, share_pct numeric);
create table public.partner_group_shares (property_id text, group_id uuid, share_pct numeric);
create table public.partner_group_members (group_id uuid, user_id uuid);
create table public.partner_property_contacts (property_id text, role text, name text, phone text);
alter table public.partner_property_contacts enable row level security;
grant select, insert, update, delete on public.partner_property_contacts to authenticated;
create function public.is_approved_partner() returns boolean language sql stable security definer as $$
  select exists (select 1 from public.broker_partners where user_id = auth.uid() and status = 'approved') $$;
create function public.is_partner_group_member(g uuid) returns boolean language sql stable security definer as $$
  select exists (select 1 from public.partner_group_members m where m.group_id = g and m.user_id = auth.uid()) $$;
create function public.owns_listing(p text, u uuid) returns boolean language sql stable security definer as $$
  select u is not null and (exists (select 1 from public.inventory i where i.property_id = p and u in (i.poster_id, i.broker_id, i.owner_id))
      or exists (select 1 from public.partner_listings l where l.property_id = p and l.broker_id = u)) $$;
insert into auth.users (id, email) values ('${BALA.uid}', '${BALA.email}'), ('${CHETAN.uid}', '${CHETAN.email}');
insert into public.broker_partners values ('${BALA.uid}', 'approved'), ('${CHETAN.uid}', 'approved');
insert into public.partner_group_members values ('${G1}', '${BALA.uid}');
-- MZ-K3: came in through MovEazy (posted by the team), given to Bala by the CRM at the 50% programme share.
insert into public.inventory (property_id, posted_by, poster_id, area, rent, status, flat_type) values
  ('MZ-K3', 'owner', null, 'Whitefield', 90000, 'published', '3 BHK'),
  ('MZ-OWN', 'broker', '${BALA.uid}', 'HSR', 30000, 'published', '2 BHK');
insert into public.partner_listings (property_id, broker_id, mapped_by) values ('MZ-K3', '${BALA.uid}', 'ops@moveazy.co.in');
insert into public.partner_platform_shares values ('MZ-K3', 50);
`);
// The bug, as it was: partner_schema.sql's own check.
await db.exec(`create function public.partner_set_sharing(p_property text, p_platform_pct numeric, p_groups jsonb default '[]') returns void
  language plpgsql security definer as $$ declare v uuid; begin
  select poster_id into v from public.inventory where property_id = p_property;
  if v is null or v <> auth.uid() then raise exception 'You can only share your own listings.' using errcode = '42501'; end if; end $$;`);
let r = await as(db, BALA, "select public.partner_set_sharing('MZ-K3', 50, '[]')");
check(r.error && /only share your own/.test(r.error.message), "before: saving a given flat failed — 'You can only share your own listings.'");

await db.exec(file("partner_given_flats.sql"));
await db.exec(file("partner_given_flats.sql"));
check(true, "partner_given_flats.sql applies, and re-applies over itself");

console.log("\na flat MovEazy gave Bala");
r = await as(db, BALA, `select public.partner_set_sharing('MZ-K3', null, '[{"group_id":"${G1}","pct":40}]')`);
check(!r.error, "Modify details saves its sharing now", r.error?.message);
check((await q(db, "select count(*)::int n from public.partner_platform_shares where property_id = 'MZ-K3'"))[0].n === 0,
  "his choice stands — like his own flat, he can take it off the all-partners pool");
r = await as(db, BALA, "select public.partner_set_sharing('MZ-K3', 60, '[]')");
check(!r.error && (await q(db, "select share_pct from public.partner_platform_shares where property_id = 'MZ-K3'"))[0]?.share_pct == 60,
  "…or share it with all partners at the % he chooses", r.error?.message);
await as(db, BALA, `select public.partner_set_sharing('MZ-K3', 60, '[{"group_id":"${G1}","pct":40}]')`);
check((await q(db, "select count(*)::int n from public.partner_group_shares where property_id = 'MZ-K3'"))[0].n === 1, "his group sharing is saved");
r = await as(db, BALA, "select public.partner_listing_sharing('MZ-K3')");
check(one(r)?.platform_pct == 60 && one(r)?.groups?.length === 1, "the edit screen reads his sharing", JSON.stringify(one(r)));
r = await as(db, BALA, "insert into public.partner_property_contacts values ('MZ-K3', 'owner', 'Sanjith', '7483488172')");
check(!r.error, "the owner's contact saves", r.error?.message);

console.log("\nhis own flat, and others'");
r = await as(db, BALA, "select public.partner_set_sharing('MZ-OWN', null, '[]')");
check(!r.error && (await q(db, "select count(*)::int n from public.partner_platform_shares where property_id = 'MZ-OWN'"))[0].n === 0,
  "on a flat he added, 'only me' still takes it off the all-partners pool", r.error?.message);
r = await as(db, CHETAN, "select public.partner_set_sharing('MZ-K3', 10, '[]')");
check(r.error && /only share your own/.test(r.error.message), "another partner still can't", r.error?.message);
r = await as(db, CHETAN, "insert into public.partner_property_contacts values ('MZ-K3', 'owner', 'X', '9000000000')");
check(Boolean(r.error), "…nor write its contacts");
r = await as(db, CHETAN, "select public.partner_listing_sharing('MZ-K3')");
check(one(r) === null, "…nor read its sharing");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
