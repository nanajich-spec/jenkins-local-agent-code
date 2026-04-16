#!/usr/bin/env bash
# =============================================================================
# run-comprehensive-devsecops.sh
# =============================================================================
# Single command to trigger the Comprehensive DevSecOps Pipeline
# Scans the ENTIRE root folder with CycloneDX SBOM, Unit Tests, Coverage,
# SonarQube, Trivy, Secret Detection, and generates comprehensive reports.
#
# Usage:
#   ./run-comprehensive-devsecops.sh                    # Default (auto-detect)
#   ./run-comprehensive-devsecops.sh --language python  # Force language
#   ./run-comprehensive-devsecops.sh --image myapp --tag 1.0.0
#   ./run-comprehensive-devsecops.sh --no-sonar --no-sbom
#
# Reports Output:
#   pipeline-reports/
#   ├── comprehensive-report.html     ← Final comprehensive HTML report
#   ├── comprehensive-report.txt      ← Console-friendly text report
#   ├── comprehensive-report.json     ← Machine-readable JSON summary
#   ├── pytest-unit-results.xml       ← Unit test results
#   ├── coverage.xml                  ← Code coverage
#   ├── sonarqube/                    ← SonarQube reports
#   ├── sbom/                         ← CycloneDX SBOM files
#   ├── trivy-*.json                  ← Trivy scan reports
#   ├── secret-scan.json              ← Secret detection
#   ├── hadolint.json                 ← Dockerfile lint
#   ├── shellcheck.json               ← Shell script analysis
#   └── gate-results.txt              ← Security gate pass/fail
# =============================================================================

set -euo pipefail

# ── Defaults ──
JENKINS_URL="${JENKINS_URL:-http://localhost:8080}"
JENKINS_USER="${JENKINS_USER:-admin}"
JENKINS_TOKEN="${JENKINS_TOKEN:-}"
JOB_NAME="${JOB_NAME:-devsecops-pipeline}"

LANGUAGE="auto"
IMAGE_NAME=""
IMAGE_TAG="latest"
REGISTRY="132.186.17.22:5000"
GIT_REPO=""
GIT_BRANCH="main"
COVERAGE_THRESHOLD="70"
SCAN_MODE="code-only"
STRICT_MODE="false"
LOCAL_REPORT_DIR="pipeline-reports"
GENERATE_SBOM="true"
RUN_SONARQUBE="true"
RUN_TRIVY="true"
RUN_TESTS="true"
RUN_SECRETS="true"
RUN_K8S_SCAN="true"
FAIL_ON_CRITICAL="true"
SONAR_PROJECT_KEY=""
AGENT_LABEL="local-security-agent"

