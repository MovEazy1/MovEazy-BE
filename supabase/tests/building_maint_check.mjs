/** Apply building_flats_maintenance.sql (PGlite, over stubs): each flat carries its maintenance, nothing private, in MovEazy's order. */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

const SQL = readFileSync(new URL("../building_flats_maintenance.sql", import.meta.url), "utf8");
let passed = true;
const check = (ok, why, extra = "") => {
  console.log(`  ${ok ? "ok    " : "FAIL  "} ${why}${ok || !extra ? "" : ` — ${extra}`}`);
  if (!ok) passed = false;
};
const B = "d0000000-0000-0000-0000-000000000001";
const db = new PGlite();
await db.exec(`
create table public.inventory (property_id text primary key, title text, flat_type text, property_type text, bedrooms int, bathrooms int,
  furnishing text, rent numeric, deposit numeric, maintenance numeric, available_from date, area_sqft int, floor_number int, images text[],
  cover_image_url text, amenities text[], description text, unit_no text default '', unit_order int, status text default 'published',
  building_id uuid, full_address text default 'secret', phone text default '9999999999');
create table public.owner_building_bookings (property_id text);
insert into public.inventory (property_id, rent, maintenance, unit_no, unit_order, building_id, status) values
  ('A', 30000, 2000, '504', 2, '${B}', 'published'), ('B', 27000, 2000, '101', 1, '${B}', 'published'),
  ('C', 27000, null, '103', 3, '${B}', 'rented'), ('D', 9, 1, '1', 1, null, 'published');
`);
await db.exec(SQL);
await db.exec(SQL);
check(true, "applies, and re-applies over itself");
const flats = (await db.query(`select public.building_flats('${B}') r`)).rows[0].r;
check(flats.map((f) => f.property_id).join("") === "BAC", "the building's flats, in MovEazy's order", flats.map((f) => f.property_id).join(""));
check(flats[0].maintenance === 2000 && flats[2].maintenance === null, "each with its maintenance");
check(flats.every((f) => !("full_address" in f) && !("phone" in f)), "never an address or a phone");
check(flats[2].available === false && flats[0].available === true, "a rented flat isn't available");
console.log(passed ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
process.exit(passed ? 0 : 1);
