# Jenkins CI/CD — Implementation Tracker

> **Reference file** — Check this before making changes to know what's done.
> Last updated: 2026-03-27 (CycloneDX SBOM + Dynamic Agent fixes)

---

## Folder Structure

```
jenkins/
├── IMPLEMENTATION-TRACKER.md    ← YOU ARE HERE
├── README.md                    ← Complete documentation
│
├── infrastructure/              ← Jenkins K8s deployment manifests
│   ├── namespace.yml            ✅ Done
│   ├── deployment.yml           ✅ Done
│   ├── service.yml              ✅ Done (NodePort 32000)
│   ├── pv.yml                   ✅ Done (20Gi, /data/jenkins)
│   ├── pvc.yml                  ✅ Done
│   ├── service-account.yml      ✅ Done (cluster-admin)
│   ├── deploy.sh                ✅ Done (one-command deployer)
│   ├── configmaps/
│   │   ├── init-groovy.yml      ✅ Done (admin user setup)
│   │   └── agent-init-groovy.yml ✅ Done (JNLP agent config)
│   └── sonarqube/               ← SonarQube K8s deployment
│       ├── namespace.yml        ✅ Done
│       ├── postgres-pv.yml      ✅ Done (10Gi, /data/sonarqube/postgres)
│       ├── postgres-pvc.yml     ✅ Done
│       ├── postgres-secrets.yml ✅ Done
│       ├── postgres-deployment.yml ✅ Done (PostgreSQL 16)
│       ├── postgres-service.yml ✅ Done (ClusterIP)
│       ├── sonarqube-pv.yml     ✅ Done (10Gi, /data/sonarqube/data)
│       ├── sonarqube-pvc.yml    ✅ Done
│       ├── sonarqube-deployment.yml ✅ Done (sonarqube:lts-community)
│       ├── sonarqube-service.yml ✅ Done (NodePort 32001)
│       └── deploy-sonarqube.sh  ✅ Done (one-command deployer)
│
├── pipelines/
│   ├── ci-cd/                   ← Universal CI/CD pipeline
│   │   ├── Jenkinsfile          ✅ Done (13 stages, multi-language)
│   │   └── pipeline.yaml        ✅ Done (config reference)
│   └── security/                ← Security scanning pipeline
│       ├── Jenkinsfile          ✅ Done (11 stages)
│       └── pipeline.yaml        ✅ Done
│
├── shared-library/vars/         ← Jenkins Shared Library modules
│   ├── detectLanguage.groovy    ✅ Done (auto-detect 9 languages)
│   ├── buildProject.groovy      ✅ Done (multi-language build)
│   ├── runTests.groovy          ✅ Done (unit/integration/e2e)
│   ├── codeQuality.groovy       ✅ Done (lint per language)
│   ├── dockerBuild.groovy       ✅ Done (podman/docker build+push)
│   ├── deployToK8s.groovy       ✅ Done (kubectl + rollback)
│   ├── notifyResults.groovy     ✅ Done (slack + email)
│   ├── securityScan.groovy      ✅ Done (orchestrator)
│   ├── trivyImageScan.groovy    ✅ Done
│   ├── trivyFsScan.groovy       ✅ Done
│   ├── trivyK8sScan.groovy      ✅ Done
│   ├── scanRegistryImages.groovy ✅ Done
│   ├── secretDetection.groovy   ✅ Done
│   ├── cyclonedxSbom.groovy     ✅ Done (multi-lang SBOM generator)
│   └── sonarQubeAnalysis.groovy ✅ Done
│
├── config/                      ← Shared configuration
│   ├── trivy.yaml               ✅ Done
│   ├── .trivyignore             ✅ Done
│   ├── owasp-suppressions.xml   ✅ Done
│   ├── sonar-project.properties ✅ Done
│   └── pipeline-job-config.xml  ✅ Done
│
├── scripts/                     ← Utility & automation scripts
│   ├── install-security-tools.sh ✅ Done
│   ├── jenkins-agent-connect.sh  ✅ Done
│   ├── setup-security-scanner.sh ✅ Done
│   ├── dev-security-scan.sh      ✅ Done
│   ├── pipeline-trigger.sh       ✅ Done
│   ├── scan-all-images.sh        ✅ Done
│   ├── create-pipeline-job.py    ✅ Done
│   ├── dynamic-agent-manager.sh  ✅ Done (on-demand JNLP agent lifecycle)
│   ├── run-comprehensive-devsecops.sh ✅ Done (full DevSecOps trigger)
│   ├── generate-comprehensive-report.sh ✅ Done (HTML+TXT+JSON report)
│   └── client/
│       ├── security-scan-client.sh   ✅ Done (zero-setup scan client)
│       ├── scan-client-server.py     ✅ Done (HTTP server for scan uploads)
│       └── serve-scan-client.sh      ✅ Done (client serving endpoint)
│
└── templates/                   ← Ready-to-use Jenkinsfile templates
    ├── Jenkinsfile.python       ✅ Done (pytest, flake8, coverage)
    ├── Jenkinsfile.java         ✅ Done (Maven/Gradle, JUnit, JaCoCo)
    ├── Jenkinsfile.nodejs       ✅ Done (npm, ESLint, Jest, Cypress)
    └── Jenkinsfile.go           ✅ Done (go test, vet, coverage)
```

