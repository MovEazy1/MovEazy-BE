#!/usr/bin/env python3
"""Load local scraped listings (default: fe/public/listings.json) — no Firebase needed."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = ROOT.parents[1]
DEFAULT_JSON = REPO_ROOT / "fe" / "public" / "listings.json"

sys.path.insert(0, str(ROOT))

from app.catalog import catalog_store, CATALOG_PATH  # noqa: E402
from app.train import recommendation_model  # noqa: E402


def load_json_rows(path: Path) -> list[dict]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(raw, list):
        return raw
    if isinstance(raw, dict) and isinstance(raw.get("listings"), list):
        return raw["listings"]
    raise ValueError(f"Expected JSON array or {{ listings: [] }} in {path}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Sync local listings JSON into flat-agent catalog")
    parser.add_argument(
        "json_path",
        nargs="?",
        default=str(DEFAULT_JSON),
        help=f"Path to listings JSON (default: {DEFAULT_JSON})",
    )
    parser.add_argument("--skip-train", action="store_true")
    args = parser.parse_args()

    path = Path(args.json_path)
    if not path.exists():
        raise SystemExit(f"Local listings file not found: {path}")

    print(f"Loading {path}…")
    rows = load_json_rows(path)
    count = catalog_store.save(rows, source=f"local_json:{path.name}")
    print(f"Saved {count} listings to {CATALOG_PATH}")

    if not args.skip_train and count >= 2:
        meta = recommendation_model.train(catalog_store.listings)
        print(f"Trained TF-IDF model on {meta['listingCount']} listings.")
    elif count < 2:
        print("Skipped training — need at least 2 listings.")


if __name__ == "__main__":
    main()
