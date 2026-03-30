#!/usr/bin/env bash
# =============================================================================
# generate-comprehensive-report.sh
# =============================================================================
# Generates a unified HTML + text comprehensive report that aggregates:
#   1. Unit Test Results & Coverage
#   2. SonarQube Quality Gate & Metrics
#   3. CycloneDX SBOM Summary
#   4. Trivy Security Scan Results
#   5. Secret Detection
#   6. SAST / SCA / Dependency Analysis
#   7. K8s Manifest / Dockerfile / Shell Lint
#   8. Final HIGH / CRITICAL / BLOCKER Summary
#
# Usage:
#   ./generate-comprehensive-report.sh <REPORTS_DIR> [LANGUAGE] [IMAGE_NAME]
# =============================================================================

set -euo pipefail

REPORTS_DIR="${1:-.}"
LANGUAGE="${2:-unknown}"
IMAGE_NAME="${3:-N/A}"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
BUILD_ID="${BUILD_NUMBER:-0}"
JOB="${JOB_NAME:-pipeline}"
COVERAGE_THRESHOLD="${COVERAGE_THRESHOLD:-70}"

REPORT_HTML="${REPORTS_DIR}/comprehensive-report.html"
REPORT_TEXT="${REPORTS_DIR}/comprehensive-report.txt"

echo "=== Generating Comprehensive Report ==="
echo "  Reports Dir: ${REPORTS_DIR}"
echo "  Language:    ${LANGUAGE}"
echo "  Output HTML: ${REPORT_HTML}"
echo "  Output TXT:  ${REPORT_TEXT}"

# =============================================================================
# Generate via Python for robust JSON parsing
# =============================================================================
python3 <<'COMPREHENSIVE_REPORT_EOF'
import json, os, glob, datetime, xml.etree.ElementTree as ET
from collections import defaultdict

REPORTS_DIR = os.environ.get("REPORTS_DIR", ".")
LANGUAGE = os.environ.get("LANGUAGE", "unknown")
IMAGE_NAME = os.environ.get("IMAGE_NAME", "N/A")
BUILD_ID = os.environ.get("BUILD_NUMBER", "0")
JOB = os.environ.get("JOB_NAME", "pipeline")
TIMESTAMP = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
COVERAGE_THRESHOLD = float(os.environ.get("COVERAGE_THRESHOLD", "70"))

# ─── Collectors ───
sections = {}
all_critical_issues = []
summary_counts = {
    "critical_vulns": 0, "high_vulns": 0, "medium_vulns": 0, "low_vulns": 0,
    "blocker_issues": 0, "secrets": 0, "misconfigs_critical": 0, "misconfigs_high": 0,
    "test_total": 0, "test_passed": 0, "test_failed": 0, "test_errors": 0,
    "coverage_pct": None, "sonar_gate": "N/A", "sonar_bugs": 0, "sonar_vulns": 0,
    "sonar_code_smells": 0, "sonar_coverage": "N/A", "sbom_components": 0
}

# =============================================================================
# 1. UNIT TEST RESULTS
# =============================================================================
def parse_unit_tests():
    section = {"title": "Unit Test Results", "status": "SKIPPED", "details": []}

    # pytest results
    for xml_file in glob.glob(os.path.join(REPORTS_DIR, "pytest-*-results.xml")) + \
                     glob.glob(os.path.join(REPORTS_DIR, "pytest-results.xml")):
        try:
            tree = ET.parse(xml_file)
            root = tree.getroot()
            tests = int(root.attrib.get("tests", 0))
            errors = int(root.attrib.get("errors", 0))
            failures = int(root.attrib.get("failures", 0))
            skipped = int(root.attrib.get("skipped", 0))
            time_s = float(root.attrib.get("time", 0))
            passed = tests - errors - failures - skipped

            summary_counts["test_total"] += tests
            summary_counts["test_passed"] += passed
            summary_counts["test_failed"] += failures
            summary_counts["test_errors"] += errors

            status = "PASS" if failures == 0 and errors == 0 else "FAIL"
            section["status"] = status
            section["details"].append({
                "framework": "pytest",
                "file": os.path.basename(xml_file),
                "total": tests, "passed": passed, "failed": failures,
                "errors": errors, "skipped": skipped, "duration": f"{time_s:.2f}s"
            })

            # Collect failed test names
            for tc in root.iter("testcase"):
                for fail in tc.findall("failure"):
                    all_critical_issues.append({
                        "source": "Unit Test",
                        "severity": "BLOCKER",
                        "title": f"FAILED: {tc.attrib.get('classname','')}.{tc.attrib.get('name','')}",
                        "detail": fail.attrib.get("message", "")[:200]
                    })
                    summary_counts["blocker_issues"] += 1
        except Exception as e:
            section["details"].append({"error": str(e), "file": xml_file})

    # Maven surefire JUnit results
    for xml_file in glob.glob(os.path.join(REPORTS_DIR, "TEST-*.xml")):
        try:
            tree = ET.parse(xml_file)
            root = tree.getroot()
            tests = int(root.attrib.get("tests", 0))
            errors = int(root.attrib.get("errors", 0))
            failures = int(root.attrib.get("failures", 0))
            passed = tests - errors - failures
            summary_counts["test_total"] += tests
            summary_counts["test_passed"] += passed
            summary_counts["test_failed"] += failures
            section["status"] = "PASS" if failures == 0 and errors == 0 else "FAIL"
            section["details"].append({
                "framework": "JUnit",
                "file": os.path.basename(xml_file),
                "total": tests, "passed": passed, "failed": failures, "errors": errors
            })
        except:
            pass

    # Go test results
    go_results = os.path.join(REPORTS_DIR, "go-test-unit.json")
    if os.path.exists(go_results):
        try:
            passed = failed = 0
            with open(go_results) as f:
                for line in f:
                    try:
                        entry = json.loads(line)
                        if entry.get("Action") == "pass" and entry.get("Test"):
                            passed += 1
                        elif entry.get("Action") == "fail" and entry.get("Test"):
                            failed += 1
                    except:
                        pass
            total = passed + failed
            summary_counts["test_total"] += total
            summary_counts["test_passed"] += passed
            summary_counts["test_failed"] += failed
            section["status"] = "PASS" if failed == 0 else "FAIL"
            section["details"].append({"framework": "go test", "total": total, "passed": passed, "failed": failed})
        except:
            pass

    if not section["details"]:
        section["status"] = "SKIPPED"
    sections["unit_tests"] = section

