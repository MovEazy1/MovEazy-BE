from __future__ import annotations

import os
from typing import Any

import httpx
from dotenv import load_dotenv
from fastapi import FastAPI, Header, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, EmailStr

from .catalog import catalog_store
from .models import CatalogStats, RecommendRequest, RecommendResponse, RecommendationItem
from .recommend import recommend_listings
from .train import recommendation_model

load_dotenv()

API_KEY = os.getenv("FLAT_AGENT_API_KEY", "").strip()
ML_WEIGHT = float(os.getenv("FLAT_AGENT_ML_WEIGHT", "0.25"))
SUPABASE_URL = os.getenv("SUPABASE_URL", "").strip().rstrip("/")
SUPABASE_SERVICE_KEY = os.getenv("SUPABASE_SERVICE_ROLE_KEY", "").strip()

DEFAULT_ORIGINS = [
    "http://localhost:5173",
    "http://127.0.0.1:5173",
    "http://localhost:5174",
    "http://127.0.0.1:5174",
    "https://moveeazy.in",
    "https://www.moveeazy.in",
    "https://moveasy-30eed.web.app",
]
CORS_ORIGINS = [o.strip() for o in os.getenv("FLAT_AGENT_CORS", "").split(",") if o.strip()] or DEFAULT_ORIGINS

app = FastAPI(title="MovEazy Flat Agent", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=CORS_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


def _require_admin(x_api_key: str | None) -> None:
    if not API_KEY:
        return
    if x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid API key")


def _sb_admin_headers() -> dict[str, str]:
    return {
        "apikey": SUPABASE_SERVICE_KEY,
        "Authorization": f"Bearer {SUPABASE_SERVICE_KEY}",
        "Content-Type": "application/json",
    }


# ── Supabase auth models ──────────────────────────────────────────────────────

class RegisterRequest(BaseModel):
    email: EmailStr
    password: str
    name: str = ""
    role: str = "customer"


class LoginRequest(BaseModel):
    email: EmailStr
    password: str


# ── Auth endpoints ─────────────────────────────────────────────────────────────

@app.post("/auth/register")
async def auth_register(body: RegisterRequest) -> dict[str, Any]:
    """
    Create a new Supabase user via the Admin API (service role).
    Sets email_confirm=true so the user can sign in immediately — no SMTP needed.
    """
    if not SUPABASE_URL or not SUPABASE_SERVICE_KEY:
        raise HTTPException(status_code=503, detail="Supabase is not configured on this server.")

    async with httpx.AsyncClient(timeout=10) as client:
        res = await client.post(
            f"{SUPABASE_URL}/auth/v1/admin/users",
            headers=_sb_admin_headers(),
            json={
                "email": body.email,
                "password": body.password,
                "email_confirm": True,       # bypass email verification
                "user_metadata": {
                    "full_name": body.name,
                    "role": body.role,
                },
            },
        )

    data = res.json()
    if res.status_code not in (200, 201):
        msg = data.get("message") or data.get("msg") or data.get("error") or "Registration failed."
        # Duplicate user — let frontend handle gracefully
        if "already registered" in str(msg).lower() or res.status_code == 422:
            raise HTTPException(status_code=409, detail="Account already exists. Please sign in.")
        raise HTTPException(status_code=res.status_code, detail=msg)

    user = data.get("id") or data.get("user", {}).get("id")
    return {"ok": True, "uid": user, "email": body.email, "role": body.role}


@app.post("/auth/login")
async def auth_login(body: LoginRequest) -> dict[str, Any]:
    """
    Sign in via Supabase password grant (anon key flow — no service role needed).
    Returns the access_token + user object.
    """
    if not SUPABASE_URL or not SUPABASE_SERVICE_KEY:
        raise HTTPException(status_code=503, detail="Supabase is not configured on this server.")

    # Use the anon password grant which is the standard sign-in flow
    anon_key = os.getenv("SUPABASE_ANON_KEY", SUPABASE_SERVICE_KEY).strip()
    async with httpx.AsyncClient(timeout=10) as client:
        res = await client.post(
            f"{SUPABASE_URL}/auth/v1/token?grant_type=password",
            headers={
                "apikey": anon_key,
                "Content-Type": "application/json",
            },
            json={"email": body.email, "password": body.password},
        )

    data = res.json()
    if res.status_code != 200:
        msg = data.get("error_description") or data.get("message") or data.get("error") or "Sign-in failed."
        if "invalid" in str(msg).lower() or res.status_code == 400:
            raise HTTPException(status_code=401, detail="Invalid email or password.")
        raise HTTPException(status_code=res.status_code, detail=msg)

    return {
        "ok": True,
        "access_token": data.get("access_token"),
        "refresh_token": data.get("refresh_token"),
        "expires_in": data.get("expires_in"),
        "user": data.get("user"),
    }


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "service": "moveazy-flat-agent"}


@app.get("/catalog/stats", response_model=CatalogStats)
def catalog_stats() -> CatalogStats:
    stats = catalog_store.stats()
    return CatalogStats(
        catalogSize=stats["catalogSize"],
        modelLoaded=recommendation_model.is_loaded,
        modelTrainedAt=recommendation_model.meta.get("trainedAt"),
        lastSyncAt=stats.get("lastSyncAt"),
        source=stats.get("source"),
    )


@app.post("/recommend", response_model=RecommendResponse)
def recommend(body: RecommendRequest) -> RecommendResponse:
    prefs = body.preferences.model_dump()
    ml_scores = recommendation_model.score_preferences(prefs) if recommendation_model.is_loaded else None

    rows = recommend_listings(
        catalog_store.listings,
        prefs,
        limit=body.limit,
        min_score=body.minScore,
        ml_scores=ml_scores,
        ml_weight=ML_WEIGHT,
    )

    return RecommendResponse(
        recommendations=[RecommendationItem(**row) for row in rows],
        catalogSize=len(catalog_store.listings),
        modelLoaded=recommendation_model.is_loaded,
    )


@app.post("/admin/reload")
def admin_reload(x_api_key: str | None = Header(default=None)) -> dict[str, Any]:
    _require_admin(x_api_key)
    catalog_store.load()
    recommendation_model.load()
    return {"ok": True, **catalog_store.stats(), "modelLoaded": recommendation_model.is_loaded}


@app.post("/admin/train")
def admin_train(x_api_key: str | None = Header(default=None)) -> dict[str, Any]:
    _require_admin(x_api_key)
    meta = recommendation_model.train()
    return {"ok": True, **meta}


@app.post("/admin/catalog/import")
def admin_import_catalog(
    payload: dict[str, Any],
    x_api_key: str | None = Header(default=None),
) -> dict[str, Any]:
    _require_admin(x_api_key)
    rows = payload.get("listings") if isinstance(payload.get("listings"), list) else payload
    if not isinstance(rows, list):
        raise HTTPException(status_code=400, detail="Expected { listings: [...] } or a JSON array")
    count = catalog_store.save(rows, source="api_import")
    recommendation_model.train(catalog_store.listings)
    return {"ok": True, "catalogSize": count, "modelLoaded": recommendation_model.is_loaded}
