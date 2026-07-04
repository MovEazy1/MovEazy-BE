#!/usr/bin/env bash
# Start frontend pointed at local Python flat agent.
set -euo pipefail

FE="$(cd "$(dirname "$0")/../../fe" && pwd)"
cd "$FE"

if ! grep -q '^VITE_FLAT_AGENT_API_URL=' .env .env.local 2>/dev/null; then
  echo "VITE_FLAT_AGENT_API_URL=http://127.0.0.1:8080" >> .env.local
  echo "→ Added VITE_FLAT_AGENT_API_URL to fe/.env.local"
fi

echo "→ Frontend: http://localhost:5173/flat-agent"
exec npm run dev
