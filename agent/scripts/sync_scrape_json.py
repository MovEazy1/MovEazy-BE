#!/usr/bin/env python3
"""Import scraped JSON (Housing.com worker output) into agent catalog and retrain."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from app.catalog import catalog_store  # noqa: E402
from app.train import recommendation_model  # noqa: E402


def load_json_rows(path: Path) -> list[dict]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(raw, list):
        return raw
    if isinstance(raw, dict) and isinstance(raw.get("listings"), list):
        return raw["listings"]
    raise ValueError(f"Expected JSON array or {{ listings: [] }} in {path}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Sync scraped JSON into flat-agent catalog")
    parser.add_argument("json_path", help="Path to scraper output JSON")
    parser.add_argument("--merge", action="store_true", help="Merge with existing catalog instead of replace")
    parser.add_argument("--skip-train", action="store_true")
    args = parser.parse_args()

    path = Path(args.json_path)
    if not path.exists():
        raise SystemExit(f"File not found: {path}")

    incoming = load_json_rows(path)
    if args.merge and catalog_store.listings:
        merged = {row["id"]: row for row in catalog_store.listings}
        for row in incoming:
            rid = str(row.get("id") or row.get("sourceUrl") or row.get("title") or "")
            if rid:
                row = {**row, "id": rid}
            merged[rid or str(len(merged))] = row
        rows = list(merged.values())
    else:
        rows = incoming

    count = catalog_store.save(rows, source=f"scrape_json:{path.name}")
    print(f"Saved {count} listings to catalog.")

    if not args.skip_train and count >= 2:
        meta = recommendation_model.train(catalog_store.listings)
        print(f"Trained TF-IDF model on {meta['listingCount']} listings.")


if __name__ == "__main__":
    main()
