"""
DevSecOps Security Scan API — Health Router
Liveness (/health) and readiness (/health/ready) probes.
"""
from __future__ import annotations

import asyncio
import time
from datetime import datetime, timezone

import httpx
from fastapi import APIRouter

from api.config import settings
from api.models import DependencyCheck, HealthResponse, ReadinessResponse

router = APIRouter(tags=["health"])


@router.get("/health", response_model=HealthResponse, summary="Liveness probe")
async def health_check() -> HealthResponse:
    return HealthResponse(
        status="ok",
        timestamp=datetime.now(timezone.utc),
        version=settings.api_version,
    )


@router.get(
    "/health/ready",
    response_model=ReadinessResponse,
    summary="Readiness probe",
    responses={503: {"model": ReadinessResponse}},
)
async def readiness_check() -> ReadinessResponse:
    checks: dict[str, DependencyCheck] = {}

    # Check Jenkins
    checks["jenkins"] = await _probe(settings.jenkins_url + "/api/json")
    # Check SonarQube
    checks["sonarqube"] = await _probe(settings.sonarqube_url + "/api/system/status")
    # Check Container Registry
    checks["registry"] = await _probe(f"http://{settings.registry}/v2/")

    ready = all(c.ok for c in checks.values())
    return ReadinessResponse(ready=ready, checks=checks)


async def _probe(url: str, timeout: float = 3.0) -> DependencyCheck:
    t0 = time.monotonic()
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            r = await client.get(url)
        latency = (time.monotonic() - t0) * 1000
        ok = r.status_code < 500
        return DependencyCheck(ok=ok, latency_ms=round(latency, 1))
    except Exception as exc:
        return DependencyCheck(ok=False, error=str(exc))
