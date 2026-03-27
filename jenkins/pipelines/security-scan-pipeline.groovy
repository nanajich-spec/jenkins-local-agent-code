pipeline {
    agent { label 'local-security-agent' }
    options {
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timeout(time: 60, unit: 'MINUTES')
    }
    environment {
        REGISTRY = '132.186.17.22:5000'
        SONARQUBE_URL = 'http://132.186.17.22:32001'
        SCAN_SEVERITY = 'CRITICAL,HIGH'
    }
    stages {
        stage('Setup') {
            steps {
                script {
                    // Clean previous reports to avoid stale artifacts
                    sh 'rm -rf security-reports && mkdir -p security-reports'
                    sh 'echo "=== Tools ===" && trivy --version 2>&1 | head -1'
                    sh 'echo "sonar-scanner: $(which sonar-scanner 2>/dev/null || echo NOT_INSTALLED)"'
                    sh 'echo "shellcheck: $(which shellcheck 2>/dev/null || echo NOT_INSTALLED)"'
                    sh 'echo "podman: $(which podman 2>/dev/null || echo NOT_INSTALLED)"'

                    // Use REGISTRY_URL param if provided
                    if (params.REGISTRY_URL?.trim()) {
                        env.REGISTRY = params.REGISTRY_URL.trim()
                    }

                    // Parse boolean params (they arrive as strings from buildWithParameters)
                    env.DO_REGISTRY_SCAN = (params.SCAN_REGISTRY_IMAGES?.toString() == 'true') ? 'true' : 'false'
                    env.DO_FAIL_CRITICAL = (params.FAIL_ON_CRITICAL?.toString() != 'false') ? 'true' : 'false'

                    // Extract uploaded source code if provided
                    if (params.SOURCE_UPLOAD_PATH?.trim()) {
                        def uploadPath = params.SOURCE_UPLOAD_PATH.trim()
                        def tarFile = uploadPath + '/source.tar.gz'
                        env.SOURCE_DIR = env.WORKSPACE + '/user-source'
                        sh "mkdir -p '${env.SOURCE_DIR}'"
                        sh """
                            if [ -f '${tarFile}' ]; then
                                tar xzf '${tarFile}' -C '${env.SOURCE_DIR}' 2>/dev/null || true
                                echo '=== Source code extracted ==='
                                echo "Files: \$(find '${env.SOURCE_DIR}' -type f | wc -l)"
                                echo "Size:  \$(du -sh '${env.SOURCE_DIR}' | cut -f1)"
                            else
                                echo "WARNING: Source tar not found at ${tarFile}"
                            fi
                        """
                    } else {
                        env.SOURCE_DIR = env.WORKSPACE
                    }

                    echo "=========================================="
                    echo "  Security Scan Pipeline"
                    echo "=========================================="
                    echo "  Scan Type:       ${params.SCAN_TYPE ?: 'code-only'}"
                    echo "  Scan ID:         ${params.SCAN_ID ?: 'N/A'}"
                    if (params.SCAN_TYPE in ['full', 'image-only']) {
                        echo "  Image:           ${env.REGISTRY}/${params.IMAGE_NAME}:${params.IMAGE_TAG}"
                    }
                    echo "  Source Dir:      ${env.SOURCE_DIR}"
                    echo "  Source Upload:   ${params.SOURCE_UPLOAD_PATH ? 'YES (user code)' : 'NO'}"
                    echo "  Registry Scan:   ${env.DO_REGISTRY_SCAN}"
                    echo "=========================================="
                }
            }
        }

        // =====================================================================
        // SOURCE CODE SCANS (code-only / full)
        // =====================================================================

        stage('Secret Detection') {
            when { expression { params.SCAN_TYPE in ['full', 'code-only'] } }
            steps {
                script {
                    def scanDir = env.SOURCE_DIR
                    sh "echo '=== Scanning for secrets in: ${scanDir} ==='"
                    sh "trivy fs --scanners secret --format json --output security-reports/secret-scan.json '${scanDir}' || true"
                    sh "trivy fs --scanners secret --format table '${scanDir}' || true"
                }
            }
        }

        stage('SAST / Vulnerability Scan') {
            when { expression { params.SCAN_TYPE in ['full', 'code-only'] } }
            steps {
                script {
                    def scanDir = env.SOURCE_DIR
                    sh "echo '=== SAST scan on: ${scanDir} ==='"
                    sh "trivy fs --scanners vuln,misconfig --severity CRITICAL,HIGH --format json --output security-reports/trivy-fs-scan.json '${scanDir}' || true"
                    sh "trivy fs --scanners vuln,misconfig --severity CRITICAL,HIGH --format table '${scanDir}' || true"
                }
            }
        }

        stage('SCA / Dependency Scan') {
            when { expression { params.SCAN_TYPE in ['full', 'code-only'] } }
            steps {
                script {
                    def scanDir = env.SOURCE_DIR
                    sh "echo '=== SCA dependency scan on: ${scanDir} ==='"
                    sh "trivy fs --scanners vuln --severity CRITICAL,HIGH,MEDIUM --format json --output security-reports/trivy-sca.json '${scanDir}' || true"
                    sh "trivy fs --scanners vuln --severity CRITICAL,HIGH,MEDIUM --format table --output security-reports/trivy-sca.txt '${scanDir}' || true"
                }
            }
        }

        stage('SonarQube Analysis') {
            when { expression { params.SCAN_TYPE in ['full', 'code-only'] } }
            steps {
                script {
                    def scanDir = env.SOURCE_DIR
                    def hasSonar = sh(script: "which sonar-scanner 2>/dev/null", returnStatus: true)
                    def sonarReachable = sh(script: "curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 '${env.SONARQUBE_URL}/api/system/status' | grep -q 200", returnStatus: true)

                    if (hasSonar == 0 && sonarReachable == 0) {
                        sh "echo '=== SonarQube code quality analysis on: ${scanDir} ==='"

                        // Generate a unique project key from scan ID or fallback
                        def projectKey = params.SCAN_ID ? "scan-${params.SCAN_ID}".replaceAll('[^a-zA-Z0-9_.-]', '_').take(100) : "user-scan-${System.currentTimeMillis()}"
                        def projectName = params.SCAN_ID ?: 'User Code Scan'

                        // Check if project has its own sonar-project.properties
                        def hasConfig = sh(script: "[ -f '${scanDir}/sonar-project.properties' ]", returnStatus: true)

                        if (hasConfig == 0) {
                            sh """
                                cd '${scanDir}'
                                sonar-scanner \
                                    -Dsonar.host.url='${env.SONARQUBE_URL}' \
                                    -Dsonar.login=admin -Dsonar.password=admin123 \\
                                    -Dsonar.qualitygate.wait=false \
                                    2>&1 | tee '${env.WORKSPACE}/security-reports/sonarqube-analysis.txt' || true
                            """
                        } else {
                            sh """
                                cd '${scanDir}'
                                sonar-scanner \
                                    -Dsonar.host.url='${env.SONARQUBE_URL}' \
                                    -Dsonar.login=admin -Dsonar.password=admin123 \\
                                    -Dsonar.projectKey='${projectKey}' \
                                    -Dsonar.projectName='${projectName}' \
                                    -Dsonar.sources=. \
                                    -Dsonar.exclusions='**/node_modules/**,**/vendor/**,**/.git/**,**/security-reports/**,**/*.class,**/*.jar' \
                                    -Dsonar.qualitygate.wait=false \
                                    2>&1 | tee '${env.WORKSPACE}/security-reports/sonarqube-analysis.txt' || true
                            """
                        }

                        // Fetch quality gate result
                        sh """
                            sleep 5
                            curl -s -u admin:admin123 '${env.SONARQUBE_URL}/api/qualitygates/project_status?projectKey=${projectKey}' \
                                > '${env.WORKSPACE}/security-reports/sonarqube-quality-gate.json' 2>/dev/null || true
                            echo '=== SonarQube Quality Gate Result ==='
                            python3 -c "
import json,sys
try:
    d=json.load(open('${env.WORKSPACE}/security-reports/sonarqube-quality-gate.json'))
    status=d.get('projectStatus',{}).get('status','UNKNOWN')
    print(f'Quality Gate: {status}')
    for c in d.get('projectStatus',{}).get('conditions',[]):
        print(f'  {c.get(\"metricKey\")}: {c.get(\"status\")} (actual={c.get(\"actualValue\")}, threshold={c.get(\"errorThreshold\")})')
except: print('Quality gate result not available yet')
" || true
                        """
                    } else {
                        sh "echo 'SKIP: SonarQube not available (sonar-scanner installed: ${hasSonar == 0}, server reachable: ${sonarReachable == 0})'"
                    }
                }
            }
        }

        stage('ShellCheck / Lint') {
            when { expression { params.SCAN_TYPE in ['full', 'code-only'] } }
            steps {
                script {
                    def scanDir = env.SOURCE_DIR
                    def hasShells = sh(script: "find '${scanDir}' -name '*.sh' -type f 2>/dev/null | head -1", returnStdout: true).trim()

                    if (hasShells) {
                        def hasShellcheck = sh(script: "which shellcheck 2>/dev/null", returnStatus: true)
                        if (hasShellcheck == 0) {
                            sh """
                                echo '=== ShellCheck lint on shell scripts ==='
                                find '${scanDir}' -name '*.sh' -type f | while read f; do
                                    echo "--- \$f ---"
                                    shellcheck -f json "\$f" 2>/dev/null || true
                                done > security-reports/shellcheck.json 2>&1 || true

                                echo '=== ShellCheck Summary ==='
                                TOTAL=\$(find '${scanDir}' -name '*.sh' -type f | wc -l)
                                echo "Shell scripts found: \$TOTAL"
                                find '${scanDir}' -name '*.sh' -type f | while read f; do
                                    echo "  \$f"
                                    shellcheck -f tty "\$f" 2>/dev/null | head -20 || true
                                done | tee security-reports/shellcheck-summary.txt || true
                            """
                        } else {
                            // Fallback: use trivy misconfig for basic linting
                            sh """
                                echo '=== Shell script lint (via trivy, shellcheck not installed) ==='
                                echo "Found shell scripts:"
                                find '${scanDir}' -name '*.sh' -type f | head -20
                                echo "TIP: Install shellcheck for detailed shell script analysis"
                            """
                        }
                    } else {
                        sh "echo 'No shell scripts (.sh) found — skipping lint'"
                    }
                }
            }
        }

        stage('Dockerfile Build & Image Scan') {
            when { expression { params.SCAN_TYPE in ['full', 'code-only'] } }
            steps {
                script {
                    def scanDir = env.SOURCE_DIR
                    // Auto-detect Dockerfiles in the project
                    def dockerfiles = sh(script: "find '${scanDir}' -maxdepth 3 -name 'Dockerfile' -o -name 'Dockerfile.*' -o -name '*.Dockerfile' 2>/dev/null | head -5", returnStdout: true).trim()

                    if (dockerfiles) {
                        def hasPodman = sh(script: "which podman 2>/dev/null", returnStatus: true)
                        if (hasPodman == 0) {
                            sh "echo '=== Auto-detected Dockerfiles — building and scanning images ==='"

                            dockerfiles.split('\n').eachWithIndex { dockerfile, idx ->
                                def buildContext = sh(script: "dirname '${dockerfile}'", returnStdout: true).trim()
                                def imgTag = "scan-build-${params.SCAN_ID ?: 'local'}-${idx}:latest"
                                def safeTag = imgTag.replaceAll('[^a-zA-Z0-9_.-:]', '_')

                                sh """
                                    echo '--- Building image from: ${dockerfile} ---'
                                    echo "Build context: ${buildContext}"
                                    echo "Image tag: ${safeTag}"

                                    # Build with podman
                                    podman build --no-cache -f '${dockerfile}' -t '${safeTag}' '${buildContext}' 2>&1 | tail -20 || {
                                        echo "WARNING: Build failed for ${dockerfile} — skipping image scan"
                                        exit 0
                                    }

                                    echo '--- Scanning built image layers: ${safeTag} ---'
                                    trivy image --podman-host '' --severity CRITICAL,HIGH,MEDIUM \
                                        --format json --output 'security-reports/trivy-build-image-${idx}.json' \
                                        '${safeTag}' || true
                                    trivy image --podman-host '' --severity CRITICAL,HIGH,MEDIUM \
                                        --format table --output 'security-reports/trivy-build-image-${idx}.txt' \
                                        '${safeTag}' || true

                                    # Cleanup built image
                                    podman rmi '${safeTag}' 2>/dev/null || true
                                """
                            }
                        } else {
                            sh """
                                echo '=== Dockerfiles found but podman/docker not available ==='
                                echo "Dockerfiles detected:"
                                find '${scanDir}' -maxdepth 3 -name 'Dockerfile' -o -name 'Dockerfile.*' -o -name '*.Dockerfile' 2>/dev/null | head -5
                                echo "TIP: Install podman or docker to auto-build and scan images"
                            """
                        }
                    } else {
                        sh "echo 'No Dockerfiles found in project — skipping auto-build image scan'"
                    }
                }
            }
        }

        // =====================================================================
        // EXPLICIT IMAGE SCAN (only with --image flag)
        // =====================================================================

        stage('Image Scan') {
            when {
                expression {
                    params.SCAN_TYPE in ['full', 'image-only'] &&
                    params.IMAGE_NAME?.trim() &&
                    params.IMAGE_NAME?.trim() != 'none'
                }
            }
            steps {
                script {
                    def img = "${env.REGISTRY}/${params.IMAGE_NAME}:${params.IMAGE_TAG}"
                    sh "echo '=== Image scan: ${img} ==='"
                    sh "trivy image --podman-host '' --severity CRITICAL,HIGH --format json --output security-reports/trivy-image-scan.json '${img}' || true"
                    sh "trivy image --podman-host '' --severity CRITICAL,HIGH --format table --output security-reports/trivy-image-scan.txt '${img}' || true"
                }
            }
        }

        // =====================================================================
        // K8S MANIFEST SCAN
        // =====================================================================

        stage('K8s Manifest Scan') {
            when { expression { params.SCAN_TYPE in ['full', 'k8s-manifests'] } }
            steps {
                script {
                    def scanDir = env.SOURCE_DIR
                    def hasK8s = sh(script: "find '${scanDir}' -name '*.yaml' -o -name '*.yml' 2>/dev/null | head -1", returnStdout: true).trim()
                    if (hasK8s) {
                        sh "echo '=== K8s manifest scan on: ${scanDir} ==='"
                        sh "trivy config --severity CRITICAL,HIGH --format json --output security-reports/trivy-k8s-config.json '${scanDir}' || true"
                        sh "trivy config --severity CRITICAL,HIGH --format table --output security-reports/trivy-k8s-config.txt '${scanDir}' || true"
                    } else {
                        sh "echo 'No YAML/YML files found for K8s manifest scan'"
                    }
                }
            }
        }

        // =====================================================================
        // REGISTRY SCAN (only with --scan-registry flag)
        // =====================================================================

        stage('Registry Scan') {
            when { expression { return env.DO_REGISTRY_SCAN == 'true' } }
            steps {
                script {
                    def reg = env.REGISTRY
                    sh """
                        echo '=== Scanning all images in registry: ${reg} ==='
                        REPOS=\$(curl -s http://${reg}/v2/_catalog | python3 -c "import sys,json; [print(r) for r in json.load(sys.stdin).get('repositories',[])]" 2>/dev/null || echo "")
                        for REPO in \$REPOS; do
                            TAGS=\$(curl -s http://${reg}/v2/\$REPO/tags/list | python3 -c "import sys,json; [print(t) for t in json.load(sys.stdin).get('tags',[])]" 2>/dev/null || echo "latest")
                            for TAG in \$TAGS; do
                                SAFE_NAME=\$(echo "\${REPO}-\${TAG}" | tr '/:' '-')
                                echo "--- Scanning \$REPO:\$TAG ---"
                                trivy image --podman-host '' --severity CRITICAL,HIGH \
                                    --format json --output "security-reports/trivy-\${SAFE_NAME}.json" \
                                    "${reg}/\$REPO:\$TAG" || true
                                trivy image --podman-host '' --severity CRITICAL,HIGH \
                                    --format table --output "security-reports/trivy-\${SAFE_NAME}.txt" \
                                    "${reg}/\$REPO:\$TAG" || true
                            done
                        done
                    """
                }
            }
        }

        // =====================================================================
        // SECURITY GATE
        // =====================================================================

        stage('Security Gate') {
            steps {
                script {
                    echo '=== Security Gate ==='
                    def rc = sh(script: '''
                        CRIT=0
                        for f in security-reports/trivy-image-scan.json security-reports/trivy-fs-scan.json security-reports/trivy-build-image-*.json; do
                            if [ -f "$f" ]; then
                                C=$(python3 -c "import json; d=json.load(open('$f')); print(sum(1 for r in d.get('Results',[]) for v in r.get('Vulnerabilities',[]) if v.get('Severity')=='CRITICAL'))" 2>/dev/null || echo 0)
                                CRIT=$((CRIT + C))
                            fi
                        done
                        echo "CRITICAL vulnerabilities: $CRIT"
                        [ "$CRIT" -gt 0 ] && exit 1 || exit 0
                    ''', returnStatus: true)
                    if (rc != 0 && env.DO_FAIL_CRITICAL == 'true') {
                        unstable('CRITICAL vulnerabilities detected')
                    }
                }
            }
        }
    }
    post {
        always {
            archiveArtifacts artifacts: 'security-reports/**', allowEmptyArchive: true
            script {
                // Cleanup uploaded source code
                if (params.SOURCE_UPLOAD_PATH?.trim()) {
                    sh "rm -rf '${env.SOURCE_DIR}' 2>/dev/null || true"
                    if (params.SCAN_ID?.trim()) {
                        sh """
                            curl -s -X POST http://132.186.17.22:9091/cleanup \
                                -H 'Content-Type: application/json' \
                                -d '{"scan_id": "${params.SCAN_ID}"}' || true
                        """
                    }
                }
            }
            echo 'Security scan complete.'
        }
    }
}
