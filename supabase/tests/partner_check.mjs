/**
 * Apply partner_schema.sql to a real Postgres (PGlite, in-process) and check
 * the rules the broker app rests on:
 *
 *   - a group-only listing is seen by current group members and nobody else,
 *     and stops being seen the moment a member is removed;
 *   - MovEazy inventory is locked (no address, no contacts) until premium,
 *     and the program's property share (program_settings) once unlocked;
 *   - program settings: anyone reads them, only partners.manage writes them,
 *     out-of-range values are refused, and a new share is live at once;
 *   - owner / tenant contacts reach only the listing broker and staff;
 *   - invites are single use and expire; auto-approve can be switched off;
 *   - the tables under the functions give a broker nothing directly.
 *
 * Applied over the inventory files in production's order, as inventory_check.mjs
 * does, so the column grants are the real ones.
 */
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

process.on("unhandledRejection", (e) => {
  console.error(`\nFAILED TO APPLY: ${e?.message}${e?.where ? `\n  at ${e.where}` : ""}`);
  process.exit(1);
});

const file = (name) =>
  readFileSync(new URL(`../${name}`, import.meta.url), "utf8")
    .replace(/create extension if not exists "pgcrypto";/g, "");

const A = "aaaaaaaa-0000-0000-0000-000000000001"; // group owner
const B = "bbbbbbbb-0000-0000-0000-000000000002"; // group member
const C = "cccccccc-0000-0000-0000-000000000003"; // partner outside the group
const T = "dddddddd-0000-0000-0000-000000000004"; // tenant, not a partner
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

create function public.is_admin_allowlisted() returns boolean language sql stable
  as $$ select false $$;
create function public.is_super_admin() returns boolean language sql stable
  as $$ select coalesce(current_setting('test.super', true), '') = 'on' $$;
create function public.is_crm_staff() returns boolean language sql stable
  as $$ select coalesce(current_setting('test.staff', true), '') = 'on' $$;
create function public.has_admin_scope(s text) returns boolean language sql stable
  as $$ select public.is_super_admin()
            or s = any(string_to_array(coalesce(current_setting('test.scopes', true), ''), ',')) $$;

create table public.admin_roles (email text primary key, role text, scopes text[] not null default '{}');
insert into public.admin_roles values ('yatharth200018@gmail.com', 'super_admin', '{crm.clients.write}');

create table public.user_profiles (
  id uuid primary key references auth.users(id), email text not null, name text default '', phone text default ''
);
grant select, insert, update on public.user_profiles to authenticated;

create or replace function public.normalize_mobile(raw text) returns text language plpgsql immutable as $$
declare digits text := regexp_replace(coalesce(raw, ''), '\\D', '', 'g'); local text;
begin
  local := case when length(digits) > 10 and left(digits, 2) = '91' then right(digits, 10) else digits end;
  return case when local ~ '^[6-9]\\d{9}$' then local else '' end;
end $$;
`;

const CRM_INVENTORY = `
alter table public.inventory add column if not exists source text default '';
alter table public.inventory add column if not exists source_url text default '';
create policy "crm staff read all inventory" on public.inventory for select
  to authenticated using (public.is_crm_staff());
create policy "crm staff write inventory" on public.inventory for all
  to authenticated using (public.has_admin_scope('crm.properties.write'))
  with check (public.has_admin_scope('crm.properties.write'));
`;

const SEED = `
insert into auth.users (id, email) values
  ('${A}', 'a@broker.in'), ('${B}', 'b@broker.in'), ('${C}', 'c@broker.in'),
  ('${T}', 'tenant@example.com'), ('${S}', 'agent@moveazy.co.in');
insert into public.user_profiles (id, email, name, phone) values
  ('${A}', 'a@broker.in', 'Asha', '9876500001'), ('${B}', 'b@broker.in', 'Bala', '+91 98765 00002'),
  ('${C}', 'c@broker.in', 'Chetan', '9876500003'), ('${T}', 'tenant@example.com', 'Tara', '');
