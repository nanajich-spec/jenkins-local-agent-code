# DevSecOps Pipeline — Workflow Architecture & Documentation

> **Complete workflow documentation** for the Jenkins DevSecOps platform
> Last updated: 2026-03-27

---

## System Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                          DEVELOPER WORKSTATION                                  │
│                                                                                 │
│  ┌──────────────────────────────┐     ┌────────────────────────────────┐        │
│  │  Option A: Zero-Setup Scan   │     │  Option B: Direct Jenkins UI   │        │
│  │                              │     │                                │        │
│  │  curl -sL                    │     │  http://132.186.17.25:32000    │        │
│  │    http://132.186.17.22:9091 │     │  → Build with Parameters      │        │
│  │    /scan | bash              │     │  → Select pipeline + params    │        │
│  │                              │     │                                │        │
│  │  Features:                   │     │  Features:                     │        │
│  │  • Auto-uploads source code  │     │  • Manual parameter control    │        │
│  │  • Dynamic agent creation    │     │  • Uses static agent only      │        │
│  │  • Real-time progress bar    │     │  • Full Jenkins dashboard      │        │
│  │  • Downloads reports         │     │  • Build history & trends      │        │
│  └──────────────┬───────────────┘     └───────────────┬────────────────┘        │
│                 │                                     │                          │
└─────────────────┼─────────────────────────────────────┼──────────────────────────┘
                  │                                     │
                  ▼                                     │
┌─────────────────────────────────┐                     │
│  HTTP Server (:9091)            │                     │
│  scan-client-server.py          │                     │
│                                 │                     │
│  Endpoints:                     │                     │
│  POST /upload  → receive tar.gz │                     │
│  POST /agent/create → dynamic   │                     │
│  POST /agent/destroy → cleanup  │                     │
│  GET  /agent/status → check     │                     │
│  POST /cleanup → post-scan      │                     │
│  GET  /scan → serve client.sh   │                     │
└────────────┬────────────────────┘                     │
             │                                          │
             │  1. Upload source code                   │
             │  2. Create dynamic JNLP agent            │
             │  3. Trigger pipeline with AGENT_LABEL    │
             │                                          │
             ▼                                          ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                       KUBERNETES CLUSTER (132.186.17.25)                        │
