/**
 * Apply crm_follow_ups.sql (PGlite, over stubs) and check daily follow-ups:
 *
 *   - an outcome moves the client along: not picked → DNP and tomorrow, three
 *     in a row → Cold; talked; visit booked → visit pending; flats shared;
 *     not interested → Ice; found elsewhere → closed outside, no next date;
 *     the owner and note kept; each logged on the client;
 *   - partners assigned free from the CRM, any number, never twice; "take it
 *     off the others" removes the rest (not one who closed), keeping their
 *     history on the client; the partner hears both;
 *   - the partner's Today list and logging a call; a CRM-assigned client
 *     closes with MovEazy's 30% / 20%;
 *   - SLA colours and the scorecard;
 *   - the morning summary, once a day, to the team and the partners;
 *   - round-robin off by default, fewest-open when on;
 *   - who may call what.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});
const read = (f) => readFileSync(new URL(`../${f}`, import.meta.url), "utf8");
let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};

const RAVI = "c0000000-0000-0000-0000-000000000001";
const NEHA = "c0000000-0000-0000-0000-000000000002";
const OLD = "c0000000-0000-0000-0000-000000000003";
const B1 = "b0000000-0000-0000-0000-000000000001";
const B2 = "b0000000-0000-0000-0000-000000000002";
const B3 = "b0000000-0000-0000-0000-000000000003";
const BX = "b0000000-0000-0000-0000-000000000009";

const db = new PGlite();
await db.exec(`
create role anon; create role authenticated;
create schema auth;
create table auth.users (id uuid primary key, email text);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
create function auth.jwt() returns jsonb language sql stable as $$ select jsonb_build_object('email', current_setting('test.email', true)) $$;
insert into auth.users values ('${B1}', 'b1@x.in'), ('${B2}', 'b2@x.in'), ('${B3}', 'b3@x.in'), ('${BX}', 'bx@x.in');
create function public.is_crm_staff() returns boolean language sql stable as $$ select current_setting('test.staff', true) = 'on' $$;
create function public.has_admin_scope(s text) returns boolean language sql stable as $$ select current_setting('test.staff', true) = 'on' $$;
create function public.is_super_admin() returns boolean language sql stable as $$ select current_setting('test.email', true) = 'yatharth200018@gmail.com' $$;
create function public.normalize_mobile(p text) returns text language sql immutable as $$ select right(regexp_replace(coalesce(p, ''), '\\D', '', 'g'), 10) $$;
create table public.admin_roles (email text primary key);
insert into public.admin_roles values ('Asha@MovEazy.in');
create table public.broker_partners (user_id uuid primary key, name text default '', phone text default '', email text default '',
  agency text default '', status text default 'approved');
insert into public.broker_partners (user_id, name, phone, status) values ('${B1}', 'Kiran Realty', '+91 98111 22233', 'approved'), ('${B2}', 'Sunil Homes', '9822233344', 'approved'),
  ('${B3}', 'Meena Estates', '9833344455', 'approved'), ('${BX}', 'Pending Broker', '9844455566', 'pending');
create function public.is_approved_partner() returns boolean language sql stable security definer as $$
  select exists (select 1 from public.broker_partners where user_id = auth.uid() and status = 'approved') $$;

create table public.crm_clients (id uuid primary key, user_id uuid, name text default '', phone text default '',
  status text not null default 'fresh', temperature text, dnp_count int not null default 0, assigned_to text default '',
  next_follow_up_at timestamptz, closed_reason text, closed_at timestamptz, attributed_to text default 'moveazy', via text default '',
  updated_at timestamptz default now());
create table public.crm_activities (id bigint generated always as identity primary key, client_id uuid, actor_email text default '',
  type text default 'note', body text default '', meta jsonb default '{}', created_at timestamptz default now());
create table public.crm_notifications (id bigint generated always as identity primary key, for_email text, type text, title text, body text,
  client_id uuid, created_at timestamptz default now());
create table public.crm_client_requirements (client_id uuid primary key, localities text[] default '{}', flat_types text[] default '{}', budget_max numeric);
create table public.user_requirements (user_id uuid primary key, localities text[] default '{}', flat_types text[] default '{}', budget_max numeric);
create table public.inventory (property_id text primary key, area text, status text default 'published');
create table public.partner_listings (property_id text, broker_id uuid);
insert into public.inventory values ('P1', 'HSR'); insert into public.partner_listings values ('P1', '${B1}');
create table public.partner_lead_requests (id uuid primary key default gen_random_uuid(), broker_id uuid, pack text not null
  constraint partner_lead_requests_pack_check check (pack in ('free10', 'paid30', 'premium', 'website', 'milestone')),
  lead_count int check (lead_count between 1 and 100), amount int, utr text, prefs jsonb default '{}', status text, note text default '', decided_by text default '', decided_at timestamptz, created_at timestamptz default now());
create table public.partner_lead_assignments (id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.partner_lead_requests (id) on delete cascade,
  client_id uuid not null references public.crm_clients (id) on delete cascade, broker_id uuid not null references auth.users (id),
  status text not null default 'assigned', closed_rent numeric, deal_type text, due_amount numeric not null default 0, closed_at timestamptz,
  assigned_by text not null default '', assigned_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  follow_up_on date, follow_up_note text default '', unique (client_id, broker_id));
create table public.partner_lead_reachouts (id bigint generated always as identity primary key,
  assignment_id uuid not null references public.partner_lead_assignments (id) on delete cascade,
  client_id uuid, broker_id uuid, channel text, at timestamptz default now());
create table public.partner_lead_events (id bigint generated always as identity primary key,
  assignment_id uuid not null references public.partner_lead_assignments (id) on delete cascade,
  client_id uuid not null, broker_id uuid not null,
  kind text not null check (kind in ('call', 'whatsapp', 'status', 'follow_up', 'response', 'team_follow_up')),
  detail text not null default '', actor text not null default '', at timestamptz not null default now());
create table public.partner_notifications (id bigint generated always as identity primary key, broker_id uuid, kind text, title text,
  body text default '', link text default '', created_at timestamptz default now());
create table public.partner_website_interest (broker_id uuid, client_id uuid, property_id text, created_at timestamptz default now());
create table public.property_tenant_views (property_id text, client_id uuid, first_at timestamptz default now());
create function public.tenant_view_property_json(p text) returns jsonb language sql stable as $$ select case when p is null then null else jsonb_build_object('property_id', p) end $$;

insert into public.crm_clients (id, name, phone) values ('${RAVI}', 'Ravi', '9845012345'), ('${NEHA}', 'Neha', '9845011111'), ('${OLD}', 'Old', '9845022222');
insert into public.crm_client_requirements values ('${RAVI}', '{HSR,Bellandur}', '{"2 BHK"}', 35000);
`);
await db.exec(read("crm_follow_ups.sql"));
check(true, "crm_follow_ups.sql applies over the stubs (pg_cron absent → falls back)");
await db.exec(read("crm_follow_ups.sql"));
check(true, "and applies again");

const as = async ({ staff = false, email = "", uid = "" } = {}) => {
  await db.exec(`select set_config('test.staff', '${staff ? "on" : "off"}', false), set_config('test.email', '${email}', false),
                        set_config('test.uid', '${uid}', false)`);
};
const one = async (sql, params = []) => (await db.query(sql, params)).rows[0];
const all = async (sql, params = []) => (await db.query(sql, params)).rows;
const save = (client, p) => one(`select public.crm_follow_up_save($1, $2::jsonb) j`, [client, JSON.stringify(p)]).then((r) => r.j);
const throws = async (sql, params = []) => { try { await db.query(sql, params); return false; } catch { return true; } };

// ── Outcomes ───────────────────────────────────────────────────────────────
await as({ staff: true, email: "asha@moveazy.in" });
const tomorrow = new Date(Date.now() + 864e5).toISOString();
let c = await save(RAVI, { outcome: "not_picked", next_at: tomorrow });
check(c.status === "dnp" && c.no_answer_streak === 1 && c.dnp_count === 1 && c.next_follow_up_at, "not picked → DNP, streak 1, next date kept");
await save(RAVI, { outcome: "busy", next_at: tomorrow });
c = await save(RAVI, { outcome: "not_picked", next_at: tomorrow });
check(c.no_answer_streak === 3 && c.temperature === "cold", "three in a row → Cold", JSON.stringify(c));
check((await one(`select count(*)::int n from public.crm_activities where client_id = $1 and type = 'temperature'`, [RAVI])).n === 1,
  "Cold is logged once");
c = await save(RAVI, { outcome: "talked", note: "Wants after salary", owner: "Asha@MovEazy.in", next_at: tomorrow });
check(c.no_answer_streak === 0 && c.status === "fresh" && c.follow_up_note === "Wants after salary" && c.assigned_to === "asha@moveazy.in",
  "talked → streak reset, back from DNP, note and owner kept");
c = await save(RAVI, { outcome: "flats_shared" });
check(c.status === "shared" && c.next_follow_up_at, "flats shared → Flats shared; next date stays when not given");
c = await save(RAVI, { outcome: "visit_booked", next_at: tomorrow });
check(c.status === "visit_pending" && c.last_outcome === "visit_booked", "visit booked → visit pending");
c = await save(NEHA, { outcome: "not_interested" });
check(c.temperature === "ice" && c.next_follow_up_at === null, "not interested → Ice, no next date");
c = await save(OLD, { outcome: "found_elsewhere" });
check(c.status === "closed_outside" && c.closed_reason === "Found elsewhere" && c.next_follow_up_at === null, "found elsewhere → closed outside");
c = await save(NEHA, { next_at: tomorrow, note: "Check in" });
check(c.next_follow_up_at && c.last_outcome === "not_interested", "a date alone doesn't change the outcome");
const acts = await all(`select type, body from public.crm_activities where client_id = $1 order by id`, [RAVI]);
check(acts.filter((a) => a.type === "call").length === 6 && acts.some((a) => /Called — Talked · next follow-up .* · owner asha@moveazy.in · Wants after salary/.test(a.body)),
  "each call is on the client's history", JSON.stringify(acts.slice(-3)));
check(await throws(`select public.crm_follow_up_save($1, '{"outcome":"lol"}'::jsonb)`, [RAVI]), "an unknown outcome is refused");

// ── Assigning partners ─────────────────────────────────────────────────────
let r = (await one(`select public.crm_partner_assign($1, $2::uuid[], false, 'Hot lead') j`, [RAVI, `{${B1},${B2},${BX}}`])).j;
check(r.added.length === 2 && r.added[0].phone === "9811122233" && r.client.need === "2 BHK · HSR, Bellandur · up to ₹35,000",
  "two approved partners assigned (not the pending one), with the client's need", JSON.stringify(r));
const asg = await all(`select a.broker_id, q.pack, a.assigned_by from public.partner_lead_assignments a join public.partner_lead_requests q on q.id = a.request_id where a.client_id = $1`, [RAVI]);
check(asg.length === 2 && asg.every((a) => a.pack === "crm" && a.assigned_by === "asha@moveazy.in"), "free: on the partner's CRM request");
r = (await one(`select public.crm_partner_assign($1, $2::uuid[], false) j`, [RAVI, `{${B1}}`])).j;
check(r.added.length === 0, "never assigned twice");
await as({ uid: B1 });
check((await all(`select * from public.partner_my_lead_requests()`)).length === 0, "the CRM's holder isn't in the partner's own requests");
await as({ staff: true, email: "asha@moveazy.in" });
const notes = await all(`select broker_id, kind, title from public.partner_notifications order by id`);
check(notes.length === 2 && notes.every((n) => n.kind === "leads_assigned" && n.title === "New MovEazy client: Ravi"), "each partner is told");

// B2 closes with the CRM share.
const b2a = (await one(`select id from public.partner_lead_assignments where client_id = $1 and broker_id = $2`, [RAVI, B2])).id;
const b1a = (await one(`select id from public.partner_lead_assignments where client_id = $1 and broker_id = $2`, [RAVI, B1])).id;
await as({ uid: B2 });
const closed = (await one(`select public.partner_lead_update($1, 'closed', 40000, 'direct') j`, [b2a])).j;
check(Number(closed.due_amount) === 12000, "a CRM-assigned client closes with MovEazy's 30%", JSON.stringify(closed));

// ── The partner's Today list ───────────────────────────────────────────────
await as({ uid: B1 });
let today = (await one(`select public.partner_follow_ups() j`)).j;
check(today.length === 1 && today[0].name === "Ravi" && today[0].last_action_at === null, "the partner's Today list: their open client, nothing done yet");
const nextDay = new Date(Date.now() + 2 * 864e5).toISOString().slice(0, 10);
const fu = (await one(`select public.partner_follow_up_save($1, 'talked', $2, 'Sending 3 flats') j`, [b1a, nextDay])).j;
check(fu.status === "contacted" && fu.follow_up_on === nextDay, "logging a call: talked → contacted, next date set");
today = (await one(`select public.partner_follow_ups() j`)).j;
check(today[0].last_outcome?.startsWith("Talked · next") && today[0].last_action_at, "the call shows as their last action");
check((await one(`select count(*)::int n from public.crm_activities where client_id = $1 and body like 'Kiran Realty called — Talked%'`, [RAVI])).n === 1,
  "and on the client's CRM history");
await as({ uid: B3 });
check(await throws(`select public.partner_follow_up_save($1, 'talked', '', '')`, [b1a]), "another partner can't log on it");

// ── Taking it off the others ───────────────────────────────────────────────
await as({ staff: true, email: "asha@moveazy.in" });
r = (await one(`select public.crm_partner_assign($1, $2::uuid[], true) j`, [RAVI, `{${B3}}`])).j;
check(r.added.length === 1 && r.removed === 1, "replace: B3 added, B1 taken off, B2 (closed) kept", JSON.stringify(r));
const left = (await all(`select broker_id from public.partner_lead_assignments where client_id = $1 order by broker_id`, [RAVI])).map((x) => x.broker_id);
check(left.length === 2 && left.includes(B2) && left.includes(B3), "B2 and B3 have the client now");
check((await one(`select count(*)::int n from public.partner_lead_events where broker_id = $1 and client_id = $2 and assignment_id is null`, [B1, RAVI])).n >= 2,
  "B1's history outlives the assignment");
check((await one(`select count(*)::int n from public.partner_notifications where broker_id = $1 and kind = 'lead_removed'`, [B1])).n === 1, "B1 is told it was reassigned");
const act = (await one(`select public.crm_client_broker_activity($1) j`, [RAVI])).j;
const gone = act.find((x) => x.broker_id === B1);
check(act.length === 3 && gone?.removed_at && gone.events.some((e) => e.kind === "outcome") && gone.events.some((e) => e.kind === "removed"),
  "the client's partners card keeps B1, marked taken off, with what they did", JSON.stringify(act.map((x) => [x.broker_name, x.removed_at, x.events.length])));
const b3a = (await one(`select id from public.partner_lead_assignments where client_id = $1 and broker_id = $2`, [RAVI, B3])).id;
check(await throws(`select public.crm_partner_unassign($1)`, [b2a]), "a partner who closed can't be taken off");
check((await one(`select public.crm_partner_unassign($1) ok`, [b3a])).ok === true, "unassign one from the record");
await one(`select public.crm_partner_assign($1, $2::uuid[], false) j`, [RAVI, `{${B3}}`]);
check((await one(`select count(*)::int n from public.partner_lead_assignments where client_id = $1 and broker_id = $2`, [RAVI, B3])).n === 1,
  "and assign them again later");

// ── SLA and scorecard ──────────────────────────────────────────────────────
await one(`select public.crm_partner_assign($1, $2::uuid[], false) j`, [NEHA, `{${B1},${B3}}`]);
await db.exec(`update public.partner_lead_assignments set assigned_at = now() - interval '50 hours' where client_id = '${NEHA}' and broker_id = '${B1}';
  update public.partner_lead_assignments set assigned_at = now() - interval '30 hours' where client_id = '${NEHA}' and broker_id = '${B3}';
  update public.partner_lead_assignments set follow_up_on = current_date - 2 where client_id = '${RAVI}' and broker_id = '${B3}';
  insert into public.partner_lead_events (assignment_id, client_id, broker_id, kind, detail)
  select id, client_id, broker_id, 'call', 'x' from public.partner_lead_assignments where client_id = '${RAVI}' and broker_id = '${B3}';`);
const board = (await one(`select public.crm_partner_follow_ups() j`)).j;
const sla = Object.fromEntries(board.rows.map((x) => [`${x.client_name}/${x.broker_name}`, x.sla]));
check(sla["Neha/Kiran Realty"] === "red" && sla["Neha/Meena Estates"] === "amber" && sla["Ravi/Meena Estates"] === "missed",
  "SLA: 50h untouched red, 30h amber, a passed follow-up missed", JSON.stringify(sla));
check(board.rows[0].sla === "red", "worst first");
const kiran = board.partners.find((p) => p.name === "Kiran Realty");
const sunil = board.partners.find((p) => p.name === "Sunil Homes");
check(kiran.open === 1 && kiran.overdue === 1 && kiran.removed_30d === 1 && sunil.closed_30d === 1,
  "scorecard: open, overdue, taken off, closed", JSON.stringify(board.partners));

// ── Morning summary ────────────────────────────────────────────────────────
await db.exec(`update public.crm_clients set next_follow_up_at = now() - interval '1 hour' where id = '${RAVI}'`);
check((await one(`select public.follow_up_digest_run(true) ran`)).ran === true, "the summary runs");
check((await one(`select public.follow_up_digest_run(true) ran`)).ran === false, "once a day");
const crmN = await all(`select for_email, title, body from public.crm_notifications where type = 'follow_up' order by for_email`);
check(crmN.length === 2 && crmN.map((n) => n.for_email).join() === "asha@moveazy.in,yatharth200018@gmail.com" && /^Follow-ups today: \d+$/.test(crmN[0].title),
  "a CRM notification for each team member", JSON.stringify(crmN));
check(/1 yours/.test(crmN[0].body) && !/yours/.test(crmN[1].body), "with how many are theirs", JSON.stringify(crmN));
const parN = await all(`select broker_id, title, body from public.partner_notifications where kind = 'follow_ups'`);
check(parN.length === 2 && parN.some((n) => n.broker_id === B1 && /overdue/.test(n.body)), "and one for each partner with clients due", JSON.stringify(parN));

// ── Round-robin ────────────────────────────────────────────────────────────
await db.exec(`insert into public.crm_clients (id, name) values (gen_random_uuid(), 'New A')`);
check((await one(`select assigned_to from public.crm_clients where name = 'New A'`)).assigned_to === "", "round-robin is off: new leads stay unassigned");
await as({ staff: true, email: "yatharth200018@gmail.com" });
check((await one(`select public.crm_follow_up_settings_set(true) j`)).j.round_robin === true, "the super admin turns it on");
await db.exec(`insert into public.crm_clients (id, name) values (gen_random_uuid(), 'New B')`);
check((await one(`select assigned_to from public.crm_clients where name = 'New B'`)).assigned_to === "yatharth200018@gmail.com",
  "on: to whoever has the fewest open clients");
await as({ staff: true, email: "asha@moveazy.in" });
check(await throws(`select public.crm_follow_up_settings_set(false)`), "only the super admin changes it");

// ── Who may call what ──────────────────────────────────────────────────────
await as({});
check(await throws(`select public.crm_follow_up_save($1, '{}'::jsonb)`, [RAVI]), "not staff: no follow-up save");
check(await throws(`select public.crm_partner_assign($1, '{}'::uuid[], true)`, [RAVI]), "not staff: no assigning");
check(await throws(`select public.crm_partner_follow_ups()`), "not staff: no partner board");
check((await one(`select public.partner_follow_ups() j`)).j.length === 0, "not a partner: an empty Today list");
const grants = await all(`select p.proname, has_function_privilege('anon', p.oid, 'execute') anon, has_function_privilege('authenticated', p.oid, 'execute') auth
  from pg_proc p where p.proname in ('crm_follow_up_save', 'crm_partner_assign', 'partner_follow_up_save', 'follow_up_digest_run', 'partner_lead_remove', 'follow_up_digest_poke')`);
const g = Object.fromEntries(grants.map((x) => [x.proname, x]));
check(Object.values(g).every((x) => !x.anon), "anon can call none of them");
check(!g.follow_up_digest_run.auth && !g.partner_lead_remove.auth && g.follow_up_digest_poke.auth && g.crm_partner_assign.auth,
  "internals stay internal; the poke is open to signed-in users");

console.log(passed ? "\nALL PASS" : "\nSOME FAILED");
process.exit(passed ? 0 : 1);
