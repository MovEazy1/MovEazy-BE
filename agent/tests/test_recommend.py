from app.recommend import recommend_listings, score_listing


SAMPLE = [
    {
        "id": "1",
        "bhk": "2 BHK",
        "monthlyRent": 35000,
        "address": "HSR Layout, Bengaluru",
        "availability": "Immediate",
        "furnishing": "Semi",
        "lat": 12.91,
        "lng": 77.64,
    },
    {
        "id": "2",
        "bhk": "1 BHK",
        "monthlyRent": 18000,
        "address": "Whitefield, Bengaluru",
        "availability": "Within 30 days",
        "furnishing": "Full",
        "lat": 12.99,
        "lng": 77.74,
    },
]


def test_hsr_match_ranks_first():
    prefs = {
        "areas": ["HSR Layout"],
        "budgetMin": 25000,
        "budgetMax": 50000,
        "bhk": "2 BHK",
        "furnishing": "Semi",
        "timeline": "Immediate",
        "mustHaves": "",
    }
    recs = recommend_listings(SAMPLE, prefs, min_score=0.2)
    assert recs[0]["listing"]["id"] == "1"


def test_budget_mismatch_scores_lower():
    good, _ = score_listing(SAMPLE[0], {"budgetMin": 30000, "budgetMax": 40000})
    bad, _ = score_listing(SAMPLE[0], {"budgetMin": 5000, "budgetMax": 10000})
    assert good > bad
