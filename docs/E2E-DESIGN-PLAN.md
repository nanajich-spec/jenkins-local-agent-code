# Security Scan Tool — End-to-End Design Plan

> **Date:** 2026-04-07  
> **Version:** 2.0.0  
> **Status:** Implementation Complete

---

## 1. Purpose & Goals

This document describes the complete end-to-end architecture, workflow, and
component design for the DevSecOps Security Scan platform, now backed by a
proper OpenAPI-specified REST API.

| Goal | How achieved |
|------|-------------|
| Zero-setup developer scan | `curl … /scan \| bash` one-liner unchanged |
| Structured, versioned API | OpenAPI 3.1.0 spec + FastAPI implementation |
| Async, scalable server | Replaces ad-hoc `http.server` with async uvicorn |
| Interactive docs | Swagger UI (`/docs`) and ReDoc (`/redoc`) auto-generated |
| Observable | `/health` + `/health/ready` probes for k8s liveness checks |
| Report access via REST | `GET /reports/{scan_id}/summary`, `/download`, `/artifact` |

---

## 2. Repository Layout (new `api/` tree)

```
api/
├── openapi.yaml              ← Single source of truth for API contract
├── main.py                   ← FastAPI app, lifespan, router wiring
├── config.py                 ← Pydantic-settings (env-driven, .env file)
├── models.py                 ← All Pydantic request/response schemas
├── requirements.txt          ← Python dependencies
├── routers/
│   ├── health.py             ← GET /health   GET /health/ready
│   ├── scan.py               ← GET /scan   POST /scan/upload   POST /scan/cleanup
│   │                            GET /scan/{id}/status|logs   POST /scan/{id}/cancel
│   ├── agent.py              ← POST /agent/create|destroy|status   GET /agent/list
│   ├── pipeline.py           ← POST /pipeline/trigger
│   │                            GET  /pipeline/{name}/builds[/{n}]
│   └── reports.py            ← GET /reports/{id}[/summary|/download|/{artifact}]
└── services/
    ├── jenkins.py            ← Async Jenkins REST client (crumb, build, nodes, logs)
    ├── agent_manager.py      ← Async wrapper over dynamic-agent-manager.sh
    └── report_parser.py      ← Parse Trivy/SonarQube JSON → ScanSummary
```

---

