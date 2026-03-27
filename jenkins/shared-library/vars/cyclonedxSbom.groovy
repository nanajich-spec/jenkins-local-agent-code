// =============================================================================
// vars/cyclonedxSbom.groovy — CycloneDX SBOM Generator (Multi-Language)
// =============================================================================
// Generates CycloneDX Software Bill of Materials (SBOM) for:
//   Java (Maven/Gradle), Python, Node.js, React, Angular, Go, .NET
//
// Usage:
//   cyclonedxSbom(language: 'auto', reportsDir: 'pipeline-reports')
//   cyclonedxSbom(language: 'python', scanPath: '.', reportsDir: 'reports')
//
// Outputs:
//   - sbom-<language>.json   (CycloneDX JSON)
//   - sbom-<language>.xml    (CycloneDX XML)
//   - sbom-summary.txt       (Human-readable summary)
// =============================================================================

def call(Map config = [:]) {
    def language   = config.get('language', 'auto')
    def scanPath   = config.get('scanPath', '.')
    def reportsDir = config.get('reportsDir', 'pipeline-reports')
    def format     = config.get('format', 'json')  // json | xml | both

    sh "mkdir -p '${reportsDir}/sbom'"

    echo """
╔══════════════════════════════════════════════════════════════╗
║        CycloneDX SBOM Generation                             ║
╠══════════════════════════════════════════════════════════════╣
║  Language:    ${language.padRight(44)}║
║  Scan Path:   ${scanPath.padRight(44)}║
║  Output Dir:  ${reportsDir}/sbom                             ║
╚══════════════════════════════════════════════════════════════╝
    """

    // Install CycloneDX CLI tool (fallback if language-specific tools missing)
    installCyclonedxTools(language)

    switch (language) {
        case 'python':
            generatePythonSbom(scanPath, reportsDir)
            break
        case 'java-maven':
            generateMavenSbom(scanPath, reportsDir)
            break
        case 'java-gradle':
            generateGradleSbom(scanPath, reportsDir)
            break
        case ['nodejs', 'react', 'angular', 'vue']:
            generateNodeSbom(scanPath, reportsDir, language)
            break
        case 'go':
            generateGoSbom(scanPath, reportsDir)
            break
        case 'dotnet':
            generateDotnetSbom(scanPath, reportsDir)
            break
        case 'auto':
            generateAutoSbom(scanPath, reportsDir)
            break
        default:
            echo "No CycloneDX plugin for language: ${language} — using Trivy SBOM fallback"
            generateTrivySbomFallback(scanPath, reportsDir, language)
    }

    // Always generate Trivy SBOM as a cross-check
    generateTrivySbomFallback(scanPath, reportsDir, 'trivy-cross-check')

    // Generate summary
    generateSbomSummary(reportsDir)

    echo "SBOM generation complete — files in ${reportsDir}/sbom/"
    return true
}

// =============================================================================
// Install CycloneDX tools based on detected language
// =============================================================================
def installCyclonedxTools(String language) {
    sh '''
        echo "--- Installing/Verifying CycloneDX Tools ---"

        # CycloneDX CLI (universal)
        if ! command -v cyclonedx &>/dev/null; then
            echo "Installing CycloneDX CLI..."
            pip install cyclonedx-bom 2>/dev/null || true
        fi
    '''

    switch (language) {
        case 'python':
            sh '''
                pip install cyclonedx-bom cyclonedx-py 2>/dev/null || true
                echo "CycloneDX Python tools ready"
            '''
            break
        case ['nodejs', 'react', 'angular', 'vue']:
            sh '''
                npm install -g @cyclonedx/cyclonedx-npm 2>/dev/null || \
                    npx @cyclonedx/cyclonedx-npm --version 2>/dev/null || true
                echo "CycloneDX Node.js tools ready"
            '''
            break
        case 'java-maven':
            // Maven plugin is declared in pom.xml or used via CLI
            echo "CycloneDX Maven plugin will be invoked directly"
            break
        case 'java-gradle':
            echo "CycloneDX Gradle plugin will be invoked directly"
            break
        case 'go':
            sh '''
                go install github.com/CycloneDX/cyclonedx-gomod/cmd/cyclonedx-gomod@latest 2>/dev/null || true
                echo "CycloneDX Go tools ready"
            '''
            break
        case 'dotnet':
            sh '''
                dotnet tool install --global CycloneDX 2>/dev/null || true
                echo "CycloneDX .NET tools ready"
            '''
            break
    }
}

