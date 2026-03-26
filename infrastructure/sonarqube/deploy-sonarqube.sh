#!/bin/bash
# =============================================================================
# SonarQube K8s Deployment Script
# =============================================================================
# Deploys SonarQube + PostgreSQL to Kubernetes cluster
# Usage: ./deploy-sonarqube.sh [--delete]
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="sonarqube"
NODEPORT="32001"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $*"; }

# ---------------------------------------------------------------------------
# Delete mode
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--delete" ]]; then
    log_warn "Deleting SonarQube deployment..."
    kubectl delete namespace ${NAMESPACE} --ignore-not-found 2>/dev/null || true
    kubectl delete pv sonarqube-data-pv sonarqube-postgres-pv --ignore-not-found 2>/dev/null || true
    log_info "SonarQube deleted."
    exit 0
fi

echo "============================================================"
echo "  SonarQube Deployment to Kubernetes"
echo "============================================================"

# ---------------------------------------------------------------------------
# 1. Namespace
# ---------------------------------------------------------------------------
log_step "1/7 — Creating namespace"
kubectl apply -f "${SCRIPT_DIR}/namespace.yml"

# ---------------------------------------------------------------------------
# 2. Persistent Volumes
# ---------------------------------------------------------------------------
log_step "2/7 — Creating Persistent Volumes"
kubectl apply -f "${SCRIPT_DIR}/postgres-pv.yml"
kubectl apply -f "${SCRIPT_DIR}/sonarqube-pv.yml"

# ---------------------------------------------------------------------------
# 3. PVCs
# ---------------------------------------------------------------------------
log_step "3/7 — Creating Persistent Volume Claims"
kubectl apply -f "${SCRIPT_DIR}/postgres-pvc.yml"
kubectl apply -f "${SCRIPT_DIR}/sonarqube-pvc.yml"

# ---------------------------------------------------------------------------
# 4. Secrets
# ---------------------------------------------------------------------------
log_step "4/7 — Creating secrets"
kubectl apply -f "${SCRIPT_DIR}/postgres-secrets.yml"

# ---------------------------------------------------------------------------
# 5. PostgreSQL
# ---------------------------------------------------------------------------
log_step "5/7 — Deploying PostgreSQL for SonarQube"
kubectl apply -f "${SCRIPT_DIR}/postgres-deployment.yml"
kubectl apply -f "${SCRIPT_DIR}/postgres-service.yml"

log_info "Waiting for PostgreSQL to be ready..."
kubectl rollout status deployment/sonarqube-postgres -n ${NAMESPACE} --timeout=120s || {
    log_error "PostgreSQL failed to start. Check: kubectl logs -n ${NAMESPACE} -l app=sonarqube-postgres"
    exit 1
}

# ---------------------------------------------------------------------------
# 6. SonarQube
# ---------------------------------------------------------------------------
log_step "6/7 — Deploying SonarQube"
kubectl apply -f "${SCRIPT_DIR}/sonarqube-deployment.yml"
kubectl apply -f "${SCRIPT_DIR}/sonarqube-service.yml"

log_info "Waiting for SonarQube to be ready (this may take 2-5 minutes)..."
kubectl rollout status deployment/sonarqube -n ${NAMESPACE} --timeout=600s || {
    log_error "SonarQube failed to start. Check: kubectl logs -n ${NAMESPACE} -l app=sonarqube"
    exit 1
}

# ---------------------------------------------------------------------------
# 7. Verify
# ---------------------------------------------------------------------------
log_step "7/7 — Verifying deployment"
echo ""
kubectl get pods -n ${NAMESPACE} -o wide
echo ""
kubectl get svc -n ${NAMESPACE}
echo ""

# Get node IPs
WORKER_IP=$(kubectl get node inblrmanappph02 -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "132.186.17.25")
CONTROL_IP=$(kubectl get node inblrmanappph06 -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "132.186.17.22")

echo "============================================================"
echo "  SonarQube Deployment Complete!"
echo "============================================================"
echo ""
echo "  URL:       http://${WORKER_IP}:${NODEPORT}"
echo "  Alt URL:   http://${CONTROL_IP}:${NODEPORT}"
echo ""
echo "  Default Credentials:"
echo "    Username: admin"
echo "    Password: admin"
echo "    (You will be prompted to change on first login)"
echo ""
echo "  Jenkins Integration:"
echo "    SONAR_HOST_URL: http://sonarqube.sonarqube.svc.cluster.local:9000"
echo "    Create token at: http://${WORKER_IP}:${NODEPORT}/account/security"
echo ""
echo "============================================================"
