#!/usr/bin/env bash
# =============================================================================
# install-security-tools.sh — Install ALL Tools for the Unified DevSecOps Agent
# =============================================================================
# Installs EVERYTHING on the Jenkins agent (server-side only).
# No local/user machine dependencies are needed after running this script.
#
# Installs:
#   Security:  Trivy, Grype, Hadolint, ShellCheck, Kubesec, OWASP DC
#   Quality:   SonarQube Scanner CLI
#   Python:    pytest, pytest-cov, pytest-html, flake8, bandit, pylint, mypy,
#              black, safety, cyclonedx-bom, cyclonedx-py, pip-audit
#   Node.js:   @cyclonedx/cyclonedx-npm (global)
#   Go:        cyclonedx-gomod (global)
#   Utilities: jq, git, python3, unzip, curl
#
# Run as root on RHEL 9 / CentOS 9 / Fedora
# Usage: chmod +x install-security-tools.sh && sudo ./install-security-tools.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "\n${BLUE}[====]${NC} $*\n"; }

INSTALL_DIR="/opt/security-tools"
BIN_DIR="/usr/local/bin"

mkdir -p "${INSTALL_DIR}" "${BIN_DIR}"

# =============================================================================
# 1. Trivy — Container & Filesystem Vulnerability Scanner
# =============================================================================
install_trivy() {
    log_step "Installing Trivy"

    if command -v trivy &>/dev/null; then
        log_info "Trivy already installed: $(trivy --version 2>&1 | head -1)"
        return 0
    fi

    # RHEL/CentOS method
    cat > /etc/yum.repos.d/trivy.repo <<'EOF'
[trivy]
name=Trivy repository
baseurl=https://aquasecurity.github.io/trivy-repo/rpm/releases/$basearch/
gpgcheck=0
enabled=1
EOF

    dnf install -y trivy 2>/dev/null || yum install -y trivy 2>/dev/null || {
        log_warn "Package install failed, trying binary download..."
        TRIVY_VERSION=$(curl -s https://api.github.com/repos/aquasecurity/trivy/releases/latest | \
            python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))" 2>/dev/null || echo "0.58.0")
        curl -sfL "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" | \
            tar xz -C "${BIN_DIR}" trivy
    }

    log_info "Trivy installed: $(trivy --version 2>&1 | head -1)"

    # Pre-download vulnerability database
    log_info "Downloading Trivy vulnerability database (first run)..."
    trivy image --download-db-only 2>/dev/null || log_warn "DB download may happen on first scan"
}

# =============================================================================
# 2. Grype — Vulnerability Scanner (Anchore)
# =============================================================================
install_grype() {
    log_step "Installing Grype"

    if command -v grype &>/dev/null; then
        log_info "Grype already installed: $(grype version 2>&1 | head -3)"
        return 0
    fi

    curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh | sh -s -- -b "${BIN_DIR}" 2>/dev/null || {
        log_warn "Grype installation failed (optional tool, continuing)"
        return 0
    }

    log_info "Grype installed: $(grype version 2>&1 | head -1)"
}

