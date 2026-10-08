# Applying the migrations before a human does

```bash
cd supabase/tests
npm install
npm test
```

Runs `marketing_schema.sql`, `ops_dashboard.sql` and `crm_curated_shares.sql`
against a real Postgres (PGlite, in-process — no server, no Docker, no
Supabase project), so the SQL editor is not where we discover they do not apply.

## Why this exists

`marketing_schema.sql` shipped four times and failed four times, each on a
different way production had drifted from the schemas in this directory:

| | |
|---|---|
| `42601` | the wrong file pasted entirely — unterminated `/*` |
| `42P01` | no `user_actions` table at all |
| `42703` | `saved_properties` without the `customer_id` its schema defines |
| `42804` | `saved_properties.property_id` is `uuid`; `listing_reactions.property_id` is `text` |

Every one was a shape nobody thought to test, which is the argument against
choosing the shapes by hand.

A fifth failure came later and differently: the file applied fine to an empty
database and failed on production, because `create or replace` cannot change a
function's RETURNS TABLE shape. The SQL editor runs the script in one
transaction, so adding one column to one function rolled the whole migration
back — quietly undoing an access rule and a column that had nothing to do with
it. The symptom reached us as "this person still cannot open /marketing/rishav",
four steps from the cause. Hence `upgrade.mjs`.

## The files

**`check.mjs`** — five named shapes, each asserting which funnel steps should
fill in: `bare` (only `user_profiles`, production's actual state), `full` (repo
spelling throughout), `drifted` (`saved_properties` as `uid`/`flat_id`/
`saved_at`), `clashing` (production's uuid-vs-text union), and `unusable` (a
table with nothing to go on, which must be skipped rather than fatal).

**`upgrade.mjs`** — applies the file over an empty database, over its own
previous run, and over older functions with deliberately different shapes. A
newer file has to be able to replace an older one, whatever changed; every other
test here starts from nothing and cannot see that.

**`fuzz.mjs`** — generates random schemas instead: which tables exist, which
spelling each column uses, and what type it is. Includes spellings the migration
does *not* know, so "resolves to no usable source" is exercised too — that path
must also not throw.

```bash
node fuzz.mjs 40 1     # 40 rounds, seed 1
```

The PRNG is seeded, so a failing round replays exactly; a failure prints the DDL
that produced it.

This found a real bug on its second seed: `_mkt_closed_reason` was gated on
`closed_reason` existing, but the SQL it generated also named `cc.status` and
`cc.closed_at`. A `crm_clients` with a reason column and no status compiled a
function referencing a column that was not there. No hand-written scenario had
that combination.

**`ops_check.mjs`** — the same idea for `ops_dashboard.sql`, which composes its
six metrics with dynamic SQL depending on which of `crm_clients`, `inventory`
and `visit_bookings` exist. Two shapes (`bare`, `full`), plus the arithmetic:
seeded rows at noon IST on named days, asserted against the day each one should
land on. It also checks the parts that fail silently — that `anon` can execute
none of the dashboard functions and holds no select on `dashboard_access`, that
an ungranted email gets an empty set rather than zeroes, and that the range is
clamped.

It earned its keep on the first run: Supabase's default privileges had handed
`anon` a SELECT on `dashboard_access`, which RLS would have refused but which
was one policy edit away from publishing the roster.

**`curated_check.mjs`** — `crm_curated_shares.sql`, whose three functions are
the only things a signed-out recipient of a WhatsApp link can call. So the
checks are the hostile cases: a token that does not exist, a property that is
not in the batch, an invented reaction, and a swipe arriving after the visit was
already booked — which must not downgrade `visit_scheduled` back to `liked`.
It also pins the order `my_curated_properties()` returns, because that array is
dealt out as a deck and the agent chose the sequence.

**`inventory_check.mjs`** — `inventory_private_read.sql` and
`inventory_authenticated_columns.sql`, applied over the inventory files in
production's order. It first reproduces the leak (a signed-in tenant reading
another poster's phone), then checks every role after the fix: tenant and anon
refused `select=*`, `select=phone,poster_email` and a `poster_id` filter;
`authenticated` holding exactly anon's column list; an owner and staff getting
full rows from `inventory_full()`; owners still able to publish, edit and add
visit slots; and `recommend_inventory` returning no PII. It also pins the two
guards in the revoke file — it will not run before the function exists, or
over a policy that still reads `inventory.poster_id` as the caller, which
would stop owners adding visit slots.

**`partner_check.mjs`** — `partner_schema.sql`, the broker app. The visibility
rules are the product, so the checks are the leaks: a partner outside a group
reading its group-only listing (through `partner_inventory()`, through the
contacts function, and straight off every table underneath), a removed member
still seeing it, a locked MovEazy listing carrying an address or a phone, an
invite link used twice or after expiry, a partner sharing into a group they are
not in, and a pending or suspended partner seeing anything at all. It also
pins auto-approve (on by default, and a decision survives re-registering) and
that manual Premium unlocks and relocks.

## What it does not cover

PGlite is Postgres, but it is not Supabase. `auth.uid()`, `auth.jwt()` and
`auth.users` are stubbed in the prelude, so RLS policies compile but are not
exercised against real JWTs — whether a channel owner can actually be refused
someone else's dashboard is still only verified by signing in and trying it.
