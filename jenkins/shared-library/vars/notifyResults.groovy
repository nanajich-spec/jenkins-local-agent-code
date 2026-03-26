// =============================================================================
// vars/notifyResults.groovy — Pipeline Notification (Slack + Email)
// =============================================================================
// Usage:
//   notifyResults(status: 'SUCCESS', channel: '#builds')
//   notifyResults(status: 'FAILURE', email: 'team@example.com')
// =============================================================================

def call(Map config = [:]) {
    def status   = config.get('status', currentBuild.currentResult ?: 'UNKNOWN')
    def channel  = config.get('channel', '')
    def email    = config.get('email', '')
    def webhook  = config.get('webhookCredential', 'slack-webhook')

    def colorMap = [
        'SUCCESS':  '#2eb886',
        'UNSTABLE': '#daa038',
        'FAILURE':  '#a30200',
        'ABORTED':  '#808080'
    ]
    def color = colorMap.get(status, '#808080')

    def summary = """
Pipeline: ${env.JOB_NAME} #${env.BUILD_NUMBER}
Status: ${status}
Branch: ${env.GIT_BRANCH ?: 'N/A'}
Duration: ${currentBuild.durationString}
URL: ${env.BUILD_URL}
"""

    // Slack notification
    if (channel) {
        try {
            withCredentials([string(credentialsId: webhook, variable: 'SLACK_URL')]) {
                def payload = """{"channel":"${channel}","attachments":[{"color":"${color}","text":"${summary.replaceAll('\n','\\\\n')}"}]}"""
                sh "curl -s -X POST -H 'Content-Type: application/json' -d '${payload}' \"\${SLACK_URL}\" || true"
            }
            echo "Slack notification sent to ${channel}"
        } catch (Exception e) {
            echo "Slack notification failed: ${e.message}"
        }
    }

    // Email notification
    if (email) {
        try {
            emailext(
                subject: "[Jenkins] ${status}: ${env.JOB_NAME} #${env.BUILD_NUMBER}",
                body: summary,
                to: email,
                mimeType: 'text/plain'
            )
            echo "Email sent to ${email}"
        } catch (Exception e) {
            echo "Email notification failed: ${e.message}"
        }
    }
}