│                                                                                 │
│  ┌───────────────────────────────────────────────────────────────────────┐      │
│  │  JENKINS MASTER (NodePort 32000)                                     │      │
│  │  Namespace: jenkins │ Pod: jenkins-6677d7cd86-t6mz2                  │      │
│  │                                                                       │      │
│  │  ┌─────────────────────┐  ┌──────────────────────┐                   │      │
│  │  │ Pipelines           │  │ Shared Library       │                   │      │
│  │  │                     │  │ (vars/)              │                   │      │
│  │  │ • ci-cd-pipeline    │  │                      │                   │      │
│  │  │ • devsecops-pipeline│  │ • detectLanguage     │                   │      │
│  │  │ • security-scan-    │  │ • buildProject       │                   │      │
│  │  │   pipeline          │  │ • runTests           │                   │      │
│  │  │                     │  │ • codeQuality        │                   │      │
│  │  │ Parameters:         │  │ • dockerBuild        │                   │      │
│  │  │ • AGENT_LABEL       │  │ • securityScan       │                   │      │
│  │  │ • GENERATE_SBOM     │  │ • cyclonedxSbom ←NEW │                   │      │
│  │  │ • SCAN_TYPE         │  │ • trivyImageScan     │                   │      │
│  │  │ • IMAGE_NAME/TAG    │  │ • trivyFsScan        │                   │      │
│  │  │ • FAIL_ON_CRITICAL  │  │ • scanRegistryImages │                   │      │
│  │  └─────────────────────┘  │ • secretDetection    │                   │      │
│  │                            │ • sonarQubeAnalysis  │                   │      │
│  │                            │ • deployToK8s        │                   │      │
│  │                            │ • notifyResults      │                   │      │
│  │                            └──────────────────────┘                   │      │
│  └───────────────────────────────┬───────────────────────────────────────┘      │
│                                  │                                              │
│                    ┌─────────────┴─────────────┐                                │
│                    ▼                           ▼                                │
│  ┌──────────────────────────┐  ┌────────────────────────────┐                  │
│  │  STATIC AGENT            │  │  DYNAMIC AGENT (on-demand) │                  │
│  │  local-security-agent    │  │  scan-agent-<scan-id>      │                  │
│  │                          │  │                            │                  │
│  │  • Always online         │  │  • Created per scan        │                  │
│  │  • 2 executors           │  │  • 1 executor (exclusive)  │                  │
│  │  • JNLP WebSocket        │  │  • JNLP connection        │                  │
│  │  • Shared workspace      │  │  • Isolated workspace      │                  │
│  │  • Queue if busy         │  │  • No queue waiting        │                  │
│  │  • Default fallback      │  │  • Auto-destroyed after    │                  │
│  │                          │  │  • Labels: dynamic-        │                  │
│  │                          │  │    security-agent linux    │                  │
│  │  Path: /opt/jenkins-     │  │  Path: /opt/jenkins-       │                  │
│  │    agent/workspace/      │  │    agent/dynamic/          │                  │
│  └──────────┬───────────────┘  │    scan-agent-<id>/        │                  │
│             │                  └─────────────┬──────────────┘                  │
│             └────────────┬───────────────────┘                                 │
│                          ▼                                                      │
│  ┌──────────────────────────────────────────────────────────────────────┐       │
│  │  SECURITY TOOLS (installed on agent host)                           │       │
│  │                                                                      │       │
│  │  ┌─────────┐ ┌───────┐ ┌──────────┐ ┌──────────┐ ┌──────────────┐  │       │
│  │  │ Trivy   │ │ Grype │ │ Hadolint │ │ShellCheck│ │ CycloneDX    │  │       │
│  │  │ v0.69.3 │ │       │ │          │ │          │ │ (multi-lang) │  │       │
│  │  └─────────┘ └───────┘ └──────────┘ └──────────┘ └──────────────┘  │       │
│  │  ┌──────────┐ ┌───────────────┐ ┌────────┐ ┌────────┐              │       │
│  │  │ Podman   │ │ SonarScanner  │ │ Bandit │ │ Kubesec│              │       │
│  │  │          │ │               │ │(Python)│ │        │              │       │
│  │  └──────────┘ └───────────────┘ └────────┘ └────────┘              │       │
│  └──────────────────────────────────────────────────────────────────────┘       │
│                                                                                 │
│  ┌──────────────────────────────────────────────────────────────────────┐       │
│  │  OTHER SERVICES                                                      │       │
│  │                                                                      │       │
│  │  ┌──────────────────┐  ┌────────────────────┐  ┌─────────────────┐  │       │
│  │  │ Container        │  │ SonarQube          │  │ Catool App      │  │       │
│  │  │ Registry (:5000) │  │ (:32001)           │  │ UI (:30080)     │  │       │
│  │  │ + Web UI (:8080) │  │ v9.9.8 LTS         │  │ API (:30600)    │  │       │
│  │  │                  │  │ + PostgreSQL 16     │  │                 │  │       │
│  │  └──────────────────┘  └────────────────────┘  └─────────────────┘  │       │
│  └──────────────────────────────────────────────────────────────────────┘       │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Pipeline Workflow Diagrams

### 1. Security Scan Pipeline Flow (security-scan-pipeline)

```
┌─────────┐    ┌──────────────┐    ┌────────────┐    ┌───────────┐    ┌────────────┐
│  Setup  │───▶│   Secret     │───▶│   SAST /   │───▶│  SCA /    │───▶│   Image    │
│  Tools  │    │  Detection   │    │   Vuln     │    │  Deps     │    │   Scan     │
│+ Source │    │  (Trivy)     │    │  Scan      │    │  Scan     │    │  (Trivy)   │
│ Extract │    │              │    │  (Trivy)   │    │  (Trivy)  │    │            │
└─────────┘    └──────────────┘    └────────────┘    └───────────┘    └────────────┘
                                                                            │
    ┌───────────────────────────────────────────────────────────────────────┘
    ▼
┌────────────┐    ┌──────────────┐    ┌──────────────────┐    ┌──────────────┐
│  K8s       │───▶│  Registry    │───▶│  CycloneDX SBOM  │───▶│  Security   │
│  Manifest  │    │  Scan        │    │  Generation      │    │  Gate       │
│  Scan      │    │  (optional)  │    │  (Trivy CycloneDX│    │  (CRITICAL  │
│  (Trivy)   │    │              │    │  + SPDX cross-   │    │   count)    │
└────────────┘    └──────────────┘    │  check)          │    └──────┬─────┘
                                      └──────────────────┘           │
                                                                      ▼
                                                              ┌──────────────┐
                                                              │  Archive     │
                                                              │  Reports +   │
                                                              │  Cleanup     │
                                                              └──────────────┘
```