-- MovEazy's own inventory, as the CRM holds it.
insert into public.inventory (property_id, poster_name, phone, area, full_address, latitude, longitude, rent, status, flat_type, partner_visible)
values
  ('MZ-MOVE01', 'CRM', '9000000001', 'HSR Layout', '27th Main, HSR', 12.9, 77.6, 30000, 'published', '2 BHK', true),
  ('MZ-HIDDEN', 'CRM', '9000000002', 'Koramangala', '5th Block', 12.9, 77.6, 40000, 'published', '3 BHK', false),
  ('MZ-PAUSED', 'CRM', '9000000003', 'Bellandur', 'ORR', 12.9, 77.6, 25000, 'paused', '1 BHK', true);
insert into public.inventory_private (property_id, source, poc_name, poc_phone)
values ('MZ-MOVE01', 'owner', 'Prakash Owner', '9000011111');
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
           set_config('test.email', '${who.email ?? ""}', false),
           set_config('test.staff', '${who.staff ? "on" : ""}', false),
           set_config('test.super', '${who.super ? "on" : ""}', false),
           set_config('test.scopes', '${(who.scopes ?? []).join(",")}', false);
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
const denied = (r) => r.error?.code === "42501";
const ids = (r) => (r.rows ?? []).map((x) => x.property_id).sort().join(",");

const anon = { role: "anon" };
const a = { uid: A, email: "a@broker.in" };
const b = { uid: B, email: "b@broker.in" };
const c = { uid: C, email: "c@broker.in" };
const tenant = { uid: T, email: "tenant@example.com" };
const staff = { uid: S, email: "agent@moveazy.co.in", staff: true };
const manager = { ...staff, scopes: ["partners.manage"] };

/* ── Production's order: none of the helper files run yet ─────────────────── */
// The first run on production failed with 42883 — is_inventory_poster() did
// not exist, because inventory_private_read.sql had not been run. The file now
// brings its own helpers when they are missing; this is that database.
console.log("on a database without inventory_private_read / lead_intake / crm_property_internal");
{
  const bare = new PGlite();
  await bare.exec(PRELUDE);
  await bare.exec("drop function public.normalize_mobile(text)");
  await bare.exec(file("inventory_schema.sql"));
  await bare.exec(CRM_INVENTORY);
  await bare.exec(file("inventory_public_columns.sql"));
  await bare.exec(file("program_settings.sql"));
  const applied = await bare.exec(file("partner_schema.sql")).then(() => null, (e) => e);
  check(!applied, "partner_schema.sql applies on its own", applied?.message);
  await bare.exec(file("partner_schema.sql"));
  check(true, "and re-applies");
  await bare.exec(SEED.split("insert into public.inventory_private")[0]);
  const reg = await as(bare, a, "select (public.partner_register('Asha', '')).phone");
  check(reg.rows?.[0]?.phone === "9876500001", "registration normalises the number with the helper it brought", reg.error?.message);
  await as(bare, a, `insert into public.inventory (property_id, posted_by, poster_id, area, rent, status)
                    values ('MZ-MINE01', 'broker', '${A}', 'HSR Layout', 30000, 'published')`);
  const sh = await as(bare, a, "select public.partner_set_sharing('MZ-MINE01', 40, '[]')");
  check(!sh.error, "sharing works", sh.error?.message);
  const own = await as(bare, a, "insert into public.partner_property_contacts (property_id, role, name, phone) values ('MZ-MINE01', 'owner', 'O', '9123456789') returning role");
  check(own.rows?.length === 1, "the lister can save owner contacts (is_inventory_poster policy)", own.error?.message);
  const s1 = await as(bare, staff, "select name, phone from public.partner_property_contacts_for('MZ-MOVE01')");
  check(s1.rows?.[0]?.phone === "9000000001", "without inventory_private, MovEazy contacts fall back to the poster", s1.error?.message);
  // Running the helpers' own files afterwards must still work over what this created.
  await bare.exec(file("inventory_private_read.sql"));
  check(true, "inventory_private_read.sql still runs afterwards");
  await bare.close();
}

const db = new PGlite();
await db.exec(PRELUDE);
await db.exec(file("inventory_schema.sql"));
await db.exec(CRM_INVENTORY);
await db.exec(file("inventory_public_columns.sql"));
await db.exec(file("crm_property_internal.sql"));
await db.exec(file("inventory_private_read.sql"));
await db.exec(file("program_settings.sql"));
await db.exec(file("program_settings.sql"));
check(true, "program_settings.sql applies, and re-applies over itself");
await db.exec(file("partner_schema.sql"));
await db.exec(file("partner_schema.sql"));
check(true, "partner_schema.sql applies, and re-applies over itself");
await db.exec(file("inventory_authenticated_columns.sql"));
check(true, "inventory_authenticated_columns.sql still runs after it (no private column leaked to anon)");
await db.exec(SEED);

