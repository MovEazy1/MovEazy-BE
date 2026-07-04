#!/usr/bin/env python3
"""Pull published listings from Firestore into the agent catalog and retrain."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from app.catalog import catalog_store  # noqa: E402
from app.train import recommendation_model  # noqa: E402


def fetch_firestore_listings(project_id: str | None = None) -> list[dict]:
    import firebase_admin
    from firebase_admin import credentials, firestore

    if not firebase_admin._apps:
        cred_path = os.getenv("GOOGLE_APPLICATION_CREDENTIALS") or os.getenv("FIREBASE_SERVICE_ACCOUNT")
        if cred_path and Path(cred_path).exists():
            cred = credentials.Certificate(cred_path)
            firebase_admin.initialize_app(cred, {"projectId": project_id} if project_id else None)
        else:
            firebase_admin.initialize_app(options={"projectId": project_id} if project_id else None)

    db = firestore.client()
    snap = db.collection("listings").where("marketStatus", "==", "published").stream()
    rows = []
    for doc in snap:
        data = doc.to_dict() or {}
        data["id"] = doc.id
        rows.append(data)
    return rows


def main() -> None:
    parser = argparse.ArgumentParser(description="Sync Firestore listings into flat-agent catalog")
    parser.add_argument("--project", default=os.getenv("FIREBASE_PROJECT_ID", "moveasy-30eed"))
    parser.add_argument("--skip-train", action="store_true")
    args = parser.parse_args()

    print(f"Fetching published listings from Firestore project {args.project}…")
    rows = fetch_firestore_listings(args.project)
    count = catalog_store.save(rows, source=f"firestore:{args.project}")
    print(f"Saved {count} listings to catalog.")

    if not args.skip_train and count >= 2:
        meta = recommendation_model.train(catalog_store.listings)
        print(f"Trained TF-IDF model on {meta['listingCount']} listings.")
    elif count < 2:
        print("Skipped training — need at least 2 listings.")


if __name__ == "__main__":
    main()
