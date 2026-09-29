/**
 * Apply partner_storefront.sql over the partner schema (PGlite, in-process)
 * and check the QR storefront's rules:
 *
 *   - a storefront exists for approved partners only, with a printable code;
 *   - the public page (anon) shows the broker and their live flats only —
 *     no paused flat, no MovEazy stock, no other broker's flat, no address;
 *   - a visit counts once per visitor a day, the broker's own visits never;
 *   - only signed-in tenants like and rate; never a flat off the storefront,
 *     never rating yourself; the broker sees who liked what;
 *   - the photo must come from the broker's own folder of the bucket;
 *   - the tables give nobody anything directly.
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

const A = "aaaaaaaa-0000-0000-0000-000000000001"; // broker with a storefront
const B = "bbbbbbbb-0000-0000-0000-000000000002"; // another broker
const U = "cccccccc-0000-0000-0000-000000000003"; // another tenant
const T = "dddddddd-0000-0000-0000-000000000004"; // tenant
const S = "eeeeeeee-0000-0000-0000-000000000005"; // CRM staff

// The same stand-ins partner_check.mjs uses for Supabase's auth and the CRM.
const PRELUDE = readFileSync(new URL("./partner_check.mjs", import.meta.url), "utf8")
  .split("const PRELUDE = `")[1].split("`;")[0];
const CRM_INVENTORY = readFileSync(new URL("./partner_check.mjs", import.meta.url), "utf8")
  .split("const CRM_INVENTORY = `")[1].split("`;")[0];

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
const denied = (r) => r.error?.code === "42501";
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);

const anon = { role: "anon" };
const a = { uid: A, email: "a@broker.in" };
const b = { uid: B, email: "b@broker.in" };
const tenant = { uid: T, email: "tenant@example.com" };
const other = { uid: U, email: "u@example.com" };
const staff = { uid: S, email: "agent@moveazy.co.in", staff: true };

const db = new PGlite();
// PRELUDE is JS-template text in partner_check.mjs: undo its escaped backslashes.
await db.exec(PRELUDE.replace(/\\\\/g, "\\"));
await db.exec(file("inventory_schema.sql"));
await db.exec(CRM_INVENTORY);
await db.exec(file("inventory_public_columns.sql"));
await db.exec(file("crm_property_internal.sql"));
await db.exec(file("inventory_private_read.sql"));
await db.exec(file("program_settings.sql"));
await db.exec(file("partner_schema.sql"));
await db.exec(file("partner_storefront.sql"));
await db.exec(file("partner_storefront.sql"));
check(true, "partner_storefront.sql applies, and re-applies over itself");

await db.exec(`
insert into auth.users (id, email) values
  ('${A}', 'a@broker.in'), ('${B}', 'b@broker.in'), ('${T}', 'tenant@example.com'), ('${U}', 'u@example.com'), ('${S}', 'agent@moveazy.co.in');
insert into public.user_profiles (id, email, name, phone) values
  ('${A}', 'a@broker.in', 'Asha', '9876500001'), ('${B}', 'b@broker.in', 'Bala', '9876500002'),
  ('${T}', 'tenant@example.com', 'Tara', '9876500009'), ('${U}', 'u@example.com', 'Uma', '');
insert into public.inventory (property_id, poster_name, phone, area, full_address, rent, status, flat_type)
values ('MZ-MOVE01', 'CRM', '9000000001', 'HSR Layout', '27th Main', 30000, 'published', '2 BHK');
`);
await as(db, a, "select public.partner_register('Asha', 'Asha Realty')");
await as(db, b, "select public.partner_register('Bala', '')");
for (const [who, id, status] of [[a, "MZ-ASHA01", "published"], [a, "MZ-ASHA02", "published"], [a, "MZ-ASHA03", "paused"], [b, "MZ-BALA01", "published"]]) {
  const ins = await as(db, who, `insert into public.inventory (property_id, posted_by, poster_id, area, full_address, rent, status, flat_type)
                     values ('${id}', 'broker', '${who.uid}', 'HSR Layout', 'Secret street 1', 30000, '${status}', '2 BHK')`);
  if (ins.error) check(false, `set up ${id}`, ins.error.message);
  const r = await as(db, who, `select public.partner_set_sharing('${id}', null, '[]')`);
  if (r.error) check(false, `share ${id}`, r.error.message);
}

console.log("\nthe broker's storefront");
check(denied(await as(db, tenant, "select public.partner_my_storefront()")), "a tenant has no storefront");
check(denied(await as(db, anon, "select public.partner_my_storefront()")), "nor does anon");
const mine = await as(db, a, "select public.partner_my_storefront() as s");
const code = mine.rows?.[0]?.s?.code || "";
check(/^[A-HJ-NP-Z2-9]{6}$/.test(code), "an approved partner gets a six-character code", JSON.stringify(mine.rows ?? mine.error?.message));
const again = await as(db, a, "select public.partner_my_storefront() as s");
check(again.rows?.[0]?.s?.code === code, "the same code on every call");
check(mine.rows?.[0]?.s?.homes === 2, "it counts the two live flats, not the paused one", JSON.stringify(mine.rows?.[0]?.s));
const bcode = one(await as(db, b, "select public.partner_my_storefront() ->> 'code'"));
check(bcode && bcode !== code, "another broker gets another code");

console.log("\nthe public page");
const page = await as(db, anon, `select public.partner_storefront('${code.toLowerCase()}') as p`);
const p = page.rows?.[0]?.p;
check(p?.broker?.name === "Asha" && p?.broker?.phone === "9876500001", "anon sees the broker's name and number (the code works in lower case too)", JSON.stringify(page.rows ?? page.error?.message));
check((p?.homes ?? []).map((h) => h.property_id).sort().join() === "MZ-ASHA01,MZ-ASHA02", "only their live flats: no paused flat, no MovEazy stock, no other broker's", JSON.stringify(p?.homes?.map((h) => h.property_id)));
check(!JSON.stringify(p ?? {}).includes("Secret street"), "no address on the public page");
check(one(await as(db, anon, "select public.partner_storefront('ZZZZZZ')")) === null, "an unknown code: nothing");
await db.exec(`update public.broker_partners set status = 'suspended' where user_id = '${B}'`);
check(one(await as(db, anon, `select public.partner_storefront('${bcode}')`)) === null, "a suspended broker's storefront is gone");
await db.exec(`update public.broker_partners set status = 'approved' where user_id = '${B}'`);

console.log("\nvisits");
await as(db, anon, `select public.partner_storefront_view('${code}', 'device-0001', 'qr')`);
await as(db, anon, `select public.partner_storefront_view('${code}', 'device-0001', 'qr')`);
await as(db, anon, `select public.partner_storefront_view('${code}', 'device-0002', 'link')`);
await as(db, tenant, `select public.partner_storefront_view('${code}', 'whatever', 'qr')`);
await as(db, a, `select public.partner_storefront_view('${code}', 'device-self', 'qr')`);
await as(db, anon, `select public.partner_storefront_view('${code}', 'x', 'qr')`);
const stats = (await as(db, a, "select public.partner_my_storefront() as s")).rows?.[0]?.s;
check(stats?.visitors === 3, "a visitor counts once a day; the broker's own visit and a junk id don't (3)", JSON.stringify(stats));
check(stats?.scans_week === 2, "two came from the QR", String(stats?.scans_week));
check(stats?.by_day?.length === 7 && stats.by_day[6].scans === 2, "scans per day, last 7 days", JSON.stringify(stats?.by_day));

console.log("\nlikes and ratings");
check(denied(await as(db, anon, `select public.partner_storefront_like('${code}', 'MZ-ASHA01', true)`)), "anon cannot like");
check(!(await as(db, tenant, `select public.partner_storefront_like('${code}', 'MZ-ASHA01', true)`)).error, "a signed-in tenant can");
check(!!(await as(db, tenant, `select public.partner_storefront_like('${code}', 'MZ-BALA01', true)`)).error, "not a flat from another storefront");
check(!!(await as(db, tenant, `select public.partner_storefront_like('${code}', 'MZ-ASHA03', true)`)).error, "not a paused flat");
await as(db, other, `select public.partner_storefront_like('${code}', 'MZ-ASHA02', true)`);
await as(db, other, `select public.partner_storefront_like('${code}', 'MZ-ASHA02', false)`);
const tp = (await as(db, tenant, `select public.partner_storefront('${code}') as p`)).rows?.[0]?.p;
check(JSON.stringify(tp?.liked) === '["MZ-ASHA01"]', "the tenant's page shows their own like", JSON.stringify(tp?.liked));
const s2 = (await as(db, a, "select public.partner_my_storefront() as s")).rows?.[0]?.s;
check(s2?.likes_total === 1 && s2?.likes?.[0]?.name === "Tara" && s2.likes[0].property_id === "MZ-ASHA01" && s2.likes[0].phone === "9876500009",
  "the broker sees who liked what (an unlike is gone)", JSON.stringify(s2?.likes));
check(denied(await as(db, a, `select public.partner_storefront_rate('${code}', 5)`)), "a broker cannot rate themselves");
check(!!(await as(db, tenant, `select public.partner_storefront_rate('${code}', 6)`)).error, "six stars: refused");
check(denied(await as(db, anon, `select public.partner_storefront_rate('${code}', 5)`)), "anon cannot rate");
await as(db, tenant, `select public.partner_storefront_rate('${code}', 5)`);
await as(db, tenant, `select public.partner_storefront_rate('${code}', 4)`);
const r2 = one(await as(db, other, `select public.partner_storefront_rate('${code}', 5)`));
check(Number(r2?.rating) === 4.5 && Number(r2?.ratings) === 2, "one rating per tenant, averaged (4 and 5 → 4.5 from 2)", JSON.stringify(r2));
const pr = (await as(db, anon, `select public.partner_storefront('${code}') as p`)).rows?.[0]?.p;
check(Number(pr?.broker?.rating) === 4.5 && Number(pr?.broker?.ratings) === 2, "the public page shows it", JSON.stringify(pr?.broker));

console.log("\nthe photo");
const good = `https://abc.supabase.co/storage/v1/object/public/partner-photos/${A}/me.jpg`;
check(!(await as(db, a, `select public.partner_set_storefront_photo('${good}')`)).error, "a photo from their own folder");
check(!!(await as(db, a, "select public.partner_set_storefront_photo('https://evil.example/x.jpg')")).error, "not any URL");
check(!!(await as(db, a, `select public.partner_set_storefront_photo('https://abc.supabase.co/storage/v1/object/public/partner-photos/${B}/me.jpg')`)).error, "not another broker's folder");
check(!!(await as(db, tenant, `select public.partner_set_storefront_photo('${good}')`)).error, "not a tenant");
check((await as(db, anon, `select public.partner_storefront('${code}') #>> '{broker,photo_url}' as u`)).rows?.[0]?.u === good, "the page shows the photo");
check(!(await as(db, a, "select public.partner_set_storefront_photo('')")).error, "and it can be removed");

console.log("\nno direct access");
for (const t of ["partner_storefronts", "partner_storefront_views", "partner_storefront_likes", "partner_storefront_ratings"]) {
  check(denied(await as(db, anon, `select * from public.${t}`)), `anon: ${t} refused`);
  check((await as(db, tenant, `select * from public.${t}`)).rows?.length === 0, `a tenant reads nothing from ${t}`);
}
check(denied(await as(db, tenant, `insert into public.partner_storefront_likes (broker_id, user_id, property_id) values ('${A}', '${T}', 'MZ-ASHA02')`)), "nor writes to it");
check((await as(db, staff, "select * from public.partner_storefront_likes")).rows?.length === 1, "CRM staff read it");
check(!!(await as(db, anon, `select * from public.storefront_homes('${A}')`)).error, "the helpers are not callable by anon");
check(!!(await as(db, tenant, `select public.storefront_broker('${code}')`)).error, "nor by a signed-in user");

await db.close();
console.log(`\n${passed ? "ALL CHECKS PASS" : "SOMETHING FAILED"}`);
process.exit(passed ? 0 : 1);