console.log("\nsign-up");
check(/mobile number/.test((await as(db, tenant, "select public.partner_register('Tara', '')")).error?.message || ""),
  "no number on the profile: registration refused");
const regA = await as(db, a, "select (public.partner_register('Asha', 'Asha Realty')).status");
check(regA.rows?.[0]?.status === "approved", "auto-approve on: a new partner is approved straight away", regA.error?.message);
const regB = await as(db, b, "select (public.partner_register(null, null)).phone");
check(regB.rows?.[0]?.phone === "9876500002", "the number comes from the profile, normalised", regB.error?.message);
check(denied(await as(db, a, "select public.partner_admin_set_auto_approve(false)")), "a partner cannot flip auto-approve");
check(!(await as(db, manager, "select public.partner_admin_set_auto_approve(false)")).error, "partners.manage can");
const regC = await as(db, c, "select (public.partner_register('Chetan', '')).status");
check(regC.rows?.[0]?.status === "pending", "auto-approve off: the next sign-up waits", regC.error?.message);
check((await as(db, c, "select * from public.partner_inventory()")).rows?.length === 0, "a pending partner sees no inventory");
check((await as(db, tenant, "select * from public.partner_inventory()")).rows?.length === 0, "a tenant sees no inventory");
check(denied(await as(db, anon, "select * from public.partner_inventory()")), "anon cannot call partner_inventory");
await as(db, manager, `select public.partner_admin_set_status('${C}', 'approved')`);
await as(db, manager, "select public.partner_admin_set_auto_approve(true)");
const regC2 = await as(db, c, "select (public.partner_register('Chetan', '')).status");
check(regC2.rows?.[0]?.status === "approved", "approval sticks; re-registering never changes a decision");

console.log("\ngroups and invites");
const g = (await as(db, a, "select public.partner_create_group('HSR Brokers', '') as id")).rows?.[0]?.id;
check(Boolean(g), "an approved partner creates a group");
const tok = (await as(db, a, `select public.partner_create_invite('${g}') as t`)).rows?.[0]?.t;
check(/^[0-9a-f]{32}$/.test(tok || ""), "and invites into it");
check(denied(await as(db, c, `select public.partner_create_invite('${g}')`)), "a non-member cannot mint an invite");
const prev = await as(db, anon, `select public.partner_invite_preview('${tok}') as p`);
check(prev.rows?.[0]?.p?.group_name === "HSR Brokers" && prev.rows[0].p.invited_by === "Asha",
  "anon can preview the invite (the join page, before sign-in)", prev.error?.message);
check(denied(await as(db, anon, "select * from public.partner_group_invites")), "anon cannot read invite tokens");
check(denied(await as(db, b, "select * from public.partner_group_invites")), "nor can a partner");
check((await as(db, b, `select public.partner_accept_invite('${tok}') as g`)).rows?.[0]?.g === g, "B joins with the link");
check(!(await as(db, b, `select public.partner_accept_invite('${tok}')`)).error, "opening it again is harmless");
check(/expired/.test((await as(db, c, `select public.partner_accept_invite('${tok}')`)).error?.message || ""),
  "the link is single use: C cannot reuse it");
const tok2 = (await as(db, b, `select public.partner_create_invite('${g}') as t`)).rows?.[0]?.t;
check(Boolean(tok2), "any member (not only the owner) can invite");
await db.exec(`update public.partner_group_invites set expires_at = now() - interval '1 minute' where token = '${tok2}'`);
check(/expired/.test((await as(db, c, `select public.partner_accept_invite('${tok2}')`)).error?.message || ""), "an expired link is refused");

