#!/usr/bin/env bash
# =============================================================================
# security-scan-client.sh — ZERO-SETUP Security Scan Client
# =============================================================================
# Other users run ONLY this script. No Java, no tools, no agents needed.
# Just curl + bash (available on every Linux/Mac machine).
#
# The centralized Jenkins server + agent does ALL the work.
# This script just: triggers → streams output → downloads reports.
#
# ┌────────────────────────────────────────────────────────────────────┐
# │  QUICK START (copy-paste this ONE command):                       │
# │                                                                   │
# │  curl -sL http://132.186.17.22:9091/scan | bash                  │
# │                                                                   │
# │  OR save locally:                                                 │
# │                                                                   │
# │  curl -sL http://132.186.17.22:9091/scan -o scan.sh && bash scan.sh      │
# │                                                                   │
# │  OR if you already have the script:                               │
# │                                                                   │
# │  bash security-scan-client.sh                                     │
# │  bash security-scan-client.sh --image catool --tag latest         │
# │  bash security-scan-client.sh --type k8s-manifests                │
# │  bash security-scan-client.sh --scan-registry                     │
# │  bash security-scan-client.sh --repo https://github.com/org/repo  │
# └────────────────────────────────────────────────────────────────────┘
#
# REQUIREMENTS: curl, bash (that's it!)
# OPTIONAL:     python3 (for JSON parsing, falls back to grep)
#
# Each user gets:
#   - Isolated scan ID (no collisions)
#   - Own report directory
#   - Full console output streamed live
#   - HTML + JSON + TXT reports downloaded locally
#
# =============================================================================

set -euo pipefail

# =============================================================================
# Server Configuration (pre-configured — users DON'T change this)
# =============================================================================
JENKINS_URL="${JENKINS_URL:-http://132.186.17.22:32000}"
JENKINS_USER="${JENKINS_USER:-admin}"
JENKINS_TOKEN="${JENKINS_TOKEN:-admin}"
JOB_NAME="${JOB_NAME:-security-scan-pipeline}"
REGISTRY="${REGISTRY:-132.186.17.22:5000}"

# =============================================================================
# User-specific isolation
# =============================================================================
USER_ID="${USER:-$(whoami 2>/dev/null || echo 'user')}"
HOST_ID="$(hostname -s 2>/dev/null || echo 'unknown')"
SCAN_ID="${USER_ID}-${HOST_ID}-$(date +%s)"

# Defaults
IMAGE_NAME="catool"
IMAGE_TAG="latest"
SCAN_TYPE="full"
FAIL_ON_CRITICAL="true"
SCAN_REGISTRY="false"
GIT_REPO=""
GIT_BRANCH="main"
OUTPUT_DIR="./security-reports-$(date +%Y%m%d_%H%M%S)"
OPEN_REPORT="true"
QUIET="false"
FORMAT="table"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'
DIM='\033[2m'; NC='\033[0m'

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat <<'EOF'

  SECURITY SCAN CLIENT — Zero Setup Required
  ============================================

  Usage: bash security-scan-client.sh [OPTIONS]

  Scan Options:
    --image NAME         Image to scan in registry (default: catool)
    --tag TAG            Image tag (default: latest)
    --type TYPE          Scan type: full | image-only | code-only | k8s-manifests
    --scan-registry      Scan ALL images in the registry
    --no-fail-critical   Don't fail on CRITICAL vulnerabilities
    --repo URL           Git repo URL to scan (optional)
    --branch NAME        Git branch (default: main)

  Output Options:
    --output DIR         Where to save reports (default: ./security-reports-<timestamp>)
    --no-open            Don't auto-open HTML report
    --quiet              Minimal output (just results)
    --json               Output summary as JSON

  Connection (usually pre-configured):
    --jenkins URL        Jenkins server URL
    --registry URL       Container registry URL
    --user USER          Jenkins username
    --token TOKEN        Jenkins API token

  Examples:
    bash security-scan-client.sh                              # Full scan of default image
    bash security-scan-client.sh --image catool-ns --tag 1.0  # Scan specific image
    bash security-scan-client.sh --type image-only            # Only container scan
    bash security-scan-client.sh --scan-registry              # Scan everything
    bash security-scan-client.sh --type k8s-manifests         # K8s config audit

  List available images:
    bash security-scan-client.sh --list-images

EOF
    exit 0
}

# Special commands
LIST_IMAGES="false"
SHOW_STATUS="false"
SHOW_HISTORY="false"