### 2. DevSecOps Pipeline Flow (19 Stages)

```
┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐
│1.Checkout│──▶│2.Tool    │──▶│3.Install │──▶│4.Lint &  │──▶│5.Unit    │
│ & Detect │   │ Verify   │   │ Deps     │   │ Quality  │   │ Tests +  │
│ Language │   │          │   │          │   │          │   │ Coverage │
└──────────┘   └──────────┘   └──────────┘   └──────────┘   └──────────┘
                                                                   │
  ┌────────────────────────────────────────────────────────────────┘
  ▼
┌──────────┐   ┌──────────────────────────┐   ┌──────────┐   ┌──────────┐
│6.Integra-│──▶│7.CycloneDX SBOM          │──▶│8.Sonar-  │──▶│9.Build   │
│ tion     │   │  ┌──────────────────────┐│   │ Qube     │   │ App      │
│ Tests    │   │  │Python: cyclonedx-py  ││   │ Analysis │   │          │
│          │   │  │Java:   mvn cyclonedx ││   │          │   │          │
│          │   │  │Node:   @cyclonedx/npm││   │          │   │          │
│          │   │  │Go:     cyclonedx-gomod│   │          │   │          │
│          │   │  │.NET:   dotnet cyclonedx│   │          │   │          │
│          │   │  │+ Trivy CycloneDX     ││   │          │   │          │
│          │   │  │+ SPDX cross-check    ││   │          │   │          │
│          │   │  └──────────────────────┘│   │          │   │          │
└──────────┘   └──────────────────────────┘   └──────────┘   └──────────┘
                                                                   │
  ┌────────────────────────────────────────────────────────────────┘
  ▼
┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐
│10.Docker │──▶│11.Trivy  │──▶│12.SAST & │──▶│13.SCA    │──▶│14.Docker-│
│ Build &  │   │ Image    │   │ Secret   │   │ Depend.  │   │ file     │
│ Push     │   │ Scan     │   │ Detect   │   │ Scan     │   │ Lint     │
└──────────┘   └──────────┘   └──────────┘   └──────────┘   └──────────┘
                                                                   │
  ┌────────────────────────────────────────────────────────────────┘
  ▼
┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────────────────────┐
│15.Shell- │──▶│16.K8s    │──▶│17.Securi-│──▶│18.Deploy │──▶│19.Report │
│ Check    │   │ Manifest │   │ ty Gate  │   │ to K8s   │   │ HTML+TXT │
│          │   │ Scan     │   │ (CRIT)   │   │          │   │ +JSON    │
└──────────┘   └──────────┘   └──────────┘   └──────────┘   └──────────┘
```

---

## Dynamic Agent Lifecycle