console.log("\nlistings and sharing");
await as(db, a, `
  insert into public.inventory (property_id, posted_by, poster_id, broker_id, poster_name, phone, area, full_address, rent, status)
  values ('MZ-GROUP1', 'broker', '${A}', '${A}', 'Asha', '9876500001', 'HSR Layout', 'Sector 2', 32000, 'published'),
         ('MZ-PLAT01', 'broker', '${A}', '${A}', 'Asha', '9876500001', 'HSR Layout', 'Sector 3', 35000, 'published'),
         ('MZ-ONLYME', 'broker', '${A}', '${A}', 'Asha', '9876500001', 'HSR Layout', 'Sector 4', 28000, 'published')`);
const sh1 = await as(db, a, `select public.partner_set_sharing('MZ-GROUP1', null, '[{"group_id":"${g}","pct":50}]')`);
check(!sh1.error, "share a listing with one group at 50%", sh1.error?.message);
await as(db, a, "select public.partner_set_sharing('MZ-PLAT01', 30, '[]')");
await as(db, a, "select public.partner_set_sharing('MZ-ONLYME', null, '[]')");
check(denied(await as(db, b, "select public.partner_set_sharing('MZ-PLAT01', 100, '[]')")), "B cannot re-share A's listing");
const g2 = (await as(db, c, "select public.partner_create_group('Whitefield', '') as id")).rows?.[0]?.id;
check(denied(await as(db, a, `select public.partner_set_sharing('MZ-GROUP1', null, '[{"group_id":"${g2}","pct":50}]')`)),
  "A cannot share into a group A is not in");
await as(db, a, `insert into public.partner_property_contacts (property_id, role, name, phone) values ('MZ-GROUP1', 'owner', 'Prakash', '9123456789')`);

console.log("\nwho sees what");
const seenA = await as(db, a, "select * from public.partner_inventory()");
check(ids(seenA) === "MZ-GROUP1,MZ-MOVE01,MZ-ONLYME,MZ-PLAT01", "A: own three + MovEazy (not hidden, not paused)", ids(seenA) || seenA.error?.message);
const seenB = await as(db, b, "select * from public.partner_inventory()");
check(ids(seenB) === "MZ-GROUP1,MZ-MOVE01,MZ-PLAT01", "B (in the group): group + platform + MovEazy, never A's private one", ids(seenB) || seenB.error?.message);
const bGroup = seenB.rows?.find((r) => r.property_id === "MZ-GROUP1");
check(bGroup?.source === "broker" && Number(bGroup.brokerage_pct) === 50 && bGroup.group_ids?.[0] === g && bGroup.lister_name === "Asha",
  "B sees the group listing at the group's 50%, credited to Asha", JSON.stringify(bGroup));
const seenC = await as(db, c, "select * from public.partner_inventory()");
check(ids(seenC) === "MZ-MOVE01,MZ-PLAT01", "C (outside the group): platform + MovEazy only", ids(seenC));
const move = seenC.rows?.find((r) => r.property_id === "MZ-MOVE01");
check(move?.locked === true && move.full_address === "" && move.latitude === null && move.lister_phone === null,
  "MovEazy listing is locked for C: no address, no pin, no phone", JSON.stringify(move));
check((await as(db, c, "select * from public.partner_property_contacts_for('MZ-GROUP1')")).rows?.length === 0,
  "C asking for the group listing's contacts gets nothing");
check((await as(db, c, "select * from public.partner_property_contacts_for('MZ-MOVE01')")).rows?.length === 0,
  "C asking for a locked listing's contacts gets nothing");
const bContacts = await as(db, b, "select role, phone from public.partner_property_contacts_for('MZ-GROUP1')");
check(bContacts.rows?.map((r) => r.role).join() === "broker" && bContacts.rows[0].phone === "9876500001",
  "B sees the listing broker's number, not the owner's", JSON.stringify(bContacts.rows));
const aContacts = await as(db, a, "select role from public.partner_property_contacts_for('MZ-GROUP1')");
check(aContacts.rows?.map((r) => r.role).join() === "broker,owner", "A (the lister) sees the owner too");

