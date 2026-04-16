"""
DevSecOps Security Scan API — Report Parser Service
Parses JSON report artifacts produced by Trivy / SonarQube / ShellCheck into
a structured ScanSummary.  Returns clean, structured data — never raw logs.
"""
from __future__ import annotations

import json
import logging
import os
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from api.config import settings
from api.models import FindingTotals, ScanSummary

logger = logging.getLogger(__name__)

# Files to exclude from artifact listings (raw logs, temp files)
_EXCLUDE_FILES = {
    "full-console-log.txt",
    "console-output.txt",
    ".trivy-cache",
}
_EXCLUDE_EXTENSIONS = {".log", ".tmp"}


def _reports_root(scan_id: str) -> Path:
    """
    Locate the report directory for a scan.
    Search order:
      1. /opt/scan-reports/<scan_id>/             (new pipeline output)
      2. /opt/scan-reports/<scan_id>-<pipeline>/  (multi-pipeline runs)
      3. Legacy workspace dirs                    (backward compat)
    """
    # Primary: dedicated reports dir
    p = Path(settings.reports_dir) / scan_id
    if p.is_dir():
        return p

    # Try with pipeline suffix patterns
    reports_base = Path(settings.reports_dir)
    if reports_base.is_dir():
        for child in sorted(reports_base.iterdir(), reverse=True):
            if child.is_dir() and child.name.startswith(scan_id):
                return child

    # Legacy: workspace security-reports-<timestamp>/<pipeline>/
    workspace = Path("/tmp/jenkins-local-agent-code")
    for legacy in sorted(workspace.glob("security-reports-*"), reverse=True):
        if legacy.is_dir():
            # Search subdirectories for one matching scan_id in its content
            for subdir in sorted(legacy.iterdir()):
                if subdir.is_dir():
                    # Check if gate-results.txt or any trivy file present
                    if any(subdir.glob("*.json")):
                        return subdir

    return p  # fallback, may not exist


def _load_json(path: Path) -> Optional[Any]:
    if not path.is_file():
        return None
    try:
        with open(path) as fh:
            return json.load(fh)
    except Exception as exc:
        logger.warning("JSON parse failed for %s: %s", path, exc)
        return None


def _count_trivy_findings(data: Any) -> FindingTotals:
    """Count vulnerabilities from a Trivy JSON report."""
    totals = FindingTotals()
    if not isinstance(data, dict):
        return totals
    for result in data.get("Results", []):
        for vuln in result.get("Vulnerabilities") or []:
            sev = (vuln.get("Severity") or "").upper()
            if sev == "CRITICAL":
                totals.critical += 1
            elif sev == "HIGH":
                totals.high += 1
            elif sev == "MEDIUM":
                totals.medium += 1
            elif sev == "LOW":
                totals.low += 1
            else:
                totals.unknown += 1
        for misc in result.get("Misconfigurations") or []:
            sev = (misc.get("Severity") or "").upper()
            if sev == "CRITICAL":
                totals.critical += 1
            elif sev == "HIGH":
                totals.high += 1
            elif sev == "MEDIUM":
                totals.medium += 1
            elif sev == "LOW":
                totals.low += 1
            else:
                totals.unknown += 1
    return totals


def _count_secrets(data: Any) -> int:
    """Count secret detections from a Trivy secret scan JSON."""
    total = 0
    if not isinstance(data, dict):
        return total
    for result in data.get("Results", []):
        total += len(result.get("Secrets") or [])
    return total


def _sbom_component_count(path: Path) -> Optional[int]:
    """Count components in a CycloneDX JSON SBOM."""
    data = _load_json(path)
    if not isinstance(data, dict):
        return None
    components = data.get("components") or []
    return len(components)


def _sonarqube_gate(path: Path) -> Optional[str]:
    """Parse SonarQube quality gate JSON."""
    data = _load_json(path)
    if not isinstance(data, dict):
        return None
    ps = data.get("projectStatus") or data
    return (ps.get("status") or "").upper() or None


def _should_include_artifact(name: str) -> bool:
    """Filter out raw log files and temp files from artifact listings."""
    basename = os.path.basename(name)
    if basename in _EXCLUDE_FILES:
        return False
    _, ext = os.path.splitext(basename)
    if ext in _EXCLUDE_EXTENSIONS:
        return False
    # Exclude console log patterns
    if "console-log" in basename.lower() or "console-output" in basename.lower():
        return False
    return True


# ── Public API ────────────────────────────────────────────────