---

## Language Support Matrix

| Language     | Detect | Install | Lint      | Unit Test | Integration | E2E      | Coverage | Build   | Docker |
|-------------|--------|---------|-----------|-----------|-------------|----------|----------|---------|--------|
| Python      | ✅     | ✅ pip  | ✅ flake8, black, mypy, bandit | ✅ pytest | ✅ pytest -m | ✅ pytest | ✅ pytest-cov | ✅ wheel/build | ✅ |
| Java Maven  | ✅     | ✅ mvn  | ✅ checkstyle, spotbugs | ✅ JUnit | ✅ failsafe | —        | ✅ JaCoCo | ✅ mvn package | ✅ |
| Java Gradle | ✅     | ✅ gradle | ✅ checkstyle, spotbugs | ✅ JUnit | ✅ gradle IT | —      | ✅ JaCoCo | ✅ gradle build | ✅ |
| Node.js     | ✅     | ✅ npm/yarn/pnpm | ✅ ESLint, Prettier | ✅ Jest/Mocha | ✅ npm script | ✅ Cypress/Playwright | ✅ lcov | ✅ npm build | ✅ |
| React       | ✅     | ✅ npm  | ✅ ESLint, Prettier | ✅ Jest | ✅ | ✅ Cypress | ✅ lcov | ✅ npm build | ✅ |
| Angular     | ✅     | ✅ npm  | ✅ ng lint | ✅ Karma | ✅ | ✅ Cypress | ✅ | ✅ ng build | ✅ |
| Vue         | ✅     | ✅ npm  | ✅ ESLint | ✅ Jest/Vitest | ✅ | ✅ Cypress | ✅ | ✅ npm build | ✅ |
| Go          | ✅     | ✅ go mod | ✅ go vet, golangci-lint, gofmt | ✅ go test | ✅ -tags | — | ✅ coverprofile | ✅ go build | ✅ |
| .NET        | ✅     | ✅ dotnet restore | ✅ dotnet format | ✅ xUnit/NUnit | ✅ | — | ✅ XPlat | ✅ dotnet publish | ✅ |

---

## Pipeline Stages — CI/CD Pipeline

| # | Stage | Description | Status |
|---|-------|-------------|--------|
| 1 | Checkout & Detect | Git checkout + auto-detect language | ✅ |
| 2 | Install Dependencies | Language-specific package install | ✅ |
| 3 | Lint & Code Quality | Linters per language (parallel) | ✅ |
| 4 | Unit Tests | pytest/JUnit/Jest/go test + JUnit XML | ✅ |
| 5 | Integration Tests | Optional, per-language | ✅ |
| 6 | E2E Tests | Cypress/Playwright/Selenium | ✅ |
| 7 | Coverage Gate | Threshold enforcement (default 70%) | ✅ |
| 8 | Build | Compile/package per language | ✅ |
| 9 | Docker Build & Push | Podman/Docker → registry | ✅ |
| 10 | Security Scan | Trivy FS + Image + Secret detection (parallel) | ✅ |
| 11 | SonarQube | Optional SAST/quality gate | ✅ |
| 12 | Security Gate | Fail/warn on CRITICAL vulns | ✅ |
| 13 | Deploy to K8s | kubectl set image + rollout + health | ✅ |
| Post | Reports & Cleanup | Archive artifacts, publish HTML, cleanWs | ✅ |

---

## Pipeline Stages — DevSecOps Pipeline (19 Stages)

