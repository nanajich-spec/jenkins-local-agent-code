// =============================================================================
// vars/codeQuality.groovy — Multi-language Lint & Quality Checks
// =============================================================================
// Usage: codeQuality(language: 'python', reportsDir: 'build-reports')
// =============================================================================

def call(Map config = [:]) {
    def language   = config.get('language', 'auto')
    def reportsDir = config.get('reportsDir', 'build-reports')

    sh "mkdir -p ${reportsDir}"
    echo "=== Code Quality Check [${language}] ==="

    switch (language) {
        case 'python':
            sh """
                echo "--- Flake8 ---"
                flake8 . --max-line-length=120 --exclude=.venv,venv,__pycache__,migrations \
                    --output-file="${reportsDir}/flake8.txt" 2>/dev/null || true

                echo "--- Black (format check) ---"
                black --check --diff . 2>/dev/null || echo "Formatting issues (non-blocking)"

                echo "--- MyPy (type check) ---"
                mypy . --ignore-missing-imports 2>/dev/null || echo "Type issues (non-blocking)"

                echo "--- Bandit (security) ---"
                bandit -r . -f json -o "${reportsDir}/bandit.json" \
                    --exclude .venv,venv,tests 2>/dev/null || true
            """
            break

        case 'java-maven':
            sh """
                echo "--- Checkstyle ---"
                mvn checkstyle:check -q 2>/dev/null || echo "Checkstyle issues (non-blocking)"
                echo "--- SpotBugs ---"
                mvn spotbugs:check -q 2>/dev/null || echo "SpotBugs not configured"
            """
            break

        case 'java-gradle':
            sh """
                echo "--- Checkstyle ---"
                ./gradlew checkstyleMain 2>/dev/null || echo "Checkstyle not configured"
                echo "--- SpotBugs ---"
                ./gradlew spotbugsMain 2>/dev/null || echo "SpotBugs not configured"
            """
            break

        case ['nodejs', 'react', 'angular', 'vue']:
            sh """
                echo "--- ESLint ---"
                if [ -f "node_modules/.bin/eslint" ]; then
                    npx eslint . --format json --output-file "${reportsDir}/eslint.json" 2>/dev/null || true
                    npx eslint . 2>/dev/null || echo "ESLint issues (non-blocking)"
                fi
                echo "--- Prettier ---"
                if [ -f "node_modules/.bin/prettier" ]; then
                    npx prettier --check 'src/**/*.{js,jsx,ts,tsx,css}' 2>/dev/null || echo "Prettier issues (non-blocking)"
                fi
            """
            break

        case 'go':
            sh """
                echo "--- go vet ---"
                go vet ./... 2>&1 | tee "${reportsDir}/govet.txt" || true
                echo "--- golangci-lint ---"
                if command -v golangci-lint &>/dev/null; then
                    golangci-lint run --out-format json > "${reportsDir}/golangci-lint.json" 2>/dev/null || true
                fi
                echo "--- gofmt ---"
                UNFORMATTED=\$(gofmt -l . 2>/dev/null)
                [ -n "\${UNFORMATTED}" ] && echo "Unformatted: \${UNFORMATTED}" || echo "All formatted"
            """
            break

        case 'dotnet':
            sh """
                echo "--- dotnet format ---"
                dotnet format --verify-no-changes 2>/dev/null || echo "Format issues (non-blocking)"
            """
            break
    }
}
