// =============================================================================
// vars/unifiedPrePushScan.groovy — Adapter-driven unified pre-push orchestration
// =============================================================================
// Usage:
//   unifiedPrePushScan(
//       scriptPath: "${WORKSPACE}/jenkins/scripts/unified_prepush_scan.py",
//       projectPath: WORKSPACE,
//       mode: params.UNIFIED_SCAN_MODE,
//       strictMode: params.STRICT_MODE,
//       outputDir: "${REPORTS_DIR}/unified"
//   )
// =============================================================================

def call(Map config = [:]) {
    def scriptPath = config.get('scriptPath', 'jenkins/scripts/unified_prepush_scan.py')
    def projectPath = config.get('projectPath', '.')
    def mode = config.get('mode', 'code-only')
    def strictMode = config.get('strictMode', false)
    def outputDir = config.get('outputDir', 'security-reports/unified')
    def coverageThreshold = config.get('coverageThreshold', '70')
    def runSonar = config.get('runSonar', false)
    def runTrivy = config.get('runTrivy', true)
    def generateSbom = config.get('generateSbom', true)
    def imageName = config.get('imageName', '')
    def imageTag = config.get('imageTag', 'latest')
    def registry = config.get('registry', '132.186.17.22:5000')

    sh "mkdir -p '${outputDir}'"

    def args = [
        "--path '${projectPath}'",
        "--mode '${mode}'",
        "--output-dir '${outputDir}'",
        "--coverage-threshold '${coverageThreshold}'",
        "--image-name '${imageName}'",
        "--image-tag '${imageTag}'",
        "--registry '${registry}'"
    ]

    if (strictMode) {
        args << '--strict'
    }
    if (runSonar) {
        args << '--run-sonar'
    }
    if (!runTrivy) {
        args << '--no-trivy'
    }
    if (!generateSbom) {
        args << '--no-sbom'
    }

    def cmd = "python3 '${scriptPath}' ${args.join(' ')}"
    def rc = sh(script: cmd, returnStatus: true)

    // Try to locate latest final-report.json in outputDir and return parsed gate summary
    def reportPath = sh(
        script: "ls -1dt '${outputDir}'/scan-*/final-report.json 2>/dev/null | head -1",
        returnStdout: true
    ).trim()

    if (!reportPath) {
        return [status: rc == 0 ? 'PASS' : 'FAIL', gate: 'UNKNOWN', reportPath: null]
    }

    def gate = sh(
        script: "python3 -c \"import json; d=json.load(open('${reportPath}')); print(d.get('summary',{}).get('gate_verdict',{}).get('status','UNKNOWN'))\"",
        returnStdout: true
    ).trim()

    return [
        status: rc == 0 ? 'PASS' : 'FAIL',
        gate: gate,
        reportPath: reportPath,
    ]
}
