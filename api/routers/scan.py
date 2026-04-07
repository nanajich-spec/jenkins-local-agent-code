"""
DevSecOps Security Scan API — Scan Router
Source-upload, status-polling, log streaming, cleanup.
"""
from __future__ import annotations

import os
import shutil
import time
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, Header, HTTPException, Request, Response

from api.config import settings
from api.models import (
    ReportListResponse,
    ScanIdBody,
    ScanStatusResponse,
    SimpleOkResponse,
    UploadResponse,
)
from api.services import report_parser
from api.services.jenkins import JenkinsClient, JenkinsError, get_jenkins_client

router = APIRouter(prefix="/scan", tags=["scan"])

# Map scan_id → (pipeline, build_number) populated by /pipeline/trigger
# Also maps scan_id-<pipeline> → (pipeline, build_number) for multi-pipeline runs
_SCAN_BUILD_MAP: dict[str, tuple[str, int]] = {}


def register_scan_build(scan_id: str, pipeline: str, build_number: int) -> None:
    """Called by the pipeline router after a successful trigger."""
    _SCAN_BUILD_MAP[scan_id] = (pipeline, build_number)
    # Also strip the pipeline suffix if scan_id ends with -<pipeline>
    for suffix in ("-security-scan-pipeline", "-ci-cd-pipeline", "-devsecops-pipeline"):
        if scan_id.endswith(suffix):
            base_id = scan_id[: -len(suffix)]
            if base_id not in _SCAN_BUILD_MAP:
                _SCAN_BUILD_MAP[base_id] = (pipeline, build_number)
            break


# ── Scan client bootstrap ────────────────────────────────────
@router.get(
    "",
    summary="Download scan client shell script",
    response_class=Response,
)
async def get_scan_client() -> Response:
    script_path = Path(settings.serve_dir) / "scan"
    if not script_path.is_file():
        # Fall back to the file in the repo
        script_path = Path(
            "/tmp/jenkins-local-agent-code/jenkins/scripts/client/security-scan-client.sh"
        )
    if not script_path.is_file():
        raise HTTPException(status_code=404, detail="Scan client script not found")
    return Response(
        content=script_path.read_bytes(),
        media_type="text/plain",
        headers={"Content-Disposition": "inline; filename=scan"},
    )


# ── Source upload ────────────────────────────────────────────
@router.post(
    "/upload",
    response_model=UploadResponse,
    summary="Upload source code archive",
    status_code=200,
)
async def upload_source(
    request: Request,
    x_scan_id: str = Header(..., alias="X-Scan-ID"),
) -> UploadResponse:
    content_length = int(request.headers.get("content-length", 0))

    if content_length == 0:
        raise HTTPException(status_code=400, detail="No data received")
    if content_length > settings.max_upload_bytes:
        raise HTTPException(status_code=413, detail="Upload too large (max 1 GB)")

    upload_path = Path(settings.upload_dir) / x_scan_id
    upload_path.mkdir(parents=True, exist_ok=True)
    tar_path = upload_path / "source.tar.gz"

    received = 0
    start = time.monotonic()
    with open(tar_path, "wb") as fh:
        async for chunk in request.stream():
            fh.write(chunk)
            received += len(chunk)

    size = tar_path.stat().st_size
    elapsed = time.monotonic() - start
    print(
        f"[UPLOAD] scan_id={x_scan_id} size={size} elapsed={elapsed:.1f}s"
    )
    return UploadResponse(
        status="ok",
        scan_id=x_scan_id,
        upload_path=str(upload_path),
        size=size,
    )


# ── Upload alias (without /scan prefix for backward compat) ────
_upload_handler = upload_source  # reference for alias in main.py


# ── Scan status ──────────────────────────────────────────────
@router.get(
    "/{scan_id}/status",
    response_model=ScanStatusResponse,
    summary="Poll scan / build status",
)
async def get_scan_status(scan_id: str) -> ScanStatusResponse:
    entry = _SCAN_BUILD_MAP.get(scan_id)
    if not entry:
        # Try to find by searching with pipeline suffix
        for suffix in ("-security-scan-pipeline", "-ci-cd-pipeline", "-devsecops-pipeline"):
            entry = _SCAN_BUILD_MAP.get(scan_id + suffix)
            if entry:
                break
    if not entry:
        # Last resort: search Jenkins for this scan ID
        async with JenkinsClient() as jenkins:
            for pipeline_name in ("security-scan-pipeline", "devsecops-pipeline", "ci-cd-pipeline"):
                try:
                    build_data = await jenkins.find_build_by_scan_id(pipeline_name, scan_id, limit=5)
                    if build_data:
                        build_number = build_data.get("number", 0)
                        register_scan_build(scan_id, pipeline_name, build_number)
                        entry = (pipeline_name, build_number)
                        break
                except Exception:
                    continue
    if not entry:
        raise HTTPException(status_code=404, detail=f"No build registered for scan {scan_id}")

    pipeline, build_number = entry
    async with JenkinsClient() as jenkins:
        try:
            data = await jenkins.get_build(pipeline, build_number)
        except JenkinsError as exc:
            if exc.status_code == 404:
                raise HTTPException(status_code=404, detail=str(exc))
            raise HTTPException(status_code=502, detail=str(exc))

    return ScanStatusResponse(
        scan_id=scan_id,
        building=data.get("building", False),
        result=data.get("result"),
        build_number=data.get("number"),
        build_url=data.get("url"),
        duration_ms=data.get("duration"),
        estimated_duration_ms=data.get("estimatedDuration"),
        timestamp=data.get("timestamp"),
    )


# ── Cancel scan ──────────────────────────────────────────────
@router.post(
    "/{scan_id}/cancel",
    response_model=SimpleOkResponse,
    summary="Abort a running scan",
)
async def cancel_scan(scan_id: str) -> SimpleOkResponse:
    entry = _SCAN_BUILD_MAP.get(scan_id)
    if not entry:
        raise HTTPException(status_code=404, detail=f"No build registered for scan {scan_id}")
    pipeline, build_number = entry
    async with JenkinsClient() as jenkins:
        try:
            await jenkins.stop_build(pipeline, build_number)
        except JenkinsError as exc:
            raise HTTPException(status_code=502, detail=str(exc))
    return SimpleOkResponse(status="cancelled")


# ── Console log ──────────────────────────────────────────────
@router.get(
    "/{scan_id}/logs",
    summary="Stream console log",
    response_class=Response,
)
async def stream_scan_logs(scan_id: str, start: int = 0) -> Response:
    entry = _SCAN_BUILD_MAP.get(scan_id)
    if not entry:
        raise HTTPException(status_code=404, detail=f"No build registered for scan {scan_id}")
    pipeline, build_number = entry
    async with JenkinsClient() as jenkins:
        try:
            text = await jenkins.get_console_text(pipeline, build_number, start)
        except JenkinsError as exc:
            if exc.status_code == 404:
                raise HTTPException(status_code=404, detail=str(exc))
            raise HTTPException(status_code=502, detail=str(exc))
    return Response(content=text, media_type="text/plain")


# ── Cleanup ──────────────────────────────────────────────────
@router.post(
    "/cleanup",
    response_model=SimpleOkResponse,
    summary="Remove uploaded source files",
)
async def cleanup_scan(body: ScanIdBody) -> SimpleOkResponse:
    scan_id = body.scan_id
    upload_path = Path(settings.upload_dir) / scan_id
    if upload_path.is_dir():
        shutil.rmtree(upload_path, ignore_errors=True)
    # Also deregister the build mapping
    _SCAN_BUILD_MAP.pop(scan_id, None)
    return SimpleOkResponse(status="cleaned")
