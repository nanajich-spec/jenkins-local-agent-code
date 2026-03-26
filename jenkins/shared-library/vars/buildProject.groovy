// =============================================================================
// vars/buildProject.groovy — Multi-language Build Step
// =============================================================================
// Usage: buildProject(language: 'python')
// =============================================================================

def call(Map config = [:]) {
    def language  = config.get('language', 'auto')
    def reportsDir = config.get('reportsDir', 'build-reports')

    sh "mkdir -p ${reportsDir}"

    switch (language) {
        case 'python':
            sh '''
                echo "=== Python Build ==="
                if [ -f "setup.py" ]; then
                    python3 setup.py bdist_wheel 2>/dev/null || python3 setup.py build || true
                elif [ -f "pyproject.toml" ]; then
                    pip install build 2>/dev/null
                    python3 -m build 2>/dev/null || true
                else
                    echo "Script-based project — no build step needed"
                fi
            '''
            break

        case 'java-maven':
            sh 'mvn package -DskipTests -q'
            break

        case 'java-gradle':
            sh './gradlew build -x test 2>/dev/null || gradle build -x test'
            break

        case ['nodejs', 'react', 'angular', 'vue']:
            sh '''
                if grep -q '"build"' package.json 2>/dev/null; then
                    npm run build
                else
                    echo "No build script in package.json"
                fi
            '''
            break

        case 'go':
            sh 'CGO_ENABLED=0 go build -o app ./... 2>/dev/null || go build ./...'
            break

        case 'dotnet':
            sh 'dotnet build --configuration Release && dotnet publish --configuration Release --output ./publish'
            break

        default:
            echo "No build step for language: ${language}"
    }
}
