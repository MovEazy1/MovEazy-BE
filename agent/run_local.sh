#!/usr/bin/env bash
# Run MovEazy Flat Agent against the Supabase `properties` table.
# Requires SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in be/agent/.env.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

if [[ ! -d .venv ]]; then
  python3 -m venv .venv
  .venv/bin/pip install -q -r requirements.txt
fi

echo "→ Syncing Supabase properties table into catalog…"
.venv/bin/python scripts/sync_supabase_properties.py

echo "→ Starting API on http://127.0.0.1:8080"
export FLAT_AGENT_RELOAD=0
exec .venv/bin/python run.py