// =============================================================================
// Python SBOM Generation
// =============================================================================
def generatePythonSbom(String scanPath, String reportsDir) {
    sh """
        echo "=== CycloneDX SBOM — Python ==="
        cd "${scanPath}"

        # Method 1: cyclonedx-py (preferred)
        if command -v cyclonedx-py &>/dev/null; then
            echo "Using cyclonedx-py..."

            # From requirements.txt
            if [ -f "requirements.txt" ]; then
                cyclonedx-py requirements \
                    -i requirements.txt \
                    --output-format json \
                    -o "${reportsDir}/sbom/sbom-python-requirements.json" 2>/dev/null || true

                cyclonedx-py requirements \
                    -i requirements.txt \
                    --output-format xml \
                    -o "${reportsDir}/sbom/sbom-python-requirements.xml" 2>/dev/null || true
            fi

            # From installed environment
            cyclonedx-py environment \
                --output-format json \
                -o "${reportsDir}/sbom/sbom-python-environment.json" 2>/dev/null || true

        # Method 2: cyclonedx-bom (fallback)
        elif python3 -m cyclonedx_py --help &>/dev/null; then
            echo "Using cyclonedx-bom module..."

            if [ -f "requirements.txt" ]; then
                python3 -m cyclonedx_py \
                    -r -i requirements.txt \
                    --format json \
                    -o "${reportsDir}/sbom/sbom-python-requirements.json" 2>/dev/null || true
            fi

            python3 -m cyclonedx_py \
                -e \
                --format json \
                -o "${reportsDir}/sbom/sbom-python-environment.json" 2>/dev/null || true

        # Method 3: pip-based approach
        else
            echo "Using pip-audit + manual SBOM generation..."
            pip install pip-audit 2>/dev/null || true
            pip-audit --format=cyclonedx-json \
                --output="${reportsDir}/sbom/sbom-python-pip-audit.json" 2>/dev/null || true
        fi

        # Also from Pipfile if present
        if [ -f "Pipfile.lock" ]; then
            echo "Found Pipfile.lock — generating additional SBOM..."
            if command -v cyclonedx-py &>/dev/null; then
                cyclonedx-py pipenv \
                    --output-format json \
                    -o "${reportsDir}/sbom/sbom-python-pipenv.json" 2>/dev/null || true
            fi
        fi

        # From pyproject.toml/poetry
        if [ -f "poetry.lock" ]; then
            echo "Found poetry.lock — generating additional SBOM..."
            if command -v cyclonedx-py &>/dev/null; then
                cyclonedx-py poetry \
                    --output-format json \
                    -o "${reportsDir}/sbom/sbom-python-poetry.json" 2>/dev/null || true
            fi
        fi

        echo "Python SBOM generation complete"
    """
}

// =============================================================================
// Java Maven SBOM Generation
// =============================================================================
def generateMavenSbom(String scanPath, String reportsDir) {
    sh """
        echo "=== CycloneDX SBOM — Java (Maven) ==="
        cd "${scanPath}"

        # Method 1: CycloneDX Maven Plugin (preferred)
        mvn org.cyclonedx:cyclonedx-maven-plugin:2.7.11:makeAggregateBom \
            -DoutputFormat=json \
            -DoutputName=sbom-java-maven \
            -DoutputDirectory="${reportsDir}/sbom" \
            -DincludeLicenseText=true \
            -DincludeCompileScope=true \
            -DincludeRuntimeScope=true \
            -DincludeTestScope=false \
            -DincludeProvidedScope=true \
            -DincludeSystemScope=false \
            -q 2>/dev/null || {
                echo "Maven CycloneDX plugin failed, trying alternate approach..."

                # Method 2: Generate from dependency:tree
                mvn dependency:tree -DoutputType=json \
                    -DoutputFile="${reportsDir}/sbom/maven-dep-tree.json" 2>/dev/null || true
            }

        # Also generate XML format
        mvn org.cyclonedx:cyclonedx-maven-plugin:2.7.11:makeAggregateBom \
            -DoutputFormat=xml \
            -DoutputName=sbom-java-maven \
            -DoutputDirectory="${reportsDir}/sbom" \
            -q 2>/dev/null || true

        echo "Java Maven SBOM generation complete"
    """
}