# =============================================================================
# 2. CODE COVERAGE
# =============================================================================
def parse_coverage():
    section = {"title": "Code Coverage", "status": "SKIPPED", "details": []}

    # Python coverage.xml (Cobertura format)
    cov_file = os.path.join(REPORTS_DIR, "coverage.xml")
    if os.path.exists(cov_file):
        try:
            tree = ET.parse(cov_file)
            root = tree.getroot()
            rate = float(root.attrib.get("line-rate", 0)) * 100
            lines_valid = root.attrib.get("lines-valid", "?")
            lines_covered = root.attrib.get("lines-covered", "?")
            branch_rate = float(root.attrib.get("branch-rate", 0)) * 100
            summary_counts["coverage_pct"] = round(rate, 1)

            gate = "PASS" if rate >= COVERAGE_THRESHOLD else "FAIL"
            section["status"] = gate
            section["details"].append({
                "type": "Line Coverage",
                "percentage": f"{rate:.1f}%",
                "lines": f"{lines_covered}/{lines_valid}",
                "branch_coverage": f"{branch_rate:.1f}%",
                "threshold": f"{COVERAGE_THRESHOLD}%",
                "gate": gate
            })

            # Per-package breakdown
            packages = []
            for pkg in root.findall(".//package"):
                pkg_name = pkg.attrib.get("name", "unknown")
                pkg_rate = float(pkg.attrib.get("line-rate", 0)) * 100
                packages.append({"package": pkg_name, "coverage": f"{pkg_rate:.1f}%"})
            if packages:
                section["details"].append({"package_breakdown": packages[:20]})

            if rate < COVERAGE_THRESHOLD:
                all_critical_issues.append({
                    "source": "Coverage",
                    "severity": "HIGH",
                    "title": f"Coverage below threshold: {rate:.1f}% < {COVERAGE_THRESHOLD}%",
                    "detail": f"Line coverage {lines_covered}/{lines_valid}"
                })
        except Exception as e:
            section["details"].append({"error": str(e)})

    # JaCoCo coverage
    jacoco_file = os.path.join(REPORTS_DIR, "jacoco-coverage.xml")
    if os.path.exists(jacoco_file):
        try:
            tree = ET.parse(jacoco_file)
            root = tree.getroot()
            for counter in root.findall(".//counter"):
                if counter.attrib.get("type") == "LINE":
                    missed = int(counter.attrib.get("missed", 0))
                    covered = int(counter.attrib.get("covered", 0))
                    total = missed + covered
                    rate = (covered / total * 100) if total > 0 else 0
                    summary_counts["coverage_pct"] = round(rate, 1)
                    section["status"] = "PASS" if rate >= COVERAGE_THRESHOLD else "FAIL"
                    section["details"].append({
                        "type": "JaCoCo Line Coverage",
                        "percentage": f"{rate:.1f}%",
                        "lines": f"{covered}/{total}",
                        "threshold": f"{COVERAGE_THRESHOLD}%"
                    })
        except:
            pass

    # Go coverage
    go_cov = os.path.join(REPORTS_DIR, "go-coverage.out")
    if os.path.exists(go_cov):
        section["details"].append({"type": "Go Coverage", "file": "go-coverage.out"})
        section["status"] = "AVAILABLE"

    # lcov (JS/TS)
    lcov = os.path.join(REPORTS_DIR, "lcov.info")
    if os.path.exists(lcov):
        try:
            with open(lcov) as f:
                content = f.read()
            lf = content.count("LF:")
            lh = content.count("LH:")
            section["details"].append({"type": "LCOV", "file": "lcov.info"})
            section["status"] = "AVAILABLE"
        except:
            pass

    if not section["details"]:
        section["status"] = "SKIPPED"
    sections["coverage"] = section

# =============================================================================
# 3. SONARQUBE REPORT
# =============================================================================
def parse_sonarqube():
    section = {"title": "SonarQube Analysis", "status": "SKIPPED", "details": []}

    # Quality Gate
    qg_file = os.path.join(REPORTS_DIR, "sonarqube", "quality-gate-status.json")
    if os.path.exists(qg_file):
        try:
            with open(qg_file) as f:
                qg = json.load(f)
            status = qg.get("projectStatus", {}).get("status", "UNKNOWN")
            summary_counts["sonar_gate"] = status
            section["status"] = status
            conditions = []
            for c in qg.get("projectStatus", {}).get("conditions", []):
                conditions.append({
                    "metric": c.get("metricKey", ""),
                    "actual": c.get("actualValue", "?"),
                    "threshold": c.get("errorThreshold", "?"),
                    "status": c.get("status", "?")
                })
                if c.get("status") == "ERROR":
                    all_critical_issues.append({
                        "source": "SonarQube",
                        "severity": "BLOCKER",
                        "title": f"Quality Gate FAILED: {c.get('metricKey', '')}",
                        "detail": f"Actual: {c.get('actualValue','?')} (threshold: {c.get('errorThreshold','?')})"
                    })
                    summary_counts["blocker_issues"] += 1
            section["details"].append({"quality_gate": status, "conditions": conditions})
        except Exception as e:
            section["details"].append({"error": f"Quality Gate parse error: {e}"})

    # Measures
    measures_file = os.path.join(REPORTS_DIR, "sonarqube", "project-measures.json")
    if os.path.exists(measures_file):
        try:
            with open(measures_file) as f:
                md = json.load(f)
            measures = {m["metric"]: m.get("value", "N/A") for m in md.get("component", {}).get("measures", [])}
            summary_counts["sonar_bugs"] = int(measures.get("bugs", 0))
            summary_counts["sonar_vulns"] = int(measures.get("vulnerabilities", 0))
            summary_counts["sonar_code_smells"] = int(measures.get("code_smells", 0))
            summary_counts["sonar_coverage"] = measures.get("coverage", "N/A")
            section["details"].append({"measures": measures})
        except:
            pass

    # Critical/Blocker issues from SonarQube
    issues_file = os.path.join(REPORTS_DIR, "sonarqube", "critical-issues.json")
    if os.path.exists(issues_file):
        try:
            with open(issues_file) as f:
                issues_data = json.load(f)
            issues = issues_data.get("issues", [])
            blocker_count = sum(1 for i in issues if i.get("severity") == "BLOCKER")
            critical_count = sum(1 for i in issues if i.get("severity") == "CRITICAL")
            section["details"].append({
                "open_issues": len(issues),
                "blocker": blocker_count,
                "critical": critical_count
            })
            for issue in issues[:20]:
                all_critical_issues.append({
                    "source": "SonarQube",
                    "severity": issue.get("severity", "UNKNOWN"),
                    "title": issue.get("message", "")[:150],
                    "detail": f"{issue.get('component','')}: {issue.get('rule','')}"
                })
        except:
            pass

    # Local quality report fallback
    local_file = os.path.join(REPORTS_DIR, "sonarqube", "local-quality-report.json")
    if os.path.exists(local_file):
        try:
            with open(local_file) as f:
                local = json.load(f)
            section["details"].append({"local_quality": local.get("quality_metrics", {})})
            if section["status"] == "SKIPPED":
                section["status"] = "LOCAL_ANALYSIS"
        except:
            pass

    if not section["details"]:
        section["status"] = "SKIPPED"
    sections["sonarqube"] = section

