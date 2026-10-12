/**
 * Apply partner_matcher_history.sql then partner_matcher_edit.sql (PGlite)
 * over the matcher test's stand-ins and check the partner's hold on a
 * shortlist:
 *   - removing a flat (before sending) keeps it out of that tenant's
 *     suggestions for good — undo puts it back; other tenants unaffected;
 *   - editing a sent list: unswiped flats out (and never again), new flats in,
 *     swiped flats stay, inventory and free-plan rules as when sending, the
 *     MovEazy tenant's CRM timeline told;
 *   - mark sold: own flat let out; anyone else's flagged for everyone, by a
 *     free partner too, the lister told;
 *   - who may do what.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});
const read = (f) => readFileSync(new URL(f, import.meta.url), "utf8");
const MATCHER = read("../partner_matcher_history.sql");
const SQL = read("../partner_matcher_edit.sql");
const mt = read("./matcher_history_check.mjs");
const end = mt.indexOf("`);\nawait db.exec(SQL);") >= 0 ? mt.indexOf("`);\nawait db.exec(SQL);") : mt.indexOf("`);\r\nawait db.exec(SQL);");
const PRELUDE = mt.slice(mt.indexOf("await db.exec(`") + "await db.exec(`".length, end);
const ids = Object.fromEntries([...mt.matchAll(/^const (B1|B2|B3|U1|C1|L1|A1|A2) = "([^"]+)";/gm)].map((m) => [m[1], m[2]]));
const INTAKE = read("../lead_intake.sql");
const ni = INTAKE.indexOf("create or replace function public.normalize_mobile");
ids.NORMALIZE = INTAKE.slice(ni, INTAKE.indexOf("$$;", ni) + 3);
const { B1, B2, L1, A1, A2 } = ids;

let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};

const db = new PGlite();
await db.exec(PRELUDE.replace(/\$\{(\w+)\}/g, (_, k) => ids[k]));
await db.exec(`
create function public.is_crm_staff() returns boolean language sql stable as $$ select false $$;
alter table public.inventory add column rent_flag text not null default '', add column updated_at timestamptz default now();
create table public.partner_listings (property_id text primary key, broker_id uuid);
create table public.partner_soldout_requests (id uuid primary key default gen_random_uuid(), property_id text, requested_by uuid,
  status text not null default 'pending', note text default '', created_at timestamptz default now());
create unique index partner_soldout_one_pending on public.partner_soldout_requests (property_id) where status = 'pending';
alter table public.partner_notifications drop constraint partner_notifications_kind_check;
-- B2's own flat, and one of B1's (a broker listing B2 can't see without Premium).
insert into public.inventory (property_id, area, rent, flat_type, src) values ('OWN-1', 'HSR Layout', 30000, '2 BHK', 'mine'), ('BR-1', 'HSR Layout', 31000, '2 BHK', 'broker');
insert into public.partner_listings values ('OWN-1', '${B2}'), ('BR-1', '${B1}');
`);
await db.exec(MATCHER);
await db.exec(SQL);
await db.exec(SQL);
check(true, "partner_matcher_edit.sql applies, and re-applies over itself");

async function as(who, sql, params = []) {
  await db.exec(`reset role; select set_config('test.uid', '${who.uid ?? ""}', false), set_config('test.email', '${who.email ?? "x@x"}', false);
    set role ${who.role ?? "authenticated"};`);
  try { return { rows: (await db.query(sql, params)).rows, error: null }; }
  catch (e) { return { rows: null, error: e }; }
  finally { await db.exec("reset role"); }
}
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const asha = { uid: B1, email: "asha@x" }, bala = { uid: B2, email: "bala@x" }, anon = { role: "anon" };
const seen = async (who, key) => (one(await as(who, "select public.partner_matcher_seen()")) ?? {})[key] ?? [];

console.log("\nremoving before sending");
let r = await as(asha, "select public.partner_matcher_exclude($1, null, 'MZ-3')", [L1]);
check(!r.error, "a partner takes a flat off their client's shortlist", r.error?.message);
check((await seen(asha, `lead:${L1}`)).includes("MZ-3"), "…and it's never suggested to them again");
check(!(await seen(asha, `asg:${A1}`)).includes("MZ-3"), "other tenants can still get it");
await as(asha, "select public.partner_matcher_exclude($1, null, 'MZ-3', true)", [L1]);
check(!(await seen(asha, `lead:${L1}`)).includes("MZ-3"), "undo puts it back");
r = await as(bala, "select public.partner_matcher_exclude($1, null, 'MZ-3')", [L1]);
check(/not yours/.test(r.error?.message ?? ""), "not on someone else's client", r.error?.message);
r = await as(bala, "select public.partner_matcher_exclude(null, $1, 'MZ-3')", [A1]);
check(Boolean(r.error), "nor on a MovEazy tenant assigned to someone else");
r = await as(bala, "select public.partner_matcher_exclude(null, $1, 'MZ-3')", [A2]);
check(!r.error, "a free partner on their own MovEazy tenant", r.error?.message);

console.log("\nediting a sent list");
const sent = one(await as(bala, "select public.partner_curated_send(null, $1, '{MZ-1,MZ-2,MZ-4}')", [A2]));
const LID = sent.id;
await db.exec(`insert into public.partner_curated_actions (list_id, property_id, action) values ('${LID}', 'MZ-1', 'liked')`);
r = await as(bala, "select public.partner_curated_edit($1, '{MZ-1}', '{}')", [LID]);
check(/already swiped MZ-1/.test(r.error?.message ?? ""), "a flat the tenant swiped stays", r.error?.message);
r = await as(bala, "select public.partner_curated_edit($1, '{MZ-2}', '{MZ-5,MZ-6}')", [LID]);
const ed = one(r);
check(ed?.count === 4 && ed.added === 2 && ed.removed === 1, "unseen flat out, two new ones in", r.error?.message ?? JSON.stringify(ed));
const after = (await db.query(`select property_ids from public.partner_curated_lists where id = '${LID}'`)).rows[0].property_ids;
check(after.join() === "MZ-1,MZ-4,MZ-5,MZ-6", "order kept, new flats at the end", after.join());
check((await seen(bala, `asg:${A2}`)).includes("MZ-2"), "the one taken out is never suggested again");
const act = (await db.query(`select body from public.crm_activities where meta->>'source' = 'partner_list_edit'`)).rows;
check(act.length === 1 && /added MZ-5, MZ-6; took out MZ-2/.test(act[0].body), "MovEazy's CRM sees the change on the tenant's timeline", JSON.stringify(act));
r = await as(bala, "select public.partner_curated_edit($1, '{}', '{NOPE-1}')", [LID]);
check(/not in your inventory/.test(r.error?.message ?? ""), "only flats they can see", r.error?.message);
r = await as(bala, "select public.partner_curated_edit($1, '{MZ-1,MZ-4,MZ-5,MZ-6}', '{}')", [LID]);
check(/swiped/.test(r.error?.message ?? ""), "a list never goes empty by accident (the swiped one stays)", r.error?.message);
r = await as(asha, "select public.partner_curated_edit($1, '{MZ-4}', '{}')", [LID]);
check(/not yours/.test(r.error?.message ?? ""), "only the partner who sent it", r.error?.message);
const big = Array.from({ length: 30 }, (_, i) => `X-${i}`);
await db.exec(`insert into public.inventory (property_id, area, rent, flat_type) select unnest('{${big.join(",")}}'::text[]), 'HSR Layout', 30000, '2 BHK'`);
r = await as(bala, "select public.partner_curated_edit($1, '{}', $2::text[])", [LID, `{${big.join(",")}}`]);
check(/up to 30/.test(r.error?.message ?? ""), "a list holds up to 30", r.error?.message);
const own = one(await as(asha, "select public.partner_curated_send($1, null, '{MZ-7}')", [L1]));
r = await as(asha, "select public.partner_curated_edit($1, '{}', '{BR-1}')", [own.id]);
check(!r.error, "a Premium partner adds a broker's flat to their own client's list", r.error?.message);

console.log("\nmark sold");
r = await as(bala, "select public.partner_mark_sold('OWN-1')");
check(one(r)?.kind === "let_out" && (await db.query("select status from public.inventory where property_id = 'OWN-1'")).rows[0].status === "rented",
  "their own flat: let out", r.error?.message);
r = await as(bala, "select public.partner_mark_sold('MZ-8')");
check(one(r)?.kind === "flagged" && (await db.query("select rent_flag from public.inventory where property_id = 'MZ-8'")).rows[0].rent_flag === "potentially_rented",
  "MovEazy's flat, by a free partner: flagged potentially rented for everyone", r.error?.message);
r = await as(bala, "select public.partner_mark_sold('MZ-8')");
check(one(r)?.already === true, "flagging again is harmless");
r = await as(asha, "select public.partner_mark_sold('BR-1')");
check(one(r)?.kind === "let_out", "the lister marking their own listing lets it out");
await db.exec("update public.inventory set status = 'published' where property_id = 'BR-1'");
await db.exec(`update public.partner_listings set broker_id = '${A1}' where property_id = 'BR-1'`); // someone else lists it now
r = await as(asha, "select public.partner_mark_sold('BR-1')");
check(one(r)?.kind === "flagged", "another broker's listing is flagged, not let out", r.error?.message);
const note = (await db.query(`select title from public.partner_notifications where kind = 'sold_out_request'`)).rows;
check(note.length === 1, "the lister is told", JSON.stringify(note));

console.log("\nwho may call what");
r = await as(anon, "select public.partner_mark_sold('MZ-8')");
check(Boolean(r.error), "signed out: nothing");
r = await as({ uid: ids.B3 }, "select public.partner_matcher_exclude(null, $1, 'MZ-1')", [A2]);
check(/Only MovEazy partners/.test(r.error?.message ?? ""), "a partner still pending: nothing", r.error?.message);
r = await as(asha, "select public.partner_tenant_key($1, null)", [L1]);
check(Boolean(r.error), "the helper isn't callable directly");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
