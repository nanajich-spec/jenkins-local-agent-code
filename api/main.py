"""
DevSecOps Security Scan API — Main Application Entry Point

Start with:
    uvicorn api.main:app --host 0.0.0.0 --port 9091 --reload

Or via the helper script:
    python -m api.main
"""
from __future__ import annotations

import logging
import os
from contextlib import asynccontextmanager
from pathlib import Path
from typing import AsyncIterator

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.openapi.utils import get_openapi

from api.config import settings
from api.routers import agent, health, pipeline, reports, scan

# ── Logging ──────────────────────────────────────────────────
logging.basicConfig(
    level=getattr(logging, settings.log_level.upper(), logging.INFO),
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
)
logger = logging.getLogger(__name__)


# ── Startup / shutdown ────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    # Ensure storage directories exist
    for d in (settings.upload_dir, settings.reports_dir, settings.serve_dir):
        Path(d).mkdir(parents=True, exist_ok=True)
    logger.info(
        "DevSecOps Security Scan API v%s starting on %s:%s",
        settings.api_version,
        settings.api_host,
        settings.api_port,
    )
    yield
    logger.info("API shutting down")


# ── Application ───────────────────────────────────────────────
app = FastAPI(
    title="DevSecOps Security Scan API",
    version=settings.api_version,
    description="""
Full end-to-end REST API for the Jenkins-backed DevSecOps security scanning
platform.

## Quick Start

```bash
# Trigger a scan (same as curl -sL http://host:9091/scan | bash)
curl -sL http://host:9091/scan | bash
```

Interactive Swagger UI is available at **/docs**, ReDoc at **/redoc**.
    """,
    lifespan=lifespan,
    docs_url="/docs",
    redoc_url="/redoc",
)

# ── CORS ──────────────────────────────────────────────────────
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],   # tighten in production
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Routers ───────────────────────────────────────────────────
app.include_router(health.router)
app.include_router(scan.router)
app.include_router(agent.router)
app.include_router(pipeline.router)
app.include_router(reports.router)


# ── Backward-compatible aliases ────────────────────────────────
# The client script POSTs to /upload and /cleanup (without /scan prefix).
# These aliases ensure backward compatibility with older client scripts.
from fastapi import Header, Request
from api.models import ScanIdBody, SimpleOkResponse, UploadResponse

@app.post("/upload", response_model=UploadResponse, include_in_schema=False)
async def upload_compat(request: Request, x_scan_id: str = Header(..., alias="X-Scan-ID")) -> UploadResponse:
    return await scan.upload_source(request, x_scan_id)

@app.post("/cleanup", response_model=SimpleOkResponse, include_in_schema=False)
async def cleanup_compat(body: ScanIdBody) -> SimpleOkResponse:
    return await scan.cleanup_scan(body)


# ── Custom OpenAPI (load from openapi.yaml if present) ────────
def _custom_openapi() -> dict:
    if app.openapi_schema:
        return app.openapi_schema
    spec_path = Path(__file__).parent / "openapi.yaml"
    if spec_path.is_file():
        import yaml  # pyyaml
        with open(spec_path) as fh:
            schema = yaml.safe_load(fh)
        app.openapi_schema = schema
        return schema
    # Fall back to auto-generated
    schema = get_openapi(
        title=app.title,
        version=app.version,
        description=app.description,
        routes=app.routes,
    )
    app.openapi_schema = schema
    return schema


app.openapi = _custom_openapi  # type: ignore[method-assign]


# ── Dev entrypoint ────────────────────────────────────────────
if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "api.main:app",
        host=settings.api_host,
        port=settings.api_port,
        reload=True,
        log_level=settings.log_level,
    )
