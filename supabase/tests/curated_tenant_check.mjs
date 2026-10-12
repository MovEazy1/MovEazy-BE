/**
 * Apply partner_matcher_history.sql then partner_curated_tenant.sql (PGlite)
 * over the matcher test's stand-ins and check the tenant's side of a list:
 *   - the details a tenant sees, with an approximate spot and never the address;
 *   - opening while signed in claims the list (never the partner, another
 *     partner or staff);
 *   - likes and dislikes change any time; a new like tells the partner, the
 *     same like saved twice doesn't; "finished" once, in the new words;
 *   - My homes: the partner's other lists to the same person;
 *   - moveazy.co.in: a signed-in account's partners, by claim or by number;
 *   - who may call what.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});
const read = (f) => readFileSync(new URL(f, import.meta.url), "utf8");
const MATCHER = read("../partner_matcher_history.sql");
const SQL = read("../partner_curated_tenant.sql");
const mt = read("./matcher_history_check.mjs");
const end = mt.indexOf("`);\nawait db.exec(SQL);") >= 0 ? mt.indexOf("`);\nawait db.exec(SQL);") : mt.indexOf("`);\r\nawait db.exec(SQL);");
const PRELUDE = mt.slice(mt.indexOf("await db.exec(`") + "await db.exec(`".length, end);
const ids = Object.fromEntries([...mt.matchAll(/^const (B1|B2|B3|U1|C1|L1|A1|A2) = "([^"]+)";/gm)].map((m) => [m[1], m[2]]));
const INTAKE = read("../lead_intake.sql");
const ni = INTAKE.indexOf("create or replace function public.normalize_mobile");
ids.NORMALIZE = INTAKE.slice(ni, INTAKE.indexOf("$$;", ni) + 3);
const { B1, B2, U1, L1, A1 } = ids;
const U2 = "e2222222-0000-0000-0000-000000000002"; // a tenant who signs in on the site
const U3 = "e3333333-0000-0000-0000-000000000003"; // someone unrelated
const U4 = "e4444444-0000-0000-0000-000000000004"; // the tenant's number, never opened signed in
const S1 = "e5555555-0000-0000-0000-000000000005"; // MovEazy staff

let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};

const db = new PGlite();
await db.exec(PRELUDE.replace(/\$\{(\w+)\}/g, (_, k) => ids[k]));
await db.exec(`
create function public.is_crm_staff() returns boolean language sql stable as $$ select auth.uid() = '${S1}'::uuid $$;
alter table public.inventory add column rent_flag text not null default '', add column area_sqft int, add column floor_number int,
  add column landmark text default '', add column full_address text default '', add column amenities text[] default '{}',
  add column house_rules text[] default '{}', add column occupants_allowed text[] default '{}', add column gender_pref text default 'any',
  add column max_flatmates int default 0, add column latitude numeric, add column longitude numeric;
update public.inventory set area_sqft = 1100, floor_number = 3, landmark = 'Near Agara Lake', full_address = 'Flat 302, 14th Main',
  amenities = '{Lift,Parking}', house_rules = '{No smoking}', latitude = 12.91234, longitude = 77.63891 where property_id = 'MZ-1';
update public.inventory set rent_flag = 'potentially_rented' where property_id = 'MZ-3';
insert into auth.users values ('${U2}'), ('${U3}'), ('${U4}'), ('${S1}');
insert into public.user_profiles values ('${U2}', ''), ('${U3}', '9333333333'), ('${U4}', '+91 98111 22222'), ('${S1}', '');
`);
await db.exec(MATCHER);
await db.exec(SQL);
await db.exec(SQL);
check(true, "partner_curated_tenant.sql applies, and re-applies over itself");

async function as(who, sql, params = []) {
  await db.exec(`reset role; select set_config('test.uid', '${who.uid ?? ""}', false), set_config('test.email', '${who.email ?? ""}', false);
    set role ${who.role ?? "authenticated"};`);
  try { return { rows: (await db.query(sql, params)).rows, error: null }; }
  catch (e) { return { rows: null, error: e }; }
  finally { await db.exec("reset role"); }
}
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const asha = { uid: B1 }, bala = { uid: B2 }, anon = { role: "anon" };
const riya = { uid: U1 }, tara = { uid: U2 }, stranger = { uid: U3 }, numberOnly = { uid: U4 }, staff = { uid: S1 };

// Asha's client Om: a list before he gave his number, then one he opened and gave it on.
const T1 = "a0000000-0000-0000-0000-0000000000t1".replace("t1", "01");
await db.exec(`
insert into public.partner_tenants (id, broker_id, phone, name) values ('${T1}', '${B1}', '9811122222', 'Om');
insert into public.partner_curated_lists (token, broker_id, lead_id, lead_name, property_ids, created_at)
  values ('old', '${B1}', '${L1}', 'Om', '{MZ-5,MZ-6}', now() - interval '2 days');
insert into public.partner_curated_lists (token, broker_id, lead_id, lead_name, property_ids, tenant_id)
  values ('om', '${B1}', '${L1}', 'Om', '{MZ-1,MZ-2,MZ-3}', '${T1}');
insert into public.partner_curated_lists (token, broker_id, lead_name, property_ids) values ('nobody', '${B1}', 'Someone', '{MZ-7}');
insert into public.partner_curated_lists (token, broker_id, assignment_id, lead_name, property_ids) values ('riya', '${B1}', '${A1}', 'Riya', '{MZ-2}');
`);

console.log("\nthe details screen");
let d = one(await as(anon, "select public.partner_curated_open('om')"));
const h1 = d?.homes?.[0];
check(d?.homes?.length === 3 && h1.area_sqft === 1100 && h1.floor_number === 3 && h1.landmark === "Near Agara Lake"
  && h1.amenities.join() === "Lift,Parking" && h1.house_rules.join() === "No smoking", "every detail the screen shows", JSON.stringify(h1));
check(!("full_address" in h1) && !JSON.stringify(d).includes("Flat 302"), "never the address");
check(Number(h1.approx_lat) === 12.91 && Number(h1.approx_lng) === 77.64, "an approximate spot (about half a km)", `${h1.approx_lat},${h1.approx_lng}`);
check(d.homes[2].let_out === true && d.homes[0].let_out === false, "a flat flagged rented shows as let out");
check(d.broker?.name === "Asha" && d.broker.agency === "Asha Homes" && d.broker.phone === "9800000001", "the partner's card");
check((await db.query("select claimed_by from public.partner_curated_lists where token = 'om'")).rows[0].claimed_by === null, "opening signed out claims nothing");
check(one(await as(anon, "select public.partner_curated_open('nope')")) === null, "an unknown link is null");

console.log("\nclaiming");
await as(asha, "select public.partner_curated_open('om')");
await as(bala, "select public.partner_curated_open('om')");
await as(staff, "select public.partner_curated_open('om')");
check((await db.query("select claimed_by from public.partner_curated_lists where token = 'om'")).rows[0].claimed_by === null,
  "the partner, another partner or staff opening it don't claim it");
await as(tara, "select public.partner_curated_open('om')");
await as(stranger, "select public.partner_curated_open('om')");
check((await db.query("select claimed_by from public.partner_curated_lists where token = 'om'")).rows[0].claimed_by === U2,
  "a tenant signed in on the site claims it — the first one only");

console.log("\nliking and disliking");
const notes = async (kind) => Number((await db.query(`select count(*) from public.partner_notifications where kind = '${kind}' and broker_id = '${B1}'`)).rows[0].count);
let r = await as(anon, "select public.partner_curated_act('nobody', 'MZ-7', 'liked')");
check(/mobile number first/.test(r.error?.message ?? ""), "a list with no number yet can't be answered", r.error?.message);
await as(anon, "select public.partner_curated_act('om', 'MZ-1', 'liked')");
check((await notes("tenant_liked")) === 1, "a like tells the partner");
await as(anon, "select public.partner_curated_act('om', 'MZ-1', 'liked')");
check((await notes("tenant_liked")) === 1, "the same like saved again doesn't");
await as(anon, "select public.partner_curated_act('om', 'MZ-1', 'skipped')");
check((await db.query("select action from public.partner_curated_actions where property_id = 'MZ-1'")).rows[0].action === "skipped", "changing to a dislike sticks");
await as(anon, "select public.partner_curated_act('om', 'MZ-1', 'liked')");
check((await notes("tenant_liked")) === 2, "liking it again after all tells the partner");
await as(anon, "select public.partner_curated_act('om', 'MZ-2', 'skipped')");
await as(anon, "select public.partner_curated_act('om', 'MZ-3', 'skipped')");
await as(anon, "select public.partner_curated_act('om', 'MZ-3', 'liked')");
const done = (await db.query(`select body from public.partner_notifications where kind = 'list_done'`)).rows;
check(done.length === 1 && /♥ 1 liked · ✕ 2 disliked/.test(done[0].body), "finished: once, in likes and dislikes", JSON.stringify(done));
await as(riya, "select public.partner_curated_act('riya', 'MZ-2', 'liked')");
check((await db.query(`select count(*)::int n from public.crm_activities where meta->>'source' = 'partner_like'`)).rows[0].n === 1, "a MovEazy tenant's like still lands on their CRM timeline");

console.log("\nmy homes");
let sib = one(await as(anon, "select public.partner_curated_siblings('om')"));
check(sib?.length === 1 && sib[0].token === "old" && sib[0].homes.length === 2, "the partner's earlier list to the same client", JSON.stringify(sib));
check((await db.query("select tenant_id from public.partner_curated_lists where token = 'old'")).rows[0].tenant_id === T1, "…which they can now answer");
r = await as(anon, "select public.partner_curated_act('old', 'MZ-5', 'liked')");
check(!r.error, "and do", r.error?.message);
check((one(await as(anon, "select public.partner_curated_siblings('nobody')")) ?? []).length === 0, "no number given, no other lists");
check((one(await as(anon, "select public.partner_curated_siblings('riya')")) ?? []).length === 0, "a list from someone else isn't mixed in");

console.log("\non moveazy.co.in");
let mine = one(await as(tara, "select public.tenant_my_partners()"));
check(mine?.length === 1 && mine[0].broker.name === "Asha" && mine[0].lists.length === 1 && mine[0].lists[0].token === "om", "opened signed in: their partner and that list", JSON.stringify(mine));
check(mine[0].liked.map((x) => x.property_id).sort().join() === "MZ-1,MZ-3", "…with the homes they liked", JSON.stringify(mine?.[0]?.liked));
await db.exec(`update public.user_profiles set phone = '9811122222' where id = '${U2}'`);
mine = one(await as(tara, "select public.tenant_my_partners()"));
check(mine[0].lists.map((x) => x.token).join() === "om,old" && mine[0].liked.length === 3, "with their number on file: every list from that partner", JSON.stringify(mine?.[0]?.lists));
await db.exec(`update public.user_profiles set phone = '' where id = '${U2}'`);
mine = one(await as(numberOnly, "select public.tenant_my_partners()"));
check(mine?.length === 1 && mine[0].lists.length === 2, "never opened signed in, same number: their partner too", JSON.stringify(mine));
mine = one(await as(riya, "select public.tenant_my_partners()"));
check(mine?.length === 1 && mine[0].lists[0].token === "riya", "a MovEazy tenant sees the partner MovEazy gave them", JSON.stringify(mine));
check((one(await as(stranger, "select public.tenant_my_partners()")) ?? []).length === 0, "someone unrelated sees nothing");
check((one(await as(asha, "select public.tenant_my_partners()")) ?? []).length === 0, "a partner doesn't see themselves");

console.log("\nwho may call what");
r = await as(anon, "select public.tenant_my_partners()");
check(Boolean(r.error), "signed out can't list partners");
r = await as(anon, "select public.partner_curated_homes(id) from public.partner_curated_lists limit 1");
check(Boolean(r.error), "the helpers aren't callable directly");
r = await as(tara, "select public.partner_curated_broker('" + B1 + "')");
check(Boolean(r.error), "…by anyone");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
