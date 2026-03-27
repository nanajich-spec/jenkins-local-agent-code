#!/usr/bin/env bash
# =============================================================================
# dynamic-agent-manager.sh — On-Demand JNLP Agent Lifecycle Manager
# =============================================================================
# Creates a temporary Jenkins JNLP agent for each scan, runs it, and deletes
# it when the scan completes. This eliminates queue waiting — every scan gets
# its own agent immediately.
#
# Usage:
#   ./dynamic-agent-manager.sh create  <scan-id>     → creates agent, starts it
#   ./dynamic-agent-manager.sh destroy <scan-id>     → stops agent, removes from Jenkins
#   ./dynamic-agent-manager.sh status  <scan-id>     → check agent status
#   ./dynamic-agent-manager.sh list                  → list active dynamic agents
#   ./dynamic-agent-manager.sh cleanup               → remove stale agents (>2h old)
#
# Each agent:
#   - Gets a unique name: scan-agent-<short-id>
#   - Gets its own workspace under /opt/jenkins-agent/dynamic/<scan-id>/
#   - Runs as a JNLP agent on the same host (all tools are already installed)
#   - Auto-deleted after the scan completes
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
JENKINS_URL="${JENKINS_URL:-http://132.186.17.25:32000}"
JENKINS_USER="${JENKINS_USER:-admin}"
JENKINS_PASS="${JENKINS_PASS:-admin}"
DYNAMIC_AGENT_BASE="/opt/jenkins-agent/dynamic"
AGENT_JAR="/opt/jenkins-agent/agent.jar"
JAVA_CMD="${JAVA_CMD:-java}"
MAX_CONCURRENT_AGENTS="${MAX_CONCURRENT_AGENTS:-10}"
AGENT_TTL_SECONDS="${AGENT_TTL_SECONDS:-7200}"   # Auto-cleanup after 2 hours
AGENT_LABELS_BASE="dynamic-security-agent linux security trivy podman"

# Lock directory for concurrency control
LOCK_DIR="${DYNAMIC_AGENT_BASE}/.locks"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $*"; }

# =============================================================================
# Helpers
# =============================================================================

# Get CSRF crumb for Jenkins API calls (with cookie jar for session binding)
# Jenkins 2.x ties crumbs to sessions, so we MUST use a cookie jar
COOKIE_JAR="${DYNAMIC_AGENT_BASE}/.jenkins-cookies-$$.txt"

get_crumb() {
    local crumb_response
    crumb_response=$(curl -s -c "${COOKIE_JAR}" -u "${JENKINS_USER}:${JENKINS_PASS}" \
        "${JENKINS_URL}/crumbIssuer/api/json" 2>/dev/null || echo "")

    if echo "${crumb_response}" | python3 -c "import sys,json; json.load(sys.stdin)" &>/dev/null; then
        local hdr val
        hdr=$(echo "${crumb_response}" | python3 -c "import sys,json; print(json.load(sys.stdin)['crumbRequestField'])")
        val=$(echo "${crumb_response}" | python3 -c "import sys,json; print(json.load(sys.stdin)['crumb'])")
        echo "-H ${hdr}:${val}"
    else
        echo ""
    fi
}

# Execute a Groovy script on Jenkins (most reliable method for node management)
jenkins_groovy() {
    local script="$1"
    local CRUMB
    CRUMB=$(get_crumb)
    curl -s -b "${COOKIE_JAR}" -u "${JENKINS_USER}:${JENKINS_PASS}" \
        ${CRUMB} \
        --data-urlencode "script=${script}" \
        "${JENKINS_URL}/scriptText" 2>/dev/null
}

jenkins_get() {
    curl -s -u "${JENKINS_USER}:${JENKINS_PASS}" "$@"
}

# Derive a short, safe agent name from SCAN_ID
# e.g., "AD001+user-host-1774587218" → "scan-agent-1774587218"
agent_name_from_scan_id() {
    local scan_id="$1"
    # Use the last segment (epoch) for uniqueness, prefix for clarity
    local short_id
    short_id=$(echo "${scan_id}" | grep -oE '[0-9]{8,}$' || echo "${scan_id}" | md5sum | cut -c1-12)
    echo "scan-agent-${short_id}"
}

