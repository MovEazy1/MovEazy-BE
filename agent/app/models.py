from __future__ import annotations

from typing import Any

from pydantic import BaseModel, Field


class Preferences(BaseModel):
    areas: list[str] = Field(default_factory=list)
    budgetMin: float | None = None
    budgetMax: float | None = None
    bhk: str = ""
    furnishing: str = ""
    timeline: str = ""
    mustHaves: str = ""


class RecommendRequest(BaseModel):
    preferences: Preferences
    limit: int = Field(default=8, ge=1, le=50)
    minScore: float = Field(default=0.3, ge=0.0, le=1.0)


class RecommendationItem(BaseModel):
    listing: dict[str, Any]
    score: float
    ruleScore: float
    mlScore: float | None = None
    breakdown: dict[str, float]


class RecommendResponse(BaseModel):
    recommendations: list[RecommendationItem]
    catalogSize: int
    modelLoaded: bool


class CatalogStats(BaseModel):
    catalogSize: int
    modelLoaded: bool
    modelTrainedAt: str | None = None
    lastSyncAt: str | None = None
    source: str | None = None
