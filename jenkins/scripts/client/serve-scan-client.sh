#!/usr/bin/env bash
# =============================================================================
# serve-scan-client.sh — HTTP server to distribute the scan client
# =============================================================================
# Run this ONCE on the central server (132.186.17.22).
# It serves the security-scan-client.sh via HTTP so any user can:
#
#   curl -sL http://132.186.17.22:9090/scan | bash
#
# This uses Python's built-in HTTP server — no extra dependencies.
# =============================================================================

set -euo pipefail

SERVE_PORT="${1:-9090}"
SERVE_DIR="/opt/scan-client-server"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=================================================="
echo "  Setting up scan client distribution server"
echo "=================================================="

# Create serving directory
sudo mkdir -p "${SERVE_DIR}"

# Copy the client script
sudo cp "${SCRIPT_DIR}/security-scan-client.sh" "${SERVE_DIR}/scan"
sudo chmod 644 "${SERVE_DIR}/scan"

# Create a simple landing page
sudo tee "${SERVE_DIR}/index.html" > /dev/null <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Security Scan Service</title>
    <style>
        body { font-family: 'Segoe UI', Arial, sans-serif; margin: 0; background: #f0f2f5; }
        .header { background: linear-gradient(135deg, #1a1a2e, #16213e); color: white; padding: 40px; text-align: center; }
        .header h1 { margin: 0 0 10px 0; font-size: 32px; }
        .header p { margin: 0; opacity: 0.8; font-size: 16px; }
        .container { max-width: 900px; margin: 30px auto; padding: 0 20px; }
        .card { background: white; border-radius: 12px; padding: 30px; margin: 20px 0;
                box-shadow: 0 2px 12px rgba(0,0,0,0.08); }
        .card h2 { margin-top: 0; color: #1a1a2e; }
        code { background: #1a1a2e; color: #00ff88; padding: 2px 8px; border-radius: 4px; font-size: 14px; }
        pre { background: #1a1a2e; color: #00ff88; padding: 20px; border-radius: 8px; overflow-x: auto;
              font-size: 14px; line-height: 1.6; }
        .badge { display: inline-block; padding: 4px 12px; border-radius: 20px; font-size: 12px;
                 font-weight: 600; margin: 2px; }
        .badge-green { background: #e8f5e9; color: #2e7d32; }
        .badge-blue { background: #e3f2fd; color: #1565c0; }
        .badge-orange { background: #fff3e0; color: #e65100; }
        table { width: 100%; border-collapse: collapse; margin: 16px 0; }
        th { background: #f5f5f5; padding: 12px; text-align: left; border-bottom: 2px solid #e0e0e0; }
        td { padding: 10px 12px; border-bottom: 1px solid #eee; }
        .highlight { background: linear-gradient(135deg, #e8f5e9, #c8e6c9); border-radius: 12px;
                     padding: 24px; text-align: center; margin: 20px 0; }
        .highlight code { font-size: 18px; padding: 8px 16px; }
    </style>
</head>
<body>
    <div class="header">
        <h1>Security Scan Service</h1>
        <p>Centralized security scanning — zero setup for users</p>
    </div>
    <div class="container">
        <div class="highlight">
            <p style="font-size: 18px; font-weight: 600; margin: 0 0 12px 0;">Quick Start — Run this ONE command:</p>
            <code>curl -sL http://132.186.17.22:9090/scan | bash</code>
        </div>

        <div class="card">
            <h2>What You Get</h2>
            <span class="badge badge-green">No Setup Required</span>
            <span class="badge badge-blue">Isolated Per User</span>
            <span class="badge badge-orange">Reports Downloaded Locally</span>
            <p>This service runs a full security scan pipeline on the central server and delivers reports to your machine.</p>
            <p><strong>Scans included:</strong> Vulnerability Scanning, Secret Detection, SAST, SCA, Container Image Scanning,
               Kubernetes Config Audit, Cluster Security Assessment</p>
            <p><strong>Tools used:</strong> Trivy, Grype, Hadolint, ShellCheck, Kubesec, OWASP Dependency-Check</p>
        </div>

        <div class="card">
            <h2>Usage Examples</h2>
            <pre># Full scan (default)
curl -sL http://132.186.17.22:9090/scan | bash

# Scan a specific image
curl -sL http://132.186.17.22:9090/scan | bash -s -- --image catool-ns --tag 1.0.0

# Image-only scan
curl -sL http://132.186.17.22:9090/scan | bash -s -- --type image-only

# Scan ALL registry images
curl -sL http://132.186.17.22:9090/scan | bash -s -- --scan-registry

# K8s manifest security audit
curl -sL http://132.186.17.22:9090/scan | bash -s -- --type k8s-manifests

# Save script locally for repeated use
curl -sL http://132.186.17.22:9090/scan -o scan.sh
bash scan.sh --image catool --tag latest

# List available images
curl -sL http://132.186.17.22:9090/scan | bash -s -- --list-images

# Check server status
curl -sL http://132.186.17.22:9090/scan | bash -s -- --status

# View scan history
curl -sL http://132.186.17.22:9090/scan | bash -s -- --history

# JSON output (for CI/CD integration)
curl -sL http://132.186.17.22:9090/scan | bash -s -- --json --quiet</pre>
        </div>

        <div class="card">
            <h2>Requirements</h2>
            <table>
                <tr><th>Requirement</th><th>Details</th></tr>
                <tr><td>curl</td><td>Pre-installed on Linux/Mac</td></tr>
                <tr><td>bash</td><td>Pre-installed on Linux/Mac</td></tr>
                <tr><td>Network</td><td>Access to 132.186.17.22 (ports 9090, 32000, 5000)</td></tr>
                <tr><td colspan="2"><em>That's it. No Java, no Docker, no tools to install.</em></td></tr>
            </table>
        </div>

        <div class="card">
            <h2>How It Works</h2>
            <table>
                <tr><th>Step</th><th>What Happens</th><th>Where</th></tr>
                <tr><td>1</td><td>Client script triggers scan via Jenkins API</td><td>Your machine</td></tr>
                <tr><td>2</td><td>Jenkins runs security pipeline on pre-configured agent</td><td>Central server</td></tr>
                <tr><td>3</td><td>Console output streams live to your terminal</td><td>Your machine</td></tr>
                <tr><td>4</td><td>Reports (HTML/JSON/TXT) downloaded to your machine</td><td>Your machine</td></tr>
                <tr><td>5</td><td>HTML report automatically opens in browser</td><td>Your machine</td></tr>
            </table>
        </div>
    </div>
</body>
</html>
HTML

echo ""
echo "  Client script: ${SERVE_DIR}/scan"
echo "  Landing page:  ${SERVE_DIR}/index.html"
echo ""

# Create systemd service for persistence
if command -v systemctl &>/dev/null; then
    sudo tee /etc/systemd/system/scan-client-server.service > /dev/null <<EOF
[Unit]
Description=Security Scan Client Distribution Server
After=network.target

[Service]
Type=simple
WorkingDirectory=${SERVE_DIR}
ExecStart=/usr/bin/python3 -m http.server ${SERVE_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable scan-client-server.service
    sudo systemctl restart scan-client-server.service

    echo "  Service started on port ${SERVE_PORT}"
    echo ""
    echo "  Users can now run:"
    echo "    curl -sL http://132.186.17.22:${SERVE_PORT}/scan | bash"
    echo ""
    echo "  Landing page:"
    echo "    http://132.186.17.22:${SERVE_PORT}/"
else
    echo "  Starting HTTP server on port ${SERVE_PORT}..."
    echo "  Users can fetch the client with:"
    echo "    curl -sL http://132.186.17.22:${SERVE_PORT}/scan | bash"
    echo ""
    cd "${SERVE_DIR}"
    python3 -m http.server "${SERVE_PORT}"
fi