# =============================================================================
# Parse CLI Arguments
# =============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)             IMAGE_NAME="$2"; shift 2 ;;
        --tag)               IMAGE_TAG="$2"; shift 2 ;;
        --type)              SCAN_TYPE="$2"; shift 2 ;;
        --scan-registry)     SCAN_REGISTRY="true"; shift ;;
        --no-fail-critical)  FAIL_ON_CRITICAL="false"; shift ;;
        --repo)              GIT_REPO="$2"; shift 2 ;;
        --branch)            GIT_BRANCH="$2"; shift 2 ;;
        --output)            OUTPUT_DIR="$2"; shift 2 ;;
        --no-open)           OPEN_REPORT="false"; shift ;;
        --quiet)             QUIET="true"; shift ;;
        --json)              FORMAT="json"; shift ;;
        --jenkins)           JENKINS_URL="$2"; shift 2 ;;
        --registry)          REGISTRY="$2"; shift 2 ;;
        --user)              JENKINS_USER="$2"; shift 2 ;;
        --token)             JENKINS_TOKEN="$2"; shift 2 ;;
        --list-images)       LIST_IMAGES="true"; shift ;;
        --status)            SHOW_STATUS="true"; shift ;;
        --history)           SHOW_HISTORY="true"; shift ;;
        -h|--help)           usage ;;
        *)                   echo "Unknown option: $1"; usage ;;
    esac
done

# =============================================================================
# Helpers
# =============================================================================
_log()  { [[ "${QUIET}" == "true" ]] && return; echo -e "$1"; }
info()  { _log "${GREEN}  [OK]${NC} $*"; }
warn()  { _log "${YELLOW}  [!!]${NC} $*"; }
err()   { echo -e "${RED}  [ERROR]${NC} $*" >&2; }
step()  { _log "\n${BLUE}${BOLD}>> $*${NC}"; }

# JSON field extractor (works without python3, falls back to grep)
json_val() {
    local json="$1" key="$2"
    if command -v python3 &>/dev/null; then
        echo "${json}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('${key}',''))" 2>/dev/null
    else
        echo "${json}" | grep -oP "\"${key}\"\s*:\s*\"?\K[^,\"}]+" 2>/dev/null | head -1
    fi
}

json_bool() {
    local json="$1" key="$2"
    if command -v python3 &>/dev/null; then
        echo "${json}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('${key}',True))" 2>/dev/null
    else
        echo "${json}" | grep -oP "\"${key}\"\s*:\s*\K(true|false)" 2>/dev/null | head -1
    fi
}

# Jenkins API helpers
jenkins_get() {
    curl -s -u "${JENKINS_USER}:${JENKINS_TOKEN}" "$@"
}

jenkins_post() {
    local url="$1"; shift
    # Get CSRF crumb
    local crumb_json crumb_hdr crumb_val
    crumb_json=$(curl -s -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
        "${JENKINS_URL}/crumbIssuer/api/json" 2>/dev/null || echo "")
    crumb_hdr=$(json_val "${crumb_json}" "crumbRequestField" 2>/dev/null || echo "Jenkins-Crumb")
    crumb_val=$(json_val "${crumb_json}" "crumb" 2>/dev/null || echo "none")
    [ -z "${crumb_hdr}" ] && crumb_hdr="Jenkins-Crumb"
    [ -z "${crumb_val}" ] && crumb_val="none"

    curl -s -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
        -H "${crumb_hdr}:${crumb_val}" \
        -X POST "$@" "${url}"
}

jenkins_post_code() {
    local url="$1"; shift
    local crumb_json crumb_hdr crumb_val
    crumb_json=$(curl -s -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
        "${JENKINS_URL}/crumbIssuer/api/json" 2>/dev/null || echo "")
    crumb_hdr=$(json_val "${crumb_json}" "crumbRequestField" 2>/dev/null || echo "Jenkins-Crumb")
    crumb_val=$(json_val "${crumb_json}" "crumb" 2>/dev/null || echo "none")
    [ -z "${crumb_hdr}" ] && crumb_hdr="Jenkins-Crumb"
    [ -z "${crumb_val}" ] && crumb_val="none"

    curl -s -o /dev/null -w "%{http_code}" -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
        -H "${crumb_hdr}:${crumb_val}" \
        -X POST "$@" "${url}"
}

