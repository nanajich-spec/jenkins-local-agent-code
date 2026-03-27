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

# Pipeline job names
JOB_SECURITY="security-scan-pipeline"
JOB_CICD="ci-cd-pipeline"
JOB_DEVSECOPS="devsecops-pipeline"

# Pipeline selection: security | ci-cd | devsecops | all
PIPELINE_MODE="all"

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
AGENT_LABEL=""

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
    --pipeline MODE      Pipeline(s) to run: security | ci-cd | devsecops | all
                           security   = Security scans only (Trivy, SAST, SCA, secrets)
                           ci-cd      = Full CI/CD (build, test, lint, security, deploy)
                           devsecops  = Full DevSecOps (test, SBOM, SonarQube, security)
                           all        = Run ALL pipelines (default)
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
    bash security-scan-client.sh                              # Run ALL pipelines on current dir
    bash security-scan-client.sh --pipeline security          # Security scans only
    bash security-scan-client.sh --pipeline ci-cd             # CI/CD pipeline only
    bash security-scan-client.sh --pipeline devsecops         # DevSecOps pipeline only
    bash security-scan-client.sh --pipeline all               # All pipelines (default)
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
        --pipeline)          PIPELINE_MODE="$2"; shift 2 ;;
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
trap 'rm -f "${COOKIE_JAR}"; destroy_dynamic_agent 2>/dev/null' EXIT

# Jenkins API helpers
jenkins_get() {
    curl -s -u "${JENKINS_USER}:${JENKINS_TOKEN}" "$@"
}

jenkins_post() {
    local url="$1"; shift
    # Get CSRF crumb with a FRESH session cookie (crumb is session-bound)
    local tmp_jar crumb_json crumb_hdr crumb_val
    tmp_jar=$(mktemp -t jenkins-post-cookies.XXXXXX 2>/dev/null || mktemp)
    crumb_json=$(curl -s -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
        -c "${tmp_jar}" \
        "${JENKINS_URL}/crumbIssuer/api/json" 2>/dev/null || echo "")
    crumb_hdr=$(json_val "${crumb_json}" "crumbRequestField" 2>/dev/null || echo "Jenkins-Crumb")
    crumb_val=$(json_val "${crumb_json}" "crumb" 2>/dev/null || echo "none")
    [ -z "${crumb_hdr}" ] && crumb_hdr="Jenkins-Crumb"
    [ -z "${crumb_val}" ] && crumb_val="none"

    curl -s -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
        -b "${tmp_jar}" \
        -H "${crumb_hdr}:${crumb_val}" \
        -X POST "$@" "${url}"
    rm -f "${tmp_jar}"
}