```
┌─────────────────────────────────────────────────────────────────┐
│                    DYNAMIC AGENT WORKFLOW                        │
└─────────────────────────────────────────────────────────────────┘

  Developer runs scan command:
  $ curl -sL http://132.186.17.22:9091/scan | bash -s -- --user $(whoami)

  ┌──────────────────┐
  │ 1. Client Start  │  security-scan-client.sh
  │    (User Machine)│  • Generates SCAN_ID: <user>-<host>-<epoch>
  │                  │  • Tars up source code
  └────────┬─────────┘
           │
           ▼
  ┌──────────────────┐
  │ 2. Upload Source │  POST /upload → scan-client-server.py
  │    to Server     │  • Saves tar.gz to /opt/scan-uploads/<scan-id>/
  └────────┬─────────┘
           │
           ▼
  ┌──────────────────┐
  │ 3. Provision     │  POST /agent/create → dynamic-agent-manager.sh create
  │    Dynamic Agent │
  │                  │  a) Check concurrency limit (max 10)
  │                  │  b) Create workspace: /opt/jenkins-agent/dynamic/scan-agent-<id>/
  │                  │  c) Jenkins API: POST /computer/doCreateItem
  │                  │     → Creates DumbSlave with JNLP launcher
  │                  │     → Labels: "dynamic-security-agent linux security trivy podman scan-agent-<id>"
  │                  │  d) Retrieve agent secret from /jenkins-agent.jnlp
  │                  │  e) Launch: java -jar agent.jar -url <jenkins> -secret <secret> -name <agent>
  │                  │  f) Wait for agent to come online (poll /api/json)
  │                  │  
  │  ON FAILURE:     │  Falls back to AGENT_LABEL="local-security-agent" (shared agent)
  └────────┬─────────┘
           │ Returns: agent_name, agent_label
           ▼
  ┌──────────────────┐
  │ 4. Trigger       │  Jenkins API: POST /job/<pipeline>/buildWithParameters
  │    Pipeline      │  • AGENT_LABEL=scan-agent-<id> (or local-security-agent)
  │                  │  • SOURCE_UPLOAD_PATH=/opt/scan-uploads/<scan-id>
  │                  │  • SCAN_ID=<scan-id>
  │                  │  • GENERATE_SBOM=true
  └────────┬─────────┘
           │
           ▼
  ┌──────────────────┐
  │ 5. Pipeline Runs │  On the dynamic (or static) agent:
  │    on Agent      │  • agent { label params.AGENT_LABEL ?: 'local-security-agent' }
  │                  │  • Extracts source from uploaded tar.gz
  │                  │  • Runs all security scan stages
  │                  │  • Generates reports + SBOM
  └────────┬─────────┘
           │
           ▼
  ┌──────────────────┐
  │ 6. Collect       │  Client polls Jenkins /consoleText & /api/json
  │    Results       │  • Downloads security-reports/ artifacts
  │                  │  • Shows scan summary to user
  └────────┬─────────┘
           │
           ▼
  ┌──────────────────┐
  │ 7. Cleanup       │  POST /agent/destroy → dynamic-agent-manager.sh destroy
  │                  │  a) Kill JNLP agent process
  │                  │  b) Jenkins API: POST /computer/<agent>/doDelete
  │                  │  c) Remove workspace directory
  │                  │  d) Remove uploaded source files
  └──────────────────┘
```

---

## CycloneDX SBOM Generation — Detailed Flow

### What is SBOM?
A **Software Bill of Materials (SBOM)** is a comprehensive inventory of all components, libraries, and dependencies used in an application. CycloneDX is the OWASP standard format.

### Where SBOM is Generated

| Pipeline | Stage | Method | Output |
|----------|-------|--------|--------|
| DevSecOps (`devsecops/Jenkinsfile`) | Stage 7 | Language-specific CycloneDX tools + Trivy CycloneDX + SPDX | `pipeline-reports/sbom/` |
| Security Scan (`pipeline-job-config.xml`) | Stage 8 | Trivy CycloneDX + SPDX | `security-reports/sbom/` |

### SBOM Generation by Language

```
┌─────────────────────────────────────────────────────────────────┐
│            CycloneDX SBOM Generation (cyclonedxSbom.groovy)     │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Auto-Detect Language                                           │
│       │                                                         │
│       ├── Python ─────── cyclonedx-py (requirements/pipenv/     │
│       │                  poetry) + pip-audit --format=cyclonedx  │
│       │                                                         │
│       ├── Java Maven ─── mvn org.cyclonedx:cyclonedx-maven-     │
│       │                  plugin:2.7.11:makeAggregateBom          │
│       │                  → target/bom.json + target/bom.xml     │
│       │                                                         │
│       ├── Java Gradle ── Gradle CycloneDX plugin or dynamic     │
│       │                  init script                             │
│       │                                                         │
│       ├── Node.js/React/ @cyclonedx/cyclonedx-npm               │
│       │   Angular/Vue    or npm sbom --sbom-format cyclonedx     │
│       │                                                         │
│       ├── Go ─────────── cyclonedx-gomod or go.sum parser       │
│       │                  fallback                                │
│       │                                                         │
│       └── .NET ──────── dotnet CycloneDX                        │
│                                                                 │
│  ALWAYS runs (regardless of language):                          │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ trivy fs --format cyclonedx → trivy-cyclonedx-sbom.json │   │
│  │ trivy fs --format spdx-json → trivy-spdx-sbom.json      │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                 │
│  Report Generator (generate-comprehensive-report.sh):           │
│  Section 6 → Parses sbom/*.json, counts components,            │
│              generates HTML + TXT summary                       │
└─────────────────────────────────────────────────────────────────┘
```

