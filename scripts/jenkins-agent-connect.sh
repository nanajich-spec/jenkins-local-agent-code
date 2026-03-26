#!/usr/bin/env bash
# =============================================================================
# jenkins-agent-connect.sh — Connect Local JNLP Agent to Jenkins Master
# =============================================================================
# This script downloads the Jenkins agent JAR from the master, creates the
# agent node via Jenkins REST API, and launches the JNLP connection.
#
# Prerequisites:
#   - Java 11+ installed
#   - Network access to Jenkins master
#   - curl installed
#
# Usage:
#   chmod +x jenkins-agent-connect.sh
#   ./jenkins-agent-connect.sh [--setup | --start | --stop | --status]
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuration — adjust these values for your environment
# =============================================================================
JENKINS_URL="${JENKINS_URL:-http://132.186.17.25:32000}"
JENKINS_USER="${JENKINS_USER:-admin}"
JENKINS_PASS="${JENKINS_PASS:-admin}"
AGENT_NAME="${AGENT_NAME:-local-security-agent}"
AGENT_WORKDIR="${AGENT_WORKDIR:-/opt/jenkins-agent}"
AGENT_LABELS="${AGENT_LABELS:-local-security-agent linux security trivy podman}"
AGENT_EXECUTORS="${AGENT_EXECUTORS:-2}"
AGENT_JAR="${AGENT_WORKDIR}/agent.jar"
AGENT_PID_FILE="${AGENT_WORKDIR}/agent.pid"
AGENT_LOG="${AGENT_WORKDIR}/agent.log"
JAVA_CMD="${JAVA_CMD:-java}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $*"; }

# =============================================================================
# Get Jenkins Crumb for CSRF protection
# =============================================================================
get_crumb() {
    local crumb_response
    crumb_response=$(curl -s -u "${JENKINS_USER}:${JENKINS_PASS}" \
        "${JENKINS_URL}/crumbIssuer/api/json" 2>/dev/null || echo "")

    if echo "${crumb_response}" | python3 -c "import sys,json; json.load(sys.stdin)" &>/dev/null; then
        CRUMB_HEADER=$(echo "${crumb_response}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['crumbRequestField'])")
        CRUMB_VALUE=$(echo "${crumb_response}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['crumb'])")
        echo "-H ${CRUMB_HEADER}:${CRUMB_VALUE}"
    else
        echo ""
    fi
}

