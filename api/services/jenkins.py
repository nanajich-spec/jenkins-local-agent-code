"""
DevSecOps Security Scan API — Jenkins Service
Thin async wrapper around the Jenkins REST API.
"""
from __future__ import annotations

import asyncio
import logging
import time
from typing import Any, Dict, List, Optional
from urllib.parse import quote

import httpx

from api.config import settings

logger = logging.getLogger(__name__)

# How long to wait for the build to leave the Jenkins queue after trigger
_QUEUE_POLL_TIMEOUT = 30   # seconds
_QUEUE_POLL_INTERVAL = 2   # seconds


class JenkinsError(RuntimeError):
    """Raised when the Jenkins API returns an unexpected response."""
    def __init__(self, message: str, status_code: int = 0, body: str = ""):
        super().__init__(message)
        self.status_code = status_code
        self.body = body


class JenkinsClient:
    """
    Async Jenkins REST API client.

    Usage::

        async with JenkinsClient() as jenkins:
            resp = await jenkins.trigger_build("security-scan-pipeline", {...})
    """

    def __init__(self) -> None:
        auth = None
        if settings.jenkins_token:
            auth = (settings.jenkins_user, settings.jenkins_token)
        self._client = httpx.AsyncClient(
            base_url=settings.jenkins_url,
            auth=auth,
            timeout=60.0,
            headers={"Accept": "application/json"},
        )
        self._crumb: Optional[Dict[str, str]] = None

    async def __aenter__(self) -> "JenkinsClient":
        return self

    async def __aexit__(self, *_: Any) -> None:
        await self._client.aclose()

    # ── CSRF crumb ───────────────────────────────────────────
    async def _get_crumb(self) -> Dict[str, str]:
        """Fetch a fresh Jenkins CSRF crumb (session-bound)."""
        if self._crumb:
            return self._crumb
        r = await self._client.get(
            "/crumbIssuer/api/json",
            headers={"Accept": "application/json"},
        )
        if r.status_code == 200:
            data = r.json()
            self._crumb = {data["crumbRequestField"]: data["crumb"]}
        else:
            logger.warning("Crumb endpoint returned %s – proceeding without CSRF", r.status_code)
            self._crumb = {}
        return self._crumb

    # ── Core request helper ──────────────────────────────────
    async def _post(self, path: str, data: Optional[Dict] = None, **kwargs: Any) -> httpx.Response:
        crumb = await self._get_crumb()
        headers = {**crumb, "Content-Type": "application/x-www-form-urlencoded"}
        return await self._client.post(path, data=data or {}, headers=headers, **kwargs)

    # ── Connectivity probe ───────────────────────────────────
    async def ping(self) -> float:
        """Return round-trip latency in ms, or raise on fail."""
        t0 = time.monotonic()
        r = await self._client.get("/api/json")
        r.raise_for_status()
        return (time.monotonic() - t0) * 1000

    # ── Build trigger ────────────────────────────────────────
    async def trigger_build(
        self,
        pipeline: str,
        params: Dict[str, Any],
    ) -> str:
        """
        Trigger a parameterised Jenkins build.

        Returns the queue item URL (e.g. ``/queue/item/42/``).
        """
        path = f"/job/{quote(pipeline, safe='')}/buildWithParameters"
        r = await self._post(path, data={str(k): str(v) for k, v in params.items()})
        if r.status_code not in (200, 201):
            raise JenkinsError(
                f"Build trigger failed for {pipeline}",
                status_code=r.status_code,
                body=r.text[:500],
            )
        location = r.headers.get("Location", "")
        logger.info("Triggered %s → queue: %s", pipeline, location)
        return location

    async def resolve_build_number(self, queue_url: str) -> Optional[int]:
        """
        Poll the queue item until a build number is assigned.
        Returns None on timeout.
        """
        if not queue_url:
            return None
        # queue_url looks like http://host/queue/item/42/
        path = queue_url.rstrip("/") + "/api/json"
        deadline = time.monotonic() + _QUEUE_POLL_TIMEOUT
        while time.monotonic() < deadline:
            try:
                r = await self._client.get(path)
                if r.status_code == 200:
                    data = r.json()
                    exe = data.get("executable")
                    if exe and exe.get("number"):
                        return int(exe["number"])
            except Exception:
                pass
            await asyncio.sleep(_QUEUE_POLL_INTERVAL)
        return None

    # ── Build status ─────────────────────────────────────────
    async def get_build(self, pipeline: str, build_number: int) -> Dict[str, Any]:
        """Return raw Jenkins build JSON."""
        path = f"/job/{quote(pipeline, safe='')}/{build_number}/api/json"
        r = await self._client.get(path)
        if r.status_code == 404:
            raise JenkinsError(f"Build {pipeline}#{build_number} not found", 404)
        r.raise_for_status()
        return r.json()

    async def find_build_by_scan_id(
        self, pipeline: str, scan_id: str, limit: int = 20
    ) -> Optional[Dict[str, Any]]:
        """
        Search recent builds of a pipeline for one whose SCAN_ID parameter
        matches. Returns the first match or None.
        """
        builds = await self.list_builds(pipeline, limit)
        for b in builds:
            try:
                detail = await self.get_build(pipeline, b["number"])
                for action in detail.get("actions", []):
                    for param in action.get("parameters", []):
                        if param.get("name") == "SCAN_ID" and param.get("value") == scan_id:
                            return detail
            except Exception:
                continue
        return None

    # ── Console log ──────────────────────────────────────────
    async def get_console_text(
        self, pipeline: str, build_number: int, start: int = 0
    ) -> str:
        """Return console text from byte offset `start`."""
        path = (
            f"/job/{quote(pipeline, safe='')}/{build_number}/logText/progressiveText"
        )
        r = await self._client.get(path, params={"start": start})
        if r.status_code == 404:
            raise JenkinsError(f"Console for {pipeline}#{build_number} not found", 404)
        r.raise_for_status()
        return r.text

    # ── Stop build ───────────────────────────────────────────
    async def stop_build(self, pipeline: str, build_number: int) -> None:
        path = f"/job/{quote(pipeline, safe='')}/{build_number}/stop"
        await self._post(path)

    # ── Node (agent) management ──────────────────────────────
    async def delete_node(self, node_name: str) -> None:
        path = f"/computer/{quote(node_name, safe='')}/doDelete"
        r = await self._post(path)
        if r.status_code not in (200, 302):
            logger.warning("delete_node %s returned %s", node_name, r.status_code)

    async def get_node(self, node_name: str) -> Dict[str, Any]:
        path = f"/computer/{quote(node_name, safe='')}/api/json"
        r = await self._client.get(path)
        if r.status_code == 404:
            raise JenkinsError(f"Node {node_name} not found", 404)
        r.raise_for_status()
        return r.json()

    async def list_nodes(self) -> List[Dict[str, Any]]:
        r = await self._client.get("/computer/api/json")
        r.raise_for_status()
        return r.json().get("computer", [])

    # ── List builds ──────────────────────────────────────────
    async def list_builds(self, pipeline: str, limit: int = 10) -> List[Dict[str, Any]]:
        path = f"/job/{quote(pipeline, safe='')}/api/json"
        r = await self._client.get(
            path,
            params={"tree": f"builds[number,result,building,timestamp,duration,url]{{0,{limit}}}"},
        )
        if r.status_code == 404:
            raise JenkinsError(f"Pipeline {pipeline} not found", 404)
        r.raise_for_status()
        return r.json().get("builds", [])


# ── Module-level singleton factory ──────────────────────────
def get_jenkins_client() -> JenkinsClient:
    """FastAPI dependency: returns a fresh JenkinsClient per request."""
    return JenkinsClient()