console.log("\nthe tables underneath give a broker nothing");
check((await as(db, c, "select * from public.partner_group_shares")).rows?.length === 0, "C reading partner_group_shares: no rows");
check((await as(db, c, "select * from public.partner_group_members")).rows?.length === 0, "C reading partner_group_members: no rows");
check((await as(db, c, "select * from public.partner_property_contacts")).rows?.length === 0, "C reading contacts: no rows");
check((await as(db, b, "select * from public.partner_property_contacts")).rows?.length === 0, "B reading contacts: no rows");
check((await as(db, c, "select * from public.broker_partners")).rows?.length === 1, "a partner reads only their own partner row");
check(denied(await as(db, anon, "select * from public.broker_partners")), "anon: broker_partners refused");
check(denied(await as(db, c, "select partner_share_pct from public.inventory")), "partner_share_pct is not a public column");
check(!(await as(db, anon, "select property_type from public.inventory")).error, "property_type is (it is on the public map)");
check((await as(db, c, "select * from public.partner_group_members_list('" + g + "')")).rows?.length === 0,
  "C cannot list the group's members");

console.log("\npremium");
check(denied(await as(db, b, `select public.partner_admin_grant_tier('${C}', 'moveazy_inventory', 1)`)), "a partner cannot grant premium");
await as(db, manager, `select public.partner_admin_grant_tier('${C}', 'moveazy_inventory', 1)`);
const cPrem = (await as(db, c, "select * from public.partner_inventory() where property_id = 'MZ-MOVE01'")).rows?.[0];
check(cPrem?.locked === false && cPrem.full_address === "27th Main, HSR" && Number(cPrem.brokerage_pct) === 50,
  "with premium: unlocked, address shown, the program's 50% brokerage", JSON.stringify(cPrem));
const cMoveContacts = await as(db, c, "select name, phone from public.partner_property_contacts_for('MZ-MOVE01')");
check(cMoveContacts.rows?.[0]?.phone === "9000011111", "and the owner's number from the CRM", JSON.stringify(cMoveContacts.rows));
const me = (await as(db, c, "select public.partner_me() as m")).rows?.[0]?.m;
check(me?.tiers?.moveazy_inventory?.active === true && me.tiers.moveazy_inventory.price_monthly === 1499, "partner_me reports the plan at the program price");
check(Number(me?.property_share) === 50 && Number(me?.client_share) === 70, "and the program's shares", JSON.stringify(me));
await as(db, manager, `select public.partner_admin_grant_tier('${C}', 'moveazy_inventory', 0)`);
check((await as(db, c, "select locked from public.partner_inventory() where property_id = 'MZ-MOVE01'")).rows?.[0]?.locked === true,
  "revoking premium locks it again");

console.log("\nprogram settings");
const pub = await as(db, anon, "select public.landing_settings() as s");
check(pub.rows?.[0]?.s?.premiumPrice === 1499 && pub.rows[0].s.premiumListPrice === 10000 && Number(pub.rows[0].s.propertyShare) === 50,
  "anon reads the landing settings (1499 / 10000 / 50%)", pub.error?.message);
check(denied(await as(db, anon, "select * from public.program_settings")), "anon cannot read the table itself");
check(denied(await as(db, anon, `select public.admin_set_program_settings('{"premiumPrice": 1}')`)), "anon cannot even call the settings writer");
check(denied(await as(db, c, `select public.admin_set_program_settings('{"premiumPrice": 1}')`)), "a partner cannot change settings");
check(denied(await as(db, staff, `select public.admin_set_program_settings('{"premiumPrice": 1}')`)), "plain staff cannot either");
const bad = await as(db, manager, `select public.admin_set_program_settings('{"propertyShare": 150}')`);
check(bad.error?.code === "22023", "a share over 100% is refused", bad.error?.message);
const typo = await as(db, manager, `select public.admin_set_program_settings('{"premiumPrize": 999}')`);
check(typo.error?.code === "22023", "an unknown key is refused, not ignored", typo.error?.message);
const vid = await as(db, manager, `select public.admin_set_program_settings('{"videoOwner": "javascript:alert(1)"}')`);
check(vid.error?.code === "22023", "a video link must be https", vid.error?.message);
const set = await as(db, manager, `select public.admin_set_program_settings('{"propertyShare": 60, "premiumPrice": 1999, "statBrokers": "25+"}') as s`);
check(Number(set.rows?.[0]?.s?.propertyShare) === 60 && set.rows[0].s.statBrokers === "25+" && set.rows[0].s.premiumListPrice === 10000,
  "partners.manage updates a subset; the rest is kept", set.error?.message);
