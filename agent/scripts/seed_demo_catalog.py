#!/usr/bin/env python3
"""Seed demo Bangalore listings when Firestore credentials are unavailable."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from app.catalog import catalog_store  # noqa: E402
from app.train import recommendation_model  # noqa: E402

DEMO_LISTINGS = [
    {"id": "demo-hsr-2bhk", "bhk": "2 BHK", "monthlyRent": 35000, "address": "HSR Layout, Bengaluru", "availability": "Immediate", "furnishing": "Semi", "propertyType": "Apartment", "lat": 12.9141, "lng": 77.6411, "description": "Bright 2BHK near HSR BDA complex with parking", "amenities": ["parking", "wifi"]},
    {"id": "demo-kora-2bhk", "bhk": "2 BHK", "monthlyRent": 42000, "address": "Koramangala, Bengaluru", "availability": "Within 15 days", "furnishing": "Full", "propertyType": "Apartment", "lat": 12.9352, "lng": 77.6245, "description": "Fully furnished 2BHK 5th block Koramangala", "amenities": ["gym", "parking"]},
    {"id": "demo-indira-3bhk", "bhk": "3 BHK", "monthlyRent": 65000, "address": "Indiranagar, Bengaluru", "availability": "Immediate", "furnishing": "Semi", "propertyType": "Apartment", "lat": 12.9719, "lng": 77.6412, "description": "Spacious 3BHK CMH Road Indiranagar", "amenities": ["parking"]},
    {"id": "demo-whitefield-1bhk", "bhk": "1 BHK", "monthlyRent": 22000, "address": "Whitefield, Bengaluru", "availability": "Within 30 days", "furnishing": "None", "propertyType": "Apartment", "lat": 12.9698, "lng": 77.75, "description": "Compact 1BHK near ITPL Whitefield", "amenities": []},
    {"id": "demo-bellandur-2bhk", "bhk": "2 BHK", "monthlyRent": 38000, "address": "Bellandur, Bengaluru", "availability": "Immediate", "furnishing": "Semi", "propertyType": "Gated Societies", "lat": 12.93, "lng": 77.6762, "description": "Gated society 2BHK Bellandur outer ring road", "amenities": ["parking", "gym", "pet-friendly"]},
    {"id": "demo-mahadevpura-2bhk", "bhk": "2 BHK", "monthlyRent": 32000, "address": "Mahadevpura, Bengaluru", "availability": "Immediate", "furnishing": "Full", "propertyType": "Apartment", "lat": 12.9516, "lng": 77.68, "description": "Furnished 2BHK Mahadevpura near Bagmane", "amenities": ["wifi"]},
    {"id": "demo-jayanagar-1bhk", "bhk": "1 BHK", "monthlyRent": 18000, "address": "Jayanagar, Bengaluru", "availability": "Flexible", "furnishing": "Semi", "propertyType": "Apartment", "lat": 12.925, "lng": 77.5938, "description": "Quiet 1BHK Jayanagar 4th block", "amenities": ["parking"]},
    {"id": "demo-hebbal-3bhk", "bhk": "3 BHK", "monthlyRent": 55000, "address": "Hebbal, Bengaluru", "availability": "Within 15 days", "furnishing": "Full", "propertyType": "Apartment", "lat": 13.0358, "lng": 77.597, "description": "Lake-facing 3BHK Hebbal", "amenities": ["parking", "gym"]},
    {"id": "demo-marathahalli-rm", "bhk": "Roommate needed", "monthlyRent": 15000, "address": "Marathahalli, Bengaluru", "availability": "Immediate", "furnishing": "Full", "propertyType": "Apartment", "lat": 12.959, "lng": 77.697, "description": "Shared flat Marathahalli for working professionals", "amenities": ["wifi"]},
    {"id": "demo-btm-2bhk", "bhk": "2 BHK", "monthlyRent": 28000, "address": "BTM Layout, Bengaluru", "availability": "Immediate", "furnishing": "None", "propertyType": "Apartment", "lat": 12.916, "lng": 77.610, "description": "Unfurnished 2BHK BTM 2nd stage budget friendly", "amenities": ["parking"]},
]

if __name__ == "__main__":
    count = catalog_store.save(DEMO_LISTINGS, source="demo_seed")
    meta = recommendation_model.train(catalog_store.listings)
    print(f"Seeded {count} demo listings. Trained model on {meta['listingCount']} rows.")