agent_workdir_from_scan_id() {
    local scan_id="$1"
    echo "${DYNAMIC_AGENT_BASE}/$(agent_name_from_scan_id "${scan_id}")"
}

count_active_agents() {
    local count=0
    if [ -d "${DYNAMIC_AGENT_BASE}" ]; then
        count=$(find "${DYNAMIC_AGENT_BASE}" -maxdepth 1 -name "scan-agent-*" -type d 2>/dev/null | wc -l)
    fi
    echo "${count}"
}

# =============================================================================
# CREATE: Provision a new dynamic agent for a scan
# =============================================================================
create_agent() {
    local scan_id="$1"
    local agent_name
    agent_name=$(agent_name_from_scan_id "${scan_id}")
    local agent_workdir
    agent_workdir=$(agent_workdir_from_scan_id "${scan_id}")

    log_step "Creating dynamic agent '${agent_name}' for scan: ${scan_id}"

    # ── Check concurrency limit ──
    local active
    active=$(count_active_agents)
    if [ "${active}" -ge "${MAX_CONCURRENT_AGENTS}" ]; then
        log_error "Maximum concurrent agents (${MAX_CONCURRENT_AGENTS}) reached."
        log_error "Active agents: ${active}. Run cleanup or wait for scans to complete."
        # Try auto-cleanup of stale agents before failing
        cleanup_stale_agents
        active=$(count_active_agents)
        if [ "${active}" -ge "${MAX_CONCURRENT_AGENTS}" ]; then
            log_error "Still at limit after cleanup. Cannot create new agent."
            exit 1
        fi
        log_info "Cleanup freed slots. Continuing..."
    fi

    # ── Create workspace ──
    mkdir -p "${agent_workdir}"
    mkdir -p "${LOCK_DIR}"
    echo "${scan_id}" > "${agent_workdir}/scan-id.txt"
    date +%s > "${agent_workdir}/created-at.txt"

    # ── Ensure agent.jar exists ──
    if [ ! -f "${AGENT_JAR}" ]; then
        log_info "Downloading agent.jar from Jenkins master..."
        mkdir -p "$(dirname "${AGENT_JAR}")"
        curl -sL -u "${JENKINS_USER}:${JENKINS_PASS}" \
            "${JENKINS_URL}/jnlpJars/agent.jar" \
            -o "${AGENT_JAR}"
    fi

    # ── Create node in Jenkins via Groovy API ──
    # The Groovy scriptText API is the most reliable method for node creation
    # (the form-based doCreateItem endpoint has CSRF session-binding issues)

    # Check if node already exists (from a previous failed cleanup)
    local node_exists
    node_exists=$(curl -s -o /dev/null -w "%{http_code}" -u "${JENKINS_USER}:${JENKINS_PASS}" \
        "${JENKINS_URL}/computer/${agent_name}/api/json" 2>/dev/null || echo "404")

    if [ "${node_exists}" = "200" ]; then
        log_warn "Node '${agent_name}' already exists — reusing"
    else
        log_info "Creating Jenkins node '${agent_name}' via Groovy API..."

        local groovy_create
        groovy_create="
import hudson.model.*
import hudson.slaves.*
import jenkins.model.*

def launcher = new JNLPLauncher(false)
def node = new DumbSlave(
    '${agent_name}',
    '${agent_workdir}',
    launcher
)
node.nodeDescription = 'Dynamic agent for scan ${scan_id}'
node.numExecutors = 1
node.labelString = '${AGENT_LABELS_BASE} ${agent_name}'
node.mode = Node.Mode.EXCLUSIVE
node.retentionStrategy = new RetentionStrategy.Always()
Jenkins.instance.addNode(node)
println 'CREATED:' + node.nodeName
"
        local create_result
        create_result=$(jenkins_groovy "${groovy_create}")

        if echo "${create_result}" | grep -q "CREATED:"; then
            log_info "Jenkins node '${agent_name}' created successfully"
        else
            log_error "Failed to create Jenkins node via Groovy API"
            log_error "Response: ${create_result}"
            # Don't exit — try to continue in case the node was partially created
        fi
    fi

    # ── Get agent secret ──
    log_info "Retrieving agent secret..."
    sleep 1  # Give Jenkins a moment to register the node

    local agent_secret=""
    agent_secret=$(curl -s -u "${JENKINS_USER}:${JENKINS_PASS}" \
        "${JENKINS_URL}/computer/${agent_name}/jenkins-agent.jnlp" 2>/dev/null | \
        grep -oP '<argument>\K[a-f0-9]{64}' | head -1 || echo "")

    if [ -z "${agent_secret}" ]; then
        agent_secret=$(curl -s -u "${JENKINS_USER}:${JENKINS_PASS}" \
            "${JENKINS_URL}/computer/${agent_name}/slave-agent.jnlp" 2>/dev/null | \
            grep -oP '<argument>\K[a-f0-9]{64}' | head -1 || echo "")
    fi

    if [ -z "${agent_secret}" ]; then
        log_error "Could not retrieve agent secret for ${agent_name}"
        log_error "Check: ${JENKINS_URL}/computer/${agent_name}/"
        destroy_agent "${scan_id}"
        exit 1
    fi

    echo "${agent_secret}" > "${agent_workdir}/agent-secret.txt"
    chmod 600 "${agent_workdir}/agent-secret.txt"

    # ── Launch JNLP agent ──
    log_info "Starting JNLP agent '${agent_name}'..."

    nohup ${JAVA_CMD} -jar "${AGENT_JAR}" \
        -url "${JENKINS_URL}" \
        -name "${agent_name}" \
        -secret "${agent_secret}" \
        -workDir "${agent_workdir}" \
        -webSocket \
        > "${agent_workdir}/agent.log" 2>&1 &

    local agent_pid=$!
    echo "${agent_pid}" > "${agent_workdir}/agent.pid"

    # ── Wait for agent to come online ──
    log_info "Waiting for agent to connect to Jenkins..."
    local wait_count=0 max_wait=30
    while [ ${wait_count} -lt ${max_wait} ]; do
        sleep 2
        wait_count=$((wait_count + 2))

        # Check if process is still alive
        if ! kill -0 "${agent_pid}" 2>/dev/null; then
            log_error "Agent process died. Check log: ${agent_workdir}/agent.log"
            tail -20 "${agent_workdir}/agent.log" 2>/dev/null || true
            destroy_agent "${scan_id}"
            exit 1
        fi

        # Check if Jenkins sees the agent as online
        local agent_json
        agent_json=$(jenkins_get "${JENKINS_URL}/computer/${agent_name}/api/json" 2>/dev/null || echo "")
        if [ -n "${agent_json}" ]; then
            local offline
            offline=$(echo "${agent_json}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('offline', True))" 2>/dev/null || echo "True")
            if [ "${offline}" = "False" ]; then
                log_info "Agent '${agent_name}' is ONLINE (took ${wait_count}s)"
                echo "ONLINE" > "${agent_workdir}/status.txt"
                echo ""
                log_info "=========================================="
                log_info "  Dynamic Agent Ready"
                log_info "=========================================="
                log_info "  Agent:     ${agent_name}"
                log_info "  Label:     ${agent_name}"
                log_info "  Scan ID:   ${scan_id}"
                log_info "  Workspace: ${agent_workdir}"
                log_info "  PID:       ${agent_pid}"
                log_info "=========================================="
                return 0
            fi
        fi
    done

    log_error "Agent did not come online within ${max_wait}s"
    log_error "Check log: ${agent_workdir}/agent.log"
    tail -10 "${agent_workdir}/agent.log" 2>/dev/null || true
    destroy_agent "${scan_id}"
    exit 1
}

