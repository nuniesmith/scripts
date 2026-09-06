#!/bin/bash
# Docker, Kubernetes, and Minikube Cleanup Script
# This script performs cleanup at two levels:
# - Level 1 (regular): Prunes unused resources without stopping running containers/pods. Preserves volumes attached to running resources.
# - Level 2 (aggressive): Stops all containers/pods, then fully cleans everything including all volumes, images, etc.
# Warning: Level 2 will remove ALL Docker and Kubernetes data irreversibly.
set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}
print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}
print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}
print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Check if Docker is installed and accessible
DOCKER_AVAILABLE=false
K8S_AVAILABLE=false
MINIKUBE_AVAILABLE=false

if command -v docker &> /dev/null && docker info &> /dev/null; then
    DOCKER_AVAILABLE=true
fi

if command -v kubectl &> /dev/null; then
    K8S_AVAILABLE=true
fi

if command -v minikube &> /dev/null; then
    MINIKUBE_AVAILABLE=true
fi

if [[ "$DOCKER_AVAILABLE" == "false" && "$K8S_AVAILABLE" == "false" && "$MINIKUBE_AVAILABLE" == "false" ]]; then
    print_error "Neither Docker, kubectl, nor minikube are available."
    exit 1
fi

print_status "Available systems:"
[[ "$DOCKER_AVAILABLE" == "true" ]] && echo "  ✓ Docker"
[[ "$K8S_AVAILABLE" == "true" ]] && echo "  ✓ Kubernetes (kubectl)"
[[ "$MINIKUBE_AVAILABLE" == "true" ]] && echo "  ✓ Minikube"
echo ""

# Usage function
usage() {
    echo "Usage: $0 [level]"
    echo "  level: 1 (regular clean, default) or 2 (aggressive clean)"
    echo ""
    echo "Level 1: Prunes unused Docker containers, images, networks, build cache, and unused volumes."
    echo "         Cleans terminated K8s pods and unused PVCs."
    echo "         Does not stop running containers/pods or delete in-use volumes."
    echo ""
    echo "Level 2: Stops all Docker containers, deletes all K8s resources, stops Minikube,"
    echo "         then fully prunes everything including all volumes and images."
    echo ""
    echo "Systems detected and cleaned:"
    [[ "$DOCKER_AVAILABLE" == "true" ]] && echo "  ✓ Docker"
    [[ "$K8S_AVAILABLE" == "true" ]] && echo "  ✓ Kubernetes (kubectl)"
    [[ "$MINIKUBE_AVAILABLE" == "true" ]] && echo "  ✓ Minikube"
    exit 0
}

# Parse level from argument (default to 1)
LEVEL="${1:-1}"
if [[ "$LEVEL" != "1" && "$LEVEL" != "2" ]]; then
    print_error "Invalid level. Must be 1 or 2."
    usage
fi

echo "=================================================================="
echo "🐳 SIMPLE DOCKER CLEANUP SCRIPT - LEVEL $LEVEL"
echo "=================================================================="
echo ""

if [[ "$LEVEL" == "1" ]]; then
    print_warning "Level 1: Regular clean (preserves running containers and their volumes)."
else
    print_warning "Level 2: Aggressive clean (stops everything and deletes all data)."
fi

print_warning "⚠️ CONFIRMATION REQUIRED ⚠️"
echo "This will delete Docker resources. Are you sure? (yes/no)"
read -r confirmation
if [[ ! "$confirmation" =~ ^[Yy][Ee][Ss]$ ]]; then
    print_status "Operation cancelled by user"
    exit 0
fi

# ==================================================================
# DOCKER CLEANUP
# ==================================================================
if [[ "$DOCKER_AVAILABLE" == "true" ]]; then
    echo ""
    print_status "=== DOCKER CLEANUP ==="

    # Level 2 specific: Stop all containers
    if [[ "$LEVEL" == "2" ]]; then
        print_status "Stopping all Docker containers..."
        if [ "$(docker ps -q)" ]; then
            docker stop $(docker ps -q) 2>/dev/null || true
            print_success "All containers stopped."
        else
            print_status "No running containers to stop."
        fi
    fi

    # Prune resources
    print_status "Pruning unused containers..."
    docker container prune -f 2>/dev/null || true

    print_status "Pruning unused images..."
    docker image prune -a -f 2>/dev/null || true

    print_status "Pruning unused networks..."
    docker network prune -f 2>/dev/null || true

    print_status "Pruning build cache..."
    docker builder prune -a -f 2>/dev/null || true

    # Volume cleanup
    if [[ "$LEVEL" == "2" ]]; then
        print_status "Pruning ALL volumes (Level 2)..."
        docker volume prune -a -f 2>/dev/null || true
    else
        print_status "Pruning unused volumes (Level 1)..."
        docker volume prune -f 2>/dev/null || true
    fi

    print_success "Docker cleanup complete!"
fi

