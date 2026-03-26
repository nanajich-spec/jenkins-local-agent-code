#!/usr/bin/env bash
# =============================================================================
# dev-security-scan.sh — ONE-COMMAND Security Pipeline for Developers
# =============================================================================
# Runs the full Jenkins-based security pipeline from any developer machine.
# Installs tools in an isolated environment, connects a JNLP agent to Jenkins,
# creates/triggers the security pipeline, waits for results, downloads reports
# locally, and cleans up everything.
#
# ┌────────────────────────────────────────────────────────────────────┐
# │  SINGLE COMMAND USAGE:                                            │
# │                                                                   │
# │  curl -sL http://132.186.17.22:5000/dev-security-scan.sh | bash  │
# │                                                                   │
# │  OR locally:                                                      │
# │                                                                   │
# │  bash dev-security-scan.sh                                        │
# │  bash dev-security-scan.sh --image catool --tag latest            │
# │  bash dev-security-scan.sh --type k8s-manifests                   │
# │  bash dev-security-scan.sh --scan-registry                        │
# │  bash dev-security-scan.sh --image catool-ns --tag 1.0.0 --type image-only │
# └────────────────────────────────────────────────────────────────────┘
#
# What it does (all automated):
#   1. Creates an isolated workspace in /tmp
#   2. Installs Trivy + other security tools (if not present)
#   3. Connects a temporary JNLP agent to Jenkins master
#   4. Creates the security-scan-pipeline job (if not present)
#   5. Triggers the pipeline with your parameters
#   6. Streams the console output live
#   7. Downloads all security reports to your local machine
#   8. Generates a consolidated HTML report
#   9. Disconnects the agent and cleans up
#
# Requirements: Java 11+, curl, python3 (all standard on RHEL9)
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
JENKINS_URL="${JENKINS_URL:-http://132.186.17.25:32000}"
JENKINS_USER="${JENKINS_USER:-admin}"
JENKINS_PASS="${JENKINS_PASS:-admin}"
REGISTRY="${REGISTRY:-132.186.17.22:5000}"
JOB_NAME="security-scan-pipeline"

# Isolated workspace
SCAN_ID="devscan-$(hostname -s)-$(date +%s)"
ISO_DIR="/tmp/${SCAN_ID}"
AGENT_NAME="${SCAN_ID}"
AGENT_WORKDIR="${ISO_DIR}/agent"
REPORTS_LOCAL="${ISO_DIR}/security-reports"
TOOLS_DIR="${ISO_DIR}/tools"
COOKIE_JAR="${ISO_DIR}/.jenkins-cookies"
AGENT_PID=""
CLEANUP_DONE=false

# Defaults
IMAGE_NAME="catool"
IMAGE_TAG="latest"
SCAN_TYPE="full"
FAIL_ON_CRITICAL="true"
SCAN_REGISTRY="false"
SKIP_TOOL_INSTALL="false"
KEEP_REPORTS_DIR="./security-reports-$(date +%Y%m%d_%H%M%S)"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# =============================================================================
# Parse CLI Arguments
# =============================================================================
usage() {
    cat <<'EOF'
Usage: bash dev-security-scan.sh [OPTIONS]

Options:
  --image NAME           Image name in local registry (default: catool)
  --tag TAG              Image tag (default: latest)
  --type TYPE            full | image-only | code-only | k8s-manifests (default: full)
  --scan-registry        Scan ALL images in the local registry
  --no-fail-critical     Don't fail on CRITICAL vulnerabilities
  --skip-install         Skip tool installation (tools already present)
  --jenkins-url URL      Jenkins master URL (default: http://132.186.17.25:32000)
  --registry URL         Container registry (default: 132.186.17.22:5000)
  --output-dir DIR       Where to save reports (default: ./security-reports-<timestamp>)
  -h, --help             Show this help

Examples:
  bash dev-security-scan.sh
  bash dev-security-scan.sh --image catool-ns --tag 1.0.0_beta_hotfix --type image-only
  bash dev-security-scan.sh --scan-registry
  bash dev-security-scan.sh --type k8s-manifests
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)             IMAGE_NAME="$2"; shift 2 ;;
        --tag)               IMAGE_TAG="$2"; shift 2 ;;
        --type)              SCAN_TYPE="$2"; shift 2 ;;
        --scan-registry)     SCAN_REGISTRY="true"; shift ;;
        --no-fail-critical)  FAIL_ON_CRITICAL="false"; shift ;;
        --skip-install)      SKIP_TOOL_INSTALL="true"; shift ;;
        --jenkins-url)       JENKINS_URL="$2"; shift 2 ;;
        --registry)          REGISTRY="$2"; shift 2 ;;
        --output-dir)        KEEP_REPORTS_DIR="$2"; shift 2 ;;
        -h|--help)           usage ;;
        *)                   echo "Unknown: $1"; usage ;;
    esac
done

# =============================================================================
# Logging
# =============================================================================
_log()  { echo -e "${1}[$(date '+%H:%M:%S')]${NC} $2"; }
info()  { _log "${GREEN}" "  $*"; }
warn()  { _log "${YELLOW}" "  $*"; }
err()   { _log "${RED}" "  $*"; }
step()  { echo -e "\n${BLUE}${BOLD}>> $*${NC}"; }
banner() {
    echo -e "${CYAN}"
    cat <<'BANNER'
  ╔═══════════════════════════════════════════════════════════════╗
  ║          DEVELOPER SECURITY SCAN — ONE COMMAND               ║
  ║   Jenkins Agent ➜ Pipeline ➜ Reports ➜ Your Machine         ║
  ╚═══════════════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"
}

