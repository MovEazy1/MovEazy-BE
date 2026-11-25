/**
 * Apply partner_group_add.sql (PGlite) over stand-ins and check adding a
 * partner to a group by mobile number: an approved partner joins at once (and
 * is told, as are the owner/admins); any other number holds a spot for 30 days
 * and joins when it becomes an approved partner; the CRM manages every group.
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
    set_config('test.staff', '${who.staff ? "on" : ""}', false), set_config('test.super', '', false), set_config('test.scopes', '', false); set role ${who.role ?? "authenticated"};`);
  try { return { rows: (await db.query(sql)).rows, error: null }; } catch (e) { return { rows: null, error: e }; } finally { await db.exec("reset role"); }
}
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const q = async (db, sql) => (await db.query(sql)).rows;

const id = (n) => `d1111111-0000-0000-0000-00000000000${n}`;
const OWNER = { uid: id(1), email: "sanjith@broker.in" };   // owns White Field Bros
const MEMBER = { uid: id(2), email: "ravi@broker.in" };     // ordinary member
const ADMIN = { uid: id(3), email: "asha@broker.in" };      // admin
const NEWBIE = { uid: id(4), email: "kiran@broker.in" };    // approved, not in the group
const LATER = { uid: id(5), email: "later@broker.in" };     // signs up later
const BAD = { uid: id(6), email: "bad@broker.in" };         // suspended
const OUTSIDER = { uid: id(7), email: "out@broker.in" };    // approved, not a member
const STAFF = { uid: id(9), email: "ops@moveazy.co.in", staff: true };
const G = "e1111111-0000-0000-0000-000000000001";

const db = new PGlite();
await db.exec(PRELUDE);
await db.exec(`
create function public.normalize_mobile(raw text) returns text language plpgsql immutable as $$
declare digits text := regexp_replace(coalesce(raw, ''), '\\D', '', 'g'); local text;
begin
  local := case when length(digits) > 10 and left(digits, 2) = '91' then right(digits, 10) else digits end;
  return case when local ~ '^[6-9]\\d{9}$' then local else '' end;
end $$;
create table public.inventory (property_id text primary key, status text);
create table public.broker_partners (user_id uuid primary key, name text not null default '', phone text not null default '',
  alt_phone text not null default '', status text not null default 'pending', joined_via_group uuid,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table public.partner_groups (id uuid primary key default gen_random_uuid(), name text not null, description text not null default '',
  city text not null default 'Bengaluru', created_by uuid, created_at timestamptz not null default now());
create table public.partner_group_members (group_id uuid not null references public.partner_groups (id) on delete cascade, user_id uuid not null,
  role text not null default 'member' check (role in ('owner', 'admin', 'member')), added_by uuid, joined_at timestamptz not null default now(),
  primary key (group_id, user_id));
create table public.partner_group_shares (property_id text, group_id uuid, share_pct numeric);
create table public.partner_notifications (id bigint generated always as identity primary key, broker_id uuid not null, kind text not null,
  title text not null, body text not null default '', link text not null default '', created_at timestamptz not null default now(), read_at timestamptz,
  constraint partner_notifications_kind_check check (kind = any ('{tenant_liked,society,visit_assigned}'::text[])));
insert into public.partner_notifications (broker_id, kind, title) values ('${OWNER.uid}', 'visit_assigned', 'old row');
create function public.is_approved_partner() returns boolean language sql stable security definer as $$
  select exists (select 1 from public.broker_partners where user_id = auth.uid() and status = 'approved') $$;
create function public.is_partner_group_member(g uuid) returns boolean language sql stable security definer as $$
  select exists (select 1 from public.partner_group_members m where m.group_id = g and m.user_id = auth.uid()) $$;
insert into auth.users (id, email) values ${[OWNER, MEMBER, ADMIN, NEWBIE, LATER, BAD, OUTSIDER, STAFF].map((u) => `('${u.uid}', '${u.email}')`).join(", ")};
insert into public.broker_partners (user_id, name, phone, alt_phone, status) values
  ('${OWNER.uid}', 'Sanjith', '9000000001', '', 'approved'), ('${MEMBER.uid}', 'Ravi', '9000000002', '', 'approved'),
  ('${ADMIN.uid}', 'Asha', '9000000003', '', 'approved'), ('${NEWBIE.uid}', 'Kiran', '9000000004', '8000000004', 'approved'),
  ('${BAD.uid}', 'Bad', '9000000006', '', 'suspended'), ('${OUTSIDER.uid}', 'Out', '9000000007', '', 'approved');
insert into public.partner_groups (id, name, created_by) values ('${G}', 'White Field Bros', '${OWNER.uid}');
insert into public.partner_group_members (group_id, user_id, role) values
  ('${G}', '${OWNER.uid}', 'owner'), ('${G}', '${MEMBER.uid}', 'member'), ('${G}', '${ADMIN.uid}', 'admin');
`);

await db.exec(file("partner_group_add.sql"));
await db.exec(file("partner_group_add.sql"));
check(true, "partner_group_add.sql applies, and re-applies over itself");
const kinds = (await q(db, "select pg_get_constraintdef(oid) d from pg_constraint where conname = 'partner_notifications_kind_check'"))[0].d;
check(/tenant_liked/.test(kinds) && /visit_assigned/.test(kinds) && !/btextb,|,textb|bkindb,/.test(kinds.split("ANY")[1] || "") && /group_added/.test(kinds) && /group_joined/.test(kinds), "notification kinds kept, two added", kinds);

console.log("\na member adds an approved partner by number");
let r = await as(db, MEMBER, `select public.partner_add_member_by_phone('${G}', '+91 80000 00004')`);
check(!r.error && one(r)?.status === "added" && one(r)?.name === "Kiran", "Ravi (a plain member) adds Kiran by his second number — in straight away", r.error?.message ?? JSON.stringify(one(r)));
check((await q(db, `select role from public.partner_group_members where group_id = '${G}' and user_id = '${NEWBIE.uid}'`))[0]?.role === "member", "Kiran is a member");
const notes = await q(db, "select broker_id, kind, title, body from public.partner_notifications where title <> 'old row' order by id");
check(notes.some((n) => n.broker_id === NEWBIE.uid && n.kind === "group_added" && n.title === "Ravi added you to White Field Bros"), "Kiran is told who added him", JSON.stringify(notes));
check(notes.filter((n) => n.kind === "group_joined").map((n) => n.broker_id).sort().join() === [OWNER.uid, ADMIN.uid].sort().join(),
  "the owner and the admin are told (not Ravi, not Kiran)");
r = await as(db, MEMBER, `select public.partner_add_member_by_phone('${G}', '9000000004')`);
check(one(r)?.status === "already", "adding him again says he's already in");

console.log("\na number that isn't a partner yet");
r = await as(db, MEMBER, `select public.partner_add_member_by_phone('${G}', '9000000005')`);
check(one(r)?.status === "invited" && one(r)?.signed_up === false, "held as invited", JSON.stringify(one(r)));
r = await as(db, MEMBER, `select * from public.partner_group_pending_list('${G}')`);
check(r.rows?.length === 1 && r.rows[0].mine === true, "Ravi sees the number he invited");
r = await as(db, OWNER, `select * from public.partner_group_pending_list('${G}')`);
check(r.rows?.length === 1, "the owner sees it too");
await db.exec(`insert into public.partner_group_members (group_id, user_id) values ('${G}', '${OUTSIDER.uid}')`);
r = await as(db, OUTSIDER, `select * from public.partner_group_pending_list('${G}')`);
check(r.rows?.length === 0, "another plain member doesn't");
r = await as(db, OUTSIDER, `select public.partner_cancel_pending((select id from public.partner_group_pending limit 1))`);
check(Boolean(r.error), "…and can't cancel it");
await db.exec(`delete from public.partner_group_members where user_id = '${OUTSIDER.uid}'`);
await db.exec(`insert into public.broker_partners (user_id, name, phone, status) values ('${LATER.uid}', 'Later', '9000000005', 'pending')`);
check((await q(db, `select count(*)::int n from public.partner_group_members where user_id = '${LATER.uid}'`))[0].n === 0, "signing up while pending doesn't join yet");
r = await as(db, MEMBER, `select public.partner_add_member_by_phone('${G}', '9000000005')`);
check(one(r)?.status === "invited" && one(r)?.signed_up === true, "a pending partner's number is held too (signed up, not approved)");
await db.exec(`update public.broker_partners set status = 'approved' where user_id = '${LATER.uid}'`);
check((await q(db, `select count(*)::int n from public.partner_group_members where user_id = '${LATER.uid}' and group_id = '${G}'`))[0].n === 1, "approval → joins the group on its own");
check((await q(db, "select count(*)::int n from public.partner_group_pending"))[0].n === 0, "…and the held spot is used up");
check((await q(db, `select title from public.partner_notifications where broker_id = '${LATER.uid}'`))[0]?.title === "Ravi added you to White Field Bros", "…and is told who added them");
await db.exec(`update public.partner_group_pending set expires_at = now() where false`);
r = await as(db, MEMBER, `select public.partner_add_member_by_phone('${G}', '7000000099')`);
await db.exec("update public.partner_group_pending set expires_at = now() - interval '1 minute'");
await db.exec(`insert into public.broker_partners (user_id, name, phone, status) values ('${id(8)}', 'Late', '7000000099', 'approved')`);
check((await q(db, `select count(*)::int n from public.partner_group_members where user_id = '${id(8)}'`))[0].n === 0, "a spot older than 30 days doesn't join anyone");

console.log("\nwho can't");
r = await as(db, OUTSIDER, `select public.partner_add_member_by_phone('${G}', '9000000002')`);
check(r.error && /Only members/.test(r.error.message), "a partner outside the group can't add to it", r.error?.message);
r = await as(db, MEMBER, `select public.partner_add_member_by_phone('${G}', '12345')`);
check(r.error && /valid 10-digit/.test(r.error.message), "a bad number is refused", r.error?.message);
r = await as(db, MEMBER, `select public.partner_add_member_by_phone('${G}', '9000000006')`);
check(r.error && /can't be added/.test(r.error.message), "a suspended partner can't be added", r.error?.message);
r = await as(db, MEMBER, "select public.crm_partner_groups()");
check(r.rows?.length === 0, "partners see no CRM union list");
r = await as(db, MEMBER, `select public.crm_group_add_member('${G}', '9000000007')`);
check(Boolean(r.error), "…and can't use the CRM's add");
r = await as(db, { role: "anon" }, `select public.partner_add_member_by_phone('${G}', '9000000007')`);
check(Boolean(r.error), "signed out: refused");
r = await as(db, MEMBER, `select public.partner_group_join('${G}', '${OUTSIDER.uid}', null, 'x')`);
check(Boolean(r.error), "the internal join can't be called directly");

console.log("\nthe CRM (Brokers → Unions)");
r = await as(db, STAFF, "select * from public.crm_partner_groups()");
const g = r.rows?.[0];
check(g?.name === "White Field Bros" && g.member_count === 5 && g.admins.length === 2 && g.admins[0].role === "owner" && g.admins[0].name === "Sanjith",
  "lists the group with its owner and admin", JSON.stringify(g));
r = await as(db, STAFF, `select public.crm_group_add_member('${G}', '9000000007')`);
check(one(r)?.status === "added", "adds a partner by number");
check((await q(db, `select title, body from public.partner_notifications where broker_id = '${OUTSIDER.uid}'`))[0]?.title === "MovEazy added you to White Field Bros", "…who is told MovEazy added them");
r = await as(db, STAFF, `select public.crm_group_set_role('${G}', '${OWNER.uid}', 'member')`);
check(r.error && /someone else the owner/.test(r.error.message), "the owner can't be demoted directly");
r = await as(db, STAFF, `select public.crm_group_remove_member('${G}', '${OWNER.uid}')`);
check(r.error && /someone else the owner/.test(r.error.message), "…nor removed");
r = await as(db, STAFF, `select public.crm_group_set_role('${G}', '${MEMBER.uid}', 'owner')`);
const roles = Object.fromEntries((await q(db, `select user_id, role from public.partner_group_members where group_id = '${G}'`)).map((x) => [x.user_id, x.role]));
check(!r.error && roles[MEMBER.uid] === "owner" && roles[OWNER.uid] === "admin", "handing over the group: Ravi owner, Sanjith stays as admin", r.error?.message);
r = await as(db, STAFF, `select public.crm_group_remove_member('${G}', '${OUTSIDER.uid}')`);
check(!r.error && (await q(db, `select count(*)::int n from public.partner_group_members where user_id = '${OUTSIDER.uid}'`))[0].n === 0, "removes a member");
r = await as(db, STAFF, `select public.crm_update_group('${G}', 'Whitefield Brokers', 'ITPL side')`);
check(!r.error && (await q(db, `select name from public.partner_groups where id = '${G}'`))[0].name === "Whitefield Brokers", "renames it");
r = await as(db, STAFF, "select public.crm_create_group('Sarjapur Union', '', '9000000007')");
const ng = one(r);
check(!r.error && (await q(db, `select role from public.partner_group_members where group_id = '${ng}' and user_id = '${OUTSIDER.uid}'`))[0]?.role === "owner",
  "creates a union with the partner on that number as owner", r.error?.message);
r = await as(db, STAFF, "select public.crm_create_group('Nobody', '', '9999999999')");
check(r.error && /approved MovEazy partner/.test(r.error.message), "…the owner must be an approved partner");
r = await as(db, STAFF, `select public.crm_group_add_member('${G}', '6000000001')`);
r = await as(db, STAFF, `select * from public.partner_group_pending_list('${G}')`);
check(r.rows?.length === 1 && r.rows[0].added_by_label === "MovEazy", "the CRM sees invited numbers");
r = await as(db, STAFF, `select public.partner_cancel_pending('${r.rows?.[0]?.id}')`);
check(!r.error && (await q(db, "select count(*)::int n from public.partner_group_pending where expires_at > now()"))[0].n === 0, "…and cancels them");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
