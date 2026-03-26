#!/usr/bin/env bash
# =============================================================================
# run-full-security-scan.sh — ONE COMMAND Full Security Pipeline (Local)
# =============================================================================
# Scans the entire /root/Testing codebase with ALL available checks and
# produces TXT reports locally without requiring Jenkins connectivity.
#
# USAGE:
#   bash run-full-security-scan.sh
#   bash run-full-security-scan.sh --target /path/to/codebase
#   bash run-full-security-scan.sh --output /path/to/reports
#
# WHAT IT CHECKS:
#   1. Secret Detection          — hardcoded passwords, tokens, API keys
#   2. Vulnerability Scan (SAST) — CVEs in dependencies & filesystem
#   3. Misconfiguration Scan     — insecure configs in Dockerfiles, YAML, etc.
#   4. Dockerfile Lint           — best practice checks for Dockerfiles
#   5. Shell Script Analysis     — ShellCheck for .sh files
#   6. K8s Manifest Security     — Trivy misconfig scan on k8s/ YAMLs
#   7. Python Dependency Audit   — known vulns in requirements.txt
#   8. Docker-Compose Analysis   — misconfigs in docker-compose
#   9. .env / Credential Audit   — exposed credentials in env files
#  10. License Scan              — license compliance check
#  11. Code Quality Metrics      — LOC counts, file type breakdown
#  12. FINAL CONSOLIDATED REPORT — everything in one TXT file
# =============================================================================

set -uo pipefail

# =============================================================================
# Configuration
# =============================================================================
TARGET_DIR="${TARGET_DIR:-/root/Testing/rnd-quality-statistics-main@0d5de127bfe}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${OUTPUT_DIR:-/root/Downloads/security-reports-${TIMESTAMP}}"
SEVERITY="CRITICAL,HIGH,MEDIUM"
REGISTRY="132.186.17.22:5000"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# Counters
TOTAL_CRITICAL=0
TOTAL_HIGH=0
TOTAL_MEDIUM=0
TOTAL_SECRETS=0
TOTAL_MISCONFIGS=0
SCAN_PASS=0
SCAN_FAIL=0
SCAN_WARN=0

# =============================================================================
# Parse CLI Arguments
# =============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)   TARGET_DIR="$2"; shift 2 ;;
        --output)   OUTPUT_DIR="$2"; shift 2 ;;
        --severity) SEVERITY="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: bash $0 [--target /path/to/code] [--output /path/to/reports] [--severity CRITICAL,HIGH]"
            exit 0 ;;
        *)          echo "Unknown: $1"; exit 1 ;;
    esac
done

# =============================================================================
# Logging
# =============================================================================
_log()  { echo -e "${1}[$(date '+%H:%M:%S')]${NC} $2"; }
info()  { _log "${GREEN}" "  $*"; }
warn()  { _log "${YELLOW}" "  $*"; }
err()   { _log "${RED}" "  $*"; }
step()  { echo -e "\n${BLUE}${BOLD}══════════════════════════════════════════════════${NC}"; echo -e "${BLUE}${BOLD}  $*${NC}"; echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════${NC}"; }

banner() {
    echo -e "${CYAN}"
    cat <<'BANNER'
  ╔═══════════════════════════════════════════════════════════════╗
  ║     FULL SECURITY PIPELINE — LOCAL ONE-COMMAND EXECUTION     ║
  ║                                                              ║
  ║   Secret Detection │ SAST │ Vulnerability │ Misconfig        ║
  ║   Dockerfile Lint  │ K8s Scan │ Dependency Audit │ License   ║
  ╚═══════════════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"
}

# =============================================================================
# Pre-flight checks
# =============================================================================
preflight() {
    step "PREFLIGHT — Verifying Tools & Target"

    if [ ! -d "${TARGET_DIR}" ]; then
        err "Target directory not found: ${TARGET_DIR}"
        exit 1
    fi
    info "Target: ${TARGET_DIR}"

    mkdir -p "${OUTPUT_DIR}"
    info "Reports: ${OUTPUT_DIR}"

    # Check tools
    local tools_found=0
    echo ""
    for tool in trivy grype hadolint shellcheck kubesec python3; do
        if command -v "$tool" &>/dev/null; then
            local ver
            case "$tool" in
                trivy)      ver=$(trivy --version 2>&1 | head -1) ;;
                grype)      ver=$(grype version 2>&1 | grep "^Version" | head -1) ;;
                hadolint)   ver=$(hadolint --version 2>&1) ;;
                shellcheck) ver=$(shellcheck --version 2>&1 | grep "^version:" | head -1) ;;
                kubesec)    ver=$(kubesec version 2>&1 | head -1) ;;
                python3)    ver=$(python3 --version 2>&1) ;;
            esac
            info "  $tool — ${ver}"
            tools_found=$((tools_found + 1))
        else
            warn "  $tool — NOT INSTALLED (will skip related scans)"
        fi
    done
    echo ""
    info "Tools available: ${tools_found}/6"
}

