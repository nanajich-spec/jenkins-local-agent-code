// =============================================================================
// Jenkinsfile.go — Template for Go Projects
// =============================================================================
// Copy this to your project root as 'Jenkinsfile' and adjust parameters.
//
// Supports: go vet, golangci-lint, go test, coverage, Docker
//
// Prerequisites:
//   - go.mod in project root
//   - *_test.go files for tests
//   - Dockerfile (optional)
// =============================================================================

pipeline {
    agent { label 'local-security-agent' }

    options {
        buildDiscarder(logRotator(numToKeepStr: '10'))
        timestamps()
        timeout(time: 20, unit: 'MINUTES')
    }

    environment {
        REGISTRY = '132.186.17.22:5000'
        IMAGE_NAME = 'my-go-app'              // <-- CHANGE THIS
        IMAGE_TAG = "${env.BUILD_NUMBER}"
        REPORTS_DIR = "${WORKSPACE}/build-reports"
        CGO_ENABLED = '0'
    }

    stages {
        stage('Setup') {
            steps {
                sh '''
                    mkdir -p "${REPORTS_DIR}"
                    go version
                '''
            }
        }

        stage('Dependencies') {
            steps {
                sh '''
                    go mod download
                    go mod verify
                '''
            }
        }

        stage('Lint & Quality') {
            parallel {
                stage('go vet') {
                    steps {
                        sh 'go vet ./... 2>&1 | tee "${REPORTS_DIR}/govet.txt" || true'
                    }
                }
                stage('golangci-lint') {
                    steps {
                        sh '''
                            if command -v golangci-lint &>/dev/null; then
                                golangci-lint run --out-format json \
                                    > "${REPORTS_DIR}/golangci-lint.json" 2>/dev/null || true
                                golangci-lint run 2>/dev/null || echo "Lint issues (non-blocking)"
                            else
                                echo "golangci-lint not installed"
                            fi
                        '''
                    }
                }
                stage('gofmt') {
                    steps {
                        sh '''
                            UNFORMATTED=$(gofmt -l . 2>/dev/null)
                            if [ -n "${UNFORMATTED}" ]; then
                                echo "Unformatted files:"
                                echo "${UNFORMATTED}"
                            else
                                echo "All files formatted"
                            fi
                        '''
                    }
                }
            }
        }

        stage('Unit Tests') {
            steps {
                sh '''
                    go test ./... -v -count=1 \
                        -coverprofile="${REPORTS_DIR}/coverage.out" \
                        -json > "${REPORTS_DIR}/test-results.json" 2>&1 || echo "Tests failed"

                    go tool cover -html="${REPORTS_DIR}/coverage.out" \
                        -o "${REPORTS_DIR}/coverage.html" 2>/dev/null || true

                    echo "=== Coverage Summary ==="
                    go tool cover -func="${REPORTS_DIR}/coverage.out" 2>/dev/null | tail -1 || true
                '''
            }
        }

        stage('Build') {
            steps {
                sh 'CGO_ENABLED=0 go build -ldflags="-w -s" -o "${REPORTS_DIR}/app" ./...'
            }
        }

        stage('Docker Build & Push') {
            when { expression { fileExists('Dockerfile') } }
            steps {
                sh """
                    podman build -t "${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}" .
                    podman push "${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}" --tls-verify=false
                """
            }
        }

        stage('Security Scan') {
            steps {
                sh """
                    trivy fs --scanners vuln --severity CRITICAL,HIGH \
                        --format json --output "${REPORTS_DIR}/trivy-fs.json" . || true
                """
            }
        }
    }

    post {
        always {
            archiveArtifacts artifacts: 'build-reports/**/*', allowEmptyArchive: true
            echo "Pipeline complete — reports in ${REPORTS_DIR}"
        }
    }
}
