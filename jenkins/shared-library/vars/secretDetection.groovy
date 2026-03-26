// =============================================================================
// vars/secretDetection.groovy — Hardcoded Secret Scanner
// =============================================================================

def call(Map config = [:]) {
    def scanPath  = config.get('path', '.')
    def reportDir = config.get('reportDir', 'security-reports')
    def failOnFind = config.get('failOnFind', false)

    sh "mkdir -p ${reportDir}"

    echo "=== Secret Detection Scan ==="

    sh """
        trivy fs --scanners secret \
            --format json \
            --output "${reportDir}/secret-scan.json" \
            "${scanPath}" || true

        trivy fs --scanners secret \
            --format table \
            "${scanPath}" | tee "${reportDir}/secret-scan.txt" || true
    """

    def secretCount = sh(script: """
        python3 -c "
import json
with open('${reportDir}/secret-scan.json') as f:
    data = json.load(f)
count = sum(len(r.get('Secrets', [])) for r in data.get('Results', []))
print(count)
" 2>/dev/null || echo "0"
    """, returnStdout: true).trim().toInteger()

    echo "Secrets found: ${secretCount}"

    if (secretCount > 0 && failOnFind) {
        error("Hardcoded secrets detected! (${secretCount} findings)")
    }

    return secretCount
}
