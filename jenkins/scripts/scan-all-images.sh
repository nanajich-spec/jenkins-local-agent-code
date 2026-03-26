#!/usr/bin/env bash
# =============================================================================
# scan-all-images.sh — Quick scan script for all registry images
# =============================================================================
# Scans all images in the local registry (132.186.17.22:5000) using Trivy.
# Can be run standalone or triggered from Jenkins.
#
# Usage:
#   chmod +x scan-all-images.sh
#   ./scan-all-images.sh [--severity CRITICAL,HIGH] [--output-dir ./reports]
# =============================================================================

set -euo pipefail

REGISTRY="${REGISTRY:-132.186.17.22:5000}"
SEVERITY="${1:---severity}"
SEVERITY_VAL="${2:-CRITICAL,HIGH}"
OUTPUT_DIR="${3:-./security-reports}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

if [ "$SEVERITY" = "--severity" ]; then
    SEVERITY_VAL="${SEVERITY_VAL}"
elif [ "$SEVERITY" = "--output-dir" ]; then
    OUTPUT_DIR="${SEVERITY_VAL}"
    SEVERITY_VAL="CRITICAL,HIGH"
fi

mkdir -p "${OUTPUT_DIR}"

echo "=========================================="
echo "  Registry Image Security Scanner"
echo "=========================================="
echo "  Registry:  ${REGISTRY}"
echo "  Severity:  ${SEVERITY_VAL}"
echo "  Output:    ${OUTPUT_DIR}"
echo "  Timestamp: ${TIMESTAMP}"
echo "=========================================="

# Get all repositories
CATALOG=$(curl -s "http://${REGISTRY}/v2/_catalog" | \
    python3 -c "import sys,json; repos=json.load(sys.stdin).get('repositories',[]); print('\n'.join(repos))" 2>/dev/null || echo "")

if [ -z "${CATALOG}" ]; then
    echo "ERROR: No repositories found in registry or registry unreachable"
    exit 1
fi

echo ""
echo "Found repositories:"
echo "${CATALOG}" | sed 's/^/  - /'
echo ""

TOTAL_CRITICAL=0
TOTAL_HIGH=0
TOTAL_IMAGES=0
SUMMARY_FILE="${OUTPUT_DIR}/scan-summary-${TIMESTAMP}.txt"

{
    echo "=========================================="
    echo "  Security Scan Summary"
    echo "  Date: $(date)"
    echo "  Registry: ${REGISTRY}"
    echo "=========================================="
    echo ""
    printf "%-40s %-10s %-10s %-10s\n" "IMAGE" "CRITICAL" "HIGH" "STATUS"
    printf "%-40s %-10s %-10s %-10s\n" "-----" "--------" "----" "------"
} > "${SUMMARY_FILE}"

for REPO in ${CATALOG}; do
    # Get tags for this repo
    TAGS=$(curl -s "http://${REGISTRY}/v2/${REPO}/tags/list" | \
        python3 -c "import sys,json; tags=json.load(sys.stdin).get('tags',[]); print('\n'.join(tags if tags else []))" 2>/dev/null || echo "")

    if [ -z "${TAGS}" ]; then
        echo "  [SKIP] ${REPO}: no tags found"
        continue
    fi

    for TAG in ${TAGS}; do
        FULL_IMAGE="${REGISTRY}/${REPO}:${TAG}"
        SAFE_NAME=$(echo "${REPO}-${TAG}" | tr '/:' '-')
        TOTAL_IMAGES=$((TOTAL_IMAGES + 1))

        echo ""
        echo "--- Scanning [${TOTAL_IMAGES}]: ${FULL_IMAGE} ---"

        # Run Trivy scan
        trivy image --podman-host "" \
            --severity "${SEVERITY_VAL}" \
            --format json \
            --output "${OUTPUT_DIR}/trivy-${SAFE_NAME}.json" \
            "${FULL_IMAGE}" 2>/dev/null || {
            echo "  [ERROR] Scan failed for ${FULL_IMAGE}"
            continue
        }

        # Parse results
        COUNTS=$(python3 -c "
import json
with open('${OUTPUT_DIR}/trivy-${SAFE_NAME}.json') as f:
    data = json.load(f)
results = data.get('Results', [])
vulns = [v for r in results for v in r.get('Vulnerabilities', [])]
c = sum(1 for v in vulns if v.get('Severity') == 'CRITICAL')
h = sum(1 for v in vulns if v.get('Severity') == 'HIGH')
print(f'{c},{h}')
" 2>/dev/null || echo "0,0")

        CRIT=$(echo "${COUNTS}" | cut -d',' -f1)
        HIGH=$(echo "${COUNTS}" | cut -d',' -f2)
        TOTAL_CRITICAL=$((TOTAL_CRITICAL + CRIT))
        TOTAL_HIGH=$((TOTAL_HIGH + HIGH))

        if [ "${CRIT}" -gt 0 ]; then
            STATUS="FAIL"
        elif [ "${HIGH}" -gt 0 ]; then
            STATUS="WARN"
        else
            STATUS="PASS"
        fi

        echo "  Critical: ${CRIT}, High: ${HIGH} — ${STATUS}"
        printf "%-40s %-10s %-10s %-10s\n" "${FULL_IMAGE}" "${CRIT}" "${HIGH}" "${STATUS}" >> "${SUMMARY_FILE}"

        # Also do table output
        trivy image --podman-host "" \
            --severity "${SEVERITY_VAL}" \
            --format table \
            "${FULL_IMAGE}" 2>/dev/null | tee "${OUTPUT_DIR}/trivy-${SAFE_NAME}.txt" || true
    done
done

# Finalize summary
{
    echo ""
    echo "=========================================="
    echo "  TOTALS"
    echo "=========================================="
    echo "  Images scanned:         ${TOTAL_IMAGES}"
    echo "  Total CRITICAL vulns:   ${TOTAL_CRITICAL}"
    echo "  Total HIGH vulns:       ${TOTAL_HIGH}"
    echo "=========================================="
    if [ "${TOTAL_CRITICAL}" -gt 0 ]; then
        echo "  RESULT: FAIL — Critical vulnerabilities found"
    elif [ "${TOTAL_HIGH}" -gt 0 ]; then
        echo "  RESULT: WARNING — High vulnerabilities found"
    else
        echo "  RESULT: PASS — No critical/high vulnerabilities"
    fi
    echo "=========================================="
} | tee -a "${SUMMARY_FILE}"

echo ""
echo "Full summary: ${SUMMARY_FILE}"
echo "Individual reports: ${OUTPUT_DIR}/"
