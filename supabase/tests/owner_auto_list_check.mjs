/**
 * Apply owner_auto_list.sql (PGlite, in-process) and check that owner flats go
 * live by themselves:
 *
 *   - the first run lists every vacant owner flat: with a photo at once, the
 *     rest on their first photo; occupied flats, flats with a tenant and other
 *     people's listings are left alone; a re-run doesn't re-list a flat the
 *     owner has since taken off;
 *   - "List on MovEazy" on a new flat: live on its first photo (a video
 *     doesn't count), off means it stays off, and a status set by hand wins;
 *   - only the flat's owner flips it; anon can't call it at all.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});

const file = (name) =>
  readFileSync(new URL(`../${name}`, import.meta.url), "utf8")
    .replace(/create extension if not exists "pgcrypto";/g, "");

const O1 = "a1111111-0000-0000-0000-000000000001"; // Priya, owner
const O2 = "a2222222-0000-0000-0000-000000000002"; // Om, another owner
const A = "d1111111-0000-0000-0000-000000000006";  // Asha, a broker

const ownerCheck = readFileSync(new URL("./owner_check.mjs", import.meta.url), "utf8");
const PRELUDE = ownerCheck.split("const PRELUDE = `")[1].split("`;")[0];
const CRM_INVENTORY = ownerCheck.split("const CRM_INVENTORY = `")[1].split("`;")[0];

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
           set_config('test.staff', '', false),
           set_config('test.super', '', false),
           set_config('test.scopes', '', false);
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

const anon = { role: "anon" };
const o1 = { uid: O1, email: "priya@example.com" };
const o2 = { uid: O2, email: "om@example.com" };

const db = new PGlite();
await db.exec(PRELUDE);
await db.exec(`
create or replace function public.normalize_mobile(raw text) returns text language plpgsql immutable as $$
declare digits text := regexp_replace(coalesce(raw, ''), '\\D', '', 'g');
begin
  digits := case when length(digits) > 10 and left(digits, 2) = '91' then right(digits, 10) else digits end;
  return case when digits ~ '^[6-9][0-9]{9}$' then digits else '' end;
end $$;
alter table public.crm_clients alter column id set default gen_random_uuid();
alter table public.crm_clients add column if not exists source text default 'app';
`);
await db.exec(file("inventory_schema.sql"));
await db.exec(CRM_INVENTORY);
await db.exec(file("inventory_public_columns.sql"));
await db.exec(file("crm_property_internal.sql").replace(/public\.normalize_mobile\(phone\)/g, "phone"));
await db.exec(file("inventory_private_read.sql"));
await db.exec(file("visits_schema.sql"));
await db.exec(file("tenants_schema.sql"));
await db.exec(file("program_settings.sql"));
await db.exec(file("partner_schema.sql"));
await db.exec(file("owner_schema.sql"));
await db.exec(file("owner_buildings.sql"));

await db.exec(`
insert into auth.users (id, email) values ('${O1}', 'priya@example.com'), ('${O2}', 'om@example.com'), ('${A}', 'asha@broker.in');
insert into public.user_profiles (id, email, name, phone) values
  ('${O1}', 'priya@example.com', 'Priya Kumar', '9876500001'), ('${O2}', 'om@example.com', 'Om Das', '9876500002');
`);
await as(db, o1, "select public.owner_register(null)");
await as(db, o2, "select public.owner_register(null)");

const PHOTO = "https://x.supabase.co/storage/v1/object/public/listings/inventory/MZ/1.jpg";
const VIDEO = "https://x.supabase.co/storage/v1/object/public/listings/inventory/MZ/tour.mp4";
const flat = async (id, status, images, owner = O1) => {
  await db.exec(`insert into public.inventory (property_id, posted_by, poster_id, area, rent, status, flat_type, source, images)
                 values ('${id}', 'owner', '${owner}', 'Koramangala', 40000, '${status}', '2 BHK', 'owner_app', '${images}')`);
};
// Before: Priya's flats in every state, and a broker's paused flat.
await flat("OLD-PHOTO", "paused", `{${PHOTO}}`);
await flat("OLD-NOPHOTO", "paused", "{}");
await flat("OLD-VIDEO", "paused", `{${VIDEO}}`);
await flat("OLD-TENANT", "paused", `{${PHOTO}}`);
await flat("OLD-RENTED", "rented", `{${PHOTO}}`);
for (const id of ["OLD-PHOTO", "OLD-NOPHOTO", "OLD-VIDEO", "OLD-TENANT", "OLD-RENTED"]) {
  await as(db, o1, `select public.owner_claim_property('${id}')`);
}
await db.exec(`insert into public.tenants (property_id, poster_id, name, status) values ('OLD-TENANT', '${O1}', 'Ravi', 'active')`);
await db.exec(`insert into public.inventory (property_id, posted_by, poster_id, area, rent, status, flat_type, images)
               values ('BROKER-1', 'broker', '${A}', 'HSR Layout', 30000, 'paused', '1 BHK', '{${PHOTO}}')`);

await db.exec(file("owner_auto_list.sql"));
check(true, "owner_auto_list.sql applies over the owner schema");
const row = async (id) => (await db.query(`select status, list_when_ready w from public.inventory where property_id = '${id}'`)).rows[0];

console.log("\nthe first run");
check((await row("OLD-PHOTO")).status === "published", "a vacant flat with a photo goes live");
check(JSON.stringify(await row("OLD-NOPHOTO")) === JSON.stringify({ status: "paused", w: true }), "one with no photo waits for its first", JSON.stringify(await row("OLD-NOPHOTO")));
check((await row("OLD-VIDEO")).status === "paused" && (await row("OLD-VIDEO")).w, "a video alone isn't a photo: it waits");
check(JSON.stringify(await row("OLD-TENANT")) === JSON.stringify({ status: "paused", w: false }), "a flat with a tenant is left alone");
check((await row("OLD-RENTED")).status === "rented" && !(await row("OLD-RENTED")).w, "an occupied flat is left alone");
check(JSON.stringify(await row("BROKER-1")) === JSON.stringify({ status: "paused", w: false }), "a broker's paused flat is left alone");

console.log("\nre-running");
await as(db, o1, `select public.owner_update_property('OLD-PHOTO', '{"status":"paused"}')`);
await db.exec(file("owner_auto_list.sql"));
check((await row("OLD-PHOTO")).status === "paused", "a flat the owner took off stays off after a re-run");

console.log("\nwaiting flats get a photo");
const waiting = (await as(db, o1, "select array_agg(x order by x) from public.owner_waiting_to_list() x")).rows[0].array_agg;
check(JSON.stringify(waiting) === JSON.stringify(["OLD-NOPHOTO", "OLD-VIDEO"]), "the owner app sees which flats are waiting", JSON.stringify(waiting));
check(one(await as(db, o2, "select count(*)::int from public.owner_waiting_to_list()")) === 0, "another owner sees none of them");
await as(db, o1, `select public.owner_update_property('OLD-NOPHOTO', '{"images":["${PHOTO}"]}')`);
check(JSON.stringify(await row("OLD-NOPHOTO")) === JSON.stringify({ status: "published", w: false }), "first photo saved: live", JSON.stringify(await row("OLD-NOPHOTO")));
await as(db, o1, `select public.owner_update_property('OLD-VIDEO', '{"images":["${VIDEO}"],"cover_image_url":"${PHOTO.replace("1.jpg", "cover-1.jpg")}"}')`);
check((await row("OLD-VIDEO")).status === "published", "a framed cover counts as a photo");

console.log("\nthe switch on a new flat");
await flat("NEW-ON", "paused", "{}");
await as(db, o1, "select public.owner_claim_property('NEW-ON')");
check(one(await as(db, o1, "select public.owner_list_when_ready('NEW-ON', true)")) === "paused", "switched on with no photos yet: still paused");
await as(db, o1, `select public.owner_update_property('NEW-ON', '{"images":["${VIDEO}","${PHOTO}"]}')`);
check((await row("NEW-ON")).status === "published", "photos uploaded: live");

await flat("NEW-HAS", "paused", `{${PHOTO}}`);
await as(db, o1, "select public.owner_claim_property('NEW-HAS')");
check(one(await as(db, o1, "select public.owner_list_when_ready('NEW-HAS', true)")) === "published", "switched on with a photo already there: live at once");

await flat("NEW-OFF", "paused", "{}");
await as(db, o1, "select public.owner_claim_property('NEW-OFF')");
await as(db, o1, "select public.owner_list_when_ready('NEW-OFF', true)");
await as(db, o1, "select public.owner_list_when_ready('NEW-OFF', false)");
await as(db, o1, `select public.owner_update_property('NEW-OFF', '{"images":["${PHOTO}"]}')`);
check(JSON.stringify(await row("NEW-OFF")) === JSON.stringify({ status: "paused", w: false }), "switched off: a photo doesn't list it");

await flat("NEW-HAND", "paused", "{}");
await as(db, o1, "select public.owner_claim_property('NEW-HAND')");
await as(db, o1, "select public.owner_list_when_ready('NEW-HAND', true)");
await as(db, o1, `select public.owner_update_property('NEW-HAND', '{"status":"rented"}')`);
check(!(await row("NEW-HAND")).w, "marked occupied by hand: no longer waiting");
await as(db, o1, `select public.owner_update_property('NEW-HAND', '{"status":"paused"}')`);
await as(db, o1, `select public.owner_update_property('NEW-HAND', '{"images":["${PHOTO}"]}')`);
check((await row("NEW-HAND")).status === "paused", "and a later photo doesn't override that decision");

await as(db, o1, "select public.owner_list_when_ready('OLD-RENTED', true)");
check(!(await row("OLD-RENTED")).w, "switching on an occupied flat does nothing");

console.log("\nwho can flip it");
check((await as(db, o2, "select public.owner_list_when_ready('NEW-OFF', true)")).error?.code === "42501", "another owner can't");
check((await as(db, anon, "select public.owner_list_when_ready('NEW-OFF', true)")).error?.code === "42501", "anon can't call it");
check(!(await row("NEW-OFF")).w, "and nothing changed");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
