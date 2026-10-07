/**
 * Apply storage_listing_access.sql (PGlite, in-process, with a stand-in for
 * Supabase's storage.objects) and check who may write listing photos:
 *
 *   - the flat's poster, its listing broker and its linked owner may;
 *     another broker, owner or tenant may not — upload or overwrite;
 *   - CRM staff who edit listings may write anything; staff without that may not;
 *   - a folder with no listing yet belongs to whoever uploaded into it first;
 *   - building photos belong to the building's owner;
 *   - thumbnails follow their photo; the archive and anything outside
 *     inventory/ are CRM-only; signed-out visitors write nothing.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});

const file = (name) => readFileSync(new URL(`../${name}`, import.meta.url), "utf8");
const ownerCheck = readFileSync(new URL("./owner_check.mjs", import.meta.url), "utf8");
const PRELUDE = ownerCheck.split("const PRELUDE = `")[1].split("`;")[0];

const ASHA = "d1111111-0000-0000-0000-000000000006"; // broker who listed MZ-ASHA01
const BALA = "d2222222-0000-0000-0000-000000000007"; // another broker
const PRIYA = "a1111111-0000-0000-0000-000000000001"; // owner linked to MZ-PRIY01 (uploaded by the CRM)
const OM = "a2222222-0000-0000-0000-000000000002"; // another owner
const TINA = "f1111111-0000-0000-0000-000000000011"; // tenant
const S = "c1111111-0000-0000-0000-000000000005"; // CRM staff

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

const asha = { uid: ASHA, email: "asha@broker.in" };
const bala = { uid: BALA, email: "bala@broker.in" };
const priya = { uid: PRIYA, email: "priya@example.com" };
const om = { uid: OM, email: "om@example.com" };
const tina = { uid: TINA, email: "tina@example.com" };
const editor = { uid: S, email: "agent@moveazy.co.in", staff: true, scopes: ["crm.properties.write"] };
const viewer = { uid: S, email: "agent@moveazy.co.in", staff: true, scopes: ["crm.clients.read"] };
const anon = { role: "anon" };

const db = new PGlite();
await db.exec(PRELUDE);
await db.exec(`
-- Supabase's storage.objects, as much of it as the policies touch.
create schema if not exists storage;
create table storage.objects (
  id uuid primary key default gen_random_uuid(), bucket_id text not null, name text not null,
  owner_id text default (nullif(current_setting('test.uid', true), '')), unique (bucket_id, name)
);
alter table storage.objects enable row level security;
create policy "Public read from listings" on storage.objects for select using (bucket_id = 'listings');
-- The policies this file replaces, so the test proves they are gone.
create policy "Authenticated upload to listings" on storage.objects for insert to authenticated with check (bucket_id = 'listings');
create policy "Authenticated update listings" on storage.objects for update to authenticated using (bucket_id = 'listings');
grant usage on schema storage to anon, authenticated;
grant select, insert, update on storage.objects to anon, authenticated;

-- The tables ownership is read from.
create table public.inventory (property_id text primary key, poster_id uuid, broker_id uuid, owner_id uuid);
create table public.partner_listings (property_id text primary key, broker_id uuid not null);
create table public.owner_property_links (property_id text primary key, owner_id uuid not null);
create table public.owner_buildings (id uuid primary key default gen_random_uuid(), owner_id uuid, code text unique);
insert into public.inventory values ('MZ-ASHA01', '${ASHA}', '${ASHA}', null), ('MZ-PRIY01', '${S}', null, null);
insert into public.partner_listings values ('MZ-ASHA01', '${ASHA}');
insert into public.owner_property_links values ('MZ-PRIY01', '${PRIYA}');
insert into public.owner_buildings (owner_id, code) values ('${PRIYA}', 'SUNRS2');
insert into storage.objects (bucket_id, name, owner_id) values
  ('listings', 'inventory/MZ-ASHA01/1-a.jpg', '${ASHA}'),
  ('listings', 'inventory/MZ-PRIY01/1-p.jpg', '${S}');
`);
await db.exec(file("storage_listing_access.sql"));
await db.exec(file("storage_listing_access.sql"));
check(true, "storage_listing_access.sql applies, and re-applies over itself");
const pols = (await db.query("select policyname from pg_policies where schemaname = 'storage' and tablename = 'objects' order by 1")).rows.map((r) => r.policyname);
check(!pols.includes("Authenticated upload to listings") && !pols.includes("Authenticated update listings"), "the open policies are gone", pols.join(", "));

const put = (who, name) => as(db, who, `insert into storage.objects (bucket_id, name) values ('listings', '${name}')`);
const overwrite = (who, name) => as(db, who, `update storage.objects set owner_id = owner_id where bucket_id = 'listings' and name = '${name}' returning id`);
const ok = (r) => !r.error;
const changed = (r) => !r.error && r.rows?.length === 1;

console.log("\na broker's flat");
check(ok(await put(asha, "inventory/MZ-ASHA01/2-b.jpg")), "Asha adds a photo to her own flat");
check(ok(await put(asha, "thumbs/inventory/MZ-ASHA01/2-b.jpg")), "and its thumbnail");
check(changed(await overwrite(asha, "inventory/MZ-ASHA01/1-a.jpg")), "and replaces one");
check(!ok(await put(bala, "inventory/MZ-ASHA01/3-x.jpg")), "Bala, another broker, cannot add to it");
check(!changed(await overwrite(bala, "inventory/MZ-ASHA01/1-a.jpg")), "nor replace her photo");
check(!ok(await put(bala, "thumbs/inventory/MZ-ASHA01/1-a.jpg")), "nor its thumbnail");
check(!ok(await put(tina, "inventory/MZ-ASHA01/3-x.jpg")), "nor can a tenant");

console.log("\nan owner's flat the CRM uploaded");
check(ok(await put(priya, "inventory/MZ-PRIY01/2-p.jpg")), "Priya, its linked owner, may add photos");
check(changed(await overwrite(priya, "inventory/MZ-PRIY01/1-p.jpg")), "and replace the CRM's");
check(!ok(await put(om, "inventory/MZ-PRIY01/3-x.jpg")), "Om, another owner, may not");

console.log("\nthe CRM");
check(ok(await put(editor, "inventory/MZ-ASHA01/9-crm.jpg")), "staff who edit listings may add to any flat");
check(changed(await overwrite(editor, "inventory/MZ-ASHA01/1-a.jpg")), "and replace any photo");
check(ok(await put(editor, "originals-archive/inventory/MZ-ASHA01/1-a.jpg")), "and use the archive");
check(!ok(await put(viewer, "inventory/MZ-ASHA01/9-x.jpg")), "staff without that permission may not");
check(!ok(await put(asha, "originals-archive/inventory/MZ-ASHA01/1-a.jpg")), "the archive is CRM-only");
check(!ok(await put(asha, "listings/OLD/1.jpg")), "and so is anything outside inventory/");

console.log("\na flat not saved yet (photos go up first)");
check(ok(await put(bala, "inventory/MZ-NEW001/1-n.jpg")), "Bala starts a new listing's folder");
check(ok(await put(bala, "thumbs/inventory/MZ-NEW001/1-n.jpg")), "and keeps adding to it");
check(ok(await put(bala, "inventory/MZ-NEW001/2-n.jpg")), "more photos");
check(!ok(await put(asha, "inventory/MZ-NEW001/3-x.jpg")), "Asha cannot slip a photo into his folder");
check(!ok(await put(asha, "thumbs/inventory/MZ-NEW001/9-x.jpg")), "not even a thumbnail");
await db.exec(`insert into public.inventory values ('MZ-NEW001', '${BALA}', '${BALA}', null)`);
check(ok(await put(bala, "inventory/MZ-NEW001/4-n.jpg")), "once saved, it is his listing: still his");
check(!ok(await put(asha, "inventory/MZ-NEW001/4-x.jpg")), "and still not hers");

console.log("\nbuilding photos");
check(ok(await put(priya, "inventory/BLD-SUNRS2/1-b.jpg")), "the building's owner adds photos");
check(!ok(await put(om, "inventory/BLD-SUNRS2/2-x.jpg")), "another owner cannot");
check(ok(await put(om, "inventory/BLD-K3J9QX7A/1-b.jpg")), "a new building's folder is its first uploader's");
check(!ok(await put(priya, "inventory/BLD-K3J9QX7A/2-x.jpg")), "and nobody else's");

console.log("\nodd names and visitors");
check(!ok(await put(bala, "inventory/MZ-ASHA01")), "no file name: refused");
check(!ok(await put(bala, "inventory/MZ%/1.jpg")), "a folder with wildcard characters: refused");
check(!ok(await put(anon, "inventory/MZ-ANON01/1.jpg")), "signed out: nothing");
check((await as(db, anon, "select count(*)::int n from storage.objects where bucket_id = 'listings'")).rows?.[0]?.n > 0, "reading stays public");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
