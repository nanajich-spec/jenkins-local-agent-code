// =============================================================================
// vars/sonarQubeAnalysis.groovy — SonarQube Analysis (Multi-Language)
// =============================================================================
// Usage:
//   sonarQubeAnalysis(language: 'python', reportsDir: 'pipeline-reports')
//   sonarQubeAnalysis(language: 'java-maven', projectKey: 'my-app')
// =============================================================================

def call(Map config = [:]) {
    def language    = config.get('language', 'auto')
    def reportsDir  = config.get('reportsDir', 'pipeline-reports')
    def projectKey  = config.get('projectKey', env.JOB_NAME ?: 'default-project')
    def projectName = config.get('projectName', projectKey)
    def sonarUrl    = config.get('sonarUrl', env.SONAR_HOST_URL ?: 'http://localhost:9000')
    def sonarToken  = config.get('sonarToken', env.SONAR_TOKEN ?: '')
    def sources     = config.get('sources', '.')
    def exclusions  = config.get('exclusions', '**/node_modules/**,**/vendor/**,**/.trivy-cache/**,**/pipeline-reports/**,**/security-reports/**,**/*.yml,**/*.yaml,**/*.json')

    sh "mkdir -p '${reportsDir}/sonarqube'"

    echo """
╔══════════════════════════════════════════════════════════════╗
║        SonarQube Analysis                                    ║
╠══════════════════════════════════════════════════════════════╣
║  Language:    ${language.padRight(44)}║
║  Project:     ${projectKey.padRight(44)}║
║  Server:      ${sonarUrl.padRight(44)}║
╚══════════════════════════════════════════════════════════════╝
    """

    // Build language-specific sonar properties
    def sonarProps = buildSonarProperties(language, reportsDir, projectKey, projectName, sources, exclusions)

    // Check if SonarQube scanner is available
    def hasSonarScanner = sh(script: 'command -v sonar-scanner', returnStatus: true) == 0

    if (hasSonarScanner && sonarToken) {
        // Run SonarQube analysis
        sh """
            echo "=== Running SonarQube Scanner ==="
            sonar-scanner \
                -Dsonar.host.url="${sonarUrl}" \
                -Dsonar.login="${sonarToken}" \
                ${sonarProps} \
                -Dsonar.qualitygate.wait=true \
                -Dsonar.qualitygate.timeout=300 \
                2>&1 | tee "${reportsDir}/sonarqube/sonar-scanner-output.txt" || true
        """

        // Fetch quality gate status via API
        fetchQualityGateStatus(sonarUrl, sonarToken, projectKey, reportsDir)

    } else if (language == 'java-maven' && fileExists('pom.xml') && sonarToken) {
        // Maven sonar plugin
        sh """
            echo "=== Running SonarQube via Maven ==="
            mvn sonar:sonar \
                -Dsonar.host.url="${sonarUrl}" \
                -Dsonar.login="${sonarToken}" \
                -Dsonar.projectKey="${projectKey}" \
                -Dsonar.projectName="${projectName}" \
                -q 2>&1 | tee "${reportsDir}/sonarqube/sonar-maven-output.txt" || true
        """
        fetchQualityGateStatus(sonarUrl, sonarToken, projectKey, reportsDir)

    } else if (language == 'java-gradle' && sonarToken) {
        // Gradle sonar plugin
        sh """
            echo "=== Running SonarQube via Gradle ==="
            ./gradlew sonarqube \
                -Dsonar.host.url="${sonarUrl}" \
                -Dsonar.login="${sonarToken}" \
                -Dsonar.projectKey="${projectKey}" \
                2>/dev/null || gradle sonarqube \
                -Dsonar.host.url="${sonarUrl}" \
                -Dsonar.login="${sonarToken}" \
                -Dsonar.projectKey="${projectKey}" \
                2>/dev/null || echo "Gradle SonarQube analysis failed"
        """
        fetchQualityGateStatus(sonarUrl, sonarToken, projectKey, reportsDir)

    } else {
        echo "SonarQube scanner not available or token not configured — generating local quality report"
        generateLocalQualityReport(language, reportsDir)
    }

    echo "SonarQube analysis complete — results in ${reportsDir}/sonarqube/"
    return true
}

