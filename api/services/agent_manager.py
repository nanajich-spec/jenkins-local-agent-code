"""
DevSecOps Security Scan API — Agent Manager Service
Wraps dynamic-agent-manager.sh via subprocess for async execution.
"""
from __future__ import annotations

import asyncio
import logging
import re
import shutil
from pathlib import Path
from typing import List, Optional, Tuple

from api.config import settings
from api.models import AgentEntry

logger = logging.getLogger(__name__)

# regex to extract epoch component from scan IDs like alice-host-1744000000
_EPOCH_RE = re.compile(r'(\d{8,})$')


def _agent_name_from_scan_id(scan_id: str) -> str:
    m = _EPOCH_RE.search(scan_id)
    short = m.group(1) if m else scan_id[:12]
    return f"scan-agent-{short}"


class AgentManagerError(RuntimeError):
    pass


class AgentManager:
    """
    Async facade over ``dynamic-agent-manager.sh``.

    All heavy work is I/O-bound subprocess execution; we offload it to a
    thread pool so the event loop stays unblocked.
    """

    def __init__(self) -> None:
        self._script = settings.dynamic_agent_script
        self._timeout_create = settings.agent_creation_timeout
        self._max_agents = settings.max_dynamic_agents

    # ── Internal subprocess runner ───────────────────────────
    async def _run(
        self,
        *args: str,
        timeout: Optional[float] = None,
    ) -> Tuple[int, str, str]:
        """
        Run dynamic-agent-manager.sh with the given args.
        Returns (returncode, stdout, stderr).
        """
        cmd = [self._script, *args]
        logger.debug("agent-manager: %s", " ".join(cmd))
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout_bytes, stderr_bytes = await asyncio.wait_for(
                proc.communicate(), timeout=timeout or self._timeout_create
            )
            return (
                proc.returncode or 0,
                stdout_bytes.decode(errors="replace"),
                stderr_bytes.decode(errors="replace"),
            )
        except asyncio.TimeoutError:
            try:
                proc.kill()
            except Exception:
                pass
            raise AgentManagerError(
                f"Agent manager timed out after {timeout or self._timeout_create}s"
            )
        except FileNotFoundError:
            raise AgentManagerError(
                f"Agent manager script not found: {self._script}"
            )

    # ── Public API ────────────────────────────────────────────
    async def create(self, scan_id: str) -> dict:
        """
        Provision a dynamic Jenkins JNLP agent for scan_id.

        Returns a dict with keys:
            agent_name, agent_label, scan_id, output
        Raises AgentManagerError on failure.
        """
        # Concurrency guard
        rc, out, _ = await self._run("list", timeout=10)
        active_count = out.strip().count("scan-agent-")
        if active_count >= self._max_agents:
            raise AgentManagerError(
                f"Concurrency limit reached: {active_count}/{self._max_agents} agents active"
            )

        rc, out, err = await self._run("create", scan_id)
        agent_name = _agent_name_from_scan_id(scan_id)
        snippet = out[-500:] if len(out) > 500 else out

        if rc != 0:
            raise AgentManagerError(
                f"Agent creation failed (rc={rc}): {err[-300:] or snippet}"
            )

        logger.info("Created agent %s for scan %s", agent_name, scan_id)
        return {
            "agent_name": agent_name,
            "agent_label": agent_name,
            "scan_id": scan_id,
            "output": snippet,
        }

    async def destroy(self, scan_id: str) -> dict:
        """
        Destroy the dynamic agent for scan_id.
        Non-fatal: logs warnings but does not raise on failure.
        """
        rc, out, err = await self._run("destroy", scan_id, timeout=60)
        snippet = out[-300:] if len(out) > 300 else out
        if rc != 0:
            logger.warning("Agent destroy non-zero exit %s for %s: %s", rc, scan_id, err[:200])
        return {"status": "destroyed", "scan_id": scan_id, "output": snippet}

    async def status(self, scan_id: Optional[str] = None) -> str:
        """Return raw status/list output from the manager script."""
        if scan_id:
            _, out, _ = await self._run("status", scan_id, timeout=10)
        else:
            _, out, _ = await self._run("list", timeout=10)
        return out

    async def list_agents(self) -> List[AgentEntry]:
        """
        Parse `dynamic-agent-manager.sh list` output into AgentEntry objects.
        Expected format per non-empty line: `scan-agent-<epoch>  ONLINE|OFFLINE`
        """
        rc, out, _ = await self._run("list", timeout=10)
        entries: List[AgentEntry] = []
        for line in out.splitlines():
            line = line.strip()
            if not line or not line.startswith("scan-agent-"):
                continue
            parts = line.split()
            name = parts[0]
            online = len(parts) > 1 and parts[1].upper() == "ONLINE"
            entries.append(AgentEntry(name=name, online=online))
        return entries

    async def cleanup_all_stale(self) -> int:
        """Call the manager's `cleanup` sub-command. Returns exit code."""
        rc, _, _ = await self._run("cleanup", timeout=60)
        return rc

    # ── Workspace helpers ─────────────────────────────────────
    @staticmethod
    def workspace_path(scan_id: str) -> Path:
        return Path(settings.upload_dir) / scan_id

    @staticmethod
    def remove_workspace(scan_id: str) -> None:
        p = Path(settings.upload_dir) / scan_id
        if p.is_dir():
            shutil.rmtree(p, ignore_errors=True)
            logger.info("Removed workspace %s", p)


# ── Module-level singleton factory ──────────────────────────
def get_agent_manager() -> AgentManager:
    """FastAPI dependency."""
    return AgentManager()
