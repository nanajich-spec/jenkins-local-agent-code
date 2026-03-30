#!/bin/bash
# =============================================================================
# trigger-devsecops-pipeline.sh — Trigger the Unified DevSecOps Pipeline
# =============================================================================
# Triggers the single end-to-end devsecops pipeline that handles:
#   Stage 0 : Bootstrap agent tools (Trivy, Hadolint, OWASP DC, SonarQube...)
#   Stage 1 : Checkout & language/Makefile/K8s detection
#   Stage 2 : Dependency install
#   Stage 3 : SAST / linting
#   Stage 4 : Unit tests (⚠ warning if no tests found)
#   Stage 5 : SCA — OWASP Dependency-Check
#   Stage 6 : SonarQube analysis
#   Stage 7 : Secret detection
#   Stage 8 : Filesystem / source Trivy scan
#   Stage 9 : Docker build (Makefile-first; ⚠ warning if no Dockerfile)
#   Stage 10: Trivy image scan + SBOM (only if image was built)
#   Stage 11: Grype image scan
#   Stage 12: SBOM generation (CycloneDX per language)
#   Stage 13: Dockerfile lint — Hadolint (⚠ warning if no Dockerfile)
#   Stage 14: ShellCheck
#   Stage 15: K8s manifest scan — Kubesec (⚠ warning if no K8s files)
#   Stage 16: Container config audit — Trivy config
#   Stage 17: Archive artifacts
#   Stage 18: Comprehensive report generation
#
# Usage:
#   ./trigger-devsecops-pipeline.sh [OPTIONS]
#
# Examples:
#   # Auto-detect language, run all scans + SBOM
#   ./trigger-devsecops-pipeline.sh
#
#   # Python project with Docker build & image scan
#   ./trigger-devsecops-pipeline.sh --language python --image-name myapp --image-tag v1.0
#
#   # Full pipeline including SonarQube + Grype
#   ./trigger-devsecops-pipeline.sh --image-name catool --run-sonarqube --run-grype
#
#   # Re-run with forced tool reinstall (after agent updates)
#   ./trigger-devsecops-pipeline.sh --force-reinstall
# =============================================================================

set -euo pipefail

# ── Defaults ──
JENKINS_URL="${JENKINS_URL:-http://132.186.17.25:32000}"
JENKINS_USER="${JENKINS_USER:-admin}"
JENKINS_PASS="${JENKINS_PASS:-}"
PIPELINE_JOB="devsecops-pipeline"

LANGUAGE="auto"
GIT_REPO=""
GIT_BRANCH="main"
IMAGE_NAME=""
IMAGE_TAG="latest"
REGISTRY="132.186.17.22:5000"
DOCKERFILE="Dockerfile"
RUN_UNIT_TESTS="true"
RUN_INTEGRATION_TESTS="false"
COVERAGE_THRESHOLD="70"
PYTEST_ARGS=""
RUN_TRIVY="true"
RUN_SECRETS="true"
RUN_K8S_SCAN="true"
RUN_DOCKERFILE_LINT="true"
RUN_OWASP="false"
RUN_GRYPE="false"
RUN_SONARQUBE="true"
GENERATE_SBOM="true"
FORCE_TOOL_REINSTALL="false"
FAIL_ON_CRITICAL="true"
DEPLOY_TO_K8S="false"
K8S_NAMESPACE=""
K8S_MANIFESTS_DIR="cat-deployments"
TIMEOUT="120"

# ── Parse Arguments ──
while [[ $# -gt 0 ]]; do
    case "$1" in
        --jenkins-url)      JENKINS_URL="$2"; shift 2;;
        --language)         LANGUAGE="$2"; shift 2;;
        --git-repo)         GIT_REPO="$2"; shift 2;;
        --git-branch)       GIT_BRANCH="$2"; shift 2;;
        --image-name)       IMAGE_NAME="$2"; shift 2;;
        --image-tag)        IMAGE_TAG="$2"; shift 2;;
        --registry)         REGISTRY="$2"; shift 2;;
        --dockerfile)       DOCKERFILE="$2"; shift 2;;
        --coverage)         COVERAGE_THRESHOLD="$2"; shift 2;;
        --pytest-args)      PYTEST_ARGS="$2"; shift 2;;
        --skip-tests)       RUN_UNIT_TESTS="false"; shift;;
        --skip-security)    RUN_TRIVY="false"; RUN_SECRETS="false"; RUN_K8S_SCAN="false"; RUN_DOCKERFILE_LINT="false"; shift;;
        --run-owasp)        RUN_OWASP="true"; shift;;
        --run-grype)        RUN_GRYPE="true"; shift;;
        --run-sonarqube)    RUN_SONARQUBE="true"; shift;;
        --no-sonarqube)     RUN_SONARQUBE="false"; shift;;
        --generate-sbom)    GENERATE_SBOM="true"; shift;;
        --no-sbom)          GENERATE_SBOM="false"; shift;;
        --force-reinstall)  FORCE_TOOL_REINSTALL="true"; shift;;
        --deploy)           DEPLOY_TO_K8S="true"; shift;;
        --namespace)        K8S_NAMESPACE="$2"; shift 2;;
        --manifests-dir)    K8S_MANIFESTS_DIR="$2"; shift 2;;
        --no-fail-critical) FAIL_ON_CRITICAL="false"; shift;;
        --timeout)          TIMEOUT="$2"; shift 2;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --language LANG       Language: auto|python|java-maven|nodejs|go|dotnet"
            echo "  --git-repo URL        Git repository URL"
            echo "  --git-branch BRANCH   Git branch (default: main)"
            echo "  --image-name NAME     Docker image name (enables Docker build)"
            echo "  --image-tag TAG       Docker image tag (default: latest)"
            echo "  --registry URL        Container registry (default: 132.186.17.22:5000)"
            echo "  --dockerfile PATH     Dockerfile path (default: Dockerfile)"
            echo "  --coverage PCT        Minimum coverage % (default: 70)"
            echo "  --pytest-args ARGS    Extra pytest arguments"
            echo "  --skip-tests          Skip unit tests"
            echo "  --skip-security       Skip all security scans"
            echo "  --run-owasp           Enable OWASP Dependency-Check"
            echo "  --run-grype           Enable Grype scan"
            echo "  --run-sonarqube       Enable SonarQube (default: on)"
            echo "  --no-sonarqube        Disable SonarQube analysis"
            echo "  --generate-sbom       Generate SBOM reports (default: on)"
            echo "  --no-sbom             Skip SBOM generation"
            echo "  --force-reinstall     Force reinstall all agent tools (Stage 0)"
            echo "  --deploy              Deploy to Kubernetes"
            echo "  --namespace NS        K8s namespace for deployment"
            echo "  --no-fail-critical    Don't fail on CRITICAL vulnerabilities"
            echo "  --timeout MIN         Pipeline timeout in minutes (default: 120)"
            echo "  --help                Show this help"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1;;
    esac