// =============================================================================
// Java Gradle SBOM Generation
// =============================================================================
def generateGradleSbom(String scanPath, String reportsDir) {
    sh """
        echo "=== CycloneDX SBOM — Java (Gradle) ==="
        cd "${scanPath}"

        # Check if CycloneDX plugin is configured in build.gradle
        if grep -q 'cyclonedx' build.gradle 2>/dev/null || grep -q 'cyclonedx' build.gradle.kts 2>/dev/null; then
            echo "CycloneDX Gradle plugin found in build config"
            ./gradlew cyclonedxBom 2>/dev/null || gradle cyclonedxBom 2>/dev/null || true
            cp build/reports/bom.json "${reportsDir}/sbom/sbom-java-gradle.json" 2>/dev/null || true
            cp build/reports/bom.xml "${reportsDir}/sbom/sbom-java-gradle.xml" 2>/dev/null || true
        else
            echo "CycloneDX plugin not in build.gradle — using init script approach..."

            # Create init script to add CycloneDX plugin dynamically
            cat > /tmp/cyclonedx-init.gradle <<'INITEOF'
initscript {
    repositories { mavenCentral() }
    dependencies { classpath 'org.cyclonedx:cyclonedx-gradle-plugin:1.8.2' }
}
allprojects {
    apply plugin: org.cyclonedx.gradle.CycloneDxPlugin
    cyclonedxBom {
        includeConfigs = ["runtimeClasspath"]
        outputFormat = "json"
    }
}
INITEOF
            ./gradlew cyclonedxBom --init-script /tmp/cyclonedx-init.gradle 2>/dev/null || \
            gradle cyclonedxBom --init-script /tmp/cyclonedx-init.gradle 2>/dev/null || {
                echo "Gradle CycloneDX generation failed — using Trivy fallback"
            }
            cp build/reports/bom.json "${reportsDir}/sbom/sbom-java-gradle.json" 2>/dev/null || true
        fi

        echo "Java Gradle SBOM generation complete"
    """
}

// =============================================================================
// Node.js / React / Angular SBOM Generation
// =============================================================================
def generateNodeSbom(String scanPath, String reportsDir, String framework) {
    sh """
        echo "=== CycloneDX SBOM — ${framework} (Node.js) ==="
        cd "${scanPath}"

        # Method 1: @cyclonedx/cyclonedx-npm (preferred)
        if npx @cyclonedx/cyclonedx-npm --version &>/dev/null 2>&1; then
            echo "Using @cyclonedx/cyclonedx-npm..."
            npx @cyclonedx/cyclonedx-npm \
                --output-format JSON \
                --output-file "${reportsDir}/sbom/sbom-${framework}.json" \
                --ignore-npm-errors \
                --package-lock-only 2>/dev/null || \
            npx @cyclonedx/cyclonedx-npm \
                --output-format JSON \
                --output-file "${reportsDir}/sbom/sbom-${framework}.json" \
                --ignore-npm-errors 2>/dev/null || true

            npx @cyclonedx/cyclonedx-npm \
                --output-format XML \
                --output-file "${reportsDir}/sbom/sbom-${framework}.xml" \
                --ignore-npm-errors 2>/dev/null || true

        # Method 2: cyclonedx-node-npm (alternate)
        elif command -v cyclonedx-npm &>/dev/null; then
            echo "Using cyclonedx-npm..."
            cyclonedx-npm --output-format json \
                --output "${reportsDir}/sbom/sbom-${framework}.json" 2>/dev/null || true

        # Method 3: npm sbom (npm 9.5+)
        elif npm sbom --help &>/dev/null 2>&1; then
            echo "Using npm sbom (built-in)..."
            npm sbom --sbom-format cyclonedx \
                --omit dev > "${reportsDir}/sbom/sbom-${framework}.json" 2>/dev/null || true

        # Method 4: From package-lock.json manually
        else
            echo "No CycloneDX npm tool available, generating from package-lock.json..."
            python3 <<'PYEOF'
import json, os, datetime, uuid

sbom = {
    "bomFormat": "CycloneDX",
    "specVersion": "1.4",
    "version": 1,
    "serialNumber": f"urn:uuid:{uuid.uuid4()}",
    "metadata": {
        "timestamp": datetime.datetime.utcnow().isoformat() + "Z",
        "tools": [{"vendor": "jenkins-pipeline", "name": "package-lock-parser", "version": "1.0"}]
    },
    "components": []
}

lock_file = None
for f in ["package-lock.json", "yarn.lock", "pnpm-lock.yaml"]:
    if os.path.exists(f):
        lock_file = f
        break

if lock_file == "package-lock.json":
    with open(lock_file) as fh:
        lock_data = json.load(fh)
    packages = lock_data.get("packages", lock_data.get("dependencies", {}))
    for name, info in packages.items():
        if not name or name == "":
            continue
        pkg_name = name.replace("node_modules/", "")
        version = info.get("version", "unknown")
        sbom["components"].append({
            "type": "library",
            "name": pkg_name,
            "version": version,
            "purl": f"pkg:npm/{pkg_name}@{version}"
        })
elif os.path.exists("package.json"):
    with open("package.json") as fh:
        pkg_data = json.load(fh)
    for dep_type in ["dependencies", "devDependencies"]:
        for name, ver in pkg_data.get(dep_type, {}).items():
            sbom["components"].append({
                "type": "library",
                "name": name,
                "version": ver.lstrip("^~>=<"),
                "purl": f"pkg:npm/{name}@{ver.lstrip('^~>=<')}"
            })

with open("${reportsDir}/sbom/sbom-${framework}.json", "w") as fh:
    json.dump(sbom, fh, indent=2)
print(f"Generated SBOM with {len(sbom['components'])} components")
PYEOF
        fi

        # Yarn support
        if [ -f "yarn.lock" ] && command -v yarn &>/dev/null; then
            echo "Generating Yarn-based SBOM..."
            npx @cyclonedx/cyclonedx-npm \
                --output-format JSON \
                --output-file "${reportsDir}/sbom/sbom-${framework}-yarn.json" \
                --ignore-npm-errors 2>/dev/null || true
        fi

        echo "${framework} SBOM generation complete"
    """
}

