/**
 * Apply whatsapp_intake.sql (PGlite, over stubs) and check WhatsApp → listings:
 *
 *   - only marked numbers are stored: the CRM list and approved partners
 *     (not a pending one, not a stranger); a message is stored once;
 *   - one sender's messages within 10 minutes are one batch, a later one a new
 *     batch, another sender their own;
 *   - a batch is read once quiet for 4 minutes (sooner when pasted), claimed
 *     once, retried after a failure, given up on after 3;
 *   - what AI read becomes drafts; photos alone join the sender's open draft;
 *     a "hi" leaves nothing; "rented" lists the sender's own live listings;
 *   - publishing a partner's flat makes it their listing and tells them;
 *     marking rented; dismissing; pasting; the marked-number list;
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

const P1 = "b0000000-0000-0000-0000-000000000001";
const PX = "b0000000-0000-0000-0000-000000000009";

const db = new PGlite();
await db.exec(`
create role anon; create role authenticated; create role service_role;
create schema auth;
create table auth.users (id uuid primary key, email text);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
create function auth.jwt() returns jsonb language sql stable as $$ select jsonb_build_object('email', current_setting('test.email', true)) $$;
insert into auth.users values ('${P1}', 'p1@x.in'), ('${PX}', 'px@x.in');
create function public.is_crm_staff() returns boolean language sql stable as $$ select current_setting('test.staff', true) in ('on', 'read') $$;
create function public.has_admin_scope(s text) returns boolean language sql stable as $$ select current_setting('test.staff', true) = 'on' $$;
create function public.normalize_mobile(raw text) returns text language plpgsql immutable as $f$
declare digits text := regexp_replace(coalesce(raw, ''), '\\D', '', 'g'); local text;
begin
  local := case when length(digits) > 10 and left(digits, 2) = '91' then right(digits, 10) else digits end;
  return case when local ~ '^[6-9]\\d{9}$' then local else '' end;
end; $f$;
create table public.broker_partners (user_id uuid primary key, name text default '', phone text default '', agency text default '', status text default 'approved');
insert into public.broker_partners values ('${P1}', 'Kiran Realty', '+91 98111 22233', '', 'approved'), ('${PX}', 'Pending', '9844455566', '', 'pending');
create table public.crm_brokers (id uuid primary key default gen_random_uuid(), name text, phone text default '',
  phone_norm text generated always as (public.normalize_mobile(phone)) stored, last_used_at timestamptz);
insert into public.crm_brokers (name, phone) values ('Ramesh', '9877766655');
create table public.inventory (property_id text primary key, title text default '', area text default '', flat_type text default '',
  rent numeric default 0, full_address text default '', phone text default '', broker_id uuid, posted_by text default 'owner',
  status text default 'published', created_at timestamptz default now(), updated_at timestamptz default now());
create table public.inventory_private (property_id text primary key, poc_phone text default '');
create table public.partner_listings (property_id text primary key, broker_id uuid);
create table public.partner_notifications (id bigint generated always as identity, broker_id uuid, kind text, title text, body text, link text);
insert into public.inventory (property_id, title, area, flat_type, rent, phone) values
  ('MZ-OLD1', '2 BHK in HSR', 'HSR', '2 BHK', 30000, ''), ('MZ-OLD2', '1 BHK in Bellandur', 'Bellandur', '1 BHK', 20000, ''),
  ('MZ-RAM1', '3 BHK Prestige', 'HSR', '3 BHK', 60000, '+91 98777 66655'), ('MZ-OTHR', 'Someone else', 'HSR', '2 BHK', 30000, '');
insert into public.partner_listings values ('MZ-OLD1', '${P1}'), ('MZ-OLD2', '${P1}');
`);
await db.exec(read("whatsapp_intake.sql"));
check(true, "whatsapp_intake.sql applies over the stubs (no pg_cron, no pg_net)");
await db.exec(read("whatsapp_intake.sql"));
check(true, "and applies again");
// Supabase's service role keeps its own grants on every table (the file revokes only public, anon, authenticated).
await db.exec(`grant all on all tables in schema public to service_role; alter role service_role bypassrls`);

const as = async ({ staff = "off", email = "", role = "" } = {}) => {
  await db.exec(`reset role; select set_config('test.staff', '${staff}', false), set_config('test.email', '${email}', false)`);
  if (role) await db.exec(`set role ${role}`);
};
const one = async (sql, params = []) => (await db.query(sql, params)).rows[0];
const all = async (sql, params = []) => (await db.query(sql, params)).rows;
const throws = async (sql, params = []) => { try { await db.query(sql, params); return false; } catch { return true; } };
const intake = (m) => one(`select public.wa_intake_message($1::jsonb) j`, [JSON.stringify(m)]).then((r) => r.j);
const ago = (min) => new Date(Date.now() - min * 60e3).toISOString();
const age = (batch, min) => db.query(`update public.wa_batches set last_message_at = now() - make_interval(mins => $2) where id = $1`, [batch, min]);

// ── Intake ─────────────────────────────────────────────────────────────────
await as({ role: "service_role" });
check(await throws(`select public.crm_wa_inbox()`), "the service role isn't CRM staff");
await as();
await db.query(`insert into public.wa_marked_numbers (phone10, label) values ('9877766655', 'Ramesh broker')`);
await as({ role: "service_role" });

let r = await intake({ id: "w1", from: "919811122233", name: "Kiran", kind: "text", body: "2BHK HSR sector 2, 32k, semi furnished", sent_at: ago(6) });
check(r.stored && r.batch && r.media === false, "a partner's text is stored", JSON.stringify(r));
const kiranBatch = r.batch;
r = await intake({ id: "w2", from: "919811122233", kind: "image", media_id: "m2", mime: "image/jpeg", sent_at: ago(5) });
check(r.stored && r.batch === kiranBatch && r.media === true, "their photo a minute later joins the batch and asks for the file");
check((await intake({ id: "w2", from: "919811122233", kind: "image", media_id: "m2" })).reason === "duplicate", "Meta's retry is stored once");
check((await intake({ id: "w3", from: "919844455566", kind: "text", body: "flat" })).reason === "not marked", "a pending partner isn't read");
check((await intake({ id: "w4", from: "919000000001", kind: "text", body: "flat" })).reason === "not marked", "a stranger isn't read");
check((await one(`select count(*)::int n from public.wa_messages where id in ('w3', 'w4')`)).n === 0, "and nothing of theirs is kept");
r = await intake({ id: "w5", from: "9877766655", kind: "text", body: "3BHK Prestige gone", sent_at: ago(1) });
const ramBatch = r.batch;
check(r.stored && ramBatch !== kiranBatch, "a CRM-listed number is read, in a batch of their own");
check((await one(`select crm_broker_id is not null b, sender_kind k from public.wa_batches where id = $1`, [ramBatch])).b,
  "the sender is matched to the Brokers directory");
await db.query(`select public.wa_set_media('w2', 'https://x/whatsapp/w2.jpg')`);

// ── Reading ────────────────────────────────────────────────────────────────
let claimed = (await one(`select public.wa_claim_ready(4) j`)).j;
check(claimed.length === 1 && claimed[0].id === kiranBatch, "only the batch quiet for 4 minutes is read", JSON.stringify(claimed.map((b) => b.id)));
check(claimed[0].messages.length === 2 && claimed[0].messages[1].media_url === "https://x/whatsapp/w2.jpg" && claimed[0].sender_kind === "partner",
  "with its messages in order and the photo's copy");
check((await one(`select public.wa_claim_ready(4) j`)).j.length === 0, "a claimed batch isn't handed out twice");

r = await intake({ id: "w6", from: "919811122233", kind: "image", media_id: "m6", sent_at: new Date().toISOString() });
check(r.batch !== kiranBatch, "a message after the batch was claimed starts a new one");
const photoBatch = r.batch;

r = (await one(`select public.wa_save_parse($1, $2::jsonb) j`, [kiranBatch, JSON.stringify({ items: [
  { kind: "property", fields: { area: "HSR", flat_type: "2 BHK", rent: 32000 }, images: ["https://x/whatsapp/w2.jpg"], missing: ["Furnishing"] },
  { kind: "other" },
] })])).j;
check(r.ok && r.drafts === 1, "what AI read becomes a draft (chit-chat dropped)", JSON.stringify(r));
const draft = await one(`select * from public.wa_drafts where batch_id = $1`, [kiranBatch]);
check(draft.fields.rent === 32000 && draft.images.length === 1 && draft.missing[0] === "Furnishing" && draft.status === "pending",
  "with its fields, photos and what's missing");

await db.query(`select public.wa_set_media('w6', 'https://x/whatsapp/w6.jpg')`);
await age(photoBatch, 5);
claimed = (await one(`select public.wa_claim_ready(4) j`)).j;
check(claimed.map((b) => b.id).includes(photoBatch), "the photo-only batch is read too");
r = (await one(`select public.wa_save_parse($1, '{"items":[]}'::jsonb) j`, [photoBatch])).j;
check(r.drafts === 0 && r.joined === draft.id, "photos alone join the sender's open draft");
check((await one(`select images from public.wa_drafts where id = $1`, [draft.id])).images.length === 2, "so the draft has both photos");

// A failure is retried, then given up on.
r = (await one(`select public.wa_save_parse($1, '{"error":"overloaded"}'::jsonb) j`, [ramBatch])).j;
check(r.retry === true && (await one(`select state from public.wa_batches where id = $1`, [ramBatch])).state === "queued",
  "a failed read is queued again");
await db.query(`update public.wa_batches set attempts = 3 where id = $1`, [ramBatch]);
await db.query(`select public.wa_save_parse($1, '{"error":"overloaded"}'::jsonb)`, [ramBatch]);
check((await one(`select state, error from public.wa_batches where id = $1`, [ramBatch])).state === "error", "after 3 tries it's an error");
check((await one(`select public.wa_claim_ready(4) j`)).j.length === 0, "and isn't read again by itself");

// ── The CRM ────────────────────────────────────────────────────────────────
await as({ staff: "on", email: "asha@moveazy.in", role: "authenticated" });
await db.query(`select public.crm_wa_retry($1)`, [ramBatch]);
await as({ role: "service_role" });
claimed = (await one(`select public.wa_claim_ready(4) j`)).j;
check(claimed.length === 1 && claimed[0].id === ramBatch, "Retry reads it again");
await db.query(`select public.wa_save_parse($1, $2::jsonb)`, [ramBatch,
  JSON.stringify({ items: [{ kind: "rented", fields: { area: "HSR", flat_type: "3 BHK", building_name: "Prestige" } }] })]);
const rented = await one(`select * from public.wa_drafts where batch_id = $1`, [ramBatch]);
check(rented.kind === "rented" && rented.candidates[0]?.property_id === "MZ-RAM1" && !rented.candidates.some((c) => c.property_id === "MZ-OTHR"),
  "'rented' lists the sender's own live listings, best match first", JSON.stringify(rented.candidates));

await as({ staff: "on", email: "asha@moveazy.in", role: "authenticated" });
let inbox = (await one(`select public.crm_wa_inbox() j`)).j;
check(inbox.pending === 2 && inbox.drafts.length === 2, "the inbox has both drafts waiting", JSON.stringify(inbox.pending));
const kd = inbox.drafts.find((d) => d.id === draft.id);
check(kd.sender_kind === "partner" && kd.partner_id === P1 && kd.text.includes("2BHK HSR") && kd.from10 === "9811122233",
  "each with its sender and the message text");
check((await one(`select public.crm_wa_pending_count() n`)).n === 2, "the rail's count");

check(await throws(`select public.crm_wa_draft_published($1, 'MZ-NOPE')`, [draft.id]), "publishing needs a real listing");
await as();
await db.query(`insert into public.inventory (property_id, title, area) values ('MZ-NEW1', '2 BHK in HSR', 'HSR')`);
await as({ staff: "on", email: "asha@moveazy.in", role: "authenticated" });
r = (await one(`select public.crm_wa_draft_published($1, 'MZ-NEW1') j`, [draft.id])).j;
check(r.partner === true, "published");
await as();
const live = await one(`select i.broker_id, i.posted_by, pl.broker_id pl from public.inventory i left join public.partner_listings pl using (property_id) where property_id = 'MZ-NEW1'`);
check(live.broker_id === P1 && live.posted_by === "broker" && live.pl === P1, "a partner's flat becomes their listing");
check((await one(`select count(*)::int n from public.partner_notifications where broker_id = $1 and kind = 'listing_live'`, [P1])).n === 1,
  "and they hear it's live");
check((await one(`select status, decided_by, property_id from public.wa_drafts where id = $1`, [draft.id])).decided_by === "asha@moveazy.in",
  "who published it is kept");

await as({ staff: "on", email: "asha@moveazy.in", role: "authenticated" });
await db.query(`select public.crm_wa_mark_rented($1, 'MZ-RAM1')`, [rented.id]);
await as();
check((await one(`select status from public.inventory where property_id = 'MZ-RAM1'`)).status === "rented" &&
  (await one(`select status from public.wa_drafts where id = $1`, [rented.id])).status === "rented_marked", "marking it rented");

// Pasting.
await as({ staff: "on", email: "asha@moveazy.in", role: "authenticated" });
const pasted = (await one(`select public.crm_wa_paste('1BHK Koramangala 22k', array['https://x/a.jpg', 'https://x/b.mp4'], '98111 22233') id`)).id;
await as();
const pb = await one(`select * from public.wa_batches where id = $1`, [pasted]);
check(pb.state === "queued" && pb.source === "paste" && pb.sender_kind === "partner" && pb.partner_id === P1,
  "a pasted message is queued, from the partner whose number was given");
check((await all(`select kind from public.wa_messages where batch_id = $1 order by sent_at, created_at`, [pasted])).map((m) => m.kind).join() === "text,image,video",
  "text first, then the photo and the video");
await as({ role: "service_role" });
check((await one(`select public.wa_claim_ready(4) j`)).j.some((b) => b.id === pasted), "and read straight away");
await db.query(`select public.wa_save_parse($1, '{"items":[{"kind":"property","fields":{"area":"Koramangala"}}]}'::jsonb)`, [pasted]);
await as();
const pd = await one(`select id from public.wa_drafts where batch_id = $1`, [pasted]);
await as({ staff: "on", email: "asha@moveazy.in", role: "authenticated" });
await db.query(`select public.crm_wa_draft_dismiss($1)`, [pd.id]);
check((await one(`select public.crm_wa_pending_count() n`)).n === 0, "dismissed; nothing waiting");
check(await throws(`select public.crm_wa_paste('', '{}')`), "an empty paste is refused");

// Marked numbers.
const saved = (await one(`select public.crm_wa_number_save('+91 70000 11111', 'Shyam') j`)).j;
check(saved.phone10 === "7000011111" && saved.label === "Shyam" && saved.added_by === "asha@moveazy.in", "a number is marked, normalised");
check(await throws(`select public.crm_wa_number_save('12345')`), "a bad number is refused");
let nums = (await one(`select public.crm_wa_numbers() j`)).j;
check(nums.marked.length === 2 && nums.partners.length === 1 && nums.partners[0].phone10 === "9811122233",
  "the list, and the partners read automatically (approved only)");
await db.query(`select public.crm_wa_number_remove('7000011111')`);
nums = (await one(`select public.crm_wa_numbers() j`)).j;
check(nums.marked.length === 1, "removing a number");

// ── Who may call what ─────────────────────────────────────────────────────
await as({ staff: "read", email: "viewer@moveazy.in", role: "authenticated" });
check(!(await throws(`select public.crm_wa_inbox()`)), "any CRM staff can see the inbox");
check(await throws(`select public.crm_wa_draft_dismiss($1)`, [pd.id]), "but only listing editors act on it");
check(await throws(`select public.crm_wa_number_save('9000000002')`), "or mark numbers");
await as({ email: "tenant@x.in", role: "authenticated" });
check(await throws(`select public.crm_wa_inbox()`), "a signed-in tenant can't see the inbox");
check((await one(`select public.crm_wa_pending_count() n`)).n === 0, "and their count is 0");
for (const fn of [`wa_intake_message('{}'::jsonb)`, `wa_claim_ready(4)`, `wa_connection_get()`, `wa_save_parse(gen_random_uuid(), '{}'::jsonb)`]) {
  check(await throws(`select public.${fn}`), `${fn.split("(")[0]} is the service role's only`);
}
check(await throws(`select * from public.wa_connection`), "the token table is closed to signed-in users");
await as({ role: "anon" });
check(await throws(`select public.crm_wa_inbox()`) && await throws(`select * from public.wa_messages`), "anon gets nothing");

// Connection save / get (service role).
await as({ role: "service_role" });
await db.query(`select public.wa_connection_save('{"waba_id":"1","phone_number_id":"2","display_phone":"+91 81000 00000","access_token":"t","connected_by":"Y@X.in"}'::jsonb)`);
const conn = (await one(`select public.wa_connection_get() j`)).j;
check(conn.access_token === "t" && conn.connected_by === "y@x.in", "the connection is saved for the webhook");
await as({ staff: "on", email: "asha@moveazy.in", role: "authenticated" });
inbox = (await one(`select public.crm_wa_inbox() j`)).j;
check(inbox.connection.connected === true && !("access_token" in inbox.connection), "the CRM sees it's connected, never the token");

console.log(passed ? "\nALL PASS" : "\nSOME FAILED");
process.exit(passed ? 0 : 1);