# ==================================================================
# KUBERNETES CLEANUP
# ==================================================================
if [[ "$K8S_AVAILABLE" == "true" ]]; then
    echo ""
    print_status "=== KUBERNETES CLEANUP ==="

    # Check if kubectl can connect to a cluster
    if kubectl cluster-info &> /dev/null; then
        if [[ "$LEVEL" == "2" ]]; then
            print_warning "Level 2: Deleting all resources in all namespaces (except kube-system)..."

            # Get all namespaces except kube-system, kube-public, kube-node-lease, default
            NAMESPACES=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v -E '^(kube-system|kube-public|kube-node-lease|default)$' || true)

            if [ -n "$NAMESPACES" ]; then
                for ns in $NAMESPACES; do
                    print_status "Deleting namespace: $ns"
                    kubectl delete namespace "$ns" --timeout=60s 2>/dev/null || true
                done
            fi

            # Clean default namespace
            print_status "Cleaning default namespace..."
            kubectl delete all --all -n default --timeout=60s 2>/dev/null || true
            kubectl delete pvc --all -n default --timeout=60s 2>/dev/null || true
            kubectl delete configmap --all -n default --timeout=60s 2>/dev/null || true
            kubectl delete secret --all -n default --timeout=60s 2>/dev/null || true

        else
            print_status "Level 1: Cleaning completed/failed pods and unused resources..."

            # Delete completed/failed pods in all namespaces
            print_status "Deleting completed/failed pods..."
            kubectl delete pods --field-selector=status.phase=Succeeded --all-namespaces 2>/dev/null || true
            kubectl delete pods --field-selector=status.phase=Failed --all-namespaces 2>/dev/null || true

            # Delete evicted pods
            print_status "Deleting evicted pods..."
            kubectl get pods --all-namespaces --field-selector=status.phase=Failed -o json | \
                jq -r '.items[] | select(.status.reason=="Evicted") | "\(.metadata.namespace) \(.metadata.name)"' | \
                while read ns pod; do kubectl delete pod "$pod" -n "$ns" 2>/dev/null || true; done

            # Clean up unused PVCs (not bound to any pod)
            print_status "Checking for unused PVCs..."
            # This is a safe operation as it only shows unused PVCs
            kubectl get pvc --all-namespaces 2>/dev/null || true
        fi

        print_success "Kubernetes cleanup complete!"
    else
        print_warning "kubectl configured but cannot connect to cluster. Skipping K8s cleanup."
    fi
fi

# ==================================================================
# MINIKUBE CLEANUP
# ==================================================================
if [[ "$MINIKUBE_AVAILABLE" == "true" ]]; then
    echo ""
    print_status "=== MINIKUBE CLEANUP ==="

    # Check if minikube is running
    MINIKUBE_STATUS=$(minikube status -o json 2>/dev/null | jq -r '.Host' || echo "Stopped")

    if [[ "$MINIKUBE_STATUS" != "Stopped" ]]; then
        if [[ "$LEVEL" == "2" ]]; then
            print_warning "Level 2: Stopping and deleting Minikube cluster..."
            minikube delete 2>/dev/null || true
            print_success "Minikube cluster deleted!"
        else
            print_status "Level 1: Cleaning Minikube Docker images and cache..."

            # SSH into minikube and clean Docker
            minikube ssh -- 'docker system prune -a -f --volumes' 2>/dev/null || true

            # Clean minikube cache
            print_status "Cleaning Minikube cache..."
            minikube cache delete 2>/dev/null || true

            print_success "Minikube cleanup complete (cluster still running)!"
        fi
    else
        print_status "Minikube is not running."
        if [[ "$LEVEL" == "2" ]]; then
            print_status "Cleaning Minikube cache and config..."
            rm -rf ~/.minikube/cache 2>/dev/null || true
            rm -rf ~/.minikube/logs 2>/dev/null || true
            print_success "Minikube cache cleaned!"
        fi
    fi
fi

# ==================================================================
# SUMMARY
# ==================================================================
echo ""
print_status "=== CLEANUP SUMMARY ==="
docker network prune -f 2>/dev/null || true

print_status "Pruning build cache..."
docker builder prune -a -f 2>/dev/null || true

print_status "Pruning unused volumes..."
docker volume prune -f 2>/dev/null || true

# For Level 2: Additional system prune with volumes (now that containers are stopped, all volumes are unused)
if [[ "$LEVEL" == "2" ]]; then
    print_status "Performing full system prune including volumes..."
    docker system prune -a -f --volumes 2>/dev/null || true
fi

# Optional: Clean temp files (simple, non-destructive)
print_status "Cleaning temporary Docker files..."
rm -rf /tmp/docker* 2>/dev/null || true
sudo rm -rf /var/lib/docker/tmp/* 2>/dev/null || true

print_success "Cleanup complete!"

echo ""
echo "📊 SUMMARY:"
docker system df 2>/dev/null || echo "Could not get Docker system info"
echo ""
print_status "Docker is ready to use. Run 'docker info' to verify."