# =============================================================================
# Banner
# =============================================================================
show_banner() {
    [[ "${QUIET}" == "true" ]] && return
    echo -e "${CYAN}"
    cat <<'BANNER'
  ╔═══════════════════════════════════════════════════════════════════╗
  ║                                                                   ║
  ║     SECURITY SCAN CLIENT  —  Zero Setup Required                ║
  ║                                                                   ║
  ║     Centralized scanning: just run this script                  ║
  ║     No tools, no agents, no configuration needed                ║
  ║                                                                   ║
  ╚═══════════════════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"
}

# =============================================================================
# Pre-flight — just check curl works and Jenkins is reachable
# =============================================================================
preflight() {
    step "Connecting to scan server..."

    # Only require curl
    if ! command -v curl &>/dev/null; then
        err "curl is required but not found."
        err "Install it: sudo dnf install -y curl  OR  sudo apt install -y curl"
        exit 1
    fi

    # Test Jenkins connectivity
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 \
        -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
        "${JENKINS_URL}/api/json" 2>/dev/null || echo "000")

    if [ "${http_code}" != "200" ]; then
        err "Cannot connect to scan server at ${JENKINS_URL} (HTTP ${http_code})"
        err ""
        err "Possible fixes:"
        err "  1. Check network connectivity: ping 132.186.17.22"
        err "  2. Make sure you're on the same network / VPN"
        err "  3. Contact the admin if the server is down"
        exit 1
    fi
    info "Connected to scan server"
}

# =============================================================================
# List available images in registry
# =============================================================================
list_images() {
    preflight
    step "Images available in container registry (${REGISTRY})"
    echo ""

    local catalog
    catalog=$(curl -s "http://${REGISTRY}/v2/_catalog" 2>/dev/null)

    if command -v python3 &>/dev/null; then
        echo "${catalog}" | python3 -c "
import sys, json
try:
    repos = json.load(sys.stdin).get('repositories', [])
    if not repos:
        print('  No images found')
        sys.exit(0)
    for repo in repos:
        tags_json = json.loads(__import__('urllib.request', fromlist=['urlopen']).urlopen(f'http://${REGISTRY}/v2/{repo}/tags/list').read())
        tags = tags_json.get('tags', [])
        for tag in tags:
            print(f'  {repo}:{tag}')
except Exception as e:
    print(f'  Error: {e}')
" 2>/dev/null
    else
        local repos
        repos=$(echo "${catalog}" | grep -oP '"repositories"\s*:\s*\[\K[^]]+' | tr -d '"' | tr ',' '\n')
        for repo in ${repos}; do
            local tags_json
            tags_json=$(curl -s "http://${REGISTRY}/v2/${repo}/tags/list" 2>/dev/null)
            local tags
            tags=$(echo "${tags_json}" | grep -oP '"tags"\s*:\s*\[\K[^]]+' | tr -d '"' | tr ',' '\n')
            for tag in ${tags}; do
                echo "  ${repo}:${tag}"
            done
        done
    fi
    echo ""
    echo -e "  ${DIM}Use: bash security-scan-client.sh --image <name> --tag <tag>${NC}"
    exit 0
}