# =============================================================================
# 4. TRIVY SECURITY REPORTS
# =============================================================================
def parse_trivy_reports():
    section = {"title": "Trivy Security Scan", "status": "PASS", "details": []}

    trivy_files = glob.glob(os.path.join(REPORTS_DIR, "trivy-*.json"))
    for tf in sorted(trivy_files):
        basename = os.path.basename(tf)
        if "sbom" in basename or "spdx" in basename:
            continue
        try:
            with open(tf) as f:
                data = json.load(f)
            results = data.get("Results", [])
            vuln_counts = defaultdict(int)
            misconfig_counts = defaultdict(int)

            for r in results:
                for v in r.get("Vulnerabilities", []):
                    sev = v.get("Severity", "UNKNOWN")
                    vuln_counts[sev] += 1
                    if sev == "CRITICAL":
                        summary_counts["critical_vulns"] += 1
                        all_critical_issues.append({
                            "source": f"Trivy ({basename})",
                            "severity": "CRITICAL",
                            "title": f"{v.get('VulnerabilityID','')}: {v.get('PkgName','')} {v.get('InstalledVersion','')}",
                            "detail": v.get("Title", "")[:200]
                        })
                    elif sev == "HIGH":
                        summary_counts["high_vulns"] += 1
                        all_critical_issues.append({
                            "source": f"Trivy ({basename})",
                            "severity": "HIGH",
                            "title": f"{v.get('VulnerabilityID','')}: {v.get('PkgName','')}",
                            "detail": v.get("Title", "")[:200]
                        })

                for m in r.get("Misconfigurations", []):
                    sev = m.get("Severity", "UNKNOWN")
                    misconfig_counts[sev] += 1
                    if sev == "CRITICAL":
                        summary_counts["misconfigs_critical"] += 1
                    elif sev == "HIGH":
                        summary_counts["misconfigs_high"] += 1

            total_vulns = sum(vuln_counts.values())
            total_misconfigs = sum(misconfig_counts.values())

            if vuln_counts.get("CRITICAL", 0) > 0:
                section["status"] = "FAIL"

            section["details"].append({
                "file": basename,
                "vulnerabilities": dict(vuln_counts),
                "misconfigurations": dict(misconfig_counts),
                "total_vulns": total_vulns,
                "total_misconfigs": total_misconfigs
            })
        except Exception as e:
            section["details"].append({"file": basename, "error": str(e)})

    if not section["details"]:
        section["status"] = "SKIPPED"
    sections["trivy"] = section

# =============================================================================
# 5. SECRET DETECTION
# =============================================================================
def parse_secrets():
    section = {"title": "Secret Detection", "status": "PASS", "details": []}

    secret_file = os.path.join(REPORTS_DIR, "secret-scan.json")
    if os.path.exists(secret_file):
        try:
            with open(secret_file) as f:
                data = json.load(f)
            results = data.get("Results", [])
            total_secrets = 0
            for r in results:
                secrets = r.get("Secrets", [])
                total_secrets += len(secrets)
                for s in secrets:
                    all_critical_issues.append({
                        "source": "Secret Detection",
                        "severity": "CRITICAL",
                        "title": f"Secret: {s.get('RuleID','')}: {s.get('Category','')}",
                        "detail": f"File: {r.get('Target','')}, Line: {s.get('StartLine','?')}"
                    })
            summary_counts["secrets"] = total_secrets
            section["status"] = "PASS" if total_secrets == 0 else "FAIL"
            section["details"].append({"secrets_found": total_secrets})
        except:
            pass
    else:
        section["status"] = "SKIPPED"

    sections["secrets"] = section

# =============================================================================
# 6. SBOM SUMMARY
# =============================================================================
def parse_sbom():
    section = {"title": "CycloneDX SBOM", "status": "SKIPPED", "details": []}

    sbom_dir = os.path.join(REPORTS_DIR, "sbom")
    if os.path.isdir(sbom_dir):
        sbom_files = glob.glob(os.path.join(sbom_dir, "sbom-*.json"))
        total = 0
        for sf in sorted(sbom_files):
            try:
                with open(sf) as f:
                    data = json.load(f)
                components = data.get("components", [])
                num = len(components)
                total += num
                section["details"].append({
                    "file": os.path.basename(sf),
                    "format": data.get("bomFormat", "Unknown"),
                    "spec": data.get("specVersion", "?"),
                    "components": num
                })
            except:
                pass
        summary_counts["sbom_components"] = total
        section["status"] = "GENERATED" if total > 0 else "SKIPPED"

        # List text-format SBOM reports for reference
        text_reports = sorted(glob.glob(os.path.join(sbom_dir, "*.txt")))
        if text_reports:
            section["text_reports"] = [os.path.basename(t) for t in text_reports]

    sections["sbom"] = section

