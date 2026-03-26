#!/usr/bin/env bash
# =============================================================================
# pipeline-trigger.sh — Trigger Security Pipeline from Local Terminal
# =============================================================================
# Triggers the Jenkins security scan pipeline via REST API.
#
# Usage:
#   ./pipeline-trigger.sh                                    # default full scan
#   ./pipeline-trigger.sh --image catool --tag latest        # image-only scan
#   ./pipeline-trigger.sh --type k8s-manifests               # K8s scan only
#   ./pipeline-trigger.sh --scan-registry                    # scan all registry images
# =============================================================================

set -euo pipefail

# Configuration
JENKINS_URL="${JENKINS_URL:-http://132.186.17.25:32000}"
JENKINS_USER="${JENKINS_USER:-admin}"
JENKINS_PASS="${JENKINS_PASS:-admin}"
JOB_NAME="${JOB_NAME:-security-scan-pipeline}"

# Defaults
IMAGE_NAME="catool"
IMAGE_TAG="latest"
SCAN_TYPE="full"
FAIL_ON_CRITICAL="true"
SCAN_REGISTRY="false"
WAIT_FOR_BUILD="true"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --image NAME          Image name to scan (default: catool)"
    echo "  --tag TAG             Image tag (default: latest)"
    echo "  --type TYPE           Scan type: full|image-only|code-only|k8s-manifests"
    echo "  --no-fail-critical    Don't fail on critical vulnerabilities"
    echo "  --scan-registry       Scan all images in local registry"
    echo "  --no-wait             Don't wait for build completion"
    echo "  --job NAME            Jenkins job name (default: security-scan-pipeline)"
    echo "  -h, --help            Show this help"
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)         IMAGE_NAME="$2"; shift 2 ;;
        --tag)           IMAGE_TAG="$2"; shift 2 ;;
        --type)          SCAN_TYPE="$2"; shift 2 ;;
        --no-fail-critical) FAIL_ON_CRITICAL="false"; shift ;;
        --scan-registry) SCAN_REGISTRY="true"; shift ;;
        --no-wait)       WAIT_FOR_BUILD="false"; shift ;;
        --job)           JOB_NAME="$2"; shift 2 ;;
        -h|--help)       usage ;;
        *)               echo "Unknown option: $1"; usage ;;
    esac
done

echo "=========================================="
echo "  Jenkins Security Pipeline Trigger"
echo "=========================================="
echo "  Jenkins:    ${JENKINS_URL}"
echo "  Job:        ${JOB_NAME}"
echo "  Scan type:  ${SCAN_TYPE}"
echo "  Image:      ${IMAGE_NAME}:${IMAGE_TAG}"
echo "  Registry:   ${SCAN_REGISTRY}"
echo "=========================================="

# Get crumb for CSRF
CRUMB_RESPONSE=$(curl -s -u "${JENKINS_USER}:${JENKINS_PASS}" \
    "${JENKINS_URL}/crumbIssuer/api/json" 2>/dev/null || echo "")

CRUMB_ARGS=""
if echo "${CRUMB_RESPONSE}" | python3 -c "import sys,json; json.load(sys.stdin)" &>/dev/null; then
    CRUMB_HEADER=$(echo "${CRUMB_RESPONSE}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['crumbRequestField'])")
    CRUMB_VALUE=$(echo "${CRUMB_RESPONSE}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['crumb'])")
    CRUMB_ARGS="-H ${CRUMB_HEADER}:${CRUMB_VALUE}"
fi

# Trigger the build with parameters
echo ""
echo "Triggering build..."

BUILD_RESPONSE=$(curl -s -w "\n%{http_code}" -u "${JENKINS_USER}:${JENKINS_PASS}" \
    ${CRUMB_ARGS} \
    -X POST \
    "${JENKINS_URL}/job/${JOB_NAME}/buildWithParameters" \
    --data-urlencode "IMAGE_NAME=${IMAGE_NAME}" \
    --data-urlencode "IMAGE_TAG=${IMAGE_TAG}" \
    --data-urlencode "SCAN_TYPE=${SCAN_TYPE}" \
    --data-urlencode "FAIL_ON_CRITICAL=${FAIL_ON_CRITICAL}" \
    --data-urlencode "SCAN_REGISTRY_IMAGES=${SCAN_REGISTRY}" \
    2>/dev/null)

HTTP_CODE=$(echo "${BUILD_RESPONSE}" | tail -1)

if [ "${HTTP_CODE}" = "201" ] || [ "${HTTP_CODE}" = "302" ]; then
    echo -e "${GREEN}Build triggered successfully!${NC}"
else
    echo -e "${RED}Failed to trigger build (HTTP ${HTTP_CODE})${NC}"
    echo "Response: $(echo "${BUILD_RESPONSE}" | head -5)"
    echo ""
    echo "Make sure the job '${JOB_NAME}' exists in Jenkins."
    echo "Create it at: ${JENKINS_URL}/newJob"
    exit 1
fi

# Wait for build if requested
if [ "${WAIT_FOR_BUILD}" = "true" ]; then
    echo ""
    echo "Waiting for build to start..."
    sleep 5

    # Get latest build number
    BUILD_NUM=$(curl -s -u "${JENKINS_USER}:${JENKINS_PASS}" \
        "${JENKINS_URL}/job/${JOB_NAME}/lastBuild/buildNumber" 2>/dev/null || echo "")

    if [ -n "${BUILD_NUM}" ]; then
        echo "Build #${BUILD_NUM} started"
        echo "Console: ${JENKINS_URL}/job/${JOB_NAME}/${BUILD_NUM}/console"
        echo ""

        # Poll for completion
        while true; do
            BUILDING=$(curl -s -u "${JENKINS_USER}:${JENKINS_PASS}" \
                "${JENKINS_URL}/job/${JOB_NAME}/${BUILD_NUM}/api/json" 2>/dev/null | \
                python3 -c "import sys,json; print(json.load(sys.stdin).get('building', False))" 2>/dev/null || echo "False")

            if [ "${BUILDING}" = "False" ]; then
                RESULT=$(curl -s -u "${JENKINS_USER}:${JENKINS_PASS}" \
                    "${JENKINS_URL}/job/${JOB_NAME}/${BUILD_NUM}/api/json" 2>/dev/null | \
                    python3 -c "import sys,json; print(json.load(sys.stdin).get('result', 'UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")

                echo ""
                case "${RESULT}" in
                    SUCCESS)  echo -e "${GREEN}Build #${BUILD_NUM}: ${RESULT}${NC}" ;;
                    UNSTABLE) echo -e "${YELLOW}Build #${BUILD_NUM}: ${RESULT}${NC}" ;;
                    *)        echo -e "${RED}Build #${BUILD_NUM}: ${RESULT}${NC}" ;;
                esac

                echo "Reports: ${JENKINS_URL}/job/${JOB_NAME}/${BUILD_NUM}/Security_20Scan_20Report/"
                break
            fi

            printf "."
            sleep 10
        done
    fi
fi