# =============================================================================
# 3. Hadolint — Dockerfile Linter
# =============================================================================
install_hadolint() {
    log_step "Installing Hadolint"

    if command -v hadolint &>/dev/null; then
        log_info "Hadolint already installed: $(hadolint --version 2>&1)"
        return 0
    fi

    HADOLINT_VERSION=$(curl -s https://api.github.com/repos/hadolint/hadolint/releases/latest | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null || echo "v2.12.0")

    curl -sL "https://github.com/hadolint/hadolint/releases/download/${HADOLINT_VERSION}/hadolint-Linux-x86_64" \
        -o "${BIN_DIR}/hadolint" && chmod +x "${BIN_DIR}/hadolint" || {
        log_warn "Hadolint installation failed (optional tool, continuing)"
        return 0
    }

    log_info "Hadolint installed: $(hadolint --version 2>&1)"
}

# =============================================================================
# 4. ShellCheck — Shell Script Static Analysis
# =============================================================================
install_shellcheck() {
    log_step "Installing ShellCheck"

    if command -v shellcheck &>/dev/null; then
        log_info "ShellCheck already installed: $(shellcheck --version 2>&1 | head -2)"
        return 0
    fi

    dnf install -y ShellCheck 2>/dev/null || yum install -y ShellCheck 2>/dev/null || {
        SHELLCHECK_VERSION=$(curl -s https://api.github.com/repos/koalaman/shellcheck/releases/latest | \
            python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null || echo "v0.10.0")
        curl -sL "https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/shellcheck-${SHELLCHECK_VERSION}.linux.x86_64.tar.xz" | \
            tar xJ --strip-components=1 -C "${BIN_DIR}" "shellcheck-${SHELLCHECK_VERSION}/shellcheck"
    }

    log_info "ShellCheck installed: $(shellcheck --version 2>&1 | head -2)"
}

# =============================================================================
# 5. Kubesec — Kubernetes Security Risk Analysis
# =============================================================================
install_kubesec() {
    log_step "Installing Kubesec"

    if command -v kubesec &>/dev/null; then
        log_info "Kubesec already installed"
        return 0
    fi

    KUBESEC_VERSION=$(curl -s https://api.github.com/repos/controlplaneio/kubesec/releases/latest | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))" 2>/dev/null || echo "2.14.1")

    curl -sL "https://github.com/controlplaneio/kubesec/releases/download/v${KUBESEC_VERSION}/kubesec_linux_amd64.tar.gz" | \
        tar xz -C "${BIN_DIR}" kubesec 2>/dev/null || {
        log_warn "Kubesec installation failed (optional tool, continuing)"
        return 0
    }

    chmod +x "${BIN_DIR}/kubesec"
    log_info "Kubesec installed"
}

# =============================================================================
# 6. OWASP Dependency-Check
# =============================================================================
install_owasp_dc() {
    log_step "Installing OWASP Dependency-Check"

    DC_DIR="/opt/dependency-check"

    if [ -f "${DC_DIR}/bin/dependency-check.sh" ]; then
        log_info "OWASP Dependency-Check already installed"
        return 0
    fi

    DC_VERSION=$(curl -s https://api.github.com/repos/jeremylong/DependencyCheck/releases/latest | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))" 2>/dev/null || echo "11.1.1")

    log_info "Downloading OWASP Dependency-Check v${DC_VERSION}..."
    curl -sL "https://github.com/jeremylong/DependencyCheck/releases/download/v${DC_VERSION}/dependency-check-${DC_VERSION}-release.zip" \
        -o "/tmp/dependency-check.zip" || {
        log_warn "OWASP DC download failed (optional tool, continuing)"
        return 0
    }

    unzip -qo /tmp/dependency-check.zip -d /opt/ 2>/dev/null || {
        dnf install -y unzip 2>/dev/null && unzip -qo /tmp/dependency-check.zip -d /opt/
    }
    rm -f /tmp/dependency-check.zip

    ln -sf "${DC_DIR}/bin/dependency-check.sh" "${BIN_DIR}/dependency-check.sh"
    log_info "OWASP Dependency-Check installed at ${DC_DIR}"
}

# =============================================================================
# 7. SonarQube Scanner CLI
# =============================================================================
install_sonar_scanner() {
    log_step "Installing SonarQube Scanner CLI"

    if command -v sonar-scanner &>/dev/null; then
        log_info "SonarQube Scanner already installed"
        return 0
    fi

    SONAR_SCANNER_VERSION="6.2.1.4610"
    SONAR_DIR="/opt/sonar-scanner"

    log_info "Downloading SonarQube Scanner v${SONAR_SCANNER_VERSION}..."
    curl -sL "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}-linux-x64.zip" \
        -o /tmp/sonar-scanner.zip || {
        log_warn "SonarScanner download failed (optional tool, continuing)"
        return 0
    }

    unzip -qo /tmp/sonar-scanner.zip -d /opt/ 2>/dev/null
    mv "/opt/sonar-scanner-${SONAR_SCANNER_VERSION}-linux-x64" "${SONAR_DIR}" 2>/dev/null || true
    rm -f /tmp/sonar-scanner.zip

    ln -sf "${SONAR_DIR}/bin/sonar-scanner" "${BIN_DIR}/sonar-scanner"
    log_info "SonarQube Scanner installed at ${SONAR_DIR}"
}

# =============================================================================
# 8. Additional utilities
# =============================================================================
install_utilities() {
    log_step "Installing additional utilities"

    # jq (JSON processor)
    if ! command -v jq &>/dev/null; then
        dnf install -y jq 2>/dev/null || yum install -y jq 2>/dev/null || log_warn "jq not available"
    fi

    # python3 (for report parsing)
    if ! command -v python3 &>/dev/null; then
        dnf install -y python3 python3-pip 2>/dev/null || \
            yum install -y python3 python3-pip 2>/dev/null || \
            log_warn "python3 not available"
    fi

    # git
    if ! command -v git &>/dev/null; then
        dnf install -y git 2>/dev/null || yum install -y git 2>/dev/null || log_warn "git not available"
    fi

    # unzip (needed for SonarScanner and OWASP DC extraction)
    if ! command -v unzip &>/dev/null; then
        dnf install -y unzip 2>/dev/null || yum install -y unzip 2>/dev/null || log_warn "unzip not available"
    fi

    log_info "Utilities check complete"
}

# =============================================================================
# 9. Python Security & SBOM Tools (system-wide on agent)
# =============================================================================
install_python_tools() {
    log_step "Installing Python security/SBOM tools (agent system-wide)"

    if ! command -v python3 &>/dev/null; then
        log_warn "python3 not found — skipping Python tool installation"
        return 0
    fi

    # Upgrade pip first
    pip install --break-system-packages --upgrade pip 2>/dev/null || \
        pip install --upgrade pip 2>/dev/null || true

    PYTHON_PACKAGES=(
        # Test frameworks
        "pytest"
        "pytest-cov"
        "pytest-html"
        "pytest-xdist"
        "pytest-json-report"
        # Linting & formatting
        "flake8"
        "black"
        "mypy"
        "pylint"
        # Security & audit
        "bandit"
        "safety"
        # SBOM generation
        "cyclonedx-bom"
        "cyclonedx-py"
        "pip-audit"
        # Build tools
        "build"
        "wheel"
        "setuptools"
    )

    pip install --break-system-packages --quiet "${PYTHON_PACKAGES[@]}" 2>/dev/null || \
        pip install --quiet "${PYTHON_PACKAGES[@]}" 2>/dev/null || {
            log_warn "Bulk pip install failed — trying one by one"
            for pkg in "${PYTHON_PACKAGES[@]}"; do
                pip install --break-system-packages --quiet "$pkg" 2>/dev/null || \
                    pip install --quiet "$pkg" 2>/dev/null || \
                    log_warn "Could not install $pkg (non-critical)"
            done
        }

    log_info "Python tools installed:"
    for tool in pytest flake8 bandit pylint black mypy pip-audit cyclonedx-py; do
        if command -v "$tool" &>/dev/null || python3 -m "$tool" --version &>/dev/null 2>&1; then
            log_info "  $tool: $(python3 -m $tool --version 2>&1 | head -1 || echo 'installed')"
        else
            log_warn "  $tool: not found"
        fi
    done
}

# =============================================================================
# 10. Node.js Global SBOM Tool
# =============================================================================
install_nodejs_tools() {
    log_step "Installing Node.js SBOM tools (global)"

    if ! command -v npm &>/dev/null; then
        log_warn "npm not found — skipping Node.js tool installation"
        return 0
    fi

    npm install -g @cyclonedx/cyclonedx-npm 2>/dev/null && \
        log_info "@cyclonedx/cyclonedx-npm installed globally" || \
        log_warn "@cyclonedx/cyclonedx-npm installation failed (non-critical)"
}

# =============================================================================
# 11. Go CycloneDX
# =============================================================================
install_go_tools() {
    log_step "Installing Go SBOM tools"

    if ! command -v go &>/dev/null; then
        log_warn "go not found — skipping Go tool installation"
        return 0
    fi

    go install github.com/CycloneDX/cyclonedx-gomod/cmd/cyclonedx-gomod@latest 2>/dev/null && \
        log_info "cyclonedx-gomod installed" || \
        log_warn "cyclonedx-gomod installation failed (non-critical)"
}

# =============================================================================
# Verify all installations
# =============================================================================
verify_all() {
    log_step "Verifying all tool installations"

    echo "=========================================="
    echo "  Agent Tools — Installation Summary"
    echo "=========================================="

    check_tool() {
        local name="$1" cmd="$2" ver_cmd="${3:-$2 --version}"
        if command -v "$cmd" &>/dev/null; then
            VER=$(eval "$ver_cmd" 2>&1 | head -1 || echo "installed")
            echo -e "  ${GREEN}✓${NC} ${name}: ${VER}"
        else
            echo -e "  ${RED}✗${NC} ${name}: NOT INSTALLED"
        fi
    }

    check_tool "trivy"             "trivy"            "trivy --version 2>&1 | head -1"
    check_tool "grype"             "grype"            "grype version 2>&1 | head -1"
    check_tool "hadolint"          "hadolint"         "hadolint --version 2>&1"
    check_tool "shellcheck"        "shellcheck"       "shellcheck --version 2>&1 | grep version: | head -1"
    check_tool "kubesec"           "kubesec"          "kubesec version 2>&1 | head -1"
    check_tool "sonar-scanner"     "sonar-scanner"    "sonar-scanner --version 2>&1 | head -1"
    check_tool "podman"            "podman"           "podman --version 2>&1"
    check_tool "java"              "java"             "java -version 2>&1 | head -1"
    check_tool "jq"                "jq"               "jq --version 2>&1"
    check_tool "python3"           "python3"          "python3 --version 2>&1"
    check_tool "pip"               "pip"              "pip --version 2>&1 | head -1"
    check_tool "git"               "git"              "git --version 2>&1"
    check_tool "npm"               "npm"              "npm --version 2>&1"
    check_tool "go"                "go"               "go version 2>&1"

    echo ""
    echo "  Python security tools:"
    for tool in pytest flake8 bandit pylint mypy black cyclonedx-py pip-audit; do
        if command -v "$tool" &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} ${tool}"
        else
            echo -e "  ${RED}✗${NC} ${tool}: not found"
        fi
    done

    if [ -f "/opt/dependency-check/bin/dependency-check.sh" ]; then
        echo -e "  ${GREEN}✓${NC} OWASP Dependency-Check: installed"
    else
        echo -e "  ${RED}✗${NC} OWASP Dependency-Check: NOT INSTALLED"
    fi

    echo "=========================================="
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo "=========================================="
    echo "  Unified DevSecOps Agent — Tool Installer"
    echo "  Target: $(hostname) ($(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2 2>/dev/null || echo 'Linux'))"
    echo "  All tools installed server-side (agent only)"
    echo "=========================================="

    install_trivy
    install_grype
    install_hadolint
    install_shellcheck
    install_kubesec
    install_owasp_dc
    install_sonar_scanner
    install_utilities
    install_python_tools
    install_nodejs_tools
    install_go_tools
    verify_all

    echo ""
    log_info "All tools installed successfully on the agent!"
    log_info "The unified DevSecOps pipeline is ready to run."
    log_info "No local/user-machine dependencies are required."
}

main "$@"
