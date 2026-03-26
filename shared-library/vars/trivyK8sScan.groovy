// =============================================================================
// vars/trivyK8sScan.groovy — Trivy Kubernetes Config & Cluster Scanner
// =============================================================================

def call(Map config = [:]) {
    def manifestsDir = config.get('manifestsDir', 'cat-deployments')
    def severity     = config.get('severity', 'CRITICAL,HIGH')
    def reportDir    = config.get('reportDir', 'security-reports')
    def clusterScan  = config.get('clusterScan', false)

    sh "mkdir -p ${reportDir}"

    // K8s manifest misconfiguration scan
    if (fileExists(manifestsDir)) {
        echo "=== Trivy K8s Config Scan: ${manifestsDir} ==="
        sh """
            trivy config \
                --severity ${severity} \
                --format json \
                --output "${reportDir}/trivy-k8s-config.json" \
                "${manifestsDir}" || true

            trivy config \
                --severity ${severity} \
                --format table \
                "${manifestsDir}" | tee "${reportDir}/trivy-k8s-config.txt" || true
        """
    }

    // Live cluster scan (optional)
    if (clusterScan) {
        echo "=== Trivy Kubernetes Cluster Audit ==="
        sh """
            trivy k8s --report summary \
                --severity ${severity} \
                --format json \
                --output "${reportDir}/trivy-k8s-cluster.json" \
                cluster 2>/dev/null || echo "Cluster scan skipped"
        """
    }

    return true
}