# =============================================================================
# DESTROY: Stop agent and remove from Jenkins
# =============================================================================
destroy_agent() {
    local scan_id="$1"
    local agent_name
    agent_name=$(agent_name_from_scan_id "${scan_id}")
    local agent_workdir
    agent_workdir=$(agent_workdir_from_scan_id "${scan_id}")

    log_step "Destroying dynamic agent '${agent_name}'..."

    # ── Stop the JNLP process ──
    if [ -f "${agent_workdir}/agent.pid" ]; then
        local pid
        pid=$(cat "${agent_workdir}/agent.pid")
        if kill -0 "${pid}" 2>/dev/null; then
            log_info "Stopping agent process (PID ${pid})..."
            kill "${pid}" 2>/dev/null || true
            sleep 2
            kill -9 "${pid}" 2>/dev/null || true
        fi
    fi

    # ── Delete the node from Jenkins via Groovy ──
    log_info "Removing node '${agent_name}' from Jenkins..."
    local delete_result
    delete_result=$(jenkins_groovy "
def node = Jenkins.instance.getNode('${agent_name}')
if (node) {
    Jenkins.instance.removeNode(node)
    println 'DELETED:${agent_name}'
} else {
    println 'NOT_FOUND:${agent_name}'
}
")

    if echo "${delete_result}" | grep -q "DELETED:"; then
        log_info "Node '${agent_name}' deleted from Jenkins"
    elif echo "${delete_result}" | grep -q "NOT_FOUND:"; then
        log_info "Node '${agent_name}' was already removed"
    else
        log_warn "Could not delete node — may need manual cleanup"
        log_warn "  ${JENKINS_URL}/computer/${agent_name}/delete"
    fi

    # ── Clean up local workspace ──
    if [ -d "${agent_workdir}" ]; then
        log_info "Cleaning up workspace: ${agent_workdir}"
        rm -rf "${agent_workdir}"
    fi

    log_info "Agent '${agent_name}' destroyed successfully"
}

# =============================================================================
# STATUS: Check agent status
# =============================================================================
status_agent() {
    local scan_id="$1"
    local agent_name
    agent_name=$(agent_name_from_scan_id "${scan_id}")
    local agent_workdir
    agent_workdir=$(agent_workdir_from_scan_id "${scan_id}")

    echo "=========================================="
    echo "  Dynamic Agent Status: ${agent_name}"
    echo "=========================================="

    # Local process
    if [ -f "${agent_workdir}/agent.pid" ]; then
        local pid
        pid=$(cat "${agent_workdir}/agent.pid")
        if kill -0 "${pid}" 2>/dev/null; then
            echo -e "  Process:   ${GREEN}RUNNING${NC} (PID ${pid})"
        else
            echo -e "  Process:   ${RED}STOPPED${NC}"
        fi
    else
        echo -e "  Process:   ${YELLOW}NO PID FILE${NC}"
    fi

    # Jenkins status
    local agent_json
    agent_json=$(jenkins_get "${JENKINS_URL}/computer/${agent_name}/api/json" 2>/dev/null || echo "")
    if [ -n "${agent_json}" ]; then
        local offline
        offline=$(echo "${agent_json}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('offline', True))" 2>/dev/null || echo "True")
        if [ "${offline}" = "False" ]; then
            echo -e "  Jenkins:   ${GREEN}ONLINE${NC}"
        else
            echo -e "  Jenkins:   ${RED}OFFLINE${NC}"
        fi
    else
        echo -e "  Jenkins:   ${YELLOW}NOT FOUND${NC}"
    fi

    # Metadata
    if [ -f "${agent_workdir}/scan-id.txt" ]; then
        echo "  Scan ID:   $(cat "${agent_workdir}/scan-id.txt")"
    fi
    if [ -f "${agent_workdir}/created-at.txt" ]; then
        local created_ts
        created_ts=$(cat "${agent_workdir}/created-at.txt")
        local now_ts
        now_ts=$(date +%s)
        local age=$(( now_ts - created_ts ))
        echo "  Created:   $(date -d @"${created_ts}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "${created_ts}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "${created_ts}")"
        echo "  Age:       $((age / 60))m $((age % 60))s"
    fi
    echo "  Workspace: ${agent_workdir}"
    echo "=========================================="
}

# =============================================================================
# LIST: Show all active dynamic agents
# =============================================================================
list_agents() {
    echo "=========================================="
    echo "  Active Dynamic Agents"
    echo "=========================================="

    local found=0
    if [ -d "${DYNAMIC_AGENT_BASE}" ]; then
        for agent_dir in "${DYNAMIC_AGENT_BASE}"/scan-agent-*; do
            [ -d "${agent_dir}" ] || continue
            found=$((found + 1))
            local name
            name=$(basename "${agent_dir}")
            local status="UNKNOWN"

            if [ -f "${agent_dir}/agent.pid" ]; then
                local pid
                pid=$(cat "${agent_dir}/agent.pid")
                if kill -0 "${pid}" 2>/dev/null; then
                    status="${GREEN}RUNNING${NC}"
                else
                    status="${RED}STOPPED${NC}"
                fi
            fi

            local scan_id=""
            [ -f "${agent_dir}/scan-id.txt" ] && scan_id=$(cat "${agent_dir}/scan-id.txt")

            local age_str=""
            if [ -f "${agent_dir}/created-at.txt" ]; then
                local created_ts now_ts age
                created_ts=$(cat "${agent_dir}/created-at.txt")
                now_ts=$(date +%s)
                age=$(( now_ts - created_ts ))
                age_str="$((age / 60))m"
            fi

            printf "  %-25s  %-20b  %-15s  %s\n" "${name}" "${status}" "${age_str}" "${scan_id}"
        done
    fi

    if [ ${found} -eq 0 ]; then
        echo "  No active dynamic agents"
    fi
    echo ""
    echo "  Total: ${found} / ${MAX_CONCURRENT_AGENTS} max"
    echo "=========================================="
}

# =============================================================================
# CLEANUP: Remove stale agents older than TTL
# =============================================================================
cleanup_stale_agents() {
    log_step "Cleaning up stale dynamic agents (TTL: $((AGENT_TTL_SECONDS / 60))m)..."

    local cleaned=0
    if [ -d "${DYNAMIC_AGENT_BASE}" ]; then
        for agent_dir in "${DYNAMIC_AGENT_BASE}"/scan-agent-*; do
            [ -d "${agent_dir}" ] || continue

            if [ -f "${agent_dir}/created-at.txt" ]; then
                local created_ts now_ts age
                created_ts=$(cat "${agent_dir}/created-at.txt")
                now_ts=$(date +%s)
                age=$(( now_ts - created_ts ))

                if [ ${age} -gt ${AGENT_TTL_SECONDS} ]; then
                    local scan_id=""
                    [ -f "${agent_dir}/scan-id.txt" ] && scan_id=$(cat "${agent_dir}/scan-id.txt")
                    log_warn "Stale agent found: $(basename "${agent_dir}") (age: $((age / 60))m)"

                    if [ -n "${scan_id}" ]; then
                        destroy_agent "${scan_id}"
                    else
                        # No scan ID — force remove
                        local name
                        name=$(basename "${agent_dir}")
                        if [ -f "${agent_dir}/agent.pid" ]; then
                            kill -9 "$(cat "${agent_dir}/agent.pid")" 2>/dev/null || true
                        fi
                        local CRUMB
                        CRUMB=$(get_crumb)
                        curl -s -u "${JENKINS_USER}:${JENKINS_PASS}" \
                            ${CRUMB} -X POST \
                            "${JENKINS_URL}/computer/${name}/doDelete" 2>/dev/null || true
                        rm -rf "${agent_dir}"
                    fi
                    cleaned=$((cleaned + 1))
                fi
            fi
        done
    fi

    log_info "Cleaned up ${cleaned} stale agent(s)"
}

# =============================================================================
# Main
# =============================================================================
case "${1:-}" in
    create)
        [ -z "${2:-}" ] && { log_error "Usage: $0 create <scan-id>"; exit 1; }
        create_agent "$2"
        ;;
    destroy)
        [ -z "${2:-}" ] && { log_error "Usage: $0 destroy <scan-id>"; exit 1; }
        destroy_agent "$2"
        ;;
    status)
        [ -z "${2:-}" ] && { log_error "Usage: $0 status <scan-id>"; exit 1; }
        status_agent "$2"
        ;;
    list)
        list_agents
        ;;
    cleanup)
        cleanup_stale_agents
        ;;
    *)
        echo "Usage: $0 {create|destroy|status|list|cleanup} [scan-id]"
        echo ""
        echo "  create  <scan-id>    Create and start a dynamic agent for a scan"
        echo "  destroy <scan-id>    Stop and remove a dynamic agent"
        echo "  status  <scan-id>    Check agent status"
        echo "  list                 List all active dynamic agents"
        echo "  cleanup              Remove stale agents (older than 2 hours)"
        exit 1
        ;;
esac

# Cleanup cookie jar
rm -f "${COOKIE_JAR}" 2>/dev/null || true