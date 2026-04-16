#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import uuid
import xml.etree.ElementTree as ET
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any


SEVERITIES = ("CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN")
SUPPORTED_ADAPTERS = ["python", "java", "node-react", "c-cpp", "kotlin", "html-static"]


@dataclass
class PhaseRecord:
    name: str
    status: str
    started_at: str
    ended_at: str
    duration_ms: int
    details: dict[str, Any]


class UnifiedScan:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        now = dt.datetime.utcnow()
        self.scan_id = args.scan_id or f"prepush-{now.strftime('%Y%m%d%H%M%S')}-{uuid.uuid4().hex[:8]}"
        stamp = now.strftime("%Y%m%d_%H%M%S")
        self.output_dir = Path(args.output_dir).resolve() / f"scan-{stamp}-{self.scan_id}"
        self.output_dir.mkdir(parents=True, exist_ok=True)

        self.phase_log_file = self.output_dir / "phase-state.jsonl"
        self.metadata_file = self.output_dir / "scan-metadata.json"
        self.summary_file = self.output_dir / "final-report.json"
        self.summary_md_file = self.output_dir / "final-report.md"

        self.warnings: list[str] = []
        self.phase_records: list[PhaseRecord] = []
        self.adapters: list[str] = []
        self.test_summary: dict[str, Any] = {
            "total": 0,
            "passed": 0,
            "failed": 0,
            "errors": 0,
            "frameworks": [],
        }
        self.coverage_summary: dict[str, Any] = {
            "overall_percent": None,
            "normalized_by_adapter": {},
            "missing": [],
        }
        self.tool_status: dict[str, dict[str, Any]] = {}
        self.findings_by_tool: dict[str, dict[str, int]] = {}
        self.traceability: dict[str, str] = {}

    def _log(self, message: str) -> None:
        print(message, flush=True)

    def _run(self, cmd: list[str], cwd: Path | None = None, allow_fail: bool = False) -> subprocess.CompletedProcess:
        proc = subprocess.run(
            cmd,
            cwd=str(cwd or Path.cwd()),
            text=True,
            capture_output=True,
            check=False,
        )
        if proc.returncode != 0 and not allow_fail:
            raise RuntimeError(f"Command failed ({proc.returncode}): {' '.join(cmd)}\n{proc.stderr}")
        return proc

    def _which(self, binary: str) -> str | None:
        return shutil.which(binary)

    def _phase(self, name: str, fn):
        start = dt.datetime.utcnow()
        status = "PASS"
        details: dict[str, Any] = {}
        try:
            details = fn() or {}
        except Exception as exc:
            status = "FAIL"
            details = {"error": str(exc)}
            if self.args.strict:
                self._record_phase(name, status, start, dt.datetime.utcnow(), details)
                raise
            self.warnings.append(f"{name} failed: {exc}")
            status = "DEGRADED"
        end = dt.datetime.utcnow()
        self._record_phase(name, status, start, end, details)
        if name == "aggregate":
            self._sync_report_phase_status()

    def _record_phase(self, name: str, status: str, start: dt.datetime, end: dt.datetime, details: dict[str, Any]) -> None:
        rec = PhaseRecord(
            name=name,
            status=status,
            started_at=start.isoformat() + "Z",
            ended_at=end.isoformat() + "Z",
            duration_ms=int((end - start).total_seconds() * 1000),
            details=details,
        )
        self.phase_records.append(rec)
        with self.phase_log_file.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(asdict(rec), ensure_ascii=False) + "\n")

    def _sync_report_phase_status(self) -> None:
        if not self.summary_file.exists():
            return
        try:
            payload = json.loads(self.summary_file.read_text(encoding="utf-8"))
            payload["phase_status"] = [asdict(x) for x in self.phase_records]
            self.summary_file.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        except Exception as exc:
            self.warnings.append(f"Could not sync aggregate phase into final report: {exc}")

    def run(self) -> int:
        self._log(f"[UnifiedScan] scan_id={self.scan_id}")
        self._phase("detect", self.phase_detect)
        self._phase("test", self.phase_test)
        self._phase("coverage", self.phase_coverage)
        self._phase("security", self.phase_security)
        self._phase("aggregate", self.phase_aggregate)

        verdict = self._compute_gate_verdict()
        self._log(f"[UnifiedScan] gate={verdict['status']}")

        if verdict["status"] == "FAIL":
            return 2
        return 0

    def phase_detect(self) -> dict[str, Any]:
        root = Path(self.args.path).resolve()
        adapters: list[str] = []
        signals: dict[str, list[str]] = {}

        py_signals = ["requirements.txt", "pyproject.toml", "setup.py", "Pipfile"]
        if any((root / p).exists() for p in py_signals):
            adapters.append("python")
            signals["python"] = [p for p in py_signals if (root / p).exists()]

        java_signals = ["pom.xml", "build.gradle", "build.gradle.kts"]
        if any((root / p).exists() for p in java_signals):
            adapters.append("java")
            signals["java"] = [p for p in java_signals if (root / p).exists()]

        if (root / "package.json").exists():
            package_text = (root / "package.json").read_text(encoding="utf-8", errors="ignore")
            adapters.append("node-react")
            signals["node-react"] = ["package.json"]
            if "react" in package_text.lower():
                signals["node-react"].append("react-dependency")

        cpp_signals = ["CMakeLists.txt", "Makefile", "makefile"]
        if any((root / p).exists() for p in cpp_signals):
            has_c_cpp_src = any(root.rglob("*.c")) or any(root.rglob("*.cpp")) or any(root.rglob("*.cc"))
            if has_c_cpp_src:
                adapters.append("c-cpp")
                signals["c-cpp"] = [p for p in cpp_signals if (root / p).exists()]

        kotlin_signals = ["build.gradle.kts", "settings.gradle.kts"]
        if any((root / p).exists() for p in kotlin_signals) or any(root.rglob("*.kt")):
            adapters.append("kotlin")
            signals["kotlin"] = [p for p in kotlin_signals if (root / p).exists()] or ["*.kt"]

        html_signals = ["index.html"]
        has_html = any((root / p).exists() for p in html_signals) or any(root.rglob("*.html"))
        if has_html:
            adapters.append("html-static")
            signals["html-static"] = ["index.html"] if (root / "index.html").exists() else ["*.html"]

        # Stable order, deduplicated
        dedup: list[str] = []
        for adapter in SUPPORTED_ADAPTERS:
            if adapter in adapters and adapter not in dedup:
                dedup.append(adapter)

        if not dedup:
            self.warnings.append("No supported adapter detected. Running in degraded mode.")

        self.adapters = dedup

        metadata = {
            "scan_id": self.scan_id,
            "generated_at": dt.datetime.utcnow().isoformat() + "Z",
            "mode": self.args.mode,
            "strict": self.args.strict,
            "project_root": str(root),
            "adapters": self.adapters,
            "signals": signals,
            "supported_adapters": SUPPORTED_ADAPTERS,
        }
        self.metadata_file.write_text(json.dumps(metadata, indent=2), encoding="utf-8")
        return {"adapters": self.adapters, "signals": signals, "metadata_file": str(self.metadata_file)}

    def _tests_path_candidates(self, root: Path) -> list[Path]:
        names = ["tests", "test", "src/test", "src/tests", "__tests__", "spec"]
        paths = [root / n for n in names if (root / n).exists()]
        return paths

    def phase_test(self) -> dict[str, Any]:
        root = Path(self.args.path).resolve()
        results: dict[str, Any] = {}

        if not self.adapters:
            self.warnings.append("Skipping tests because no adapter was detected.")
            return {"skipped": True}

        for adapter in self.adapters:
            adapter_dir = self.output_dir / adapter
            adapter_dir.mkdir(parents=True, exist_ok=True)
            if adapter == "python":
                results[adapter] = self._run_python_tests(root, adapter_dir)
            elif adapter == "java":
                results[adapter] = self._run_java_tests(root, adapter_dir)
            elif adapter == "node-react":
                results[adapter] = self._run_node_tests(root, adapter_dir)
            elif adapter == "c-cpp":
                results[adapter] = self._run_cpp_tests(root, adapter_dir)
            elif adapter == "kotlin":
                results[adapter] = self._run_kotlin_tests(root, adapter_dir)
            elif adapter == "html-static":
                msg = "No native test runner required for html-static adapter"
                self.warnings.append(msg)
                results[adapter] = {"status": "SKIPPED", "reason": msg}

        return results

    def _accumulate_junit(self, xml_path: Path, framework: str) -> dict[str, int]:
        if not xml_path.exists():
            return {"total": 0, "failed": 0, "errors": 0, "passed": 0}
        tree = ET.parse(xml_path)
        root = tree.getroot()
        suites = [root] if root.tag in {"testsuite", "testsuites"} else list(root)
        total = failed = errors = skipped = 0
        for suite in suites:
            total += int(suite.attrib.get("tests", 0))
            failed += int(suite.attrib.get("failures", 0))
            errors += int(suite.attrib.get("errors", 0))
            skipped += int(suite.attrib.get("skipped", 0))
        passed = max(total - failed - errors - skipped, 0)
        self.test_summary["total"] += total
        self.test_summary["failed"] += failed
        self.test_summary["errors"] += errors
        self.test_summary["passed"] += passed
        self.test_summary["frameworks"].append(framework)
        return {"total": total, "failed": failed, "errors": errors, "passed": passed}

    def _run_python_tests(self, root: Path, out: Path) -> dict[str, Any]:
        candidates = self._tests_path_candidates(root)
        if not candidates and not list(root.rglob("test_*.py")) and not list(root.rglob("*_test.py")):
            warning = "Python adapter detected but no test folders/files found"
            self.warnings.append(warning)
            return {"status": "DEGRADED", "warning": warning}

        pytest_cfg = any((root / name).exists() for name in ["pytest.ini", "pyproject.toml", "tox.ini", "setup.cfg"])
        junit_path = out / "pytest-results.xml"
        coverage_path = out / "coverage.xml"

        if pytest_cfg and self._which("pytest"):
            cmd = [
                "pytest",
                str(root),
                "-q",
                f"--junitxml={junit_path}",
            ]
            if self._which("coverage"):
                cmd = [
                    "coverage",
                    "run",
                    "-m",
                    "pytest",
                    str(root),
                    "-q",
                    f"--junitxml={junit_path}",
                ]
            proc = self._run(cmd, cwd=root, allow_fail=True)
            if self._which("coverage"):
                self._run(["coverage", "xml", "-o", str(coverage_path)], cwd=root, allow_fail=True)
            (out / "pytest.stdout.log").write_text(proc.stdout or "", encoding="utf-8")
            (out / "pytest.stderr.log").write_text(proc.stderr or "", encoding="utf-8")
            stats = self._accumulate_junit(junit_path, "pytest")
            return {"status": "PASS" if proc.returncode == 0 else "FAIL", "framework": "pytest", "stats": stats, "junit": str(junit_path)}

        # fallback: unittest discovery
        unittest_xml = out / "unittest-results.xml"
        cmd = [sys.executable, "-m", "unittest", "discover", "-s", "tests", "-v"] if (root / "tests").exists() else [sys.executable, "-m", "unittest", "discover", "-v"]
        proc = self._run(cmd, cwd=root, allow_fail=True)
        (out / "unittest.stdout.log").write_text(proc.stdout or "", encoding="utf-8")
        (out / "unittest.stderr.log").write_text(proc.stderr or "", encoding="utf-8")

        # best-effort parse for totals
        total = 0
        failed = 0
        errors = 0
        m = re.search(r"Ran\s+(\d+)\s+tests?", (proc.stdout or "") + "\n" + (proc.stderr or ""))
        if m:
            total = int(m.group(1))
        failed += len(re.findall(r"FAIL:", proc.stdout or "")) + len(re.findall(r"FAIL:", proc.stderr or ""))
        errors += len(re.findall(r"ERROR:", proc.stdout or "")) + len(re.findall(r"ERROR:", proc.stderr or ""))
        passed = max(total - failed - errors, 0)
        self.test_summary["total"] += total
        self.test_summary["failed"] += failed
        self.test_summary["errors"] += errors
        self.test_summary["passed"] += passed
        self.test_summary["frameworks"].append("unittest")

        if self._which("coverage"):
            self._run(["coverage", "run", "-m", "unittest", "discover"], cwd=root, allow_fail=True)
            self._run(["coverage", "xml", "-o", str(out / "coverage.xml")], cwd=root, allow_fail=True)

        return {
            "status": "PASS" if proc.returncode == 0 else "FAIL",
            "framework": "unittest",
            "stats": {"total": total, "failed": failed, "errors": errors, "passed": passed},
            "junit": str(unittest_xml),
        }

    def _run_java_tests(self, root: Path, out: Path) -> dict[str, Any]:
        if not (root / "src/test").exists() and not list(root.rglob("*Test.java")):
            warning = "Java adapter detected but no src/test or *Test.java found"
            self.warnings.append(warning)
            return {"status": "DEGRADED", "warning": warning}

        if (root / "pom.xml").exists() and self._which("mvn"):
            proc = self._run(["mvn", "-B", "test", "-Dmaven.test.failure.ignore=true"], cwd=root, allow_fail=True)
            (out / "maven-test.stdout.log").write_text(proc.stdout or "", encoding="utf-8")
            (out / "maven-test.stderr.log").write_text(proc.stderr or "", encoding="utf-8")
            for report in root.glob("target/surefire-reports/TEST-*.xml"):
                shutil.copy2(report, out / report.name)
            jacoco = root / "target/site/jacoco/jacoco.xml"
            if jacoco.exists():
                shutil.copy2(jacoco, out / "jacoco-coverage.xml")
            return {"status": "PASS" if proc.returncode == 0 else "FAIL", "runner": "maven"}

        if (root / "build.gradle").exists() or (root / "build.gradle.kts").exists():
            gradle = "./gradlew" if (root / "gradlew").exists() else "gradle"
            if self._which(gradle) or gradle == "./gradlew":
                proc = self._run([gradle, "test", "--continue"], cwd=root, allow_fail=True)
                (out / "gradle-test.stdout.log").write_text(proc.stdout or "", encoding="utf-8")
                (out / "gradle-test.stderr.log").write_text(proc.stderr or "", encoding="utf-8")
                for report in root.glob("build/test-results/test/*.xml"):
                    shutil.copy2(report, out / report.name)
                jacoco = root / "build/reports/jacoco/test/jacocoTestReport.xml"
                if jacoco.exists():
                    shutil.copy2(jacoco, out / "jacoco-coverage.xml")
                return {"status": "PASS" if proc.returncode == 0 else "FAIL", "runner": "gradle"}

        self.warnings.append("Java tests skipped because maven/gradle was not available")
        return {"status": "DEGRADED", "warning": "No java test runner available"}

    def _run_node_tests(self, root: Path, out: Path) -> dict[str, Any]:
        if not (root / "package.json").exists():
            return {"status": "SKIPPED", "reason": "package.json missing"}
        if not self._which("npm"):
            self.warnings.append("Node adapter detected but npm not available")
            return {"status": "DEGRADED", "warning": "npm unavailable"}

        proc = self._run(["npm", "test", "--", "--coverage"], cwd=root, allow_fail=True)
        (out / "npm-test.stdout.log").write_text(proc.stdout or "", encoding="utf-8")
        (out / "npm-test.stderr.log").write_text(proc.stderr or "", encoding="utf-8")

        lcov = root / "coverage/lcov.info"
        if lcov.exists():
            shutil.copy2(lcov, out / "lcov.info")
        return {"status": "PASS" if proc.returncode == 0 else "FAIL", "runner": "npm"}

    def _run_cpp_tests(self, root: Path, out: Path) -> dict[str, Any]:
        if not (root / "CMakeLists.txt").exists():
            self.warnings.append("C/C++ adapter detected without CMakeLists.txt; test execution skipped")
            return {"status": "DEGRADED", "warning": "No CMakeLists.txt"}
        if not self._which("cmake"):
            self.warnings.append("C/C++ adapter detected but cmake not available")
            return {"status": "DEGRADED", "warning": "cmake unavailable"}

        build_dir = out / "cmake-build"
        build_dir.mkdir(parents=True, exist_ok=True)
        self._run(["cmake", str(root)], cwd=build_dir, allow_fail=True)
        self._run(["cmake", "--build", "."], cwd=build_dir, allow_fail=True)
        proc = self._run(["ctest", "--output-on-failure"], cwd=build_dir, allow_fail=True)
        (out / "ctest.stdout.log").write_text(proc.stdout or "", encoding="utf-8")
        (out / "ctest.stderr.log").write_text(proc.stderr or "", encoding="utf-8")
        return {"status": "PASS" if proc.returncode == 0 else "FAIL", "runner": "ctest"}

    def _run_kotlin_tests(self, root: Path, out: Path) -> dict[str, Any]:
        gradle = "./gradlew" if (root / "gradlew").exists() else "gradle"
        if not (root / "build.gradle.kts").exists() and not any(root.rglob("*.kt")):
            return {"status": "SKIPPED", "reason": "no kotlin signals"}
        if not self._which(gradle) and gradle != "./gradlew":
            self.warnings.append("Kotlin adapter detected but gradle not available")
            return {"status": "DEGRADED", "warning": "gradle unavailable"}

        proc = self._run([gradle, "test", "--continue"], cwd=root, allow_fail=True)
        (out / "kotlin-test.stdout.log").write_text(proc.stdout or "", encoding="utf-8")
        (out / "kotlin-test.stderr.log").write_text(proc.stderr or "", encoding="utf-8")
        return {"status": "PASS" if proc.returncode == 0 else "FAIL", "runner": "gradle"}

    def phase_coverage(self) -> dict[str, Any]:
        by_adapter: dict[str, Any] = {}
        for adapter in self.adapters:
            adapter_dir = self.output_dir / adapter
            if adapter == "python":
                cov = adapter_dir / "coverage.xml"
                if cov.exists():
                    pct = self._parse_cobertura_percent(cov)
                    by_adapter[adapter] = {"overall_percent": pct, "artifact": str(cov)}
                    self.traceability[f"coverage:{adapter}"] = str(cov)
                else:
                    self.coverage_summary["missing"].append(adapter)
            elif adapter in {"java", "kotlin"}:
                jacoco = adapter_dir / "jacoco-coverage.xml"
                if jacoco.exists():
                    pct = self._parse_jacoco_percent(jacoco)
                    by_adapter[adapter] = {"overall_percent": pct, "artifact": str(jacoco)}
                    self.traceability[f"coverage:{adapter}"] = str(jacoco)
                else:
                    self.coverage_summary["missing"].append(adapter)
            elif adapter == "node-react":
                lcov = adapter_dir / "lcov.info"
                if lcov.exists():
                    pct = self._parse_lcov_percent(lcov)
                    by_adapter[adapter] = {"overall_percent": pct, "artifact": str(lcov)}
                    self.traceability[f"coverage:{adapter}"] = str(lcov)
                else:
                    self.coverage_summary["missing"].append(adapter)
            else:
                self.coverage_summary["missing"].append(adapter)

        self.coverage_summary["normalized_by_adapter"] = by_adapter
        pcts = [v.get("overall_percent") for v in by_adapter.values() if v.get("overall_percent") is not None]
        self.coverage_summary["overall_percent"] = round(sum(pcts) / len(pcts), 1) if pcts else None

        if self.coverage_summary["missing"]:
            self.warnings.append(
                "Coverage unavailable for adapters: " + ", ".join(sorted(set(self.coverage_summary["missing"])))
            )

        return self.coverage_summary

    def _parse_cobertura_percent(self, xml_path: Path) -> float | None:
        try:
            root = ET.parse(xml_path).getroot()
            line_rate = root.attrib.get("line-rate")
            if line_rate is None:
                return None
            return round(float(line_rate) * 100, 1)
        except Exception:
            return None

    def _parse_jacoco_percent(self, xml_path: Path) -> float | None:
        try:
            root = ET.parse(xml_path).getroot()
            for counter in root.findall(".//counter"):
                if counter.attrib.get("type") == "LINE":
                    missed = int(counter.attrib.get("missed", 0))
                    covered = int(counter.attrib.get("covered", 0))
                    total = missed + covered
                    return round((covered / total) * 100, 1) if total else 0.0
        except Exception:
            return None
        return None

    def _parse_lcov_percent(self, path: Path) -> float | None:
        try:
            lf = lh = 0
            for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
                if line.startswith("LF:"):
                    lf += int(line.split(":", 1)[1])
                elif line.startswith("LH:"):
                    lh += int(line.split(":", 1)[1])
            return round((lh / lf) * 100, 1) if lf else None
        except Exception:
            return None

    def phase_security(self) -> dict[str, Any]:
        root = Path(self.args.path).resolve()
        sec_dir = self.output_dir / "security"
        sec_dir.mkdir(parents=True, exist_ok=True)

        required_tools = ["trivy"] if self.args.run_trivy else []
        optional_tools = ["sonar-scanner"]
        for tool in required_tools + optional_tools:
            self.tool_status[tool] = {
                "available": bool(self._which(tool)),
                "required": tool in required_tools,
            }

        missing_required = [k for k, v in self.tool_status.items() if v["required"] and not v["available"]]
        if missing_required:
            raise RuntimeError(f"Missing required tool(s): {', '.join(missing_required)}")

        missing_optional = [k for k, v in self.tool_status.items() if not v["required"] and not v["available"]]
        if missing_optional:
            self.warnings.append("Missing optional tools: " + ", ".join(missing_optional))

        mode = self.args.mode
        if self.args.run_trivy:
            if mode in {"code-only", "full", "k8s-manifests"}:
                fs_json = sec_dir / "trivy-fs.json"
                cfg_json = sec_dir / "trivy-config.json"
                self._run([
                    "trivy", "fs", "--scanners", "vuln,misconfig", "--severity", self.args.severity,
                    "--format", "json", "--output", str(fs_json), str(root)
                ], allow_fail=True)
                self._run([
                    "trivy", "config", "--severity", self.args.severity,
                    "--format", "json", "--output", str(cfg_json), str(root)
                ], allow_fail=True)
                self._collect_trivy_counts("trivy-fs", fs_json)
                self._collect_trivy_counts("trivy-config", cfg_json)
                self.traceability["security:trivy-fs"] = str(fs_json)
                self.traceability["security:trivy-config"] = str(cfg_json)

            if mode in {"image-only", "full"} and self.args.image_name:
                image = f"{self.args.registry}/{self.args.image_name}:{self.args.image_tag}"
                img_json = sec_dir / "trivy-image.json"
                self._run([
                    "trivy", "image", "--severity", self.args.severity,
                    "--format", "json", "--output", str(img_json), image
                ], allow_fail=True)
                self._collect_trivy_counts("trivy-image", img_json)
                self.traceability["security:trivy-image"] = str(img_json)

            if self.args.generate_sbom and mode in {"code-only", "full", "k8s-manifests"}:
                sbom_cdx = sec_dir / "sbom-cyclonedx.json"
                sbom_spdx = sec_dir / "sbom-spdx.json"
                self._run(["trivy", "fs", "--format", "cyclonedx", "--output", str(sbom_cdx), str(root)], allow_fail=True)
                self._run(["trivy", "fs", "--format", "spdx-json", "--output", str(sbom_spdx), str(root)], allow_fail=True)
                self.traceability["sbom:cyclonedx"] = str(sbom_cdx)
                self.traceability["sbom:spdx"] = str(sbom_spdx)

        if self.args.run_sonar:
            self._run_sonar(sec_dir)

        return {
            "tool_status": self.tool_status,
            "findings_by_tool": self.findings_by_tool,
            "traceability": self.traceability,
        }

    def _run_sonar(self, sec_dir: Path) -> None:
        if not self._which("sonar-scanner"):
            self.warnings.append("SonarQube scanner unavailable; skipped Sonar phase")
            return
        if not self.args.sonar_host_url or not self.args.sonar_token:
            self.warnings.append("SonarQube host/token not provided; skipped Sonar phase")
            return

        report = sec_dir / "sonar-report-task.txt"
        cmd = [
            "sonar-scanner",
            f"-Dsonar.host.url={self.args.sonar_host_url}",
            f"-Dsonar.login={self.args.sonar_token}",
            f"-Dsonar.projectKey={self.args.sonar_project_key or self.scan_id}",
            f"-Dsonar.projectBaseDir={str(Path(self.args.path).resolve())}",
        ]
        proc = self._run(cmd, allow_fail=True)
        report.write_text((proc.stdout or "") + "\n" + (proc.stderr or ""), encoding="utf-8")
        self.traceability["security:sonarqube"] = str(report)

    def _collect_trivy_counts(self, key: str, json_file: Path) -> None:
        totals = {s: 0 for s in SEVERITIES}
        if not json_file.exists():
            self.findings_by_tool[key] = totals
            return
        try:
            payload = json.loads(json_file.read_text(encoding="utf-8"))
            for result in payload.get("Results", []):
                for vuln in result.get("Vulnerabilities") or []:
                    sev = (vuln.get("Severity") or "UNKNOWN").upper()
                    totals[sev if sev in totals else "UNKNOWN"] += 1
                for mis in result.get("Misconfigurations") or []:
                    sev = (mis.get("Severity") or "UNKNOWN").upper()
                    totals[sev if sev in totals else "UNKNOWN"] += 1
                for secret in result.get("Secrets") or []:
                    sev = (secret.get("Severity") or "HIGH").upper()
                    totals[sev if sev in totals else "UNKNOWN"] += 1
        except Exception as exc:
            self.warnings.append(f"Could not parse Trivy output {json_file.name}: {exc}")
        self.findings_by_tool[key] = totals

    def _aggregate_findings(self) -> dict[str, int]:
        total = {s: 0 for s in SEVERITIES}
        for counts in self.findings_by_tool.values():
            for sev, value in counts.items():
                total[sev] += int(value)
        return total

    def _compute_gate_verdict(self) -> dict[str, Any]:
        findings = self._aggregate_findings()
        failed_tests = self.test_summary["failed"] + self.test_summary["errors"]
        coverage = self.coverage_summary.get("overall_percent")
        reasons: list[str] = []

        status = "PASS"
        if findings["CRITICAL"] > 0:
            reasons.append(f"critical findings: {findings['CRITICAL']}")
            if self.args.strict:
                status = "FAIL"
            else:
                status = "DEGRADED"

        if failed_tests > 0:
            reasons.append(f"failed tests/errors: {failed_tests}")
            status = "FAIL" if self.args.strict else "DEGRADED"

        if coverage is not None and coverage < self.args.coverage_threshold:
            reasons.append(f"coverage below threshold: {coverage}% < {self.args.coverage_threshold}%")
            status = "FAIL" if self.args.strict else "DEGRADED"

        if self.warnings and status == "PASS":
            status = "DEGRADED"

        return {"status": status, "reasons": reasons, "strict_mode": self.args.strict}

    def phase_aggregate(self) -> dict[str, Any]:
        findings = self._aggregate_findings()
        verdict = self._compute_gate_verdict()

        report = {
            "schema_version": "1.0.0",
            "scan_id": self.scan_id,
            "generated_at": dt.datetime.utcnow().isoformat() + "Z",
            "project_root": str(Path(self.args.path).resolve()),
            "mode": self.args.mode,
            "strict": self.args.strict,
            "adapters": self.adapters,
            "summary": {
                "gate_verdict": verdict,
                "severity_totals": findings,
                "tests": self.test_summary,
                "coverage": self.coverage_summary,
                "tool_status": self.tool_status,
                "warnings": self.warnings,
            },
            "phase_status": [asdict(x) for x in self.phase_records],
            "findings_by_tool": self.findings_by_tool,
            "traceability": self.traceability,
            "artifacts": {
                "phase_log": str(self.phase_log_file),
                "metadata": str(self.metadata_file),
                "report_json": str(self.summary_file),
                "report_markdown": str(self.summary_md_file),
            },
        }
        self.summary_file.write_text(json.dumps(report, indent=2), encoding="utf-8")
        self.summary_md_file.write_text(self._render_markdown(report), encoding="utf-8")
        return {"report": str(self.summary_file), "markdown": str(self.summary_md_file)}

    def _render_markdown(self, report: dict[str, Any]) -> str:
        summary = report["summary"]
        verdict = summary["gate_verdict"]
        lines = [
            "# Unified Pre-Push Security Scan Report",
            "",
            f"- Scan ID: `{report['scan_id']}`",
            f"- Generated At: `{report['generated_at']}`",
            f"- Project Root: `{report['project_root']}`",
            f"- Mode: `{report['mode']}`",
            f"- Strict: `{report['strict']}`",
            f"- Adapters: `{', '.join(report['adapters']) if report['adapters'] else 'none'}`",
            "",
            "## Gate Verdict",
            f"- Status: **{verdict['status']}**",
            f"- Reasons: {', '.join(verdict['reasons']) if verdict['reasons'] else 'none'}",
            "",
            "## Severity Totals",
        ]
        for sev, value in summary["severity_totals"].items():
            lines.append(f"- {sev}: {value}")

        lines += [
            "",
            "## Tests",
            f"- Total: {summary['tests']['total']}",
            f"- Passed: {summary['tests']['passed']}",
            f"- Failed: {summary['tests']['failed']}",
            f"- Errors: {summary['tests']['errors']}",
            f"- Frameworks: {', '.join(summary['tests']['frameworks']) if summary['tests']['frameworks'] else 'none'}",
            "",
            "## Coverage",
            f"- Overall (%): {summary['coverage']['overall_percent']}",
            f"- Missing adapters: {', '.join(summary['coverage']['missing']) if summary['coverage']['missing'] else 'none'}",
            "",
            "## Tool Status",
        ]
        for tool, status in summary["tool_status"].items():
            lines.append(f"- {tool}: {'available' if status.get('available') else 'missing'} (required={status.get('required')})")

        lines += ["", "## Traceability"]
        for key, path in report["traceability"].items():
            lines.append(f"- {key}: `{path}`")

        if summary["warnings"]:
            lines += ["", "## Warnings"] + [f"- {w}" for w in summary["warnings"]]

        return "\n".join(lines) + "\n"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Unified pre-push DevSecOps scan")
    parser.add_argument("--path", default=".", help="Project root to scan")
    parser.add_argument("--scan-id", default="", help="Optional explicit scan ID")
    parser.add_argument("--mode", choices=["full", "code-only", "image-only", "k8s-manifests"], default="code-only")
    parser.add_argument("--strict", action="store_true", help="Fail scan on critical findings/test failures")
    parser.add_argument("--output-dir", default="./security-reports", help="Base output directory")
    parser.add_argument("--coverage-threshold", type=float, default=70.0)
    parser.add_argument("--severity", default="CRITICAL,HIGH")
    parser.add_argument("--image-name", default="")
    parser.add_argument("--image-tag", default="latest")
    parser.add_argument("--registry", default="132.186.17.22:5000")
    parser.add_argument("--run-sonar", action="store_true")
    parser.add_argument("--run-trivy", action="store_true", default=True)
    parser.add_argument("--no-trivy", action="store_true")
    parser.add_argument("--generate-sbom", action="store_true", default=True)
    parser.add_argument("--no-sbom", action="store_true")
    parser.add_argument("--sonar-host-url", default=os.getenv("SONAR_HOST_URL", ""))
    parser.add_argument("--sonar-token", default=os.getenv("SONAR_TOKEN", ""))
    parser.add_argument("--sonar-project-key", default="")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.no_trivy:
        args.run_trivy = False
    if args.no_sbom:
        args.generate_sbom = False

    scanner = UnifiedScan(args)
    return scanner.run()


if __name__ == "__main__":
    raise SystemExit(main())
