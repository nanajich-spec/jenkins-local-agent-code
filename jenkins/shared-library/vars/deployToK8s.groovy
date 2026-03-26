// =============================================================================
// vars/deployToK8s.groovy — Kubernetes Deployment
// =============================================================================
// Usage:
//   deployToK8s(image: 'registry/app:v1', deployment: 'myapp', namespace: 'prod')
// =============================================================================

def call(Map config = [:]) {
    def image      = config.get('image', '')
    def deployment = config.get('deployment', '')
    def namespace  = config.get('namespace', 'default')
    def container  = config.get('container', deployment)
    def timeout    = config.get('timeout', '300s')
    def healthPath = config.get('healthPath', '')
    def rollback   = config.get('rollbackOnFail', true)

    if (!image || !deployment) {
        error "deployToK8s: 'image' and 'deployment' parameters are required"
    }

    echo """
    ===========================================
      Kubernetes Deployment
    ===========================================
      Image:      ${image}
      Deployment: ${deployment}
      Namespace:  ${namespace}
      Timeout:    ${timeout}
    ===========================================
    """

    // Update the container image
    def updateResult = sh(script: """
        kubectl set image deployment/${deployment} \
            ${container}=${image} \
            -n ${namespace}
    """, returnStatus: true)

    if (updateResult != 0) {
        error "Failed to update deployment image"
    }

    // Wait for rollout
    def rolloutResult = sh(script: """
        kubectl rollout status deployment/${deployment} \
            -n ${namespace} --timeout=${timeout}
    """, returnStatus: true)

    if (rolloutResult != 0) {
        echo "Rollout failed!"
        if (rollback) {
            echo "Rolling back..."
            sh "kubectl rollout undo deployment/${deployment} -n ${namespace}"
            error "Deployment failed — rolled back to previous version"
        }
        error "Deployment failed"
    }

    // Health check
    if (healthPath) {
        echo "=== Health Check ==="
        def podIP = sh(script: """
            kubectl get pods -n ${namespace} -l app=${deployment} \
                -o jsonpath='{.items[0].status.podIP}' 2>/dev/null
        """, returnStdout: true).trim()

        if (podIP) {
            sh "curl -sf http://${podIP}${healthPath} || echo 'Health check warning'"
        }
    }

    // Show final pod status
    sh "kubectl get pods -n ${namespace} -l app=${deployment}"
    echo "Deployment successful: ${image}"
}