# =============================================================================
# Show scan history
# =============================================================================
show_history() {
    preflight
    step "Recent scan history"
    echo ""

    local builds_json
    builds_json=$(jenkins_get "${JENKINS_URL}/job/${JOB_NAME}/api/json" 2>/dev/null)

    if command -v python3 &>/dev/null; then
        echo "${builds_json}" | python3 -c "
import sys, json, urllib.request
from datetime import datetime
try:
    data = json.load(sys.stdin)
    builds = data.get('builds', [])
    if not builds:
        print('  No builds found')
        sys.exit(0)
    print('  %-8s %-12s %-22s %-10s' % ('BUILD', 'RESULT', 'DATE', 'DURATION'))
    print('  ' + '-' * 55)
    for b in builds[:10]:
        num = b.get('number', '?')
        # Fetch individual build details
        import base64
        auth = base64.b64encode(b'${JENKINS_USER}:${JENKINS_TOKEN}').decode()
        req = urllib.request.Request(
            '${JENKINS_URL}/job/${JOB_NAME}/' + str(num) + '/api/json',
            headers={'Authorization': 'Basic ' + auth}
        )
        try:
            bd = json.load(urllib.request.urlopen(req, timeout=5))
            ts = datetime.fromtimestamp(bd['timestamp']/1000).strftime('%Y-%m-%d %H:%M:%S')
            dur = '%ds' % (bd.get('duration',0)//1000)
            result = bd.get('result', 'RUNNING') or 'RUNNING'
            print('  #%-7s %-12s %-22s %-10s' % (num, result, ts, dur))
        except:
            print('  #%-7s %-12s' % (num, 'unknown'))
except Exception as e:
    print(f'  Error: {e}')
" 2>/dev/null
    else
        echo "  (Install python3 for formatted output)"
        echo "${builds_json}"
    fi
    echo ""
    exit 0
}

# =============================================================================
# Show server status
# =============================================================================
show_status() {
    preflight
    step "Scan server status"
    echo ""

    # Jenkins status
    local jenkins_info
    jenkins_info=$(jenkins_get "${JENKINS_URL}/api/json" 2>/dev/null)
    info "Jenkins: Online"

    # Agent status
    local agents
    agents=$(jenkins_get "${JENKINS_URL}/computer/api/json" 2>/dev/null)
    if command -v python3 &>/dev/null; then
        echo "${agents}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    comps = data.get('computer', [])
    online = sum(1 for c in comps if not c.get('offline', True))
    total = len(comps)
    print(f'  Agents: {online}/{total} online')
    for c in comps:
        name = c.get('displayName', 'unknown')
        status = 'ONLINE' if not c.get('offline', True) else 'OFFLINE'
        executors = c.get('numExecutors', 0)
        print(f'    - {name}: {status} ({executors} executors)')
except Exception as e:
    print(f'  Error: {e}')
" 2>/dev/null
    fi

    # Registry status
    local reg_code
    reg_code=$(curl -s -o /dev/null -w "%{http_code}" "http://${REGISTRY}/v2/_catalog" 2>/dev/null || echo "000")
    if [ "${reg_code}" = "200" ]; then
        info "Registry: Online (${REGISTRY})"
        local count
        count=$(curl -s "http://${REGISTRY}/v2/_catalog" 2>/dev/null | grep -oP '"[^"]+' | grep -v repositories | wc -l)
        echo -e "    Images: ${count} repositories"
    else
        warn "Registry: Unreachable (${REGISTRY})"
    fi

    echo ""
    exit 0
}

# =============================================================================
# Trigger the scan
# =============================================================================
trigger_scan() {
    step "Triggering security scan..."
    echo ""
    echo -e "  ${BOLD}Scan ID:${NC}    ${SCAN_ID}"
    echo -e "  ${BOLD}User:${NC}       ${USER_ID}@${HOST_ID}"
    echo -e "  ${BOLD}Image:${NC}      ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
    echo -e "  ${BOLD}Scan type:${NC}  ${SCAN_TYPE}"
    [ -n "${GIT_REPO}" ] && echo -e "  ${BOLD}Git Repo:${NC}   ${GIT_REPO} (${GIT_BRANCH})"
    echo ""

    local trigger_code
    trigger_code=$(jenkins_post_code "${JENKINS_URL}/job/${JOB_NAME}/buildWithParameters" \
        --data-urlencode "IMAGE_NAME=${IMAGE_NAME}" \
        --data-urlencode "IMAGE_TAG=${IMAGE_TAG}" \
        --data-urlencode "REGISTRY_URL=${REGISTRY}" \
        --data-urlencode "SCAN_TYPE=${SCAN_TYPE}" \
        --data-urlencode "FAIL_ON_CRITICAL=${FAIL_ON_CRITICAL}" \
        --data-urlencode "SCAN_REGISTRY_IMAGES=${SCAN_REGISTRY}")

    if [ "${trigger_code}" = "201" ] || [ "${trigger_code}" = "302" ]; then
        info "Scan triggered successfully"
    else
        err "Failed to trigger scan (HTTP ${trigger_code})"
        err ""
        err "The pipeline job '${JOB_NAME}' may not exist yet."
        err "Ask the admin to run the setup, or check:"
        err "  ${JENKINS_URL}/job/${JOB_NAME}/"
        exit 1
    fi
}

# =============================================================================
# Wait for build, stream output live, download reports
# =============================================================================
wait_and_download() {
    step "Waiting for scan to start..."

    # Get build number
    sleep 4
    local build_num="" retries=0
    while [ -z "${build_num}" ] && [ ${retries} -lt 20 ]; do
        build_num=$(jenkins_get "${JENKINS_URL}/job/${JOB_NAME}/lastBuild/buildNumber" 2>/dev/null || echo "")
        retries=$((retries + 1))
        [ -z "${build_num}" ] && sleep 2
    done

    if [ -z "${build_num}" ]; then
        err "Could not get build number. The scan may still be queued."
        err "Check manually: ${JENKINS_URL}/job/${JOB_NAME}/"
        exit 1
    fi

    info "Scan #${build_num} started"
    echo -e "  ${DIM}Live console: ${JENKINS_URL}/job/${JOB_NAME}/${build_num}/console${NC}"
    echo ""

    # ── Stream console output ──
    if [[ "${QUIET}" != "true" ]]; then
        echo -e "${DIM}─── Live Console Output ────────────────────────────────────────${NC}"
        local log_offset=0 building="True" tmp_headers
        tmp_headers=$(mktemp)

        while [ "${building}" = "True" ]; do
            local console_chunk
            console_chunk=$(curl -s -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
                -D "${tmp_headers}" \
                "${JENKINS_URL}/job/${JOB_NAME}/${build_num}/logText/progressiveText?start=${log_offset}" \
                2>/dev/null || echo "")

            if [ -n "${console_chunk}" ]; then
                echo "${console_chunk}"
                local new_offset
                new_offset=$(grep -i "X-Text-Size" "${tmp_headers}" 2>/dev/null | tr -d '\r' | awk '{print $2}' || echo "")
                [ -n "${new_offset}" ] && log_offset="${new_offset}"
            fi

            local api_json
            api_json=$(jenkins_get "${JENKINS_URL}/job/${JOB_NAME}/${build_num}/api/json" 2>/dev/null || echo "")
            building=$(json_bool "${api_json}" "building" 2>/dev/null || echo "False")

            [ "${building}" = "True" ] && sleep 5
        done

        # Final chunk
        local final_chunk
        final_chunk=$(curl -s -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
            "${JENKINS_URL}/job/${JOB_NAME}/${build_num}/logText/progressiveText?start=${log_offset}" \
            2>/dev/null || echo "")
        [ -n "${final_chunk}" ] && echo "${final_chunk}"

        rm -f "${tmp_headers}"
        echo -e "${DIM}────────────────────────────────────────────────────────────────${NC}"
    else
        # Quiet mode: just wait
        local building="True"
        while [ "${building}" = "True" ]; do
            printf "."
            sleep 10
            local api_json
            api_json=$(jenkins_get "${JENKINS_URL}/job/${JOB_NAME}/${build_num}/api/json" 2>/dev/null || echo "")
            building=$(json_bool "${api_json}" "building" 2>/dev/null || echo "False")
        done
        echo ""
    fi

    # Get final result
    local result_json result duration
    result_json=$(jenkins_get "${JENKINS_URL}/job/${JOB_NAME}/${build_num}/api/json" 2>/dev/null || echo "")
    result=$(json_val "${result_json}" "result" 2>/dev/null || echo "UNKNOWN")
    duration=$(json_val "${result_json}" "duration" 2>/dev/null || echo "0")
    local dur_sec=$(( ${duration:-0} / 1000 ))

    echo ""
    case "${result}" in
        SUCCESS)  echo -e "  ${GREEN}${BOLD}RESULT: PASS${NC} ${DIM}(${dur_sec}s)${NC}" ;;
        UNSTABLE) echo -e "  ${YELLOW}${BOLD}RESULT: WARNING — vulnerabilities found${NC} ${DIM}(${dur_sec}s)${NC}" ;;
        FAILURE)  echo -e "  ${RED}${BOLD}RESULT: FAIL — critical issues${NC} ${DIM}(${dur_sec}s)${NC}" ;;
        *)        echo -e "  ${RED}${BOLD}RESULT: ${result}${NC} ${DIM}(${dur_sec}s)${NC}" ;;
    esac

    # ── Download reports ──
    step "Downloading reports..."
    mkdir -p "${OUTPUT_DIR}"

    # Get artifact list
    local artifacts=""
    if command -v python3 &>/dev/null; then
        artifacts=$(echo "${result_json}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for a in data.get('artifacts', []):
        print(a['relativePath'])
except: pass
" 2>/dev/null || echo "")
    else
        artifacts=$(echo "${result_json}" | grep -oP '"relativePath"\s*:\s*"\K[^"]+' 2>/dev/null || echo "")
    fi

    if [ -n "${artifacts}" ]; then
        local count=0
        while IFS= read -r artifact; do
            [ -z "${artifact}" ] && continue
            local filename
            filename=$(basename "${artifact}")
            curl -s -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
                "${JENKINS_URL}/job/${JOB_NAME}/${build_num}/artifact/${artifact}" \
                -o "${OUTPUT_DIR}/${filename}" 2>/dev/null
            count=$((count + 1))
        done <<< "${artifacts}"
        info "Downloaded ${count} report files"
    else
        # Fallback: download console output as report
        warn "No artifacts found — saving console log"
        jenkins_get "${JENKINS_URL}/job/${JOB_NAME}/${build_num}/consoleText" \
            -o "${OUTPUT_DIR}/console-output.txt" 2>/dev/null
        info "Console log saved"
    fi

    # Also always save the full console log
    jenkins_get "${JENKINS_URL}/job/${JOB_NAME}/${build_num}/consoleText" \
        -o "${OUTPUT_DIR}/full-console-log.txt" 2>/dev/null

    # ── JSON summary output ──
    if [[ "${FORMAT}" == "json" ]]; then
        if command -v python3 &>/dev/null; then
            python3 -c "
import json, os, glob

rdir = '${OUTPUT_DIR}'
summary = {
    'scan_id': '${SCAN_ID}',
    'user': '${USER_ID}',
    'host': '${HOST_ID}',
    'build_number': ${build_num},
    'result': '${result}',
    'duration_seconds': ${dur_sec},
    'image': '${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}',
    'scan_type': '${SCAN_TYPE}',
    'reports_dir': rdir,
    'reports': []
}

for f in sorted(glob.glob(os.path.join(rdir, '*'))):
    summary['reports'].append({
        'file': os.path.basename(f),
        'size': os.path.getsize(f)
    })

# Try to extract vuln counts
for f in glob.glob(os.path.join(rdir, 'trivy-*.json')):
    try:
        with open(f) as fh:
            d = json.load(fh)
        vulns = [v for r in d.get('Results', []) for v in r.get('Vulnerabilities', [])]
        summary['vulnerabilities'] = {
            'critical': sum(1 for v in vulns if v.get('Severity') == 'CRITICAL'),
            'high': sum(1 for v in vulns if v.get('Severity') == 'HIGH'),
            'medium': sum(1 for v in vulns if v.get('Severity') == 'MEDIUM'),
            'low': sum(1 for v in vulns if v.get('Severity') == 'LOW')
        }
        break
    except: pass

print(json.dumps(summary, indent=2))
" 2>/dev/null
        fi
    fi

    # ── Final summary ──
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "  ╔═══════════════════════════════════════════════════════════════╗"
    echo "  ║                     SCAN COMPLETE                            ║"
    echo "  ╠═══════════════════════════════════════════════════════════════╣"
    printf "  ║  Result:   %-48s ║\n" "${result}"
    printf "  ║  Duration: %-48s ║\n" "${dur_sec}s"
    printf "  ║  Reports:  %-48s ║\n" "${OUTPUT_DIR}/"
    printf "  ║  Build:    %-48s ║\n" "#${build_num}"
    printf "  ║  User:     %-48s ║\n" "${USER_ID}@${HOST_ID}"
    echo "  ╠═══════════════════════════════════════════════════════════════╣"
    echo "  ║  View Reports:                                               ║"
    printf "  ║    ls %-54s║\n" "${OUTPUT_DIR}/"
    echo "  ║                                                              ║"
    echo "  ║  Open HTML Report:                                           ║"
    printf "  ║    xdg-open %-48s║\n" "${OUTPUT_DIR}/security-report.html"
    echo "  ║                                                              ║"
    echo "  ║  Jenkins Console:                                            ║"
    printf "  ║    %-56s║\n" "${JENKINS_URL}/job/${JOB_NAME}/${build_num}/console"
    echo "  ╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    # List downloaded files
    if [ -d "${OUTPUT_DIR}" ]; then
        echo "  Downloaded report files:"
        ls -lh "${OUTPUT_DIR}"/ 2>/dev/null | tail -n +2 | while read -r line; do
            echo "    ${line}"
        done
        echo ""
    fi

    # Auto-open HTML report
    if [[ "${OPEN_REPORT}" == "true" ]] && [ -f "${OUTPUT_DIR}/security-report.html" ]; then
        if command -v xdg-open &>/dev/null; then
            xdg-open "${OUTPUT_DIR}/security-report.html" 2>/dev/null &
        elif command -v open &>/dev/null; then
            open "${OUTPUT_DIR}/security-report.html" 2>/dev/null &
        fi
    fi
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    # Handle special commands
    [[ "${LIST_IMAGES}" == "true" ]] && list_images
    [[ "${SHOW_STATUS}" == "true" ]] && show_status
    [[ "${SHOW_HISTORY}" == "true" ]] && show_history

    show_banner
    preflight
    trigger_scan
    wait_and_download
}

main