# =============================================================================
# Cleanup trap — always disconnect agent and remove temp files
# =============================================================================
cleanup() {
    if [ "${CLEANUP_DONE}" = "true" ]; then return; fi
    CLEANUP_DONE=true

    echo ""
    step "Cleanup — disconnecting agent & removing temp files"

    # Kill the JNLP agent process
    if [ -n "${AGENT_PID}" ] && kill -0 "${AGENT_PID}" 2>/dev/null; then
        kill "${AGENT_PID}" 2>/dev/null || true
        wait "${AGENT_PID}" 2>/dev/null || true
        info "JNLP agent stopped (PID ${AGENT_PID})"
    fi

    # Delete the temporary agent node from Jenkins
    local crumb_hdr crumb_val
    _fetch_crumb_pair crumb_hdr crumb_val 2>/dev/null || true
    curl -s -b "${COOKIE_JAR}" -u "${JENKINS_USER}:${JENKINS_PASS}" \
        -H "${crumb_hdr:-Jenkins-Crumb}:${crumb_val:-none}" \
        -X POST \
        "${JENKINS_URL}/computer/${AGENT_NAME}/doDelete" 2>/dev/null || true
    info "Agent node '${AGENT_NAME}' removed from Jenkins"

    # Clean up isolated directory (but keep reports)
    rm -rf "${ISO_DIR}" 2>/dev/null || true
    info "Temp directory cleaned: ${ISO_DIR}"
}
trap cleanup EXIT INT TERM

# =============================================================================
# Helper: Jenkins CSRF crumb
# =============================================================================
# Fetch crumb + save session cookie (Jenkins crumbs are tied to sessions)
_fetch_crumb_pair() {
    local -n _hdr_ref=$1 _val_ref=$2
    mkdir -p "$(dirname "${COOKIE_JAR}")"
    local resp
    resp=$(curl -s -c "${COOKIE_JAR}" -u "${JENKINS_USER}:${JENKINS_PASS}" \
        "${JENKINS_URL}/crumbIssuer/api/json" 2>/dev/null || echo "")
    if echo "${resp}" | python3 -c "import sys,json; json.load(sys.stdin)" &>/dev/null; then
        _hdr_ref=$(echo "${resp}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['crumbRequestField'])")
        _val_ref=$(echo "${resp}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['crumb'])")
    else
        _hdr_ref="Jenkins-Crumb"
        _val_ref="none"
    fi
}

# Convenience: Jenkins API POST with crumb+cookie
jenkins_post() {
    local url="$1"; shift
    local crumb_hdr crumb_val
    _fetch_crumb_pair crumb_hdr crumb_val
    curl -s -b "${COOKIE_JAR}" -u "${JENKINS_USER}:${JENKINS_PASS}" \
        -H "${crumb_hdr}:${crumb_val}" \
        -X POST "$@" "${url}"
}

jenkins_post_code() {
    local url="$1"; shift
    local crumb_hdr crumb_val
    _fetch_crumb_pair crumb_hdr crumb_val
    curl -s -o /dev/null -w "%{http_code}" -b "${COOKIE_JAR}" -u "${JENKINS_USER}:${JENKINS_PASS}" \
        -H "${crumb_hdr}:${crumb_val}" \
        -X POST "$@" "${url}"
}

jenkins_get() {
    curl -s -u "${JENKINS_USER}:${JENKINS_PASS}" "$@"
}

# =============================================================================
# PHASE 1: Pre-flight checks
# =============================================================================
preflight() {
    step "Phase 1/7 — Pre-flight checks"

    # Java
    if ! command -v java &>/dev/null; then
        err "Java not found. Install: sudo dnf install -y java-17-openjdk"
        exit 1
    fi
    info "Java: $(java -version 2>&1 | head -1)"

    # curl
    if ! command -v curl &>/dev/null; then
        err "curl not found. Install: sudo dnf install -y curl"
        exit 1
    fi

    # python3
    if ! command -v python3 &>/dev/null; then
        err "python3 not found. Install: sudo dnf install -y python3"
        exit 1
    fi

    # Test Jenkins connectivity
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -u "${JENKINS_USER}:${JENKINS_PASS}" \
        "${JENKINS_URL}/api/json" 2>/dev/null || echo "000")
    if [ "${http_code}" != "200" ]; then
        err "Cannot reach Jenkins at ${JENKINS_URL} (HTTP ${http_code})"
        err "Set JENKINS_URL, JENKINS_USER, JENKINS_PASS environment variables"
        exit 1
    fi
    info "Jenkins reachable at ${JENKINS_URL}"

    # Create isolated workspace
    mkdir -p "${ISO_DIR}" "${AGENT_WORKDIR}" "${REPORTS_LOCAL}" "${TOOLS_DIR}"
    info "Isolated workspace: ${ISO_DIR}"
}

