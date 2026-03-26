pipeline {
    agent { label 'local-security-agent' }
    options {
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timeout(time: 60, unit: 'MINUTES')
    }
    environment {
        REGISTRY = '132.186.17.22:5000'
        SCAN_SEVERITY = 'CRITICAL,HIGH'
    }
    stages {
        stage('Setup') {
            steps {
                script {
                    sh 'mkdir -p security-reports'
                    sh 'echo "=== Tools ===" && trivy --version 2>&1 | head -1'

                    // Use REGISTRY_URL param if provided
                    if (params.REGISTRY_URL?.trim()) {
                        env.REGISTRY = params.REGISTRY_URL.trim()
                    }

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
                    echo "  Scan Type:     ${params.SCAN_TYPE}"
                    echo "  Scan ID:       ${params.SCAN_ID ?: 'N/A'}"
                    echo "  Image:         ${env.REGISTRY}/${params.IMAGE_NAME}:${params.IMAGE_TAG}"
                    echo "  Source Dir:    ${env.SOURCE_DIR}"
                    echo "  Source Upload: ${params.SOURCE_UPLOAD_PATH ? 'YES (user code)' : 'NO'}"
                    echo "=========================================="
                }
            }
        }

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

        stage('Image Scan') {
            when { expression { params.SCAN_TYPE in ['full', 'image-only'] } }
            steps {
                script {
                    def img = "${env.REGISTRY}/${params.IMAGE_NAME}:${params.IMAGE_TAG}"
                    sh "echo '=== Image scan: ${img} ==='"
                    sh "trivy image --podman-host '' --severity CRITICAL,HIGH --format json --output security-reports/trivy-image-scan.json '${img}' || true"
                    sh "trivy image --podman-host '' --severity CRITICAL,HIGH --format table --output security-reports/trivy-image-scan.txt '${img}' || true"
                }
            }
        }

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

        stage('Registry Scan') {
            when { expression { return params.SCAN_REGISTRY_IMAGES } }
            steps {
                script {
                    def reg = env.REGISTRY
                    sh """
                        echo '=== Scanning all images in registry: ${reg} ==='
                        REPOS=\$(curl -s http://${reg}/v2/_catalog | python3 -c "import sys,json; [print(r) for r in json.load(sys.stdin).get('repositories',[])]" 2>/dev/null || echo "")
                        for REPO in \$REPOS; do
                            TAGS=\$(curl -s http://${reg}/v2/\$REPO/tags/list | python3 -c "import sys,json; [print(t) for t in json.load(sys.stdin).get('tags',[])]" 2>/dev/null || echo "latest")
                            for TAG in \$TAGS; do
                                echo "--- Scanning \$REPO:\$TAG ---"
                                trivy image --podman-host '' --severity CRITICAL,HIGH --format table "${reg}/\$REPO:\$TAG" || true
                            done
                        done
                    """
                }
            }
        }

        stage('Security Gate') {
            steps {
                script {
                    echo '=== Security Gate ==='
                    def rc = sh(script: '''
                        CRIT=0
                        for f in security-reports/trivy-image-scan.json security-reports/trivy-fs-scan.json; do
                            if [ -f "$f" ]; then
                                C=$(python3 -c "import json; d=json.load(open('$f')); print(sum(1 for r in d.get('Results',[]) for v in r.get('Vulnerabilities',[]) if v.get('Severity')=='CRITICAL'))" 2>/dev/null || echo 0)
                                CRIT=$((CRIT + C))
                            fi
                        done
                        echo "CRITICAL vulnerabilities: $CRIT"
                        [ "$CRIT" -gt 0 ] && exit 1 || exit 0
                    ''', returnStatus: true)
                    if (rc != 0 && params.FAIL_ON_CRITICAL) {
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