| # | Stage | Description | Status |
|---|-------|-------------|--------|
| 1 | Checkout & Language Detection | Git clone + auto-detect 9 languages | ✅ |
| 2 | Tool Verification | Verify trivy, sonar-scanner, hadolint, shellcheck | ✅ |
| 3 | Install Dependencies | Language-specific package install | ✅ |
| 4 | Lint & Code Quality | flake8/eslint/checkstyle/go vet/dotnet format | ✅ |
| 5 | Unit Testing + Coverage | pytest/JUnit/Jest/go test with coverage | ✅ |
| 6 | Integration Tests | Optional per-language integration tests | ✅ |
| 7 | **CycloneDX SBOM Generation** | **Multi-lang SBOM (Python/Java/Node/Go/.NET) + Trivy CycloneDX + SPDX** | ✅ |
| 8 | SonarQube Analysis | SAST code quality + security hotspots | ✅ |
| 9 | Build Application | Language-specific build/compile/package | ✅ |
| 10 | Docker Build & Push | Podman/Docker build → registry push | ✅ |
| 11 | Trivy Image Scan | Container image vulnerability scan | ✅ |
| 12 | SAST & Secret Detection | Source code + secret scanning | ✅ |
| 13 | SCA — Dependency Scan | Third-party dependency vulnerability scan | ✅ |
| 14 | Dockerfile Lint | Hadolint best practices | ✅ |
| 15 | ShellCheck | Shell script lint | ✅ |
| 16 | K8s Manifest Security | K8s config audit (kubesec/trivy) | ✅ |
| 17 | Security Gate | Pass/Fail on CRITICAL count | ✅ |
| 18 | Deploy to K8s | kubectl deploy + rollout + health check | ✅ |
| 19 | Comprehensive Report | HTML+TXT+JSON consolidated report | ✅ |

---

## Pipeline Stages — Security Scan Pipeline (pipeline-job-config.xml)

| # | Stage | Description | Status |
|---|-------|-------------|--------|
| 1 | Setup | Tool check + source extraction | ✅ |
| 2 | Secret Detection | Trivy secret scanner | ✅ |
| 3 | SAST / Vulnerability Scan | Trivy FS vuln + misconfig | ✅ |
| 4 | SCA / Dependency Scan | Trivy dependency analysis | ✅ |
| 5 | Image Scan | Trivy container image scan | ✅ |
| 6 | K8s Manifest Scan | Trivy config on YAML/YML | ✅ |
| 7 | Registry Scan | All registry images (optional) | ✅ |
| 8 | **CycloneDX SBOM** | **Trivy CycloneDX + SPDX SBOM generation** | ✅ NEW |
| 9 | Security Gate | CRITICAL count → pass/fail | ✅ |

---

## Pipeline Stages — Security Pipeline (Dedicated Jenkinsfile)
| 2 | Checkout | Git clone (optional) | ✅ |
| 3 | Secret Detection | Trivy secret scanner | ✅ |
| 4 | SAST | Trivy FS + Hadolint + ShellCheck (parallel) | ✅ |
| 5 | SCA | Trivy + OWASP DC + Grype (parallel) | ✅ |
| 6 | Container Image Scan | Trivy + Grype image scan (parallel) | ✅ |
| 7 | Registry Image Scan | Scan all images in registry | ✅ |
| 8 | K8s Manifest Scan | Trivy config + Kubesec (parallel) | ✅ |
| 9 | Cluster Security Audit | Live K8s cluster scan | ✅ |
| 10 | Security Gate | Pass/Fail based on CRITICAL count | ✅ |
| 11 | Generate Report | Consolidated HTML report | ✅ |

---

## What's Done