# ── Parse Arguments ──
while [[ $# -gt 0 ]]; do
    case "$1" in
        --language)       LANGUAGE="$2"; shift 2 ;;
        --image)          IMAGE_NAME="$2"; shift 2 ;;
        --tag)            IMAGE_TAG="$2"; shift 2 ;;
        --registry)       REGISTRY="$2"; shift 2 ;;
        --git-repo)       GIT_REPO="$2"; shift 2 ;;
        --branch)         GIT_BRANCH="$2"; shift 2 ;;
        --coverage)       COVERAGE_THRESHOLD="$2"; shift 2 ;;
        --scan-mode)      SCAN_MODE="$2"; shift 2 ;;
        --strict-mode)    STRICT_MODE="true"; shift ;;
        --local-report-dir) LOCAL_REPORT_DIR="$2"; shift 2 ;;
        --sonar-key)      SONAR_PROJECT_KEY="$2"; shift 2 ;;
        --agent)          AGENT_LABEL="$2"; shift 2 ;;
        --no-sbom)        GENERATE_SBOM="false"; shift ;;
        --no-sonar)       RUN_SONARQUBE="false"; shift ;;
        --no-trivy)       RUN_TRIVY="false"; shift ;;
        --no-tests)       RUN_TESTS="false"; shift ;;
        --no-secrets)     RUN_SECRETS="false"; shift ;;
        --no-k8s-scan)    RUN_K8S_SCAN="false"; shift ;;
        --no-fail)        FAIL_ON_CRITICAL="false"; shift ;;
        --jenkins-url)    JENKINS_URL="$2"; shift 2 ;;
        --jenkins-user)   JENKINS_USER="$2"; shift 2 ;;
        --jenkins-token)  JENKINS_TOKEN="$2"; shift 2 ;;
        --job)            JOB_NAME="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --language <lang>    Language: auto|python|java-maven|java-gradle|nodejs|react|angular|go|dotnet"
            echo "  --image <name>       Docker image name"
            echo "  --tag <tag>          Docker image tag (default: latest)"
            echo "  --registry <url>     Container registry (default: 132.186.17.22:5000)"
            echo "  --git-repo <url>     Git repository URL"
            echo "  --branch <branch>    Git branch (default: main)"
            echo "  --coverage <pct>     Coverage threshold % (default: 70)"
            echo "  --scan-mode <mode>   full|code-only|image-only|k8s-manifests (default: code-only)"
            echo "  --strict-mode        Enable blocking gate mode"
            echo "  --local-report-dir   Local report directory hint (default: pipeline-reports)"
            echo "  --sonar-key <key>    SonarQube project key"
            echo "  --agent <label>      Jenkins agent label"
            echo "  --no-sbom            Skip SBOM generation"
            echo "  --no-sonar           Skip SonarQube analysis"
            echo "  --no-trivy           Skip Trivy scans"
            echo "  --no-tests           Skip unit tests"
            echo "  --no-secrets         Skip secret detection"
            echo "  --no-k8s-scan        Skip K8s manifest scan"
            echo "  --no-fail            Don't fail on critical issues"
            echo "  --jenkins-url <url>  Jenkins URL"
            echo "  --jenkins-user <u>   Jenkins user"
            echo "  --jenkins-token <t>  Jenkins API token"
            echo "  --job <name>         Jenkins job name"
            echo "  -h, --help           Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ── Display Configuration ──
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Comprehensive DevSecOps Pipeline — Trigger                ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Language:       ${LANGUAGE}"
echo "║  Image:          ${IMAGE_NAME:-N/A}"
echo "║  Tag:            ${IMAGE_TAG}"
echo "║  Registry:       ${REGISTRY}"
echo "║  Git Repo:       ${GIT_REPO:-workspace}"
echo "║  Branch:         ${GIT_BRANCH}"
echo "║  Coverage:       ${COVERAGE_THRESHOLD}%"
echo "║  Scan Mode:      ${SCAN_MODE}"
echo "║  Strict Mode:    ${STRICT_MODE}"
echo "║  Report Dir:     ${LOCAL_REPORT_DIR}"
echo "║  SBOM:           ${GENERATE_SBOM}"
echo "║  SonarQube:      ${RUN_SONARQUBE}"
echo "║  Trivy:          ${RUN_TRIVY}"
echo "║  Tests:          ${RUN_TESTS}"
echo "║  Secrets:        ${RUN_SECRETS}"
echo "║  K8s Scan:       ${RUN_K8S_SCAN}"
echo "║  Fail on Crit:   ${FAIL_ON_CRITICAL}"
echo "║  Jenkins URL:    ${JENKINS_URL}"
echo "║  Job:            ${JOB_NAME}"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── Method 1: Trigger via Jenkins API ──
if [ -n "${JENKINS_TOKEN}" ]; then
    echo "=== Triggering Jenkins pipeline via API ==="

    CRUMB=$(curl -s -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
        "${JENKINS_URL}/crumbIssuer/api/json" 2>/dev/null | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print(d['crumbRequestField']+':'+d['crumb'])" 2>/dev/null || echo "")

    PARAMS="LANGUAGE=${LANGUAGE}"
    PARAMS="${PARAMS}&IMAGE_NAME=${IMAGE_NAME}"
    PARAMS="${PARAMS}&IMAGE_TAG=${IMAGE_TAG}"
    PARAMS="${PARAMS}&REGISTRY=${REGISTRY}"
    PARAMS="${PARAMS}&GIT_REPO=${GIT_REPO}"
    PARAMS="${PARAMS}&GIT_BRANCH=${GIT_BRANCH}"
    PARAMS="${PARAMS}&COVERAGE_THRESHOLD=${COVERAGE_THRESHOLD}"
    PARAMS="${PARAMS}&UNIFIED_SCAN_MODE=${SCAN_MODE}"
    PARAMS="${PARAMS}&STRICT_MODE=${STRICT_MODE}"
    PARAMS="${PARAMS}&LOCAL_REPORT_DIR=${LOCAL_REPORT_DIR}"
    PARAMS="${PARAMS}&GENERATE_SBOM=${GENERATE_SBOM}"
    PARAMS="${PARAMS}&RUN_SONARQUBE=${RUN_SONARQUBE}"
    PARAMS="${PARAMS}&RUN_TRIVY_SCAN=${RUN_TRIVY}"
    PARAMS="${PARAMS}&RUN_UNIT_TESTS=${RUN_TESTS}"
    PARAMS="${PARAMS}&RUN_SECRET_DETECTION=${RUN_SECRETS}"
    PARAMS="${PARAMS}&RUN_K8S_MANIFEST_SCAN=${RUN_K8S_SCAN}"
    PARAMS="${PARAMS}&FAIL_ON_CRITICAL=${FAIL_ON_CRITICAL}"
    PARAMS="${PARAMS}&SONAR_PROJECT_KEY=${SONAR_PROJECT_KEY}"
    PARAMS="${PARAMS}&AGENT_LABEL=${AGENT_LABEL}"

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
        ${CRUMB:+-H "${CRUMB}"} \
        "${JENKINS_URL}/job/${JOB_NAME}/buildWithParameters?${PARAMS}")

    if [ "${HTTP_CODE}" = "201" ] || [ "${HTTP_CODE}" = "200" ]; then
        echo "Pipeline triggered successfully! (HTTP ${HTTP_CODE})"
        echo ""
        echo "Monitor at: ${JENKINS_URL}/job/${JOB_NAME}/"
        echo ""
        echo "After completion, download reports from:"
        echo "  ${JENKINS_URL}/job/${JOB_NAME}/lastBuild/artifact/pipeline-reports/"
    else
        echo "ERROR: Failed to trigger pipeline (HTTP ${HTTP_CODE})"
        echo "Falling back to CLI trigger..."
    fi

