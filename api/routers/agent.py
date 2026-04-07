"""
DevSecOps Security Scan API — Agent Router
Dynamic Jenkins JNLP agent lifecycle: create / destroy / status / list.
"""
from __future__ import annotations

from fastapi import APIRouter, HTTPException

from api.models import (
    AgentCreateRequest,
    AgentCreateResponse,
    AgentDestroyResponse,
    AgentListResponse,
    AgentStatusResponse,
    ScanIdBody,
    ScanIdBodyOptional,
)
from api.services.agent_manager import AgentManager, AgentManagerError, get_agent_manager

router = APIRouter(prefix="/agent", tags=["agent"])


# ── Create ───────────────────────────────────────────────────
@router.post(
    "/create",
    response_model=AgentCreateResponse,
    summary="Provision a dynamic Jenkins JNLP agent",
    responses={
        429: {"description": "Concurrency limit reached"},
        504: {"description": "Agent creation timed out"},
    },
)
async def create_agent(body: AgentCreateRequest) -> AgentCreateResponse:
    manager: AgentManager = get_agent_manager()
    try:
        result = await manager.create(body.scan_id)
    except AgentManagerError as exc:
        msg = str(exc)
        if "Concurrency limit" in msg:
            raise HTTPException(status_code=429, detail=msg)
        if "timed out" in msg:
            raise HTTPException(status_code=504, detail=msg)
        raise HTTPException(status_code=500, detail=msg)
    return AgentCreateResponse(**result)


# ── Destroy ──────────────────────────────────────────────────
@router.post(
    "/destroy",
    response_model=AgentDestroyResponse,
    summary="Destroy a dynamic Jenkins agent",
)
async def destroy_agent(body: ScanIdBody) -> AgentDestroyResponse:
    manager: AgentManager = get_agent_manager()
    try:
        result = await manager.destroy(body.scan_id)
    except AgentManagerError as exc:
        raise HTTPException(status_code=500, detail=str(exc))
    return AgentDestroyResponse(**result)


# ── Status ───────────────────────────────────────────────────
@router.post(
    "/status",
    response_model=AgentStatusResponse,
    summary="Query dynamic agent status",
)
async def get_agent_status(body: ScanIdBodyOptional = ScanIdBodyOptional()) -> AgentStatusResponse:
    manager: AgentManager = get_agent_manager()
    try:
        output = await manager.status(body.scan_id if body else None)
    except AgentManagerError as exc:
        raise HTTPException(status_code=500, detail=str(exc))
    return AgentStatusResponse(status="ok", output=output)


# ── List ─────────────────────────────────────────────────────
@router.get(
    "/list",
    response_model=AgentListResponse,
    summary="List all active dynamic agents",
)
async def list_agents() -> AgentListResponse:
    manager: AgentManager = get_agent_manager()
    try:
        agents = await manager.list_agents()
    except AgentManagerError as exc:
        raise HTTPException(status_code=500, detail=str(exc))
    return AgentListResponse(agents=agents)