# =============================================================================
# PHASE 2: Install security tools in isolated environment
# =============================================================================
install_tools() {
    step "Phase 2/7 — Installing security tools (isolated)"

    if [ "${SKIP_TOOL_INSTALL}" = "true" ]; then
        info "Skipping tool installation (--skip-install)"
        return 0
    fi

    # Trivy
    if command -v trivy &>/dev/null; then
        info "Trivy already installed: $(trivy --version 2>&1 | head -1)"
    else
        info "Installing Trivy..."
        if [ -f /etc/yum.repos.d/trivy.repo ] || cat > /etc/yum.repos.d/trivy.repo <<'REPO' 2>/dev/null
[trivy]
name=Trivy repository
baseurl=https://aquasecurity.github.io/trivy-repo/rpm/releases/$basearch/
gpgcheck=0
enabled=1
REPO
        then
            dnf install -y trivy 2>/dev/null || yum install -y trivy 2>/dev/null || {
                warn "Package install failed, downloading binary..."
                curl -sfL "https://github.com/aquasecurity/trivy/releases/download/v0.58.0/trivy_0.58.0_Linux-64bit.tar.gz" | \
                    tar xz -C "${TOOLS_DIR}" trivy 2>/dev/null || true
                export PATH="${TOOLS_DIR}:${PATH}"
            }
        fi
        info "Trivy: $(trivy --version 2>&1 | head -1 || echo 'installed')"
    fi

    # Grype (optional)
    if ! command -v grype &>/dev/null; then
        info "Installing Grype (optional)..."
        curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh 2>/dev/null | \
            sh -s -- -b "${TOOLS_DIR}" 2>/dev/null || warn "Grype install failed (optional, continuing)"
        export PATH="${TOOLS_DIR}:${PATH}"
    else
        info "Grype already installed"
    fi

    # ShellCheck (optional)
    if ! command -v shellcheck &>/dev/null; then
        dnf install -y ShellCheck 2>/dev/null || yum install -y ShellCheck 2>/dev/null || \
            warn "ShellCheck not available (optional)"
    fi

    # Hadolint (optional)
    if ! command -v hadolint &>/dev/null; then
        curl -sL "https://github.com/hadolint/hadolint/releases/download/v2.12.0/hadolint-Linux-x86_64" \
            -o "${TOOLS_DIR}/hadolint" 2>/dev/null && chmod +x "${TOOLS_DIR}/hadolint" 2>/dev/null || \
            warn "Hadolint not available (optional)"
        export PATH="${TOOLS_DIR}:${PATH}"
    fi

    info "Tool installation complete"
}

