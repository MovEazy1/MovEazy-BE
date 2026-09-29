/**
 * Apply tenant_profile_schema.sql to a real Postgres (PGlite, in-process) and
 * check what the tenant profile — and later the owner-facing verification
 * portal — rests on:
 *
 *   - a tenant reads and writes only their own profile; anon nothing;
 *   - CRM staff can read every profile, but not change one;
 *   - the score is the database's: 90 for a complete single profile, 100 for a
 *     complete family, whatever number the browser sends;
 *   - bad values (a non-profile LinkedIn link, an unknown status) are refused.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});

const file = (name) => readFileSync(new URL(`../${name}`, import.meta.url), "utf8");

const R = "aaaaaaaa-0000-0000-0000-000000000001"; // Riya, a tenant
const K = "bbbbbbbb-0000-0000-0000-000000000002"; // Kabir, another tenant
const S = "eeeeeeee-0000-0000-0000-000000000005"; // CRM staff

const PRELUDE = `
create role anon;
create role authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant all on functions to anon, authenticated;

create schema auth;
grant usage on schema auth to anon, authenticated;
create table auth.users (id uuid primary key, email text);
create function auth.uid() returns uuid language sql stable
  as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
create function auth.jwt() returns jsonb language sql stable
  as $$ select jsonb_build_object('email', current_setting('test.email', true)) $$;
create function public.is_crm_staff() returns boolean language sql stable
  as $$ select coalesce(current_setting('test.staff', true), '') = 'on' $$;

create table public.user_profiles (
  id uuid primary key references auth.users(id), email text not null, name text default '', phone text default ''
);
insert into auth.users values ('${R}', 'riya@example.com'), ('${K}', 'kabir@example.com'), ('${S}', 'agent@moveazy.co.in');
insert into public.user_profiles values ('${R}', 'riya@example.com', 'Riya Sharma', '9876543210'),
                                        ('${K}', 'kabir@example.com', 'Kabir', '');
`;

let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};

async function as(db, who, sql) {
  await db.exec(`
    reset role;
    select set_config('test.uid', '${who.uid ?? ""}', false),
           set_config('test.staff', '${who.staff ? "on" : ""}', false);
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
const denied = (r) => r.error?.code === "42501" || /row-level security/.test(r.error?.message || "");

const riya = { uid: R };
const kabir = { uid: K };
const staff = { uid: S, staff: true };
const anon = { role: "anon" };

const db = new PGlite();
await db.exec(PRELUDE);
await db.exec(file("tenant_profile_schema.sql"));
await db.exec(file("tenant_profile_schema.sql"));
check(true, "tenant_profile_schema.sql applies, and re-applies over itself");

console.log("\nwriting and the score");
const full = `linkedin, current_company, past_company, college, graduation_year, in_bangalore_since, marital_status, score`;
const ins = await as(db, riya, `insert into public.tenant_profiles (user_id, current_company, score)
                                values ('${R}', 'Swiggy', 100) returning score`);
check(ins.rows?.[0]?.score === 35, "the database scores it (name 10 + mobile 10 + company 15 = 35), not the 100 sent", JSON.stringify(ins.rows ?? ins.error?.message));
const single = await as(db, riya, `update public.tenant_profiles set linkedin = 'https://www.linkedin.com/in/riya-sharma', past_company = '',
  first_job = true, college = 'BITS Pilani', graduation_year = 2021, in_bangalore_since = '2023', marital_status = 'single' returning ${full}`);
check(single.rows?.[0]?.score === 90, "every field in, single: 90", JSON.stringify(single.rows ?? single.error?.message));
const fam = await as(db, riya, `update public.tenant_profiles set marital_status = 'married' returning score`);
check(fam.rows?.[0]?.score === 100, "every field in, married: 100");
const noLi = await as(db, riya, `update public.tenant_profiles set linkedin = '' returning score`);
check(noLi.rows?.[0]?.score === 80, "no family bonus once anything is missing (LinkedIn removed: 80)", JSON.stringify(noLi.rows));
const k = await as(db, kabir, `insert into public.tenant_profiles (user_id, current_company) values ('${K}', 'Zepto') returning score`);
check(k.rows?.[0]?.score === 25, "no verified mobile on file: those 10 points aren't given (name 10 + company 15)", JSON.stringify(k.rows));

console.log("\nbad values are refused");
check(!!(await as(db, riya, `update public.tenant_profiles set linkedin = 'https://www.linkedin.com/company/swiggy'`)).error, "a LinkedIn company page is not a profile");
check(!(await as(db, riya, `update public.tenant_profiles set linkedin = 'https://www.linkedin.com/in/%E0%A4%B0%E0%A4%BF%E0%A4%AF%E0%A4%BE-sharma'`)).error,
  "an ID in another script, percent-encoded, is fine");
check(!!(await as(db, riya, `update public.tenant_profiles set marital_status = 'complicated'`)).error, "an unknown status");
check(!!(await as(db, riya, `update public.tenant_profiles set graduation_year = 1800`)).error, "a graduation year from 1800");

console.log("\nwho can see what");
check((await as(db, riya, "select user_id from public.tenant_profiles")).rows?.length === 1, "Riya sees only her own profile");
check((await as(db, kabir, `select * from public.tenant_profiles where user_id = '${R}'`)).rows?.length === 0, "Kabir cannot see Riya's");
check((await as(db, kabir, `update public.tenant_profiles set current_company = 'x' where user_id = '${R}' returning 1`)).rows?.length === 0, "nor change it");
check(denied(await as(db, kabir, `insert into public.tenant_profiles (user_id) values ('${R}')`)), "nor create one in her name");
const moved = await as(db, riya, `update public.tenant_profiles set user_id = '${K}' where user_id = '${R}' returning user_id`);
check(!!moved.error || moved.rows?.[0]?.user_id === R, "a profile can't be moved to another user", JSON.stringify(moved.rows ?? moved.error?.message));
check((await as(db, staff, "select user_id from public.tenant_profiles")).rows?.length === 2, "CRM staff read every profile");
check((await as(db, staff, `update public.tenant_profiles set current_company = 'x' returning 1`)).rows?.length === 0, "but change none");
check(denied(await as(db, anon, "select * from public.tenant_profiles")), "anon: refused");
check(!!(await as(db, anon, `select public.tenant_profile_score(null::public.tenant_profiles, 'a', 'b')`)).error, "anon cannot call the scorer");
check((await as(db, riya, `delete from public.tenant_profiles where user_id = '${R}' returning 1`)).rows?.length === 1, "a tenant can delete their own profile");

await db.close();
console.log(`\n${passed ? "ALL CHECKS PASS" : "SOMETHING FAILED"}`);
process.exit(passed ? 0 : 1);
