from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

AGENT_ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = AGENT_ROOT / "data"
CATALOG_PATH = DATA_DIR / "catalog.json"
META_PATH = DATA_DIR / "catalog_meta.json"


def _parse_rent(value: Any) -> float:
    if value is None:
        return 0.0
    if isinstance(value, (int, float)):
        n = float(value)
        return n if n > 0 else 0.0
    text = str(value).lower().replace(",", "")
    lakh = re.search(r"(\d+(?:\.\d+)?)\s*lakh", text)
    if lakh:
        return float(lakh.group(1)) * 100_000
    num = re.search(r"(\d+(?:\.\d+)?)", text)
    return float(num.group(1)) if num else 0.0


def _normalize_bhk(raw: Any) -> str:
    if isinstance(raw, (int, float)) and raw > 0:
        n = int(raw)
        if n >= 4:
            return "3+ BHK"
        if n == 1:
            return "1 BHK"
        return f"{n} BHK"
    t = str(raw or "").upper().replace(" ", "")
    if not t:
        return ""
    if "ROOMMATE" in t or "FLATMATE" in t:
        return "Roommate needed"
    if "1RK" in t or t == "RK":
        return "1 RK"
    if "1BHK" in t:
        return "1 BHK"
    if "2BHK" in t:
        return "2 BHK"
    if "3+" in t or "4BHK" in t:
        return "3+ BHK"
    if "3BHK" in t:
        return "3 BHK"
    return str(raw or "").strip()


def normalize_listing(raw: dict[str, Any]) -> dict[str, Any] | None:
    if not raw:
        return None

    status = str(raw.get("marketStatus") or raw.get("market_status") or "published").lower()
    if status in ("withdrawn", "archived"):
        return None

    listing_id = str(raw.get("id") or raw.get("_docId") or raw.get("publicListingId") or "").strip()
    if not listing_id:
        return None

    lat = raw.get("lat")
    lng = raw.get("lng")
    coords = raw.get("precise_coordinates") or {}
    if lat is None and coords:
        lat = coords.get("y")
    if lng is None and coords:
        lng = coords.get("x")

    rent = _parse_rent(
        raw.get("monthlyRent")
        or raw.get("monthly_rent")
        or raw.get("rent")
        or raw.get("price")
    )

    images = raw.get("images") or []
    if not isinstance(images, list):
        images = [images] if images else []
    cover = (
        raw.get("image")
        or raw.get("coverImage")
        or raw.get("cover_image_url")
        or (images[0] if images else "")
    )

    address = (
        raw.get("address")
        or raw.get("location")
        or raw.get("area")
        or raw.get("display_title")
        or raw.get("title")
        or "Bengaluru"
    )

    amenities = raw.get("amenities") or []
    if isinstance(amenities, dict):
        amenities = [k for k, v in amenities.items() if v]

    return {
        "id": listing_id,
        "title": str(raw.get("title") or raw.get("display_title") or "").strip(),
        "address": str(address).strip(),
        "area": str(raw.get("area") or "").strip(),
        "location": str(raw.get("location") or raw.get("location_details") or "").strip(),
        "monthlyRent": int(rent) if rent else 0,
        "rent": int(rent) if rent else 0,
        "price": raw.get("price") or (f"₹ {int(rent):,}" if rent else ""),
        "bhk": _normalize_bhk(raw.get("bhk") or raw.get("bedroom_count")),
        "propertyType": str(raw.get("propertyType") or raw.get("property_type") or "Apartment"),
        "furnishing": str(
            raw.get("furnishing")
            or ("Full" if raw.get("is_furnished") else "Semi")
        ),
        "availability": str(raw.get("availability") or "Immediate"),
        "description": str(raw.get("description") or ""),
        "lat": float(lat) if lat is not None else 12.9716,
        "lng": float(lng) if lng is not None else 77.5946,
        "images": [str(x) for x in images if x],
        "image": str(cover or ""),
        "amenities": amenities if isinstance(amenities, list) else [],
        "marketStatus": "published",
        "source": str(raw.get("source") or "catalog"),
        "sourceUrl": str(raw.get("sourceUrl") or raw.get("source_url") or ""),
    }


def listing_search_text(listing: dict[str, Any]) -> str:
    parts = [
        listing.get("title"),
        listing.get("description"),
        listing.get("address"),
        listing.get("area"),
        listing.get("location"),
        listing.get("bhk"),
        listing.get("propertyType"),
        listing.get("furnishing"),
        " ".join(listing.get("amenities") or []),
    ]
    return " ".join(str(p) for p in parts if p).lower()


class CatalogStore:
    def __init__(self) -> None:
        self.listings: list[dict[str, Any]] = []
        self.meta: dict[str, Any] = {}
        self.load()

    def load(self) -> None:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        if CATALOG_PATH.exists():
            raw = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
            rows = raw if isinstance(raw, list) else raw.get("listings", [])
            self.listings = [n for row in rows if (n := normalize_listing(row))]
        else:
            self.listings = []

        if META_PATH.exists():
            self.meta = json.loads(META_PATH.read_text(encoding="utf-8"))
        else:
            self.meta = {}

    def save(self, listings: list[dict[str, Any]], *, source: str) -> int:
        normalized = [n for row in listings if (n := normalize_listing(row))]
        deduped: dict[str, dict[str, Any]] = {}
        for row in normalized:
            deduped[row["id"]] = row

        self.listings = list(deduped.values())
        self.meta = {
            "lastSyncAt": datetime.now(timezone.utc).isoformat(),
            "source": source,
            "count": len(self.listings),
        }

        DATA_DIR.mkdir(parents=True, exist_ok=True)
        CATALOG_PATH.write_text(json.dumps(self.listings, ensure_ascii=False, indent=2), encoding="utf-8")
        META_PATH.write_text(json.dumps(self.meta, ensure_ascii=False, indent=2), encoding="utf-8")
        return len(self.listings)

    def stats(self) -> dict[str, Any]:
        return {
            "catalogSize": len(self.listings),
            "lastSyncAt": self.meta.get("lastSyncAt"),
            "source": self.meta.get("source"),
        }


catalog_store = CatalogStore()
