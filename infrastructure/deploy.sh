#!/usr/bin/env bash
# =============================================================================
# deploy.sh — One-Command Jenkins Infrastructure Deployment
# =============================================================================
# Deploys all Jenkins K8s resources in the correct order.
#
# Usage:
#   chmod +x deploy.sh
#   ./deploy.sh              # Deploy all
#   ./deploy.sh --delete     # Delete all
#   ./deploy.sh --status     # Check status
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="${SCRIPT_DIR}"
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

info()  { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC}  $*"; }

case "${1:-deploy}" in
    --delete|delete)
        echo "=== Deleting Jenkins Infrastructure ==="
        kubectl delete -f "${INFRA_DIR}/service.yml" 2>/dev/null || true
        kubectl delete -f "${INFRA_DIR}/deployment.yml" 2>/dev/null || true
        kubectl delete -f "${INFRA_DIR}/configmaps/" 2>/dev/null || true
        kubectl delete -f "${INFRA_DIR}/pvc.yml" 2>/dev/null || true
        kubectl delete -f "${INFRA_DIR}/pv.yml" 2>/dev/null || true
        kubectl delete -f "${INFRA_DIR}/service-account.yml" 2>/dev/null || true
        kubectl delete -f "${INFRA_DIR}/namespace.yml" 2>/dev/null || true
        info "Jenkins infrastructure deleted"
        ;;

    --status|status)
        echo "=== Jenkins Infrastructure Status ==="
        kubectl get all -n jenkins 2>/dev/null || warn "Jenkins namespace not found"
        echo ""
        kubectl get pv jenkins-pv 2>/dev/null || true
        ;;

    deploy|*)
        echo "=== Deploying Jenkins Infrastructure ==="
        echo ""

        echo "1/6 Namespace..."
        kubectl apply -f "${INFRA_DIR}/namespace.yml"
        info "Namespace created"

        echo "2/6 Service Account & RBAC..."
        kubectl apply -f "${INFRA_DIR}/service-account.yml"
        info "ServiceAccount + ClusterRoleBinding created"

        echo "3/6 Persistent Volume..."
        kubectl apply -f "${INFRA_DIR}/pv.yml"
        kubectl apply -f "${INFRA_DIR}/pvc.yml"
        info "PV + PVC created"

        echo "4/6 ConfigMaps..."
        kubectl apply -f "${INFRA_DIR}/configmaps/init-groovy.yml"
        kubectl apply -f "${INFRA_DIR}/configmaps/agent-init-groovy.yml"
        info "ConfigMaps created"

        echo "5/6 Deployment..."
        kubectl apply -f "${INFRA_DIR}/deployment.yml"
        info "Deployment created"

        echo "6/6 Service..."
        kubectl apply -f "${INFRA_DIR}/service.yml"
        info "Service created (NodePort 32000)"

        echo ""
        echo "=== Waiting for Jenkins to start... ==="
        kubectl rollout status deployment/jenkins -n jenkins --timeout=300s 2>/dev/null || \
            warn "Rollout not complete yet — check 'kubectl get pods -n jenkins'"

        echo ""
        info "Jenkins deployed!"
        info "Access: http://<node-ip>:32000"
        info "Login:  admin / admin"
        ;;
esac