// =============================================================================
// Build SonarQube scanner properties per language
// =============================================================================
def buildSonarProperties(String language, String reportsDir, String projectKey, String projectName, String sources, String exclusions) {
    def props = """
        -Dsonar.projectKey="${projectKey}" \\
        -Dsonar.projectName="${projectName}" \\
        -Dsonar.sources="${sources}" \\
        -Dsonar.exclusions="${exclusions}" \\
        -Dsonar.sourceEncoding=UTF-8
    """.trim()

    switch (language) {
        case 'python':
            props += """
                -Dsonar.language=py \\
                -Dsonar.python.coverage.reportPaths="${reportsDir}/coverage.xml" \\
                -Dsonar.python.xunit.reportPath="${reportsDir}/pytest-unit-results.xml" \\
                -Dsonar.python.bandit.reportPaths="${reportsDir}/bandit-report.json" \\
                -Dsonar.python.pylint.reportPaths="${reportsDir}/pylint-report.txt" \\
                -Dsonar.python.flake8.reportPaths="${reportsDir}/flake8-report.txt"
            """.trim()
            break

        case 'java-maven':
            props += """
                -Dsonar.java.binaries="target/classes" \\
                -Dsonar.java.test.binaries="target/test-classes" \\
                -Dsonar.coverage.jacoco.xmlReportPaths="${reportsDir}/jacoco-coverage.xml" \\
                -Dsonar.junit.reportPaths="target/surefire-reports"
            """.trim()
            break

        case 'java-gradle':
            props += """
                -Dsonar.java.binaries="build/classes" \\
                -Dsonar.coverage.jacoco.xmlReportPaths="${reportsDir}/jacoco-coverage.xml" \\
                -Dsonar.junit.reportPaths="build/test-results/test"
            """.trim()
            break

        case ['nodejs', 'react', 'angular', 'vue']:
            props += """
                -Dsonar.javascript.lcov.reportPaths="${reportsDir}/lcov.info" \\
                -Dsonar.eslint.reportPaths="${reportsDir}/eslint-report.json" \\
                -Dsonar.typescript.lcov.reportPaths="${reportsDir}/lcov.info"
            """.trim()
            break

        case 'go':
            props += """
                -Dsonar.go.coverage.reportPaths="${reportsDir}/go-coverage.out" \\
                -Dsonar.go.tests.reportPaths="${reportsDir}/go-test-unit.json"
            """.trim()
            break

        case 'dotnet':
            props += """
                -Dsonar.cs.opencover.reportsPaths="${reportsDir}/**/coverage.opencover.xml" \\
                -Dsonar.cs.vstest.reportsPaths="${reportsDir}/**/*.trx"
            """.trim()
            break
    }

    return props
}

// =============================================================================
// Fetch quality gate status from SonarQube API
// =============================================================================
def fetchQualityGateStatus(String sonarUrl, String sonarToken, String projectKey, String reportsDir) {
    sh """
        echo "=== Fetching SonarQube Quality Gate Status ==="

        # Wait for analysis to complete
        sleep 10

        # Get quality gate status
        curl -s -u "${sonarToken}:" \
            "${sonarUrl}/api/qualitygates/project_status?projectKey=${projectKey}" \
            > "${reportsDir}/sonarqube/quality-gate-status.json" 2>/dev/null || true

        # Get project measures
        curl -s -u "${sonarToken}:" \
            "${sonarUrl}/api/measures/component?component=${projectKey}&metricKeys=bugs,vulnerabilities,code_smells,coverage,duplicated_lines_density,ncloc,sqale_rating,reliability_rating,security_rating,security_hotspots" \
            > "${reportsDir}/sonarqube/project-measures.json" 2>/dev/null || true

        # Get issues summary
        curl -s -u "${sonarToken}:" \
            "${sonarUrl}/api/issues/search?componentKeys=${projectKey}&severities=BLOCKER,CRITICAL&statuses=OPEN,CONFIRMED&ps=500" \
            > "${reportsDir}/sonarqube/critical-issues.json" 2>/dev/null || true

        # Parse and display
        if [ -f "${reportsDir}/sonarqube/quality-gate-status.json" ]; then
            python3 <<'PYEOF'
import json

# Quality Gate
try:
    with open("${reportsDir}/sonarqube/quality-gate-status.json") as f:
        qg = json.load(f)
    status = qg.get("projectStatus", {}).get("status", "UNKNOWN")
    conditions = qg.get("projectStatus", {}).get("conditions", [])
    print(f"  Quality Gate:    {status}")
    for c in conditions:
        metric = c.get("metricKey", "")
        actual = c.get("actualValue", "?")
        threshold = c.get("errorThreshold", "?")
        cstatus = c.get("status", "?")
        print(f"    {metric:35s} {actual:>8s}  (threshold: {threshold})  [{cstatus}]")
except Exception as e:
    print(f"  Quality Gate:    Unable to parse ({e})")

# Measures
try:
    with open("${reportsDir}/sonarqube/project-measures.json") as f:
        measures_data = json.load(f)
    measures = {m["metric"]: m.get("value", "N/A") for m in measures_data.get("component", {}).get("measures", [])}
    print()
    print("  SonarQube Measures:")
    print(f"    Lines of Code:           {measures.get('ncloc', 'N/A')}")
    print(f"    Bugs:                    {measures.get('bugs', 'N/A')}")
    print(f"    Vulnerabilities:         {measures.get('vulnerabilities', 'N/A')}")
    print(f"    Code Smells:             {measures.get('code_smells', 'N/A')}")
    print(f"    Coverage:                {measures.get('coverage', 'N/A')}%")
    print(f"    Duplicated Lines:        {measures.get('duplicated_lines_density', 'N/A')}%")
    print(f"    Security Hotspots:       {measures.get('security_hotspots', 'N/A')}")
except Exception as e:
    print(f"  Measures:        Unable to fetch ({e})")

PYEOF
        fi
    """
}

