from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import joblib
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.metrics.pairwise import cosine_similarity

from .catalog import DATA_DIR, catalog_store, listing_search_text
from .recommend import preferences_to_query

MODEL_DIR = DATA_DIR / "model"
VECTORIZER_PATH = MODEL_DIR / "vectorizer.pkl"
MATRIX_PATH = MODEL_DIR / "matrix.pkl"
INDEX_PATH = MODEL_DIR / "index.json"
META_PATH = MODEL_DIR / "meta.json"


class RecommendationModel:
    def __init__(self) -> None:
        self.vectorizer: TfidfVectorizer | None = None
        self.matrix = None
        self.listing_ids: list[str] = []
        self.meta: dict[str, Any] = {}
        self.load()

    @property
    def is_loaded(self) -> bool:
        return self.vectorizer is not None and self.matrix is not None and bool(self.listing_ids)

    def load(self) -> None:
        if not VECTORIZER_PATH.exists() or not MATRIX_PATH.exists() or not INDEX_PATH.exists():
            self.vectorizer = None
            self.matrix = None
            self.listing_ids = []
            return
        self.vectorizer = joblib.load(VECTORIZER_PATH)
        self.matrix = joblib.load(MATRIX_PATH)
        self.listing_ids = json.loads(INDEX_PATH.read_text(encoding="utf-8"))
        if META_PATH.exists():
            self.meta = json.loads(META_PATH.read_text(encoding="utf-8"))

    def train(self, listings: list[dict[str, Any]] | None = None) -> dict[str, Any]:
        rows = listings if listings is not None else catalog_store.listings
        docs = [listing_search_text(row) for row in rows]
        ids = [str(row["id"]) for row in rows]

        if len(docs) < 2:
            raise ValueError("Need at least 2 listings to train the text model.")

        vectorizer = TfidfVectorizer(max_features=5000, ngram_range=(1, 2), stop_words="english")
        matrix = vectorizer.fit_transform(docs)

        MODEL_DIR.mkdir(parents=True, exist_ok=True)
        joblib.dump(vectorizer, VECTORIZER_PATH)
        joblib.dump(matrix, MATRIX_PATH)
        INDEX_PATH.write_text(json.dumps(ids, ensure_ascii=False), encoding="utf-8")

        self.meta = {
            "trainedAt": datetime.now(timezone.utc).isoformat(),
            "listingCount": len(ids),
        }
        META_PATH.write_text(json.dumps(self.meta, ensure_ascii=False, indent=2), encoding="utf-8")

        self.vectorizer = vectorizer
        self.matrix = matrix
        self.listing_ids = ids
        return self.meta

    def score_preferences(self, prefs: dict[str, Any]) -> dict[str, float]:
        if not self.is_loaded or self.vectorizer is None or self.matrix is None:
            return {}

        query = preferences_to_query(prefs)
        if not query.strip():
            return {}

        q_vec = self.vectorizer.transform([query])
        sims = cosine_similarity(q_vec, self.matrix).flatten()

        out: dict[str, float] = {}
        for listing_id, sim in zip(self.listing_ids, sims):
            # cosine is 0–1 for non-negative TF-IDF; clamp for safety
            out[listing_id] = float(max(0.0, min(1.0, sim)))
        return out


recommendation_model = RecommendationModel()