# ── Method 2: Trigger via Jenkins CLI ──
elif command -v jenkins-cli &>/dev/null || [ -f "/opt/jenkins-cli.jar" ]; then
    echo "=== Triggering via Jenkins CLI ==="

    CLI_CMD="java -jar /opt/jenkins-cli.jar -s ${JENKINS_URL}"
    ${CLI_CMD} build "${JOB_NAME}" \
        -p "LANGUAGE=${LANGUAGE}" \
        -p "IMAGE_NAME=${IMAGE_NAME}" \
        -p "IMAGE_TAG=${IMAGE_TAG}" \
        -p "GENERATE_SBOM=${GENERATE_SBOM}" \
        -p "RUN_SONARQUBE=${RUN_SONARQUBE}" \
        -p "RUN_TRIVY_SCAN=${RUN_TRIVY}" \
        -p "RUN_UNIT_TESTS=${RUN_TESTS}" \
        -p "FAIL_ON_CRITICAL=${FAIL_ON_CRITICAL}" \
        -s -v 2>&1 || echo "CLI trigger failed"

# ── Method 3: Direct local execution ──
else
    echo "=== No Jenkins API/CLI available — running pipeline stages locally ==="
    echo ""
    echo "To run the pipeline in Jenkins, configure the job with:"
    echo "  Pipeline script from SCM → jenkins/pipelines/devsecops/Jenkinsfile"
    echo ""
    echo "Or trigger via API:"
    echo "  export JENKINS_URL=http://your-jenkins:8080"
    echo "  export JENKINS_USER=admin"
    echo "  export JENKINS_TOKEN=your-api-token"
    echo "  $0 --language ${LANGUAGE}"
    echo ""

    # Run the comprehensive report generator locally if reports already exist
    REPORTS_DIR="${REPORTS_DIR:-./pipeline-reports}"
    if [ -d "${REPORTS_DIR}" ] && [ "$(ls -A ${REPORTS_DIR} 2>/dev/null)" ]; then
        echo "=== Found existing reports in ${REPORTS_DIR} — generating comprehensive report ==="
        SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
        export LANGUAGE IMAGE_NAME COVERAGE_THRESHOLD
        bash "${SCRIPT_DIR}/generate-comprehensive-report.sh" "${REPORTS_DIR}" "${LANGUAGE}" "${IMAGE_NAME:-N/A}"
    fi
fi