jenkins_post_code() {
    local url="$1"; shift
    # Get CSRF crumb with a FRESH session cookie (crumb is session-bound)
    local tmp_jar crumb_json crumb_hdr crumb_val
    tmp_jar=$(mktemp -t jenkins-post-cookies.XXXXXX 2>/dev/null || mktemp)
    crumb_json=$(curl -s -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
        -c "${tmp_jar}" \
        "${JENKINS_URL}/crumbIssuer/api/json" 2>/dev/null || echo "")
    crumb_hdr=$(json_val "${crumb_json}" "crumbRequestField" 2>/dev/null || echo "Jenkins-Crumb")
    crumb_val=$(json_val "${crumb_json}" "crumb" 2>/dev/null || echo "none")
    [ -z "${crumb_hdr}" ] && crumb_hdr="Jenkins-Crumb"
    [ -z "${crumb_val}" ] && crumb_val="none"

    curl -s -o /dev/null -w "%{http_code}" -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
        -b "${tmp_jar}" \
        -H "${crumb_hdr}:${crumb_val}" \
        -X POST "$@" "${url}"
    rm -f "${tmp_jar}"
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
  ║     SECURITY & CI/CD SCAN CLIENT  —  Zero Setup Required        ║
  ║                                                                   ║
  ║     Pipelines: Security | CI/CD | DevSecOps | ALL               ║
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
# Provision a dynamic agent for this scan (no queue waiting!)
# =============================================================================
provision_dynamic_agent() {
    step "Provisioning dedicated scan agent..."
    log_detail "Each scan gets its own agent — no waiting in queue"
    log_detail "Scan ID: ${SCAN_ID}"

    spin "Requesting dynamic agent from server..."

    local agent_response
    agent_response=$(curl -s --connect-timeout 15 --max-time 130 \
        -X POST "${UPLOAD_SERVER}/agent/create" \
        -H "Content-Type: application/json" \
        -d "{\"scan_id\": \"${SCAN_ID}\"}" 2>/dev/null || echo '{"error":"connection failed"}')

    local agent_status
    agent_status=$(json_val "${agent_response}" "status" 2>/dev/null || echo "")

    if [ "${agent_status}" = "ok" ]; then
        AGENT_LABEL=$(json_val "${agent_response}" "agent_label" 2>/dev/null || echo "")
        local agent_name
        agent_name=$(json_val "${agent_response}" "agent_name" 2>/dev/null || echo "")
        spin_done "Dynamic agent '${agent_name}' is ONLINE"
        log_detail "Agent label: ${AGENT_LABEL}"
        log_detail "This scan will run immediately on its own agent"
    else
        local agent_err
        agent_err=$(json_val "${agent_response}" "error" 2>/dev/null || echo "unknown")
        spin_fail "Could not create dynamic agent"
        warn "Error: ${agent_err}"
        warn "Falling back to shared agent (may queue if another scan is running)"
        AGENT_LABEL="local-security-agent"
    fi
}

# Destroy the dynamic agent after scan completes
destroy_dynamic_agent() {
    if [ -n "${AGENT_LABEL}" ] && [[ "${AGENT_LABEL}" == scan-agent-* ]]; then
        log_detail "Cleaning up dynamic agent '${AGENT_LABEL}'..."
        curl -s --connect-timeout 10 --max-time 35 \
            -X POST "${UPLOAD_SERVER}/agent/destroy" \
            -H "Content-Type: application/json" \
            -d "{\"scan_id\": \"${SCAN_ID}\"}" 2>/dev/null || true
        log_detail "Agent cleanup requested"
    fi
}

# =============================================================================
# Trigger the scan — supports multiple pipelines
# =============================================================================
trigger_scan() {
    # ── Determine scan mode ──
    local do_code_scan="false"
    local do_image_scan="false"

    if [ -n "${IMAGE_NAME}" ]; then
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

    # ── Determine which pipelines to run ──
    local pipelines_to_run=()
    case "${PIPELINE_MODE}" in
        security)  pipelines_to_run=("${JOB_SECURITY}") ;;
        ci-cd)     pipelines_to_run=("${JOB_CICD}") ;;
        devsecops) pipelines_to_run=("${JOB_DEVSECOPS}") ;;
        all)       pipelines_to_run=("${JOB_SECURITY}" "${JOB_CICD}" "${JOB_DEVSECOPS}") ;;
        *)
            err "Unknown pipeline mode: ${PIPELINE_MODE}"
            err "Use: security | ci-cd | devsecops | all"
            exit 1
            ;;
    esac

    step "Triggering pipelines..."
    echo ""
    echo -e "  ${BOLD}Scan ID:${NC}    ${SCAN_ID}"
    echo -e "  ${BOLD}User:${NC}       ${USER_ID}@${HOST_ID}"
    echo -e "  ${BOLD}Pipelines:${NC}  ${PIPELINE_MODE} (${#pipelines_to_run[@]} pipeline(s))"
    if [ "${do_image_scan}" = "true" ]; then
        echo -e "  ${BOLD}Image:${NC}      ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
    fi
    if [ "${do_code_scan}" = "true" ] || [ "${SCAN_TYPE}" = "k8s-manifests" ]; then
        echo -e "  ${BOLD}Source:${NC}     $(pwd) (uploaded)"
    fi
    echo -e "  ${BOLD}Scan type:${NC}  ${SCAN_TYPE}"
    [ -n "${GIT_REPO}" ] && echo -e "  ${BOLD}Git Repo:${NC}   ${GIT_REPO} (${GIT_BRANCH})"
    echo ""

    # ── Trigger each pipeline ──
    TRIGGERED_JOBS=()
    TRIGGERED_SCANIDS=()
    for pipeline_job in "${pipelines_to_run[@]}"; do
        local job_scan_id="${SCAN_ID}-${pipeline_job}"

        # Check if the job exists first
        local job_check
        job_check=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 \
            -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
            "${JENKINS_URL}/job/${pipeline_job}/api/json" 2>/dev/null || echo "000")

        if [ "${job_check}" = "404" ]; then
            warn "Pipeline '${pipeline_job}' not found in Jenkins — skipping"
            log_detail "Create it first: ${JENKINS_URL}/job/${pipeline_job}/"
            continue
        fi

        log_detail "Triggering pipeline: ${pipeline_job}"

        local trigger_code
        # Build parameters differ per pipeline type
        if [ "${pipeline_job}" = "${JOB_SECURITY}" ]; then
            trigger_code=$(jenkins_post_code "${JENKINS_URL}/job/${pipeline_job}/buildWithParameters" \
                --data-urlencode "IMAGE_NAME=${IMAGE_NAME}" \
                --data-urlencode "IMAGE_TAG=${IMAGE_TAG}" \
                --data-urlencode "REGISTRY_URL=${REGISTRY}" \
                --data-urlencode "SCAN_TYPE=${SCAN_TYPE}" \
                --data-urlencode "FAIL_ON_CRITICAL=${FAIL_ON_CRITICAL}" \
                --data-urlencode "SCAN_REGISTRY_IMAGES=${SCAN_REGISTRY}" \
                --data-urlencode "SOURCE_UPLOAD_PATH=${SOURCE_UPLOAD_PATH}" \
                --data-urlencode "SCAN_ID=${job_scan_id}" \
                --data-urlencode "AGENT_LABEL=${AGENT_LABEL}")
        elif [ "${pipeline_job}" = "${JOB_CICD}" ]; then
            trigger_code=$(jenkins_post_code "${JENKINS_URL}/job/${pipeline_job}/buildWithParameters" \
                --data-urlencode "LANGUAGE=auto" \
                --data-urlencode "GIT_REPO=${GIT_REPO}" \
                --data-urlencode "GIT_BRANCH=${GIT_BRANCH}" \
                --data-urlencode "IMAGE_NAME=${IMAGE_NAME}" \
                --data-urlencode "IMAGE_TAG=${IMAGE_TAG}" \
                --data-urlencode "REGISTRY=${REGISTRY}" \
                --data-urlencode "RUN_UNIT_TESTS=true" \
                --data-urlencode "RUN_INTEGRATION_TESTS=false" \
                --data-urlencode "RUN_LINT=true" \
                --data-urlencode "RUN_SECURITY_SCAN=true" \
                --data-urlencode "FAIL_ON_CRITICAL=${FAIL_ON_CRITICAL}" \
                --data-urlencode "SOURCE_UPLOAD_PATH=${SOURCE_UPLOAD_PATH}" \
                --data-urlencode "SCAN_ID=${job_scan_id}" \
                --data-urlencode "AGENT_LABEL=${AGENT_LABEL}")
        elif [ "${pipeline_job}" = "${JOB_DEVSECOPS}" ]; then
            trigger_code=$(jenkins_post_code "${JENKINS_URL}/job/${pipeline_job}/buildWithParameters" \
                --data-urlencode "LANGUAGE=auto" \
                --data-urlencode "GIT_REPO=${GIT_REPO}" \
                --data-urlencode "GIT_BRANCH=${GIT_BRANCH}" \
                --data-urlencode "IMAGE_NAME=${IMAGE_NAME}" \
                --data-urlencode "IMAGE_TAG=${IMAGE_TAG}" \
                --data-urlencode "REGISTRY=${REGISTRY}" \
                --data-urlencode "RUN_UNIT_TESTS=true" \
                --data-urlencode "RUN_INTEGRATION_TESTS=false" \
                --data-urlencode "COVERAGE_THRESHOLD=70" \
                --data-urlencode "RUN_TRIVY_SCAN=true" \
                --data-urlencode "RUN_SECRET_DETECTION=true" \
                --data-urlencode "RUN_K8S_MANIFEST_SCAN=true" \
                --data-urlencode "RUN_DOCKERFILE_LINT=true" \
                --data-urlencode "GENERATE_SBOM=true" \
                --data-urlencode "RUN_SONARQUBE=false" \
                --data-urlencode "FAIL_ON_CRITICAL=${FAIL_ON_CRITICAL}" \
                --data-urlencode "SOURCE_UPLOAD_PATH=${SOURCE_UPLOAD_PATH}" \
                --data-urlencode "SCAN_ID=${job_scan_id}" \
                --data-urlencode "AGENT_LABEL=${AGENT_LABEL}")
        fi

        if [ "${trigger_code}" = "201" ] || [ "${trigger_code}" = "302" ]; then
            info "Pipeline '${pipeline_job}' triggered (HTTP ${trigger_code})"
            TRIGGERED_JOBS+=("${pipeline_job}")
            TRIGGERED_SCANIDS+=("${job_scan_id}")
        else
            warn "Failed to trigger '${pipeline_job}' (HTTP ${trigger_code})"
            log_detail "Check: ${JENKINS_URL}/job/${pipeline_job}/"
        fi
    done

    if [ ${#TRIGGERED_JOBS[@]} -eq 0 ]; then
        err "No pipelines were triggered successfully."
        err "Make sure the pipeline jobs exist in Jenkins."
        err "Run: python3 jenkins/scripts/create-pipeline-job.py  to create them."
        exit 1
    fi

    info "Triggered ${#TRIGGERED_JOBS[@]}/${#pipelines_to_run[@]} pipeline(s)"
}

# =============================================================================
# Wait for build, stream output live, download reports — multi-pipeline
# =============================================================================
wait_and_download() {
    local total_jobs=${#TRIGGERED_JOBS[@]}
    local all_results=()
    local all_build_nums=()
    local overall_result="SUCCESS"

    for idx in $(seq 0 $((total_jobs - 1))); do
        local current_job="${TRIGGERED_JOBS[$idx]}"
        local current_scanid="${TRIGGERED_SCANIDS[$idx]}"
        local job_num=$((idx + 1))

        echo ""
        echo -e "${CYAN}${BOLD}"
        echo "  ╔═══════════════════════════════════════════════════════════════╗"
        printf "  ║  PIPELINE %d/%d: %-45s║\n" "${job_num}" "${total_jobs}" "${current_job}"
        echo "  ╚═══════════════════════════════════════════════════════════════╝"
        echo -e "${NC}"

        log_phase "PHASE 1: Queue & Build Assignment [${current_job}]"
        step "Waiting for '${current_job}' to start..."
        log_detail "Scan ID: ${current_scanid}"

        spin "Waiting for Jenkins to process build request..."
        sleep 3
        spin_done "Build request received by Jenkins"

        # ── Check queue ──
        local queue_wait=0 max_queue_wait=60 in_queue="true"
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
        task_name = item.get('task', {}).get('name', '')
        if task_name == '${current_job}':
            why = item.get('why', '')
            print(f'QUEUED|{why}')
except: pass
" 2>/dev/null || echo "")
            fi
            if [ -n "${queued_item}" ]; then
                local q_why
                q_why=$(echo "${queued_item}" | cut -d'|' -f2)
                spin "[${current_job}] Queued (${queue_wait}s) — ${q_why:-waiting for executor}"
                sleep 2
                queue_wait=$((queue_wait + 2))
            else
                in_queue="false"
            fi
        done
        [ ${queue_wait} -gt 0 ] && spin_done "Build left queue after ${queue_wait}s"

        # ── Find build number ──
        local build_num="" retries=0 max_retries=40
        while [ -z "${build_num}" ] && [ ${retries} -lt ${max_retries} ]; do
            spin "[${current_job}] Searching for build... (attempt ${retries}/${max_retries})"
            local last_build
            last_build=$(jenkins_get "${JENKINS_URL}/job/${current_job}/lastBuild/buildNumber" 2>/dev/null || echo "")
            if [ -n "${last_build}" ]; then
                for check_num in ${last_build} $((last_build - 1)) $((last_build + 1)) $((last_build - 2)) $((last_build + 2)); do
                    [ "${check_num}" -lt 1 ] 2>/dev/null && continue
                    local build_json
                    build_json=$(jenkins_get "${JENKINS_URL}/job/${current_job}/${check_num}/api/json" 2>/dev/null || echo "")
                    if [ -n "${build_json}" ]; then
                        local found_id
                        if command -v python3 &>/dev/null; then
                            found_id=$(echo "${build_json}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for a in d.get('actions', []):
        for p in a.get('parameters', []):
            if p.get('name') == 'SCAN_ID' and p.get('value') == '${current_scanid}':
                print(p['value'])
except: pass
" 2>/dev/null || echo "")
                        fi
                        if [ -n "${found_id}" ]; then
                            build_num="${check_num}"
                            break
                        fi
                    fi
                done
            fi
            retries=$((retries + 1))
            [ -z "${build_num}" ] && sleep 3
        done

        # Fallback to lastBuild
        if [ -z "${build_num}" ]; then
            build_num=$(jenkins_get "${JENKINS_URL}/job/${current_job}/lastBuild/buildNumber" 2>/dev/null || echo "")
            [ -n "${build_num}" ] && warn "Using latest build #${build_num} for ${current_job} (fallback)"
        fi

        if [ -z "${build_num}" ]; then
            spin_fail "Could not find build for '${current_job}'"
            all_results+=("UNKNOWN")
            all_build_nums+=("?")
            continue
        fi

        spin_done "[${current_job}] Build #${build_num} found"
        all_build_nums+=("${build_num}")
        log_phase_end

        log_phase "PHASE 2: Live Execution [${current_job} #${build_num}]"
        info "Pipeline '${current_job}' #${build_num} is running"
        echo -e "  ${DIM}Live console: ${JENKINS_URL}/job/${current_job}/${build_num}/console${NC}"
        echo ""

        # ── Stream console output ──
        if [[ "${QUIET}" != "true" ]]; then
            echo -e "${DIM}─── Live Console Output [${current_job}] ───────────────────────${NC}"
            local log_offset=0 building="True" tmp_headers poll_count=0
            local last_phase_msg=""
            tmp_headers=$(mktemp)

            while [ "${building}" = "True" ]; do
                poll_count=$((poll_count + 1))
                local console_chunk
                console_chunk=$(curl -s -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
                    -D "${tmp_headers}" \
                    "${JENKINS_URL}/job/${current_job}/${build_num}/logText/progressiveText?start=${log_offset}" \
                    2>/dev/null || echo "")

                if [ -n "${console_chunk}" ]; then
                    local detected_phase=""
                    if echo "${console_chunk}" | grep -qiE 'checking out|clone|git'; then
                        detected_phase="Checking out source code"
                    elif echo "${console_chunk}" | grep -qiE 'unit test|pytest|jest|go test|mvn test|dotnet test'; then
                        detected_phase="Running unit tests"
                    elif echo "${console_chunk}" | grep -qiE 'NO TESTS FOLDER DETECTED'; then
                        detected_phase="No test folder detected"
                    elif echo "${console_chunk}" | grep -qiE 'lint|eslint|flake8|checkstyle|golangci'; then
                        detected_phase="Running lint & code quality"
                    elif echo "${console_chunk}" | grep -qiE 'cyclonedx|sbom'; then
                        detected_phase="Generating SBOM"
                    elif echo "${console_chunk}" | grep -qiE 'sonarqube|sonar-scanner'; then
                        detected_phase="Running SonarQube analysis"
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
                        detected_phase="K8s manifest security audit"
                    elif echo "${console_chunk}" | grep -qiE 'docker.*build|podman.*build|container.*build'; then
                        detected_phase="Building container image"
                    elif echo "${console_chunk}" | grep -qiE 'deploy.*k8s|kubectl.*apply'; then
                        detected_phase="Deploying to Kubernetes"
                    elif echo "${console_chunk}" | grep -qiE 'generat.*report|html.*report|consolidat'; then
                        detected_phase="Generating reports"
                    elif echo "${console_chunk}" | grep -qiE 'archiv|artifact'; then
                        detected_phase="Archiving artifacts"
                    fi

                    if [ -n "${detected_phase}" ] && [ "${detected_phase}" != "${last_phase_msg}" ]; then
                        echo -e "\n  ${CYAN}${BOLD}▶ ${detected_phase}${NC} ${DIM}($(timestamp))${NC}"
                        last_phase_msg="${detected_phase}"
                    fi

                    echo "${console_chunk}"
                    local new_offset
                    new_offset=$(grep -i "X-Text-Size" "${tmp_headers}" 2>/dev/null | tr -d '\r' | awk '{print $2}' || echo "")
                    [ -n "${new_offset}" ] && log_offset="${new_offset}"
                else
                    if [ $((poll_count % 6)) -eq 0 ]; then
                        echo -e "  ${DIM}... waiting for output ($(timestamp), poll #${poll_count})${NC}"
                    fi
                fi

                local api_json
                api_json=$(jenkins_get "${JENKINS_URL}/job/${current_job}/${build_num}/api/json" 2>/dev/null || echo "")
                building=$(json_bool "${api_json}" "building" 2>/dev/null || echo "False")

                if [ "${building}" = "True" ]; then
                    sleep 3
                fi
            done

            # Final chunk
            local final_chunk
            final_chunk=$(curl -s -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
                "${JENKINS_URL}/job/${current_job}/${build_num}/logText/progressiveText?start=${log_offset}" \
                2>/dev/null || echo "")
            [ -n "${final_chunk}" ] && echo "${final_chunk}"
            rm -f "${tmp_headers}"
            echo -e "${DIM}────────────────────────────────────────────────────────────────${NC}"
        else
            local building="True" q_count=0
            while [ "${building}" = "True" ]; do
                q_count=$((q_count + 1))
                spin "[${current_job}] Running... (${q_count}0s elapsed)"
                sleep 10
                local api_json
                api_json=$(jenkins_get "${JENKINS_URL}/job/${current_job}/${build_num}/api/json" 2>/dev/null || echo "")
                building=$(json_bool "${api_json}" "building" 2>/dev/null || echo "False")
            done
            spin_done "[${current_job}] Complete"
        fi

        log_phase_end

        # ── Get result for this pipeline ──
        local result_json result duration
        result_json=$(jenkins_get "${JENKINS_URL}/job/${current_job}/${build_num}/api/json" 2>/dev/null || echo "")
        result=$(json_val "${result_json}" "result" 2>/dev/null || echo "UNKNOWN")
        duration=$(json_val "${result_json}" "duration" 2>/dev/null || echo "0")
        local dur_sec=$(( ${duration:-0} / 1000 ))

        all_results+=("${result}")

        echo ""
        case "${result}" in
            SUCCESS)  echo -e "  ${GREEN}${BOLD}[${current_job}] RESULT: PASS${NC} ${DIM}(${dur_sec}s)${NC}" ;;
            UNSTABLE) echo -e "  ${YELLOW}${BOLD}[${current_job}] RESULT: WARNING${NC} ${DIM}(${dur_sec}s)${NC}" ;;
            FAILURE)  echo -e "  ${RED}${BOLD}[${current_job}] RESULT: FAIL${NC} ${DIM}(${dur_sec}s)${NC}" ;;
            *)        echo -e "  ${RED}${BOLD}[${current_job}] RESULT: ${result}${NC} ${DIM}(${dur_sec}s)${NC}" ;;
        esac

        # Track overall result
        if [ "${result}" = "FAILURE" ]; then
            overall_result="FAILURE"
        elif [ "${result}" = "UNSTABLE" ] && [ "${overall_result}" != "FAILURE" ]; then
            overall_result="UNSTABLE"
        fi

        # ── Download reports for this pipeline ──
        local job_output_dir="${OUTPUT_DIR}/${current_job}"
        mkdir -p "${job_output_dir}"

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
            local total_artifacts count=0
            total_artifacts=$(echo "${artifacts}" | grep -c . 2>/dev/null || echo "0")
            log_detail "Downloading ${total_artifacts} artifacts for '${current_job}'..."
            while IFS= read -r artifact; do
                [ -z "${artifact}" ] && continue
                local filename
                filename=$(basename "${artifact}")
                count=$((count + 1))
                spin "[${current_job}] Downloading [${count}/${total_artifacts}]: ${filename}"
                curl -s -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
                    "${JENKINS_URL}/job/${current_job}/${build_num}/artifact/${artifact}" \
                    -o "${job_output_dir}/${filename}" 2>/dev/null
                spin_done "Downloaded: ${filename}"
            done <<< "${artifacts}"
            info "[${current_job}] Downloaded ${count} reports to ${job_output_dir}/"
        else
            warn "[${current_job}] No artifacts — saving console log"
        fi

        # Save console log per pipeline
        jenkins_get "${JENKINS_URL}/job/${current_job}/${build_num}/consoleText" \
            -o "${job_output_dir}/full-console-log.txt" 2>/dev/null
    done

    # Also save combined console log
    spin "Saving combined console log..."
    cat "${OUTPUT_DIR}"/*/full-console-log.txt > "${OUTPUT_DIR}/full-console-log.txt" 2>/dev/null || true
    spin_done "Combined console log saved"

    # ══════════════════════════════════════════════════════════════
    # FINAL COMBINED SUMMARY
    # ══════════════════════════════════════════════════════════════
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "  ╔═══════════════════════════════════════════════════════════════╗"
    echo "  ║              ALL PIPELINES COMPLETE                          ║"
    echo "  ╠═══════════════════════════════════════════════════════════════╣"
    printf "  ║  Overall:  %-48s ║\n" "${overall_result}"
    printf "  ║  User:     %-48s ║\n" "${USER_ID}@${HOST_ID}"
    printf "  ║  Reports:  %-48s ║\n" "${OUTPUT_DIR}/"

    echo "  ╠═══════════════════════════════════════════════════════════════╣"
    echo "  ║  Pipeline Results:                                           ║"
    for idx in $(seq 0 $((total_jobs - 1))); do
        local job_name="${TRIGGERED_JOBS[$idx]}"
        local job_result="${all_results[$idx]}"
        local job_build="${all_build_nums[$idx]}"
        local result_icon="✔"
        [ "${job_result}" = "FAILURE" ] && result_icon="✘"
        [ "${job_result}" = "UNSTABLE" ] && result_icon="⚠"
        printf "  ║    %s %-18s #%-6s %-21s ║\n" "${result_icon}" "${job_name}" "${job_build}" "${job_result}"
    done

    echo "  ╠═══════════════════════════════════════════════════════════════╣"
    echo "  ║  View Reports:                                               ║"
    printf "  ║    ls %-54s║\n" "${OUTPUT_DIR}/"
    echo "  ║                                                              ║"
    echo "  ║  Pipeline Consoles:                                          ║"
    for idx in $(seq 0 $((total_jobs - 1))); do
        local job_name="${TRIGGERED_JOBS[$idx]}"
        local job_build="${all_build_nums[$idx]}"
        printf "  ║    %-56s║\n" "${JENKINS_URL}/job/${job_name}/${job_build}/console"
    done
    echo "  ╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    log_phase_end

    # List downloaded files
    if [ -d "${OUTPUT_DIR}" ]; then
        echo "  Downloaded report structure:"
        for job_dir in "${OUTPUT_DIR}"/*/; do
            [ -d "${job_dir}" ] || continue
            local dir_name
            dir_name=$(basename "${job_dir}")
            local file_count
            file_count=$(find "${job_dir}" -type f | wc -l)
            echo "    ${dir_name}/ (${file_count} files)"
            ls -lh "${job_dir}" 2>/dev/null | tail -n +2 | while read -r line; do
                echo "      ${line}"
            done
        done
        echo ""
    fi

    # Auto-open HTML reports
    if [[ "${OPEN_REPORT}" == "true" ]]; then
        local html_report
        html_report=$(find "${OUTPUT_DIR}" -name "*.html" -type f | head -1)
        if [ -n "${html_report}" ]; then
            if command -v xdg-open &>/dev/null; then
                xdg-open "${html_report}" 2>/dev/null &
            elif command -v open &>/dev/null; then
                open "${html_report}" 2>/dev/null &
            fi
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
    provision_dynamic_agent
    trigger_scan
    wait_and_download

    # Cleanup: destroy dynamic agent (Jenkinsfile post{} also does this as backup)
    destroy_dynamic_agent
}

main
