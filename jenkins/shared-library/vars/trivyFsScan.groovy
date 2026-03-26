// =============================================================================
// vars/trivyFsScan.groovy — Trivy Filesystem Vulnerability & Misconfig Scanner
// =============================================================================

def call(Map config = [:]) {
    def scanPath   = config.get('path', '.')
    def severity   = config.get('severity', 'CRITICAL,HIGH')
    def scanners   = config.get('scanners', 'vuln,misconfig,secret')
    def reportDir  = config.get('reportDir', 'security-reports')

    sh "mkdir -p ${reportDir}"

    echo "=== Trivy Filesystem Scan: ${scanPath} ==="

    sh """
        trivy fs --scanners ${scanners} \
            --severity ${severity} \
            --format json \
            --output "${reportDir}/trivy-fs-scan.json" \
            "${scanPath}" || true

        trivy fs --scanners ${scanners} \
            --severity ${severity} \
            --format table \
            "${scanPath}" | tee "${reportDir}/trivy-fs-scan.txt" || true
    """

    return true
}