### SBOM Output Files

```
pipeline-reports/sbom/         (DevSecOps pipeline)
├── cyclonedx-<lang>-sbom.json    Language-specific SBOM
├── pip-audit-cyclonedx.json      Python pip-audit CycloneDX
├── trivy-cyclonedx-full.json     Trivy full-root CycloneDX scan
└── trivy-spdx-sbom.json          SPDX compliance cross-check

security-reports/sbom/         (Security scan pipeline)
├── trivy-cyclonedx-sbom.json     Trivy CycloneDX SBOM
└── trivy-spdx-sbom.json          SPDX compliance cross-check
```

---

## Network Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Network Layout                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  132.186.17.22 (Agent Host / Tool Server)                   │
│  ├── :5000   Container Registry (HTTP)                      │
│  ├── :8080   Registry Web UI                                │
│  ├── :9091   Scan Client HTTP Server (scan-client-server.py)│
│  └── :32001  SonarQube (NodePort)                           │
│                                                             │
│  132.186.17.25 (Jenkins Master K8s Node)                    │
│  └── :32000  Jenkins Master (NodePort)                      │
│                                                             │
│  Catool Application                                         │
│  ├── :30080  Frontend UI                                    │
│  ├── :30600  Backend API (Swagger: /docs)                   │
│  └── :31286  Ingress Controller                             │
│                                                             │
│  Internal (ClusterIP):                                      │
│  └── sonarqube.sonarqube.svc.cluster.local:9000             │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## File Reference Map

### Pipeline Files

| File | Purpose | Agent Support | SBOM Support |
|------|---------|---------------|--------------|
| `jenkins/pipelines/ci-cd/Jenkinsfile` | 13-stage CI/CD | ✅ AGENT_LABEL param | ❌ Not in CI/CD |
| `jenkins/pipelines/devsecops/Jenkinsfile` | 19-stage DevSecOps | ✅ AGENT_LABEL param | ✅ Stage 7 (multi-lang) |
| `jenkins/pipelines/security/Jenkinsfile` | 11-stage Security | ✅ AGENT_LABEL param | ❌ N/A |
| `jenkins/config/pipeline-job-config.xml` | Inline security scan | ✅ AGENT_LABEL param (FIXED) | ✅ Trivy CycloneDX (ADDED) |
| `jenkins/pipelines/security-scan-pipeline.groovy` | Lightweight scan | ❌ Static only | ❌ N/A |

### Dynamic Agent Files

| File | Purpose |
|------|---------|
| `jenkins/scripts/dynamic-agent-manager.sh` | Create/destroy/status/list/cleanup JNLP agents |
| `jenkins/scripts/jenkins-agent-connect.sh` | Static agent JNLP connection |
| `jenkins/scripts/client/security-scan-client.sh` | Client-side scan trigger with dynamic agent provisioning |
| `jenkins/scripts/client/scan-client-server.py` | HTTP server: upload, agent API, cleanup |

### CycloneDX / SBOM Files

| File | Purpose |
|------|---------|
| `jenkins/shared-library/vars/cyclonedxSbom.groovy` | 616-line multi-language SBOM generator |
| `jenkins/scripts/run-comprehensive-devsecops.sh` | CLI trigger with `--no-sbom` flag |
| `jenkins/scripts/generate-comprehensive-report.sh` | Section 6: SBOM parsing in report |

---

## User Workflows

### Workflow 1: Zero-Setup Security Scan (Recommended)

```bash
# From any developer machine with network access
curl -sL http://132.186.17.22:9091/scan | bash -s -- --user $(whoami)

# What happens:
# 1. Downloads security-scan-client.sh
# 2. Packages current directory as tar.gz
# 3. Uploads to scan server
# 4. Creates dynamic agent (or falls back to shared)
# 5. Triggers security-scan-pipeline
# 6. Streams progress with real-time status bar
# 7. Downloads reports to ./security-reports-<timestamp>/
# 8. Cleans up dynamic agent
```