# =============================================================================
# Setup: Create agent directory, download JAR, create node in Jenkins
# =============================================================================
setup_agent() {
    log_step "Setting up Jenkins agent '${AGENT_NAME}'"

    # Create work directory
    log_info "Creating agent work directory: ${AGENT_WORKDIR}"
    mkdir -p "${AGENT_WORKDIR}"

    # Test Jenkins connectivity
    log_info "Testing Jenkins connectivity at ${JENKINS_URL}..."
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -u "${JENKINS_USER}:${JENKINS_PASS}" \
        "${JENKINS_URL}/api/json" 2>/dev/null || echo "000")
    if [ "${HTTP_CODE}" != "200" ]; then
        log_error "Cannot reach Jenkins at ${JENKINS_URL} (HTTP ${HTTP_CODE})"
        log_error "Check JENKINS_URL, JENKINS_USER, JENKINS_PASS"
        exit 1
    fi
    log_info "Jenkins is reachable (HTTP ${HTTP_CODE})"

    # Download agent.jar
    log_info "Downloading agent.jar from Jenkins master..."
    curl -sL -u "${JENKINS_USER}:${JENKINS_PASS}" \
        "${JENKINS_URL}/jnlpJars/agent.jar" \
        -o "${AGENT_JAR}"

    if [ ! -f "${AGENT_JAR}" ] || [ ! -s "${AGENT_JAR}" ]; then
        log_error "Failed to download agent.jar"
        exit 1
    fi
    log_info "agent.jar downloaded ($(du -h "${AGENT_JAR}" | cut -f1))"

    # Get crumb
    CRUMB=$(get_crumb)

    # Check if node already exists
    NODE_EXISTS=$(curl -s -o /dev/null -w "%{http_code}" -u "${JENKINS_USER}:${JENKINS_PASS}" \
        "${JENKINS_URL}/computer/${AGENT_NAME}/api/json" 2>/dev/null || echo "404")

    if [ "${NODE_EXISTS}" = "200" ]; then
        log_warn "Node '${AGENT_NAME}' already exists in Jenkins"
    else
        # Create the agent node via Jenkins REST API
        log_info "Creating agent node '${AGENT_NAME}' in Jenkins..."

        NODE_CONFIG=$(cat <<NODEEOF
{
  "name": "${AGENT_NAME}",
  "nodeDescription": "Local Security Scanning Agent ($(hostname))",
  "numExecutors": "${AGENT_EXECUTORS}",
  "remoteFS": "${AGENT_WORKDIR}",
  "labelString": "${AGENT_LABELS}",
  "mode": "EXCLUSIVE",
  "retentionStrategy": {
    "stapler-class": "hudson.slaves.RetentionStrategy\$Always"
  },
  "nodeProperties": {"stapler-class-bag": "true"},
  "launcher": {
    "stapler-class": "hudson.slaves.JNLPLauncher",
    "\$class": "hudson.slaves.JNLPLauncher",
    "workDirSettings": {
      "disabled": false,
      "internalDir": "remoting",
      "failIfWorkDirIsMissing": false
    },
    "webSocket": false,
    "tunnel": ""
  },
  "type": "hudson.slaves.DumbSlave"
}
NODEEOF
)

        CREATE_RESULT=$(curl -s -w "\n%{http_code}" -u "${JENKINS_USER}:${JENKINS_PASS}" \
            ${CRUMB} \
            -X POST \
            "${JENKINS_URL}/computer/doCreateItem" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            --data-urlencode "name=${AGENT_NAME}" \
            --data-urlencode "type=hudson.slaves.DumbSlave" \
            --data-urlencode "json=${NODE_CONFIG}" 2>/dev/null)

        CREATE_CODE=$(echo "${CREATE_RESULT}" | tail -1)
        if [ "${CREATE_CODE}" = "200" ] || [ "${CREATE_CODE}" = "302" ]; then
            log_info "Agent node created successfully"
        else
            log_warn "Node creation returned HTTP ${CREATE_CODE} (may already exist or require manual creation)"
            log_warn "If auto-creation fails, create the node manually in Jenkins UI:"
            log_warn "  ${JENKINS_URL}/computer/new"
        fi
    fi

    # Get the agent secret
    log_info "Retrieving agent secret..."
    AGENT_SECRET=$(curl -s -u "${JENKINS_USER}:${JENKINS_PASS}" \
        "${JENKINS_URL}/computer/${AGENT_NAME}/jenkins-agent.jnlp" 2>/dev/null | \
        grep -oP '<argument>\K[a-f0-9]{64}' | head -1 || echo "")

    if [ -z "${AGENT_SECRET}" ]; then
        # Alternative: try the slave-agent.jnlp endpoint
        AGENT_SECRET=$(curl -s -u "${JENKINS_USER}:${JENKINS_PASS}" \
            "${JENKINS_URL}/computer/${AGENT_NAME}/slave-agent.jnlp" 2>/dev/null | \
            grep -oP '<argument>\K[a-f0-9]{64}' | head -1 || echo "")
    fi

    if [ -n "${AGENT_SECRET}" ]; then
        echo "${AGENT_SECRET}" > "${AGENT_WORKDIR}/agent-secret.txt"
        chmod 600 "${AGENT_WORKDIR}/agent-secret.txt"
        log_info "Agent secret saved to ${AGENT_WORKDIR}/agent-secret.txt"
    else
        log_warn "Could not auto-retrieve agent secret."
        log_warn "Get it manually from: ${JENKINS_URL}/computer/${AGENT_NAME}/"
        log_warn "Save it to: ${AGENT_WORKDIR}/agent-secret.txt"
    fi

    # Create systemd service file
    create_systemd_service

    log_info ""
    log_info "=========================================="
    log_info "  Agent setup complete!"
    log_info "=========================================="
    log_info "  Agent name:   ${AGENT_NAME}"
    log_info "  Work dir:     ${AGENT_WORKDIR}"
    log_info "  Labels:       ${AGENT_LABELS}"
    log_info "  Jenkins URL:  ${JENKINS_URL}"
    log_info ""
    log_info "  Next steps:"
    log_info "    1. Run: $0 --start"
    log_info "    2. Or:  systemctl start jenkins-agent"
    log_info "=========================================="
}

# =============================================================================
# Create systemd service for persistent agent
# =============================================================================
create_systemd_service() {
    local SERVICE_FILE="/etc/systemd/system/jenkins-agent.service"

    log_info "Creating systemd service: ${SERVICE_FILE}"

    cat > "${SERVICE_FILE}" <<SVCEOF
[Unit]
Description=Jenkins JNLP Agent (${AGENT_NAME})
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${AGENT_WORKDIR}
ExecStart=${JAVA_CMD} -jar ${AGENT_JAR} \\
    -url ${JENKINS_URL} \\
    -name ${AGENT_NAME} \\
    -secret @${AGENT_WORKDIR}/agent-secret.txt \\
    -workDir ${AGENT_WORKDIR} \\
    -webSocket
Restart=on-failure
RestartSec=10
StandardOutput=append:${AGENT_LOG}
StandardError=append:${AGENT_LOG}

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload 2>/dev/null || true
    log_info "Systemd service created. Enable with: systemctl enable jenkins-agent"
}

