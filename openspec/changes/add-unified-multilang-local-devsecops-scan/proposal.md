## Why

The current platform already supports many security and CI checks, but teams still lack a single, consistent developer workflow that guarantees test execution, coverage collection, security scanning, and one consolidated local report before code is pushed. This change is needed now to enforce a practical “scan-before-push” quality gate across mixed-language repositories and reduce late-stage failures in Jenkins.

## What Changes

- Add a unified developer command workflow that runs pre-push scans locally and/or through the central scanner, with consistent behavior across supported languages.
- Add deterministic language and test-framework detection that checks for test folders and framework conventions (including Python `pytest`/`unittest`) and runs the correct test commands automatically.
- Add standardized coverage collection and normalization so code/test coverage results are included in the final report regardless of language tooling.
- Integrate security tooling into one orchestrated flow: SonarQube analysis, Trivy scans (fs/image/config), SBOM generation (CycloneDX and SPDX), and optional additional scanners where available.
- Add a consolidated final report model that summarizes vulnerabilities, secrets, code quality, test status, and coverage in one local output bundle.
- Add explicit handling rules for unsupported or partially configured repos (graceful warnings, actionable remediation, non-silent failures).

## Capabilities

### New Capabilities
- `pre-push-scan-orchestration`: A single developer-triggered command that orchestrates tests, coverage, quality checks, and security scans before push.
- `multi-language-test-coverage-detection`: Auto-detect language stack and test framework(s), discover test directories, run tests, and collect coverage in a normalized format.
- `integrated-security-toolchain`: Coordinate SonarQube, Trivy, SBOM generation, and security-related scanners in a single pipeline flow.
- `consolidated-local-security-reporting`: Produce one local final report with executive summary, per-tool findings, severity breakdowns, test outcomes, and coverage metrics.
- `cross-language-scan-compatibility`: Define minimum supported behavior for Python, Java, Node/React, C/C++, Kotlin, and HTML/static-content projects, with extension points for additional languages.

### Modified Capabilities
- None (no existing OpenSpec capabilities currently defined in `openspec/specs`).

## Impact

- Affected Jenkins assets: `jenkins/pipelines/`, `jenkins/config/pipeline-job-config.xml`, and shared library modules in `jenkins/shared-library/vars/`.
- Affected scripts: developer entrypoints under `jenkins/scripts/` and client/report generation scripts.
- Affected API/reporting surface: endpoints and summary parsing under `api/routers/` and `api/services/` for unified reporting.
- May require additional tool packaging/version pinning for coverage and language-specific scanners.
- Improves developer shift-left security posture while preserving existing zero-setup scan UX.
