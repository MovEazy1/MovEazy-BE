#!/usr/bin/env python3
"""Sync the `public.properties` Supabase table into the flat-agent catalog.

Requires SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY (be/agent/.env) — the
service role key is needed to read every row regardless of the broker-owns-row
RLS policy on `properties`.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any

import httpx
from dotenv import load_dotenv
import os

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

load_dotenv(ROOT / ".env")

from app.catalog import catalog_store, CATALOG_PATH  # noqa: E402
from app.train import recommendation_model  # noqa: E402

PAGE_SIZE = 1000


def _row_to_raw_listing(row: dict[str, Any]) -> dict[str, Any]:
    """Map a `properties` row onto the field names app.catalog.normalize_listing expects."""
    return {
        "id": row.get("id"),
        "title": row.get("title"),
        "description": row.get("description"),
        "area": row.get("area"),
        "address": row.get("full_address") or row.get("area"),
        "monthly_rent": row.get("rent_amount"),
        "bhk": row.get("bhk_type"),
        "furnishing": row.get("furnishing"),
        "lat": row.get("lat"),
        "lng": row.get("lng"),
        "images": row.get("images") or [],
        "amenities": row.get("amenities") or [],
        "market_status": "published" if row.get("status") == "available" else "withdrawn",
        "source": "supabase:properties",
    }


def fetch_all_properties(base_url: str, service_key: str) -> list[dict[str, Any]]:
    headers = {
        "apikey": service_key,
        "Authorization": f"Bearer {service_key}",
    }
    rows: list[dict[str, Any]] = []
    offset = 0
    with httpx.Client(timeout=30) as client:
        while True:
            res = client.get(
                f"{base_url}/rest/v1/properties",
                headers={**headers, "Range": f"{offset}-{offset + PAGE_SIZE - 1}"},
                params={"select": "*", "status": "eq.available"},
            )
            if res.status_code not in (200, 206):
                raise SystemExit(f"Supabase fetch failed ({res.status_code}): {res.text}")
            page = res.json()
            rows.extend(page)
            if len(page) < PAGE_SIZE:
                break
            offset += PAGE_SIZE
    return rows


def main() -> None:
    parser = argparse.ArgumentParser(description="Sync Supabase properties into flat-agent catalog")
    parser.add_argument("--skip-train", action="store_true")
    args = parser.parse_args()

    base_url = os.getenv("SUPABASE_URL", "").strip().rstrip("/")
    service_key = os.getenv("SUPABASE_SERVICE_ROLE_KEY", "").strip()
    if not base_url or not service_key:
        raise SystemExit("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set in be/agent/.env")

    print(f"→ Fetching available properties from {base_url}…")
    rows = fetch_all_properties(base_url, service_key)
    print(f"→ Fetched {len(rows)} rows.")

    raw_listings = [_row_to_raw_listing(r) for r in rows]
    count = catalog_store.save(raw_listings, source="supabase:properties")
    print(f"Saved {count} listings to {CATALOG_PATH}")

    if not args.skip_train and count >= 2:
        meta = recommendation_model.train(catalog_store.listings)
        print(f"Trained TF-IDF model on {meta['listingCount']} listings.")
    elif count < 2:
        print("Skipped training — need at least 2 listings.")


if __name__ == "__main__":
    main()