### Workflow 2: Jenkins UI Scan

```
1. Open http://132.186.17.25:32000
2. Select pipeline: ci-cd-pipeline / devsecops-pipeline / security-scan-pipeline
3. Click "Build with Parameters"
4. Set: IMAGE_NAME, SCAN_TYPE, GENERATE_SBOM=true
5. Click "Build"
6. View console output + download artifacts
```

### Workflow 3: DevSecOps Full Pipeline

```bash
# Trigger via script
cd /path/to/your/project
/opt/jenkins-local-agent-code/jenkins/scripts/run-comprehensive-devsecops.sh \
  --repo /path/to/your/project \
  --language auto \
  --sbom    # (enabled by default, use --no-sbom to skip)
```

---

## Troubleshooting

### Dynamic Agent Not Creating

> **STATUS: RESOLVED (2026-03-27)** — All 6 root causes identified and fixed.

The full chain now works: Client → HTTP Server → `dynamic-agent-manager.sh` → Jenkins Groovy API → JNLP Agent Online (2s).

**What was wrong** (in order of discovery):
1. Running server (`/opt/scan-client-server/server.py`) was old version without `/agent/create` endpoint
2. Jenkins CSRF crumbs are session-bound — needed cookie jar (`-c`/`-b`) for curl
3. Form-based `POST /computer/doCreateItem` silently failed — switched to Groovy `scriptText` API
4. Jenkins URL mismatch (`.22` vs `.25`)
5. `DYNAMIC_AGENT_SCRIPT` path referenced `/opt/` but code is in `/tmp/`
6. `pipeline-job-config.xml` hardcoded `local-security-agent` label

**Check 1: Are you using the scan client?**
Dynamic agents are only created when scans are triggered via the client (`curl` one-liner). Jenkins UI builds always use `local-security-agent`.

**Check 2: Is the scan server running?**
```bash
curl -s http://132.186.17.22:9091/scan | head -1
# Should return the client script
```

**Check 3: Jenkins URL consistency**
All scripts should use the same Jenkins URL. Verify:
```bash
grep -r "JENKINS_URL" jenkins/scripts/ | grep -v ".pyc"
# All should point to http://132.186.17.25:32000
```

**Check 4: Agent creation via API**
```bash
# Test manual agent creation
./jenkins/scripts/dynamic-agent-manager.sh create test-$(date +%s)
# Check status
./jenkins/scripts/dynamic-agent-manager.sh list
# Cleanup
./jenkins/scripts/dynamic-agent-manager.sh cleanup
```

### SBOM Not Generated

**Check 1: GENERATE_SBOM parameter**
Ensure `GENERATE_SBOM=true` is passed (default is true).

**Check 2: Trivy version**
```bash
trivy --version  # Should be v0.49+ for CycloneDX support
```

**Check 3: Output directory**
```bash
ls -la pipeline-reports/sbom/   # DevSecOps pipeline
ls -la security-reports/sbom/   # Security scan pipeline
```

---

## Security Scan Coverage Matrix

| Scan Type | Tool | Pipeline | Output Format |
|-----------|------|----------|---------------|
| Secret Detection | Trivy | All 3 | JSON + Table |
| SAST (Vulnerabilities) | Trivy, Bandit | Security, DevSecOps | JSON + Table |
| SCA (Dependencies) | Trivy, Grype, OWASP DC | All 3 | JSON + Table |
| Container Image | Trivy, Grype | All 3 | JSON + Table |
| K8s Manifests | Trivy config, Kubesec | Security, DevSecOps | JSON + Table |
| Dockerfile | Hadolint | DevSecOps | Text |
| Shell Scripts | ShellCheck | DevSecOps | Text |
| Code Quality | SonarQube | CI/CD, DevSecOps | SonarQube Dashboard |
| **SBOM (CycloneDX)** | **CycloneDX tools, Trivy** | **DevSecOps, Security** | **CycloneDX JSON** |
| **SBOM (SPDX)** | **Trivy** | **DevSecOps, Security** | **SPDX JSON** |
| Registry All-Images | Trivy | Security Scan | Table |
| Cluster Audit | Trivy K8s | Security | JSON |
