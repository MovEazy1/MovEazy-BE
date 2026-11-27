/**
 * Apply rent_agreements.sql (PGlite) over the shared PRELUDE plus light stubs
 * for the multi-city helpers and a minimal storage schema, and check the whole
 * flow: price per city, nearest-vendor routing, request → pay → vendor upload →
 * owner/tenant e-sign → completed with a renewal date, who may see Aadhaar,
 * renewal cloning, and the access rules.
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
    set_config('test.staff', '${who.staff ? "on" : ""}', false), set_config('test.super', '${who.super ? "on" : ""}', false),
    set_config('test.scopes', '${who.scopes ?? ""}', false); set role ${who.role ?? "authenticated"};`);
  try { return { rows: (await db.query(sql)).rows, error: null }; } catch (e) { return { rows: null, error: e }; } finally { await db.exec("reset role"); }
}
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
// white-box read as the bootstrap superuser (bypasses RLS); jsonb comes back already parsed
const raw = async (sql) => { await db.exec("reset role"); return (await db.query(sql)).rows; };
const rawOne = async (sql) => { const r = await raw(sql); return r[0] ? Object.values(r[0])[0] : undefined; };

const U = (n) => `d2222222-0000-0000-0000-0000000000${String(n).padStart(2, "0")}`;
const SUPER   = { uid: U(1), email: "boss@moveazy.co.in", staff: true, super: true };
const STAFF   = { uid: U(2), email: "ops@moveazy.co.in", staff: true };
const TENANT  = { uid: U(3), email: "tenant@x.in" };
const OWNER   = { uid: U(4), email: "owner@x.in" };
const VENDOR  = { uid: U(5), email: "vendor@hsr.in" };
const STRANGER= { uid: U(6), email: "nobody@x.in" };

const db = new PGlite();
await db.exec(PRELUDE);

// users + profiles (owner/tenant verified mobiles, for party matching by phone)
await db.exec(`
insert into auth.users (id, email) values
  ('${SUPER.uid}','${SUPER.email}'),('${STAFF.uid}','${STAFF.email}'),('${TENANT.uid}','${TENANT.email}'),
  ('${OWNER.uid}','${OWNER.email}'),('${VENDOR.uid}','${VENDOR.email}'),('${STRANGER.uid}','${STRANGER.email}');
insert into public.user_profiles (id, email, name, phone) values
  ('${TENANT.uid}','${TENANT.email}','Tenant','9800000011'),
  ('${OWNER.uid}','${OWNER.email}','Owner','9800000022');`);

// multi-city helper stubs (the real ones live in multi_city.sql)
await db.exec(`
create table public.cities (name text primary key, ncr boolean not null default false);
insert into public.cities (name) values ('Bengaluru'),('Mumbai'),('Pune');
create function public.normalize_city(p text) returns text language sql immutable as $$
  select case lower(trim(coalesce(p,'')))
    when 'bengaluru' then 'Bengaluru' when 'bangalore' then 'Bengaluru'
    when 'mumbai' then 'Mumbai' when 'bombay' then 'Mumbai' when 'pune' then 'Pune'
    else '' end $$;
create function public.city_of_area(p_area text, p_hint text) returns text language sql stable as $$
  select case when lower(coalesce(p_area,'')) in ('hsr','koramangala','hsr layout') then 'Bengaluru' else '' end $$;
create function public.crm_city_ok(p_city text) returns boolean language sql stable as $$
  select public.is_crm_staff() $$;`);

// normalize_mobile (real body, from lead_intake.sql)
await db.exec(`
create function public.normalize_mobile(raw text) returns text language plpgsql immutable as $$
declare digits text := regexp_replace(coalesce(raw,''),'\\D','','g'); local text;
begin
  local := case when length(digits) > 10 and left(digits,2)='91' then right(digits,10) else digits end;
  return case when local ~ '^[6-9]\\d{9}$' then local else '' end;
end $$;`);

// minimal storage schema so the file's bucket + policies apply
await db.exec(`
create schema if not exists storage;
grant usage on schema storage to anon, authenticated;
create table storage.buckets (id text primary key, name text, public boolean);
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text);
alter table storage.objects enable row level security;
grant select, insert, update on storage.objects to authenticated;`);

await db.exec(file("rent_agreements.sql"));
console.log("applied rent_agreements.sql\n");

/* ── price seeded per city ─────────────────────────────────────────────────── */
check((await rawOne(`select price from public.rent_agreement_settings where city='Bengaluru'`)) == 150, "Bengaluru price seeded at 150");
check((await one(await as(db, SUPER, `select public.rent_price('Bangalore')`))) == 150, "rent_price maps Bangalore→Bengaluru→150");
check((await one(await as(db, SUPER, `select public.rent_price('Pune')`))) == 0, "Pune price unset (0)");

