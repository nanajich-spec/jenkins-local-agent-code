# DevOps Platform — Jenkins CI/CD, App Deployments & Container Registry

> Centralized DevOps platform: Jenkins pipelines, security scanning, Kubernetes
> application deployments, container registry management, and zero-setup scanning for all users.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Repository Structure](#repository-structure)
3. [Quick Start — For Users](#quick-start--for-users)
4. [Quick Start — For Admins](#quick-start--for-admins)
5. [Jenkins CI/CD](#jenkins-cicd)
6. [Cat-Deployments (Application Manifests)](#cat-deployments)
7. [Container Registry](#container-registry)
8. [Security Scanning](#security-scanning)
9. [Developer Workflow](#developer-workflow)
10. [Configuration Reference](#configuration-reference)
11. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    DEVELOPER WORKSTATION                        │
│                                                                 │
│  git push → triggers pipeline   OR   ./jenkins/scripts/pipeline-trigger │
└────────────────┬────────────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────────────┐
│              JENKINS MASTER  (K8s Pod, port 32000)              │
│                                                                 │
│  ┌─────────┐  ┌────────────────────┐  ┌──────────────────────┐ │
│  │ Web UI  │  │ Pipeline Engine    │  │ Shared Library       │ │
│  │ :32000  │  │ (Jenkinsfile)      │  │ (vars/*.groovy)      │ │
│  └─────────┘  └────────┬───────────┘  └──────────────────────┘ │
└─────────────────────────┼───────────────────────────────────────┘
                          │ JNLP (:50000)
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│              JENKINS AGENT  (inblrmanappph06)                   │
│                                                                 │
│  Tools: Trivy, Grype, Hadolint, ShellCheck, Kubesec, Podman   │
│                                                                 │
│  Pipelines:                                                     │
│  ┌─────────────────┐    ┌───────────────────┐                  │
│  │ CI/CD Pipeline  │    │ Security Pipeline │                  │
│  │ (multi-language) │    │ (vuln scanning)   │                  │
│  └────────┬────────┘    └────────┬──────────┘                  │
│           │                      │                              │
│           ▼                      ▼                              │
│  Detect → Lint → Test      Secret → SAST → SCA                │
│  → Build → Docker          → Image → K8s → Gate               │
│  → Security → Deploy       → Report                           │
└─────────────────────────────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────────────┐
│  LOCAL REGISTRY (132.186.17.22:5000)  │  KUBERNETES CLUSTER    │
│  Docker/Podman images                 │  App deployments       │
└───────────────────────────────────────┴─────────────────────────┘
```

---

## Repository Structure

```
├── README.md                           ← This file
├── .gitignore
│
├── jenkins/                            ← Jenkins CI/CD Platform
│   ├── infrastructure/                 ← K8s deployment manifests
│   │   ├── deploy.sh                   (one-command setup)
│   │   ├── namespace.yml
│   │   ├── deployment.yml
│   │   ├── service.yml                 (NodePort 32000)
│   │   ├── pv.yml / pvc.yml
│   │   ├── service-account.yml
│   │   ├── kubernetes-group-cluster-admin.yaml
│   │   ├── configmaps/
│   │   │   ├── init-groovy.yml         (auto admin setup)
│   │   │   └── agent-init-groovy.yml   (JNLP agent config)
│   │   └── sonarqube/                  (SonarQube deployment)
│   │
│   ├── pipelines/
│   │   ├── ci-cd/                      ← Universal CI/CD Pipeline
│   │   │   ├── Jenkinsfile             (13 stages, multi-language)
│   │   │   └── pipeline.yaml
│   │   └── security/                   ← Security Scanning Pipeline
│   │       ├── Jenkinsfile             (11 stages)
│   │       └── pipeline.yaml
│   │
│   ├── scripts/
│   │   ├── jenkins-agent-connect.sh    (agent setup/start/stop)
│   │   ├── dev-security-scan.sh        (full automated scan)
│   │   ├── pipeline-trigger.sh         (trigger via API)
│   │   ├── install-security-tools.sh   (install Trivy, Grype, etc.)
│   │   ├── scan-all-images.sh          (scan registry images)
│   │   ├── create-pipeline-job.py      (create jobs via API)
│   │   ├── run-full-security-scan.sh
│   │   ├── setup-security-scanner.sh
│   │   └── client/                     ← Zero-Setup Client Distribution
│   │       ├── security-scan-client.sh (users download & run this)
│   │       ├── serve-scan-client.sh    (admin: start HTTP server)
│   │       └── scan-client-server.py   (HTTP distribution server)
│   │
│   ├── config/                         ← Scan configuration
│   │   ├── trivy.yaml / .trivyignore
│   │   ├── owasp-suppressions.xml
│   │   ├── sonar-project.properties
│   │   └── pipeline-job-config.xml
│   │
│   ├── shared-library/vars/            ← Reusable Groovy pipeline modules
│   │   ├── detectLanguage.groovy
│   │   ├── buildProject.groovy
│   │   ├── securityScan.groovy
│   │   ├── trivyImageScan.groovy
│   │   └── ... (13 modules)
│   │
│   ├── templates/                      ← Jenkinsfile templates per language
│   │   ├── Jenkinsfile.python
│   │   ├── Jenkinsfile.java
│   │   ├── Jenkinsfile.nodejs
│   │   └── Jenkinsfile.go
│   │
│   └── sonarqube-jenkins-pipeline-bundle.sh
│
├── cat-deployments/                    ← Application K8s Manifests
│   ├── catool/                         (Backend API + Workers)
│   │   ├── catool-deployment.yml
│   │   ├── catool-service.yml
│   │   ├── catool-ingress.yml
│   │   ├── catool-postgres-*.yml       (Database)
│   │   ├── catool-mq-*.yml            (RabbitMQ)
│   │   └── catool-worker-deployment.yml
│   │
│   ├── catool-ns/                      (Notification Service)
│   │   ├── catool-ns-deployment.yml
│   │   ├── catool-ns-ws-*.yml          (WebSocket)
│   │   └── catool-ns-db-deployment.yml
│   │
│   └── catool-ui/                      (Frontend UI)
│       ├── catool-ui-deployment.yml
│       ├── catool-ui-service.yml
│       ├── catool-ui-ingress.yml
│       └── tls-secret.yml
│
├── registry/                           ← Container Registry Setup
│   ├── setup/
│   │   ├── LOCAL_REGISTRY_SETUP.md     (setup guide)
│   │   ├── COMPLETE-REGISTRY-GUIDE.txt
│   │   ├── REGISTRY-ACCESS-INFO.txt
│   │   └── REGISTRY-WEB-UI-ACCESS.txt
│   └── scripts/
│       ├── push-images-to-local-registry.sh
│       ├── configure-k8s-insecure-registry.sh
│       ├── create-placeholder-images.sh
│       └── test-registry-push.sh
│
└── docs/                               ← Documentation
    ├── USER-GUIDE-SECURITY-SCAN.md     (zero-setup user guide)
    ├── DEPLOYMENT_SUMMARY.md
    ├── IMPLEMENTATION-TRACKER.md
    └── STORAGE-CLEANUP-REPORT.txt
```

---

## Quick Start — For Users

**Zero setup required.** Just run this ONE command from any machine on the network:

```bash
curl -sL http://132.186.17.22:9091/scan | bash
```

That's it. No tools, no agents, no configuration needed. Reports download to your local machine.

```bash
# Scan a specific image
curl -sL http://132.186.17.22:9091/scan | bash -s -- --image catool-ns --tag 1.0.0

# List available images in registry
curl -sL http://132.186.17.22:9091/scan | bash -s -- --list-images

# View scan history
curl -sL http://132.186.17.22:9091/scan | bash -s -- --history

# Check server status
curl -sL http://132.186.17.22:9091/scan | bash -s -- --status
```

See [docs/USER-GUIDE-SECURITY-SCAN.md](docs/USER-GUIDE-SECURITY-SCAN.md) for full details.

---

## Quick Start — For Admins

### 1. Deploy Jenkins (one command)

```bash
cd jenkins/infrastructure
./deploy.sh
```

Access Jenkins at `http://<node-ip>:32000` (login: `admin` / `admin`)

### 2. Connect an Agent

```bash
cd jenkins/scripts
./jenkins-agent-connect.sh --setup
./jenkins-agent-connect.sh --start
```

### 3. Run a Pipeline

**Option A — Use the universal CI/CD pipeline:**
Copy `jenkins/pipelines/ci-cd/Jenkinsfile` to your project root, push, and trigger.

**Option B — Use a language-specific template:**
Copy the matching template from `jenkins/templates/` to your project root as `Jenkinsfile`.

**Option C — Trigger from terminal:**
```bash
./jenkins/scripts/pipeline-trigger.sh --image myapp --tag v1.0
```

### 4. Start Client Distribution Server

```bash
cd jenkins/scripts/client
bash serve-scan-client.sh
```

This lets all users scan with `curl -sL http://132.186.17.22:9091/scan | bash`.

---

## Jenkins CI/CD

### Kubernetes Resources

| Resource | File | Details |
|----------|------|---------|
| Namespace | `jenkins/infrastructure/namespace.yml` | `jenkins` namespace |
| Deployment | `jenkins/infrastructure/deployment.yml` | Jenkins LTS, 1 replica, hostNetwork |
| Service | `jenkins/infrastructure/service.yml` | NodePort 32000 (HTTP), 50000 (JNLP) |
| PV | `jenkins/infrastructure/pv.yml` | 20Gi, hostPath `/data/jenkins` |
| PVC | `jenkins/infrastructure/pvc.yml` | 20Gi, bound to jenkins-pv |
| ServiceAccount | `jenkins/infrastructure/service-account.yml` | cluster-admin role |
| Init Groovy | `jenkins/infrastructure/configmaps/init-groovy.yml` | Creates admin user |
| Agent Config | `jenkins/infrastructure/configmaps/agent-init-groovy.yml` | Enables JNLP4 on port 50000 |

### Deploy / Delete / Status

```bash
./jenkins/infrastructure/deploy.sh              # Deploy all resources
./jenkins/infrastructure/deploy.sh --status     # Check pod/service status
./jenkins/infrastructure/deploy.sh --delete     # Tear down everything
```

---

## CI/CD Pipeline — How It Works

The universal pipeline at `jenkins/pipelines/ci-cd/Jenkinsfile` handles **any** project language
through auto-detection and language-specific stage logic.

### Pipeline Flow

```
┌──────────────────────────────────────────────────────────────────────┐
│                       CI/CD Pipeline Flow                           │
│                                                                      │
│  1. CHECKOUT & DETECT                                                │
│     └─ git clone + detectLanguage()                                  │
│        (checks requirements.txt, pom.xml, package.json, go.mod...) │
│                                                                      │
│  2. INSTALL DEPENDENCIES                                             │
│     ├─ Python:  pip install -r requirements.txt                      │
│     ├─ Java:    mvn dependency:resolve / gradle dependencies         │
│     ├─ Node:    npm ci / yarn install / pnpm install                 │
│     ├─ Go:      go mod download                                      │
│     └─ .NET:    dotnet restore                                       │
│                                                                      │
│  3. LINT & CODE QUALITY                                              │
│     ├─ Python:  flake8 + black + mypy + bandit                       │
│     ├─ Java:    checkstyle + spotbugs                                │
│     ├─ Node:    eslint + prettier + tsc                              │
│     ├─ Go:      go vet + golangci-lint + gofmt                       │
│     └─ .NET:    dotnet format                                        │
│                                                                      │
│  4. UNIT TESTS                                                       │
│     ├─ Python:  pytest --cov --junitxml                              │
│     ├─ Java:    mvn test / gradle test (JUnit + JaCoCo)              │
│     ├─ Node:    jest --ci --coverage                                 │
│     ├─ Go:      go test ./... -coverprofile                          │
│     └─ .NET:    dotnet test --collect:"XPlat Code Coverage"          │
│                                                                      │
│  5. INTEGRATION TESTS (optional)                                     │
│     └─ Language-specific integration test runners                    │
│                                                                      │
│  6. E2E TESTS (optional)                                             │
│     ├─ Cypress:     npx cypress run                                  │
│     ├─ Playwright:  npx playwright test                              │
│     └─ Selenium:    pytest tests/e2e/                                │
│                                                                      │
│  7. COVERAGE GATE                                                    │
│     └─ Checks coverage % >= threshold (default 70%)                 │
│                                                                      │
│  8. BUILD                                                            │
│     ├─ Python:  python -m build / setup.py bdist_wheel               │
│     ├─ Java:    mvn package / gradle build                           │
│     ├─ Node:    npm run build                                        │
│     ├─ Go:      go build -o app                                      │
│     └─ .NET:    dotnet publish                                       │
│                                                                      │
│  9. DOCKER BUILD & PUSH                                              │
│     └─ podman build + push → 132.186.17.22:5000                     │
│                                                                      │
│  10. SECURITY SCAN (parallel)                                        │
│      ├─ Trivy FS scan (vuln + misconfig + secret)                    │
│      ├─ Trivy Image scan                                             │
│      └─ Secret detection                                             │
│                                                                      │
│  11. SONARQUBE (optional)                                            │
│      └─ sonar-scanner + quality gate                                 │
│                                                                      │
│  12. SECURITY GATE                                                   │
│      └─ Fail/warn on CRITICAL vulnerabilities                        │
│                                                                      │
│  13. DEPLOY TO K8S (optional)                                        │
│      └─ kubectl set image → rollout status → health check            │
│                                                                      │
│  POST: Archive reports, publish HTML, cleanup workspace              │
└──────────────────────────────────────────────────────────────────────┘
```

### Pipeline Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `LANGUAGE` | `auto` | `auto`, `python`, `java-maven`, `java-gradle`, `nodejs`, `react`, `angular`, `vue`, `go`, `dotnet` |
| `GIT_REPO` | _(blank)_ | Git URL to checkout (blank = use workspace) |
| `GIT_BRANCH` | `main` | Branch to build |
| `IMAGE_NAME` | _(blank)_ | Docker image name (blank = skip Docker) |
| `IMAGE_TAG` | `latest` | Docker image tag |
| `RUN_UNIT_TESTS` | `true` | Run unit tests |
| `RUN_INTEGRATION_TESTS` | `false` | Run integration tests |
| `RUN_E2E_TESTS` | `false` | Run E2E tests (Cypress/Playwright) |
| `COVERAGE_THRESHOLD` | `70` | Minimum code coverage % |
| `RUN_LINT` | `true` | Run linting |
| `RUN_SECURITY_SCAN` | `true` | Run Trivy scans |
| `RUN_SONARQUBE` | `false` | Run SonarQube (needs server) |
| `DEPLOY_TO_K8S` | `false` | Deploy after build |
| `DEPLOY_ENV` | `staging` | `staging` or `production` |

---

## Security Pipeline — How It Works

The security pipeline at `jenkins/pipelines/security/Jenkinsfile` focuses exclusively on
vulnerability scanning, secret detection, and compliance.

### Stages

1. **Setup & Verify Tools** — Check Trivy, Grype, Hadolint, ShellCheck, Kubesec
2. **Checkout** — Git clone (optional)
3. **Secret Detection** — Trivy secret scanner
4. **SAST** — Trivy FS + Hadolint + ShellCheck (parallel)
5. **SCA** — Trivy + OWASP DC + Grype dependency scan (parallel)
6. **Container Image Scan** — Trivy + Grype image scan (parallel)
7. **Registry Image Scan** — Scan ALL images in registry
8. **K8s Manifest Scan** — Trivy config + Kubesec (parallel)
9. **Cluster Security Audit** — Live cluster scan
10. **Security Gate** — Pass/Fail on CRITICAL count
11. **Generate Report** — Consolidated HTML report

### Run Security Scan (Developer One-Liner)

```bash
# Full scan
bash jenkins/scripts/dev-security-scan.sh

# Scan specific image
bash jenkins/scripts/dev-security-scan.sh --image catool --tag latest --type image-only

# Scan all registry images
bash jenkins/scripts/dev-security-scan.sh --scan-registry
```

---

## Using Templates for Your Project

### Step 1: Choose a template

| Your Project | Template |
|-------------|----------|
| Python (Flask, Django, FastAPI) | `jenkins/templates/Jenkinsfile.python` |
| Java (Spring Boot, Maven/Gradle) | `jenkins/templates/Jenkinsfile.java` |
| Node.js / React / Angular / Vue | `jenkins/templates/Jenkinsfile.nodejs` |
| Go | `jenkins/templates/Jenkinsfile.go` |
| **Any language** (universal) | `jenkins/pipelines/ci-cd/Jenkinsfile` |

### Step 2: Copy to your project

```bash
# Python project
cp jenkins/templates/Jenkinsfile.python /path/to/your-project/Jenkinsfile

# OR use the universal pipeline (auto-detects language)
cp jenkins/pipelines/ci-cd/Jenkinsfile /path/to/your-project/Jenkinsfile
```

### Step 3: Edit the variables

Open the Jenkinsfile and change:
- `IMAGE_NAME` — your Docker image name
- `REGISTRY` — your registry URL (default: `132.186.17.22:5000`)
- Any test/build paths specific to your project

### Step 4: Create Jenkins job

1. Jenkins UI → **New Item** → **Pipeline**
2. Set **Pipeline script from SCM** → point to your repo
3. Build!

OR use the API script:
```bash
python3 jenkins/scripts/create-pipeline-job.py
```

---

## Shared Library Reference

Import in any Jenkinsfile:
```groovy
@Library('security-pipeline') _
```

### Available Functions

| Function | Usage | Description |
|----------|-------|-------------|
| `detectLanguage()` | `def lang = detectLanguage()` | Auto-detect project language from files |
| `buildProject(language: 'python')` | Build step for any language | |
| `runTests(language: 'python', type: 'unit')` | Run unit/integration/e2e tests | |
| `codeQuality(language: 'nodejs')` | Lint & quality checks per language | |
| `dockerBuild(image: 'app', tag: 'v1')` | Build & push container image | |
| `deployToK8s(image: 'reg/app:v1', deployment: 'app')` | K8s deploy + rollout + health | |
| `notifyResults(status: 'SUCCESS', channel: '#ci')` | Slack/Email notifications | |
| `securityScan(image: 'app', tag: 'v1')` | Full security scan orchestrator | |
| `trivyImageScan(image: 'reg/app:v1')` | Trivy container image scan | |
| `trivyFsScan(path: '.')` | Trivy filesystem scan | |
| `trivyK8sScan(manifestsDir: 'k8s/')` | K8s manifest misconfig scan | |
| `scanRegistryImages(registry: '...:5000')` | Scan all registry images | |
| `secretDetection(path: '.')` | Scan for hardcoded secrets | |

---

## Testing Guide

### Python Projects

**Required structure:**
```
your-project/
├── requirements.txt          # or setup.py / pyproject.toml
├── src/ or your_package/
├── tests/
│   ├── __init__.py
│   ├── test_main.py          # unit tests
│   ├── integration/
│   │   └── test_api.py       # integration tests (optional)
│   └── e2e/
│       └── test_ui.py        # e2e tests (optional)
├── pytest.ini or setup.cfg   # pytest config (optional)
└── Jenkinsfile
```

**What runs:**
- `pytest tests/ --cov=. --junitxml=results.xml` (unit)
- `pytest -m integration` (integration)
- `pytest tests/e2e/ -m e2e` (e2e)
- Coverage threshold enforced (default 70%)

### Java Projects

**Required structure (Maven):**
```
your-project/
├── pom.xml
├── src/
│   ├── main/java/
│   └── test/java/            # JUnit tests
├── Dockerfile (optional)
└── Jenkinsfile
```

**What runs:**
- `mvn test` → JUnit + Surefire reports
- `mvn jacoco:report` → coverage
- `mvn checkstyle:check` → lint
- `mvn package` → build JAR/WAR

### Node.js / React / Angular / Vue Projects

**Required structure:**
```
your-project/
├── package.json              # must have "test" and "build" scripts
├── src/
├── cypress.config.js         # for E2E (optional)
├── Dockerfile (optional)
└── Jenkinsfile
```

**What runs:**
- `npm ci` → install
- `npx eslint .` → lint
- `npx jest --ci --coverage` → unit tests
- `npx cypress run` → E2E (if config exists)
- `npm run build` → build
- `npm audit` → security

### Go Projects

**Required structure:**
```
your-project/
├── go.mod
├── main.go
├── *_test.go                 # test files
├── Dockerfile (optional)
└── Jenkinsfile
```

**What runs:**
- `go mod download` → install
- `go vet ./...` → lint
- `go test ./... -coverprofile=coverage.out` → test + coverage
- `go build -o app ./...` → build

---

## Developer Workflow

### Day-to-Day: Commit → Pipeline → Deploy

```
1. Developer writes code + tests
2. git push to repo
3. Jenkins detects change (webhook or poll)
4. Pipeline auto-runs:
   a. Detects language (Python/Java/Node/Go/etc.)
   b. Installs dependencies
   c. Runs linting
   d. Runs tests (unit → integration → e2e)
   e. Checks coverage (≥70%)
   f. Builds application
   g. Builds Docker image → pushes to registry
   h. Runs security scan (Trivy)
   i. Deploys to K8s (if enabled)
5. Results: Jenkins UI, reports, Slack/email
```

### Triggering Pipelines Manually

```bash
# From terminal — trigger with parameters
./jenkins/scripts/pipeline-trigger.sh --image myapp --tag v2.0 --type full

# Security scan only
bash jenkins/scripts/dev-security-scan.sh --image myapp --tag v2.0 --type image-only
```

---

## Configuration Reference

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `JENKINS_URL` | `http://132.186.17.25:32000` | Jenkins master URL |
| `JENKINS_USER` | `admin` | Jenkins username |
| `JENKINS_PASS` | `admin` | Jenkins password |
| `REGISTRY` | `132.186.17.22:5000` | Container registry |

### Config Files

| File | Purpose |
|------|---------|
| `jenkins/config/trivy.yaml` | Trivy scanner settings (severity, scanners, license rules) |
| `jenkins/config/.trivyignore` | CVEs to suppress (accepted risks) |
| `jenkins/config/owasp-suppressions.xml` | OWASP Dependency-Check suppressions |
| `jenkins/config/sonar-project.properties` | SonarQube project settings |
| `jenkins/config/pipeline-job-config.xml` | Jenkins job definition (XML) |

---

## Troubleshooting

### Jenkins pod not starting
```bash
kubectl get pods -n jenkins
kubectl describe pod -n jenkins -l app=jenkins
kubectl logs -n jenkins -l app=jenkins
```

### Agent not connecting
```bash
# Check agent status
./jenkins/scripts/jenkins-agent-connect.sh --status

# Restart agent
./jenkins/scripts/jenkins-agent-connect.sh --stop
./jenkins/scripts/jenkins-agent-connect.sh --start

# Check JNLP port
curl -v http://<jenkins-ip>:50000
```

### Pipeline fails at "Install Dependencies"
- Ensure the language runtime is installed on the agent (python3, java, node, go)
- Check network access for package downloads (pip, npm, maven)

### Docker/Podman build fails
```bash
# Check podman
podman --version
podman info

# Test registry access
curl http://132.186.17.22:5000/v2/_catalog
```

### Trivy scan fails
```bash
# Test Trivy directly
trivy image --podman-host "" 132.186.17.22:5000/myapp:latest

# Update DB
trivy image --download-db-only
```

### Coverage below threshold
- Default threshold is 70% — adjust via `COVERAGE_THRESHOLD` parameter
- Add more tests to increase coverage
- Check that coverage tool is configured for your language

---

## Scripts Reference

| Script | Purpose | Usage |
|--------|---------|-------|
| `infrastructure/deploy.sh` | Deploy/delete/status Jenkins on K8s | `./deploy.sh` |
| `jenkins/scripts/jenkins-agent-connect.sh` | Setup/start/stop JNLP agent | `./jenkins-agent-connect.sh --setup` |
| `jenkins/scripts/install-security-tools.sh` | Install Trivy, Grype, etc. | `sudo ./install-security-tools.sh` |
| `jenkins/scripts/dev-security-scan.sh` | One-command security scan | `bash dev-security-scan.sh` |
| `jenkins/scripts/pipeline-trigger.sh` | Trigger pipeline from terminal | `./pipeline-trigger.sh --image app` |
| `jenkins/scripts/scan-all-images.sh` | Scan all registry images | `./scan-all-images.sh` |
| `jenkins/scripts/setup-security-scanner.sh` | Host scanner for developers | `sudo ./setup-security-scanner.sh` |
| `jenkins/scripts/create-pipeline-job.py` | Create Jenkins job via API | `python3 create-pipeline-job.py` |