// =============================================================================
// Go SBOM Generation
// =============================================================================
def generateGoSbom(String scanPath, String reportsDir) {
    sh """
        echo "=== CycloneDX SBOM — Go ==="
        cd "${scanPath}"

        # Method 1: cyclonedx-gomod (preferred)
        if command -v cyclonedx-gomod &>/dev/null; then
            echo "Using cyclonedx-gomod..."
            cyclonedx-gomod mod \
                -json \
                -output "${reportsDir}/sbom/sbom-go.json" 2>/dev/null || true

            cyclonedx-gomod mod \
                -output "${reportsDir}/sbom/sbom-go.xml" 2>/dev/null || true

        # Method 2: From go.sum parse
        elif [ -f "go.sum" ]; then
            echo "Generating Go SBOM from go.sum..."
            python3 <<'PYEOF'
import json, datetime, uuid

sbom = {
    "bomFormat": "CycloneDX",
    "specVersion": "1.4",
    "version": 1,
    "serialNumber": f"urn:uuid:{uuid.uuid4()}",
    "metadata": {
        "timestamp": datetime.datetime.utcnow().isoformat() + "Z",
        "tools": [{"vendor": "jenkins-pipeline", "name": "go-sum-parser", "version": "1.0"}]
    },
    "components": []
}

seen = set()
with open("go.sum") as f:
    for line in f:
        parts = line.strip().split()
        if len(parts) >= 2:
            name = parts[0]
            version = parts[1].split("/")[0].lstrip("v")
            key = f"{name}@{version}"
            if key not in seen:
                seen.add(key)
                sbom["components"].append({
                    "type": "library",
                    "name": name,
                    "version": version,
                    "purl": f"pkg:golang/{name}@{version}"
                })

with open("${reportsDir}/sbom/sbom-go.json", "w") as fh:
    json.dump(sbom, fh, indent=2)
print(f"Generated Go SBOM with {len(sbom['components'])} components")
PYEOF
        fi

        echo "Go SBOM generation complete"
    """
}

// =============================================================================
// .NET SBOM Generation
// =============================================================================
def generateDotnetSbom(String scanPath, String reportsDir) {
    sh """
        echo "=== CycloneDX SBOM — .NET ==="
        cd "${scanPath}"

        # Method 1: CycloneDX .NET tool
        if dotnet tool list -g 2>/dev/null | grep -qi cyclonedx; then
            echo "Using CycloneDX .NET tool..."
            CSPROJ=\$(find . -maxdepth 2 -name "*.csproj" | head -1)
            if [ -n "\${CSPROJ}" ]; then
                dotnet CycloneDX "\${CSPROJ}" \
                    --json \
                    --output "${reportsDir}/sbom" \
                    --filename "sbom-dotnet.json" 2>/dev/null || true

                dotnet CycloneDX "\${CSPROJ}" \
                    --output "${reportsDir}/sbom" \
                    --filename "sbom-dotnet.xml" 2>/dev/null || true
            fi
        else
            echo "CycloneDX .NET tool not available — using Trivy fallback"
        fi

        echo ".NET SBOM generation complete"
    """
}