def list_artifacts(scan_id: str) -> List[str]:
    """
    Return relative paths of all report files for scan_id.
    Excludes raw log files.
    """
    root = _reports_root(scan_id)
    if not root.is_dir():
        return []
    result = []
    for p in sorted(root.rglob("*")):
        if p.is_file():
            rel = str(p.relative_to(root))
            if _should_include_artifact(rel):
                result.append(rel)
    return result


def get_artifact_path(scan_id: str, artifact: str) -> Optional[Path]:
    """
    Resolve a relative artifact name (e.g. ``sbom/trivy-cyclonedx-full.json``)
    to an absolute path, only if it exists under the scan's report root.
    """
    root = _reports_root(scan_id)
    # Prevent path traversal
    candidate = (root / artifact).resolve()
    try:
        candidate.relative_to(root.resolve())  # raises ValueError if outside
    except ValueError:
        return None
    return candidate if candidate.is_file() else None


def build_summary(scan_id: str) -> Optional[ScanSummary]:
    """
    Parse all available report JSON files for scan_id and return a
    structured ScanSummary with finding counts — never includes raw logs.
    Returns None if no reports exist.
    """
    root = _reports_root(scan_id)
    if not root.is_dir():
        logger.debug("No reports directory for scan %s at %s", scan_id, root)
        return None

    # Check if we have a pre-built scan-summary.json (from pipeline Stage 11)
    summary_json = root / "scan-summary.json"
    if summary_json.is_file():
        data = _load_json(summary_json)
        if data and isinstance(data, dict):
            return _build_from_summary_json(scan_id, data)

    # Check if we have a unified local final-report.json (pre-push scanner)
    unified_report = root / "final-report.json"
    if unified_report.is_file():
        data = _load_json(unified_report)
        if data and isinstance(data, dict):
            return _build_from_unified_report(scan_id, data)

    findings_by_type: Dict[str, FindingTotals] = {}

    # ── SAST / filesystem scan ──────────────────────────────
    for fname in ("trivy-fs-scan.json", "trivy-fs.json"):
        p = root / fname
        if p.is_file():
            data = _load_json(p)
            if data:
                findings_by_type["sast"] = _count_trivy_findings(data)
            break

    # ── SCA / dependency scan ───────────────────────────────
    for fname in ("trivy-sca.json",):
        p = root / fname
        if p.is_file():
            data = _load_json(p)
            if data:
                findings_by_type["sca"] = _count_trivy_findings(data)
            break

    # ── Image scan ──────────────────────────────────────────
    for fname in ("trivy-image-scan.json", "trivy-image.json"):
        p = root / fname
        if p.is_file():
            data = _load_json(p)
            if data:
                findings_by_type["image"] = _count_trivy_findings(data)
            break

    # ── K8s / config scan ───────────────────────────────────
    for fname in ("trivy-k8s-scan.json", "trivy-k8s-config.json"):
        p = root / fname
        if p.is_file():
            data = _load_json(p)
            if data:
                findings_by_type["k8s"] = _count_trivy_findings(data)
            break

    # ── Registry image scans ────────────────────────────────
    for p in sorted(root.glob("registry-scan-*.json")):
        data = _load_json(p)
        if data:
            img_name = p.stem.replace("registry-scan-", "")
            findings_by_type[f"registry:{img_name}"] = _count_trivy_findings(data)

    # ── ShellCheck / Hadolint (count as low if present) ──────
    for fname in ("shellcheck.json", "shellcheck-report.json"):
        p = root / fname
        if p.is_file():
            data = _load_json(p)
            if isinstance(data, list) and data:
                findings_by_type["shellcheck"] = FindingTotals(low=len(data))
            break

    for fname in ("hadolint.json", "hadolint-report.json"):
        p = root / fname
        if p.is_file():
            data = _load_json(p)
            if isinstance(data, list) and data:
                findings_by_type["hadolint"] = FindingTotals(low=len(data))
            break

    # ── Secret detection ────────────────────────────────────
    secrets = 0
    p = root / "secret-scan.json"
    if p.is_file():
        data = _load_json(p)
        if data:
            secrets = _count_secrets(data)

    # ── SBOM component count ─────────────────────────────────
    sbom_count: Optional[int] = None
    for sbom_path in [
        root / "sbom" / "trivy-cyclonedx-full.json",
        root / "sbom-trivy-cyclonedx.json",
        root / "sbom" / "trivy-cyclonedx-sbom.json",
    ]:
        if sbom_path.is_file():
            sbom_count = _sbom_component_count(sbom_path)
            break

    # ── SonarQube quality gate ───────────────────────────────
    sq_gate: Optional[str] = None
    for sq_path in [
        root / "sonarqube-quality-gate.json",
        root / "sonarqube" / "quality-gate.json",
    ]:
        if sq_path.is_file():
            sq_gate = _sonarqube_gate(sq_path)
            break

    # ── Gate results from gate-results.txt ──────────────────
    gate_passed = True
    gate_txt = root / "gate-results.txt"
    if gate_txt.is_file():
        text = gate_txt.read_text(errors="replace")
        # Parse structured gate-results.txt
        vals = {}
        for line in text.splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                vals[k.strip()] = v.strip()
        gate_status = vals.get("GATE_STATUS", "").upper()
        if gate_status == "FAIL":
            gate_passed = False
        elif gate_status == "PASS":
            gate_passed = True
        else:
            # Fallback: check for fail/critical keywords
            lower = text.lower()
            if "fail" in lower:
                gate_passed = False

    # ── Aggregate totals ─────────────────────────────────────
    agg = FindingTotals()
    for ft in findings_by_type.values():
        agg.critical += ft.critical
        agg.high += ft.high
        agg.medium += ft.medium
        agg.low += ft.low
        agg.unknown += ft.unknown

    # Auto-fail if any CRITICAL found and gate_results.txt absent
    if agg.critical > 0 and not gate_txt.is_file():
        gate_passed = False

    return ScanSummary(
        scan_id=scan_id,
        gate_passed=gate_passed,
        totals=agg,
        findings_by_type=findings_by_type if findings_by_type else None,
        sbom_component_count=sbom_count,
        secrets_found=secrets,
        sonarqube_quality_gate=sq_gate,
    )


