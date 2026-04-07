"""
DevSecOps Security Scan API — Pipeline Router
Trigger Jenkins pipelines, list and get build details.
"""
from __future__ import annotations

from typing import List

from fastapi import APIRouter, HTTPException

from api.config import settings
from api.models import (
    BuildDetail,
    BuildListResponse,
    BuildSummary,
    PipelineTriggerRequest,
    PipelineTriggerResponse,
)
from api.services.jenkins import JenkinsClient, JenkinsError, get_jenkins_client
from api.routers.scan import register_scan_build

router = APIRouter(prefix="/pipeline", tags=["pipeline"])


def _build_params(req: PipelineTriggerRequest) -> dict:
    """Convert trigger request to Jenkins buildWithParameters form data."""
    params: dict = {
        "AGENT_LABEL": req.agent_label,
        "SCAN_ID": req.scan_id,
        "SCAN_TYPE": req.scan_type,
        "GENERATE_SBOM": str(req.generate_sbom).lower(),
        "FAIL_ON_CRITICAL": str(req.fail_on_critical).lower(),
        "SCAN_REGISTRY_IMAGES": str(req.scan_registry_images).lower(),
    }
    if req.source_upload_path:
        params["SOURCE_UPLOAD_PATH"] = req.source_upload_path
    if req.image_name:
        params["IMAGE_NAME"] = req.image_name
    if req.image_tag:
        params["IMAGE_TAG"] = req.image_tag
    if req.registry_url:
        params["REGISTRY_URL"] = req.registry_url
    return params


@router.post(
    "/trigger",
    response_model=PipelineTriggerResponse,
    status_code=202,
    summary="Trigger a Jenkins pipeline build",
)
async def trigger_pipeline(req: PipelineTriggerRequest) -> PipelineTriggerResponse:
    if req.pipeline not in settings.known_pipelines:
        raise HTTPException(
            status_code=400,
            detail=f"Unknown pipeline '{req.pipeline}'. "
                   f"Known: {settings.known_pipelines}",
        )

    async with JenkinsClient() as jenkins:
        try:
            queue_url = await jenkins.trigger_build(req.pipeline, _build_params(req))
        except JenkinsError as exc:
            raise HTTPException(status_code=502, detail=str(exc))

        # Best-effort: resolve queue → build number
        build_number = await jenkins.resolve_build_number(queue_url)

    # Register mapping for /scan/{id}/status
    if build_number:
        register_scan_build(req.scan_id, req.pipeline, build_number)

    return PipelineTriggerResponse(
        status="queued",
        queue_item_url=queue_url,
        build_number=build_number,
    )


@router.get(
    "/{pipeline_name}/builds",
    response_model=BuildListResponse,
    summary="List recent builds of a pipeline",
)
async def list_pipeline_builds(
    pipeline_name: str,
    limit: int = 10,
) -> BuildListResponse:
    if pipeline_name not in settings.known_pipelines:
        raise HTTPException(status_code=404, detail=f"Pipeline '{pipeline_name}' not found")

    async with JenkinsClient() as jenkins:
        try:
            raw = await jenkins.list_builds(pipeline_name, min(limit, 100))
        except JenkinsError as exc:
            if exc.status_code == 404:
                raise HTTPException(status_code=404, detail=str(exc))
            raise HTTPException(status_code=502, detail=str(exc))

    builds = [
        BuildSummary(
            number=b.get("number", 0),
            result=b.get("result"),
            building=b.get("building", False),
            timestamp=b.get("timestamp"),
            duration=b.get("duration"),
            url=b.get("url"),
        )
        for b in raw
    ]
    return BuildListResponse(pipeline=pipeline_name, builds=builds)


@router.get(
    "/{pipeline_name}/builds/{build_number}",
    response_model=BuildDetail,
    summary="Get single build detail",
)
async def get_build_detail(pipeline_name: str, build_number: int) -> BuildDetail:
    if pipeline_name not in settings.known_pipelines:
        raise HTTPException(status_code=404, detail=f"Pipeline '{pipeline_name}' not found")

    async with JenkinsClient() as jenkins:
        try:
            b = await jenkins.get_build(pipeline_name, build_number)
        except JenkinsError as exc:
            if exc.status_code == 404:
                raise HTTPException(status_code=404, detail=str(exc))
            raise HTTPException(status_code=502, detail=str(exc))

    # Extract parameters from actions
    params: dict = {}
    for action in b.get("actions", []):
        for p in action.get("parameters", []):
            params[p.get("name", "")] = p.get("value")

    artifacts = [
        {
            "fileName": a.get("fileName", ""),
            "relativePath": a.get("relativePath", ""),
            "displayPath": a.get("displayPath", ""),
        }
        for a in b.get("artifacts", [])
    ]

    return BuildDetail(
        number=b.get("number", 0),
        result=b.get("result"),
        building=b.get("building", False),
        timestamp=b.get("timestamp"),
        duration=b.get("duration"),
        url=b.get("url"),
        display_name=b.get("displayName"),
        description=b.get("description"),
        parameters=params or None,
        artifacts=artifacts or None,
    )
