// =============================================================================
// vars/dockerBuild.groovy — Container Image Build & Push
// =============================================================================
// Usage:
//   dockerBuild(image: 'myapp', tag: 'v1.0', registry: '132.186.17.22:5000')
// =============================================================================

def call(Map config = [:]) {
    def image      = config.get('image', '')
    def tag        = config.get('tag', 'latest')
    def registry   = config.get('registry', '132.186.17.22:5000')
    def dockerfile = config.get('dockerfile', 'Dockerfile')
    def context    = config.get('context', '.')
    def push       = config.get('push', true)
    def insecure   = config.get('insecure', true)

    if (!image) {
        error "dockerBuild: 'image' parameter is required"
    }

    def fullImage = "${registry}/${image}:${tag}"
    def tlsFlag = insecure ? '--tls-verify=false' : ''

    echo "=== Docker Build: ${fullImage} ==="

    sh """
        if command -v podman &>/dev/null; then
            podman build -t "${fullImage}" -f "${dockerfile}" "${context}"
        elif command -v docker &>/dev/null; then
            docker build -t "${fullImage}" -f "${dockerfile}" "${context}"
        else
            echo "ERROR: Neither podman nor docker found"
            exit 1
        fi
    """

    if (push) {
        echo "=== Pushing: ${fullImage} ==="
        sh """
            if command -v podman &>/dev/null; then
                podman push "${fullImage}" ${tlsFlag}
            else
                docker push "${fullImage}"
            fi
        """
    }

    echo "Image built and pushed: ${fullImage}"
    return fullImage
}
