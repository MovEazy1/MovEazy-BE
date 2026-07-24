# MovEazy-BE — Production Push Report

| | |
|---|---|
| **Author** | Yatharth Singh &lt;yatharth200018@gmail.com&gt; |
| **Date** | 2026-07-23 |
| **Repository** | `MovEazy1/MovEazy-BE` |
| **Branch** | `feat/supabase-schema-migration` → PR into `main` |
| **Net change** | **+603 / −0** across 4 SQL files<br/>_(excludes this report file)_ |

---

## What shipped

**Supabase schema consolidated into the backend repo.**

The database schema SQL previously lived in the frontend repo (`MovEazy-FE/supabase/`),
which meant the frontend carried the definition of backend tables. These files are now
in the backend repo as the single source of truth, so the database schema lives with the
backend and the frontend consumes it through the API/client only.

These four files define **14 tables** across the customer, broker, admin and chatbot
domains. Run them in the Supabase **SQL Editor** to provision a fresh project.

---

## Files changed (lines added / deleted)

| File | Added | Deleted | Purpose |
|---|---:|---:|---|
| `supabase/broker_schema.sql` | 251 | 0 | Broker CRM — hunters, properties, follow-ups, tasks, visit schedules, property matches |
| `supabase/customer_schema.sql` | 227 | 0 | `user_profiles` + customer-side search profile tables (required for login/profile creation) |
| `supabase/admin_schema.sql` | 75 | 0 | Admin email allowlist / access control |
| `supabase/chatbot_schema.sql` | 50 | 0 | Chatbot session + message history |

**Totals: +603 / −0** across 4 files — verified via `git diff --numstat origin/main`.
(This report file is excluded from the totals, since counting it changes its own line count.)

---

## Related

Paired with the frontend release in `MovEazy1/MovEazy-FE`
(branch `feat/broker-consultant-and-marketing-pages`), which removed these SQL files
from the frontend repo as part of the same migration.

## Security notes
- No credentials in these files — they are pure DDL (table, index and policy definitions).
- No `.env` files are tracked; only `agent/.env.example` (placeholders) is in version control.
