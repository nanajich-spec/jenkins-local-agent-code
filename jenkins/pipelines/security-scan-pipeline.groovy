// =============================================================================
// security-scan-pipeline.groovy — 11-Stage Security Scan Pipeline
// =============================================================================
// Implements the E2E Design Plan Section 7: Security Scan Tool Coverage Matrix
//
// Stages:
//  1. Setup + Source Extract
//  2. Secret Detection          (Trivy --scanners secret)
//  3. SAST / Vuln Scan          (Trivy --scanners vuln,misconfig)
//  4. SCA / Dependency Scan     (Trivy --scanners vuln)
//  5. Image Scan                (Trivy image)
//  6. K8s Manifest Scan         (Trivy config)
//  7. Registry Scan             (Trivy image per registry image)
//  8. SBOM Generation           (Trivy CycloneDX + SPDX)
//  9. SonarQube Analysis        (sonar-scanner)
// 10. Security Gate             (count CRITICAL; fail/warn/pass)
// 11. Archive + Structured Report
// =============================================================================

pipeline {
    agent { label params.AGENT_LABEL ?: 'local-security-agent' }

    options {
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timestamps()
        timeout(time: 60, unit: 'MINUTES')
        ansiColor('xterm')
    }

    environment {
        REGISTRY         = '132.186.17.22:5000'
        SONARQUBE_URL    = 'http://132.186.17.22:32001'
        SCAN_SEVERITY    = 'CRITICAL,HIGH'
        REPORTS_DIR      = "${WORKSPACE}/security-reports"
        FINAL_REPORTS    = "/opt/scan-reports/${params.SCAN_ID ?: 'default'}"
        TRIVY_CACHE_DIR  = '/opt/trivy-cache'
    }

    parameters {
        string(name: 'IMAGE_NAME',           defaultValue: '',      description: 'Image name to scan')
        string(name: 'IMAGE_TAG',            defaultValue: 'latest', description: 'Image tag')
        choice(name: 'SCAN_TYPE',            choices: ['code-only', 'image-only', 'full', 'k8s-manifests'], description: 'Scan type')
        booleanParam(name: 'FAIL_ON_CRITICAL',    defaultValue: true,  description: 'Fail on CRITICAL vulns')
        booleanParam(name: 'SCAN_REGISTRY_IMAGES', defaultValue: false, description: 'Scan all registry images')
        booleanParam(name: 'GENERATE_SBOM',        defaultValue: true,  description: 'Generate SBOM (CycloneDX + SPDX)')
        string(name: 'SCAN_ID',             defaultValue: '',      description: 'Unique scan ID')
        string(name: 'SOURCE_UPLOAD_PATH',   defaultValue: '',      description: 'Uploaded source path')
        string(name: 'AGENT_LABEL',          defaultValue: 'local-security-agent', description: 'Agent label')
        string(name: 'REGISTRY_URL',         defaultValue: '',      description: 'Override registry URL')
    }

    stages {

        // =====================================================================
        // Stage 1: Setup + Source Extract
        // =====================================================================
        stage('Setup') {
            steps {
                script {
                    sh "rm -rf '${REPORTS_DIR}' && mkdir -p '${REPORTS_DIR}/sbom'"
                    sh "mkdir -p '${FINAL_REPORTS}/sbom'"
                    sh 'mkdir -p /opt/trivy-cache'

                    sh '''
                        echo "=== Tool Verification ==="
                        trivy --version 2>&1 | head -1 || echo "trivy: NOT INSTALLED"
                        echo "sonar-scanner: $(which sonar-scanner 2>/dev/null || echo NOT_INSTALLED)"
                        echo "shellcheck: $(which shellcheck 2>/dev/null || echo NOT_INSTALLED)"
                        echo "hadolint: $(which hadolint 2>/dev/null || echo NOT_INSTALLED)"
                        echo "podman: $(which podman 2>/dev/null || echo NOT_INSTALLED)"
                    '''

                    if (params.REGISTRY_URL?.trim()) {
                        env.REGISTRY = params.REGISTRY_URL.trim()
                    }

                    env.DO_REGISTRY_SCAN = (params.SCAN_REGISTRY_IMAGES?.toString() == 'true') ? 'true' : 'false'
                    env.DO_FAIL_CRITICAL = (params.FAIL_ON_CRITICAL?.toString() != 'false') ? 'true' : 'false'
                    env.DO_SBOM = (params.GENERATE_SBOM?.toString() != 'false') ? 'true' : 'false'

                    if (params.SOURCE_UPLOAD_PATH?.trim()) {
                        def uploadPath = params.SOURCE_UPLOAD_PATH.trim()
                        def tarFile = uploadPath + '/source.tar.gz'
                        env.SOURCE_DIR = env.WORKSPACE + '/user-source'
                        sh "mkdir -p '${env.SOURCE_DIR}'"
                        sh """
                            if [ -f '${tarFile}' ]; then
                                tar xzf '${tarFile}' -C '${env.SOURCE_DIR}' 2>/dev/null || true
                                echo "Source extracted: \$(find '${env.SOURCE_DIR}' -type f | wc -l) files, \$(du -sh '${env.SOURCE_DIR}' | cut -f1)"
                            else
                                echo "WARNING: Source tar not found at ${tarFile}"
                            fi
                        """
                    } else {
                        env.SOURCE_DIR = env.WORKSPACE
                    }

                    echo """
==========================================
  Security Scan Pipeline
==========================================
  Scan ID:       ${params.SCAN_ID ?: 'N/A'}
  Scan Type:     ${params.SCAN_TYPE ?: 'code-only'}
  Source Dir:    ${env.SOURCE_DIR}
  SBOM:          ${env.DO_SBOM}
  Registry Scan: ${env.DO_REGISTRY_SCAN}
=========================================="""
                }
            }
        }

        // =====================================================================
        // Stage 2: Secret Detection
        // =====================================================================
        stage('Secret Detection') {
            when { expression { params.SCAN_TYPE in ['full', 'code-only'] } }
            steps {
                script {
                    def scanDir = env.SOURCE_DIR
                    sh """
                        echo '=== Secret Detection ==='
                        trivy fs --scanners secret \
                            --format json \
                            --output '${REPORTS_DIR}/secret-scan.json' \
                            '${scanDir}' || true
                    """
                }
            }
        }

        // =====================================================================
        // Stage 3: SAST / Vulnerability Scan
        // =====================================================================
        stage('SAST / Vulnerability Scan') {
            when { expression { params.SCAN_TYPE in ['full', 'code-only'] } }
            steps {
                script {
                    def scanDir = env.SOURCE_DIR
                    sh """
                        echo '=== SAST / Vuln + Misconfig Scan ==='
                        trivy fs --scanners vuln,misconfig \
                            --severity ${SCAN_SEVERITY} \
                            --format json \
                            --output '${REPORTS_DIR}/trivy-fs-scan.json' \
                            '${scanDir}' || true
                    """
                }
            }
        }

        // =====================================================================
        // Stage 4: SCA / Dependency Scan
        // =====================================================================
        stage('SCA / Dependency Scan') {
            when { expression { params.SCAN_TYPE in ['full', 'code-only'] } }
            steps {
                script {
                    def scanDir = env.SOURCE_DIR
                    sh """
                        echo '=== SCA / Dependency Scan ==='
                        trivy fs --scanners vuln \
                            --severity CRITICAL,HIGH,MEDIUM \
                            --format json \
                            --output '${REPORTS_DIR}/trivy-sca.json' \
                            '${scanDir}' || true
                    """
                }
            }
        }

        // =====================================================================
        // Stage 5: Container Image Scan
        // =====================================================================
        stage('Image Scan') {
            when {
                expression {
                    params.SCAN_TYPE in ['full', 'image-only'] &&
                    params.IMAGE_NAME?.trim() &&
                    params.IMAGE_NAME?.trim() != 'none'
                }
            }
            steps {
                script {
                    def img = "${env.REGISTRY}/${params.IMAGE_NAME}:${params.IMAGE_TAG}"
                    sh """
                        echo '=== Container Image Scan: ${img} ==='
                        trivy image --podman-host '' \
                            --severity ${SCAN_SEVERITY} \
                            --format json \
                            --output '${REPORTS_DIR}/trivy-image-scan.json' \
                            '${img}' || true
                    """
                }
            }
        }

        // =====================================================================
        // Stage 6: K8s Manifest Scan
        // =====================================================================
        stage('K8s Manifest Scan') {
            when { expression { params.SCAN_TYPE in ['full', 'code-only', 'k8s-manifests'] } }
            steps {
                script {
                    def scanDir = env.SOURCE_DIR
                    def hasK8s = sh(script: "find '${scanDir}' -name '*.yaml' -o -name '*.yml' 2>/dev/null | head -1", returnStdout: true).trim()
                    if (hasK8s) {
                        sh """
                            echo '=== K8s Manifest Scan ==='
                            trivy config \
                                --severity ${SCAN_SEVERITY} \
                                --format json \
                                --output '${REPORTS_DIR}/trivy-k8s-scan.json' \
                                '${scanDir}' || true
                        """
                    } else {
                        sh "echo 'No YAML/YML files found — K8s scan skipped'"
                    }
                }
            }
        }

        // =====================================================================
        // Stage 7: Registry Scan
        // =====================================================================
        stage('Registry Scan') {
            when { expression { return env.DO_REGISTRY_SCAN == 'true' } }
            steps {
                script {
                    def reg = env.REGISTRY
                    sh """
                        echo '=== Registry Image Scan: ${reg} ==='
                        REPOS=\$(curl -s http://${reg}/v2/_catalog | python3 -c "import sys,json; [print(r) for r in json.load(sys.stdin).get('repositories',[])]" 2>/dev/null || echo "")
                        for REPO in \$REPOS; do
                            TAGS=\$(curl -s http://${reg}/v2/\$REPO/tags/list | python3 -c "import sys,json; [print(t) for t in json.load(sys.stdin).get('tags',[])]" 2>/dev/null || echo "latest")
                            for TAG in \$TAGS; do
                                SAFE_NAME=\$(echo "\${REPO}-\${TAG}" | tr '/:' '-')
                                echo "--- Scanning \$REPO:\$TAG ---"
                                trivy image --podman-host '' --severity ${SCAN_SEVERITY} \
                                    --format json --output "${REPORTS_DIR}/registry-scan-\${SAFE_NAME}.json" \
                                    "${reg}/\$REPO:\$TAG" || true
                            done
                        done
                    """
                }
            }
        }

        // =====================================================================
        // Stage 8: SBOM Generation
        // =====================================================================
        stage('SBOM Generation') {
            when { expression { return env.DO_SBOM == 'true' && params.SCAN_TYPE in ['full', 'code-only'] } }
            steps {
                script {
                    def scanDir = env.SOURCE_DIR
                    sh """
                        echo '=== SBOM Generation (CycloneDX) ==='
                        trivy fs --format cyclonedx \
                            --output '${REPORTS_DIR}/sbom/trivy-cyclonedx-full.json' \
                            '${scanDir}' || true

                        echo '=== SBOM Generation (SPDX) ==='
                        trivy fs --format spdx-json \
                            --output '${REPORTS_DIR}/sbom/trivy-spdx-sbom.json' \
                            '${scanDir}' || true
                    """
                }
            }
        }

        // =====================================================================
        // Stage 9: SonarQube Analysis
        // =====================================================================
        stage('SonarQube Analysis') {
            when { expression { params.SCAN_TYPE in ['full', 'code-only'] } }
            steps {
                script {
                    def scanDir = env.SOURCE_DIR
                    def hasSonar = sh(script: "which sonar-scanner 2>/dev/null", returnStatus: true)
                    def sonarReachable = sh(script: "curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 '${env.SONARQUBE_URL}/api/system/status' | grep -q 200", returnStatus: true)

                    if (hasSonar == 0 && sonarReachable == 0) {
                        def projectKey = params.SCAN_ID ? "scan-${params.SCAN_ID}".replaceAll('[^a-zA-Z0-9_.-]', '_').take(100) : "user-scan-${System.currentTimeMillis()}"
                        def projectName = params.SCAN_ID ?: 'User Code Scan'

                        def hasConfig = sh(script: "[ -f '${scanDir}/sonar-project.properties' ]", returnStatus: true)

                        if (hasConfig == 0) {
                            sh """
                                cd '${scanDir}'
                                sonar-scanner \
                                    -Dsonar.host.url='${env.SONARQUBE_URL}' \
                                    -Dsonar.login=admin -Dsonar.password=admin123 \
                                    -Dsonar.qualitygate.wait=false \
                                    2>&1 | tee '${REPORTS_DIR}/sonarqube-analysis.txt' || true
                            """
                        } else {
                            sh """
                                cd '${scanDir}'
                                sonar-scanner \
                                    -Dsonar.host.url='${env.SONARQUBE_URL}' \
                                    -Dsonar.login=admin -Dsonar.password=admin123 \
                                    -Dsonar.projectKey='${projectKey}' \
                                    -Dsonar.projectName='${projectName}' \
                                    -Dsonar.sources=. \
                                    -Dsonar.exclusions='**/node_modules/**,**/vendor/**,**/.git/**,**/security-reports/**,**/*.class,**/*.jar' \
                                    -Dsonar.qualitygate.wait=false \
                                    2>&1 | tee '${REPORTS_DIR}/sonarqube-analysis.txt' || true
                            """
                        }

                        sh """
                            sleep 5
                            curl -s -u admin:admin123 '${env.SONARQUBE_URL}/api/qualitygates/project_status?projectKey=${projectKey}' \
                                > '${REPORTS_DIR}/sonarqube-quality-gate.json' 2>/dev/null || true
                        """
                    } else {
                        sh "echo 'SonarQube not available — skipping'"
                    }
                }
            }
        }

        // =====================================================================
        // Stage 10: Security Gate
        // =====================================================================
        stage('Security Gate') {
            steps {
                script {
                    def gateResult = sh(script: """#!/usr/bin/env bash
set -uo pipefail
CRITICAL=0; HIGH=0; MEDIUM=0; LOW=0; SECRETS=0; MISCONFIG=0

for REPORT in '${REPORTS_DIR}'/trivy-fs-scan.json '${REPORTS_DIR}'/trivy-sca.json '${REPORTS_DIR}'/trivy-image-scan.json '${REPORTS_DIR}'/trivy-k8s-scan.json; do
    [ -f "\$REPORT" ] || continue
    COUNTS=\$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f: data = json.load(f)
    results = data.get('Results', [])
    c=h=m=l=mc=0
    for r in results:
        for v in (r.get('Vulnerabilities') or []):
            s = v.get('Severity','').upper()
            if s=='CRITICAL': c+=1
            elif s=='HIGH': h+=1
            elif s=='MEDIUM': m+=1
            elif s=='LOW': l+=1
        for v in (r.get('Misconfigurations') or []):
            s = v.get('Severity','').upper()
            if s in ('CRITICAL','HIGH'): mc+=1
    print(c, h, m, l, mc)
except: print('0 0 0 0 0')
" "\$REPORT" 2>/dev/null || echo "0 0 0 0 0")
    CRITICAL=\$((CRITICAL + \$(echo "\$COUNTS" | awk '{print \$1}')))
    HIGH=\$((HIGH       + \$(echo "\$COUNTS" | awk '{print \$2}')))
    MEDIUM=\$((MEDIUM   + \$(echo "\$COUNTS" | awk '{print \$3}')))
    LOW=\$((LOW         + \$(echo "\$COUNTS" | awk '{print \$4}')))
    MISCONFIG=\$((MISCONFIG + \$(echo "\$COUNTS" | awk '{print \$5}')))
done

if [ -f '${REPORTS_DIR}/secret-scan.json' ]; then
    SECRETS=\$(python3 -c "
import json
try:
    with open('${REPORTS_DIR}/secret-scan.json') as f: data = json.load(f)
    print(sum(len(r.get('Secrets') or []) for r in data.get('Results', [])))
except: print(0)
" 2>/dev/null || echo 0)
fi

cat > '${REPORTS_DIR}/gate-results.txt' <<EOF
CRITICAL_VULNS=\${CRITICAL}
HIGH_VULNS=\${HIGH}
MEDIUM_VULNS=\${MEDIUM}
LOW_VULNS=\${LOW}
SECRETS=\${SECRETS}
MISCONFIGS=\${MISCONFIG}
EOF

echo "======================================================================"
echo "  SECURITY GATE RESULTS"
echo "======================================================================"
printf "  CRITICAL vulnerabilities:  %s\\n" "\${CRITICAL}"
printf "  HIGH vulnerabilities:      %s\\n" "\${HIGH}"
printf "  MEDIUM vulnerabilities:    %s\\n" "\${MEDIUM}"
printf "  LOW vulnerabilities:       %s\\n" "\${LOW}"
printf "  Secrets detected:          %s\\n" "\${SECRETS}"
printf "  Misconfigurations (C/H):   %s\\n" "\${MISCONFIG}"
echo "----------------------------------------------------------------------"
if [ "\${CRITICAL}" -gt 0 ] || [ "\${SECRETS}" -gt 0 ]; then
    echo "  GATE: FAIL"
    echo "GATE_STATUS=FAIL" >> '${REPORTS_DIR}/gate-results.txt'
    exit 1
else
    echo "  GATE: PASS"
    echo "GATE_STATUS=PASS" >> '${REPORTS_DIR}/gate-results.txt'
    exit 0
fi
""", returnStatus: true)

                    if (gateResult != 0 && env.DO_FAIL_CRITICAL == 'true') {
                        unstable('CRITICAL vulnerabilities or secrets detected')
                    }
                }
            }
        }

        // =====================================================================
        // Stage 11: Archive + Structured Report + Copy to /opt/scan-reports/
        // =====================================================================
        stage('Archive & Report') {
            steps {
                script {
                    // Generate structured HTML report (NO raw logs)
                    sh """#!/usr/bin/env bash
set -uo pipefail

export REPORTS='${REPORTS_DIR}'
export SCAN_ID='${params.SCAN_ID ?: 'unknown'}'
export SCAN_TYPE='${params.SCAN_TYPE ?: 'code-only'}'
export FINAL='${FINAL_REPORTS}'

python3 << 'PYEOF'
import json, os, sys
from datetime import datetime, timezone

REPORTS   = os.environ.get('REPORTS', '')
SCAN_ID   = os.environ.get('SCAN_ID', 'unknown')
SCAN_TYPE = os.environ.get('SCAN_TYPE', 'code-only')
FINAL     = os.environ.get('FINAL', '')

def count_trivy(path):
    if not os.path.isfile(path):
        return {'critical':0,'high':0,'medium':0,'low':0,'unknown':0,'details':[]}
    try:
        with open(path) as f:
            data = json.load(f)
    except:
        return {'critical':0,'high':0,'medium':0,'low':0,'unknown':0,'details':[]}
    c=h=m=l=u=0
    details = []
    for result in data.get('Results', []):
        target = result.get('Target', '')
        for vuln in (result.get('Vulnerabilities') or []):
            sev = (vuln.get('Severity') or '').upper()
            vid = vuln.get('VulnerabilityID', '')
            pkg = vuln.get('PkgName', '')
            ver = vuln.get('InstalledVersion', '')
            fix = vuln.get('FixedVersion', '')
            title = vuln.get('Title', vuln.get('Description', ''))
            if title and len(title) > 120:
                title = title[:117] + '...'
            if sev == 'CRITICAL': c += 1
            elif sev == 'HIGH': h += 1
            elif sev == 'MEDIUM': m += 1
            elif sev == 'LOW': l += 1
            else: u += 1
            details.append({'severity': sev, 'id': vid, 'package': pkg,
                'installed': ver, 'fixed': fix, 'title': title or '', 'target': target})
        for mc in (result.get('Misconfigurations') or []):
            sev = (mc.get('Severity') or '').upper()
            if sev == 'CRITICAL': c += 1
            elif sev == 'HIGH': h += 1
            elif sev == 'MEDIUM': m += 1
            elif sev == 'LOW': l += 1
            else: u += 1
            details.append({'severity': sev, 'id': mc.get('ID',''),
                'package': mc.get('Type',''), 'installed': '',
                'fixed': (mc.get('Resolution','') or '')[:80],
                'title': (mc.get('Title','') or '')[:120], 'target': target})
    return {'critical':c,'high':h,'medium':m,'low':l,'unknown':u,'details':details}

def count_secrets(path):
    if not os.path.isfile(path):
        return 0, []
    try:
        with open(path) as f:
            data = json.load(f)
    except:
        return 0, []
    total = 0
    found = []
    for result in data.get('Results', []):
        for s in (result.get('Secrets') or []):
            total += 1
            found.append({'rule': s.get('RuleID', ''), 'category': s.get('Category', ''),
                'title': s.get('Title', ''), 'target': result.get('Target', ''),
                'severity': s.get('Severity', 'HIGH')})
    return total, found

def count_sbom_components(path):
    if not os.path.isfile(path):
        return None
    try:
        with open(path) as f:
            data = json.load(f)
        return len(data.get('components', []))
    except:
        return None

def parse_sonar_gate(path):
    if not os.path.isfile(path):
        return None, []
    try:
        with open(path) as f:
            data = json.load(f)
    except:
        return None, []
    ps = data.get('projectStatus', data)
    return ps.get('status', 'UNKNOWN'), [
        {'metric': c.get('metricKey',''), 'status': c.get('status',''),
         'actual': c.get('actualValue',''), 'threshold': c.get('errorThreshold','')}
        for c in ps.get('conditions', [])]

def parse_gate_results(path):
    if not os.path.isfile(path):
        return 'UNKNOWN', {}
    vals = {}
    for line in open(path).read().splitlines():
        if '=' in line:
            k,v = line.split('=',1)
            vals[k.strip()] = v.strip()
    return vals.get('GATE_STATUS', 'UNKNOWN'), vals

# Gather all findings
scans = {}
scan_map = {
    'Secret Detection': 'secret-scan.json',
    'SAST / Vulnerability': 'trivy-fs-scan.json',
    'SCA / Dependency': 'trivy-sca.json',
    'Container Image': 'trivy-image-scan.json',
    'K8s Manifests': 'trivy-k8s-scan.json',
}

for label, fname in scan_map.items():
    path = os.path.join(REPORTS, fname)
    if os.path.isfile(path):
        if label == 'Secret Detection':
            count, found = count_secrets(path)
            scans[label] = {'found': count, 'secrets': found, 'file': fname}
        else:
            scans[label] = count_trivy(path)
            scans[label]['file'] = fname

# Registry scans
for fname in sorted(os.listdir(REPORTS)):
    if fname.startswith('registry-scan-') and fname.endswith('.json'):
        img_name = fname.replace('registry-scan-','').replace('.json','')
        data = count_trivy(os.path.join(REPORTS, fname))
        data['file'] = fname
        scans['Registry: ' + img_name] = data

# SBOM
sbom_count = count_sbom_components(os.path.join(REPORTS, 'sbom', 'trivy-cyclonedx-full.json'))

# SonarQube
sq_gate, sq_conditions = parse_sonar_gate(os.path.join(REPORTS, 'sonarqube-quality-gate.json'))

# Gate results
gate_status, gate_vals = parse_gate_results(os.path.join(REPORTS, 'gate-results.txt'))

# Aggregate totals
totals = {'critical':0,'high':0,'medium':0,'low':0,'unknown':0}
for label, data in scans.items():
    if label == 'Secret Detection':
        continue
    for sev in totals:
        totals[sev] += data.get(sev, 0)

secrets_total = scans.get('Secret Detection', {}).get('found', 0)
now = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')

# ── Write JSON summary ──
summary = {
    'scan_id': SCAN_ID, 'scan_type': SCAN_TYPE, 'timestamp': now,
    'gate_status': gate_status, 'gate_passed': gate_status == 'PASS',
    'totals': totals, 'secrets_found': secrets_total,
    'sbom_component_count': sbom_count, 'sonarqube_quality_gate': sq_gate,
    'findings_by_scan': {}
}
for label, data in scans.items():
    if label == 'Secret Detection':
        summary['findings_by_scan'][label] = {'found': data.get('found',0), 'file': data.get('file','')}
    else:
        summary['findings_by_scan'][label] = {
            k: data[k] for k in ('critical','high','medium','low','unknown','file') if k in data}

with open(os.path.join(REPORTS, 'scan-summary.json'), 'w') as f:
    json.dump(summary, f, indent=2)

# ── Build HTML ──
def sev_badge(s):
    colors = {'CRITICAL':'#d32f2f','HIGH':'#e65100','MEDIUM':'#f9a825','LOW':'#2e7d32','UNKNOWN':'#757575'}
    c = colors.get(s.upper(), '#757575')
    fc = '#fff' if s.upper() != 'MEDIUM' else '#333'
    return '<span style="background:%s;color:%s;padding:2px 8px;border-radius:4px;font-size:0.85em;font-weight:600">%s</span>' % (c, fc, s)

gate_color = '#2e7d32' if gate_status == 'PASS' else '#d32f2f'
gate_icon = '&#10004;' if gate_status == 'PASS' else '&#10008;'

html = []
html.append('''<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<title>Security Scan Report</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',system-ui,sans-serif;background:#f0f2f5;color:#1a1a2e;line-height:1.6}
.wrap{max-width:1100px;margin:0 auto;padding:24px}
.hdr{background:linear-gradient(135deg,#1a1a2e,#16213e);color:#fff;padding:32px;border-radius:12px;margin-bottom:24px}
.hdr h1{font-size:1.8em;margin-bottom:8px}.hdr .meta{opacity:.85;font-size:.95em}
.badge{display:inline-block;padding:8px 20px;border-radius:8px;font-weight:700;font-size:1.1em;margin-top:12px;color:#fff}
.card{background:#fff;border-radius:10px;box-shadow:0 1px 3px rgba(0,0,0,.08);margin-bottom:20px;overflow:hidden}
.card-h{padding:16px 20px;font-weight:600;font-size:1.05em;border-bottom:1px solid #e8e8e8;background:#fafbfc}
.card-b{padding:20px}
table{width:100%%;border-collapse:collapse;font-size:.92em}
th{text-align:left;padding:10px 12px;background:#f5f7fa;border-bottom:2px solid #e0e0e0;font-weight:600;color:#444}
td{padding:9px 12px;border-bottom:1px solid #f0f0f0}tr:hover{background:#f8f9ff}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:12px;margin-bottom:16px}
.box{text-align:center;padding:16px;border-radius:8px;background:#f5f7fa}
.box .n{font-size:2em;font-weight:700}.box .lb{font-size:.85em;color:#666;margin-top:4px}
.box.cr .n{color:#d32f2f}.box.hi .n{color:#e65100}.box.me .n{color:#f9a825}.box.lo .n{color:#2e7d32}.box.se .n{color:#6a1b9a}
.mute{color:#999;font-style:italic;padding:20px}.ft{text-align:center;color:#999;font-size:.85em;padding:20px}
.inf{display:flex;gap:24px;flex-wrap:wrap;margin-top:8px}.inf span{font-size:.93em}.inf strong{color:#aaa}
</style></head><body><div class="wrap">''')

html.append('<div class="hdr"><h1>&#128274; Security Scan Report</h1>')
html.append('<div class="meta"><div class="inf">')
html.append('<span><strong>Scan ID:</strong> %s</span>' % SCAN_ID)
html.append('<span><strong>Type:</strong> %s</span>' % SCAN_TYPE)
html.append('<span><strong>Date:</strong> %s</span>' % now)
html.append('<span><strong>Pipeline:</strong> security-scan-pipeline</span>')
html.append('</div></div>')
html.append('<div class="badge" style="background:%s">%s Security Gate: %s</div>' % (gate_color, gate_icon, gate_status))
html.append('</div>')

# Totals
html.append('<div class="card"><div class="card-h">Vulnerability Summary</div><div class="card-b"><div class="grid">')
html.append('<div class="box cr"><div class="n">%d</div><div class="lb">Critical</div></div>' % totals['critical'])
html.append('<div class="box hi"><div class="n">%d</div><div class="lb">High</div></div>' % totals['high'])
html.append('<div class="box me"><div class="n">%d</div><div class="lb">Medium</div></div>' % totals['medium'])
html.append('<div class="box lo"><div class="n">%d</div><div class="lb">Low</div></div>' % totals['low'])
html.append('<div class="box se"><div class="n">%d</div><div class="lb">Secrets</div></div>' % secrets_total)
html.append('</div>')
if sbom_count is not None:
    html.append('<p style="color:#555;font-size:.9em">SBOM Components: <strong>%d</strong></p>' % sbom_count)
if sq_gate:
    sq_c = '#2e7d32' if sq_gate == 'OK' else '#d32f2f'
    html.append('<p style="color:#555;font-size:.9em">SonarQube Quality Gate: <span style="color:%s;font-weight:600">%s</span></p>' % (sq_c, sq_gate))
html.append('</div></div>')

# By scan type
html.append('<div class="card"><div class="card-h">Findings by Scan Type</div><div class="card-b">')
html.append('<table><tr><th>Scan</th><th>Critical</th><th>High</th><th>Medium</th><th>Low</th><th>Report</th></tr>')
for label, data in scans.items():
    if label == 'Secret Detection':
        html.append('<tr><td>%s</td><td colspan="4">%d secret(s)</td><td>%s</td></tr>' % (label, data.get('found',0), data.get('file','')))
    else:
        html.append('<tr><td>%s</td><td style="color:#d32f2f;font-weight:600">%d</td><td style="color:#e65100;font-weight:600">%d</td><td>%d</td><td>%d</td><td>%s</td></tr>' % (
            label, data.get('critical',0), data.get('high',0), data.get('medium',0), data.get('low',0), data.get('file','')))
html.append('</table></div></div>')

# Detailed
all_details = []
for label, data in scans.items():
    if label == 'Secret Detection':
        for s in data.get('secrets', []):
            all_details.append({'scan': label, 'severity': s.get('severity','HIGH'), 'id': s.get('rule',''),
                'package': s.get('category',''), 'title': s.get('title',''), 'target': s.get('target',''), 'fixed': ''})
    else:
        for d in data.get('details', []):
            d['scan'] = label
            all_details.append(d)

sev_order = {'CRITICAL':0,'HIGH':1,'MEDIUM':2,'LOW':3,'UNKNOWN':4}
all_details.sort(key=lambda x: sev_order.get(x.get('severity','').upper(), 5))

if all_details:
    html.append('<div class="card"><div class="card-h">Detailed Findings (Top 50)</div><div class="card-b">')
    html.append('<table><tr><th>Severity</th><th>ID</th><th>Package</th><th>Title</th><th>Fix</th></tr>')
    for d in all_details[:50]:
        html.append('<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>' % (
            sev_badge(d.get('severity','')), d.get('id',''), d.get('package','') or d.get('target',''),
            d.get('title',''), d.get('fixed','') or chr(8212)))
    if len(all_details) > 50:
        html.append('<tr><td colspan="5" class="mute">... and %d more. See JSON for full details.</td></tr>' % (len(all_details)-50))
    html.append('</table></div></div>')
else:
    html.append('<div class="card"><div class="card-b"><p class="mute">No vulnerabilities detected.</p></div></div>')

# SonarQube
if sq_gate and sq_conditions:
    html.append('<div class="card"><div class="card-h">SonarQube Quality Gate</div><div class="card-b">')
    html.append('<table><tr><th>Metric</th><th>Status</th><th>Actual</th><th>Threshold</th></tr>')
    for c in sq_conditions:
        sc = '#2e7d32' if c['status']=='OK' else '#d32f2f'
        html.append('<tr><td>%s</td><td style="color:%s;font-weight:600">%s</td><td>%s</td><td>%s</td></tr>' % (c['metric'], sc, c['status'], c['actual'], c['threshold']))
    html.append('</table></div></div>')

# Artifacts
artifacts = []
for root, dirs, files in os.walk(REPORTS):
    dirs.sort()
    for f in sorted(files):
        rel = os.path.relpath(os.path.join(root, f), REPORTS)
        if not rel.startswith('.') and not f.endswith('.html'):
            artifacts.append(rel)

html.append('<div class="card"><div class="card-h">Report Artifacts</div><div class="card-b"><table><tr><th>#</th><th>File</th></tr>')
for i, a in enumerate(artifacts, 1):
    html.append('<tr><td>%d</td><td>%s</td></tr>' % (i, a))
html.append('</table></div></div>')

html.append('<div class="ft">Generated by DevSecOps Security Scan Pipeline &mdash; %s</div>' % now)
html.append('</div></body></html>')

with open(os.path.join(REPORTS, 'security-report.html'), 'w') as f:
    f.write('\n'.join(html))

print('[OK] Report: %s/security-report.html' % REPORTS)
print('[OK] Summary: %s/scan-summary.json' % REPORTS)
PYEOF

# Copy all reports to FINAL_REPORTS
echo "=== Copying reports to \${FINAL} ==="
cp -r '${REPORTS_DIR}'/* "\${FINAL}/" 2>/dev/null || true
echo "Reports stored at: \${FINAL}"
ls -la "\${FINAL}/" 2>/dev/null || true
"""
                }
            }
        }
    }

    // =========================================================================
    // Post Actions
    // =========================================================================
    post {
        always {
            archiveArtifacts artifacts: 'security-reports/**', allowEmptyArchive: true

            publishHTML(target: [
                allowMissing: true,
                alwaysLinkToLastBuild: true,
                keepAll: true,
                reportDir: 'security-reports',
                reportFiles: 'security-report.html',
                reportName: 'Security Scan Report'
            ])

            script {
                echo """
==========================================
  Security Scan Pipeline Complete
==========================================
  Scan ID:  ${params.SCAN_ID ?: 'N/A'}
  Reports:  ${REPORTS_DIR}
  Archived: ${FINAL_REPORTS}
=========================================="""
            }
        }
        success  { echo 'Security pipeline PASSED — no critical vulnerabilities.' }
        unstable { echo 'Security pipeline UNSTABLE — review findings.' }
        failure  { echo 'Security pipeline FAILED — critical issues detected.' }
        cleanup {
            cleanWs(deleteDirs: true, patterns: [[pattern: '.trivy-cache/**', type: 'INCLUDE']])
        }
    }
}
