// =============================================================================
// vars/detectLanguage.groovy — Auto-detect Project Language
// =============================================================================
// Usage: def lang = detectLanguage()
// Returns: python | java-maven | java-gradle | nodejs | react | angular | vue | go | dotnet
// =============================================================================

def call(Map config = [:]) {
    def workspace = config.get('path', '.')

    if (fileExists("${workspace}/requirements.txt") || fileExists("${workspace}/setup.py") ||
        fileExists("${workspace}/pyproject.toml") || fileExists("${workspace}/Pipfile")) {
        echo "[detectLanguage] Detected: Python"
        return 'python'
    }

    if (fileExists("${workspace}/pom.xml")) {
        echo "[detectLanguage] Detected: Java (Maven)"
        return 'java-maven'
    }

    if (fileExists("${workspace}/build.gradle") || fileExists("${workspace}/build.gradle.kts")) {
        echo "[detectLanguage] Detected: Java (Gradle)"
        return 'java-gradle'
    }

    if (fileExists("${workspace}/angular.json")) {
        echo "[detectLanguage] Detected: Angular"
        return 'angular'
    }

    if (fileExists("${workspace}/next.config.js") || fileExists("${workspace}/next.config.mjs")) {
        echo "[detectLanguage] Detected: React (Next.js)"
        return 'react'
    }

    if (fileExists("${workspace}/vue.config.js") || fileExists("${workspace}/nuxt.config.js")) {
        echo "[detectLanguage] Detected: Vue.js"
        return 'vue'
    }

    if (fileExists("${workspace}/package.json")) {
        def pkgJson = readFile("${workspace}/package.json")
        if (pkgJson.contains('"react"')) {
            echo "[detectLanguage] Detected: React"
            return 'react'
        }
        echo "[detectLanguage] Detected: Node.js"
        return 'nodejs'
    }

    if (fileExists("${workspace}/go.mod")) {
        echo "[detectLanguage] Detected: Go"
        return 'go'
    }

    def csproj = sh(script: "find ${workspace} -maxdepth 2 -name '*.csproj' | head -1", returnStdout: true).trim()
    if (csproj) {
        echo "[detectLanguage] Detected: .NET"
        return 'dotnet'
    }

    echo "[detectLanguage] Could not auto-detect — defaulting to nodejs"
    return 'nodejs'
}