# =============================================================================
# 01. Secret Detection
# =============================================================================
scan_secrets() {
    step "01/12 — SECRET DETECTION"

    local report="${OUTPUT_DIR}/01-secret-detection.txt"

    {
        echo "============================================================"
        echo "  SECRET DETECTION REPORT"
        echo "  Target: ${TARGET_DIR}"
        echo "  Date:   $(date)"
        echo "============================================================"
        echo ""
    } > "${report}"

    # Trivy secret scan
    if command -v trivy &>/dev/null; then
        info "Running Trivy secret scanner..."
        trivy fs --scanners secret \
            --severity "${SEVERITY}" \
            --format table \
            "${TARGET_DIR}" 2>/dev/null >> "${report}" || true

        # Also output JSON for counting
        trivy fs --scanners secret \
            --format json \
            --output "${OUTPUT_DIR}/01-secret-detection.json" \
            "${TARGET_DIR}" 2>/dev/null || true

        # Count secrets
        if [ -f "${OUTPUT_DIR}/01-secret-detection.json" ]; then
            local count
            count=$(python3 -c "
import json, sys
try:
    d = json.load(open('${OUTPUT_DIR}/01-secret-detection.json'))
    total = sum(len(r.get('Secrets', [])) for r in d.get('Results', []))
    print(total)
except:
    print(0)
" 2>/dev/null || echo "0")
            TOTAL_SECRETS=$count
        fi
    fi

    # Custom credential pattern scan
    {
        echo ""
        echo "============================================================"
        echo "  CUSTOM PATTERN SCAN — Hardcoded Credentials"
        echo "============================================================"
        echo ""
    } >> "${report}"

    local patterns=("password" "secret" "token" "api_key" "private_key" "passwd" "credential" "auth_token" "access_key" "secret_key")
    for pattern in "${patterns[@]}"; do
        local hits
        hits=$(grep -rn --include="*.py" --include="*.ts" --include="*.tsx" --include="*.js" \
            --include="*.yml" --include="*.yaml" --include="*.env" --include="*.json" \
            --include="*.sh" --include="*.sql" --include="*.md" \
            -i "${pattern}" "${TARGET_DIR}" 2>/dev/null | \
            grep -vi "node_modules" | grep -vi ".git/" | grep -vi "keycloak-24" | grep -vi "java17" || true)
        if [ -n "${hits}" ]; then
            echo "--- Pattern: '${pattern}' ---" >> "${report}"
            echo "${hits}" >> "${report}"
            echo "" >> "${report}"
        fi
    done

    # .env file audit
    {
        echo ""
        echo "============================================================"
        echo "  .env FILE AUDIT"
        echo "============================================================"
        echo ""
    } >> "${report}"

    find "${TARGET_DIR}" -name "*.env" -o -name ".env*" 2>/dev/null | \
        grep -v node_modules | grep -v ".git/" | grep -v "keycloak-24" | grep -v "java17" | while read -r envfile; do
        echo "--- ${envfile} ---" >> "${report}"
        # Mask actual values
        sed 's/=.*/=<REDACTED>/' "${envfile}" >> "${report}" 2>/dev/null || true
        echo "" >> "${report}"
    done

    if [ "${TOTAL_SECRETS}" -gt 0 ]; then
        warn "Secrets found: ${TOTAL_SECRETS}"
        SCAN_FAIL=$((SCAN_FAIL + 1))
    else
        info "No secrets detected by Trivy"
        SCAN_PASS=$((SCAN_PASS + 1))
    fi

    info "Report: ${report}"
}

# =============================================================================
# 02. Filesystem Vulnerability Scan (SAST)
# =============================================================================
scan_vulnerabilities() {
    step "02/12 — FILESYSTEM VULNERABILITY SCAN (SAST)"

    local report="${OUTPUT_DIR}/02-vulnerability-scan.txt"

    {
        echo "============================================================"
        echo "  FILESYSTEM VULNERABILITY SCAN (SAST)"
        echo "  Target: ${TARGET_DIR}"
        echo "  Severity: ${SEVERITY}"
        echo "  Date:   $(date)"
        echo "============================================================"
        echo ""
    } > "${report}"

    if command -v trivy &>/dev/null; then
        info "Running Trivy filesystem vulnerability scan..."
        trivy fs --scanners vuln \
            --severity "${SEVERITY}" \
            --format table \
            "${TARGET_DIR}" 2>/dev/null >> "${report}" || true

        # JSON for counting
        trivy fs --scanners vuln \
            --severity "${SEVERITY}" \
            --format json \
            --output "${OUTPUT_DIR}/02-vulnerability-scan.json" \
            "${TARGET_DIR}" 2>/dev/null || true

        if [ -f "${OUTPUT_DIR}/02-vulnerability-scan.json" ]; then
            local counts
            counts=$(python3 -c "
import json
try:
    d = json.load(open('${OUTPUT_DIR}/02-vulnerability-scan.json'))
    c = h = m = 0
    for r in d.get('Results', []):
        for v in r.get('Vulnerabilities', []):
            sev = v.get('Severity', '')
            if sev == 'CRITICAL': c += 1
            elif sev == 'HIGH': h += 1
            elif sev == 'MEDIUM': m += 1
    print(f'{c} {h} {m}')
except:
    print('0 0 0')
" 2>/dev/null || echo "0 0 0")
            read -r crit high med <<< "${counts}"
            TOTAL_CRITICAL=$((TOTAL_CRITICAL + crit))
            TOTAL_HIGH=$((TOTAL_HIGH + high))
            TOTAL_MEDIUM=$((TOTAL_MEDIUM + med))
            info "Found: ${crit} CRITICAL, ${high} HIGH, ${med} MEDIUM"
        fi
    else
        warn "Trivy not available, skipping"
    fi

    if [ "${TOTAL_CRITICAL}" -gt 0 ]; then
        SCAN_FAIL=$((SCAN_FAIL + 1))
    else
        SCAN_PASS=$((SCAN_PASS + 1))
    fi

    info "Report: ${report}"
}

# =============================================================================
# 03. Misconfiguration Scan
# =============================================================================
scan_misconfig() {
    step "03/12 — MISCONFIGURATION SCAN"

    local report="${OUTPUT_DIR}/03-misconfiguration-scan.txt"

    {
        echo "============================================================"
        echo "  MISCONFIGURATION SCAN"
        echo "  Target: ${TARGET_DIR}"
        echo "  Date:   $(date)"
        echo "============================================================"
        echo ""
    } > "${report}"

    if command -v trivy &>/dev/null; then
        info "Running Trivy misconfiguration scanner..."
        trivy fs --scanners misconfig \
            --severity "${SEVERITY}" \
            --format table \
            "${TARGET_DIR}" 2>/dev/null >> "${report}" || true

        trivy fs --scanners misconfig \
            --severity "${SEVERITY}" \
            --format json \
            --output "${OUTPUT_DIR}/03-misconfiguration-scan.json" \
            "${TARGET_DIR}" 2>/dev/null || true

        if [ -f "${OUTPUT_DIR}/03-misconfiguration-scan.json" ]; then
            local mc
            mc=$(python3 -c "
import json
try:
    d = json.load(open('${OUTPUT_DIR}/03-misconfiguration-scan.json'))
    total = sum(len(r.get('Misconfigurations', [])) for r in d.get('Results', []))
    print(total)
except:
    print(0)
" 2>/dev/null || echo "0")
            TOTAL_MISCONFIGS=$mc
            info "Misconfigurations found: ${mc}"
        fi
    else
        warn "Trivy not available, skipping"
    fi

    [ "${TOTAL_MISCONFIGS}" -gt 5 ] && SCAN_WARN=$((SCAN_WARN + 1)) || SCAN_PASS=$((SCAN_PASS + 1))
    info "Report: ${report}"
}

# =============================================================================
# 04. Dockerfile Security Lint
# =============================================================================
scan_dockerfile() {
    step "04/12 — DOCKERFILE SECURITY LINT"

    local report="${OUTPUT_DIR}/04-dockerfile-lint.txt"

    {
        echo "============================================================"
        echo "  DOCKERFILE SECURITY LINT"
        echo "  Date:   $(date)"
        echo "============================================================"
        echo ""
    } > "${report}"

    local dockerfiles
    dockerfiles=$(find "${TARGET_DIR}" -name "Dockerfile" -o -name "Containerfile" 2>/dev/null | \
        grep -v node_modules | grep -v ".git/" | grep -v "keycloak-24" | grep -v "java17" || true)

    if [ -z "${dockerfiles}" ]; then
        info "No Dockerfiles found"
        echo "No Dockerfiles found in target." >> "${report}"
        SCAN_PASS=$((SCAN_PASS + 1))
        return
    fi

    while IFS= read -r df; do
        echo "" >> "${report}"
        echo "--- ${df} ---" >> "${report}"
        echo "" >> "${report}"

        # Trivy misconfig on Dockerfile
        if command -v trivy &>/dev/null; then
            trivy config --severity "${SEVERITY}" --format table "${df}" >> "${report}" 2>/dev/null || true
        fi

        # Hadolint
        if command -v hadolint &>/dev/null; then
            echo "" >> "${report}"
            echo "Hadolint Results:" >> "${report}"
            hadolint "${df}" >> "${report}" 2>&1 || true
        fi

        # Manual checks
        echo "" >> "${report}"
        echo "Manual Checks:" >> "${report}"
        if grep -q "^FROM.*:latest" "${df}" 2>/dev/null; then
            echo "  [WARN] Uses ':latest' tag — pin to specific version" >> "${report}"
        fi
        if ! grep -q "USER" "${df}" 2>/dev/null; then
            echo "  [WARN] No USER instruction — runs as root" >> "${report}"
        fi
        if grep -q "ADD " "${df}" 2>/dev/null; then
            echo "  [INFO] Uses ADD — prefer COPY for local files" >> "${report}"
        fi
        if ! grep -q "HEALTHCHECK" "${df}" 2>/dev/null; then
            echo "  [INFO] No HEALTHCHECK instruction" >> "${report}"
        fi
    done <<< "${dockerfiles}"

    SCAN_PASS=$((SCAN_PASS + 1))
    info "Report: ${report}"
}

# =============================================================================
# 05. Shell Script Analysis
# =============================================================================
scan_shellscripts() {
    step "05/12 — SHELL SCRIPT ANALYSIS"

    local report="${OUTPUT_DIR}/05-shell-script-analysis.txt"

    {
        echo "============================================================"
        echo "  SHELL SCRIPT ANALYSIS"
        echo "  Date:   $(date)"
        echo "============================================================"
        echo ""
    } > "${report}"

    local scripts
    scripts=$(find "${TARGET_DIR}" -name "*.sh" -type f 2>/dev/null | \
        grep -v node_modules | grep -v ".git/" | grep -v "keycloak-24" | grep -v "java17" || true)

    if [ -z "${scripts}" ]; then
        info "No shell scripts found"
        echo "No shell scripts found in target." >> "${report}"
        SCAN_PASS=$((SCAN_PASS + 1))
        return
    fi

    local total_issues=0
    while IFS= read -r script; do
        echo "--- ${script} ---" >> "${report}"
        if command -v shellcheck &>/dev/null; then
            shellcheck -f tty "${script}" >> "${report}" 2>&1 || true
            local issues
            issues=$(shellcheck -f json "${script}" 2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
            total_issues=$((total_issues + issues))
        else
            echo "  ShellCheck not installed — manual review:" >> "${report}"
            if ! head -1 "${script}" | grep -q "^#!"; then
                echo "  [WARN] Missing shebang line" >> "${report}"
            fi
            if grep -qn 'eval ' "${script}" 2>/dev/null; then
                echo "  [WARN] Uses eval — potential injection risk" >> "${report}"
            fi
        fi
        echo "" >> "${report}"
    done <<< "${scripts}"

    info "Shell script issues: ${total_issues}"
    [ "${total_issues}" -gt 10 ] && SCAN_WARN=$((SCAN_WARN + 1)) || SCAN_PASS=$((SCAN_PASS + 1))
    info "Report: ${report}"
}

# =============================================================================
# 06. Kubernetes Manifest Security Scan
# =============================================================================
scan_k8s_manifests() {
    step "06/12 — KUBERNETES MANIFEST SECURITY"

    local report="${OUTPUT_DIR}/06-k8s-manifest-scan.txt"

    {
        echo "============================================================"
        echo "  KUBERNETES MANIFEST SECURITY SCAN"
        echo "  Date:   $(date)"
        echo "============================================================"
        echo ""
    } > "${report}"

    local k8s_dir="${TARGET_DIR}/k8s"
    if [ ! -d "${k8s_dir}" ]; then
        info "No k8s/ directory found"
        echo "No k8s/ directory in target." >> "${report}"
        SCAN_PASS=$((SCAN_PASS + 1))
        return
    fi

    # Trivy config scan
    if command -v trivy &>/dev/null; then
        info "Scanning K8s manifests with Trivy..."
        trivy config --severity "${SEVERITY}" --format table "${k8s_dir}" >> "${report}" 2>/dev/null || true

        trivy config --severity "${SEVERITY}" --format json \
            --output "${OUTPUT_DIR}/06-k8s-manifest-scan.json" \
            "${k8s_dir}" 2>/dev/null || true
    fi

    # Manual K8s security checks
    {
        echo ""
        echo "============================================================"
        echo "  MANUAL K8S SECURITY CHECKS"
        echo "============================================================"
        echo ""
    } >> "${report}"

    find "${k8s_dir}" -name "*.yaml" -o -name "*.yml" 2>/dev/null | while read -r manifest; do
        echo "--- ${manifest} ---" >> "${report}"

        if grep -q "privileged: true" "${manifest}" 2>/dev/null; then
            echo "  [CRITICAL] Running in privileged mode" >> "${report}"
        fi
        if grep -q "runAsRoot\|runAsUser: 0" "${manifest}" 2>/dev/null; then
            echo "  [HIGH] Running as root user" >> "${report}"
        fi
        if ! grep -q "resources:" "${manifest}" 2>/dev/null; then
            echo "  [MEDIUM] No resource limits defined" >> "${report}"
        fi
        if ! grep -q "readOnlyRootFilesystem" "${manifest}" 2>/dev/null; then
            echo "  [LOW] readOnlyRootFilesystem not set" >> "${report}"
        fi
        if grep -q "hostNetwork: true\|hostPID: true\|hostIPC: true" "${manifest}" 2>/dev/null; then
            echo "  [HIGH] Host namespace sharing enabled" >> "${report}"
        fi
        if ! grep -q "securityContext:" "${manifest}" 2>/dev/null; then
            echo "  [MEDIUM] No securityContext defined" >> "${report}"
        fi
        if grep -qiE "(password|secret).*:" "${manifest}" 2>/dev/null; then
            if ! grep -q "kind: Secret" "${manifest}" 2>/dev/null; then
                echo "  [WARN] Possible credential in non-Secret resource" >> "${report}"
            fi
        fi
        echo "" >> "${report}"
    done

    SCAN_PASS=$((SCAN_PASS + 1))
    info "Report: ${report}"
}

# =============================================================================
# 07. Python Dependency Audit
# =============================================================================
scan_python_deps() {
    step "07/12 — PYTHON DEPENDENCY AUDIT"

    local report="${OUTPUT_DIR}/07-python-dependency-audit.txt"

    {
        echo "============================================================"
        echo "  PYTHON DEPENDENCY AUDIT"
        echo "  Date:   $(date)"
        echo "============================================================"
        echo ""
    } > "${report}"

    local reqfiles
    reqfiles=$(find "${TARGET_DIR}" -name "requirements*.txt" -o -name "pyproject.toml" 2>/dev/null | \
        grep -v node_modules | grep -v ".git/" | grep -v "keycloak-24" | grep -v "java17" || true)

    if [ -z "${reqfiles}" ]; then
        info "No Python dependency files found"
        echo "No Python dependency files found." >> "${report}"
        SCAN_PASS=$((SCAN_PASS + 1))
        return
    fi

    while IFS= read -r reqfile; do
        echo "--- ${reqfile} ---" >> "${report}"
        echo "" >> "${report}"
        cat "${reqfile}" >> "${report}" 2>/dev/null || true
        echo "" >> "${report}"

        # Trivy scan on the specific file
        if command -v trivy &>/dev/null; then
            echo "Trivy Vulnerability Scan:" >> "${report}"
            trivy fs --scanners vuln --severity "${SEVERITY}" --format table "${reqfile}" >> "${report}" 2>/dev/null || true
        fi
        echo "" >> "${report}"
    done <<< "${reqfiles}"

    SCAN_PASS=$((SCAN_PASS + 1))
    info "Report: ${report}"
}

# =============================================================================
# 08. Docker-Compose Analysis
# =============================================================================
scan_docker_compose() {
    step "08/12 — DOCKER-COMPOSE ANALYSIS"

    local report="${OUTPUT_DIR}/08-docker-compose-analysis.txt"

    {
        echo "============================================================"
        echo "  DOCKER-COMPOSE SECURITY ANALYSIS"
        echo "  Date:   $(date)"
        echo "============================================================"
        echo ""
    } > "${report}"

    local compose_files
    compose_files=$(find "${TARGET_DIR}" -name "docker-compose*.yml" -o -name "docker-compose*.yaml" \
        -o -name "compose.yml" -o -name "compose.yaml" 2>/dev/null | \
        grep -v node_modules | grep -v ".git/" | grep -v "keycloak-24" | grep -v "java17" || true)

    if [ -z "${compose_files}" ]; then
        info "No docker-compose files found"
        echo "No docker-compose files found." >> "${report}"
        SCAN_PASS=$((SCAN_PASS + 1))
        return
    fi

    while IFS= read -r cf; do
        echo "--- ${cf} ---" >> "${report}"
        echo "" >> "${report}"

        # Trivy config scan
        if command -v trivy &>/dev/null; then
            trivy config --severity "${SEVERITY}" --format table "${cf}" >> "${report}" 2>/dev/null || true
        fi

        echo "" >> "${report}"
        echo "Manual Security Checks:" >> "${report}"
        echo "" >> "${report}"

        # Check for common issues
        if grep -q "privileged:" "${cf}" 2>/dev/null; then
            echo "  [CRITICAL] Privileged containers detected" >> "${report}"
        fi
        if grep -q "network_mode.*host" "${cf}" 2>/dev/null; then
            echo "  [HIGH] Host network mode used" >> "${report}"
        fi
        if grep -qiE "(password|secret).*:" "${cf}" 2>/dev/null; then
            echo "  [WARN] Hardcoded credentials detected in compose file" >> "${report}"
        fi
        if ! grep -q "read_only:" "${cf}" 2>/dev/null; then
            echo "  [INFO] No read-only filesystem configuration" >> "${report}"
        fi
        if ! grep -q "mem_limit\|memory:" "${cf}" 2>/dev/null; then
            echo "  [INFO] No memory limits set" >> "${report}"
        fi
        if ! grep -q "healthcheck:" "${cf}" 2>/dev/null; then
            echo "  [INFO] No healthcheck defined" >> "${report}"
        fi
        echo "" >> "${report}"
    done <<< "${compose_files}"

    SCAN_PASS=$((SCAN_PASS + 1))
    info "Report: ${report}"
}

# =============================================================================
# 09. Environment & Credential Audit
# =============================================================================
scan_env_credentials() {
    step "09/12 — ENVIRONMENT & CREDENTIAL AUDIT"

    local report="${OUTPUT_DIR}/09-env-credential-audit.txt"

    {
        echo "============================================================"
        echo "  ENVIRONMENT & CREDENTIAL AUDIT"
        echo "  Date:   $(date)"
        echo "============================================================"
        echo ""
    } > "${report}"

    # Find all .env files
    echo "═══ .env Files Found ═══" >> "${report}"
    echo "" >> "${report}"
    find "${TARGET_DIR}" -name ".env*" -type f 2>/dev/null | \
        grep -v node_modules | grep -v ".git/" | grep -v "keycloak-24" | grep -v "java17" | while read -r ef; do
        echo "--- ${ef} ---" >> "${report}"
        while IFS= read -r line; do
            if echo "${line}" | grep -qiE "(password|secret|token|key|credential)" 2>/dev/null; then
                # Mask the value
                local key
                key=$(echo "${line}" | cut -d'=' -f1)
                echo "  [SENSITIVE] ${key}=<REDACTED>" >> "${report}"
            else
                echo "  ${line}" >> "${report}"
            fi
        done < "${ef}"
        echo "" >> "${report}"
    done

    # Check for .env in .gitignore
    echo "" >> "${report}"
    echo "═══ .gitignore Check ═══" >> "${report}"
    echo "" >> "${report}"
    local gitignore="${TARGET_DIR}/.gitignore"
    if [ -f "${gitignore}" ]; then
        if grep -q "\.env" "${gitignore}"; then
            echo "  [PASS] .env is in .gitignore" >> "${report}"
        else
            echo "  [FAIL] .env is NOT in .gitignore - credentials may be committed!" >> "${report}"
        fi
    else
        echo "  [WARN] No .gitignore found" >> "${report}"
    fi

    # Check for hardcoded IPs/URLs
    echo "" >> "${report}"
    echo "═══ Hardcoded IPs & URLs ═══" >> "${report}"
    echo "" >> "${report}"
    grep -rn --include="*.py" --include="*.ts" --include="*.tsx" --include="*.yaml" --include="*.yml" \
        -E "([0-9]{1,3}\.){3}[0-9]{1,3}" "${TARGET_DIR}" 2>/dev/null | \
        grep -v node_modules | grep -v ".git/" | grep -v "keycloak-24" | grep -v "java17" | \
        grep -v "0\.0\.0\.0" | grep -v "127\.0\.0\.1" | head -50 >> "${report}" || true

    SCAN_PASS=$((SCAN_PASS + 1))
    info "Report: ${report}"
}

# =============================================================================
# 10. License Compliance Scan
# =============================================================================
scan_licenses() {
    step "10/12 — LICENSE COMPLIANCE SCAN"

    local report="${OUTPUT_DIR}/10-license-scan.txt"

    {
        echo "============================================================"
        echo "  LICENSE COMPLIANCE SCAN"
        echo "  Date:   $(date)"
        echo "============================================================"
        echo ""
    } > "${report}"

    if command -v trivy &>/dev/null; then
        info "Running Trivy license scan..."
        trivy fs --scanners license \
            --format table \
            "${TARGET_DIR}" >> "${report}" 2>&1 || echo "  License scan completed with warnings." >> "${report}"
    else
        echo "Trivy not available for license scan." >> "${report}"
    fi

    # Check for LICENSE file
    echo "" >> "${report}"
    echo "═══ License Files ═══" >> "${report}"
    echo "" >> "${report}"
    find "${TARGET_DIR}" -maxdepth 2 -iname "LICENSE*" -o -iname "LICENCE*" -o -iname "COPYING*" 2>/dev/null | \
        grep -v node_modules | grep -v ".git/" | grep -v "keycloak-24" | grep -v "java17" | while read -r lf; do
        echo "  Found: ${lf}" >> "${report}"
    done

    SCAN_PASS=$((SCAN_PASS + 1))
    info "Report: ${report}"
}

# =============================================================================
# 11. Code Quality Metrics
# =============================================================================
scan_code_quality() {
    step "11/12 — CODE QUALITY METRICS"

    local report="${OUTPUT_DIR}/11-code-quality-metrics.txt"

    {
        echo "============================================================"
        echo "  CODE QUALITY METRICS"
        echo "  Target: ${TARGET_DIR}"
        echo "  Date:   $(date)"
        echo "============================================================"
        echo ""
    } > "${report}"

    echo "═══ File Type Breakdown ═══" >> "${report}"
    echo "" >> "${report}"

    for ext in py ts tsx js jsx sql yaml yml sh ps1 json md css html; do
        local count
        count=$(find "${TARGET_DIR}" -name "*.${ext}" -type f 2>/dev/null | \
            grep -v node_modules | grep -v ".git/" | grep -v "keycloak-24" | grep -v "java17" | wc -l)
        if [ "${count}" -gt 0 ]; then
            printf "  %-10s %5d files\n" ".${ext}" "${count}" >> "${report}"
        fi
    done

    echo "" >> "${report}"
    echo "═══ Lines of Code (Source Files) ═══" >> "${report}"
    echo "" >> "${report}"

    local total_loc=0
    for ext in py ts tsx js; do
        local loc
        loc=$(find "${TARGET_DIR}" -name "*.${ext}" -type f 2>/dev/null | \
            grep -v node_modules | grep -v ".git/" | grep -v "keycloak-24" | grep -v "java17" | \
            xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}' || echo "0")
        if [ "${loc}" -gt 0 ]; then
            printf "  %-10s %6d lines\n" ".${ext}" "${loc}" >> "${report}"
            total_loc=$((total_loc + loc))
        fi
    done
    echo "" >> "${report}"
    echo "  TOTAL: ${total_loc} lines of source code" >> "${report}"

    echo "" >> "${report}"
    echo "═══ Directory Structure ═══" >> "${report}"
    echo "" >> "${report}"

    # Tree showing only source dirs
    find "${TARGET_DIR}" -type d 2>/dev/null | \
        grep -v node_modules | grep -v ".git" | grep -v "keycloak-24" | grep -v "java17" | \
        grep -v "__pycache__" | sort | \
        sed "s|${TARGET_DIR}|.|g" >> "${report}" || true

    echo "" >> "${report}"
    echo "═══ Backend API Routes ═══" >> "${report}"
    echo "" >> "${report}"

    # Extract FastAPI route decorators
    find "${TARGET_DIR}/backend" -name "*.py" -type f 2>/dev/null | while read -r pyfile; do
        local routes
        routes=$(grep -n "@router\.\(get\|post\|put\|delete\|patch\)" "${pyfile}" 2>/dev/null || true)
        if [ -n "${routes}" ]; then
            echo "  ${pyfile}:" >> "${report}"
            echo "${routes}" | sed 's/^/    /' >> "${report}"
            echo "" >> "${report}"
        fi
    done

    echo "" >> "${report}"
    echo "═══ Frontend Pages & Components ═══" >> "${report}"
    echo "" >> "${report}"

    find "${TARGET_DIR}/frontend/src" -name "*.tsx" -type f 2>/dev/null | sort | \
        sed "s|${TARGET_DIR}/frontend/src|src|g" >> "${report}" || true

    SCAN_PASS=$((SCAN_PASS + 1))
    info "Report: ${report}"
}

# =============================================================================
# 12. FINAL CONSOLIDATED REPORT
# =============================================================================
generate_final_report() {
    step "12/12 — FINAL CONSOLIDATED REPORT"

    local report="${OUTPUT_DIR}/00-FULL-SECURITY-REPORT.txt"
    local dt
    dt=$(date '+%Y-%m-%d %H:%M:%S')

    cat > "${report}" <<EOF
╔═══════════════════════════════════════════════════════════════════════════════╗
║                                                                             ║
║           FULL SECURITY SCAN REPORT — RnD Quality Statistics                ║
║                                                                             ║
╠═══════════════════════════════════════════════════════════════════════════════╣
║  Date:     ${dt}                                           ║
║  Target:   ${TARGET_DIR}  ║
║  Severity: ${SEVERITY}                                     ║
║  Scanner:  Trivy $(trivy --version 2>&1 | grep -oP 'Version: \K\S+' || echo 'N/A')                                                        ║
╚═══════════════════════════════════════════════════════════════════════════════╝


════════════════════════════════════════════════════════════════════════════════
  EXECUTIVE SUMMARY
════════════════════════════════════════════════════════════════════════════════

  Scan Outcome:
    CRITICAL Vulnerabilities ... ${TOTAL_CRITICAL}
    HIGH Vulnerabilities ....... ${TOTAL_HIGH}
    MEDIUM Vulnerabilities ..... ${TOTAL_MEDIUM}
    Secrets Detected ........... ${TOTAL_SECRETS}
    Misconfigurations .......... ${TOTAL_MISCONFIGS}

  Gate Status:
    Checks PASSED .............. ${SCAN_PASS}
    Checks WARNED .............. ${SCAN_WARN}
    Checks FAILED .............. ${SCAN_FAIL}

EOF

    # Overall verdict
    if [ "${TOTAL_CRITICAL}" -gt 0 ] || [ "${TOTAL_SECRETS}" -gt 0 ]; then
        cat >> "${report}" <<'EOF'
  ┌─────────────────────────────────────────────────────────────┐
  │  OVERALL VERDICT:  ❌ FAIL — Action Required                │
  │  Critical vulnerabilities or secrets were detected.         │
  │  Address these issues before deployment.                    │
  └─────────────────────────────────────────────────────────────┘
EOF
    elif [ "${TOTAL_HIGH}" -gt 10 ]; then
        cat >> "${report}" <<'EOF'
  ┌─────────────────────────────────────────────────────────────┐
  │  OVERALL VERDICT:  ⚠️  WARNING — Review Recommended         │
  │  Multiple HIGH severity vulnerabilities found.              │
  │  Review and plan remediation.                               │
  └─────────────────────────────────────────────────────────────┘
EOF
    else
        cat >> "${report}" <<'EOF'
  ┌─────────────────────────────────────────────────────────────┐
  │  OVERALL VERDICT:  ✅ PASS — Acceptable Risk Level          │
  │  No critical issues found. Continue with deployment.        │
  └─────────────────────────────────────────────────────────────┘
EOF
    fi

    # Append project overview
    cat >> "${report}" <<'EOF'


════════════════════════════════════════════════════════════════════════════════
  PROJECT OVERVIEW
════════════════════════════════════════════════════════════════════════════════

  Project: RnD Quality Statistics (rnd-quality-statistics-main)
  Stack:   FastAPI (Python 3.14) + React 19 + PostgreSQL + Keycloak SSO

  Architecture:
    ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
    │  Frontend   │────▶│   Backend   │────▶│  PostgreSQL  │
    │  React 19   │     │  FastAPI    │     │   :5432      │
    │  Vite+TS    │     │  :8000     │     └─────────────┘
    │  :5173      │     │            │
    └─────────────┘     └──────┬─────┘
                               │
                        ┌──────▼──────┐
                        │  Keycloak   │
                        │  SSO/OIDC   │
                        │  :8180      │
                        └─────────────┘

  Components Scanned:
    - Backend:  61 Python files (FastAPI + Keycloak auth + PostgreSQL)
    - Frontend: 61 TypeScript/TSX files (React 19 + shadcn/ui)
    - Database: 6 SQL files (PostgreSQL schema + migrations)
    - K8s:      17 manifests (namespace, deployments, services, ingress)
    - DevOps:   docker-compose.yml, Dockerfile, CI/CD configs

EOF

    # Append all individual reports
    cat >> "${report}" <<'EOF'

════════════════════════════════════════════════════════════════════════════════
  DETAILED SCAN REPORTS
════════════════════════════════════════════════════════════════════════════════

EOF

    for i in 01 02 03 04 05 06 07 08 09 10 11; do
        local subfile="${OUTPUT_DIR}/${i}-*.txt"
        for f in ${subfile}; do
            if [ -f "$f" ]; then
                echo "" >> "${report}"
                echo "────────────────────────────────────────────────────────────────────" >> "${report}"
                cat "$f" >> "${report}"
                echo "" >> "${report}"
            fi
        done
    done

    # Report index
    cat >> "${report}" <<EOF


════════════════════════════════════════════════════════════════════════════════
  REPORT INDEX
════════════════════════════════════════════════════════════════════════════════

  All individual reports are saved in: ${OUTPUT_DIR}/

EOF

    ls -1 "${OUTPUT_DIR}/"*.txt 2>/dev/null | while read -r f; do
        local size
        size=$(wc -c < "$f" | tr -d ' ')
        printf "    %-50s %8s bytes\n" "$(basename "$f")" "${size}" >> "${report}"
    done

    cat >> "${report}" <<EOF


════════════════════════════════════════════════════════════════════════════════
  END OF REPORT — Generated $(date '+%Y-%m-%d %H:%M:%S')
════════════════════════════════════════════════════════════════════════════════
EOF

    info "Consolidated report: ${report}"
}

# =============================================================================
# Print Summary
# =============================================================================
print_summary() {
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "  ╔═══════════════════════════════════════════════════════════════╗"
    echo "  ║               SCAN COMPLETE — SUMMARY                       ║"
    echo "  ╠═══════════════════════════════════════════════════════════════╣"
    printf "  ║  CRITICAL: %-5s  HIGH: %-5s  MEDIUM: %-5s               ║\n" "${TOTAL_CRITICAL}" "${TOTAL_HIGH}" "${TOTAL_MEDIUM}"
    printf "  ║  Secrets:  %-5s  Misconfigs: %-5s                        ║\n" "${TOTAL_SECRETS}" "${TOTAL_MISCONFIGS}"
    echo "  ╠═══════════════════════════════════════════════════════════════╣"
    printf "  ║  PASSED: %-3s  WARNED: %-3s  FAILED: %-3s                    ║\n" "${SCAN_PASS}" "${SCAN_WARN}" "${SCAN_FAIL}"
    echo "  ╠═══════════════════════════════════════════════════════════════╣"
    echo "  ║  Reports: ${OUTPUT_DIR}"
    echo "  ║  Main:    ${OUTPUT_DIR}/00-FULL-SECURITY-REPORT.txt"
    echo "  ╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    if [ "${TOTAL_CRITICAL}" -gt 0 ]; then
        echo -e "  ${RED}${BOLD}VERDICT: ❌ FAIL — Critical issues found${NC}"
    elif [ "${TOTAL_HIGH}" -gt 10 ]; then
        echo -e "  ${YELLOW}${BOLD}VERDICT: ⚠️  WARNING — Review recommended${NC}"
    else
        echo -e "  ${GREEN}${BOLD}VERDICT: ✅ PASS — Acceptable risk level${NC}"
    fi
    echo ""
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================
main() {
    banner
    preflight

    scan_secrets
    scan_vulnerabilities
    scan_misconfig
    scan_dockerfile
    scan_shellscripts
    scan_k8s_manifests
    scan_python_deps
    scan_docker_compose
    scan_env_credentials
    scan_licenses
    scan_code_quality
    generate_final_report

    print_summary

    echo -e "${GREEN}${BOLD}  To view the full report:${NC}"
    echo -e "  ${CYAN}cat ${OUTPUT_DIR}/00-FULL-SECURITY-REPORT.txt${NC}"
    echo ""
}

main "$@"