# =============================================================================
# 7. OTHER REPORTS (Hadolint, ShellCheck, Grype, OWASP etc.)
# =============================================================================
def parse_other_reports():
    section = {"title": "Additional Security Reports", "status": "SKIPPED", "details": []}

    # Hadolint — support both legacy hadolint.json and new per-Dockerfile hadolint-*.json
    hadolint_jsons = [os.path.join(REPORTS_DIR, "hadolint.json")] + \
                     sorted(glob.glob(os.path.join(REPORTS_DIR, "hadolint-*.json")))
    total_hadolint = 0
    for hadolint_file in hadolint_jsons:
        if not os.path.exists(hadolint_file): continue
        try:
            with open(hadolint_file) as f:
                content = f.read().strip()
            if not content or content in ('[]', '[[]]', ''):
                continue
            issues = json.loads(content)
            # Handle [[...]] wrapping or flat list
            if isinstance(issues, list) and len(issues) > 0 and isinstance(issues[0], list):
                issues = [i for sub in issues for i in sub]
            total_hadolint += len(issues)
            for i in issues:
                if i.get("level") in ("error", "warning"):
                    all_critical_issues.append({
                        "source": f"Hadolint ({os.path.basename(hadolint_file)})",
                        "severity": "HIGH" if i.get("level") == "error" else "MEDIUM",
                        "title": i.get("code", "?"),
                        "description": i.get("message", ""),
                        "location": f"{i.get('file','?')}:{i.get('line','?')}"
                    })
        except Exception as ex:
            pass
    if total_hadolint > 0:
        section["details"].append({"tool": "Hadolint (Dockerfile Lint)", "issues": total_hadolint})
        section["status"] = "SCANNED"

    # ShellCheck
    shellcheck_file = os.path.join(REPORTS_DIR, "shellcheck.json")
    if os.path.exists(shellcheck_file):
        try:
            with open(shellcheck_file) as f:
                issues = json.load(f)
            errors = sum(1 for i in issues if i.get("level") == "error")
            warnings = sum(1 for i in issues if i.get("level") == "warning")
            section["details"].append({
                "tool": "ShellCheck", "total": len(issues),
                "errors": errors, "warnings": warnings
            })
            section["status"] = "SCANNED"
        except:
            pass

    # Grype
    grype_file = os.path.join(REPORTS_DIR, "grype-sca.json")
    if os.path.exists(grype_file):
        try:
            with open(grype_file) as f:
                data = json.load(f)
            matches = data.get("matches", [])
            grype_counts = defaultdict(int)
            for m in matches:
                sev = m.get("vulnerability", {}).get("severity", "Unknown")
                grype_counts[sev] += 1
            section["details"].append({"tool": "Grype SCA", "findings": dict(grype_counts), "total": len(matches)})
            section["status"] = "SCANNED"
        except:
            pass

    # Bandit
    bandit_file = os.path.join(REPORTS_DIR, "bandit-report.json")
    if os.path.exists(bandit_file):
        try:
            with open(bandit_file) as f:
                data = json.load(f)
            results = data.get("results", [])
            sev_counts = defaultdict(int)
            for r in results:
                sev_counts[r.get("issue_severity", "?")] += 1
            section["details"].append({"tool": "Bandit (Python Security)", "findings": dict(sev_counts), "total": len(results)})
            section["status"] = "SCANNED"
        except:
            pass

    # Kubesec
    kubesec_file = os.path.join(REPORTS_DIR, "kubesec-results.json")
    if os.path.exists(kubesec_file):
        section["details"].append({"tool": "Kubesec (K8s Risk)", "file": "kubesec-results.json"})
        section["status"] = "SCANNED"

    if not section["details"]:
        section["status"] = "SKIPPED"
    sections["other"] = section

# =============================================================================
# RUN ALL PARSERS
# =============================================================================
parse_unit_tests()
parse_coverage()
parse_sonarqube()
parse_trivy_reports()
parse_secrets()
parse_sbom()
parse_other_reports()

# =============================================================================
# DETERMINE OVERALL STATUS
# =============================================================================
overall_status = "PASS"
if summary_counts["critical_vulns"] > 0 or summary_counts["secrets"] > 0 or summary_counts["blocker_issues"] > 0:
    overall_status = "FAIL"
elif summary_counts["high_vulns"] > 10 or summary_counts["test_failed"] > 0:
    overall_status = "WARNING"

