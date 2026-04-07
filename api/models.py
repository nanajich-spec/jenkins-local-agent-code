"""
DevSecOps Security Scan API — Pydantic Models
All request / response schemas, mirroring openapi.yaml components/schemas.
"""
from __future__ import annotations

from datetime import datetime
from typing import Any, Dict, List, Optional
from pydantic import BaseModel, Field, field_validator
import re

# ── Pattern used across multiple models ─────────────────────
_SCAN_ID_RE = re.compile(r'^[a-zA-Z0-9_\-]{3,80}$')


def _validate_scan_id(v: str) -> str:
    if not _SCAN_ID_RE.match(v):
        raise ValueError(
            "scan_id must be 3-80 chars: letters, digits, hyphens, underscores"
        )
    return v


# ────────────────────────────────────────────────────────────
# GENERIC
# ────────────────────────────────────────────────────────────

class ErrorResponse(BaseModel):
    error: str
    detail: Optional[str] = None


class SimpleOkResponse(BaseModel):
    status: str  # ok | cleaned | cancelled | destroyed


class ScanIdBody(BaseModel):
    scan_id: str
    _validate_id = field_validator("scan_id")(_validate_scan_id)


class ScanIdBodyOptional(BaseModel):
    scan_id: Optional[str] = None


# ────────────────────────────────────────────────────────────
# HEALTH
# ────────────────────────────────────────────────────────────

class HealthResponse(BaseModel):
    status: str = "ok"
    timestamp: datetime
    version: str


class DependencyCheck(BaseModel):
    ok: bool
    latency_ms: Optional[float] = None
    error: Optional[str] = None


class ReadinessResponse(BaseModel):
    ready: bool
    checks: Dict[str, DependencyCheck]


# ────────────────────────────────────────────────────────────
# SCAN
# ────────────────────────────────────────────────────────────

class UploadResponse(BaseModel):
    status: str = "ok"
    scan_id: str
    upload_path: str
    size: int = Field(..., description="File size in bytes")


class ScanStatusResponse(BaseModel):
    scan_id: str
    building: bool
    result: Optional[str] = None          # SUCCESS | FAILURE | ABORTED | UNSTABLE
    build_number: Optional[int] = None
    build_url: Optional[str] = None
    duration_ms: Optional[int] = None
    estimated_duration_ms: Optional[int] = None
    timestamp: Optional[int] = None       # epoch millis


class ReportListResponse(BaseModel):
    scan_id: str
    artifacts: List[str]


class FindingTotals(BaseModel):
    critical: int = 0
    high: int = 0
    medium: int = 0
    low: int = 0
    unknown: int = 0


class ScanSummary(BaseModel):
    scan_id: str
    gate_passed: bool
    totals: FindingTotals
    findings_by_type: Optional[Dict[str, FindingTotals]] = None
    sbom_component_count: Optional[int] = None
    secrets_found: Optional[int] = None
    sonarqube_quality_gate: Optional[str] = None
    pipeline: Optional[str] = None
    build_number: Optional[int] = None


# ────────────────────────────────────────────────────────────
# AGENT
# ────────────────────────────────────────────────────────────

class AgentCreateRequest(BaseModel):
    scan_id: str
    _validate_id = field_validator("scan_id")(_validate_scan_id)


class AgentCreateResponse(BaseModel):
    status: str = "ok"
    agent_name: str
    agent_label: str
    scan_id: str
    output: Optional[str] = None


class AgentDestroyResponse(BaseModel):
    status: str = "destroyed"
    scan_id: str
    output: Optional[str] = None


class AgentStatusResponse(BaseModel):
    status: str = "ok"
    output: Optional[str] = None


class AgentEntry(BaseModel):
    name: str
    scan_id: Optional[str] = None
    online: bool = False
    created_at: Optional[datetime] = None


class AgentListResponse(BaseModel):
    agents: List[AgentEntry]


# ────────────────────────────────────────────────────────────
# PIPELINE
# ────────────────────────────────────────────────────────────

class PipelineTriggerRequest(BaseModel):
    pipeline: str = Field(..., description="Jenkins pipeline job name")
    agent_label: str = Field(..., description="Target agent label")
    scan_id: str
    scan_type: str = Field("code-only", pattern="^(code-only|image-only|full)$")
    source_upload_path: Optional[str] = None
    image_name: Optional[str] = None
    image_tag: Optional[str] = "latest"
    generate_sbom: bool = True
    fail_on_critical: bool = True
    registry_url: Optional[str] = None
    scan_registry_images: bool = False

    _validate_id = field_validator("scan_id")(_validate_scan_id)


class PipelineTriggerResponse(BaseModel):
    status: str = "queued"
    queue_item_url: str
    build_number: Optional[int] = None


class BuildSummary(BaseModel):
    number: int
    result: Optional[str] = None
    building: bool = False
    timestamp: Optional[int] = None
    duration: Optional[int] = None
    url: Optional[str] = None


class BuildDetail(BuildSummary):
    display_name: Optional[str] = None
    description: Optional[str] = None
    parameters: Optional[Dict[str, Any]] = None
    artifacts: Optional[List[Dict[str, str]]] = None


class BuildListResponse(BaseModel):
    pipeline: str
    builds: List[BuildSummary]
