# Applying `marketing_schema.sql` before a human does

```bash
cd supabase/tests
npm install
npm test
```

Runs the migration against a real Postgres (PGlite, in-process — no server, no
Docker, no Supabase project), so the SQL editor is not where we discover it does
not apply.

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

## The three files

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

## What it does not cover

PGlite is Postgres, but it is not Supabase. `auth.uid()`, `auth.jwt()` and
`auth.users` are stubbed in the prelude, so RLS policies compile but are not
exercised against real JWTs — whether a channel owner can actually be refused
someone else's dashboard is still only verified by signing in and trying it.
