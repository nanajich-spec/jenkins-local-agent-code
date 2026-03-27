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
UPLOAD_SERVER="${UPLOAD_SERVER:-http://132.186.17.22:9091}"

# =============================================================================
# User-specific isolation
# =============================================================================
USER_ID="${USER:-$(whoami 2>/dev/null || echo 'user')}"
HOST_ID="$(hostname -s 2>/dev/null || echo 'unknown')"
SCAN_ID="${USER_ID}-${HOST_ID}-$(date +%s)"

# Defaults
IMAGE_NAME=""
IMAGE_TAG="latest"
SCAN_TYPE=""
FAIL_ON_CRITICAL="true"
SCAN_REGISTRY="false"
GIT_REPO=""
GIT_BRANCH="main"
OUTPUT_DIR="./security-reports-$(date +%Y%m%d_%H%M%S)"
OPEN_REPORT="true"
QUIET="false"
FORMAT="table"
SOURCE_UPLOAD_PATH=""

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'
DIM='\033[2m'; NC='\033[0m'

# Spinner for progress indication
SPINNER_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
SPINNER_IDX=0
spin() {
    local char="${SPINNER_CHARS:SPINNER_IDX:1}"
    SPINNER_IDX=$(( (SPINNER_IDX + 1) % ${#SPINNER_CHARS} ))
    printf "\r  ${CYAN}${char}${NC} %s" "$*"
}
spin_done() {
    printf "\r  ${GREEN}✔${NC} %s\n" "$*"
}
spin_fail() {
    printf "\r  ${RED}✘${NC} %s\n" "$*"
}
log_detail() { _log "  ${DIM}  ↳ $*${NC}"; }
log_phase() { echo -e "\n  ${CYAN}${BOLD}┌─ $* ─────────────────────────────────${NC}"; }
log_phase_end() { echo -e "  ${CYAN}${BOLD}└──────────────────────────────────────────────${NC}"; }
timestamp() { date '+%H:%M:%S'; }

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat <<'EOF'

  SECURITY SCAN CLIENT — Zero Setup Required
  ============================================

  Usage: bash security-scan-client.sh [OPTIONS]

  DEFAULT BEHAVIOR:
    Running without --image scans the SOURCE CODE in your current directory.
    Your code is uploaded to the central server, scanned, then cleaned up.

  Scan Options:
    --image NAME         Scan a Docker image from the registry (image-only scan)
    --tag TAG            Image tag (default: latest)
    --type TYPE          Scan type: full | image-only | code-only | k8s-manifests
                           full         = source code + image (requires --image)
                           code-only    = source code only (default)
                           image-only   = Docker image only (requires --image)
                           k8s-manifests = scan YAML/YML files for K8s issues
    --scan-registry      Scan ALL images in the registry
    --no-fail-critical   Don't fail on CRITICAL vulnerabilities
    --repo URL           Git repo URL to scan (optional)
    --branch NAME        Git branch (default: main)

  Output Options:
    --output DIR         Where to save reports (default: ./security-reports-<timestamp>)
    --no-open            Don't auto-open HTML report
    --quiet              Minimal output (just results)
    --json               Output summary as JSON

  User:
    --user USER          Your username for scan attribution (default: $(whoami))

  Connection (usually pre-configured):
    --jenkins URL        Jenkins server URL
    --registry URL       Container registry URL
    --jenkins-user USER  Jenkins username (rarely needed)
    --token TOKEN        Jenkins API token

  Examples:
    bash security-scan-client.sh                              # Scan current dir source code
    bash security-scan-client.sh --image catool --tag 1.0     # Scan Docker image only
    bash security-scan-client.sh --image catool --type full   # Scan source code + image
    bash security-scan-client.sh --type k8s-manifests         # K8s config audit on current dir
    bash security-scan-client.sh --scan-registry              # Scan all registry images

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
        --user)              USER_ID="$2"; shift 2 ;;
        --jenkins-user)      JENKINS_USER="$2"; shift 2 ;;
        --token)             JENKINS_TOKEN="$2"; shift 2 ;;
        --list-images)       LIST_IMAGES="true"; shift ;;
        --status)            SHOW_STATUS="true"; shift ;;
        --history)           SHOW_HISTORY="true"; shift ;;
        -h|--help)           usage ;;
        *)                   echo "Unknown option: $1"; usage ;;
    esac