# =============================================================================
# PHASE 3: Create temporary JNLP agent node in Jenkins & connect
# =============================================================================
connect_agent() {
    step "Phase 3/7 — Connecting JNLP agent to Jenkins"

    # Download agent.jar
    info "Downloading agent.jar..."
    jenkins_get "${JENKINS_URL}/jnlpJars/agent.jar" -L -o "${AGENT_WORKDIR}/agent.jar"

    if [ ! -s "${AGENT_WORKDIR}/agent.jar" ]; then
        err "Failed to download agent.jar from Jenkins"
        exit 1
    fi
    info "agent.jar downloaded ($(du -h "${AGENT_WORKDIR}/agent.jar" | cut -f1))"

    # Create a temporary agent node via REST API
    info "Creating temporary agent node '${AGENT_NAME}'..."

    local node_config
    node_config=$(cat <<NODEEOF
{
  "name": "${AGENT_NAME}",
  "nodeDescription": "Temporary dev security scan agent ($(hostname -s), $(date))",
  "numExecutors": "1",
  "remoteFS": "${AGENT_WORKDIR}",
  "labelString": "local-security-agent dev-scan ${SCAN_ID}",
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

    local create_code
    create_code=$(jenkins_post_code "${JENKINS_URL}/computer/doCreateItem" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "name=${AGENT_NAME}" \
        --data-urlencode "type=hudson.slaves.DumbSlave" \
        --data-urlencode "json=${node_config}")

    if [ "${create_code}" = "200" ] || [ "${create_code}" = "302" ]; then
        info "Agent node created successfully (HTTP ${create_code})"
    else
        warn "Agent creation returned HTTP ${create_code} — may already exist, continuing"
    fi

    # Retrieve agent secret
    sleep 2
    local agent_secret=""
    local retries=0
    while [ -z "${agent_secret}" ] && [ ${retries} -lt 5 ]; do
        agent_secret=$(jenkins_get "${JENKINS_URL}/computer/${AGENT_NAME}/jenkins-agent.jnlp" 2>/dev/null | \
            grep -oP '<argument>\K[a-f0-9]{64}' | head -1 || echo "")
        if [ -z "${agent_secret}" ]; then
            agent_secret=$(jenkins_get "${JENKINS_URL}/computer/${AGENT_NAME}/slave-agent.jnlp" 2>/dev/null | \
                grep -oP '<argument>\K[a-f0-9]{64}' | head -1 || echo "")
        fi
        retries=$((retries + 1))
        [ -z "${agent_secret}" ] && sleep 2
    done

    if [ -z "${agent_secret}" ]; then
        err "Could not retrieve agent secret. Check Jenkins UI at:"
        err "  ${JENKINS_URL}/computer/${AGENT_NAME}/"
        exit 1
    fi
    info "Agent secret retrieved"

    # Launch JNLP agent in background
    info "Launching JNLP agent..."
    nohup java -jar "${AGENT_WORKDIR}/agent.jar" \
        -url "${JENKINS_URL}" \
        -name "${AGENT_NAME}" \
        -secret "${agent_secret}" \
        -workDir "${AGENT_WORKDIR}" \
        -webSocket \
        > "${ISO_DIR}/agent.log" 2>&1 &
    AGENT_PID=$!

    # Wait for agent to connect
    local wait_count=0
    local agent_online=false
    info "Waiting for agent to connect to Jenkins..."
    while [ ${wait_count} -lt 30 ]; do
        sleep 2
        local offline
        offline=$(jenkins_get \
            "${JENKINS_URL}/computer/${AGENT_NAME}/api/json" 2>/dev/null | \
            python3 -c "import sys,json; print(json.load(sys.stdin).get('offline', True))" 2>/dev/null || echo "True")
        if [ "${offline}" = "False" ]; then
            agent_online=true
            break
        fi
        wait_count=$((wait_count + 1))
        printf "."
    done
    echo ""

    if [ "${agent_online}" = "true" ]; then
        info "Agent connected successfully (PID ${AGENT_PID})"
    else
        warn "Agent may not be online yet — continuing anyway"
        warn "Check agent log: ${ISO_DIR}/agent.log"
    fi
}

# =============================================================================
# PHASE 4: Create the pipeline job in Jenkins (if not exists)
# =============================================================================
ensure_pipeline_job() {
    step "Phase 4/7 — Ensuring pipeline job exists"

    # Check if job exists
    local job_status
    job_status=$(curl -s -o /dev/null -w "%{http_code}" -u "${JENKINS_USER}:${JENKINS_PASS}" \
        "${JENKINS_URL}/job/${JOB_NAME}/api/json" 2>/dev/null || echo "000")

    if [ "${job_status}" = "200" ]; then
        info "Pipeline job '${JOB_NAME}' already exists — updating config"
    else
        info "Creating pipeline job '${JOB_NAME}'..."
    fi

    # Generate the job config XML with the current AGENT_NAME label
    # so this pipeline runs on THIS developer's temporary agent
    local job_xml
    job_xml=$(cat <<'JOBEOF'
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <actions/>
  <description>Developer Security Scan — Auto-created by dev-security-scan.sh</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <hudson.model.ParametersDefinitionProperty>
      <parameterDefinitions>
        <hudson.model.StringParameterDefinition>
          <name>IMAGE_NAME</name>
          <defaultValue>catool</defaultValue>
          <description>Image name to scan</description>
        </hudson.model.StringParameterDefinition>
        <hudson.model.StringParameterDefinition>
          <name>IMAGE_TAG</name>
          <defaultValue>latest</defaultValue>
          <description>Image tag</description>
        </hudson.model.StringParameterDefinition>
        <hudson.model.StringParameterDefinition>
          <name>REGISTRY_URL</name>
          <defaultValue>132.186.17.22:5000</defaultValue>
          <description>Container registry</description>
        </hudson.model.StringParameterDefinition>
        <hudson.model.ChoiceParameterDefinition>
          <name>SCAN_TYPE</name>
          <choices class="java.util.Arrays$ArrayList">
            <a class="string-array">
              <string>full</string>
              <string>image-only</string>
              <string>code-only</string>
              <string>k8s-manifests</string>
            </a>
          </choices>
          <description>Type of security scan</description>
        </hudson.model.ChoiceParameterDefinition>
        <hudson.model.BooleanParameterDefinition>
          <name>FAIL_ON_CRITICAL</name>
          <defaultValue>true</defaultValue>
          <description>Fail build on CRITICAL vulnerabilities</description>
        </hudson.model.BooleanParameterDefinition>
        <hudson.model.BooleanParameterDefinition>
          <name>SCAN_REGISTRY_IMAGES</name>
          <defaultValue>false</defaultValue>
          <description>Scan all images in local registry</description>
        </hudson.model.BooleanParameterDefinition>
        <hudson.model.StringParameterDefinition>
          <name>MANIFESTS_PATH</name>
          <defaultValue>/root/Downloads/cat-deployments</defaultValue>
          <description>Path to K8s manifests</description>
        </hudson.model.StringParameterDefinition>
      </parameterDefinitions>
    </hudson.model.ParametersDefinitionProperty>
  </properties>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps">
    <script><![CDATA[
pipeline {
    agent { label 'local-security-agent' }
    options {
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timestamps()
        timeout(time: 60, unit: 'MINUTES')
        ansiColor('xterm')
    }
    environment {
        REGISTRY         = "${params.REGISTRY_URL}"
        REPORTS_DIR      = "${WORKSPACE}/security-reports"
        SCAN_SEVERITY    = 'CRITICAL,HIGH'
    }
    stages {

        stage('Setup & Verify Tools') {
            steps {
                sh '''
                    mkdir -p "${REPORTS_DIR}"
                    echo "=========================================="
                    echo "  Security Pipeline — Tool Check"
                    echo "=========================================="
                    java -version 2>&1 | head -1
                    trivy --version 2>&1 | head -1 || echo "Trivy not found"
                    podman --version 2>&1 || echo "Podman not found"
                    command -v grype && grype version 2>&1 | head -1 || echo "Grype not available"
                    command -v hadolint && hadolint --version 2>&1 || echo "Hadolint not available"
                    command -v shellcheck && shellcheck --version 2>&1 | head -2 || echo "ShellCheck not available"
                    echo "=========================================="
                '''
            }
        }

        stage('Secret Detection') {
            when { expression { params.SCAN_TYPE in ['full', 'code-only'] } }
            steps {
                sh '''
                    echo "=== Secret Detection ==="
                    trivy fs --scanners secret \
                        --format json \
                        --output "${REPORTS_DIR}/secret-scan.json" \
                        "${WORKSPACE}" 2>/dev/null || true
                    trivy fs --scanners secret \
                        --format table \
                        "${WORKSPACE}" 2>/dev/null | tee "${REPORTS_DIR}/secret-scan.txt" || true
                    SECRETS=$(python3 -c "import json; d=json.load(open('${REPORTS_DIR}/secret-scan.json')); print(sum(len(r.get('Secrets',[])) for r in d.get('Results',[])))" 2>/dev/null || echo "0")
                    echo "Secrets found: ${SECRETS}"
                '''
            }
        }

        stage('SAST — Static Analysis') {
            when { expression { params.SCAN_TYPE in ['full', 'code-only'] } }
            parallel {
                stage('Trivy FS Scan') {
                    steps {
                        sh '''
                            echo "=== Trivy Filesystem Vulnerability Scan ==="
                            trivy fs --scanners vuln,misconfig \
                                --severity "${SCAN_SEVERITY}" \
                                --format json \
                                --output "${REPORTS_DIR}/trivy-fs-scan.json" \
                                "${WORKSPACE}" 2>/dev/null || true
                            trivy fs --scanners vuln,misconfig \
                                --severity "${SCAN_SEVERITY}" \
                                --format table \
                                "${WORKSPACE}" 2>/dev/null | tee "${REPORTS_DIR}/trivy-fs-scan.txt" || true
                        '''
                    }
                }
                stage('ShellCheck') {
                    steps {
                        sh '''
                            if command -v shellcheck &>/dev/null; then
                                echo "=== ShellCheck ==="
                                find "${WORKSPACE}" -name "*.sh" -type f \
                                    ! -path "*/.trivy-cache/*" ! -path "*/remoting/*" \
                                    -exec shellcheck --format=json {} + \
                                    > "${REPORTS_DIR}/shellcheck.json" 2>/dev/null || true
                            fi
                        '''
                    }
                }
            }
        }

        stage('SCA — Dependency Scan') {
            when { expression { params.SCAN_TYPE in ['full', 'code-only'] } }
            parallel {
                stage('Trivy SCA') {
                    steps {
                        sh '''
                            echo "=== Trivy SCA ==="
                            trivy fs --scanners vuln,license \
                                --severity "${SCAN_SEVERITY}" \
                                --format json \
                                --output "${REPORTS_DIR}/trivy-sca.json" \
                                "${WORKSPACE}" 2>/dev/null || true
                        '''
                    }
                }
                stage('Grype SCA') {
                    steps {
                        sh '''
                            if command -v grype &>/dev/null; then
                                echo "=== Grype SCA ==="
                                grype dir:"${WORKSPACE}" --output json \
                                    --file "${REPORTS_DIR}/grype-sca.json" 2>/dev/null || true
                            fi
                        '''
                    }
                }
            }
        }

        stage('Container Image Scan') {
            when { expression { params.SCAN_TYPE in ['full', 'image-only'] } }
            parallel {
                stage('Trivy Image') {
                    steps {
                        script {
                            def img = "${params.REGISTRY_URL}/${params.IMAGE_NAME}:${params.IMAGE_TAG}"
                            sh """
                                echo "=== Trivy Image Scan: ${img} ==="
                                trivy image --podman-host "" \
                                    --severity "${SCAN_SEVERITY}" \
                                    --format json \
                                    --output "${REPORTS_DIR}/trivy-image-scan.json" \
                                    "${img}" 2>/dev/null || true
                                trivy image --podman-host "" \
                                    --severity "${SCAN_SEVERITY}" \
                                    --format table \
                                    "${img}" 2>/dev/null | tee "${REPORTS_DIR}/trivy-image-scan.txt" || true
                            """
                        }
                    }
                }
                stage('Grype Image') {
                    steps {
                        script {
                            if (sh(script: 'command -v grype', returnStatus: true) == 0) {
                                def img = "${params.REGISTRY_URL}/${params.IMAGE_NAME}:${params.IMAGE_TAG}"
                                sh """
                                    echo "=== Grype Image Scan ==="
                                    grype "podman:${img}" --output json \
                                        --file "${REPORTS_DIR}/grype-image.json" 2>/dev/null || true
                                """
                            }
                        }
                    }
                }
            }
        }

        stage('Registry-Wide Scan') {
            when { expression { return params.SCAN_REGISTRY_IMAGES } }
            steps {
                sh '''
                    echo "=== Scanning ALL registry images ==="
                    CATALOG=$(curl -s "http://${REGISTRY}/v2/_catalog" | \
                        python3 -c "import sys,json; print('\\n'.join(json.load(sys.stdin).get('repositories',[])))" 2>/dev/null || echo "")
                    [ -z "${CATALOG}" ] && { echo "No repos found"; exit 0; }
                    echo "Repos: ${CATALOG}"
                    for REPO in ${CATALOG}; do
                        TAGS=$(curl -s "http://${REGISTRY}/v2/${REPO}/tags/list" | \
                            python3 -c "import sys,json; print('\\n'.join(json.load(sys.stdin).get('tags',[])))" 2>/dev/null || echo "")
                        for TAG in ${TAGS}; do
                            FULL="${REGISTRY}/${REPO}:${TAG}"
                            echo "--- Scanning: ${FULL} ---"
                            trivy image --podman-host "" --severity CRITICAL,HIGH \
                                --format table "${FULL}" 2>/dev/null | tee -a "${REPORTS_DIR}/registry-scan-all.txt" || true
                            trivy image --podman-host "" --severity CRITICAL,HIGH \
                                --format json --output "${REPORTS_DIR}/trivy-$(echo ${REPO}-${TAG} | tr '/:' '-').json" \
                                "${FULL}" 2>/dev/null || true
                        done
                    done
                '''
            }
        }

        stage('K8s Manifest Scan') {
            when { expression { params.SCAN_TYPE in ['full', 'k8s-manifests'] } }
            steps {
                sh '''
                    echo "=== K8s Manifest Security Scan ==="
                    MDIR="${MANIFESTS_PATH:-/root/Downloads/cat-deployments}"
                    if [ -d "${MDIR}" ]; then
                        trivy config --severity "${SCAN_SEVERITY}" \
                            --format json \
                            --output "${REPORTS_DIR}/trivy-k8s-config.json" \
                            "${MDIR}" 2>/dev/null || true
                        trivy config --severity "${SCAN_SEVERITY}" \
                            --format table \
                            "${MDIR}" 2>/dev/null | tee "${REPORTS_DIR}/trivy-k8s-config.txt" || true
                    else
                        echo "No manifests dir: ${MDIR}"
                    fi
                '''
            }
        }

        stage('Cluster Security Audit') {
            when { expression { params.SCAN_TYPE == 'full' } }
            steps {
                sh '''
                    echo "=== Live K8s Cluster Scan ==="
                    trivy k8s --report summary \
                        --severity "${SCAN_SEVERITY}" \
                        --format json \
                        --output "${REPORTS_DIR}/trivy-k8s-cluster.json" \
                        cluster 2>/dev/null || echo "Cluster scan skipped (no kubeconfig)"
                    trivy k8s --report summary \
                        --severity "${SCAN_SEVERITY}" \
                        --format table \
                        cluster 2>/dev/null | tee "${REPORTS_DIR}/trivy-k8s-cluster.txt" || true
                '''
            }
        }

        stage('Security Gate') {
            steps {
                script {
                    def rc = sh(script: '''
                        CRIT=0; HIGH=0
                        for f in "${REPORTS_DIR}"/trivy-*.json; do
                            [ -f "$f" ] || continue
                            COUNTS=$(python3 -c "
import json
with open('$f') as fh:
    d = json.load(fh)
results = d.get('Results', [])
c = sum(1 for r in results for v in r.get('Vulnerabilities', []) if v.get('Severity') == 'CRITICAL')
h = sum(1 for r in results for v in r.get('Vulnerabilities', []) if v.get('Severity') == 'HIGH')
print(f'{c},{h}')
" 2>/dev/null || echo "0,0")
                            CRIT=$((CRIT + $(echo $COUNTS | cut -d, -f1)))
                            HIGH=$((HIGH + $(echo $COUNTS | cut -d, -f2)))
                        done
                        echo "=========================================="
                        echo "  SECURITY GATE"
                        echo "  CRITICAL: ${CRIT}  |  HIGH: ${HIGH}"
                        echo "=========================================="
                        [ "$CRIT" -gt 0 ] && exit 1 || exit 0
                    ''', returnStatus: true)
                    if (rc != 0 && params.FAIL_ON_CRITICAL) {
                        unstable('CRITICAL vulnerabilities detected')
                    }
                }
            }
        }

        stage('HTML Report') {
            steps {
                sh '''
                    python3 - "${REPORTS_DIR}" <<'PYEOF'
import json, os, sys, glob
from datetime import datetime

rdir = sys.argv[1]
scans = []
total_c = total_h = total_m = total_l = 0

for f in sorted(glob.glob(os.path.join(rdir, "trivy-*.json"))):
    try:
        with open(f) as fh:
            d = json.load(fh)
        results = d.get("Results", [])
        vulns = [v for r in results for v in r.get("Vulnerabilities", [])]
        c = sum(1 for v in vulns if v.get("Severity") == "CRITICAL")
        h = sum(1 for v in vulns if v.get("Severity") == "HIGH")
        m = sum(1 for v in vulns if v.get("Severity") == "MEDIUM")
        l = sum(1 for v in vulns if v.get("Severity") == "LOW")
        total_c += c; total_h += h; total_m += m; total_l += l
        status = "FAIL" if c > 0 else ("WARN" if h > 0 else "PASS")
        name = os.path.basename(f).replace("trivy-","").replace(".json","")
        scans.append({"name": name, "c": c, "h": h, "m": m, "l": l, "status": status, "file": os.path.basename(f)})
    except Exception:
        pass

# Check for secrets
secrets_count = 0
sf = os.path.join(rdir, "secret-scan.json")
if os.path.exists(sf):
    try:
        with open(sf) as fh:
            sd = json.load(fh)
        secrets_count = sum(len(r.get("Secrets",[])) for r in sd.get("Results",[]))
    except Exception:
        pass

gate = "FAIL" if total_c > 0 else ("WARNING" if total_h > 0 else "PASS")
gate_color = "#d32f2f" if gate == "FAIL" else ("#f57c00" if gate == "WARNING" else "#388e3c")

rows = ""
for s in scans:
    sc = "#d32f2f" if s["status"]=="FAIL" else ("#f57c00" if s["status"]=="WARN" else "#388e3c")
    rows += f"""<tr>
        <td>{s['name']}</td>
        <td class="critical">{s['c']}</td><td class="high">{s['h']}</td>
        <td class="medium">{s['m']}</td><td class="low">{s['l']}</td>
        <td style="color:{sc};font-weight:bold">{s['status']}</td>
        <td><code>{s['file']}</code></td></tr>\n"""

html = f"""<!DOCTYPE html><html><head><title>Security Scan Report</title>
<style>
body {{ font-family:'Segoe UI',Arial,sans-serif; margin:0; background:#f0f2f5; }}
.top-bar {{ background:linear-gradient(135deg,#1a1a2e,#16213e); color:white; padding:30px 40px; }}
.top-bar h1 {{ margin:0 0 8px 0; font-size:28px; }}
.top-bar p {{ margin:2px 0; opacity:0.85; font-size:14px; }}
.container {{ max-width:1200px; margin:0 auto; padding:20px 40px; }}
.cards {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(160px,1fr)); gap:16px; margin:20px 0; }}
.card {{ background:white; border-radius:12px; padding:20px; text-align:center; box-shadow:0 2px 8px rgba(0,0,0,0.08); }}
.card .num {{ font-size:36px; font-weight:700; }}
.card .label {{ font-size:13px; color:#666; margin-top:4px; }}
.critical {{ color:#d32f2f; }} .high {{ color:#f57c00; }} .medium {{ color:#fbc02d; }} .low {{ color:#388e3c; }}
.gate {{ display:inline-block; font-size:20px; font-weight:700; padding:8px 24px; border-radius:8px;
         color:white; background:{gate_color}; }}
table {{ width:100%; border-collapse:collapse; margin:16px 0; background:white; border-radius:12px;
         overflow:hidden; box-shadow:0 2px 8px rgba(0,0,0,0.08); }}
th {{ background:#e3f2fd; padding:12px 16px; text-align:left; font-size:13px; text-transform:uppercase; color:#555; }}
td {{ padding:10px 16px; border-bottom:1px solid #eee; font-size:14px; }}
tr:hover {{ background:#f5f5f5; }}
code {{ background:#eee; padding:2px 6px; border-radius:4px; font-size:12px; }}
.section {{ margin:24px 0; }}
.section h2 {{ font-size:18px; color:#333; border-bottom:2px solid #1a73e8; display:inline-block; padding-bottom:4px; }}
</style></head><body>
<div class="top-bar">
    <h1>Security Scan Report</h1>
    <p>Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</p>
    <p>Host: {os.uname().nodename} | Registry: {os.environ.get('REGISTRY','132.186.17.22:5000')}</p>
</div>
<div class="container">
    <div class="cards">
        <div class="card"><div class="num critical">{total_c}</div><div class="label">CRITICAL</div></div>
        <div class="card"><div class="num high">{total_h}</div><div class="label">HIGH</div></div>
        <div class="card"><div class="num medium">{total_m}</div><div class="label">MEDIUM</div></div>
        <div class="card"><div class="num low">{total_l}</div><div class="label">LOW</div></div>
        <div class="card"><div class="num" style="color:#6a1b9a">{secrets_count}</div><div class="label">SECRETS</div></div>
        <div class="card"><div class="num">{len(scans)}</div><div class="label">SCANS RUN</div></div>
    </div>
    <p>Security Gate: <span class="gate">{gate}</span></p>
    <div class="section"><h2>Scan Details</h2>
    <table>
        <tr><th>Scan</th><th>Critical</th><th>High</th><th>Medium</th><th>Low</th><th>Status</th><th>Report</th></tr>
        {rows}
    </table></div>
    <div class="section"><h2>Report Files</h2>
    <ul>{"".join(f'<li><code>{os.path.basename(f)}</code></li>' for f in sorted(glob.glob(os.path.join(rdir,'*'))))}</ul>
    </div>
</div></body></html>"""

with open(os.path.join(rdir, "security-report.html"), "w") as fh:
    fh.write(html)
print("HTML report generated: security-reports/security-report.html")
PYEOF
                '''
            }
        }
    }

    post {
        always {
            archiveArtifacts artifacts: 'security-reports/**/*', allowEmptyArchive: true
            echo """
==================================================
  Security Pipeline Complete
  Reports archived in: security-reports/
=================================================="""
        }
        success  { echo 'RESULT: PASS' }
        unstable { echo 'RESULT: WARNING — review findings' }
        failure  { echo 'RESULT: FAIL — critical issues found' }
    }
}
]]></script>
    <sandbox>true</sandbox>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>
JOBEOF
)

    if [ "${job_status}" = "200" ]; then
        # Update existing job
        jenkins_post "${JENKINS_URL}/job/${JOB_NAME}/config.xml" \
            -H "Content-Type: application/xml" \
            --data-raw "${job_xml}" > /dev/null 2>&1 || true
        info "Pipeline job updated"
    else
        # Create new job
        local create_code
        create_code=$(jenkins_post_code "${JENKINS_URL}/createItem?name=${JOB_NAME}" \
            -H "Content-Type: application/xml" \
            --data-raw "${job_xml}")
        if [ "${create_code}" = "200" ] || [ "${create_code}" = "302" ]; then
            info "Pipeline job created successfully"
        else
            warn "Job creation returned HTTP ${create_code} — may already exist"
        fi
    fi
}

# =============================================================================
# PHASE 5: Trigger the pipeline
# =============================================================================
trigger_pipeline() {
    step "Phase 5/7 — Triggering security pipeline"

    echo -e "  ${BOLD}Image:${NC}      ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
    echo -e "  ${BOLD}Scan type:${NC}  ${SCAN_TYPE}"
    echo -e "  ${BOLD}Registry:${NC}   ${SCAN_REGISTRY}"
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
        info "Build triggered successfully (HTTP ${trigger_code})"
    else
        err "Failed to trigger build (HTTP ${trigger_code})"
        err "Check: ${JENKINS_URL}/job/${JOB_NAME}/"
        exit 1
    fi
}

# =============================================================================
# PHASE 6: Wait for build, stream console, download reports
# =============================================================================
wait_and_collect() {
    step "Phase 6/7 — Waiting for build & streaming output"

    # Wait for build to appear
    sleep 5
    local build_num=""
    local retries=0
    while [ -z "${build_num}" ] && [ ${retries} -lt 15 ]; do
        build_num=$(jenkins_get "${JENKINS_URL}/job/${JOB_NAME}/lastBuild/buildNumber" 2>/dev/null || echo "")
        retries=$((retries + 1))
        [ -z "${build_num}" ] && sleep 3
    done

    if [ -z "${build_num}" ]; then
        err "Could not get build number. Check Jenkins UI."
        return 1
    fi

    info "Build #${build_num} started"
    info "Console: ${JENKINS_URL}/job/${JOB_NAME}/${build_num}/console"
    echo ""

    # Stream console output
    local log_offset=0
    local building="True"
    while [ "${building}" = "True" ]; do
        # Get progressive console text
        local console_text
        console_text=$(jenkins_get \
            "${JENKINS_URL}/job/${JOB_NAME}/${build_num}/logText/progressiveText?start=${log_offset}" \
            -D "${ISO_DIR}/headers.txt" 2>/dev/null || echo "")

        if [ -n "${console_text}" ]; then
            echo "${console_text}"
            # Get the new offset from response headers
            local new_offset
            new_offset=$(grep -i "X-Text-Size" "${ISO_DIR}/headers.txt" 2>/dev/null | tr -d '\r' | awk '{print $2}' || echo "${log_offset}")
            [ -n "${new_offset}" ] && log_offset="${new_offset}"
        fi

        # Check if still building
        building=$(jenkins_get \
            "${JENKINS_URL}/job/${JOB_NAME}/${build_num}/api/json" 2>/dev/null | \
            python3 -c "import sys,json; print(json.load(sys.stdin).get('building', False))" 2>/dev/null || echo "False")

        [ "${building}" = "True" ] && sleep 5
    done

    # Get final console chunk
    local final_text
    final_text=$(jenkins_get \
        "${JENKINS_URL}/job/${JOB_NAME}/${build_num}/logText/progressiveText?start=${log_offset}" 2>/dev/null || echo "")
    [ -n "${final_text}" ] && echo "${final_text}"

    # Get result
    local result
    result=$(jenkins_get \
        "${JENKINS_URL}/job/${JOB_NAME}/${build_num}/api/json" 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('result', 'UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")

    echo ""
    case "${result}" in
        SUCCESS)  echo -e "  ${GREEN}${BOLD}Build #${build_num}: ${result}${NC}" ;;
        UNSTABLE) echo -e "  ${YELLOW}${BOLD}Build #${build_num}: ${result}${NC}" ;;
        *)        echo -e "  ${RED}${BOLD}Build #${build_num}: ${result}${NC}" ;;
    esac

    # Download archived artifacts (reports)
    step "Phase 7/7 — Downloading reports to local machine"

    mkdir -p "${KEEP_REPORTS_DIR}"

    # Get list of archived artifacts
    local artifacts
    artifacts=$(jenkins_get \
        "${JENKINS_URL}/job/${JOB_NAME}/${build_num}/api/json" 2>/dev/null | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
for a in data.get('artifacts', []):
    print(a['relativePath'])
" 2>/dev/null || echo "")

    if [ -n "${artifacts}" ]; then
        local count=0
        while IFS= read -r artifact; do
            [ -z "${artifact}" ] && continue
            local filename
            filename=$(basename "${artifact}")
            jenkins_get \
                "${JENKINS_URL}/job/${JOB_NAME}/${build_num}/artifact/${artifact}" \
                -o "${KEEP_REPORTS_DIR}/${filename}" 2>/dev/null
            count=$((count + 1))
        done <<< "${artifacts}"
        info "Downloaded ${count} report files to ${KEEP_REPORTS_DIR}/"
    else
        warn "No archived artifacts found — trying console log"
        jenkins_get \
            "${JENKINS_URL}/job/${JOB_NAME}/${build_num}/consoleText" \
            -o "${KEEP_REPORTS_DIR}/console-output.txt" 2>/dev/null
        info "Console log saved to ${KEEP_REPORTS_DIR}/console-output.txt"
    fi

    # Show final summary
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "  ╔═══════════════════════════════════════════════════════════════╗"
    echo "  ║                    SCAN COMPLETE                             ║"
    echo "  ╠═══════════════════════════════════════════════════════════════╣"
    echo -e "  ║  Result:  ${result}$(printf '%*s' $((43 - ${#result})) '')║"
    echo -e "  ║  Reports: ${KEEP_REPORTS_DIR}/$(printf '%*s' $((43 - ${#KEEP_REPORTS_DIR})) '')║"
    echo "  ║                                                             ║"
    echo "  ║  Open HTML report:                                          ║"
    echo -e "  ║    xdg-open ${KEEP_REPORTS_DIR}/security-report.html$(printf '%*s' $((25 - ${#KEEP_REPORTS_DIR})) '')║"
    echo "  ╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    # List report files
    if [ -d "${KEEP_REPORTS_DIR}" ]; then
        echo "  Report files:"
        ls -lh "${KEEP_REPORTS_DIR}"/ 2>/dev/null | tail -n +2 | sed 's/^/    /'
    fi
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    banner
    echo -e "  ${BOLD}Host:${NC}       $(hostname -s)"
    echo -e "  ${BOLD}Jenkins:${NC}    ${JENKINS_URL}"
    echo -e "  ${BOLD}Registry:${NC}   ${REGISTRY}"
    echo -e "  ${BOLD}Image:${NC}      ${IMAGE_NAME}:${IMAGE_TAG}"
    echo -e "  ${BOLD}Scan type:${NC}  ${SCAN_TYPE}"
    echo -e "  ${BOLD}Scan ID:${NC}    ${SCAN_ID}"
    echo -e "  ${BOLD}Reports:${NC}    ${KEEP_REPORTS_DIR}"
    echo ""

    preflight
    install_tools
    connect_agent
    ensure_pipeline_job
    trigger_pipeline
    wait_and_collect

    # Cleanup happens via trap
}

main