await as(db, manager, `select public.partner_admin_grant_tier('${C}', 'moveazy_inventory', 1)`);
const at60 = (await as(db, c, "select brokerage_pct from public.partner_inventory() where property_id = 'MZ-MOVE01'")).rows?.[0];
check(Number(at60?.brokerage_pct) === 60, "the new share is live on MovEazy listings at once", JSON.stringify(at60));
const tier = (await as(db, c, "select public.partner_me() as m")).rows?.[0]?.m?.tiers?.moveazy_inventory;
check(tier?.price_monthly === 1999, "and the plan row follows the new price", JSON.stringify(tier));
await as(db, manager, `select public.partner_admin_grant_tier('${C}', 'moveazy_inventory', 0)`);
check(denied(await as(db, staff, `select public.partner_admin_set_client_share('${C}', 80)`)), "plain staff cannot set a broker's client share");
check((await as(db, manager, `select public.partner_admin_set_client_share('${C}', 101)`)).error?.code === "22023", "a client share over 100% is refused");
await as(db, manager, `select public.partner_admin_set_client_share('${C}', 80)`);
check(Number((await as(db, c, "select public.partner_me() as m")).rows?.[0]?.m?.client_share) === 80, "a broker's own client share overrides the default");
check(Number((await as(db, manager, `select client_share_pct from public.partner_admin_list() where user_id = '${C}'`)).rows?.[0]?.client_share_pct) === 80,
  "and shows in the CRM list");
await as(db, manager, `select public.partner_admin_set_client_share('${C}', null)`);
check(Number((await as(db, c, "select public.partner_me() as m")).rows?.[0]?.m?.client_share) === 70, "clearing it goes back to the default");
await as(db, manager, `select public.admin_set_program_settings('{"propertyShare": 50, "premiumPrice": 1499, "statBrokers": "20+"}')`);

console.log("\nleaving a group");
check(denied(await as(db, b, `select public.partner_remove_member('${g}', '${A}')`)), "nobody removes the owner");
await as(db, a, `select public.partner_remove_member('${g}', '${B}')`);
const afterB = await as(db, b, "select * from public.partner_inventory()");
check(ids(afterB) === "MZ-MOVE01,MZ-PLAT01", "removed from the group, B loses its listing on the next read", ids(afterB));
check((await as(db, b, "select * from public.partner_property_contacts_for('MZ-GROUP1')")).rows?.length === 0, "and its contacts");

console.log("\nstaff and suspension");
const seenS = await as(db, staff, "select property_id, locked from public.partner_inventory()");
check(ids(seenS) === "MZ-GROUP1,MZ-HIDDEN,MZ-MOVE01,MZ-ONLYME,MZ-PLAT01" && seenS.rows.every((r) => !r.locked),
  "CRM staff see everything, unlocked (paused MovEazy stock stays out)", ids(seenS));
const sContacts = await as(db, staff, "select role from public.partner_property_contacts_for('MZ-GROUP1')");
check(sContacts.rows?.map((r) => r.role).join() === "broker,owner", "staff see owner contacts on partner listings");
const list = await as(db, staff, "select name, listing_count from public.partner_admin_list() order by name");
check(list.rows?.find((r) => r.name === "Asha")?.listing_count === 3, "the CRM list counts each partner's listings", list.error?.message);
check(denied(await as(db, staff, `select public.partner_admin_set_status('${C}', 'suspended')`)), "plain staff cannot suspend (needs partners.manage)");
await as(db, manager, `select public.partner_admin_set_status('${C}', 'suspended')`);
check((await as(db, c, "select * from public.partner_inventory()")).rows?.length === 0, "a suspended partner sees nothing");

console.log("\nleads");
await db.exec(`update public.broker_partners set status = 'approved' where user_id = '${B}'`);
const lead = await as(db, b, "insert into public.partner_leads (name, phone) values ('Rahul', '9876543210') returning id");
check(lead.rows?.length === 1, "a partner adds a lead with only name and mobile", lead.error?.message);
check((await as(db, a, "select * from public.partner_leads")).rows?.length === 0, "another partner cannot see it");
check(/row-level security/.test((await as(db, tenant, "insert into public.partner_leads (name) values ('x')")).error?.message || ""),
  "a non-partner cannot add leads");

await db.close();
console.log(`\n${passed ? "ALL CHECKS PASS" : "SOMETHING FAILED"}`);
process.exit(passed ? 0 : 1);