done

# Recompute SCAN_ID after argument parsing (--user may have changed USER_ID)
SCAN_ID="${USER_ID}-${HOST_ID}-$(date +%s)"

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

# Cookie jar for session-bound CSRF crumbs
COOKIE_JAR=$(mktemp -t jenkins-cookies.XXXXXX 2>/dev/null || mktemp)
trap 'rm -f "${COOKIE_JAR}"' EXIT

# Jenkins API helpers
jenkins_get() {
    curl -s -u "${JENKINS_USER}:${JENKINS_TOKEN}" "$@"
}

jenkins_post() {
    local url="$1"; shift
    # Get CSRF crumb with session cookie (crumb is session-bound)
    local crumb_json crumb_hdr crumb_val
    crumb_json=$(curl -s -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
        -c "${COOKIE_JAR}" \
        "${JENKINS_URL}/crumbIssuer/api/json" 2>/dev/null || echo "")
    crumb_hdr=$(json_val "${crumb_json}" "crumbRequestField" 2>/dev/null || echo "Jenkins-Crumb")
    crumb_val=$(json_val "${crumb_json}" "crumb" 2>/dev/null || echo "none")
    [ -z "${crumb_hdr}" ] && crumb_hdr="Jenkins-Crumb"
    [ -z "${crumb_val}" ] && crumb_val="none"

    curl -s -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
        -b "${COOKIE_JAR}" \
        -H "${crumb_hdr}:${crumb_val}" \
        -X POST "$@" "${url}"
}