// =============================================================================
// Auto-detect language and generate all applicable SBOMs
// =============================================================================
def generateAutoSbom(String scanPath, String reportsDir) {
    sh """
        echo "=== Auto-detecting languages for SBOM generation ==="
        cd "${scanPath}"
    """

    // Detect and generate for each language found
    if (fileExists("${scanPath}/requirements.txt") || fileExists("${scanPath}/setup.py") ||
        fileExists("${scanPath}/pyproject.toml") || fileExists("${scanPath}/Pipfile")) {
        echo "[SBOM] Detected Python project"
        generatePythonSbom(scanPath, reportsDir)
    }

    if (fileExists("${scanPath}/pom.xml")) {
        echo "[SBOM] Detected Java Maven project"
        generateMavenSbom(scanPath, reportsDir)
    }

    if (fileExists("${scanPath}/build.gradle") || fileExists("${scanPath}/build.gradle.kts")) {
        echo "[SBOM] Detected Java Gradle project"
        generateGradleSbom(scanPath, reportsDir)
    }

    if (fileExists("${scanPath}/package.json")) {
        def pkgJson = readFile("${scanPath}/package.json")
        def framework = 'nodejs'
        if (pkgJson.contains('"react"')) framework = 'react'
        else if (pkgJson.contains('"@angular/core"')) framework = 'angular'
        else if (pkgJson.contains('"vue"')) framework = 'vue'
        echo "[SBOM] Detected ${framework} project"
        generateNodeSbom(scanPath, reportsDir, framework)
    }

    if (fileExists("${scanPath}/go.mod")) {
        echo "[SBOM] Detected Go project"
        generateGoSbom(scanPath, reportsDir)
    }

    def csproj = sh(script: "find '${scanPath}' -maxdepth 2 -name '*.csproj' | head -1", returnStdout: true).trim()
    if (csproj) {
        echo "[SBOM] Detected .NET project"
        generateDotnetSbom(scanPath, reportsDir)
    }
}

// =============================================================================
// Trivy SBOM Fallback (works for any language)
// =============================================================================
def generateTrivySbomFallback(String scanPath, String reportsDir, String label) {
    sh """
        echo "=== Trivy CycloneDX SBOM — ${label} ==="

        trivy fs --format cyclonedx \
            --output "${reportsDir}/sbom/sbom-${label}-trivy.json" \
            "${scanPath}" 2>/dev/null || true

        # Also generate SPDX for compliance
        trivy fs --format spdx-json \
            --output "${reportsDir}/sbom/sbom-${label}-spdx.json" \
            "${scanPath}" 2>/dev/null || true

        echo "Trivy SBOM (${label}) generation complete"
    """
}

// =============================================================================
// Generate SBOM Summary
// =============================================================================
def generateSbomSummary(String reportsDir) {
    sh """
        echo "=== Generating SBOM Summary ==="

        python3 <<'PYEOF'
import json, os, glob

sbom_dir = "${reportsDir}/sbom"
summary_lines = []
summary_lines.append("=" * 70)
summary_lines.append("  CycloneDX SBOM GENERATION SUMMARY")
summary_lines.append("=" * 70)

total_components = 0
sbom_files = glob.glob(os.path.join(sbom_dir, "sbom-*.json"))

for sbom_file in sorted(sbom_files):
    basename = os.path.basename(sbom_file)
    try:
        with open(sbom_file) as f:
            data = json.load(f)

        bom_format = data.get("bomFormat", "Unknown")
        spec_version = data.get("specVersion", "Unknown")
        components = data.get("components", [])
        num_components = len(components)
        total_components += num_components

        # Count component types
        types = {}
        for c in components:
            t = c.get("type", "unknown")
            types[t] = types.get(t, 0) + 1

        summary_lines.append(f"")
        summary_lines.append(f"  File: {basename}")
        summary_lines.append(f"    Format:     {bom_format} v{spec_version}")
        summary_lines.append(f"    Components: {num_components}")
        for t, count in sorted(types.items()):
            summary_lines.append(f"      {t}: {count}")

    except Exception as e:
        summary_lines.append(f"")
        summary_lines.append(f"  File: {basename}")
        summary_lines.append(f"    Error parsing: {e}")

summary_lines.append("")
summary_lines.append("=" * 70)
summary_lines.append(f"  TOTAL COMPONENTS ACROSS ALL SBOMS: {total_components}")
summary_lines.append(f"  TOTAL SBOM FILES: {len(sbom_files)}")
summary_lines.append("=" * 70)

summary_text = "\\n".join(summary_lines)
print(summary_text)

with open(os.path.join(sbom_dir, "sbom-summary.txt"), "w") as f:
    f.write(summary_text)

PYEOF
    """
}