// =============================================================================
// Generate local quality report when SonarQube is not accessible
// =============================================================================
def generateLocalQualityReport(String language, String reportsDir) {
    sh """
        echo "=== Generating Local Quality Report (SonarQube unavailable) ==="

        python3 <<'PYEOF'
import json, os, glob

report = {
    "sonarqube_available": False,
    "local_analysis": True,
    "quality_metrics": {},
    "issues": []
}

reports_dir = "${reportsDir}"

# Parse Bandit (Python security)
bandit_file = os.path.join(reports_dir, "bandit-report.json")
if os.path.exists(bandit_file):
    with open(bandit_file) as f:
        bandit = json.load(f)
    results = bandit.get("results", [])
    report["quality_metrics"]["bandit_issues"] = len(results)
    report["quality_metrics"]["bandit_high"] = sum(1 for r in results if r.get("issue_severity") == "HIGH")
    report["quality_metrics"]["bandit_medium"] = sum(1 for r in results if r.get("issue_severity") == "MEDIUM")

# Parse Flake8
flake8_file = os.path.join(reports_dir, "flake8-report.txt")
if os.path.exists(flake8_file):
    with open(flake8_file) as f:
        lines = f.readlines()
    report["quality_metrics"]["flake8_issues"] = len(lines)

# Parse ESLint
eslint_file = os.path.join(reports_dir, "eslint-report.json")
if os.path.exists(eslint_file):
    try:
        with open(eslint_file) as f:
            eslint = json.load(f)
        total_errors = sum(r.get("errorCount", 0) for r in eslint)
        total_warnings = sum(r.get("warningCount", 0) for r in eslint)
        report["quality_metrics"]["eslint_errors"] = total_errors
        report["quality_metrics"]["eslint_warnings"] = total_warnings
    except:
        pass

# Parse Coverage
coverage_file = os.path.join(reports_dir, "coverage.xml")
if os.path.exists(coverage_file):
    import xml.etree.ElementTree as ET
    tree = ET.parse(coverage_file)
    root = tree.getroot()
    rate = float(root.attrib.get("line-rate", 0)) * 100
    report["quality_metrics"]["coverage_percent"] = round(rate, 1)

# Parse Pylint
pylint_file = os.path.join(reports_dir, "pylint-report.txt")
if os.path.exists(pylint_file):
    with open(pylint_file) as f:
        content = f.read()
    import re
    score_match = re.search(r'Your code has been rated at ([0-9.]+)', content)
    if score_match:
        report["quality_metrics"]["pylint_score"] = float(score_match.group(1))

with open(os.path.join(reports_dir, "sonarqube", "local-quality-report.json"), "w") as f:
    json.dump(report, f, indent=2)

print("  Local Quality Report Generated:")
for k, v in report["quality_metrics"].items():
    print(f"    {k:30s}: {v}")

PYEOF
    """
}