jenkins_post_code() {
    local url="$1"; shift
    local crumb_json crumb_hdr crumb_val
    # Get CSRF crumb with session cookie (crumb is session-bound)
    crumb_json=$(curl -s -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
        -c "${COOKIE_JAR}" \
        "${JENKINS_URL}/crumbIssuer/api/json" 2>/dev/null || echo "")
    crumb_hdr=$(json_val "${crumb_json}" "crumbRequestField" 2>/dev/null || echo "Jenkins-Crumb")
    crumb_val=$(json_val "${crumb_json}" "crumb" 2>/dev/null || echo "none")
    [ -z "${crumb_hdr}" ] && crumb_hdr="Jenkins-Crumb"
    [ -z "${crumb_val}" ] && crumb_val="none"

    curl -s -o /dev/null -w "%{http_code}" -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
        -b "${COOKIE_JAR}" \
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
    log_detail "Testing connection to ${JENKINS_URL}..."
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 \
        -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
        "${JENKINS_URL}/api/json" 2>/dev/null || echo "000")

    if [ "${http_code}" != "200" ]; then
        spin_fail "Cannot connect to scan server"
        err "Cannot connect to scan server at ${JENKINS_URL} (HTTP ${http_code})"
        err ""
        err "Possible fixes:"
        err "  1. Check network connectivity: ping 132.186.17.22"
        err "  2. Make sure you're on the same network / VPN"
        err "  3. Contact the admin if the server is down"
        exit 1
    fi
    info "Connected to scan server"
    log_detail "Jenkins API responded with HTTP ${http_code}"

    # Check if agents are available
    local agents_json
    agents_json=$(jenkins_get "${JENKINS_URL}/computer/api/json" 2>/dev/null || echo "")
    if [ -n "${agents_json}" ] && command -v python3 &>/dev/null; then
        local agent_status
        agent_status=$(echo "${agents_json}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    comps = d.get('computer', [])
    online = sum(1 for c in comps if not c.get('offline', True))
    total = len(comps)
    busy = sum(1 for c in comps if not c.get('idle', True))
    print(f'{online}/{total} online, {busy} busy')
except: print('unknown')
" 2>/dev/null || echo "unknown")
        log_detail "Agents: ${agent_status}"
    fi
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
# Upload source code to central server
# =============================================================================
upload_source() {
    step "Packaging source code from current directory..."

    local src_dir
    src_dir="$(pwd)"
    local tar_file
    tar_file=$(mktemp /tmp/scan-source-XXXXXX.tar.gz)

    # Count files (excluding common large/irrelevant dirs)
    local file_count
    file_count=$(find "${src_dir}" -maxdepth 5 -type f \
        ! -path '*/.git/*' ! -path '*/node_modules/*' ! -path '*/__pycache__/*' \
        ! -path '*/venv/*' ! -path '*/.venv/*' ! -path '*/dist/*' ! -path '*/build/*' \
        ! -path '*/.idea/*' ! -path '*/.vscode/*' ! -path '*/target/*' \
        ! -path '*/.gradle/*' ! -path '*/.m2/*' \
        2>/dev/null | wc -l)

    echo -e "  ${BOLD}Directory:${NC} ${src_dir}"
    echo -e "  ${BOLD}Files:${NC}     ${file_count} (excluding .git, node_modules, etc.)"

    if [ "${file_count}" -eq 0 ]; then
        warn "No source files found in ${src_dir}"
        warn "Make sure you run this from your project directory"
        exit 1
    fi

    # Create tar.gz excluding common large directories and binary artifacts
    tar czf "${tar_file}" \
        --exclude='.git' --exclude='node_modules' --exclude='__pycache__' \
        --exclude='venv' --exclude='.venv' --exclude='dist' --exclude='build' \
        --exclude='.idea' --exclude='.vscode' --exclude='target' \
        --exclude='.gradle' --exclude='.m2' --exclude='.tox' \
        --exclude='*.pyc' --exclude='*.class' --exclude='*.o' --exclude='*.so' \
        --exclude='*.jar' --exclude='*.war' --exclude='*.ear' \
        --exclude='*.exe' --exclude='*.dll' --exclude='*.dylib' \
        --exclude='*.zip' --exclude='*.tar' --exclude='*.tar.gz' --exclude='*.tgz' \
        --exclude='*.rar' --exclude='*.7z' \
        --exclude='*.iso' --exclude='*.img' --exclude='*.bin' \
        --exclude='.cache' --exclude='.npm' --exclude='.yarn' \
        --exclude='vendor' --exclude='coverage' --exclude='.coverage' \
        --exclude='*.log' --exclude='*.sqlite3' --exclude='*.db' \
        --exclude='security-reports-*' \
        -C "${src_dir}" . 2>/dev/null || true

    local tar_size
    tar_size=$(du -sh "${tar_file}" 2>/dev/null | cut -f1)
    echo -e "  ${BOLD}Archive:${NC}   ${tar_size}"

    # Upload to central server
    step "Uploading source code to scan server..."
    log_detail "Upload target: ${UPLOAD_SERVER}/upload"
    log_detail "Scan ID header: ${SCAN_ID}"
    spin "Uploading ${tar_size} to scan server..."
    local upload_response
    upload_response=$(curl -s --connect-timeout 30 --max-time 300 \
        -X POST "${UPLOAD_SERVER}/upload" \
        -H "Content-Type: application/octet-stream" \
        -H "X-Scan-ID: ${SCAN_ID}" \
        --data-binary "@${tar_file}" 2>/dev/null || echo '{"error":"upload failed"}')
    log_detail "Server response: ${upload_response}"

    rm -f "${tar_file}"

    # Parse response
    local upload_status upload_path
    upload_status=$(json_val "${upload_response}" "status" 2>/dev/null || echo "")
    upload_path=$(json_val "${upload_response}" "upload_path" 2>/dev/null || echo "")

    if [ "${upload_status}" = "ok" ] && [ -n "${upload_path}" ]; then
        SOURCE_UPLOAD_PATH="${upload_path}"
        spin_done "Source code uploaded (${tar_size})"
        log_detail "Server stored at: ${upload_path}"
    else
        local upload_err
        upload_err=$(json_val "${upload_response}" "error" 2>/dev/null || echo "unknown error")
        spin_fail "Upload failed"
        err "Failed to upload source code: ${upload_err}"
        err "Response: ${upload_response}"
        err ""
        err "Troubleshooting:"
        err "  1. Check upload server is running: curl -s ${UPLOAD_SERVER}/"
        err "  2. Check disk space on server"
        err "  3. File size: ${tar_size} (limit: 1GB)"
        exit 1
    fi
}

# =============================================================================
# Trigger the scan
# =============================================================================
trigger_scan() {
    # ── Determine scan mode ──
    # If --image is set → image scan; if no --image → source code scan
    local do_code_scan="false"
    local do_image_scan="false"

    if [ -n "${IMAGE_NAME}" ]; then
        # User specified --image
        if [ -z "${SCAN_TYPE}" ]; then
            SCAN_TYPE="image-only"
        fi
        case "${SCAN_TYPE}" in
            full)          do_code_scan="true";  do_image_scan="true" ;;
            image-only)    do_code_scan="false"; do_image_scan="true" ;;
            code-only)     do_code_scan="true";  do_image_scan="false" ;;
            k8s-manifests) do_code_scan="false"; do_image_scan="false" ;;
        esac
    else
        # No --image → scan current directory source code
        if [ -z "${SCAN_TYPE}" ]; then
            SCAN_TYPE="code-only"
        fi
        IMAGE_NAME="none"
        case "${SCAN_TYPE}" in
            full)          do_code_scan="true"; do_image_scan="false" ;;
            code-only)     do_code_scan="true"; do_image_scan="false" ;;
            k8s-manifests) do_code_scan="true"; do_image_scan="false" ;;
            image-only)
                err "Cannot use --type image-only without --image"
                err "Usage: bash security-scan-client.sh --image <name> --type image-only"
                exit 1
                ;;
        esac
    fi

    # ── Upload source code if needed ──
    if [ "${do_code_scan}" = "true" ] || [ "${SCAN_TYPE}" = "k8s-manifests" ]; then
        upload_source
    fi

    step "Triggering security scan..."
    echo ""
    echo -e "  ${BOLD}Scan ID:${NC}    ${SCAN_ID}"
    echo -e "  ${BOLD}User:${NC}       ${USER_ID}@${HOST_ID}"
    if [ "${do_image_scan}" = "true" ]; then
        echo -e "  ${BOLD}Image:${NC}      ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
    fi
    if [ "${do_code_scan}" = "true" ] || [ "${SCAN_TYPE}" = "k8s-manifests" ]; then
        echo -e "  ${BOLD}Source:${NC}     $(pwd) (uploaded)"
    fi
    echo -e "  ${BOLD}Scan type:${NC}  ${SCAN_TYPE}"
    [ -n "${GIT_REPO}" ] && echo -e "  ${BOLD}Git Repo:${NC}   ${GIT_REPO} (${GIT_BRANCH})"
    echo ""

    log_detail "Sending build request to Jenkins..."
    local trigger_code
    trigger_code=$(jenkins_post_code "${JENKINS_URL}/job/${JOB_NAME}/buildWithParameters" \
        --data-urlencode "IMAGE_NAME=${IMAGE_NAME}" \
        --data-urlencode "IMAGE_TAG=${IMAGE_TAG}" \
        --data-urlencode "REGISTRY_URL=${REGISTRY}" \
        --data-urlencode "SCAN_TYPE=${SCAN_TYPE}" \
        --data-urlencode "FAIL_ON_CRITICAL=${FAIL_ON_CRITICAL}" \
        --data-urlencode "SCAN_REGISTRY_IMAGES=${SCAN_REGISTRY}" \
        --data-urlencode "SOURCE_UPLOAD_PATH=${SOURCE_UPLOAD_PATH}" \
        --data-urlencode "SCAN_ID=${SCAN_ID}")

    if [ "${trigger_code}" = "201" ] || [ "${trigger_code}" = "302" ]; then
        info "Scan triggered successfully (HTTP ${trigger_code})"
        log_detail "Build request accepted by Jenkins at $(timestamp)"
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
    log_phase "PHASE 1: Queue & Build Assignment"
    step "Waiting for scan to start..."
    log_detail "Scan ID: ${SCAN_ID}"
    log_detail "Checking Jenkins queue at $(timestamp)..."

    # ── Step 1: Check if build is stuck in queue ──
    local queue_wait=0 max_queue_wait=120
    local in_queue="true"

    # Give Jenkins a moment to receive the build request
    spin "Waiting for Jenkins to process build request..."
    sleep 3
    spin_done "Build request received by Jenkins"

    # Check the queue for our build
    while [ "${in_queue}" = "true" ] && [ ${queue_wait} -lt ${max_queue_wait} ]; do
        local queue_json
        queue_json=$(jenkins_get "${JENKINS_URL}/queue/api/json" 2>/dev/null || echo '{}')

        local queued_item=""
        if command -v python3 &>/dev/null; then
            queued_item=$(echo "${queue_json}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for item in d.get('items', []):
        why = item.get('why', '')
        task_name = item.get('task', {}).get('name', '')
        item_id = item.get('id', '')
        # Check if this queue item is for our job
        if task_name == '${JOB_NAME}':
            # Check params for our scan ID
            params = item.get('params', '')
            actions = item.get('actions', [])
            is_ours = '${SCAN_ID}' in str(params) or '${SCAN_ID}' in str(actions)
            print(f'QUEUED|{item_id}|{why}|{is_ours}')
except: pass
" 2>/dev/null || echo "")
        else
            queued_item=$(echo "${queue_json}" | grep -o "${JOB_NAME}" 2>/dev/null | head -1)
            [ -n "${queued_item}" ] && queued_item="QUEUED|0|checking|false"
        fi

        if [ -n "${queued_item}" ]; then
            local q_why
            q_why=$(echo "${queued_item}" | cut -d'|' -f3)
            spin "Build queued (${queue_wait}s) — ${q_why:-waiting for executor}"
            sleep 2
            queue_wait=$((queue_wait + 2))
        else
            # Not in queue anymore — either started or never queued
            in_queue="false"
        fi
    done

    if [ ${queue_wait} -ge ${max_queue_wait} ]; then
        spin_fail "Build stuck in queue for ${max_queue_wait}s"
        warn "Build may be waiting for an available executor."
        warn "Check Jenkins: ${JENKINS_URL}/queue/"
        log_detail "Continuing to look for started build..."
    elif [ ${queue_wait} -gt 0 ]; then
        spin_done "Build left queue after ${queue_wait}s"
    fi

    # ── Step 2: Find the build matching our SCAN_ID ──
    log_detail "Looking for build with Scan ID: ${SCAN_ID}"
    sleep 1
    local build_num="" retries=0 max_retries=40
    while [ -z "${build_num}" ] && [ ${retries} -lt ${max_retries} ]; do
        spin "Searching for build... (attempt ${retries}/${max_retries})"

        # Get the last few build numbers and find ours by SCAN_ID
        local last_build
        last_build=$(jenkins_get "${JENKINS_URL}/job/${JOB_NAME}/lastBuild/buildNumber" 2>/dev/null || echo "")
        if [ -n "${last_build}" ]; then
            log_detail "Latest build in Jenkins: #${last_build} — checking for our Scan ID"
            # Check last 5 builds for our SCAN_ID (wider range for concurrent scans)
            for check_num in ${last_build} $((last_build - 1)) $((last_build + 1)) $((last_build - 2)) $((last_build + 2)); do
                [ "${check_num}" -lt 1 ] 2>/dev/null && continue
                local build_json
                build_json=$(jenkins_get "${JENKINS_URL}/job/${JOB_NAME}/${check_num}/api/json" 2>/dev/null || echo "")
                if [ -n "${build_json}" ]; then
                    local found_id
                    if command -v python3 &>/dev/null; then
                        found_id=$(echo "${build_json}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for a in d.get('actions', []):
        for p in a.get('parameters', []):
            if p.get('name') == 'SCAN_ID' and p.get('value') == '${SCAN_ID}':
                print(p['value'])
except: pass
" 2>/dev/null || echo "")
                    else
                        found_id=$(echo "${build_json}" | grep -o "\"value\":\"${SCAN_ID}\"" 2>/dev/null | head -1)
                    fi
                    if [ -n "${found_id}" ]; then
                        build_num="${check_num}"
                        break
                    fi
                fi
            done
        else
            log_detail "No builds found yet — job may still be starting (attempt ${retries}/${max_retries})"
        fi
        retries=$((retries + 1))
        if [ -z "${build_num}" ]; then
            # Check queue again in case it's still waiting
            local still_queued
            still_queued=$(jenkins_get "${JENKINS_URL}/queue/api/json" 2>/dev/null | grep -c "${JOB_NAME}" 2>/dev/null || echo "0")
            if [ "${still_queued}" -gt 0 ]; then
                spin "Build still in queue — waiting for executor... (${retries}/${max_retries})"
            fi
            sleep 3
        fi
    done

    # Fallback to lastBuild if we can't find our specific build
    if [ -z "${build_num}" ]; then
        warn "Could not match build by Scan ID after ${max_retries} attempts"
        log_detail "Falling back to latest build number..."
        build_num=$(jenkins_get "${JENKINS_URL}/job/${JOB_NAME}/lastBuild/buildNumber" 2>/dev/null || echo "")
        if [ -n "${build_num}" ]; then
            warn "Using latest build #${build_num} (may not be yours if concurrent scans exist)"
        fi
    fi

    if [ -z "${build_num}" ]; then
        spin_fail "Could not find build"
        err "Could not get build number. The scan may still be queued."
        err "Troubleshooting:"
        err "  1. Check Jenkins UI:    ${JENKINS_URL}/job/${JOB_NAME}/"
        err "  2. Check build queue:   ${JENKINS_URL}/queue/"
        err "  3. Check agents online: ${JENKINS_URL}/computer/"
        err "  4. Scan ID was:         ${SCAN_ID}"
        exit 1
    fi

    spin_done "Build #${build_num} found and assigned"
    log_phase_end

    log_phase "PHASE 2: Live Scan Execution"
    info "Scan #${build_num} is running"
    echo -e "  ${DIM}Live console: ${JENKINS_URL}/job/${JOB_NAME}/${build_num}/console${NC}"
    echo -e "  ${DIM}Started at:   $(timestamp)${NC}"
    echo ""

    # ── Stream console output with phase detection ──
    if [[ "${QUIET}" != "true" ]]; then
        echo -e "${DIM}─── Live Console Output ────────────────────────────────────────${NC}"
        local log_offset=0 building="True" tmp_headers poll_count=0
        local current_phase="initializing" last_phase_msg=""
        tmp_headers=$(mktemp)

        while [ "${building}" = "True" ]; do
            poll_count=$((poll_count + 1))
            local console_chunk
            console_chunk=$(curl -s -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
                -D "${tmp_headers}" \
                "${JENKINS_URL}/job/${JOB_NAME}/${build_num}/logText/progressiveText?start=${log_offset}" \
                2>/dev/null || echo "")

            if [ -n "${console_chunk}" ]; then
                # Detect pipeline phases from console output for status messages
                local detected_phase=""
                if echo "${console_chunk}" | grep -qiE 'checking out|clone|git'; then
                    detected_phase="Checking out source code"
                elif echo "${console_chunk}" | grep -qiE 'trivy|vulnerability scan'; then
                    detected_phase="Running vulnerability scan (Trivy)"
                elif echo "${console_chunk}" | grep -qiE 'grype|sca'; then
                    detected_phase="Running SCA scan (Grype)"
                elif echo "${console_chunk}" | grep -qiE 'secret|detect-secrets|gitleaks'; then
                    detected_phase="Running secret detection"
                elif echo "${console_chunk}" | grep -qiE 'hadolint|dockerfile'; then
                    detected_phase="Linting Dockerfiles (Hadolint)"
                elif echo "${console_chunk}" | grep -qiE 'shellcheck'; then
                    detected_phase="Checking shell scripts (ShellCheck)"
                elif echo "${console_chunk}" | grep -qiE 'kubesec|kubernetes.*audit|k8s.*scan'; then
                    detected_phase="K8s manifest security audit (Kubesec)"
                elif echo "${console_chunk}" | grep -qiE 'dependency.check|owasp'; then
                    detected_phase="Dependency check (OWASP)"
                elif echo "${console_chunk}" | grep -qiE 'generat.*report|html.*report|consolidat'; then
                    detected_phase="Generating reports"
                elif echo "${console_chunk}" | grep -qiE 'archiv|artifact'; then
                    detected_phase="Archiving artifacts"
                elif echo "${console_chunk}" | grep -qiE 'cleanup|clean up|post'; then
                    detected_phase="Cleanup & post-processing"
                fi

                # Show phase transition header
                if [ -n "${detected_phase}" ] && [ "${detected_phase}" != "${last_phase_msg}" ]; then
                    echo -e "\n  ${CYAN}${BOLD}▶ ${detected_phase}${NC} ${DIM}($(timestamp))${NC}"
                    last_phase_msg="${detected_phase}"
                fi

                echo "${console_chunk}"
                local new_offset
                new_offset=$(grep -i "X-Text-Size" "${tmp_headers}" 2>/dev/null | tr -d '\r' | awk '{print $2}' || echo "")
                [ -n "${new_offset}" ] && log_offset="${new_offset}"
            else
                # No new output — show heartbeat so user knows we're still connected
                if [ $((poll_count % 6)) -eq 0 ]; then
                    echo -e "  ${DIM}... waiting for output ($(timestamp), poll #${poll_count})${NC}"
                fi
            fi

            local api_json
            api_json=$(jenkins_get "${JENKINS_URL}/job/${JOB_NAME}/${build_num}/api/json" 2>/dev/null || echo "")
            building=$(json_bool "${api_json}" "building" 2>/dev/null || echo "False")

            # Log estimated progress based on duration
            if [ "${building}" = "True" ]; then
                local est_progress
                est_progress=$(echo "${api_json}" | python3 -c "
import sys, json, time
try:
    d = json.load(sys.stdin)
    est = d.get('estimatedDuration', 0)
    ts = d.get('timestamp', 0)
    if est > 0 and ts > 0:
        elapsed = int(time.time() * 1000) - ts
        pct = min(int(elapsed * 100 / est), 99)
        elapsed_s = elapsed // 1000
        est_s = est // 1000
        print(f'{pct}%|{elapsed_s}s|{est_s}s')
    else:
        print('')
except: print('')
" 2>/dev/null || echo "")

                if [ -n "${est_progress}" ]; then
                    local pct elapsed_s est_s
                    pct=$(echo "${est_progress}" | cut -d'|' -f1)
                    elapsed_s=$(echo "${est_progress}" | cut -d'|' -f2)
                    est_s=$(echo "${est_progress}" | cut -d'|' -f3)
                    # Show progress bar every 4th poll
                    if [ $((poll_count % 4)) -eq 0 ]; then
                        echo -e "  ${DIM}⏱  Progress: ~${pct} (${elapsed_s} / ~${est_s} estimated)${NC}"
                    fi
                fi
                sleep 3
            fi
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
        # Quiet mode: show minimal progress
        local building="True" q_count=0
        while [ "${building}" = "True" ]; do
            q_count=$((q_count + 1))
            spin "Scan running... (${q_count}0s elapsed)"
            sleep 10
            local api_json
            api_json=$(jenkins_get "${JENKINS_URL}/job/${JOB_NAME}/${build_num}/api/json" 2>/dev/null || echo "")
            building=$(json_bool "${api_json}" "building" 2>/dev/null || echo "False")
        done
        spin_done "Scan complete"
        echo ""
    fi

    log_phase_end

    log_phase "PHASE 3: Results & Reports"

    # Get final result
    local result_json result duration
    result_json=$(jenkins_get "${JENKINS_URL}/job/${JOB_NAME}/${build_num}/api/json" 2>/dev/null || echo "")
    result=$(json_val "${result_json}" "result" 2>/dev/null || echo "UNKNOWN")
    duration=$(json_val "${result_json}" "duration" 2>/dev/null || echo "0")
    local dur_sec=$(( ${duration:-0} / 1000 ))
    log_detail "Scan finished at $(timestamp) — took ${dur_sec}s"

    echo ""
    case "${result}" in
        SUCCESS)  echo -e "  ${GREEN}${BOLD}RESULT: PASS${NC} ${DIM}(${dur_sec}s)${NC}" ;;
        UNSTABLE) echo -e "  ${YELLOW}${BOLD}RESULT: WARNING — vulnerabilities found${NC} ${DIM}(${dur_sec}s)${NC}" ;;
        FAILURE)  echo -e "  ${RED}${BOLD}RESULT: FAIL — critical issues${NC} ${DIM}(${dur_sec}s)${NC}" ;;
        *)        echo -e "  ${RED}${BOLD}RESULT: ${result}${NC} ${DIM}(${dur_sec}s)${NC}" ;;
    esac

    # ── Download reports ──
    step "Downloading reports..."
    log_detail "Fetching artifact list from build #${build_num}..."
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
        local total_artifacts
        total_artifacts=$(echo "${artifacts}" | grep -c . 2>/dev/null || echo "0")
        log_detail "Found ${total_artifacts} artifacts to download"
        local count=0
        while IFS= read -r artifact; do
            [ -z "${artifact}" ] && continue
            local filename
            filename=$(basename "${artifact}")
            count=$((count + 1))
            spin "Downloading [${count}/${total_artifacts}]: ${filename}"
            curl -s -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
                "${JENKINS_URL}/job/${JOB_NAME}/${build_num}/artifact/${artifact}" \
                -o "${OUTPUT_DIR}/${filename}" 2>/dev/null
            local fsize
            fsize=$(du -sh "${OUTPUT_DIR}/${filename}" 2>/dev/null | cut -f1)
            spin_done "Downloaded: ${filename} (${fsize})"
        done <<< "${artifacts}"
        info "Downloaded ${count} report files to ${OUTPUT_DIR}/"
    else
        # Fallback: download console output as report
        warn "No artifacts found — saving console log"
        spin "Saving console output..."
        jenkins_get "${JENKINS_URL}/job/${JOB_NAME}/${build_num}/consoleText" \
            -o "${OUTPUT_DIR}/console-output.txt" 2>/dev/null
        spin_done "Console log saved"
    fi

    # Also always save the full console log
    spin "Saving full console log..."
    jenkins_get "${JENKINS_URL}/job/${JOB_NAME}/${build_num}/consoleText" \
        -o "${OUTPUT_DIR}/full-console-log.txt" 2>/dev/null
    spin_done "Full console log saved"

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

    log_phase_end

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
