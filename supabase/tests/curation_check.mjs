/**
 * Apply crm_curation.sql (PGlite) over crm_curated_shares.sql and check:
 * drafts and sent lists, 'passed' joining the shortlist statuses without losing
 * any, and the office distance on a client's requirement.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});
const file = (name) => readFileSync(new URL(`../${name}`, import.meta.url), "utf8");
const curated = readFileSync(new URL("./curated_check.mjs", import.meta.url), "utf8");
const PRELUDE = curated.split("const PRELUDE = `")[1].split("`;")[0];

let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};
const fails = async (sql) => { try { await db.exec(sql); return false; } catch { return true; } };

const db = new PGlite();
await db.exec(PRELUDE);
await db.exec(`
create table public.crm_client_requirements (
  client_id uuid primary key references public.crm_clients(id) on delete cascade,
  localities text[] default '{}', budget_max int
);
insert into public.crm_clients (id, name) values ('22222222-2222-2222-2222-222222222222', 'Asha'), ('33333333-3333-3333-3333-333333333333', 'Ravi');
`);
await db.exec(file("crm_curated_shares.sql"));
await db.exec(`insert into public.crm_curated_shares (client_id, token, property_ids, created_at)
               values ('22222222-2222-2222-2222-222222222222', 'old', '{MZ-1,MZ-2}', '2026-09-01T10:00:00Z')`);
await db.exec(file("crm_curation.sql"));
await db.exec(file("crm_curation.sql"));
check(true, "crm_curation.sql applies over crm_curated_shares.sql, and re-applies over itself");

console.log("\ncurated lists");
const old = (await db.query("select status, sent_at::text s from public.crm_curated_shares where token = 'old'")).rows[0];
check(old.status === "sent" && old.s?.startsWith("2026-09-01"), "a list made before drafts counts as sent, when it was made", JSON.stringify(old));
await db.exec(`insert into public.crm_curated_shares (client_id, token, property_ids, status)
               values ('33333333-3333-3333-3333-333333333333', 'draft1', '{MZ-3}', 'draft')`);
const d = (await db.query("select status, sent_at from public.crm_curated_shares where token = 'draft1'")).rows[0];
check(d.status === "draft" && d.sent_at === null, "a draft has no sent time");
check(await fails("insert into public.crm_curated_shares (client_id, token, status) values ('33333333-3333-3333-3333-333333333333', 'x', 'maybe')"),
  "only draft or sent");

console.log("\npasses");
await db.exec(`insert into public.crm_shortlists (client_id, property_id, status) values ('33333333-3333-3333-3333-333333333333', 'MZ-9', 'liked')`);
await db.exec(`insert into public.crm_client_passes (client_id, property_id, passed_by) values ('33333333-3333-3333-3333-333333333333', 'MZ-9', 'agent@moveazy.co.in')`);
check((await db.query("select count(*)::int n from public.crm_client_passes")).rows[0].n === 1, "a pass is kept per client and flat");
check((await db.query("select status from public.crm_shortlists where property_id = 'MZ-9'")).rows[0].status === "liked",
  "and leaves what the client said about it alone");
check(await fails(`insert into public.crm_client_passes (client_id, property_id) values ('33333333-3333-3333-3333-333333333333', 'MZ-9')`), "once");
await db.exec(`delete from public.crm_clients where id = '33333333-3333-3333-3333-333333333333'`);
check((await db.query("select count(*)::int n from public.crm_client_passes")).rows[0].n === 0, "and goes with the client");
await db.exec(`insert into public.crm_clients (id, name) values ('33333333-3333-3333-3333-333333333333', 'Ravi')`);

console.log("\noffice distance");
await db.exec(`insert into public.crm_client_requirements (client_id) values ('33333333-3333-3333-3333-333333333333')`);
check(Number((await db.query("select office_radius_km r from public.crm_client_requirements")).rows[0].r) === 8, "8 km unless changed");
await db.exec(`update public.crm_client_requirements set office_radius_km = 12.5`);
check(Number((await db.query("select office_radius_km r from public.crm_client_requirements")).rows[0].r) === 12.5, "an agent can change it");
check(await fails("update public.crm_client_requirements set office_radius_km = 0"), "not zero");
check(await fails("update public.crm_client_requirements set office_radius_km = 500"), "not absurd");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
