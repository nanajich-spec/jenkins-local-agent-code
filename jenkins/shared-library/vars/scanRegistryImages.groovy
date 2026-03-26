// =============================================================================
// vars/scanRegistryImages.groovy — Scan All Images in Local Registry
// =============================================================================

def call(Map config = [:]) {
    def registry  = config.get('registry', '132.186.17.22:5000')
    def severity  = config.get('severity', 'CRITICAL,HIGH')
    def reportDir = config.get('reportDir', 'security-reports')

    sh "mkdir -p ${reportDir}"

    echo "=== Scanning all images in registry: ${registry} ==="

    sh """
        CATALOG=\$(curl -s http://${registry}/v2/_catalog | \
            python3 -c "import sys,json; print('\\n'.join(json.load(sys.stdin).get('repositories',[])))" 2>/dev/null)

        echo "Repositories found:"
        echo "\${CATALOG}"

        for REPO in \${CATALOG}; do
            TAGS=\$(curl -s "http://${registry}/v2/\${REPO}/tags/list" | \
                python3 -c "import sys,json; tags=json.load(sys.stdin).get('tags',[]); print('\\n'.join(tags if tags else []))" 2>/dev/null)
            for TAG in \${TAGS}; do
                FULL="${registry}/\${REPO}:\${TAG}"
                echo "--- Scanning: \${FULL} ---"
                SAFE=\$(echo "\${REPO}-\${TAG}" | tr '/:' '-')
                trivy image --podman-host "" \
                    --severity ${severity} \
                    --format json \
                    --output "${reportDir}/registry-\${SAFE}.json" \
                    "\${FULL}" || true
                trivy image --podman-host "" \
                    --severity ${severity} \
                    --format table \
                    "\${FULL}" | tee -a "${reportDir}/registry-scan-all.txt" || true
            done
        done
    """

    return true
}
