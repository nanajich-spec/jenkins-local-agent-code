// =============================================================================
// Jenkinsfile.java — Template for Java Projects (Maven / Gradle)
// =============================================================================
// Copy this to your project root as 'Jenkinsfile' and adjust parameters.
//
// Supports: Maven OR Gradle, JUnit, JaCoCo, Checkstyle, SpotBugs, Docker
//
// Prerequisites:
//   - pom.xml (Maven) or build.gradle (Gradle)
//   - src/test/java/ with JUnit tests
//   - Dockerfile (optional)
// =============================================================================

pipeline {
    agent { label 'local-security-agent' }

    options {
        buildDiscarder(logRotator(numToKeepStr: '10'))
        timestamps()
        timeout(time: 45, unit: 'MINUTES')
    }

    environment {
        REGISTRY = '132.186.17.22:5000'
        IMAGE_NAME = 'my-java-app'            // <-- CHANGE THIS
        IMAGE_TAG = "${env.BUILD_NUMBER}"
        REPORTS_DIR = "${WORKSPACE}/build-reports"
        JAVA_HOME = '/usr/lib/jvm/java-17'    // <-- Adjust if needed
    }

    stages {
        stage('Setup') {
            steps {
                sh '''
                    mkdir -p "${REPORTS_DIR}"
                    java -version 2>&1 | head -1
                    mvn --version 2>/dev/null | head -1 || echo "Maven not found"
                    gradle --version 2>/dev/null | head -3 || echo "Gradle not found"
                '''
            }
        }

        // ---- MAVEN PATH ----
        stage('Maven Build & Test') {
            when { expression { fileExists('pom.xml') } }
            stages {
                stage('Compile') {
                    steps { sh 'mvn compile -q' }
                }
                stage('Checkstyle') {
                    steps { sh 'mvn checkstyle:check -q 2>/dev/null || echo "Checkstyle issues"' }
                }
                stage('Unit Tests') {
                    steps {
                        sh 'mvn test -Dmaven.test.failure.ignore=true'
                        sh 'cp -r target/surefire-reports/* "${REPORTS_DIR}/" 2>/dev/null || true'
                    }
                    post {
                        always { junit allowEmptyResults: true, testResults: 'target/surefire-reports/**/*.xml' }
                    }
                }
                stage('Coverage (JaCoCo)') {
                    steps {
                        sh '''
                            mvn jacoco:report 2>/dev/null || echo "JaCoCo not configured"
                            cp target/site/jacoco/jacoco.xml "${REPORTS_DIR}/jacoco.xml" 2>/dev/null || true
                        '''
                    }
                }
                stage('Package') {
                    steps { sh 'mvn package -DskipTests -q' }
                }
            }
        }

        // ---- GRADLE PATH ----
        stage('Gradle Build & Test') {
            when { expression { fileExists('build.gradle') || fileExists('build.gradle.kts') } }
            stages {
                stage('Compile') {
                    steps { sh './gradlew compileJava 2>/dev/null || gradle compileJava' }
                }
                stage('Unit Tests') {
                    steps {
                        sh './gradlew test --continue 2>/dev/null || gradle test --continue || echo "Tests failed"'
                        sh 'cp -r build/test-results/test/* "${REPORTS_DIR}/" 2>/dev/null || true'
                    }
                    post {
                        always { junit allowEmptyResults: true, testResults: 'build/test-results/**/*.xml' }
                    }
                }
                stage('Package') {
                    steps { sh './gradlew build -x test 2>/dev/null || gradle build -x test' }
                }
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
            when { expression { fileExists('Dockerfile') } }
            steps {
                sh """
                    trivy image --podman-host "" --severity CRITICAL,HIGH \
                        --format json --output "${REPORTS_DIR}/trivy-image.json" \
                        "${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}" || true
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
