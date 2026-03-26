# Security Scan Service — User Guide

## For Users (Zero Setup)

You don't need to install anything. Just run ONE command:

```bash
curl -sL http://132.186.17.22:9091/scan | bash
```

**That's it.** The scan runs on the central server and reports download to your machine.

### Requirements

| Requirement | Details |
|-------------|---------|
| `curl` | Pre-installed on all Linux/Mac systems |
| `bash` | Pre-installed on all Linux/Mac systems |
| Network | Access to `132.186.17.22` (same network or VPN) |

**You do NOT need:** Java, Docker, Podman, Trivy, Python, Jenkins, or any other tool.

---

### Common Commands

```bash
# Full security scan (default image: catool:latest)
curl -sL http://132.186.17.22:9091/scan | bash

# Scan a specific image
curl -sL http://132.186.17.22:9091/scan | bash -s -- --image catool-ns --tag 1.0.0

# Scan type options
curl -sL http://132.186.17.22:9091/scan | bash -s -- --type image-only       # Container scan only
curl -sL http://132.186.17.22:9091/scan | bash -s -- --type code-only        # Code/dependency scan
curl -sL http://132.186.17.22:9091/scan | bash -s -- --type k8s-manifests    # Kubernetes audit

# Scan ALL images in registry
curl -sL http://132.186.17.22:9091/scan | bash -s -- --scan-registry

# List images available for scanning
curl -sL http://132.186.17.22:9091/scan | bash -s -- --list-images

# View recent scan history
curl -sL http://132.186.17.22:9091/scan | bash -s -- --history

# Check server status
curl -sL http://132.186.17.22:9091/scan | bash -s -- --status

# Save reports to custom location
curl -sL http://132.186.17.22:9091/scan | bash -s -- --output /path/to/reports

# Get JSON summary (for scripts/CI)
curl -sL http://132.186.17.22:9091/scan | bash -s -- --json --quiet
```

### Save Locally for Repeated Use

```bash
# Download once
curl -sL http://132.186.17.22:9091/scan -o scan.sh

# Run anytime
bash scan.sh
bash scan.sh --image catool --tag latest
bash scan.sh --type k8s-manifests
bash scan.sh --list-images
```

### What Happens When You Run It

```
Your Machine                          Central Server (132.186.17.22)
─────────────                         ──────────────────────────────
                                      
1. curl downloads client script ───►  HTTP server (port 9091)
                                      
2. Script triggers scan via API ───►  Jenkins (port 32000)
                                          │
3. Console output streams back  ◄───  Jenkins runs pipeline on agent
                                          │ Trivy, Grype, Hadolint,
                                          │ ShellCheck, Kubesec, OWASP
                                          │
4. Reports download to your     ◄───  Pipeline generates reports
   local ./security-reports-*/            (HTML, JSON, TXT)
                                      
5. HTML report opens in browser        Scan complete, results archived
```

### Report Files You Get

| File | Description |
|------|-------------|
| `security-report.html` | Consolidated dashboard with all findings |
| `trivy-fs-scan.json/txt` | Filesystem vulnerability scan |
| `trivy-image-scan.json/txt` | Container image vulnerabilities |
| `trivy-sca.json/txt` | Software composition analysis |
| `trivy-k8s-config.json/txt` | Kubernetes config issues |
| `secret-scan.json/txt` | Detected secrets/credentials |
| `grype-sca.json/txt` | Grype dependency vulnerabilities |
| `shellcheck.json` | Shell script issues |
| `full-console-log.txt` | Complete pipeline console output |

### User Isolation

Each scan is completely isolated:
- **Unique Scan ID**: `username-hostname-timestamp` (e.g., `john-laptop01-1711411200`)
- **Separate reports**: Each run saves to a timestamped directory
- **No conflicts**: Multiple users can scan simultaneously
- **No side effects**: Your scans don't affect other users

---

## For Admins (One-Time Setup)

The admin sets up everything ONCE. Users never touch this.

### Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                    CENTRAL SERVER (132.186.17.22)                │
│                                                                  │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────────────┐  │
│  │ HTTP Server  │  │   Jenkins    │  │   Container Registry   │  │
│  │ Port 9091    │  │  Port 32000  │  │      Port 5000         │  │
│  │              │  │              │  │                        │  │
│  │ Serves       │  │ Pipeline +   │  │ catool, catool-ns,     │  │
│  │ client       │  │ Agent runs   │  │ catool-ui, postgres,   │  │
│  │ script       │  │ all scans    │  │ rabbitmq, ubuntu       │  │
│  └──────┬───────┘  └──────┬───────┘  └────────────────────────┘  │
│         │                 │                                      │
│         │    ┌────────────┴────────────────┐                     │
│         │    │     Security Tools          │                     │
│         │    │  Trivy, Grype, Hadolint,    │                     │
│         │    │  ShellCheck, Kubesec, OWASP │                     │
│         │    └─────────────────────────────┘                     │
└─────────┼────────────────────────────────────────────────────────┘
          │
          │  curl http://132.186.17.22:9091/scan | bash
          │
┌─────────┴──────────┐  ┌──────────────────┐  ┌──────────────────┐
│  User A (laptop)   │  │  User B (desktop) │  │  User C (CI/CD)  │
│  Just curl + bash  │  │  Just curl + bash │  │  Just curl + bash│
│  Reports saved     │  │  Reports saved    │  │  JSON output     │
│  locally           │  │  locally          │  │  for automation   │
└────────────────────┘  └──────────────────┘  └──────────────────┘
```

### Setup Steps (Run Once)

#### 1. Jenkins + Pipeline (Already Done)

The Jenkins server, agent, and security-scan-pipeline are already deployed and running.

#### 2. Start the Client Distribution Server

```bash
# On the central server (132.186.17.22):
bash serve-scan-client.sh
```

This:
- Copies `security-scan-client.sh` to `/opt/scan-client-server/scan`
- Creates a landing page at `http://132.186.17.22:9091/`
- Creates a systemd service for auto-start on reboot

#### 3. Verify

```bash
# Test the distribution endpoint
curl -s http://132.186.17.22:9091/scan | head -5

# Test a scan
curl -sL http://132.186.17.22:9091/scan | bash -s -- --status
```

#### 4. Share with Team

Send ONE line to your team:

```
To run a security scan, execute:
curl -sL http://132.186.17.22:9091/scan | bash
```

Or share the landing page URL: `http://132.186.17.22:9091/`

### Service Endpoints

| Service | URL | Purpose |
|---------|-----|---------|
| Client Download | `http://132.186.17.22:9091/scan` | Script distribution |
| Landing Page | `http://132.186.17.22:9091/` | Documentation for users |
| Jenkins UI | `http://132.186.17.22:32000` | Pipeline management |
| Registry | `http://132.186.17.22:5000` | Container images |
| Registry UI | `http://132.186.17.22:8080` | Browse images |

### Troubleshooting

| Issue | Fix |
|-------|-----|
| "Cannot connect to scan server" | Check network/VPN. Run: `ping 132.186.17.22` |
| "Failed to trigger scan" | Pipeline job may not exist. Check Jenkins UI |
| "No artifacts found" | Agent may be offline. Run: `curl ... \| bash -s -- --status` |
| Slow scan | First run downloads vulnerability DBs. Subsequent runs are faster |
| Port blocked | Ensure firewall allows 9091, 32000, 5000 |
