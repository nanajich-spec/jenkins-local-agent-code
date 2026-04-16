## 1. Unified Scan Entry and Orchestration

- [x] 1.1 Define canonical pre-push scan command contract and CLI arguments for mode, strictness, and output path
- [x] 1.2 Refactor entry script(s) to execute deterministic phases: detect → test → coverage → security → aggregate
- [x] 1.3 Add scan run metadata generation (scan ID, timestamps, phase timing, adapter list)
- [x] 1.4 Add structured phase-state logging for use by report aggregation and debugging

## 2. Language Adapters and Test/Coverage Detection

- [x] 2.1 Implement adapter interface for Python, Java, Node/React, C/C++, Kotlin, and HTML/static projects
- [x] 2.2 Implement repository signal detection (manifest/build file/test path detection) for single and polyglot repos
- [x] 2.3 Implement Python test logic: prefer pytest when configured, otherwise unittest discovery
- [x] 2.4 Implement per-language coverage extraction and normalization into a shared summary model
- [x] 2.5 Add explicit warnings when tests or coverage cannot be collected

## 3. Security Toolchain Integration

- [x] 3.1 Standardize SonarQube stage invocation and result ingestion in unified flow
- [x] 3.2 Standardize Trivy fs/image/config execution by selected scan mode
- [x] 3.3 Standardize SBOM generation and archival for CycloneDX and SPDX outputs
- [x] 3.4 Add preflight checks for required/optional scanners and implement degraded-mode behavior
- [x] 3.5 Normalize findings severities across integrated tools for consolidated reporting

## 4. Consolidated Local Reporting

- [x] 4.1 Define consolidated report schema (executive summary, gate verdict, findings, tests, coverage, tool status)
- [x] 4.2 Update report generator/parser logic to produce one local report bundle per scan
- [x] 4.3 Add artifact traceability links from summary findings to raw tool outputs
- [x] 4.4 Ensure local output directory conventions are stable and timestamped

## 5. Jenkins Pipeline and Shared Library Alignment

- [x] 5.1 Update shared library modules to use adapter-driven orchestration and normalized outputs
- [x] 5.2 Align `security-scan` and `devsecops` pipeline definitions with unified phase contracts
- [x] 5.3 Add/align pipeline parameters for strict mode, scan mode, and local report packaging
- [x] 5.4 Verify dynamic-agent and static-agent compatibility for new flow

## 6. Validation and Rollout

- [x] 6.1 Validate behavior on representative repositories: Python, Java, Node/React, C/C++, Kotlin, and static HTML
- [x] 6.2 Validate Python-specific test folder and pytest/unittest coverage scenarios
- [x] 6.3 Validate consolidated local report completeness and gate verdict accuracy
- [x] 6.4 Roll out in warn-first mode, then enforce blocking gate policy after baseline stability
- [x] 6.5 Update user/admin documentation for unified pre-push workflow and troubleshooting
