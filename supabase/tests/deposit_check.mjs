/**
 * Apply inventory_auto_deposit.sql (PGlite) and check the automatic deposit:
 * 3.5 × rent to the nearest ₹5,000 when blank, following the rent until a
 * real deposit is typed, back on when cleared, and filled in for old listings.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});
const file = (name) => readFileSync(new URL(`../${name}`, import.meta.url), "utf8");

let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};

const db = new PGlite();
await db.exec(`
create role anon; create role authenticated;
create table public.inventory (property_id text primary key, rent numeric, deposit numeric, title text default '');
insert into public.inventory values ('OLD-BLANK', 27500, null), ('OLD-ZERO', 30000, 0), ('OLD-SET', 30000, 60000), ('OLD-NORENT', 0, null);
`);
await db.exec(file("inventory_auto_deposit.sql"));
await db.exec(file("inventory_auto_deposit.sql"));
check(true, "inventory_auto_deposit.sql applies, and re-applies over itself");
const row = async (id) => (await db.query(`select deposit::int d, deposit_auto a from public.inventory where property_id = '${id}'`)).rows[0];

console.log("\nold listings");
check(JSON.stringify(await row("OLD-BLANK")) === JSON.stringify({ d: 95000, a: true }), "blank: 27,500 × 3.5 = 96,250 → ₹95,000, auto", JSON.stringify(await row("OLD-BLANK")));
check((await row("OLD-ZERO")).d === 105000 && (await row("OLD-ZERO")).a, "zero counts as blank: ₹1,05,000");
check((await row("OLD-SET")).d === 60000 && !(await row("OLD-SET")).a, "a real deposit is left alone");
check((await row("OLD-NORENT")).d === null, "no rent, no deposit to work out");

console.log("\nnew listings");
await db.exec(`insert into public.inventory (property_id, rent) values ('NEW-1', 34000)`);
check((await row("NEW-1")).d === 120000 && (await row("NEW-1")).a, "posted blank: ₹1,20,000 (1,19,000 rounded), auto");
await db.exec(`insert into public.inventory (property_id, rent, deposit) values ('NEW-2', 34000, 100000)`);
check((await row("NEW-2")).d === 100000 && !(await row("NEW-2")).a, "posted with a deposit: kept");

console.log("\nedits");
await db.exec(`update public.inventory set rent = 40000 where property_id = 'NEW-1'`);
check((await row("NEW-1")).d === 140000, "rent changed, deposit still automatic: it follows (₹1,40,000)");
await db.exec(`update public.inventory set rent = 42000, deposit = 140000 where property_id = 'NEW-1'`);
check((await row("NEW-1")).d === 145000 && (await row("NEW-1")).a, "a form re-sending the same automatic figure with a new rent: still follows");
await db.exec(`update public.inventory set title = 'x' where property_id = 'NEW-1'`);
check((await row("NEW-1")).d === 145000, "an edit that isn't rent or deposit leaves it alone");
await db.exec(`update public.inventory set deposit = 150000 where property_id = 'NEW-1'`);
check((await row("NEW-1")).d === 150000 && !(await row("NEW-1")).a, "typing a deposit makes it the poster's");
await db.exec(`update public.inventory set rent = 50000 where property_id = 'NEW-1'`);
check((await row("NEW-1")).d === 150000, "and a later rent change no longer moves it");
await db.exec(`update public.inventory set deposit = null where property_id = 'NEW-1'`);
check((await row("NEW-1")).d === 175000 && (await row("NEW-1")).a, "clearing it brings the automatic one back (₹1,75,000)");
await db.exec(`update public.inventory set deposit = 60000, rent = 31000 where property_id = 'OLD-SET'`);
check((await row("OLD-SET")).d === 60000, "a typed deposit survives its own edit");

console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
