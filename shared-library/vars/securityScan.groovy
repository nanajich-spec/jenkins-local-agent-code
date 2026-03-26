// =============================================================================
// vars/securityScan.groovy — Jenkins Shared Library: Security Scan Orchestrator
// =============================================================================
// Usage in Jenkinsfile:
//   @Library('security-pipeline') _
//   securityScan(image: 'catool', tag: 'latest', registry: '132.186.17.22:5000')
// =============================================================================

def call(Map config = [:]) {
    def registry    = config.get('registry', '132.186.17.22:5000')
    def imageName   = config.get('image', '')
    def imageTag    = config.get('tag', 'latest')
    def severity    = config.get('severity', 'CRITICAL,HIGH')
    def reportsDir  = config.get('reportsDir', 'security-reports')
    def failOnCrit  = config.get('failOnCritical', true)

    def fullImage = "${registry}/${imageName}:${imageTag}"

    echo "=== Security Scan: ${fullImage} ==="

    sh "mkdir -p ${reportsDir}"

    // Image vulnerability scan
    if (imageName) {
        echo "--- Trivy Image Scan ---"
        sh """
            trivy image --podman-host "" \
                --severity ${severity} \
                --format json \
                --output ${reportsDir}/trivy-image-${imageName}.json \
                ${fullImage} || true

            trivy image --podman-host "" \
                --severity ${severity} \
                --format table \
                ${fullImage} | tee ${reportsDir}/trivy-image-${imageName}.txt || true
        """
    }

    // Filesystem scan
    echo "--- Trivy Filesystem Scan ---"
    sh """
        trivy fs --scanners vuln,misconfig,secret \
            --severity ${severity} \
            --format json \
            --output ${reportsDir}/trivy-fs.json \
            . || true
    """

    // K8s config scan
    if (fileExists('cat-deployments')) {
        echo "--- K8s Manifest Config Scan ---"
        sh """
            trivy config \
                --severity ${severity} \
                --format json \
                --output ${reportsDir}/trivy-k8s-config.json \
                cat-deployments/ || true
        """
    }

    // Parse results and evaluate gate
    def criticalCount = sh(script: """
        if [ -f "${reportsDir}/trivy-image-${imageName}.json" ]; then
            python3 -c "
import json, sys
with open('${reportsDir}/trivy-image-${imageName}.json') as f:
    data = json.load(f)
count = sum(1 for r in data.get('Results',[]) for v in r.get('Vulnerabilities',[]) if v.get('Severity')=='CRITICAL')
print(count)
" 2>/dev/null
        else
            echo 0
        fi
    """, returnStdout: true).trim().toInteger()

    echo "Critical vulnerabilities found: ${criticalCount}"

    if (criticalCount > 0 && failOnCrit) {
        unstable("${criticalCount} CRITICAL vulnerabilities detected")
    }

    return criticalCount
}
