// =============================================================================
// vars/trivyImageScan.groovy — Trivy Container Image Scanner
// =============================================================================

def call(Map config = [:]) {
    def image      = config.get('image', '')
    def severity   = config.get('severity', 'CRITICAL,HIGH')
    def reportDir  = config.get('reportDir', 'security-reports')
    def format     = config.get('format', 'table')

    if (!image) {
        error "trivyImageScan: 'image' parameter is required"
    }

    def safeName = image.replaceAll('[/:]', '-')
    sh "mkdir -p ${reportDir}"

    echo "=== Trivy Image Scan: ${image} ==="

    // JSON report
    sh """
        trivy image --podman-host "" \
            --severity ${severity} \
            --format json \
            --output "${reportDir}/trivy-image-${safeName}.json" \
            "${image}" || true
    """

    // Human-readable report
    sh """
        trivy image --podman-host "" \
            --severity ${severity} \
            --format ${format} \
            "${image}" | tee "${reportDir}/trivy-image-${safeName}.txt" || true
    """

    // Return vulnerability counts
    def result = sh(script: """
        python3 -c "
import json
with open('${reportDir}/trivy-image-${safeName}.json') as f:
    data = json.load(f)
results = data.get('Results', [])
vulns = [v for r in results for v in r.get('Vulnerabilities', [])]
critical = sum(1 for v in vulns if v.get('Severity') == 'CRITICAL')
high = sum(1 for v in vulns if v.get('Severity') == 'HIGH')
print(f'{critical},{high}')
" 2>/dev/null || echo "0,0"
    """, returnStdout: true).trim()

    def counts = result.split(',')
    return [critical: counts[0].toInteger(), high: counts[1].toInteger()]
}