/* ── vendors + nearest routing ─────────────────────────────────────────────── */
// create two Bengaluru vendors: A near HSR, B farther
const mkVendor = (who, body) => as(db, who, `select (public.crm_rent_vendor_save('${body.replace(/'/g,"''")}'::jsonb)) ->> 'id'`);
const vendorA = await one(await mkVendor(SUPER, JSON.stringify({ name:"HSR Deeds", email:VENDOR.email, phone:"9800000099", city:"Bengaluru", area:"HSR Layout", lat:12.910, lng:77.640, active:true })));
const vendorB = await one(await mkVendor(SUPER, JSON.stringify({ name:"City Deeds", email:"other@v.in", city:"Bengaluru", area:"MG Road", lat:12.975, lng:77.605, active:true })));
check(!!vendorA && !!vendorB, "two Bengaluru vendors created");
check((await one(await as(db, SUPER, `select public.rent_nearest_vendor('Bengaluru', 12.911, 77.641)`))) === vendorA, "nearest to HSR coords routes to vendor A");
check((await one(await as(db, SUPER, `select public.rent_nearest_vendor('Bengaluru', 12.976, 77.606)`))) === vendorB, "nearest to MG Road coords routes to vendor B");
check((await one(await as(db, TENANT, `select public.rent_nearest_vendor('Pune', null, null)`))) == null, "no vendor in Pune → null");
check((await mkVendor(STAFF, JSON.stringify({name:"x",email:"y@z.in",city:"Bengaluru"}))).error != null, "non-super cannot add a vendor");

/* ── tenant requests an agreement ──────────────────────────────────────────── */
const reqPayload = {
  city:"Bengaluru", role:"tenant", lat:12.911, lng:77.641, aadhaar:"1234 5678 9012",
  rent:30000, deposit:120000, start_date:"2026-12-01", duration_months:11,
  owner:{ name:"Owner Raj", mobile:"98 0000 0022", email:OWNER.email },
  tenant:{ name:"Tenant Sam", mobile:"9800000011", email:TENANT.email },
  details:{ area:"HSR Layout", address:"1 Main, HSR, 560102", flat_type:"2 BHK", furnishing:"semi",
            occupants:[{name:"Sam",relation:"self",age:29},{name:"Pat",relation:"spouse",age:28}],
            maintenance:"extra", notice_months:1, increment_pct:5 } };
const created = await as(db, TENANT, `select public.rent_request('${JSON.stringify(reqPayload).replace(/'/g,"''")}'::jsonb) as j`);
const agJson = created.rows?.[0]?.j;
const agId = agJson?.id;
check(!!agId, "rent_request created an agreement", created.error?.message);
check(agJson?.status === "unpaid" && agJson?.price === 150, "new agreement is unpaid at price 150");
check(agJson?.renewal_date?.startsWith("2026-11") === false && String(agJson?.renewal_date).startsWith("2027-11"), "renewal date = start + 11 months", String(agJson?.renewal_date));
check((await rawOne(`select vendor_id from public.rent_agreements where id='${agId}'`)) === vendorA, "routed to nearest vendor (A)");
check((await rawOne(`select count(*) from public.rent_agreement_parties where agreement_id='${agId}'`)) == 2, "owner + tenant parties created");
check((await rawOne(`select mobile from public.rent_agreement_parties where agreement_id='${agId}' and role='owner'`)) === "9800000022", "owner mobile normalised");

/* ── vendor can't see it until paid ────────────────────────────────────────── */
check((await one(await as(db, VENDOR, `select public.rent_vendor_queue('pending')`))).length === 0, "unpaid agreement is NOT in vendor queue");
check((await as(db, STRANGER, `select public.rent_vendor_queue(null)`)).error != null, "non-vendor cannot open the vendor queue");

/* ── mark paid (super) → released to vendor ────────────────────────────────── */
const paid = await as(db, SUPER, `select public.crm_rent_mark_paid('${agId}','manual') -> 'status' as s`);
check(String(paid.rows?.[0]?.s).includes("with_vendor"), "mark paid → with_vendor");
check((await as(db, STAFF, `select public.crm_rent_mark_paid('${agId}','x')`)).error != null, "non-super cannot mark paid");
let q = (await one(await as(db, VENDOR, `select public.rent_vendor_queue('pending')`)));
check(q.length === 1 && q[0].id === agId, "paid agreement now in vendor 'pending' queue");
check(q[0].tenant_aadhaar === "1234 5678 9012", "vendor sees Aadhaar");

/* ── vendor uploads the stamped PDF ────────────────────────────────────────── */
check((await as(db, VENDOR, `select public.rent_vendor_upload('${agId}','wrong/path.pdf','a.pdf')`)).error != null, "upload rejects a path outside the agreement folder");
const up = await as(db, VENDOR, `select public.rent_vendor_upload('${agId}','${agId}/stamped.pdf','stamped.pdf') -> 'status' as s`);
check(String(up.rows?.[0]?.s).includes("ready_to_sign"), "vendor upload → ready_to_sign");