- [x] Folder structure reorganized (infrastructure, pipelines, shared-library, config, scripts, templates)
- [x] Jenkins K8s infrastructure (namespace, deploy, service, SA, PV, configmaps)
- [x] Infrastructure deploy script (deploy.sh)
- [x] Security scanning pipeline (11-stage Jenkinsfile)
- [x] Universal CI/CD pipeline (13-stage Jenkinsfile, 9 languages)
- [x] Shared Library (13 Groovy modules)
- [x] Language auto-detection (Python, Java Maven/Gradle, Node.js, React, Angular, Vue, Go, .NET)
- [x] Unit testing support (pytest, JUnit, Jest, go test, dotnet test)
- [x] Integration testing support (all languages)
- [x] E2E testing support (Cypress, Playwright, Selenium)
- [x] Code coverage with threshold enforcement
- [x] Linting per language (flake8, ESLint, checkstyle, go vet, etc.)
- [x] Docker/Podman build & push
- [x] Security scanning (Trivy, Grype, OWASP DC, Kubesec)
- [x] Template Jenkinsfiles (Python, Java, Node.js, Go)
- [x] Jenkins agent connection scripts
- [x] Developer security scan (one-command)
- [x] Complete documentation (README.md)
- [x] This tracker file
- [x] SonarQube server deployed in K8s (sonarqube namespace, PostgreSQL 16 backend, NodePort 32001)
- [x] CycloneDX SBOM generation (shared library: cyclonedxSbom.groovy — Python, Java, Node.js, Go, .NET)
- [x] CycloneDX SBOM stage in DevSecOps pipeline (Stage 7, Trivy CycloneDX + SPDX cross-check)
- [x] CycloneDX SBOM stage added to security-scan-pipeline (pipeline-job-config.xml)
- [x] Dynamic agent manager (dynamic-agent-manager.sh — create/destroy/status/list/cleanup)
- [x] Dynamic agent support in pipeline-job-config.xml (AGENT_LABEL parameter)
- [x] Zero-setup scan client (curl one-liner with HTTP upload server)
- [x] Comprehensive report generator (HTML/TXT/JSON with SBOM section)

---

## Change Log

| Date | Change | Files Modified |
|------|--------|----------------|
| 2026-03-10 | Initial Catool deployment | cat-deployments/ |
| 2026-03-20 | Jenkins CI/CD infrastructure | jenkins/infrastructure/ |
| 2026-03-22 | Pipelines + Shared Library + Templates | jenkins/pipelines/, shared-library/, templates/ |
| 2026-03-25 | SonarQube deployed (v9.9.8 LTS) | jenkins/infrastructure/sonarqube/ |
| 2026-03-26 | Security scan client + dynamic agents | jenkins/scripts/client/, dynamic-agent-manager.sh |
| 2026-03-26 | CycloneDX SBOM shared library | jenkins/shared-library/vars/cyclonedxSbom.groovy |
| 2026-03-27 | **Fixed**: Dynamic agent Jenkins URL mismatch (.22→.25) | jenkins/scripts/dynamic-agent-manager.sh |
| 2026-03-27 | **Fixed**: pipeline-job-config.xml hardcoded agent label | jenkins/config/pipeline-job-config.xml |
| 2026-03-27 | **Added**: AGENT_LABEL + GENERATE_SBOM params to security pipeline | jenkins/config/pipeline-job-config.xml |
| 2026-03-27 | **Added**: CycloneDX SBOM stage (Trivy CycloneDX+SPDX) to security pipeline | jenkins/config/pipeline-job-config.xml |
| 2026-03-27 | Workflow documentation + architecture diagram | docs/WORKFLOW-ARCHITECTURE.md |
| 2026-03-27 | **Fixed**: 3 root causes for dynamic agent failure | dynamic-agent-manager.sh, server.py |
| 2026-03-27 | **Fixed**: Deployed updated server.py to /opt/scan-client-server/ | scan-client-server.py → server.py |
| 2026-03-27 | **Verified**: Dynamic agent lifecycle (create→online→destroy) working | E2E test passed |

---

## Known Issues & Fixes (2026-03-27)

### Issue 1: Dynamic Agents Not Creating — **RESOLVED** ✅
**Symptom**: `Could not create dynamic agent` error, all pipelines run on `local-security-agent`.

**Root Causes Found & Fixed**:

| # | Root Cause | Fix Applied |
|---|-----------|-------------|
| 1 | **Deployed server.py missing agent endpoints** — The running server at `/opt/scan-client-server/server.py` (151 lines) had NO `/agent/create` endpoint. The updated version (281 lines) with agent support was only in the repo, never deployed. Client got 404 → "Error: unknown". | Deployed updated `scan-client-server.py` → `/opt/scan-client-server/server.py` and restarted systemd service. |
| 2 | **CSRF 403 on node creation** — Jenkins 2.541.3 ties CSRF crumbs to HTTP sessions. The `dynamic-agent-manager.sh` used `curl` without a cookie jar, so the crumb was created in one session and used in another → HTTP 403. | Rewrote `get_crumb()` to use `cookie jar` (`-c`/`-b` flags). All Jenkins API calls now share the same session. |
| 3 | **Form-based node creation API broken** — `POST /computer/doCreateItem` with `application/x-www-form-urlencoded` silently failed even with valid crumbs on Jenkins 2.541.3. | Replaced with **Jenkins Groovy `scriptText` API** — uses `Jenkins.instance.addNode(DumbSlave)` which is the most reliable node creation method. |
| 4 | **Jenkins URL mismatch** — `dynamic-agent-manager.sh` used `132.186.17.22:32000` but Jenkins is at `132.186.17.25:32000`. | Fixed URL to `.25`. |
| 5 | **`DYNAMIC_AGENT_SCRIPT` path wrong** — Server.py referenced `/opt/jenkins-local-agent-code/...` but code is at `/tmp/jenkins-local-agent-code/...`. | Fixed path in `scan-client-server.py`. |
| 6 | **`pipeline-job-config.xml` hardcoded agent label** — No `AGENT_LABEL` parameter, always used `local-security-agent`. | Added `AGENT_LABEL` parameter with fallback. |

**Verification**: Full lifecycle tested and working:
```
curl POST /agent/create → Groovy API creates DumbSlave → JNLP connects in 2s → Agent ONLINE
curl POST /agent/destroy → Groovy API removes node → workspace cleaned
```

### Issue 2: CycloneDX SBOM Missing from Security Scan Pipeline — **RESOLVED** ✅
**Symptom**: SBOM only generated by DevSecOps pipeline, not the security-scan-pipeline job.

**Fix**: Added `GENERATE_SBOM` parameter and CycloneDX SBOM stage to `pipeline-job-config.xml`.

---

## What's NOT Done (Future / Optional)

- [ ] Helm chart for Jenkins deployment
- [ ] Jenkins Configuration as Code (JCasC) YAML
- [ ] Artifactory / Nexus integration for artifacts
- [ ] GitHub/GitLab webhook auto-trigger setup
- [ ] Multi-branch pipeline job config
- [ ] Blue Ocean dashboard setup
- [ ] Pipeline metrics and dashboards (Prometheus/Grafana)
- [ ] Notifications (Slack/Email — module exists, needs credentials)
- [x] ~~SonarQube server setup~~ ✅ Deployed (v9.9.8 LTS, NodePort 32001)
- [ ] HashiCorp Vault integration

---

## Jenkins Agent Status (Updated 2026-03-27)

| Component | Status | Details |
|-----------|--------|---------|
| Jenkins Master | ✅ RUNNING | NodePort 32000, pod jenkins-6677d7cd86-t6mz2 |
| JNLP Agent (local-security-agent) | ✅ ONLINE | PID running, WebSocket connected, 2 executors |
| Dynamic Agent Manager | ✅ WORKING | Groovy API + cookie-jar CSRF + URL fix + server deployed |
| SonarQube Server | ✅ UP (GREEN) | NodePort 32001, v9.9.8 LTS Community |
| SonarQube PostgreSQL | ✅ RUNNING | ClusterIP, PostgreSQL 16 |
| Pipeline SonarQube Config | ✅ ENABLED | CI/CD + Security pipelines updated |
| CycloneDX SBOM (DevSecOps) | ✅ CONFIGURED | Stage 7 — multi-lang + Trivy CycloneDX + SPDX |
| CycloneDX SBOM (Security Scan) | ✅ ADDED | pipeline-job-config.xml — Trivy CycloneDX + SPDX |
| Scan Client Server | ✅ RUNNING | HTTP :9091, source upload + dynamic agent API |

### Access URLs

| Service | URL |
|---------|-----|
| Jenkins | http://132.186.17.25:32000 |
| SonarQube | http://132.186.17.22:32001 |
| SonarQube (internal) | http://sonarqube.sonarqube.svc.cluster.local:9000 |

### Test Project Found

| Component | Path | Tech Stack |
|-----------|------|------------|
| Backend | /root/Testing/rnd-quality-statistics-main@0d5de127bfe/backend | Python/FastAPI, pytest, ruff |
| Frontend | /root/Testing/rnd-quality-statistics-main@0d5de127bfe/frontend | React 19, TypeScript, Vite, ESLint |
| K8s Manifests | /root/Testing/rnd-quality-statistics-main@0d5de127bfe/k8s | Kustomize-based |
| Tests | backend/tests/ | 5 test files (health, auth, middleware, services) |
