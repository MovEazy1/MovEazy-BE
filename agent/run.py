#!/usr/bin/env python3
"""Start the MovEazy Flat Agent API (FastAPI + uvicorn)."""

from __future__ import annotations

import os

import uvicorn

if __name__ == "__main__":
    host = os.getenv("FLAT_AGENT_HOST", "127.0.0.1")
    port = int(os.getenv("FLAT_AGENT_PORT", "8080"))
    reload = os.getenv("FLAT_AGENT_RELOAD", "1") == "1"
    uvicorn.run("app.main:app", host=host, port=port, reload=reload)