def _build_from_summary_json(
    scan_id: str, data: Dict[str, Any]
) -> ScanSummary:
    """Build ScanSummary from the pre-generated scan-summary.json."""
    totals_raw = data.get("totals", {})
    totals = FindingTotals(
        critical=totals_raw.get("critical", 0),
        high=totals_raw.get("high", 0),
        medium=totals_raw.get("medium", 0),
        low=totals_raw.get("low", 0),
        unknown=totals_raw.get("unknown", 0),
    )

    findings_by_type: Dict[str, FindingTotals] = {}
    for key, val in (data.get("findings_by_scan") or {}).items():
        if isinstance(val, dict) and "critical" in val:
            findings_by_type[key] = FindingTotals(
                critical=val.get("critical", 0),
                high=val.get("high", 0),
                medium=val.get("medium", 0),
                low=val.get("low", 0),
                unknown=val.get("unknown", 0),
            )

    return ScanSummary(
        scan_id=scan_id,
        gate_passed=data.get("gate_passed", True),
        totals=totals,
        findings_by_type=findings_by_type if findings_by_type else None,
        sbom_component_count=data.get("sbom_component_count"),
        secrets_found=data.get("secrets_found", 0),
        sonarqube_quality_gate=data.get("sonarqube_quality_gate"),
    )


def _build_from_unified_report(scan_id: str, data: Dict[str, Any]) -> ScanSummary:
    """Build ScanSummary from unified local final-report.json output."""
    summary = data.get("summary") or {}
    verdict = summary.get("gate_verdict") or {}
    sev = summary.get("severity_totals") or {}

    totals = FindingTotals(
        critical=int(sev.get("CRITICAL", 0)),
        high=int(sev.get("HIGH", 0)),
        medium=int(sev.get("MEDIUM", 0)),
        low=int(sev.get("LOW", 0)),
        unknown=int(sev.get("UNKNOWN", 0)),
    )

    findings_by_type: Dict[str, FindingTotals] = {}
    for key, val in (data.get("findings_by_tool") or {}).items():
        if isinstance(val, dict):
            findings_by_type[key] = FindingTotals(
                critical=int(val.get("CRITICAL", 0)),
                high=int(val.get("HIGH", 0)),
                medium=int(val.get("MEDIUM", 0)),
                low=int(val.get("LOW", 0)),
                unknown=int(val.get("UNKNOWN", 0)),
            )

    sonarqube_quality_gate = None
    sonar_status = (summary.get("tool_status") or {}).get("sonar-scanner")
    if isinstance(sonar_status, dict):
        sonarqube_quality_gate = "AVAILABLE" if sonar_status.get("available") else "UNAVAILABLE"

    return ScanSummary(
        scan_id=scan_id,
        gate_passed=(verdict.get("status") == "PASS"),
        totals=totals,
        findings_by_type=findings_by_type if findings_by_type else None,
        sbom_component_count=None,
        secrets_found=None,
        sonarqube_quality_gate=sonarqube_quality_gate,
        pipeline="unified-prepush",
        build_number=None,
    )