done

# ── Validate ──
if [ -z "$JENKINS_PASS" ]; then
    echo "ERROR: JENKINS_PASS environment variable not set"
    echo "  export JENKINS_PASS='your-password'"
    exit 1
fi

# ── Build Parameter String ──
PARAMS=""
PARAMS+="LANGUAGE=${LANGUAGE}&"
PARAMS+="GIT_REPO=${GIT_REPO}&"
PARAMS+="GIT_BRANCH=${GIT_BRANCH}&"
PARAMS+="IMAGE_NAME=${IMAGE_NAME}&"
PARAMS+="IMAGE_TAG=${IMAGE_TAG}&"
PARAMS+="REGISTRY=${REGISTRY}&"
PARAMS+="DOCKERFILE_PATH=${DOCKERFILE}&"
PARAMS+="RUN_UNIT_TESTS=${RUN_UNIT_TESTS}&"
PARAMS+="RUN_INTEGRATION_TESTS=${RUN_INTEGRATION_TESTS}&"
PARAMS+="COVERAGE_THRESHOLD=${COVERAGE_THRESHOLD}&"
PARAMS+="PYTEST_ARGS=${PYTEST_ARGS}&"
PARAMS+="RUN_TRIVY_SCAN=${RUN_TRIVY}&"
PARAMS+="RUN_SECRET_DETECTION=${RUN_SECRETS}&"
PARAMS+="RUN_K8S_MANIFEST_SCAN=${RUN_K8S_SCAN}&"
PARAMS+="RUN_DOCKERFILE_LINT=${RUN_DOCKERFILE_LINT}&"
PARAMS+="RUN_OWASP_CHECK=${RUN_OWASP}&"
PARAMS+="RUN_GRYPE=${RUN_GRYPE}&"
PARAMS+="RUN_SONARQUBE=${RUN_SONARQUBE}&"
PARAMS+="GENERATE_SBOM=${GENERATE_SBOM}&"
PARAMS+="FORCE_TOOL_REINSTALL=${FORCE_TOOL_REINSTALL}&"
PARAMS+="FAIL_ON_CRITICAL=${FAIL_ON_CRITICAL}&"
PARAMS+="DEPLOY_TO_K8S=${DEPLOY_TO_K8S}&"
PARAMS+="K8S_NAMESPACE=${K8S_NAMESPACE}&"
PARAMS+="K8S_MANIFESTS_DIR=${K8S_MANIFESTS_DIR}&"
PARAMS+="TIMEOUT_MINUTES=${TIMEOUT}"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║       Triggering Unified DevSecOps Pipeline                 ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Jenkins:    ${JENKINS_URL}"
echo "║  Job:        ${PIPELINE_JOB}"
echo "║  Language:   ${LANGUAGE}"
echo "║  Image:      ${IMAGE_NAME:-N/A}:${IMAGE_TAG}"
echo "║  Tests:      Unit=${RUN_UNIT_TESTS}"
echo "║  Security:   Trivy=${RUN_TRIVY}  Secrets=${RUN_SECRETS}  K8s=${RUN_K8S_SCAN}"
echo "║  SBOM:       ${GENERATE_SBOM}  SonarQube:  ${RUN_SONARQUBE}"
echo "║  Timeout:    ${TIMEOUT}min  ForceReinstall: ${FORCE_TOOL_REINSTALL}"
echo "╚══════════════════════════════════════════════════════════════╝"

# ── Get Crumb ──
CRUMB=$(curl -s -u "${JENKINS_USER}:${JENKINS_PASS}" \
    "${JENKINS_URL}/crumbIssuer/api/json" 2>/dev/null | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print(f'{d[\"crumbRequestField\"]}:{d[\"crumb\"]}')" 2>/dev/null || echo "")

CRUMB_HEADER=""
if [ -n "$CRUMB" ]; then
    CRUMB_HEADER="-H ${CRUMB}"
fi

# ── Trigger Build ──
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -u "${JENKINS_USER}:${JENKINS_PASS}" \
    ${CRUMB_HEADER} \
    "${JENKINS_URL}/job/${PIPELINE_JOB}/buildWithParameters?${PARAMS}")

if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ]; then
    echo ""
    echo "Pipeline triggered successfully (HTTP ${HTTP_CODE})"
    echo "View at: ${JENKINS_URL}/job/${PIPELINE_JOB}/"
else
    echo ""
    echo "ERROR: Failed to trigger pipeline (HTTP ${HTTP_CODE})"
    echo "  Ensure the job '${PIPELINE_JOB}' exists in Jenkins"
    exit 1
fi
