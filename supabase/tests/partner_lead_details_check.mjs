/**
 * Apply partner_lead_details.sql (PGlite) over stand-ins and check: every board
 * row carries who is moving in and whether move-in is flexible, and a MovEazy
 * lead's page gets everything the tenant filled — the team's corrections
 * winning — with the exact move-in date (form day + what they picked).
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
// lead_move_in_date exactly as live (partner_moveazy_leads.sql).
const moveInFn = file("partner_moveazy_leads.sql").match(/create or replace function public\.lead_move_in_date[\s\S]*?\n\$\$;/)[0];

let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};
async function as(db, who, sql) {
  await db.exec(`reset role; select set_config('test.uid', '${who.uid ?? ""}', false), set_config('test.email', '', false),
    set_config('test.staff', '', false), set_config('test.super', '', false), set_config('test.scopes', '', false); set role authenticated;`);
  try { return { rows: (await db.query(sql)).rows, error: null }; } catch (e) { return { rows: null, error: e }; } finally { await db.exec("reset role"); }
}
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);

const BALA = { uid: "d1111111-0000-0000-0000-000000000006" };
const CHETAN = { uid: "d1111111-0000-0000-0000-000000000007" };
const TENANT = "a1111111-0000-0000-0000-000000000001";
const C1 = "c1111111-0000-0000-0000-000000000001"; // filled the form; team corrected budget
const C2 = "c1111111-0000-0000-0000-000000000002"; // flexible
const A1 = "b1111111-0000-0000-0000-000000000001";
const A2 = "b1111111-0000-0000-0000-000000000002";

const db = new PGlite();
await db.exec(PRELUDE);
await db.exec(`
drop table public.crm_client_requirements; drop table public.user_requirements;
create table public.crm_client_requirements (client_id uuid primary key, localities text[] default '{}', budget_min numeric, budget_max numeric,
  flat_types text[] default '{}', furnishing text default '', must_haves text[] default '{}', deal_breakers text[] default '{}',
  occupants text[] default '{}', move_in text default '', updated_at timestamptz not null default now());
create table public.user_requirements (user_id uuid primary key, office jsonb, age text default '', localities text[] default '{}',
  budget_min numeric, budget_max numeric, stretch boolean default false, occupants text[] default '{}', flat_types text[] default '{}',
  must_haves text[] default '{}', lifestyle text[] default '{}', deal_breakers text[] default '{}', priority text[] default '{}',
  notes jsonb default '{}', updated_at timestamptz not null default now());
create function public.normalize_mobile(raw text) returns text language sql immutable as $$ select right(regexp_replace(coalesce(raw, ''), '\\D', '', 'g'), 10) $$;
create function public.is_approved_partner() returns boolean language sql stable as $$ select auth.uid() is not null $$;
${moveInFn}
create table public.partner_lead_assignments (id uuid primary key, client_id uuid, broker_id uuid, status text default 'assigned', assigned_at timestamptz default now());
create table public.partner_leads (id uuid primary key default gen_random_uuid(), broker_id uuid, name text, phone text, localities text[] default '{}',
  flat_types text[] default '{}', budget_min numeric, budget_max numeric, furnishing text default '', move_in_label text default '',
  created_at timestamptz default now(), last_contacted_at timestamptz, status text default 'new', source text default '', tentative boolean default false,
  household text not null default '');
create table public.partner_tenant_track (lead_id uuid, assignment_id uuid, outcome text, outcome_at timestamptz, lost_reason text, move_in date,
  deal_property_id text default '', deal_rent numeric, deal_move_in date, actions_seen_at timestamptz);
create table public.partner_curated_lists (id uuid primary key, broker_id uuid, lead_id uuid, assignment_id uuid, opened_at timestamptz);
create table public.partner_curated_actions (list_id uuid, property_id text, action text, at timestamptz);
create table public.partner_visits (lead_id uuid, assignment_id uuid, status text, visit_at timestamptz);
create table public.partner_reminders (id uuid, broker_id uuid, lead_id uuid, assignment_id uuid, due_at timestamptz, note text, kind text, done_at timestamptz);
create table public.partner_storefront_visits (lead_id uuid);
-- partner_my_assigned_leads, as partner_moveazy_leads.sql shapes it (fixed rows here).
create function public.partner_my_assigned_leads()
returns table (id uuid, name text, phone text, localities text[], flat_types text[], occupants text[], budget_min numeric, budget_max numeric,
               move_in_raw text, move_in date, status text, closed_rent numeric, deal_type text, due_amount numeric, pack text,
               assigned_at timestamptz, last_reach_at timestamptz)
language sql stable as $$
  select '${A1}'::uuid, 'Ravi', '9000000001', '{HSR}'::text[], '{2 BHK}'::text[], '{Family}'::text[], 25000::numeric, 35000::numeric,
         'Within 15 days', '2026-11-16'::date, 'assigned', null::numeric, null, 0::numeric, 'website', now(), null::timestamptz
   where auth.uid() = '${BALA.uid}'
  union all
  select '${A2}'::uuid, 'Meera', '9000000002', '{}', '{1 BHK}', '{Bachelor}', null, 20000, 'Flexible', null, 'assigned', null, null, 0, 'website', now() - interval '1 day', null
   where auth.uid() = '${BALA.uid}'
$$;
insert into auth.users (id, email) values ('${TENANT}', 't@x.in');
insert into public.crm_clients (id, user_id, name, phone) values ('${C1}', '${TENANT}', 'Ravi', '9000000001'), ('${C2}', null, 'Meera', '9000000002');
insert into public.partner_lead_assignments (id, client_id, broker_id) values ('${A1}', '${C1}', '${BALA.uid}'), ('${A2}', '${C2}', '${BALA.uid}');
insert into public.user_requirements values ('${TENANT}', '{"display": "Embassy Tech Village"}', '29', '{HSR,Koramangala}', 20000, 25000, true,
  '{Family}', '{2 BHK}', '{Lift,Parking}', '{Gym}', '{Ground floor}', '{"Walking Distance to Office","Budget Deals"}',
  '{"moveInDate": "Within 15 days", "commuteMinutes": 30, "commuteFlexible": false, "profile": "New to Bengaluru", "moveReason": "Switched company", "aboutMe": ["I have a car"]}',
  '2026-11-01 10:00+05:30');
insert into public.crm_client_requirements (client_id, budget_max, budget_min, furnishing) values ('${C1}', 32000, 25000, 'Semi furnished');
insert into public.crm_client_requirements (client_id, move_in, updated_at) values ('${C2}', 'Flexible', now());
insert into public.partner_leads (broker_id, name, phone, household, flat_types) values ('${BALA.uid}', 'Own lead', '9000000003', 'bachelor', '{1 RK}');
`);

await db.exec(file("partner_lead_details.sql"));
await db.exec(file("partner_lead_details.sql"));
check(true, "partner_lead_details.sql applies, and re-applies over itself");

console.log("\nthe list (partner_tenants_board)");
let r = await as(db, BALA, "select public.partner_tenants_board()");
const board = one(r) ?? [];
const by = Object.fromEntries(board.map((t) => [t.name, t]));
check(by.Ravi?.household === "Family" && by.Meera?.household === "Bachelor", "MovEazy leads carry who is moving in", JSON.stringify(board.map((t) => t.household)));
check(by["Own lead"]?.household === "bachelor", "own leads carry theirs");
check(by.Meera?.move_in_flexible === true && by.Ravi?.move_in_flexible === false && by["Own lead"]?.move_in_flexible === false, "flexible move-in is flagged");
check(by.Ravi?.move_in === "2026-11-16" && by.Ravi?.qr_visits === 0 && by.Ravi?.stage === "new", "everything the board had is still there");

console.log("\nthe lead's page (partner_lead_profile)");
r = await as(db, BALA, `select public.partner_lead_profile('${A1}')`);
const p = one(r);
check(p?.budget_max == 32000 && p?.budget_min == 25000, "budget: the team's correction, not the tenant's ₹20–25k", JSON.stringify(p));
check(p?.stretch === false, "…and the tenant's 'can stretch' is dropped once the team set the budget");
check(p?.localities?.join() === "HSR,Koramangala" && p?.flat_types?.join() === "2 BHK" && p?.occupants?.join() === "Family", "fields the team left alone: the tenant's answers");
check(p?.move_in === "2026-11-16" && p?.move_in_raw === "Within 15 days", "exact move-in: filled 1 Nov + 15 days = 16 Nov", `${p?.move_in} ${p?.move_in_raw}`);
check(p?.office === "Embassy Tech Village" && p?.commute_minutes === "30" && p?.commute_flexible === false, "office and commute");
check(p?.must_haves?.join() === "Lift,Parking" && p?.deal_breakers?.join() === "Ground floor" && p?.lifestyle?.join() === "Gym"
  && p?.priority?.[0] === "Walking Distance to Office", "preferences and priorities");
check(p?.profile === "New to Bengaluru" && p?.move_reason === "Switched company" && p?.about?.[0] === "I have a car" && p?.furnishing === "Semi furnished", "about them, furnishing");
check(!("age" in p), "age is not shared");
r = await as(db, BALA, `select public.partner_lead_profile('${A2}')`);
check(one(r)?.move_in_flexible === true && one(r)?.move_in === null && one(r)?.office === "", "no form, team said Flexible: flexible, no date");
r = await as(db, CHETAN, `select public.partner_lead_profile('${A1}')`);
check(one(r) == null, "another broker gets nothing");
r = await as(db, {}, `select public.partner_lead_profile('${A1}')`);
check(one(r) == null, "signed out gets nothing");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