/* ── fetch sign tokens (vendor view) and sign ──────────────────────────────── */
const parties = (await one(await as(db, VENDOR, `select public.rent_vendor_queue(null)`)))[0].parties;
const ownerTok = parties.find((p) => p.role === "owner").sign_token;
const tenantTok = parties.find((p) => p.role === "tenant").sign_token;
check(!!ownerTok && !!tenantTok, "sign tokens issued for both parties");

await as(db, OWNER, `select public.rent_sign_view('${ownerTok}')`);
const sig1 = await as(db, OWNER, `select public.rent_sign('${ownerTok}','typed','Owner Raj') -> 'status' as s`);
check(String(sig1.rows?.[0]?.s).includes("partially_signed"), "owner signs → partially_signed");
check((await as(db, OWNER, `select public.rent_sign('${ownerTok}','typed','Owner Raj')`)).error != null, "owner cannot sign twice");
const sig2 = await as(db, TENANT, `select public.rent_sign('${tenantTok}','drawn','data:image/png;base64,AAA') -> 'status' as s`);
check(String(sig2.rows?.[0]?.s).includes("completed"), "tenant signs → completed");
check((await rawOne(`select renewal_date from public.rent_agreements where id='${agId}'`)) != null, "renewal date set on completion");

/* ── who sees what ─────────────────────────────────────────────────────────── */
const tReq = await as(db, TENANT, `select public.rent_agreement('${agId}') -> 'tenant_aadhaar' as a`);
check(tReq.rows?.[0]?.a == null, "requester/party view hides Aadhaar");
const mine = (await one(await as(db, TENANT, `select public.rent_my_agreements()`)));
check(mine.length === 1 && mine[0].id === agId && mine[0].my_party?.role === "tenant", "rent_my_agreements shows it with my_party");
check(mine[0].tenant_aadhaar == null, "my_agreements never carries Aadhaar");
const ownerMine = (await one(await as(db, OWNER, `select public.rent_my_agreements()`)));
check(ownerMine.length === 1, "owner (matched by email/phone) also sees the agreement");
check((await as(db, STRANGER, `select public.rent_agreement('${agId}')`)).error != null, "a stranger cannot open the agreement");
check((await one(await as(db, STRANGER, `select public.rent_my_agreements()`))).length === 0, "a stranger's my_agreements is empty");

/* ── storage access function ───────────────────────────────────────────────── */
check((await one(await as(db, TENANT, `select public.rent_doc_access('${agId}/stamped.pdf', false)`))) === true, "tenant may read the stamped PDF");
check((await one(await as(db, STRANGER, `select public.rent_doc_access('${agId}/stamped.pdf', false)`))) === false, "stranger may not read the PDF");
check((await one(await as(db, TENANT, `select public.rent_doc_access('${agId}/stamped.pdf', true)`))) === false, "tenant may not write the PDF");
check((await one(await as(db, VENDOR, `select public.rent_doc_access('${agId}/x.pdf', true)`))) === true, "vendor may write the PDF");

/* ── CRM list + prices + renewals ──────────────────────────────────────────── */
check((await one(await as(db, STAFF, `select public.crm_rent_list(null,null)`))).length === 1, "crm_rent_list shows the agreement to staff");
check((await one(await as(db, STAFF, `select public.crm_rent_list('Mumbai',null)`))).length === 0, "crm_rent_list filters by city");
const detail = (await one(await as(db, STAFF, `select public.crm_rent_detail('${agId}')`)));
check(detail.tenant_aadhaar === "1234 5678 9012" && Array.isArray(detail.events) && detail.events.length >= 4, "crm_rent_detail has Aadhaar + event trail");
check((await as(db, SUPER, `select public.crm_rent_set_price('Pune', 199)`)).error == null &&
  (await one(await as(db, SUPER, `select public.rent_price('Pune')`))) == 199, "super sets Pune price to 199");
check((await as(db, STAFF, `select public.crm_rent_set_price('Pune', 1)`)).error != null, "non-super cannot set a price");

/* ── renewal clone ─────────────────────────────────────────────────────────── */
const renewed = await as(db, TENANT, `select public.rent_renew('${agId}','{}'::jsonb) as j`);
const rJson = renewed.rows?.[0]?.j;
check(!!rJson?.id && rJson.id !== agId && rJson.status === "unpaid", "rent_renew clones into a fresh unpaid agreement", renewed.error?.message);
check(String(rJson?.start_date).startsWith("2027-11"), "renewal starts on the old renewal date", String(rJson?.start_date));
check((await as(db, STRANGER, `select public.rent_renew('${agId}','{}'::jsonb)`)).error != null, "a stranger cannot renew");

/* ── direct table access is revoked ────────────────────────────────────────── */
check((await as(db, TENANT, `select * from public.rent_agreements`)).error != null, "authenticated has no direct table read");

console.log(`\n${passed ? "ALL PASSED" : "SOME FAILED"}`);
process.exit(passed ? 0 : 1);