## 3. End-to-End Workflow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        COMPLETE SCAN WORKFLOW                               │
└─────────────────────────────────────────────────────────────────────────────┘

 ① Developer Machine
 ┌──────────────────────────────────────────┐
 │  curl -sL http://HOST:9091/scan | bash   │
 │                                          │
 │  security-scan-client.sh                 │
 │  ① generate SCAN_ID: <user>-<host>-<ts> │
 │  ② tar -czf source.tar.gz .             │
 │  ③ POST /scan/upload (streaming 1GB max) │
 │  ④ POST /agent/create                   │
 │  ⑤ POST /pipeline/trigger               │
 │  ⑥ poll GET /scan/{id}/status every 5s  │
 │  ⑦ tail GET /scan/{id}/logs             │
 │  ⑧ GET  /reports/{id}/download          │
 │  ⑨ POST /agent/destroy                  │
 │  ⑩ POST /scan/cleanup                   │
 └──────────────────────────────────────────┘
         │ HTTP/1.1 (all to :9091)
         ▼
 ② FastAPI Server  (api/main.py  +  uvicorn)
 ┌──────────────────────────────────────────┐
 │  /scan/upload  →  save tar.gz to disk    │
 │  /agent/create →  spawn agent script     │
 │  /pipeline/trigger → Jenkins API call    │
 │  /scan/{id}/status → Jenkins API poll    │
 │  /scan/{id}/logs   → Jenkins consoleTxt  │
 │  /reports/{id}/... → parse JSON on disk  │
 │  /scan/cleanup     → rm -rf upload dir   │
 │  /agent/destroy    → kill JNLP process   │
 └──────────────────────────────────────────┘
         │
         ├───── subprocess ──────────────────────────────────────────────────┐
         │                                                                   │
         │  dynamic-agent-manager.sh create <scan_id>                       │
         │  ① check concurrency (max 10)                                    │
         │  ② mkdir /opt/jenkins-agent/dynamic/scan-agent-<id>/             │
         │  ③ Jenkins Groovy API → createDumbSlave                          │
         │  ④ retrieve JNLP secret                                          │
         │  ⑤ java -jar agent.jar (background)                             │
         │  ⑥ poll /computer/<name>/api/json until online                   │
         └───────────────────────────────────────────────────────────────────┘
         │
         └───── HTTP ─────────────────────────────────────────────────────────┐
                                                                              │
 ③ Jenkins Master  (http://132.186.17.25:32000)                               │
 ┌──────────────────────────────────────────────────────────────────────┐     │
 │  Receives: POST /job/<pipeline>/buildWithParameters                  │◄────┘
 │  Parameters forwarded:                                               │
 │    AGENT_LABEL, SCAN_ID, SCAN_TYPE, SOURCE_UPLOAD_PATH,             │
 │    GENERATE_SBOM, FAIL_ON_CRITICAL, IMAGE_NAME, IMAGE_TAG           │
 │                                                                      │
 │  Pipeline stages executed on dynamic agent:                          │
 │  (security-scan-pipeline — 11 stages)                                │
 │  ① Setup + source extract                                           │
 │  ② Secret Detection       (trivy fs --scanners secret)              │
 │  ③ SAST / Vuln Scan       (trivy fs --scanners vuln,misconfig)      │
 │  ④ SCA / Dependency Scan  (trivy fs --scanners vuln)                │
 │  ⑤ Image Scan             (trivy image)                             │
 │  ⑥ K8s Manifest Scan      (trivy config)                            │
 │  ⑦ Registry Scan          (trivy image for each registry image)     │
 │  ⑧ SBOM Generation        (trivy fs --format cyclonedx / spdx-json) │
 │  ⑨ SonarQube Analysis     (sonar-scanner)                           │
 │  ⑩ Security Gate          (count CRITICAL; fail/warn/pass)          │
 │  ⑪ Archive + Cleanup      (archive artifacts, copy to reports dir)  │
 └──────────────────────────────────────────────────────────────────────┘
                │ reports written to agent filesystem
                ▼
 ④ Agent Filesystem  /opt/scan-reports/<scan_id>/
 ┌──────────────────────────────────────────────────────────────────────┐
 │  secret-scan.json               Trivy secret findings               │
 │  trivy-fs-scan.json             SAST + misconfig findings            │
 │  trivy-sca.json                 SCA dependency findings              │
 │  trivy-image-scan.json          Container image findings             │
 │  trivy-k8s-scan.json            Kubernetes manifest findings         │
 │  registry-scan-<image>.json     Registry image findings (per image)  │
 │  sbom/trivy-cyclonedx-full.json CycloneDX SBOM                      │
 │  sbom/trivy-spdx-sbom.json      SPDX SBOM                           │
 │  sonarqube-analysis.txt         SonarQube analysis report           │
 │  sonarqube-quality-gate.json    SonarQube quality gate result        │
 │  shellcheck-report.json         ShellCheck findings                  │
 │  hadolint-report.json           Hadolint Dockerfile findings         │
 │  gate-results.txt               Security gate Pass / Fail verdict    │
 └──────────────────────────────────────────────────────────────────────┘
                │ read by
                ▼
 ⑤ ReportParser service  (api/services/report_parser.py)
 ┌──────────────────────────────────────────────────────────────────────┐
 │  GET /reports/{id}/summary  →  ScanSummary JSON                     │
 │  GET /reports/{id}/download →  tar.gz of all artifacts              │
 │  GET /reports/{id}/{artifact} → individual file                     │
 └──────────────────────────────────────────────────────────────────────┘
```

---

## 4. API Surface Summary

| Method | Path | Purpose |
|--------|------|---------|
| `GET`  | `/health` | Liveness probe |
| `GET`  | `/health/ready` | Readiness probe (checks Jenkins, SonarQube, registry) |
| `GET`  | `/scan` | Download `security-scan-client.sh` |
| `POST` | `/scan/upload` | Upload `source.tar.gz` (stream, ≤ 1 GB) |
| `GET`  | `/scan/{id}/status` | Poll Jenkins build status |
| `GET`  | `/scan/{id}/logs` | Stream Jenkins console log |
| `POST` | `/scan/{id}/cancel` | Abort running build |
| `POST` | `/scan/cleanup` | Delete uploaded source files |
| `POST` | `/agent/create` | Provision dynamic JNLP agent |
| `POST` | `/agent/destroy` | Tear down JNLP agent |
| `POST` | `/agent/status` | Query single or all agent status |
| `GET`  | `/agent/list` | List all active dynamic agents |
| `POST` | `/pipeline/trigger` | Trigger Jenkins build with parameters |
| `GET`  | `/pipeline/{name}/builds` | List recent builds |
| `GET`  | `/pipeline/{name}/builds/{n}` | Single build detail + parameters |
| `GET`  | `/reports/{id}` | List report artifact file names |
| `GET`  | `/reports/{id}/summary` | Structured finding counts + gate verdict |
| `GET`  | `/reports/{id}/download` | Download all reports as `.tar.gz` |
| `GET`  | `/reports/{id}/{artifact}` | Download single artifact file |

---

## 5. OpenAPI Spec & Tooling

### Spec location
```
api/openapi.yaml   (OpenAPI 3.1.0)
```

### Validate spec
```bash
python -c "
from openapi_spec_validator import validate
import yaml, pathlib
spec = yaml.safe_load(pathlib.Path('api/openapi.yaml').read_text())
validate(spec)
print('✓ Spec is valid')
"
```

### Generate client SDK (example — Python)
```bash
# Using openapi-generator-cli (docker)
docker run --rm -v $PWD:/local openapitools/openapi-generator-cli generate \
  -i /local/api/openapi.yaml \
  -g python \
  -o /local/sdk/python \
  --additional-properties=packageName=security_scan_client
```

### Generate TypeScript SDK
```bash
docker run --rm -v $PWD:/local openapitools/openapi-generator-cli generate \
  -i /local/api/openapi.yaml \
  -g typescript-fetch \
  -o /local/sdk/typescript
```

---

## 6. Running the API

### Development
```bash
cd /tmp/jenkins-local-agent-code
pip install -r api/requirements.txt
uvicorn api.main:app --host 0.0.0.0 --port 9091 --reload
```

### Production (replaces scan-client-server.py)
```bash
uvicorn api.main:app \
  --host 0.0.0.0 \
  --port 9091 \
  --workers 4 \
  --log-level info
```

### Environment variables (override defaults)
```bash
export JENKINS_URL=http://132.186.17.25:32000
export JENKINS_TOKEN=<your-api-token>
export UPLOAD_DIR=/opt/scan-uploads
export REPORTS_DIR=/opt/scan-reports
export MAX_DYNAMIC_AGENTS=10
```

Or create `api/.env`:
```ini
JENKINS_URL=http://132.186.17.25:32000
JENKINS_TOKEN=your-token-here
UPLOAD_DIR=/opt/scan-uploads
REPORTS_DIR=/opt/scan-reports
LOG_LEVEL=info
```

### Interactive docs
```
http://HOST:9091/docs     ← Swagger UI
http://HOST:9091/redoc    ← ReDoc
http://HOST:9091/openapi.json  ← raw schema
```

---

## 7. Security Scan Tool Coverage Matrix

### Source Code Scans

| # | Scan Layer | Tool | Triggers | Report Output |
|---|-----------|------|----------|---------------|
| 1 | **Secret Detection** | Trivy `--scanners secret` | `code-only`, `full` | `secret-scan.json` |
| 2 | **SAST / Vulnerability** | Trivy `--scanners vuln,misconfig` | `code-only`, `full` | `trivy-fs-scan.json` |
| 3 | **SCA / Dependency** | Trivy `--scanners vuln` | `code-only`, `full` | `trivy-sca.json` |
| 4 | **Code Quality** | SonarQube `sonar-scanner` | always | `sonarqube-analysis.txt`, `sonarqube-quality-gate.json` |
| 5 | **Shell Scripts** | ShellCheck | DevSecOps pipeline | `shellcheck-report.json` |
| 6 | **Dockerfiles** | Hadolint | DevSecOps pipeline | `hadolint-report.json` |

### Container & Image Scans

| # | Scan Layer | Tool | Triggers | Report Output |
|---|-----------|------|----------|---------------|
| 7 | **Container Image** | Trivy `image` | `image-only`, `full` | `trivy-image-scan.json` |
| 8 | **Registry All-Images** | Trivy `image` | `SCAN_REGISTRY_IMAGES=true` | `registry-scan-<image>.json` (per image) |

### Infrastructure & Config Scans

| # | Scan Layer | Tool | Triggers | Report Output |
|---|-----------|------|----------|---------------|
| 9 | **K8s Manifests** | Trivy `config` | always | `trivy-k8s-scan.json` |

### Software Bill of Materials (SBOM)

| # | Scan Layer | Tool | Triggers | Report Output |
|---|-----------|------|----------|---------------|
| 10 | **SBOM — CycloneDX** | Trivy `--format cyclonedx` | `GENERATE_SBOM=true` | `sbom/trivy-cyclonedx-full.json` |
| 11 | **SBOM — SPDX** | Trivy `--format spdx-json` | `GENERATE_SBOM=true` | `sbom/trivy-spdx-sbom.json` |

---

## 8. Configuration Reference

| Env var | Default | Description |
|---------|---------|-------------|
| `API_HOST` | `0.0.0.0` | Bind address |
| `API_PORT` | `9091` | Bind port |
| `JENKINS_URL` | `http://132.186.17.25:32000` | Jenkins master |
| `JENKINS_USER` | `admin` | Jenkins user for API auth |
| `JENKINS_TOKEN` | `` | Jenkins API token (required for trigger) |
| `UPLOAD_DIR` | `/opt/scan-uploads` | Source upload storage |
| `REPORTS_DIR` | `/opt/scan-reports` | Scan results storage |
| `SERVE_DIR` | `/opt/scan-client-server` | Dir holding `scan` script |
| `DYNAMIC_AGENT_SCRIPT` | (repo path) | Path to `dynamic-agent-manager.sh` |
| `MAX_DYNAMIC_AGENTS` | `10` | Max simultaneous JNLP agents |
| `AGENT_CREATION_TIMEOUT` | `120` | Seconds before agent create times out |
| `MAX_UPLOAD_BYTES` | `1073741824` | 1 GB upload limit |
| `REGISTRY` | `132.186.17.22:5000` | Container registry |
| `SONARQUBE_URL` | `http://132.186.17.22:32001` | SonarQube server |
| `LOG_LEVEL` | `info` | Python logging level |

---

## 9. Deployment — Replace Legacy Server

```bash
# 1. Kill old http.server-based scan server (if running)
pkill -f scan-client-server.py

# 2. Install deps (one-time)
pip3 install -r /tmp/jenkins-local-agent-code/api/requirements.txt

# 3. Start new FastAPI server
cd /tmp/jenkins-local-agent-code
JENKINS_TOKEN=<token> uvicorn api.main:app --host 0.0.0.0 --port 9091

# 4. Verify
curl http://localhost:9091/health
# {"status":"ok","timestamp":"...","version":"2.0.0"}

curl http://localhost:9091/health/ready
# {"ready":true,"checks":{"jenkins":{"ok":true,...},...}}
```

---

## 10. Future Enhancements

| Item | Priority | Notes |
|------|----------|-------|
| JWT / API-key auth middleware | High | Protect `/pipeline/trigger` and `/agent/create` |
| WebSocket endpoint for live log streaming | Medium | Replace polling `/scan/{id}/logs` |
| Persistent scan state (SQLite / Redis) | Medium | Survive API restarts; currently in-memory dict |
| Rate limiting | Medium | `slowapi` / `starlette-limiter` |
| Prometheus metrics endpoint `/metrics` | Low | Track scan counts, durations, error rates |
| Webhook callbacks | Low | `POST` result to caller URL when scan finishes |
| Multi-tenant scan isolation | Low | Namespace uploads + reports per user/org |
