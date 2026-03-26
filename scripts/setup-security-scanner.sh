#!/usr/bin/env bash
# =============================================================================
# setup-security-scanner.sh — Host the Security Scanner for All Developers
# =============================================================================
# Run this ONCE on the infra server (132.186.17.22) to make the security
# scanner available to all developers via a one-liner command.
#
# What it does:
#   1. Copies dev-security-scan.sh to a web-accessible location
#   2. Starts a lightweight Python HTTP server (or uses existing nginx/httpd)
#   3. Prints the one-liner command developers should use
#
# Usage: sudo bash setup-security-scanner.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVE_DIR="/opt/security-scanner"
SERVE_PORT="${SERVE_PORT:-8888}"
SERVER_IP="${SERVER_IP:-132.186.17.22}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

echo -e "${CYAN}"
echo "  ╔═══════════════════════════════════════════════════════════╗"
echo "  ║    Security Scanner — Server Setup                       ║"
echo "  ╚═══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Create serve directory
mkdir -p "${SERVE_DIR}"

# Copy the scanner script
cp "${SCRIPT_DIR}/dev-security-scan.sh" "${SERVE_DIR}/dev-security-scan.sh"
chmod 644 "${SERVE_DIR}/dev-security-scan.sh"

echo -e "${GREEN}[OK]${NC} Scanner script copied to ${SERVE_DIR}/"

