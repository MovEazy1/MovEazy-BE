/**
 * partner_launch.sql § 8–9 on a real Postgres (PGlite): a broker's curated
 * list and the tenant's swipes, notifications, broker tenants kept out of
 * MovEazy's CRM leads, and the group sold-out flow.
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

const A = "aaaaaaaa-0000-0000-0000-000000000001"; // listing broker, on a plan
const B = "bbbbbbbb-0000-0000-0000-000000000002"; // broker without a plan
const C = "cccccccc-0000-0000-0000-000000000003"; // group member, on a plan
const T = "dddddddd-0000-0000-0000-000000000004"; // tenant with an account
const S = "eeeeeeee-0000-0000-0000-000000000005"; // CRM staff

const partnerCheck = readFileSync(new URL("./partner_check.mjs", import.meta.url), "utf8");
const PRELUDE = partnerCheck.split("const PRELUDE = `")[1].split("`;")[0];
const CRM_INVENTORY = partnerCheck.split("const CRM_INVENTORY = `")[1].split("`;")[0];

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
const denied = (r) => r.error?.code === "42501";
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const J = async (db, who, sql) => one(await as(db, who, sql));

const anon = { role: "anon" };
const a = { uid: A, email: "a@broker.in" };
const b = { uid: B, email: "b@broker.in" };
const c = { uid: C, email: "c@broker.in" };
const tenant = { uid: T, email: "tenant@example.com" };
const staff = { uid: S, email: "agent@moveazy.co.in", staff: true };
const manager = { ...staff, scopes: ["partners.manage"] };

const db = new PGlite();
await db.exec(PRELUDE.replace(/\\\\/g, "\\"));
await db.exec(file("inventory_schema.sql"));
await db.exec(CRM_INVENTORY);
await db.exec(file("inventory_public_columns.sql"));
await db.exec(file("crm_property_internal.sql"));
await db.exec(file("inventory_private_read.sql"));
await db.exec(file("program_settings.sql"));
await db.exec(file("partner_schema.sql"));
await db.exec(file("partner_storefront.sql"));
// The CRM's lead table, as much of it as this needs.
await db.exec("create table public.crm_clients (id uuid primary key default gen_random_uuid(), name text default '', phone text default '', source text default 'app')");
await db.exec(`
insert into auth.users (id, email) values
  ('${A}', 'a@broker.in'), ('${B}', 'b@broker.in'), ('${C}', 'c@broker.in'), ('${T}', 'tenant@example.com'), ('${S}', 'agent@moveazy.co.in');
insert into public.user_profiles (id, email, name, phone) values
  ('${A}', 'a@broker.in', 'Asha', '9876500001'), ('${B}', 'b@broker.in', 'Bala', '9876500002'),
  ('${C}', 'c@broker.in', 'Chetan', '9876500003'), ('${T}', 'tenant@example.com', 'Tara', '9876500009');
`);
await db.exec(file("partner_launch.sql"));
await db.exec(file("partner_launch.sql"));
check(true, "partner_launch.sql (§ 1–9) applies, and re-applies over itself");
for (const who of [a, b, c]) await as(db, who, "select public.partner_register(null, null)");
await as(db, manager, `select public.partner_admin_grant_tier('${A}', 'moveazy_inventory', 1)`);
await as(db, manager, `select public.partner_admin_grant_tier('${C}', 'moveazy_inventory', 1)`);

// A's flats, one shared into a group C is in.
const g = await J(db, a, "select public.partner_create_group('HSR Brokers', '')");
const tok = await J(db, a, `select public.partner_create_invite('${g}')`);
await as(db, c, `select public.partner_accept_invite('${tok}')`);
for (const id of ["MZ-A1", "MZ-A2", "MZ-A3"]) {
  await as(db, a, `insert into public.inventory (property_id, posted_by, poster_id, area, full_address, rent, status, flat_type)
                   values ('${id}', 'broker', '${A}', 'HSR Layout', 'Secret street', 30000, 'published', '2 BHK')`);
  await as(db, a, `select public.partner_set_sharing('${id}', null, '[{"group_id":"${g}","pct":50}]')`);
}
const lead = await J(db, a, "insert into public.partner_leads (name, phone) values ('Ravi', '9876511111') returning id");

console.log("\n§ 8 curated lists");
check(denied(await as(db, b, `select public.partner_curated_create(null, '{MZ-A1}')`)), "without a plan: refused");
check(!!(await as(db, a, `select public.partner_curated_create('${lead}', '{MZ-NOPE}')`)).error, "a flat the broker can't see: refused");
const bl = await J(db, b, "insert into public.partner_leads (name, phone) values ('X', '9876522222') returning id");
check(denied(await as(db, a, `select public.partner_curated_create('${bl}', '{MZ-A1}')`)), "someone else's lead: refused");
const list = await J(db, a, `select public.partner_curated_create('${lead}', '{MZ-A1,MZ-A2,MZ-A3,MZ-A1}')`);
check(list?.count === 3 && /^[0-9a-f]{32}$/.test(list.token), "a list of three (duplicates dropped) with a link token", JSON.stringify(list));

const open = await J(db, anon, `select public.partner_curated_open('${list.token}')`);
check(open?.homes?.length === 3 && open.broker?.name === "Asha" && open.lead_name === "Ravi" && open.has_contact === false,
  "anon opens it: three homes, the broker, not yet identified", JSON.stringify(open)?.slice(0, 200));
check(!JSON.stringify(open).includes("Secret street"), "no address on the tenant's page");
check((await J(db, anon, "select public.partner_curated_open('nope')")) === null, "a wrong token: nothing");
check(denied(await as(db, anon, `select public.partner_curated_act('${list.token}', 'MZ-A1', 'liked')`)), "no swiping before the mobile number");
check(!!(await as(db, anon, `select public.partner_curated_contact('${list.token}', '123', '')`)).error, "a bad number: refused");
check(!(await as(db, anon, `select public.partner_curated_contact('${list.token}', '+91 98765 33333', 'Ravi K')`)).error, "the tenant gives their mobile");
check(!!(await as(db, anon, `select public.partner_curated_act('${list.token}', 'MZ-OTHER', 'liked')`)).error, "a home not on the list: refused");
await as(db, anon, `select public.partner_curated_act('${list.token}', 'MZ-A1', 'liked')`);
await as(db, anon, `select public.partner_curated_act('${list.token}', 'MZ-A2', 'skipped')`);
const mine = await J(db, a, "select public.partner_curated_mine()");
check(mine?.[0]?.actions?.["MZ-A1"]?.action === "liked" && mine[0].actions["MZ-A2"].action === "skipped" && mine[0].tenant?.phone === "9876533333",
  "the broker sees each action and the tenant's number", JSON.stringify(mine?.[0]?.actions));
const notes = await J(db, a, "select public.partner_notifications_list()");
check(Number(notes?.unread) === 2 && notes.items[0].kind === "tenant_liked" && notes.items[0].body.includes("9876533333")
  && notes.items[1].kind === "list_opened", "the first open and a like both notify the broker", JSON.stringify(notes));
await as(db, anon, `select public.partner_curated_open('${list.token}')`);
check(Number((await J(db, a, "select public.partner_notifications_list()"))?.unread) === 2, "a second open doesn't");
await as(db, anon, `select public.partner_curated_act('${list.token}', 'MZ-A3', 'skipped')`);
const done = (await J(db, a, "select public.partner_notifications_list()"))?.items?.[0];
check(done?.kind === "list_done" && done.body.includes("1 liked") && done.body.includes("2 skipped"), "finishing the list sends one summary of likes and skips", JSON.stringify(done));
await as(db, anon, `select public.partner_curated_act('${list.token}', 'MZ-A3', 'liked')`);
check(Number(await J(db, staff, "select count(*) from public.partner_notifications where kind = 'list_done'")) === 1, "changing a swipe afterwards doesn't send another summary");
await as(db, a, "select public.partner_notifications_read()");
check(Number((await J(db, a, "select public.partner_notifications_list()"))?.unread) === 0, "…and reading clears the count");
check((await J(db, b, "select public.partner_notifications_list()"))?.items?.length === 0, "nobody else sees them");
const tRow = (await db.query(`select status, source from public.partner_tenants where phone = '9876533333'`)).rows[0];
check(tRow?.status === "unverified" && tRow.source === "curated", "the tenant is the broker's unverified tenant", JSON.stringify(tRow));

console.log("\n§ 8 kept out of MovEazy's leads");
await db.exec("insert into public.crm_clients (name, phone) values ('Ravi K', '9876533333'), ('Someone', '9000011111')");
const attr = (await db.query("select phone, attributed_to from public.crm_clients order by phone")).rows;
check(attr.find((r) => r.phone === "9876533333")?.attributed_to === A && attr.find((r) => r.phone === "9000011111")?.attributed_to === "moveazy",
  "a CRM lead whose number came through a broker is theirs; others are MovEazy's", JSON.stringify(attr));
check(denied(await as(db, a, "select public.crm_broker_leads()")), "brokers can't read the CRM's broker leads");
const bleads = await J(db, staff, "select public.crm_broker_leads()");
check(bleads?.tenants?.[0]?.broker === "Asha" && Number(bleads.tenants[0].likes) === 2 && Number(bleads.attributed_clients) === 1,
  "CRM staff see every broker tenant, with the broker and their likes", JSON.stringify(bleads));

console.log("\n§ 8 storefront likes");
const code = (await J(db, a, "select public.partner_my_storefront()"))?.code;
await as(db, tenant, `select public.partner_storefront_like('${code}', 'MZ-A3', true)`);
const sn = await J(db, a, "select public.partner_notifications_list()");
check(sn?.items?.[0]?.kind === "storefront_like" && Number(sn.unread) === 1, "a QR-page like notifies the broker too", JSON.stringify(sn?.items?.[0]));
check(Number(await J(db, staff, "select count(*) from public.partner_tenants where phone = '9876500009' and source = 'storefront'")) === 1,
  "…and makes the tenant theirs");

console.log("\n§ 9 sold out");
check(denied(await as(db, b, "select public.partner_mark_sold_out('MZ-A1')")), "without a plan: refused");
check(denied(await as(db, a, "select public.partner_mark_sold_out('MZ-A1')")), "the listing broker uses Mark as closed, not this");
const so = await J(db, c, "select public.partner_mark_sold_out('MZ-A1', 'Let on Sunday')");
check(so?.ok === true, "a group member flags it", JSON.stringify(so));
check((await J(db, anon, "select rent_flag from public.inventory where property_id = 'MZ-A1'")) === "potentially_rented", "the site shows 'potentially rented' (public column)");
check((await J(db, c, "select public.partner_mark_sold_out('MZ-A1')"))?.already === true, "flagging twice is harmless");
check(Number((await J(db, a, "select public.partner_notifications_list()"))?.unread) === 2, "the listing broker is notified");
check(denied(await as(db, c, "select public.partner_decide_sold_out('MZ-A1', true)")), "the flagger can't decide it");
check(Number((await J(db, staff, "select jsonb_array_length(public.crm_soldout_requests())"))) === 1, "MovEazy sees it in the CRM");
await as(db, a, "select public.partner_decide_sold_out('MZ-A1', true)");
const after = (await db.query("select status, rent_flag from public.inventory where property_id = 'MZ-A1'")).rows[0];
check(after?.status === "rented" && after.rent_flag === "", "the broker confirms: sold out, marker gone — the row is still there", JSON.stringify(after));
check((await J(db, c, "select public.partner_notifications_list()"))?.items?.[0]?.kind === "sold_out_decided", "the flagger hears back");
await as(db, c, "select public.partner_mark_sold_out('MZ-A2')");
await as(db, manager, "select public.partner_decide_sold_out('MZ-A2', false)");
const kept = (await db.query("select status, rent_flag from public.inventory where property_id = 'MZ-A2'")).rows[0];
check(kept?.status === "published" && kept.rent_flag === "", "MovEazy can say it's still available: back to normal", JSON.stringify(kept));

console.log("\n§ 10 poster spots and the dashboard");
check(denied(await as(db, tenant, "select public.partner_add_spot('HSR Layout', 'x')")), "a tenant can't add a poster spot");
const spot = await J(db, a, "select public.partner_add_spot('HSR Layout', '27th Main gate')");
check(/^[a-z2-9]{5}$/.test(spot?.code || ""), "a spot gets a short code", JSON.stringify(spot));
const spot2 = await J(db, a, "select public.partner_add_spot('Koramangala', 'Cafe board')");
await as(db, anon, `select public.partner_storefront_view('${code}', 'device-000A', 'qr', '${spot.code}')`);
await as(db, anon, `select public.partner_storefront_view('${code}', 'device-000B', 'link', '${spot.code}')`);
await as(db, anon, `select public.partner_storefront_view('${code}', 'device-000C', 'qr', '${spot2.code}')`);
await as(db, anon, `select public.partner_storefront_view('${code}', 'device-000D', 'qr', '')`);
await as(db, anon, `select public.partner_storefront_view('${code}', 'device-000E', 'link', 'zzzzz')`);
const ins = await J(db, a, "select public.partner_insights()");
const byArea = Object.fromEntries((ins?.by_area || []).map((x) => [x.area, Number(x.scans)]));
check(byArea["HSR Layout"] === 2 && byArea.Koramangala === 1 && byArea["Not tagged"] === 1, "scans by area: a spot's QR counts as a scan there; an unknown spot is just a link visit", JSON.stringify(ins?.by_area));
check(Number(ins?.scans_week) === 4 && ins.by_day.length === 14, "scans this week, and 14 days by day", JSON.stringify([ins?.scans_week, ins?.by_day?.length]));
check(ins?.spots?.find((x) => x.code === spot.code)?.scans === 2, "each spot shows its scans");
check(ins?.top_liked?.[0]?.property_id === "MZ-A3" && Number(ins.top_liked[0].likes) === 2, "the most liked home first (a list like + a QR-page like)", JSON.stringify(ins?.top_liked?.map((x) => [x.property_id, x.likes, x.skips])));
check(ins?.lists?.sent === 1 && ins.lists.opened === 1 && Number(ins.lists.liked) === 2 && Number(ins.lists.skipped) === 1, "list stats", JSON.stringify(ins?.lists));
check((ins?.activity || []).some((e) => e.kind === "skipped") && (ins?.activity || []).some((e) => e.via === "qr"), "the activity feed has likes and skips, from lists and the QR page");
check(denied(await as(db, tenant, "select public.partner_insights()")), "a tenant has no dashboard");
await as(db, b, `select public.partner_remove_spot('${spot.id}')`);
check((await J(db, a, "select public.partner_insights()"))?.spots?.length === 2, "nobody else can remove your spot");
await as(db, a, `select public.partner_remove_spot('${spot.id}')`);
check((await J(db, a, "select public.partner_insights()"))?.spots?.length === 1, "you can");
const pv = await J(db, anon, `select public.partner_curated_preview('${list.token}')`);
check(pv?.broker === "Asha" && pv.count === 3, "the link preview says who and how many, without counting an open", JSON.stringify(pv));

console.log("\n§ 8–9 access");
for (const t of ["partner_curated_lists", "partner_curated_actions", "partner_tenants", "partner_notifications", "partner_soldout_requests"]) {
  check(denied(await as(db, anon, `select * from public.${t}`)), `anon: ${t} refused`);
  check((await as(db, b, `select * from public.${t}`)).rows?.length === 0, `a broker reads nothing from ${t} directly`);
}

await db.close();
console.log(`\n${passed ? "ALL CHECKS PASS" : "SOMETHING FAILED"}`);
process.exit(passed ? 0 : 1);
