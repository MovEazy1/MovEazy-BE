/**
 * Apply partner_matcher_history.sql then partner_tenant_care.sql (PGlite) over
 * the matcher test's stand-ins (plus the leads functions they lean on), and
 * check tenant management: the board and its self-moving stages, move-in,
 * done (with the renewal reminder) / lost / reopen — for own and MovEazy
 * tenants — reminders firing into the bell once, snooze and done, notes and
 * the timeline, what's new since the partner looked, per-flat interest,
 * free partners' lists (own + MovEazy flats only), and who may do what.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});
const read = (f) => readFileSync(new URL(f, import.meta.url), "utf8");
const MATCHER = read("../partner_matcher_history.sql");
const SQL = read("../partner_tenant_care.sql");
const mt = read("./matcher_history_check.mjs");
const PRELUDE = mt.slice(mt.indexOf("await db.exec(`") + "await db.exec(`".length, mt.indexOf("`);\nawait db.exec(SQL);") >= 0
  ? mt.indexOf("`);\nawait db.exec(SQL);") : mt.indexOf("`);\r\nawait db.exec(SQL);"));
const ids = Object.fromEntries([...mt.matchAll(/^const (B1|B2|B3|U1|C1|L1|A1|A2) = "([^"]+)";/gm)].map((m) => [m[1], m[2]]));

let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};

const INTAKE = read("../lead_intake.sql");
const ni = INTAKE.indexOf("create or replace function public.normalize_mobile");
ids.NORMALIZE = INTAKE.slice(ni, INTAKE.indexOf("$$;", ni) + 3);
const { B1, B2, L1, A2 } = ids;
const db = new PGlite();
await db.exec(PRELUDE.replace(/\$\{(\w+)\}/g, (_, k) => ids[k]));
// What the leads file provides, enough for these.
await db.exec(`
create table public.partner_lead_reachouts (id bigint generated always as identity, assignment_id uuid, broker_id uuid, channel text, at timestamptz default now());
create function public.partner_my_assigned_leads()
returns table (id uuid, name text, phone text, localities text[], flat_types text[], occupants text[], budget_min numeric, budget_max numeric,
               move_in_raw text, move_in date, status text, closed_rent numeric, deal_type text, due_amount numeric, pack text,
               assigned_at timestamptz, last_reach_at timestamptz)
language sql stable security definer as $$
  select a.id, c.name, c.phone, '{HSR Layout}'::text[], '{2 BHK}'::text[], '{}'::text[], null::numeric, 45000::numeric,
         'Within 15 days', (now() + interval '15 days')::date, a.status, null::numeric, null::text, 0::numeric, 'free10', now(),
         (select max(x.at) from public.partner_lead_reachouts x where x.assignment_id = a.id)
    from public.partner_lead_assignments a join public.crm_clients c on c.id = a.client_id where a.broker_id = auth.uid() $$;
create function public.partner_lead_update(p_assignment uuid, p_status text, p_rent numeric default null, p_deal text default null)
returns jsonb language plpgsql security definer as $$
begin
  if not exists (select 1 from public.partner_lead_assignments where id = p_assignment and broker_id = auth.uid()) then
    raise exception 'That lead isn''t yours.' using errcode = '42501'; end if;
  if p_status = 'closed' and p_deal not in ('direct', 'shared') then raise exception 'Say how the deal went.' using errcode = '22023'; end if;
  update public.partner_lead_assignments set status = p_status where id = p_assignment;
  return jsonb_build_object('status', p_status);
end $$;
alter table public.inventory add column if not exists nearby_areas text[] default '{}';
alter table public.partner_lead_assignments add column if not exists assigned_at timestamptz not null default now();
alter table public.partner_leads add column if not exists localities text[] not null default '{}', add column if not exists flat_types text[] not null default '{}',
  add column if not exists budget_min numeric, add column if not exists budget_max numeric, add column if not exists furnishing text not null default '',
  add column if not exists last_contacted_at timestamptz, add column if not exists created_at timestamptz not null default now(),
  add column if not exists updated_at timestamptz not null default now();
insert into public.inventory (property_id, area, rent, flat_type, src) values ('BR-1', 'HSR Layout', 40000, '2 BHK', 'broker'), ('MINE-1', 'HSR Layout', 38000, '2 BHK', 'mine');
`);
await db.exec(MATCHER);
await db.exec(SQL);
await db.exec(SQL);
check(true, "partner_tenant_care.sql applies, and re-applies over itself");

async function as(who, sql, params = []) {
  await db.exec(`reset role; select set_config('test.uid', '${who.uid ?? ""}', false), set_config('test.email', '${who.email ?? ""}', false);
    set role ${who.role ?? "authenticated"};`);
  try { return { rows: (await db.query(sql, params)).rows, error: null }; }
  catch (e) { return { rows: null, error: e }; }
  finally { await db.exec("reset role"); }
}
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const asha = { uid: B1, email: "asha@x" }, bala = { uid: B2, email: "bala@x" };
const board = async (who) => Object.fromEntries((one(await as(who, "select public.partner_tenants_board()")) ?? []).map((t) => [t.key, t]));

console.log("\nthe board");
let b = await board(bala);
const riya = b[`asg:${A2}`];
check(riya?.kind === "moveazy" && riya.stage === "new" && riya.name === "Riya Sharma" && riya.move_in && riya.slug === `asg-${A2}`,
  "a MovEazy tenant: new, with their move-in", JSON.stringify(riya));
b = await board(asha);
check(b[`lead:${L1}`]?.kind === "own" && b[`lead:${L1}`].stage === "new", "an own client: new");
check(!Object.keys(await board(bala)).includes(`lead:${L1}`), "nobody sees another partner's tenants");

console.log("\nstages move by themselves");
await db.exec(`insert into public.partner_lead_reachouts (assignment_id, broker_id, channel) values ('${A2}', '${B2}', 'whatsapp')`);
check((await board(bala))[`asg:${A2}`].stage === "contacted", "a WhatsApp logged: contacted");
const list = one(await as(bala, "select public.partner_curated_send(null, $1, $2::text[])", [A2, ["MZ-1", "MZ-2"]]));
check((await board(bala))[`asg:${A2}`].stage === "list_sent", "a list sent: list sent");
await as({ role: "anon" }, "select public.partner_curated_open($1)", [list.token]);
await as({ role: "anon" }, "select public.partner_curated_act($1, 'MZ-1', 'liked')", [list.token]);
b = await board(bala);
check(b[`asg:${A2}`].stage === "liked" && b[`asg:${A2}`].liked === 1 && b[`asg:${A2}`].new_actions === 1, "they liked a flat: liked, and it's new", JSON.stringify(b[`asg:${A2}`]));
await as(bala, "select public.partner_tenant_seen(null, $1)", [A2]);
check((await board(bala))[`asg:${A2}`].new_actions === 0, "the partner looked: no longer new");
await as(bala, "select public.partner_visit_set(null, $1, 'MZ-1', now() + interval '1 day')", [A2]);
check((await board(bala))[`asg:${A2}`].stage === "visit", "a visit fixed: visit fixed");

console.log("\nmove-in, done, lost, reopen");
await as(bala, `select public.partner_tenant_update(null, $1, '{"move_in":"2026-12-01"}')`, [A2]);
check((await board(bala))[`asg:${A2}`].move_in === "2026-12-01", "the partner sets the move-in date");
let r = await as(bala, `select public.partner_tenant_update(null, $1, '{"outcome":"done","deal_rent":"500"}')`, [A2]);
check(/rent/.test(r.error?.message ?? ""), "done needs the rent", r.error?.message);
r = await as(bala, `select public.partner_tenant_update(null, $1, '{"outcome":"done","deal_rent":"42000"}')`, [A2]);
check(/deal went/.test(r.error?.message ?? ""), "a MovEazy deal needs the deal type", r.error?.message);
r = await as(bala, `select public.partner_tenant_update(null, $1, '{"outcome":"done","deal_rent":"42000","deal_type":"direct","deal_property_id":"MZ-1","deal_move_in":"2026-12-01"}')`, [A2]);
check(!r.error, "deal done", r.error?.message);
b = await board(bala);
check(b[`asg:${A2}`].stage === "done" && b[`asg:${A2}`].deal.rent === 42000 && b[`asg:${A2}`].deal.property_id === "MZ-1", "done, with the deal", JSON.stringify(b[`asg:${A2}`]));
check((await db.query(`select status from public.partner_lead_assignments where id = '${A2}'`)).rows[0].status === "closed", "the MovEazy closure is recorded (its share worked out there)");
const ren = (await db.query(`select * from public.partner_reminders where assignment_id = '${A2}' and kind = 'renewal'`)).rows;
check(ren.length === 1 && new Date(ren[0].due_at).toISOString().startsWith("2027-10-01") && /Renew it/.test(ren[0].note), "a renewal reminder 10 months after move-in", JSON.stringify(ren));
r = await as(bala, `select public.partner_tenant_update(null, $1, '{"outcome":null}')`, [A2]);
check(/can't be reopened/.test(r.error?.message ?? ""), "a closed MovEazy deal isn't reopened from the app", r.error?.message);

await as(asha, `select public.partner_tenant_update($1, null, '{"outcome":"lost","lost_reason":"Went with another broker"}')`, [L1]);
b = await board(asha);
check(b[`lead:${L1}`].stage === "lost" && b[`lead:${L1}`].lost_reason === "Went with another broker", "an own client marked lost, with why");
await as(asha, `select public.partner_tenant_update($1, null, '{"outcome":null}')`, [L1]);
check((await board(asha))[`lead:${L1}`].stage === "new", "and reopened");
r = await as(bala, `select public.partner_tenant_update($1, null, '{"move_in":"2026-12-01"}')`, [L1]);
check(/isn't yours/.test(r.error?.message ?? ""), "nobody changes another partner's tenant", r.error?.message);

console.log("\nreminders");
r = await as(asha, "select public.partner_reminder_add($1, null, now() - interval '1 day', 'too late')", [L1]);
check(/from now on/.test(r.error?.message ?? ""), "not in the past", r.error?.message);
const rid = one(await as(asha, "select public.partner_reminder_add($1, null, now() + interval '1 second', 'Call about the HSR flat')", [L1]));
check(Boolean(rid), "a follow-up set");
check((await board(asha))[`lead:${L1}`].next_reminder?.note === "Call about the HSR flat", "it shows on the board as next");
await new Promise((res) => setTimeout(res, 1200));
check(one(await as(asha, "select public.partner_reminders_fire()")) === 1, "when due, it fires");
check(one(await as(asha, "select public.partner_reminders_fire()")) === 0, "once");
const bell = (await db.query(`select * from public.partner_notifications where broker_id = '${B1}' and kind = 'reminder'`)).rows;
check(bell.length === 1 && bell[0].title === "Follow up: Om" && bell[0].body === "Call about the HSR flat" && bell[0].link === `/tenants/lead-${L1}`,
  "into the bell, with the note and a link to the tenant", JSON.stringify(bell));
await as(asha, "select public.partner_reminder_snooze($1, now() + interval '1 second')", [rid]);
await new Promise((res) => setTimeout(res, 1200));
check(one(await as(asha, "select public.partner_reminders_fire()")) === 1, "snoozed: fires again when due");
const open = one(await as(asha, "select public.partner_reminders_open()"));
check(open?.length === 1 && open[0].tenant.name === "Om" && open[0].slug === `lead-${L1}`, "open reminders, with the tenant", JSON.stringify(open));
await as(bala, "select public.partner_reminder_done($1)", [rid]);
check(one(await as(asha, "select public.partner_reminders_open()"))?.length === 1, "another partner can't close it");
await as(asha, "select public.partner_reminder_done($1)", [rid]);
check(one(await as(asha, "select public.partner_reminders_open()"))?.length === 0, "done");

console.log("\nnotes and the timeline");
await as(asha, "select public.partner_tenant_note_add($1, null, 'Prefers a ground floor')", [L1]);
let tl = one(await as(asha, "select public.partner_tenant_timeline($1, null)", [L1]));
check(tl?.[0]?.kind === "note" && tl.some((e) => e.kind === "reminder") && tl.some((e) => e.kind === "start"), "the note, the follow-up done, when they were added", JSON.stringify(tl?.map((e) => e.kind)));
tl = one(await as(bala, "select public.partner_tenant_timeline(null, $1)", [A2]));
const kinds = tl?.map((e) => e.kind) ?? [];
check(["done", "visit", "liked", "opened", "list", "reach", "start"].every((k) => kinds.includes(k)), "a MovEazy tenant's whole story", JSON.stringify(kinds));
r = await as(asha, "select public.partner_tenant_timeline(null, $1)", [A2]);
check(Boolean(r.error), "not another partner's tenant's");

console.log("\nflats");
const fi = one(await as(bala, "select public.partner_flat_interest('MZ-1')"));
check(fi?.sent === 1 && fi.opened === 1 && fi.liked === 1 && fi.tenants[0].action === "liked" && fi.tenants[0].slug === `asg-${A2}`, "a flat: sent, opened, liked — and by whom", JSON.stringify(fi));
check(one(await as(asha, "select public.partner_flat_interest('MZ-1')"))?.sent === 0, "only the partner's own lists count");

console.log("\nfree partners send lists to their own clients");
await db.exec(`insert into public.partner_leads (id, broker_id, name, phone) values ('f9999999-0000-0000-0000-000000000009', '${B2}', 'Kiran', '9333333333')`);
r = await as(bala, "select public.partner_curated_send('f9999999-0000-0000-0000-000000000009', null, $1::text[])", [["MINE-1", "MZ-3"]]);
check(one(r)?.count === 2, "their own flats and MovEazy's", r.error?.message);
r = await as(bala, "select public.partner_curated_send('f9999999-0000-0000-0000-000000000009', null, $1::text[])", [["BR-1"]]);
check(/Premium/.test(r.error?.message ?? ""), "another broker's flat needs Premium", r.error?.message);
r = await as(asha, "select public.partner_curated_send($1, null, $2::text[])", [L1, ["BR-1"]]);
check(!r.error, "a Premium partner sends any flat", r.error?.message);

console.log("\nsigned out");
for (const f of ["public.partner_tenants_board()", "public.partner_reminders_open()", "public.partner_reminders_fire()"]) {
  r = await as({ role: "anon" }, `select ${f}`);
  check(Boolean(r.error), `anon can't call ${f.split("(")[0]}`);
}
r = await as(asha, "select * from public.partner_reminders");
check(Boolean(r.error), "the tables aren't readable directly");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