# =============================================================================
# Start the agent
# =============================================================================
start_agent() {
    log_step "Starting Jenkins agent '${AGENT_NAME}'..."

    if [ -f "${AGENT_PID_FILE}" ] && kill -0 "$(cat "${AGENT_PID_FILE}")" 2>/dev/null; then
        log_warn "Agent is already running (PID $(cat "${AGENT_PID_FILE}"))"
        return 0
    fi

    if [ ! -f "${AGENT_JAR}" ]; then
        log_error "agent.jar not found. Run: $0 --setup first."
        exit 1
    fi

    # Read secret
    if [ -f "${AGENT_WORKDIR}/agent-secret.txt" ]; then
        AGENT_SECRET=$(cat "${AGENT_WORKDIR}/agent-secret.txt")
    else
        log_error "Agent secret not found at ${AGENT_WORKDIR}/agent-secret.txt"
        log_error "Get it from: ${JENKINS_URL}/computer/${AGENT_NAME}/"
        exit 1
    fi

    # Start agent in background
    nohup ${JAVA_CMD} -jar "${AGENT_JAR}" \
        -url "${JENKINS_URL}" \
        -name "${AGENT_NAME}" \
        -secret "${AGENT_SECRET}" \
        -workDir "${AGENT_WORKDIR}" \
        -webSocket \
        > "${AGENT_LOG}" 2>&1 &

    echo $! > "${AGENT_PID_FILE}"
    log_info "Agent started (PID $(cat "${AGENT_PID_FILE}"))"
    log_info "Log: tail -f ${AGENT_LOG}"

    # Wait a moment and check
    sleep 3
    if kill -0 "$(cat "${AGENT_PID_FILE}")" 2>/dev/null; then
        log_info "Agent is running successfully"
        log_info "Verify at: ${JENKINS_URL}/computer/${AGENT_NAME}/"
    else
        log_error "Agent process died. Check log: ${AGENT_LOG}"
        exit 1
    fi
}

# =============================================================================
# Stop the agent
# =============================================================================
stop_agent() {
    log_step "Stopping Jenkins agent '${AGENT_NAME}'..."

    if [ -f "${AGENT_PID_FILE}" ]; then
        PID=$(cat "${AGENT_PID_FILE}")
        if kill -0 "${PID}" 2>/dev/null; then
            kill "${PID}"
            sleep 2
            if kill -0 "${PID}" 2>/dev/null; then
                kill -9 "${PID}" || true
            fi
            log_info "Agent stopped (PID ${PID})"
        else
            log_warn "Agent process not running (stale PID file)"
        fi
        rm -f "${AGENT_PID_FILE}"
    else
        # Try systemd
        systemctl stop jenkins-agent 2>/dev/null && log_info "Agent stopped via systemd" || \
            log_warn "No running agent found"
    fi
}

# =============================================================================
# Status check
# =============================================================================
status_agent() {
    echo "=========================================="
    echo "  Jenkins Agent Status"
    echo "=========================================="

    # Local process status
    if [ -f "${AGENT_PID_FILE}" ] && kill -0 "$(cat "${AGENT_PID_FILE}")" 2>/dev/null; then
        echo -e "  Local process:  ${GREEN}RUNNING${NC} (PID $(cat "${AGENT_PID_FILE}"))"
    else
        echo -e "  Local process:  ${RED}STOPPED${NC}"
    fi

    # Systemd status
    if systemctl is-active jenkins-agent &>/dev/null; then
        echo -e "  Systemd:        ${GREEN}ACTIVE${NC}"
    else
        echo -e "  Systemd:        ${YELLOW}INACTIVE${NC}"
    fi

    # Jenkins master status
    AGENT_STATUS=$(curl -s -u "${JENKINS_USER}:${JENKINS_PASS}" \
        "${JENKINS_URL}/computer/${AGENT_NAME}/api/json" 2>/dev/null || echo "")

    if [ -n "${AGENT_STATUS}" ]; then
        OFFLINE=$(echo "${AGENT_STATUS}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('offline', True))" 2>/dev/null || echo "true")
        if [ "${OFFLINE}" = "False" ]; then
            echo -e "  Jenkins status:  ${GREEN}ONLINE${NC}"
        else
            echo -e "  Jenkins status:  ${RED}OFFLINE${NC}"
        fi
    else
        echo -e "  Jenkins status:  ${YELLOW}UNKNOWN${NC} (cannot reach master)"
    fi

    echo ""
    echo "  Agent name:     ${AGENT_NAME}"
    echo "  Work dir:       ${AGENT_WORKDIR}"
    echo "  Jenkins URL:    ${JENKINS_URL}"
    echo "  Log file:       ${AGENT_LOG}"
    echo "=========================================="
}

# =============================================================================
# Main
# =============================================================================
case "${1:-}" in
    --setup|-s)
        setup_agent
        ;;
    --start)
        start_agent
        ;;
    --stop)
        stop_agent
        ;;
    --status)
        status_agent
        ;;
    --restart)
        stop_agent
        sleep 2
        start_agent
        ;;
    *)
        echo "Usage: $0 {--setup|--start|--stop|--restart|--status}"
        echo ""
        echo "  --setup    Download agent.jar, create node in Jenkins, create systemd service"
        echo "  --start    Start the JNLP agent process"
        echo "  --stop     Stop the JNLP agent process"
        echo "  --restart  Restart the agent"
        echo "  --status   Check agent status"
        exit 1
        ;;
esac
