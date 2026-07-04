from __future__ import annotations

import re
from typing import Any

POPULAR_AREAS = [
    "Indiranagar",
    "HSR Layout",
    "Koramangala",
    "Bellandur",
    "Whitefield",
    "Mahadevpura",
    "Jayanagar",
    "Hebbal",
    "Marathahalli",
    "Electronic City",
    "Sarjapur Road",
    "BTM Layout",
]

WEIGHTS = {
    "area": 0.28,
    "budget": 0.28,
    "bhk": 0.18,
    "furnishing": 0.10,
    "timeline": 0.08,
    "mustHaves": 0.08,
}


def locality_from_listing(listing: dict[str, Any]) -> str:
    for key in ("area", "address", "location", "title"):
        val = str(listing.get(key) or "").strip()
        if val:
            return val.split(",")[0].strip()
    return "Bengaluru"


def listing_rent(listing: dict[str, Any]) -> float:
    n = listing.get("monthlyRent") or listing.get("rent") or 0
    try:
        rent = float(n)
        if rent > 0:
            return rent
    except (TypeError, ValueError):
        pass
    text = str(listing.get("price") or "").lower().replace(",", "")
    lakh = re.search(r"(\d+(?:\.\d+)?)\s*lakh", text)
    if lakh:
        return float(lakh.group(1)) * 100_000
    num = re.search(r"(\d+)", text)
    return float(num.group(1)) if num else 0.0


def normalize_bhk_value(raw: Any) -> str:
    t = str(raw or "").upper().replace(" ", "")
    if not t:
        return ""
    if "ROOMMATE" in t or "FLATMATE" in t:
        return "Roommate needed"
    if "1RK" in t:
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


def listing_search_blob(listing: dict[str, Any]) -> str:
    amenities = listing.get("amenities") or []
    if isinstance(amenities, dict):
        amenities = [k for k, v in amenities.items() if v]
    parts = [
        listing.get("title"),
        listing.get("description"),
        listing.get("address"),
        listing.get("location"),
        listing.get("area"),
        listing.get("propertyType"),
        listing.get("furnishing"),
        " ".join(str(a) for a in amenities),
    ]
    return " ".join(str(p) for p in parts if p).lower()


def is_bangalore_listing(listing: dict[str, Any]) -> bool:
    blob = f"{listing.get('address', '')} {listing.get('location', '')}".lower()
    if "bangalore" in blob or "bengaluru" in blob:
        return True
    loc = locality_from_listing(listing).lower()
    if any(loc == a.lower() or a.lower() in loc for a in POPULAR_AREAS):
        return True
    lat = float(listing.get("lat") or 0)
    lng = float(listing.get("lng") or 0)
    return 12.72 <= lat <= 13.22 and 77.38 <= lng <= 77.82


def _area_score(listing: dict[str, Any], areas: list[str]) -> float:
    if not areas or "Flexible" in areas:
        return 0.5
    blob = f"{locality_from_listing(listing)} {listing_search_blob(listing)}".lower()
    hits = [a for a in areas if a.lower() in blob]
    if not hits:
        return 0.0
    return min(1.0, 0.6 + len(hits) * 0.2)


def _budget_score(listing: dict[str, Any], min_rent: float | None, max_rent: float | None) -> float:
    rent = listing_rent(listing)
    if not rent:
        return 0.2
    if min_rent is None and max_rent is None:
        return 0.5
    lo = min_rent or 0
    hi = max_rent or 500_000
    if lo <= rent <= hi:
        return 1.0
    margin = max(5000, hi * 0.15)
    if lo - margin <= rent <= hi + margin:
        return 0.55
    return 0.0


def _bhk_score(listing: dict[str, Any], preferred: str) -> float:
    if not preferred or preferred == "Any":
        return 0.5
    listing_bhk = normalize_bhk_value(listing.get("bhk"))
    if listing_bhk == preferred:
        return 1.0
    if preferred == "3+ BHK" and "3" in listing_bhk:
        return 0.85
    return 0.15


def _furnishing_score(listing: dict[str, Any], pref: str) -> float:
    if not pref or pref == "Any":
        return 0.5
    f = str(listing.get("furnishing") or "").lower()
    if pref.lower() in f:
        return 1.0
    if pref == "Semi" and ("semi" in f or "partial" in f):
        return 0.9
    return 0.2


def _timeline_score(listing: dict[str, Any], timeline: str) -> float:
    if not timeline or timeline == "Flexible":
        return 0.5
    avail = str(listing.get("availability") or "Immediate").lower()
    if timeline.lower() in avail:
        return 1.0
    if timeline == "Immediate" and "immediate" in avail:
        return 1.0
    return 0.35


def _must_have_score(listing: dict[str, Any], must_haves: str) -> float:
    text = str(must_haves or "").strip().lower()
    if not text:
        return 0.5
    blob = listing_search_blob(listing)
    tokens = [t.strip() for t in re.split(r"[,;]+|\band\b|\bor\b", text) if len(t.strip()) > 2]
    if not tokens:
        return 0.5
    hits = sum(1 for tok in tokens if tok in blob)
    return hits / len(tokens)


def score_listing(listing: dict[str, Any], prefs: dict[str, Any]) -> tuple[float, dict[str, float]]:
    breakdown = {
        "area": _area_score(listing, prefs.get("areas") or []),
        "budget": _budget_score(listing, prefs.get("budgetMin"), prefs.get("budgetMax")),
        "bhk": _bhk_score(listing, prefs.get("bhk") or ""),
        "furnishing": _furnishing_score(listing, prefs.get("furnishing") or ""),
        "timeline": _timeline_score(listing, prefs.get("timeline") or ""),
        "mustHaves": _must_have_score(listing, prefs.get("mustHaves") or ""),
    }
    total = sum(breakdown[k] * WEIGHTS[k] for k in WEIGHTS)
    return total, breakdown


def preferences_to_query(prefs: dict[str, Any]) -> str:
    parts = [
        " ".join(prefs.get("areas") or []),
        prefs.get("bhk") or "",
        prefs.get("furnishing") or "",
        prefs.get("timeline") or "",
        prefs.get("mustHaves") or "",
    ]
    min_r = prefs.get("budgetMin")
    max_r = prefs.get("budgetMax")
    if min_r is not None and max_r is not None:
        parts.append(f"rent {min_r} to {max_r}")
    elif max_r is not None:
        parts.append(f"rent under {max_r}")
    return " ".join(str(p) for p in parts if p).lower()


def recommend_listings(
    listings: list[dict[str, Any]],
    prefs: dict[str, Any],
    *,
    limit: int = 8,
    min_score: float = 0.3,
    ml_scores: dict[str, float] | None = None,
    ml_weight: float = 0.25,
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for listing in listings:
        if not is_bangalore_listing(listing):
            continue
        rule_score, breakdown = score_listing(listing, prefs)
        ml_score = (ml_scores or {}).get(str(listing.get("id")))
        if ml_score is not None:
            final = (1 - ml_weight) * rule_score + ml_weight * ml_score
        else:
            final = rule_score
            ml_score = None

        if final < min_score:
            continue

        rows.append(
            {
                "listing": listing,
                "score": round(final, 4),
                "ruleScore": round(rule_score, 4),
                "mlScore": round(ml_score, 4) if ml_score is not None else None,
                "breakdown": {k: round(v, 4) for k, v in breakdown.items()},
            }
        )

    rows.sort(key=lambda r: r["score"], reverse=True)
    return rows[:limit]
