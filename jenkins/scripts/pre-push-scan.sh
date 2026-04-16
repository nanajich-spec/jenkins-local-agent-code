#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

MODE="code-only"
STRICT="false"
OUTPUT_DIR="./security-reports"
PROJECT_PATH="."
COVERAGE_THRESHOLD="70"
IMAGE_NAME=""
IMAGE_TAG="latest"
REGISTRY="132.186.17.22:5000"
RUN_SONAR="false"
RUN_TRIVY="true"
GENERATE_SBOM="true"
SONAR_HOST_URL="${SONAR_HOST_URL:-}"
SONAR_TOKEN="${SONAR_TOKEN:-}"
SONAR_PROJECT_KEY=""

usage() {
  cat <<EOF
Usage: $0 [options]

Unified pre-push scan phases:
  detect -> test -> coverage -> security -> aggregate

Options:
  --path <dir>                 Project path (default: .)
  --mode <mode>                full|code-only|image-only|k8s-manifests (default: code-only)
  --strict                     Enforce blocking gate on critical/test failures
  --output-dir <dir>           Output base directory (default: ./security-reports)
  --coverage-threshold <pct>   Coverage threshold (default: 70)
  --image-name <name>          Image name for image/full mode
  --image-tag <tag>            Image tag (default: latest)
  --registry <registry>        Registry host (default: 132.186.17.22:5000)
  --run-sonar                  Enable SonarQube stage (requires SONAR_HOST_URL/SONAR_TOKEN)
  --no-trivy                   Disable Trivy stage
  --no-sbom                    Disable CycloneDX/SPDX generation
  --sonar-host-url <url>       SonarQube URL override
  --sonar-token <token>        SonarQube token override
  --sonar-project-key <key>    Sonar project key
  -h, --help                   Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --path) PROJECT_PATH="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --strict) STRICT="true"; shift ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --coverage-threshold) COVERAGE_THRESHOLD="$2"; shift 2 ;;
    --image-name) IMAGE_NAME="$2"; shift 2 ;;
    --image-tag) IMAGE_TAG="$2"; shift 2 ;;
    --registry) REGISTRY="$2"; shift 2 ;;
    --run-sonar) RUN_SONAR="true"; shift ;;
    --no-trivy) RUN_TRIVY="false"; shift ;;
    --no-sbom) GENERATE_SBOM="false"; shift ;;
    --sonar-host-url) SONAR_HOST_URL="$2"; shift 2 ;;
    --sonar-token) SONAR_TOKEN="$2"; shift 2 ;;
    --sonar-project-key) SONAR_PROJECT_KEY="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

CMD=(
  "$PYTHON_BIN" "$SCRIPT_DIR/unified_prepush_scan.py"
  --path "$PROJECT_PATH"
  --mode "$MODE"
  --output-dir "$OUTPUT_DIR"
  --coverage-threshold "$COVERAGE_THRESHOLD"
  --image-name "$IMAGE_NAME"
  --image-tag "$IMAGE_TAG"
  --registry "$REGISTRY"
  --sonar-host-url "$SONAR_HOST_URL"
  --sonar-token "$SONAR_TOKEN"
  --sonar-project-key "$SONAR_PROJECT_KEY"
)

if [[ "$STRICT" == "true" ]]; then
  CMD+=(--strict)
fi
if [[ "$RUN_SONAR" == "true" ]]; then
  CMD+=(--run-sonar)
fi
if [[ "$RUN_TRIVY" == "false" ]]; then
  CMD+=(--no-trivy)
fi
if [[ "$GENERATE_SBOM" == "false" ]]; then
  CMD+=(--no-sbom)
fi

"${CMD[@]}"
