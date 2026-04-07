"""
DevSecOps Security Scan API — Reports Router
List, summarise, and download scan report artifacts.
"""
from __future__ import annotations

import io
import mimetypes
import tarfile
from pathlib import Path

from fastapi import APIRouter, HTTPException
from fastapi.responses import Response, StreamingResponse

from api.models import ReportListResponse, ScanSummary
from api.services import report_parser

router = APIRouter(prefix="/reports", tags=["reports"])


# ── List artifacts ───────────────────────────────────────────
@router.get(
    "/{scan_id}",
    response_model=ReportListResponse,
    summary="List available report artifacts for a scan",
)
async def list_report_files(scan_id: str) -> ReportListResponse:
    artifacts = report_parser.list_artifacts(scan_id)
    if not artifacts:
        raise HTTPException(status_code=404, detail=f"No reports found for scan {scan_id}")
    return ReportListResponse(scan_id=scan_id, artifacts=artifacts)


# ── Structured summary ───────────────────────────────────────
@router.get(
    "/{scan_id}/summary",
    response_model=ScanSummary,
    summary="Get structured vulnerability summary",
)
async def get_scan_summary(scan_id: str) -> ScanSummary:
    summary = report_parser.build_summary(scan_id)
    if summary is None:
        raise HTTPException(status_code=404, detail=f"No reports found for scan {scan_id}")
    return summary


# ── Download all as tar.gz ────────────────────────────────────
@router.get(
    "/{scan_id}/download",
    summary="Download all reports as tar.gz archive",
)
async def download_reports_archive(scan_id: str) -> StreamingResponse:
    artifacts = report_parser.list_artifacts(scan_id)
    if not artifacts:
        raise HTTPException(status_code=404, detail=f"No reports found for scan {scan_id}")

    root = report_parser._reports_root(scan_id)

    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for artifact in artifacts:
            fpath = root / artifact
            if fpath.is_file():
                tar.add(str(fpath), arcname=f"security-reports-{scan_id}/{artifact}")
    buf.seek(0)

    return StreamingResponse(
        buf,
        media_type="application/octet-stream",
        headers={
            "Content-Disposition": f'attachment; filename="security-reports-{scan_id}.tar.gz"'
        },
    )


# ── Single artifact ──────────────────────────────────────────
@router.get(
    "/{scan_id}/{artifact:path}",
    summary="Download a specific report artifact",
)
async def get_report_artifact(scan_id: str, artifact: str) -> Response:
    path = report_parser.get_artifact_path(scan_id, artifact)
    if path is None:
        raise HTTPException(
            status_code=404,
            detail=f"Artifact '{artifact}' not found for scan {scan_id}",
        )

    content = path.read_bytes()
    mime, _ = mimetypes.guess_type(str(path))
    if mime is None:
        mime = "application/octet-stream"

    return Response(
        content=content,
        media_type=mime,
        headers={"Content-Disposition": f'inline; filename="{path.name}"'},
    )