# Create a small landing page
cat > "${SERVE_DIR}/index.html" <<'INDEXEOF'
<!DOCTYPE html>
<html>
<head>
    <title>Security Scanner — Developer Portal</title>
    <style>
        body { font-family: 'Segoe UI', Arial, sans-serif; max-width: 800px; margin: 60px auto; background: #f5f5f5; padding: 20px; }
        h1 { color: #1a1a2e; }
        .cmd { background: #263238; color: #aed581; padding: 16px 20px; border-radius: 8px; font-family: monospace; font-size: 15px; margin: 12px 0; overflow-x: auto; }
        .section { background: white; padding: 24px; border-radius: 12px; margin: 16px 0; box-shadow: 0 2px 8px rgba(0,0,0,0.08); }
        .note { background: #fff3e0; padding: 12px 16px; border-radius: 8px; border-left: 4px solid #f57c00; margin: 12px 0; }
        table { width: 100%; border-collapse: collapse; margin: 12px 0; }
        th { background: #e3f2fd; text-align: left; padding: 10px; }
        td { padding: 8px 10px; border-bottom: 1px solid #eee; }
        code { background: #eee; padding: 2px 6px; border-radius: 4px; font-size: 13px; }
    </style>
</head>
<body>
    <h1>&#128274; Security Scanner — Developer Portal</h1>

    <div class="section">
        <h2>Quick Start (One Command)</h2>
        <p>Run this on your machine to scan all registry images:</p>
        <div class="cmd">curl -sL http://SERVER_IP:SERVER_PORT/dev-security-scan.sh | bash</div>

        <p>Scan a specific image:</p>
        <div class="cmd">curl -sL http://SERVER_IP:SERVER_PORT/dev-security-scan.sh | bash -s -- --image catool --tag latest --type image-only</div>

        <p>Or download first, then run:</p>
        <div class="cmd">curl -sL http://SERVER_IP:SERVER_PORT/dev-security-scan.sh -o sec-scan.sh && bash sec-scan.sh</div>
    </div>

    <div class="section">
        <h2>All Scan Options</h2>
        <table>
            <tr><th>Option</th><th>Description</th><th>Default</th></tr>
            <tr><td><code>--image NAME</code></td><td>Image name in registry</td><td>catool</td></tr>
            <tr><td><code>--tag TAG</code></td><td>Image tag</td><td>latest</td></tr>
            <tr><td><code>--type TYPE</code></td><td>full / image-only / code-only / k8s-manifests</td><td>full</td></tr>
            <tr><td><code>--scan-registry</code></td><td>Scan ALL images in registry</td><td>off</td></tr>
            <tr><td><code>--no-fail-critical</code></td><td>Don't fail on CRITICAL vulns</td><td>fail</td></tr>
            <tr><td><code>--skip-install</code></td><td>Skip tool installation</td><td>install</td></tr>
            <tr><td><code>--jenkins-url URL</code></td><td>Jenkins master URL</td><td>http://132.186.17.25:32000</td></tr>
            <tr><td><code>--registry URL</code></td><td>Container registry</td><td>132.186.17.22:5000</td></tr>
            <tr><td><code>--output-dir DIR</code></td><td>Report output directory</td><td>./security-reports-&lt;ts&gt;</td></tr>
        </table>
    </div>

    <div class="section">
        <h2>Examples</h2>
        <div class="cmd"># Full scan (all stages)<br>bash sec-scan.sh</div>
        <div class="cmd"># Scan specific image<br>bash sec-scan.sh --image catool-ns --tag 1.0.0_beta_hotfix --type image-only</div>
        <div class="cmd"># Scan all registry images<br>bash sec-scan.sh --scan-registry</div>
        <div class="cmd"># K8s manifests only<br>bash sec-scan.sh --type k8s-manifests</div>
    </div>

    <div class="section">
        <h2>Prerequisites (auto-checked)</h2>
        <ul>
            <li>Java 11+ (for Jenkins JNLP agent)</li>
            <li>curl, python3 (standard on RHEL9)</li>
            <li>Network access to Jenkins (132.186.17.25:32000) and Registry (132.186.17.22:5000)</li>
        </ul>
        <div class="note">
            <strong>Note:</strong> Trivy and other security tools are auto-installed if not present. All tools and temp files are cleaned up automatically after scanning.
        </div>
    </div>

    <div class="section">
        <h2>How It Works</h2>
        <ol>
            <li>Creates an isolated workspace in <code>/tmp</code></li>
            <li>Installs security tools (Trivy, Grype, etc.) if needed</li>
            <li>Connects a temporary JNLP agent to Jenkins master</li>
            <li>Creates/triggers the security pipeline job</li>
            <li>Streams live console output to your terminal</li>
            <li>Downloads all reports (JSON + HTML) to your machine</li>
            <li>Auto-cleans up (agent, temp files, Jenkins node)</li>
        </ol>
    </div>
</body>
</html>
INDEXEOF

# Replace placeholders in landing page
sed -i "s/SERVER_IP/${SERVER_IP}/g" "${SERVE_DIR}/index.html"
sed -i "s/SERVER_PORT/${SERVE_PORT}/g" "${SERVE_DIR}/index.html"

echo -e "${GREEN}[OK]${NC} Landing page created at ${SERVE_DIR}/index.html"

# Create systemd service for persistent hosting
cat > /etc/systemd/system/security-scanner-web.service <<SVCEOF
[Unit]
Description=Security Scanner Web Server
After=network.target

[Service]
Type=simple
WorkingDirectory=${SERVE_DIR}
ExecStart=/usr/bin/python3 -m http.server ${SERVE_PORT} --bind 0.0.0.0
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable security-scanner-web.service 2>/dev/null || true
systemctl restart security-scanner-web.service 2>/dev/null || true

echo -e "${GREEN}[OK]${NC} Web server started on port ${SERVE_PORT}"
echo ""

# Verify it's running
sleep 1
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${SERVE_PORT}/dev-security-scan.sh" 2>/dev/null || echo "000")

if [ "${HTTP_STATUS}" = "200" ]; then
    echo -e "${GREEN}[OK]${NC} Scanner is accessible!"
else
    echo -e "${YELLOW}[WARN]${NC} Couldn't verify (HTTP ${HTTP_STATUS}). May need firewall rule:"
    echo "  firewall-cmd --permanent --add-port=${SERVE_PORT}/tcp && firewall-cmd --reload"
fi

echo ""
echo -e "${CYAN}${BOLD}"
echo "  ╔═══════════════════════════════════════════════════════════════════════╗"
echo "  ║                                                                       ║"
echo "  ║   DEVELOPERS: Run this ONE command on your machine:                   ║"
echo "  ║                                                                       ║"
echo "  ║   curl -sL http://${SERVER_IP}:${SERVE_PORT}/dev-security-scan.sh | bash           ║"
echo "  ║                                                                       ║"
echo "  ║   Or with options:                                                    ║"
echo "  ║   curl -sL http://${SERVER_IP}:${SERVE_PORT}/dev-security-scan.sh | bash -s -- \\   ║"
echo "  ║       --image catool --tag latest --type image-only                   ║"
echo "  ║                                                                       ║"
echo "  ║   Portal: http://${SERVER_IP}:${SERVE_PORT}/                                       ║"
echo "  ║                                                                       ║"
echo "  ╚═══════════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