# =============================================================================
# GENERATE TEXT REPORT
# =============================================================================
def generate_text_report():
    lines = []
    w = 80
    lines.append("=" * w)
    lines.append("  COMPREHENSIVE SECURITY & QUALITY REPORT".center(w))
    lines.append("=" * w)
    lines.append(f"  Pipeline:      {JOB}")
    lines.append(f"  Build:         #{BUILD_ID}")
    lines.append(f"  Date:          {TIMESTAMP}")
    lines.append(f"  Language:      {LANGUAGE}")
    lines.append(f"  Image:         {IMAGE_NAME}")
    lines.append(f"  Overall:       {overall_status}")
    lines.append("=" * w)

    # ── Section 1: Unit Tests ──
    lines.append("")
    lines.append("┌" + "─" * (w-2) + "┐")
    lines.append("│  [1] UNIT TEST RESULTS".ljust(w-1) + "│")
    lines.append("├" + "─" * (w-2) + "┤")
    s = sections["unit_tests"]
    lines.append(f"│  Status: {s['status']}".ljust(w-1) + "│")
    for d in s["details"]:
        if isinstance(d, dict) and "framework" in d:
            lines.append(f"│    Framework:  {d['framework']}".ljust(w-1) + "│")
            lines.append(f"│    Total:      {d.get('total','?')}".ljust(w-1) + "│")
            lines.append(f"│    Passed:     {d.get('passed','?')}".ljust(w-1) + "│")
            lines.append(f"│    Failed:     {d.get('failed','?')}".ljust(w-1) + "│")
            lines.append(f"│    Errors:     {d.get('errors','?')}".ljust(w-1) + "│")
            lines.append(f"│    Duration:   {d.get('duration','?')}".ljust(w-1) + "│")
    lines.append("│  Totals:".ljust(w-1) + "│")
    lines.append(f"│    Total: {summary_counts['test_total']}  Passed: {summary_counts['test_passed']}  Failed: {summary_counts['test_failed']}  Errors: {summary_counts['test_errors']}".ljust(w-1) + "│")
    lines.append("└" + "─" * (w-2) + "┘")

    # ── Section 2: Coverage ──
    lines.append("")
    lines.append("┌" + "─" * (w-2) + "┐")
    lines.append("│  [2] CODE COVERAGE".ljust(w-1) + "│")
    lines.append("├" + "─" * (w-2) + "┤")
    s = sections["coverage"]
    lines.append(f"│  Status: {s['status']}".ljust(w-1) + "│")
    for d in s["details"]:
        if isinstance(d, dict) and "percentage" in d:
            lines.append(f"│    Type:       {d.get('type','')}".ljust(w-1) + "│")
            lines.append(f"│    Coverage:   {d['percentage']}".ljust(w-1) + "│")
            lines.append(f"│    Lines:      {d.get('lines','?')}".ljust(w-1) + "│")
            lines.append(f"│    Branch:     {d.get('branch_coverage','?')}".ljust(w-1) + "│")
            lines.append(f"│    Threshold:  {d.get('threshold','?')}".ljust(w-1) + "│")
            lines.append(f"│    Gate:       {d.get('gate','?')}".ljust(w-1) + "│")
    lines.append("└" + "─" * (w-2) + "┘")

    # ── Section 3: SonarQube ──
    lines.append("")
    lines.append("┌" + "─" * (w-2) + "┐")
    lines.append("│  [3] SONARQUBE ANALYSIS".ljust(w-1) + "│")
    lines.append("├" + "─" * (w-2) + "┤")
    s = sections["sonarqube"]
    lines.append(f"│  Status: {s['status']}".ljust(w-1) + "│")
    for d in s["details"]:
        if isinstance(d, dict):
            if "quality_gate" in d:
                lines.append(f"│    Quality Gate:    {d['quality_gate']}".ljust(w-1) + "│")
                for c in d.get("conditions", []):
                    lines.append(f"│      {c['metric']:35s} {c['actual']:>8s}  (th: {c['threshold']})  [{c['status']}]".ljust(w-1) + "│")
            if "measures" in d:
                m = d["measures"]
                lines.append(f"│    Bugs:            {m.get('bugs','N/A')}".ljust(w-1) + "│")
                lines.append(f"│    Vulnerabilities:  {m.get('vulnerabilities','N/A')}".ljust(w-1) + "│")
                lines.append(f"│    Code Smells:      {m.get('code_smells','N/A')}".ljust(w-1) + "│")
                lines.append(f"│    Coverage:         {m.get('coverage','N/A')}%".ljust(w-1) + "│")
                lines.append(f"│    Duplication:      {m.get('duplicated_lines_density','N/A')}%".ljust(w-1) + "│")
                lines.append(f"│    Lines of Code:    {m.get('ncloc','N/A')}".ljust(w-1) + "│")
            if "local_quality" in d:
                for k, v in d["local_quality"].items():
                    lines.append(f"│    {k:30s}: {v}".ljust(w-1) + "│")
    lines.append("└" + "─" * (w-2) + "┘")

    # ── Section 4: Trivy ──
    lines.append("")
    lines.append("┌" + "─" * (w-2) + "┐")
    lines.append("│  [4] TRIVY SECURITY SCAN".ljust(w-1) + "│")
    lines.append("├" + "─" * (w-2) + "┤")
    s = sections["trivy"]
    lines.append(f"│  Status: {s['status']}".ljust(w-1) + "│")
    for d in s["details"]:
        if isinstance(d, dict) and "file" in d:
            lines.append(f"│  ── {d['file']} ──".ljust(w-1) + "│")
            vulns = d.get("vulnerabilities", {})
            if vulns:
                for sev in ["CRITICAL", "HIGH", "MEDIUM", "LOW"]:
                    lines.append(f"│    {sev:10s}: {vulns.get(sev, 0)}".ljust(w-1) + "│")
            misconfigs = d.get("misconfigurations", {})
            if misconfigs:
                lines.append(f"│    Misconfigurations:".ljust(w-1) + "│")
                for sev in ["CRITICAL", "HIGH", "MEDIUM", "LOW"]:
                    if misconfigs.get(sev, 0) > 0:
                        lines.append(f"│      {sev:10s}: {misconfigs[sev]}".ljust(w-1) + "│")
    lines.append("└" + "─" * (w-2) + "┘")

    # ── Section 5: Secrets ──
    lines.append("")
    lines.append("┌" + "─" * (w-2) + "┐")
    lines.append("│  [5] SECRET DETECTION".ljust(w-1) + "│")
    lines.append("├" + "─" * (w-2) + "┤")
    s = sections["secrets"]
    lines.append(f"│  Status: {s['status']}".ljust(w-1) + "│")
    lines.append(f"│  Secrets Found: {summary_counts['secrets']}".ljust(w-1) + "│")
    lines.append("└" + "─" * (w-2) + "┘")

    # ── Section 6: SBOM ──
    lines.append("")
    lines.append("┌" + "─" * (w-2) + "┐")
    lines.append("│  [6] CycloneDX SBOM".ljust(w-1) + "│")
    lines.append("├" + "─" * (w-2) + "┤")
    s = sections["sbom"]
    lines.append(f"│  Status: {s['status']}".ljust(w-1) + "│")
    for d in s["details"]:
        if isinstance(d, dict) and "file" in d:
            lines.append(f"│    {d['file']:40s}  {d.get('components',0)} components".ljust(w-1) + "│")
    lines.append(f"│  Total Components: {summary_counts['sbom_components']}".ljust(w-1) + "│")
    # List human-readable text SBOM reports
    for txt in s.get("text_reports", []):
        lines.append(f"│  [TEXT] pipeline-reports/sbom/{txt}".ljust(w-1) + "│")
    lines.append("└" + "─" * (w-2) + "┘")

    # ── Section 7: Other Reports ──
    lines.append("")
    lines.append("┌" + "─" * (w-2) + "┐")
    lines.append("│  [7] ADDITIONAL REPORTS".ljust(w-1) + "│")
    lines.append("├" + "─" * (w-2) + "┤")
    s = sections["other"]
    for d in s["details"]:
        if isinstance(d, dict) and "tool" in d:
            lines.append(f"│    {d['tool']:35s}  {d.get('total', d.get('issues',''))!s:>5s} findings".ljust(w-1) + "│")
    lines.append("└" + "─" * (w-2) + "┘")

    # ── CRITICAL/HIGH/BLOCKER Summary ──
    lines.append("")
    lines.append("=" * w)
    lines.append("  CRITICAL / HIGH / BLOCKER ISSUES SUMMARY".center(w))
    lines.append("=" * w)
    lines.append(f"  CRITICAL Vulnerabilities:   {summary_counts['critical_vulns']}")
    lines.append(f"  HIGH Vulnerabilities:       {summary_counts['high_vulns']}")
    lines.append(f"  BLOCKER Issues:             {summary_counts['blocker_issues']}")
    lines.append(f"  Secrets Detected:           {summary_counts['secrets']}")
    lines.append(f"  Misconfigs (Critical):      {summary_counts['misconfigs_critical']}")
    lines.append(f"  Misconfigs (High):          {summary_counts['misconfigs_high']}")
    lines.append("")
    lines.append(f"  Test Coverage:              {summary_counts['coverage_pct'] if summary_counts['coverage_pct'] is not None else 'N/A'}%")
    lines.append(f"  SonarQube Gate:             {summary_counts['sonar_gate']}")
    lines.append(f"  SonarQube Bugs:             {summary_counts['sonar_bugs']}")
    lines.append(f"  SonarQube Vulns:            {summary_counts['sonar_vulns']}")
    lines.append(f"  SBOM Components:            {summary_counts['sbom_components']}")
    lines.append("")

    if all_critical_issues:
        lines.append("─" * w)
        lines.append("  TOP CRITICAL/HIGH/BLOCKER ISSUES (first 50):")
        lines.append("─" * w)
        for idx, issue in enumerate(all_critical_issues[:50], 1):
            lines.append(f"  {idx:3d}. [{issue['severity']:8s}] [{issue['source']}]")
            lines.append(f"       {issue['title']}")
            if issue.get("detail"):
                lines.append(f"       {issue['detail'][:100]}")
            lines.append("")

    lines.append("=" * w)
    lines.append(f"  OVERALL STATUS:  {overall_status}".center(w))
    lines.append("=" * w)

    return "\n".join(lines)

