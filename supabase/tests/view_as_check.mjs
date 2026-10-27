/**
 * Apply view_as.sql (PGlite, in-process) and check "view as a user":
 *
 *   - with no view-as header, writes are untouched;
 *   - view-only: inserts, updates and deletes are dropped, the response is
 *     marked 203, activity counters are never written;
 *   - actions allowed: writes go through and are recorded; a wrong key, an
 *     ended session or another account's session can't write;
 *   - revert puts every row back (inserted rows go, updated rows return,
 *     deleted rows come back — identity and generated columns too), and
 *     skips a row someone else changed since;
 *   - search, history, keep and revert are the super admin's only;
 *   - tables created later are protected too.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});

const file = (name) => readFileSync(new URL(`../${name}`, import.meta.url), "utf8");
const ownerCheck = readFileSync(new URL("./owner_check.mjs", import.meta.url), "utf8");
const PRELUDE = ownerCheck.split("const PRELUDE = `")[1].split("`;")[0];

const ADMIN = "a0000000-0000-0000-0000-000000000001";
const RAVI = "b0000000-0000-0000-0000-000000000002";
const OM = "c0000000-0000-0000-0000-000000000003";
const S1 = "d0000000-0000-0000-0000-000000000004";
const S2 = "e0000000-0000-0000-0000-000000000005";
const KEY = "secret-key-1";
const sha = (s) => createHash("sha256").update(s).digest("hex");

let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};

const db = new PGlite();
async function as(who, sql, { session } = {}) {
  await db.exec(`
    reset role;
    select set_config('test.uid', '${who.uid ?? ""}', false),
           set_config('test.email', '${who.email ?? ""}', false),
           set_config('test.super', '${who.super ? "on" : ""}', false),
           set_config('request.headers', '${session ? JSON.stringify({ "x-mz-view-as": session }) : ""}', false),
           set_config('response.status', '', false);
    set role ${who.role ?? "authenticated"};
  `);
  try {
    const res = await db.query(sql);
    return { rows: res.rows, error: null };
  } catch (e) {
    return { rows: null, error: e };
  } finally {
    await db.exec("reset role; select set_config('request.headers', '', false);");
  }
}
const one = (r) => (r.rows?.[0] ? Object.values(r.rows[0])[0] : undefined);
const denied = (r) => r.error?.code === "42501" || /permission denied|Not allowed/.test(r.error?.message || "");
const q1 = async (sql) => Object.values((await db.query(sql)).rows[0] ?? {})[0];

const admin = { uid: ADMIN, email: "yatharth200018@gmail.com", super: true };
const ravi = { uid: RAVI, email: "ravi@example.com" };
const om = { uid: OM, email: "om@example.com" };
const anon = { role: "anon" };

await db.exec(PRELUDE);
await db.exec(`
alter table auth.users add column last_sign_in_at timestamptz;
create table public.owner_accounts (user_id uuid primary key, name text default '', phone text default '');
create table public.broker_partners (user_id uuid primary key, name text default '', phone text default '');
create table public.society_members (id uuid primary key default gen_random_uuid(), user_id uuid, status text default 'active');
create table public.user_sessions (id uuid primary key default gen_random_uuid(), user_id uuid, started_at timestamptz default now());
create table public.app_events (id bigserial primary key, user_id uuid, what text);
create table public.flats (id text primary key, owner uuid, rent int, title text default '', updated_at timestamptz default now());
create table public.flat_photos (id uuid primary key default gen_random_uuid(), flat_id text references public.flats(id) on delete cascade, url text);
create table public.ledger (n int generated always as identity primary key, note text);
create table public.sized (id int primary key, w int, h int, area int generated always as (w * h) stored);
grant all on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;

insert into auth.users (id, email, last_sign_in_at) values
  ('${ADMIN}', 'yatharth200018@gmail.com', now()), ('${RAVI}', 'ravi@example.com', '2026-01-01T10:00:00Z'), ('${OM}', 'om@example.com', null);
insert into public.user_profiles (id, email, name, phone) values
  ('${RAVI}', 'ravi@example.com', 'Ravi Kumar', '9876511111'), ('${OM}', 'om@example.com', 'Om Das', '9876522222');
insert into public.owner_accounts (user_id, name) values ('${RAVI}', 'Ravi Kumar');
insert into public.broker_partners (user_id, name) values ('${OM}', 'Om Das');
insert into public.flats (id, owner, rent, title) values ('F1', '${RAVI}', 20000, 'Sunny 1BHK'), ('F3', '${RAVI}', 30000, 'Big 3BHK');
insert into public.ledger (note) values ('first');
insert into public.sized (id, w, h) values (1, 2, 3);
`);
await db.exec(file("view_as.sql"));
await db.exec(file("view_as.sql"));
check(true, "view_as.sql applies, and re-applies over itself");
const trig = Number(await q1("select count(*) from pg_trigger where tgname = 'zz_view_as_guard'"));
check(trig >= 10, "every table in public is protected", String(trig));
check(Number(await q1("select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid where c.relname like 'view_as_%' and t.tgname like 'zz_view_as%'")) === 0,
  "but not the view-as tables themselves");

await db.exec(`
insert into public.view_as_sessions (id, admin_id, admin_email, target_id, target_email, key_hash, prior_sign_in)
values ('${S1}', '${ADMIN}', 'yatharth200018@gmail.com', '${RAVI}', 'ravi@example.com', '${sha(KEY)}', '2026-01-01T10:00:00Z');
`);

console.log("\nno header");
await as(ravi, "insert into public.flats (id, owner, rent) values ('F0', '" + RAVI + "', 1)");
check(Number(await q1("select count(*) from public.flats where id = 'F0'")) === 1, "an ordinary request writes as always");
await db.exec("delete from public.flats where id = 'F0'");

console.log("\nview-only");
await as(ravi, "insert into public.flats (id, owner, rent) values ('F2', '" + RAVI + "', 25000)", { session: S1 });
await as(ravi, "update public.flats set rent = 1 where id = 'F1'", { session: S1 });
await as(ravi, "delete from public.flats where id = 'F3'", { session: S1 });
check(await q1("select string_agg(id || ':' || rent, ',' order by id) from public.flats") === "F1:20000,F3:30000",
  "insert, update and delete are all dropped");
await db.exec(`select set_config('request.headers', '${JSON.stringify({ "x-mz-view-as": S1 })}', false), set_config('test.uid', '${RAVI}', false)`);
await db.exec("begin; set local role authenticated; update public.flats set rent = 2 where id = 'F1';");
const status = await q1("select current_setting('response.status', true)");
await db.exec("commit; reset role; select set_config('request.headers', '', false);");
check(status === "203", "and the response says nothing was kept (203)", status);
await as(ravi, "insert into public.app_events (user_id, what) values ('" + RAVI + "', 'open')", { session: S1 });
check(Number(await q1("select count(*) from public.app_events")) === 0, "activity counters aren't written");
const read = await as(ravi, "select count(*) from public.flats", { session: S1 });
check(Number(one(read)) === 2, "reads work as usual");

console.log("\nthe browser's controls");
check(denied(await as(anon, `select public.view_as_control('${S1}', 'wrong', 'act')`)), "a wrong key can't switch modes");
const beg = await as(anon, `select public.view_as_control('${S1}', '${KEY}', 'begin')`);
await db.exec("update auth.users set last_sign_in_at = now() where id = '" + RAVI + "'");
await as(anon, `select public.view_as_control('${S1}', '${KEY}', 'begin')`);
check(!beg.error && (await q1(`select last_sign_in_at::text from auth.users where id = '${RAVI}'`)).startsWith("2026-01-01"),
  "'begin' puts back the user's last sign-in", beg.error?.message);
const act = one(await as(anon, `select public.view_as_control('${S1}', '${KEY}', 'act')`));
check(act?.mode === "act", "the key switches the session to actions allowed", JSON.stringify(act));

console.log("\nactions allowed");
await as(ravi, "insert into public.flats (id, owner, rent, title) values ('F2', '" + RAVI + "', 25000, 'New 2BHK')", { session: S1 });
await as(ravi, "insert into public.flat_photos (flat_id, url) values ('F2', 'x.jpg')", { session: S1 });
await as(ravi, "update public.flats set rent = 21000 where id = 'F1'", { session: S1 });
await as(ravi, "delete from public.flats where id = 'F3'", { session: S1 });
await as(ravi, "delete from public.ledger where note = 'first'", { session: S1 });
await as(ravi, "update public.sized set w = 5 where id = 1", { session: S1 });
await as(ravi, "insert into public.app_events (user_id, what) values ('" + RAVI + "', 'open')", { session: S1 });
check(await q1("select string_agg(id || ':' || rent, ',' order by id) from public.flats") === "F1:21000,F2:25000",
  "writes go through");
check(Number(await q1(`select count(*) from public.view_as_changes where session_id = '${S1}'`)) === 6,
  "and each one is recorded (six rows)", await q1(`select count(*) from public.view_as_changes where session_id = '${S1}'`));
check(Number(await q1("select count(*) from public.app_events")) === 0, "counters still aren't written");
await as(om, "update public.flats set title = 'Om was here' where id = 'F1'", { session: S1 });
check(await q1("select title from public.flats where id = 'F1'") === "Sunny 1BHK", "another account can't use the session");

console.log("\nrevert");
check(denied(await as(ravi, `select public.view_as_revert('${S1}')`)), "the user can't revert");
check(denied(await as(om, `select public.view_as_history()`)), "nor read the history");
// Someone else edits F1 after the admin did.
await db.exec("update public.flats set title = 'Edited by the owner' where id = 'F1'");
const hist = one(await as(admin, "select public.view_as_history()"));
check(hist?.[0]?.changes === 6 && hist[0].pending === 6, "the history lists the session and its six changes", JSON.stringify(hist?.[0]));
const list = one(await as(admin, `select public.view_as_session_changes('${S1}')`));
check(list?.length === 6 && list.some((c) => c.op === "UPDATE" && c.fields?.includes("rent")), "the changes, with what each touched");
const rev = one(await as(admin, `select public.view_as_revert('${S1}')`));
check(rev?.reverted === 5 && rev.skipped?.length === 1 && /changed since/.test(rev.skipped[0].why),
  "five changes put back, one skipped — the row the owner changed since", JSON.stringify(rev));
check(await q1("select string_agg(id || ':' || rent || ':' || title, ',' order by id) from public.flats") === "F1:21000:Edited by the owner,F3:30000:Big 3BHK",
  "the new flat is gone, the deleted one is back; the owner's edit stays");
check(Number(await q1("select count(*) from public.flat_photos")) === 0, "the new flat's photo row is gone too");
check(await q1("select note from public.ledger where n = 1") === "first", "a deleted row with an identity key comes back with its key");
check(await q1("select w || 'x' || h || '=' || area from public.sized where id = 1") === "2x3=6", "an updated row with a generated column comes back");
check(await q1(`select outcome from public.view_as_sessions where id = '${S1}'`) === "partly", "the session says: partly reverted");

console.log("\nended and expired sessions");
await as(anon, `select public.view_as_control('${S1}', '${KEY}', 'end', 'exit')`);
await as(ravi, "update public.flats set rent = 1 where id = 'F1'", { session: S1 });
check(await q1("select rent from public.flats where id = 'F1'") === 21000, "an ended session can't write, even with actions on");
await db.exec(`
insert into public.view_as_sessions (id, target_id, key_hash, mode, last_seen_at)
values ('${S2}', '${RAVI}', '${sha("k2")}', 'act', now() - interval '2 hours');
`);
await as(ravi, "update public.flats set rent = 1 where id = 'F1'", { session: S2 });
check(await q1("select rent from public.flats where id = 'F1'") === 21000, "nor one left idle for hours");
await as(ravi, "update public.flats set rent = 1 where id = 'F1'", { session: "not-a-uuid" });
check(await q1("select rent from public.flats where id = 'F1'") === 21000, "a made-up session id drops the write");
await as(admin, `select public.view_as_keep('${S2}')`);
check(await q1(`select outcome from public.view_as_sessions where id = '${S2}'`) === "kept", "kept on purpose: the history says so");

console.log("\nsearch");
check(denied(await as(ravi, "select public.view_as_search('ravi')")), "only the super admin searches");
const byName = one(await as(admin, "select public.view_as_search('ravi')"));
check(byName?.length === 1 && byName[0].email === "ravi@example.com" && byName[0].roles.join() === "tenant,owner",
  "by name, with what the account is", JSON.stringify(byName));
const byPhone = one(await as(admin, "select public.view_as_search('22222')"));
check(byPhone?.[0]?.email === "om@example.com" && byPhone[0].roles.includes("partner"), "by part of a phone number");
check((one(await as(admin, "select public.view_as_search('yatharth')")) ?? []).length === 0, "never the super admin");

console.log("\nlocked down");
check(!!(await as(anon, "select * from public.view_as_sessions")).error, "nobody reads the sessions directly");
check(!!(await as(ravi, "select * from public.view_as_changes")).error, "nor the changes");
await db.exec("create table public.later_table (id int primary key)");
check(Number(await q1("select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid where c.relname = 'later_table' and t.tgname like 'zz_view_as%'")) === 2,
  "a table created later is protected as it's made");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
