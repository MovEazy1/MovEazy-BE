/**
 * Apply crm_onboarding.sql over the CRM, owner, partner and building schemas
 * (PGlite, in-process) and check how CRM uploads reach their owners and brokers:
 *
 *   - an owner contact entered before the owner has an account links the flat
 *     the first time they open the owner app; one added later on an edit
 *     links at once;
 *   - the Google email decides when the CRM has one; a mobile only when it
 *     has none — a number typed on a profile never beats a mismatched email;
 *   - a building the team adds, with the owner's contact, becomes theirs with
 *     every flat in it, and a flat added to it later follows;
 *   - a flat uploaded on a broker's behalf becomes the partner's own listing
 *     only once they are on a plan, keeping its network share;
 *   - only staff with crm.properties.write add buildings; nobody calls the
 *     linking functions directly.
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
const O2 = "a2222222-0000-0000-0000-000000000002"; // Om, owner with only a phone on the CRM
const O3 = "a3333333-0000-0000-0000-000000000003"; // Mallory, who types Om's number on her profile
const B = "d1111111-0000-0000-0000-000000000006";  // Bala, partner broker
const S = "c1111111-0000-0000-0000-000000000005";  // CRM staff

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
           set_config('test.staff', '${who.staff ? "on" : ""}', false),
           set_config('test.super', '${who.super ? "on" : ""}', false),
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
const denied = (r) => r.error?.code === "42501" || /permission denied/.test(r.error?.message || "");
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const J = async (db, who, sql) => one(await as(db, who, sql));
const ids = (r) => (r.rows ?? []).map((x) => x.property_id).sort().join(",");

const anon = { role: "anon" };
const o1 = { uid: O1, email: "priya@example.com" };
const o2 = { uid: O2, email: "om@example.com" };
const o3 = { uid: O3, email: "mallory@example.com" };
const broker = { uid: B, email: "bala@broker.in" };
const staff = { uid: S, email: "agent@moveazy.co.in", staff: true };
const writer = { ...staff, scopes: ["crm.properties.write"] };
const manager = { ...staff, scopes: ["partners.manage"] };

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
await db.exec(file("crm_property_internal.sql"));
await db.exec(file("visits_schema.sql"));
await db.exec(file("tenants_schema.sql"));
await db.exec(file("program_settings.sql"));
await db.exec(file("partner_schema.sql"));
await db.exec(file("owner_schema.sql"));
await db.exec(file("partner_storefront.sql"));
await db.exec(file("partner_launch.sql"));
await db.exec(file("owner_buildings.sql"));
await db.exec(file("crm_onboarding.sql"));
await db.exec(file("crm_onboarding.sql"));
check(true, "crm_onboarding.sql applies over the CRM, owner, partner and building schemas, and re-applies over itself");

await db.exec(`
insert into auth.users (id, email) values
  ('${O1}', 'priya@example.com'), ('${O2}', 'om@example.com'), ('${O3}', 'mallory@example.com'),
  ('${B}', 'bala@broker.in'), ('${S}', 'agent@moveazy.co.in');
insert into public.user_profiles (id, email, name, phone) values
  ('${O1}', 'priya@example.com', 'Priya Kumar', '9876500001'), ('${O2}', 'om@example.com', 'Om Das', '9876500002'),
  ('${O3}', 'mallory@example.com', 'Mallory', '9876500002'), ('${B}', 'bala@broker.in', 'Bala', '9876500006'),
  ('${S}', 'agent@moveazy.co.in', 'Agent', '9876500005');
insert into public.crm_brokers (id, name, phone, email) values
  ('e1111111-0000-0000-0000-000000000001', 'Bala', '98765 00006', 'Bala@Broker.in');
`);
// What the CRM form writes: an inventory row and its private row.
const upload = (id, priv) => db.exec(`
  insert into public.inventory (property_id, posted_by, poster_id, area, full_address, rent, status, flat_type, source, partner_share_pct)
  values ('${id}', 'owner', '${S}', 'HSR Layout', 'Somewhere', 30000, 'published', '2 BHK', 'crm', 60);
  insert into public.inventory_private (property_id, source, broker_id, owner_onboarded, owner_email, owner_phone, multi_unit)
  values ('${id}', '${priv.source || "owner"}', ${priv.broker ? `'${priv.broker}'` : "null"}, ${priv.onboarded ? "true" : "false"},
          '${priv.email || ""}', '${priv.phone || ""}', ${priv.multi ? "true" : "false"});`);

console.log("\nowners");
await upload("MZ-C1", { email: "PRIYA@example.com", onboarded: true });
await upload("MZ-C2", {});
await upload("MZ-C3", { phone: "+91 98765 00002" });
await upload("MZ-C4", { email: "someone@else.com", phone: "9876500002" });
await as(db, o1, "select public.owner_register(null)");
check(ids(await as(db, o1, "select property_id from public.owner_properties()")) === "MZ-C1",
  "Priya opens the owner app: the flat the CRM put under her email is there (case ignored)");
await db.exec("update public.inventory_private set owner_email = 'priya@example.com' where property_id = 'MZ-C2'");
check(ids(await as(db, o1, "select property_id from public.owner_properties()")) === "MZ-C1,MZ-C2",
  "her email added to another flat on a later edit links it at once");
await as(db, o3, "select public.owner_register(null)");
check(ids(await as(db, o3, "select property_id from public.owner_properties()")) === "MZ-C3",
  "a phone-only contact links to the first account with that number (Mallory got there first)");
await db.exec("delete from public.owner_property_links where property_id = 'MZ-C3'");
await db.exec("update public.inventory_private set owner_email = 'om@example.com' where property_id = 'MZ-C3'");
await as(db, o2, "select public.owner_register(null)");
const om = ids(await as(db, o2, "select property_id from public.owner_properties()"));
check(om === "MZ-C3", "with Om's email on it, it is Om's — and MZ-C4's mismatched email wins over his matching number", om);
check(ids(await as(db, o3, "select property_id from public.owner_properties()")) === "",
  "Mallory, with Om's number on her profile, gets nothing an email names");

console.log("\nbuildings from the CRM");
check(denied(await as(db, staff, `select public.crm_building_save('{"name":"Lake View"}')`)), "adding a building needs crm.properties.write");
check(denied(await as(db, o1, `select public.crm_building_save('{"name":"Lake View"}')`)), "an owner cannot use the CRM's");
const bld = await J(db, writer, `select public.crm_building_save('{"name":"Lake View","area":"HSR Layout","owner_email":"newowner@example.com","total_floors":3}')`);
check(/^[A-HJ-NP-Z2-9]{6}$/.test(bld?.code || ""), "the team adds a building with no owner account yet", JSON.stringify(bld));
await upload("MZ-L0", { email: "newowner@example.com", multi: true });
await upload("MZ-L1", { multi: true });
check(!(await as(db, writer, `select public.crm_set_flat_building('MZ-L0', '${bld.id}', 0)`)).error, "puts a flat in it, on the ground floor");
await as(db, writer, `select public.crm_set_flat_building('MZ-L1', '${bld.id}', 1)`);
const opts = await J(db, staff, "select public.crm_building_options()");
check(opts?.find((x) => x.id === bld.id)?.flats === 2 && opts.find((x) => x.id === bld.id).owner_joined === false,
  "the CRM picker lists it: two flats, owner not in the app yet", JSON.stringify(opts));
const crmView = await J(db, staff, "select public.crm_buildings()");
check(crmView?.buildings?.find((x) => x.id === bld.id)?.owner?.email === "newowner@example.com",
  "Owner QR in the CRM shows the contact it is waiting for");
const N = "a4444444-0000-0000-0000-000000000004";
await db.exec(`insert into auth.users (id, email) values ('${N}', 'newowner@example.com');
  insert into public.user_profiles (id, email, name, phone) values ('${N}', 'newowner@example.com', 'Neha', '9876500044');`);
const neha = { uid: N, email: "newowner@example.com" };
await as(db, neha, "select public.owner_register(null)");
const nb = await J(db, neha, "select public.owner_buildings_list()");
check(nb?.length === 1 && nb[0].name === "Lake View" && nb[0].flats === 2, "the owner signs in: the building is hers", JSON.stringify(nb));
check(ids(await as(db, neha, "select property_id from public.owner_properties()")) === "MZ-L0,MZ-L1",
  "with both flats — the one without her contact too");
await upload("MZ-L2", {});
await as(db, writer, `select public.crm_set_flat_building('MZ-L2', '${bld.id}', 2)`);
check(ids(await as(db, neha, "select property_id from public.owner_properties()")) === "MZ-L0,MZ-L1,MZ-L2",
  "a flat the team adds to her building later is hers straight away");
const det = await J(db, neha, `select public.owner_building_detail('${bld.id}')`);
check(det?.flats?.length === 3 && det.stats, "and her dashboard shows the building's flats and funnel");

console.log("\nhouse numbers, order, societies");
await upload("MZ-L3", {});
const set = await J(db, writer, `select public.crm_building_set_units('${bld.id}', '[{"property_id":"MZ-L2","unit_no":"301","unit_order":1},
  {"property_id":"mz-l0","unit_no":"G-01","floor_number":0,"unit_order":2},{"property_id":"MZ-L3","unit_no":"402","floor_number":4}]')`);
check(set === 3, "staff group three flats with house numbers and an order (adding a new one to the building)", String(set));
check(denied(await as(db, staff, `select public.crm_building_set_units('${bld.id}', '[]')`)), "ordering needs crm.properties.write");
const page = await J(db, anon, `select public.building_page('${bld.code}')`);
check(page?.flats?.map((f) => f.property_id).join() === "MZ-L2,MZ-L0,MZ-L1,MZ-L3" && page.flats[0].unit_no === "301",
  "the QR page lists them in MovEazy's order, unordered ones after, with house numbers", page?.flats?.map((f) => `${f.property_id}:${f.unit_no}`).join());
check(!(await as(db, writer, `select public.crm_building_save('{"id":"${bld.id}","cover_video":"https://x.supabase.co/v.mp4","photos":["https://x.supabase.co/a.jpg"]}')`)).error,
  "staff add the building's cover video and photos");
const page2 = await J(db, anon, `select public.building_page('${bld.code}')`);
check(page2?.cover_video === "https://x.supabase.co/v.mp4" && page2.photos?.length === 1 && page2.kind === "building", "the QR page opens with the video");
await as(db, writer, `select public.crm_building_save('{"id":"${bld.id}","cover_video":"javascript:alert(1)"}')`);
check((await J(db, anon, `select public.building_page('${bld.code}')`))?.cover_video === "https://x.supabase.co/v.mp4", "a non-https video is ignored");
const det2 = await J(db, staff, `select public.crm_building_detail('${bld.id}')`);
check(det2?.flats?.length === 4 && det2.flats[0].unit_no === "301" && det2.owner?.email === "newowner@example.com",
  "the CRM editor sees every flat, in order, and the owner", JSON.stringify(det2?.flats?.map((f) => f.unit_no)));
check(ids(await as(db, neha, "select property_id from public.owner_properties()")) === "MZ-L0,MZ-L1,MZ-L2,MZ-L3",
  "a flat grouped into her building is hers too");
await as(db, writer, "select public.crm_set_flat_building('MZ-L3', null)");
check((await db.query("select unit_no from public.inventory where property_id = 'MZ-L3'")).rows[0].unit_no === "",
  "taking a flat out of the building clears its house number");

const soc = await J(db, writer, `select public.crm_building_save('{"name":"Green Glen Society","kind":"society","owner_email":"someone@example.com"}')`);
const socRow = (await db.query(`select kind, owner_email from public.owner_buildings where id = '${soc.id}'`)).rows[0];
check(socRow?.kind === "society" && socRow.owner_email === "", "a society keeps no single owner contact", JSON.stringify(socRow));
await upload("MZ-S1", { email: "priya@example.com", multi: true });
await upload("MZ-S2", { email: "om@example.com", multi: true });
await as(db, writer, `select public.crm_building_set_units('${soc.id}', '[{"property_id":"MZ-S1","unit_no":"A-101"},{"property_id":"MZ-S2","unit_no":"B-202"}]')`);
const pr = ids(await as(db, o1, "select property_id from public.owner_properties()"));
check(pr.includes("MZ-S1") && !pr.includes("MZ-S2"), "in a society each owner gets only their own flat", pr);
check(ids(await as(db, o2, "select property_id from public.owner_properties()")).includes("MZ-S2"), "and the other owner theirs");
check((await J(db, o1, "select public.owner_buildings_list()"))?.every((b) => b.id !== soc.id), "nobody owns the society itself");

console.log("\npartner brokers");
await as(db, broker, "select public.partner_register('Bala', 'Bala Homes')");
await upload("MZ-B1", { source: "broker", broker: "e1111111-0000-0000-0000-000000000001" });
check((await J(db, broker, "select public.partner_claim_crm_listings()")) === 0
  && Number((await db.query("select count(*) n from public.partner_listings")).rows[0].n) === 0,
  "on no plan, the flat the team added for Bala stays MovEazy's");
check(!(await as(db, manager, `select public.partner_admin_grant_tier('${B}', 'moveazy_inventory', 1)`)).error, "Bala's plan starts");
const pl = (await db.query("select broker_id from public.partner_listings where property_id = 'MZ-B1'")).rows[0];
check(pl?.broker_id === B, "the flat is now his own listing", JSON.stringify(pl));
const share = (await db.query("select share_pct from public.partner_platform_shares where property_id = 'MZ-B1'")).rows[0];
check(Number(share?.share_pct) === 60, "still shown to every partner, at the 60% it was offered at", JSON.stringify(share));
const mine = await as(db, broker, "select property_id, source from public.partner_inventory() where property_id = 'MZ-B1'");
check(mine.rows?.[0]?.source === "mine", "and his app lists it as his", JSON.stringify(mine.rows ?? mine.error?.message));
await upload("MZ-B2", { source: "broker", broker: "e1111111-0000-0000-0000-000000000001" });
check(Number((await db.query("select count(*) n from public.partner_listings where property_id = 'MZ-B2' and broker_id = '" + B + "'")).rows[0].n) === 1,
  "a flat added for him while on a plan is his at once");
check(Number(await J(db, broker, "select public.partner_claim_crm_listings()")) === 0, "claiming again changes nothing");

const sf = await J(db, staff, `select public.crm_partner_storefront('${B}')`);
check(/^[A-HJ-NP-Z2-9]{6}$/.test(sf?.code || "") && sf.name === "Bala", "the CRM gets Bala's storefront QR code (made on first ask)", JSON.stringify(sf));
check((await J(db, staff, `select public.crm_partner_storefront('${B}')`))?.code === sf?.code, "the same code every time");
check(denied(await as(db, broker, `select public.crm_partner_storefront('${B}')`)), "only staff ask for it");
check(!!(await as(db, staff, `select public.crm_partner_storefront('${O1}')`)).error, "an owner is not a partner");

console.log("\nthe CRM sees who has it");
const links = await J(db, staff, "select public.crm_property_links('mz-l0')");
check(links?.owner?.email === "newowner@example.com" && links.building?.name === "Lake View", "owner and building", JSON.stringify(links));
check((await J(db, staff, "select public.crm_property_links('MZ-B1')"))?.partner?.name === "Bala", "and the partner");
check(denied(await as(db, o1, "select public.crm_property_links('MZ-C1')")), "owners can't ask");

console.log("\nlocked down");
check(!!(await as(db, o1, `select public.owner_link_crm_properties('${O1}')`)).error, "nobody calls the owner linker directly");
check(!!(await as(db, broker, `select public.partner_link_crm_listings('${B}')`)).error, "nor the broker one");
check(!!(await as(db, anon, "select public.partner_claim_crm_listings()")).error, "anon can't claim");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