# =============================================================================
# GENERATE HTML REPORT
# =============================================================================
def generate_html_report():
    def severity_class(sev):
        return {"CRITICAL": "critical", "HIGH": "high", "BLOCKER": "critical",
                "MEDIUM": "medium", "LOW": "low", "PASS": "pass", "FAIL": "fail"}.get(sev, "")

    def status_badge(status):
        cls = {"PASS": "badge-pass", "FAIL": "badge-fail", "WARNING": "badge-warn",
               "OK": "badge-pass", "ERROR": "badge-fail", "SKIPPED": "badge-skip",
               "GENERATED": "badge-pass", "SCANNED": "badge-pass",
               "LOCAL_ANALYSIS": "badge-warn", "AVAILABLE": "badge-pass"}.get(status, "badge-skip")
        return f'<span class="{cls}">{status}</span>'

    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Comprehensive Security & Quality Report - Build #{BUILD_ID}</title>
    <style>
        * {{ margin: 0; padding: 0; box-sizing: border-box; }}
        body {{ font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, Roboto, Arial, sans-serif; background: #0d1117; color: #c9d1d9; line-height: 1.6; padding: 20px; }}
        .container {{ max-width: 1200px; margin: 0 auto; }}
        .header {{ background: linear-gradient(135deg, #1a1a2e 0%, #16213e 50%, #0f3460 100%); padding: 30px; border-radius: 12px; margin-bottom: 24px; border: 1px solid #30363d; }}
        .header h1 {{ color: #58a6ff; font-size: 24px; margin-bottom: 8px; }}
        .header .meta {{ color: #8b949e; font-size: 14px; }}
        .header .overall {{ font-size: 20px; margin-top: 12px; }}
        .card {{ background: #161b22; border: 1px solid #30363d; border-radius: 8px; margin-bottom: 16px; overflow: hidden; }}
        .card-header {{ background: #21262d; padding: 12px 20px; border-bottom: 1px solid #30363d; display: flex; justify-content: space-between; align-items: center; }}
        .card-header h2 {{ font-size: 16px; color: #f0f6fc; }}
        .card-body {{ padding: 16px 20px; }}
        table {{ width: 100%; border-collapse: collapse; margin: 8px 0; }}
        th {{ text-align: left; padding: 8px 12px; background: #21262d; color: #8b949e; font-size: 12px; text-transform: uppercase; letter-spacing: 0.5px; }}
        td {{ padding: 8px 12px; border-bottom: 1px solid #21262d; font-size: 14px; }}
        tr:hover {{ background: #1c2128; }}
        .critical {{ color: #f85149; font-weight: 600; }}
        .high {{ color: #db6d28; font-weight: 600; }}
        .medium {{ color: #d29922; }}
        .low {{ color: #3fb950; }}
        .pass {{ color: #3fb950; }}
        .fail {{ color: #f85149; }}
        .badge-pass {{ background: #238636; color: #fff; padding: 2px 8px; border-radius: 12px; font-size: 12px; font-weight: 600; }}
        .badge-fail {{ background: #da3633; color: #fff; padding: 2px 8px; border-radius: 12px; font-size: 12px; font-weight: 600; }}
        .badge-warn {{ background: #9e6a03; color: #fff; padding: 2px 8px; border-radius: 12px; font-size: 12px; font-weight: 600; }}
        .badge-skip {{ background: #484f58; color: #8b949e; padding: 2px 8px; border-radius: 12px; font-size: 12px; }}
        .summary-grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 12px; margin: 16px 0; }}
        .summary-item {{ background: #21262d; padding: 16px; border-radius: 8px; text-align: center; }}
        .summary-item .value {{ font-size: 28px; font-weight: 700; }}
        .summary-item .label {{ font-size: 12px; color: #8b949e; margin-top: 4px; }}
        .issue-list {{ list-style: none; }}
        .issue-list li {{ padding: 8px 12px; border-left: 3px solid; margin-bottom: 4px; background: #1c2128; }}
        .issue-list li.sev-CRITICAL, .issue-list li.sev-BLOCKER {{ border-color: #f85149; }}
        .issue-list li.sev-HIGH {{ border-color: #db6d28; }}
        .issue-list li.sev-MEDIUM {{ border-color: #d29922; }}
        .issue-tag {{ font-size: 11px; padding: 1px 6px; border-radius: 4px; margin-right: 6px; }}
        .issue-source {{ color: #8b949e; font-size: 12px; }}
        .progress-bar {{ background: #21262d; border-radius: 4px; height: 8px; overflow: hidden; margin-top: 4px; }}
        .progress-fill {{ height: 100%; border-radius: 4px; }}
        .collapsible {{ cursor: pointer; }}
        .collapsible:after {{ content: ' ▼'; font-size: 10px; }}
        pre {{ background: #0d1117; border: 1px solid #30363d; padding: 12px; border-radius: 6px; overflow-x: auto; font-size: 13px; }}
    </style>
</head>
<body>
<div class="container">
    <div class="header">
        <h1>Comprehensive Security & Quality Report</h1>
        <div class="meta">
            Pipeline: {JOB} | Build: #{BUILD_ID} | Date: {TIMESTAMP} | Language: {LANGUAGE} | Image: {IMAGE_NAME}
        </div>
        <div class="overall">
            Overall Status: {status_badge(overall_status)}
        </div>
    </div>

    <!-- EXECUTIVE SUMMARY -->
    <div class="card">
        <div class="card-header"><h2>Executive Summary</h2></div>
        <div class="card-body">
            <div class="summary-grid">
                <div class="summary-item">
                    <div class="value {'critical' if summary_counts['critical_vulns'] > 0 else 'pass'}">{summary_counts['critical_vulns']}</div>
                    <div class="label">CRITICAL Vulns</div>
                </div>
                <div class="summary-item">
                    <div class="value {'high' if summary_counts['high_vulns'] > 0 else 'pass'}">{summary_counts['high_vulns']}</div>
                    <div class="label">HIGH Vulns</div>
                </div>
                <div class="summary-item">
                    <div class="value {'critical' if summary_counts['blocker_issues'] > 0 else 'pass'}">{summary_counts['blocker_issues']}</div>
                    <div class="label">BLOCKER Issues</div>
                </div>
                <div class="summary-item">
                    <div class="value {'critical' if summary_counts['secrets'] > 0 else 'pass'}">{summary_counts['secrets']}</div>
                    <div class="label">Secrets Found</div>
                </div>
                <div class="summary-item">
                    <div class="value">{summary_counts['coverage_pct'] if summary_counts['coverage_pct'] is not None else 'N/A'}</div>
                    <div class="label">Coverage %</div>
                    <div class="progress-bar"><div class="progress-fill" style="width: {summary_counts['coverage_pct'] or 0}%; background: {'#3fb950' if (summary_counts['coverage_pct'] or 0) >= COVERAGE_THRESHOLD else '#f85149'};"></div></div>
                </div>
                <div class="summary-item">
                    <div class="value">{summary_counts['sonar_gate']}</div>
                    <div class="label">SonarQube Gate</div>
                </div>
                <div class="summary-item">
                    <div class="value">{summary_counts['test_passed']}/{summary_counts['test_total']}</div>
                    <div class="label">Tests Passed</div>
                </div>
                <div class="summary-item">
                    <div class="value">{summary_counts['sbom_components']}</div>
                    <div class="label">SBOM Components</div>
                </div>
            </div>
        </div>
    </div>
"""

    # ── Section cards ──
    for key in ["unit_tests", "coverage", "sonarqube", "trivy", "secrets", "sbom", "other"]:
        s = sections[key]
        html += f"""
    <div class="card">
        <div class="card-header">
            <h2>{s['title']}</h2>
            {status_badge(s['status'])}
        </div>
        <div class="card-body">
"""
        if key == "unit_tests":
            html += "<table><tr><th>Framework</th><th>Total</th><th>Passed</th><th>Failed</th><th>Errors</th><th>Duration</th></tr>"
            for d in s["details"]:
                if isinstance(d, dict) and "framework" in d:
                    fail_cls = "fail" if d.get("failed", 0) > 0 else ""
                    html += f"<tr><td>{d['framework']}</td><td>{d.get('total','?')}</td><td class='pass'>{d.get('passed','?')}</td><td class='{fail_cls}'>{d.get('failed','?')}</td><td>{d.get('errors','?')}</td><td>{d.get('duration','?')}</td></tr>"
            html += "</table>"

        elif key == "coverage":
            for d in s["details"]:
                if isinstance(d, dict) and "percentage" in d:
                    pct = float(d["percentage"].rstrip("%"))
                    color = "#3fb950" if pct >= COVERAGE_THRESHOLD else "#f85149"
                    html += f"""
                    <table><tr><th>Metric</th><th>Value</th></tr>
                    <tr><td>Type</td><td>{d.get('type','')}</td></tr>
                    <tr><td>Coverage</td><td><strong style="color: {color}">{d['percentage']}</strong></td></tr>
                    <tr><td>Lines</td><td>{d.get('lines','?')}</td></tr>
                    <tr><td>Branch Coverage</td><td>{d.get('branch_coverage','?')}</td></tr>
                    <tr><td>Threshold</td><td>{d.get('threshold','?')}</td></tr>
                    <tr><td>Gate</td><td>{status_badge(d.get('gate','?'))}</td></tr>
                    </table>
                    <div class="progress-bar" style="height:12px"><div class="progress-fill" style="width:{pct}%; background:{color}"></div></div>
                    """

        elif key == "sonarqube":
            for d in s["details"]:
                if isinstance(d, dict):
                    if "quality_gate" in d:
                        html += f"<p><strong>Quality Gate:</strong> {status_badge(d['quality_gate'])}</p>"
                        if d.get("conditions"):
                            html += "<table><tr><th>Metric</th><th>Actual</th><th>Threshold</th><th>Status</th></tr>"
                            for c in d["conditions"]:
                                html += f"<tr><td>{c['metric']}</td><td>{c['actual']}</td><td>{c['threshold']}</td><td>{status_badge(c['status'])}</td></tr>"
                            html += "</table>"
                    if "measures" in d:
                        m = d["measures"]
                        html += "<table><tr><th>Metric</th><th>Value</th></tr>"
                        for mk, mv in m.items():
                            html += f"<tr><td>{mk}</td><td>{mv}</td></tr>"
                        html += "</table>"
                    if "local_quality" in d:
                        html += "<table><tr><th>Metric</th><th>Value</th></tr>"
                        for lk, lv in d["local_quality"].items():
                            html += f"<tr><td>{lk}</td><td>{lv}</td></tr>"
                        html += "</table>"

        elif key == "trivy":
            html += "<table><tr><th>Report</th><th>CRITICAL</th><th>HIGH</th><th>MEDIUM</th><th>LOW</th><th>Misconfigs</th></tr>"
            for d in s["details"]:
                if isinstance(d, dict) and "file" in d:
                    v = d.get("vulnerabilities", {})
                    m = d.get("misconfigurations", {})
                    html += f"""<tr>
                        <td>{d['file']}</td>
                        <td class='critical'>{v.get('CRITICAL',0)}</td>
                        <td class='high'>{v.get('HIGH',0)}</td>
                        <td class='medium'>{v.get('MEDIUM',0)}</td>
                        <td class='low'>{v.get('LOW',0)}</td>
                        <td>{sum(m.values()) if m else 0}</td>
                    </tr>"""
            html += "</table>"

        elif key == "secrets":
            count = summary_counts["secrets"]
            html += f"<p>Secrets Found: <strong class='{'critical' if count > 0 else 'pass'}'>{count}</strong></p>"

        elif key == "sbom":
            html += "<table><tr><th>SBOM File</th><th>Format</th><th>Spec</th><th>Components</th></tr>"
            for d in s["details"]:
                if isinstance(d, dict) and "file" in d:
                    html += f"<tr><td>{d['file']}</td><td>{d.get('format','?')}</td><td>{d.get('spec','?')}</td><td>{d.get('components',0)}</td></tr>"
            html += f"</table><p>Total Components: <strong>{summary_counts['sbom_components']}</strong></p>"

        elif key == "other":
            html += "<table><tr><th>Tool</th><th>Findings</th><th>Details</th></tr>"
            for d in s["details"]:
                if isinstance(d, dict) and "tool" in d:
                    findings = d.get("total", d.get("issues", "N/A"))
                    details = str(d.get("findings", ""))[:100]
                    html += f"<tr><td>{d['tool']}</td><td>{findings}</td><td>{details}</td></tr>"
            html += "</table>"

        html += "</div></div>"

    # ── Critical Issues List ──
    if all_critical_issues:
        html += """
    <div class="card">
        <div class="card-header"><h2>All CRITICAL / HIGH / BLOCKER Issues</h2></div>
        <div class="card-body">
            <ul class="issue-list">
"""
        for issue in all_critical_issues[:100]:
            sev = issue["severity"]
            html += f"""<li class="sev-{sev}">
                <span class="issue-tag badge-{'fail' if sev in ('CRITICAL','BLOCKER') else 'warn'}">{sev}</span>
                <strong>{issue['title'][:150]}</strong>
                <span class="issue-source">[{issue['source']}]</span>
                {'<br><small>' + issue['detail'][:200] + '</small>' if issue.get("detail") else ''}
            </li>"""
        html += "</ul></div></div>"

    html += """
    <div class="card">
        <div class="card-header"><h2>Report Files</h2></div>
        <div class="card-body"><pre>"""

    # List report files
    for root, dirs, files in os.walk(REPORTS_DIR):
        for fname in sorted(files):
            fpath = os.path.join(root, fname)
            rel = os.path.relpath(fpath, REPORTS_DIR)
            try:
                size = os.path.getsize(fpath)
                size_str = f"{size/1024:.1f}KB" if size > 1024 else f"{size}B"
            except:
                size_str = "?"
            html += f"{rel:55s}  {size_str}\n"

    html += f"""</pre></div></div>

    <div style="text-align:center; color:#484f58; padding:20px; font-size:12px;">
        Generated by Jenkins DevSecOps Pipeline | {TIMESTAMP}
    </div>
</div>
</body>
</html>"""

    return html

# =============================================================================
# WRITE REPORTS
# =============================================================================
text_report = generate_text_report()
html_report = generate_html_report()

txt_path = os.path.join(REPORTS_DIR, "comprehensive-report.txt")
html_path = os.path.join(REPORTS_DIR, "comprehensive-report.html")

with open(txt_path, "w") as f:
    f.write(text_report)

with open(html_path, "w") as f:
    f.write(html_report)

# Also save JSON summary
json_path = os.path.join(REPORTS_DIR, "comprehensive-report.json")
with open(json_path, "w") as f:
    json.dump({
        "overall_status": overall_status,
        "summary": summary_counts,
        "sections": {k: {"title": v["title"], "status": v["status"]} for k, v in sections.items()},
        "critical_issues_count": len(all_critical_issues),
        "top_issues": all_critical_issues[:50]
    }, f, indent=2, default=str)

# Print text report to console
print(text_report)

COMPREHENSIVE_REPORT_EOF

echo ""
echo "=== Comprehensive Report Generated ==="
echo "  HTML: ${REPORT_HTML}"
echo "  Text: ${REPORT_TEXT}"
echo "  JSON: ${REPORTS_DIR}/comprehensive-report.json"
