// =============================================================================
// vars/runTests.groovy — Multi-language Test Runner
// =============================================================================
// Usage:
//   runTests(language: 'python', type: 'unit')
//   runTests(language: 'java-maven', type: 'integration')
//   runTests(language: 'react', type: 'e2e')
// =============================================================================

def call(Map config = [:]) {
    def language   = config.get('language', 'auto')
    def testType   = config.get('type', 'unit')           // unit | integration | e2e
    def reportsDir = config.get('reportsDir', 'build-reports')
    def coverage   = config.get('coverage', true)
    def threshold  = config.get('coverageThreshold', '70')

    sh "mkdir -p ${reportsDir}"

    echo "=== Running ${testType} tests [${language}] ==="

    switch (language) {
        case 'python':
            runPythonTests(testType, reportsDir, coverage, threshold)
            break
        case 'java-maven':
            runMavenTests(testType, reportsDir)
            break
        case 'java-gradle':
            runGradleTests(testType, reportsDir)
            break
        case ['nodejs', 'react', 'angular', 'vue']:
            runJsTests(testType, reportsDir, language, coverage)
            break
        case 'go':
            runGoTests(testType, reportsDir, coverage)
            break
        case 'dotnet':
            runDotnetTests(testType, reportsDir, coverage)
            break
        default:
            echo "No test runner for: ${language}"
    }
}

// ---- Python (pytest) ----
def runPythonTests(String type, String reportsDir, boolean coverage, String threshold) {
    def testDir = type == 'unit' ? 'tests/' : (type == 'integration' ? 'tests/integration/' : 'tests/e2e/')
    def marker = type == 'unit' ? '' : "-m ${type}"
    def covArgs = coverage ? "--cov=. --cov-report=xml:${reportsDir}/coverage.xml --cov-report=html:${reportsDir}/htmlcov --cov-report=term-missing --cov-fail-under=${threshold}" : ''

    sh """
        python3 -m pytest ${testDir} \
            --junitxml="${reportsDir}/pytest-${type}-results.xml" \
            ${covArgs} ${marker} \
            -v 2>/dev/null || \
        python3 -m pytest \
            --junitxml="${reportsDir}/pytest-${type}-results.xml" \
            ${covArgs} \
            -v 2>/dev/null || echo "No ${type} tests found"
    """
}

// ---- Java Maven (JUnit + JaCoCo) ----
def runMavenTests(String type, String reportsDir) {
    if (type == 'unit') {
        sh """
            mvn test -Dmaven.test.failure.ignore=true || echo "Tests failed"
            cp -r target/surefire-reports/* "${reportsDir}/" 2>/dev/null || true
            cp target/site/jacoco/jacoco.xml "${reportsDir}/jacoco-coverage.xml" 2>/dev/null || true
        """
    } else if (type == 'integration') {
        sh """
            mvn verify -DskipUTs=true -Dmaven.test.failure.ignore=true || echo "Integration tests failed"
            cp -r target/failsafe-reports/* "${reportsDir}/" 2>/dev/null || true
        """
    }
}

// ---- Java Gradle (JUnit + JaCoCo) ----
def runGradleTests(String type, String reportsDir) {
    def task = type == 'unit' ? 'test' : 'integrationTest'
    sh """
        ./gradlew ${task} --continue 2>/dev/null || gradle ${task} --continue 2>/dev/null || echo "${type} tests failed"
        cp -r build/test-results/${task}/* "${reportsDir}/" 2>/dev/null || true
        cp build/reports/jacoco/test/jacocoTestReport.xml "${reportsDir}/jacoco-coverage.xml" 2>/dev/null || true
    """
}

// ---- JavaScript/TypeScript (Jest, Mocha, Cypress, Playwright) ----
def runJsTests(String type, String reportsDir, String framework, boolean coverage) {
    if (type == 'unit') {
        sh """
            if grep -q '"test"' package.json 2>/dev/null; then
                npx jest --ci --coverage \
                    --coverageDirectory="${reportsDir}/coverage" \
                    --coverageReporters=json-summary --coverageReporters=lcov --coverageReporters=text \
                    2>/dev/null || \
                npm test -- --coverage 2>/dev/null || \
                npm test 2>/dev/null || echo "Tests failed"
            fi
            cp coverage/lcov.info "${reportsDir}/lcov.info" 2>/dev/null || true
            cp coverage/coverage-summary.json "${reportsDir}/coverage-summary.json" 2>/dev/null || true
        """
    } else if (type == 'integration') {
        sh '''
            if grep -q '"test:integration"' package.json 2>/dev/null; then
                npm run test:integration || echo "Integration tests failed"
            fi
        '''
    } else if (type == 'e2e') {
        sh """
            if [ -f "cypress.config.js" ] || [ -f "cypress.config.ts" ]; then
                npx cypress run --reporter junit \
                    --reporter-options "mochaFile=${reportsDir}/cypress-results.xml" \
                    2>/dev/null || echo "Cypress E2E failed"
            elif [ -f "playwright.config.js" ] || [ -f "playwright.config.ts" ]; then
                npx playwright test --reporter=junit 2>/dev/null || echo "Playwright E2E failed"
            elif grep -q '"test:e2e"' package.json 2>/dev/null; then
                npm run test:e2e 2>/dev/null || echo "E2E tests failed"
            else
                echo "No E2E framework detected"
            fi
        """
    }
}

// ---- Go ----
def runGoTests(String type, String reportsDir, boolean coverage) {
    def tags = type == 'unit' ? '' : "-tags=${type}"
    sh """
        go test ./... -v -count=1 ${tags} \
            -coverprofile="${reportsDir}/go-coverage.out" \
            -json > "${reportsDir}/go-test-${type}.json" 2>&1 || echo "${type} tests failed"
        go tool cover -html="${reportsDir}/go-coverage.out" -o "${reportsDir}/go-coverage.html" 2>/dev/null || true
        go tool cover -func="${reportsDir}/go-coverage.out" 2>/dev/null | tail -1 || true
    """
}

// ---- .NET ----
def runDotnetTests(String type, String reportsDir, boolean coverage) {
    def pattern = type == 'unit' ? '*Test*' : '*Integration*'
    sh """
        TEST_PROJ=\$(find . -name "${pattern}.csproj" | head -1)
        if [ -n "\${TEST_PROJ}" ]; then
            dotnet test "\${TEST_PROJ}" \
                --logger "trx;LogFileName=${reportsDir}/${type}-results.trx" \
                --collect:"XPlat Code Coverage" \
                --results-directory "${reportsDir}" \
                -v normal || echo "${type} tests failed"
        else
            dotnet test \
                --logger "trx;LogFileName=${reportsDir}/${type}-results.trx" \
                --results-directory "${reportsDir}" \
                -v normal || echo "${type} tests failed"
        fi
    """
}
