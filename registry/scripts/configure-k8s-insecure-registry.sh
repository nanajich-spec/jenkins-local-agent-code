#!/bin/bash
# Script to configure Kubernetes nodes to trust the local insecure registry

REGISTRY_HOST="132.186.17.22:5000"

echo "==================================================================="
echo "Configure Kubernetes Nodes for Insecure Registry"
echo "Registry: $REGISTRY_HOST"
echo "==================================================================="
echo ""

# Detect container runtime
echo "Step 1: Detecting container runtime..."
if which containerd >/dev/null 2>&1; then
    RUNTIME="containerd"
    echo "✓ Detected: containerd"
elif which dockerd >/dev/null 2>&1; then
    RUNTIME="docker"
    echo "✓ Detected: docker"
else
    echo "✗ Could not detect container runtime"
    exit 1
fi
echo ""

# Function to configure containerd
configure_containerd() {
    echo "Configuring containerd for insecure registry..."
    
    CONFIG_FILE="/etc/containerd/config.toml"
    
    # Backup original config
    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" "${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        echo "✓ Backed up $CONFIG_FILE"
    fi
    
    # Check if config already has our registry
    if grep -q "$REGISTRY_HOST" "$CONFIG_FILE" 2>/dev/null; then
        echo "⚠ Registry configuration already exists in $CONFIG_FILE"
        echo "Please review and update manually if needed"
        return
    fi
    
    # Add registry configuration
    cat >> "$CONFIG_FILE" << EOF

# Local insecure registry configuration
[plugins."io.containerd.grpc.v1.cri".registry.configs."$REGISTRY_HOST"]
  [plugins."io.containerd.grpc.v1.cri".registry.configs."$REGISTRY_HOST".tls]
    insecure_skip_verify = true

[plugins."io.containerd.grpc.v1.cri".registry.mirrors."$REGISTRY_HOST"]
  endpoint = ["http://$REGISTRY_HOST"]
EOF
    
    echo "✓ Added registry configuration to $CONFIG_FILE"
    echo ""
    echo "Restarting containerd..."
    systemctl restart containerd
    
    if [ $? -eq 0 ]; then
        echo "✓ containerd restarted successfully"
    else
        echo "✗ Failed to restart containerd"
        exit 1
    fi
}

# Function to configure Docker
configure_docker() {
    echo "Configuring Docker for insecure registry..."
    
    CONFIG_FILE="/etc/docker/daemon.json"
    
    # Backup original config
    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" "${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        echo "✓ Backed up $CONFIG_FILE"
    fi
    
    # Create or update daemon.json
    if [ -f "$CONFIG_FILE" ]; then
        # File exists, check if it has insecure-registries
        if grep -q "insecure-registries" "$CONFIG_FILE"; then
            echo "⚠ insecure-registries already configured in $CONFIG_FILE"
            echo "Please add \"$REGISTRY_HOST\" manually to the array"
            return
        fi
    else
        # Create new daemon.json
        cat > "$CONFIG_FILE" << EOF
{
  "insecure-registries": ["$REGISTRY_HOST"]
}
EOF
        echo "✓ Created $CONFIG_FILE with registry configuration"
    fi
    
    echo ""
    echo "Restarting Docker..."
    systemctl restart docker
    
    if [ $? -eq 0 ]; then
        echo "✓ Docker restarted successfully"
    else
        echo "✗ Failed to restart Docker"
        exit 1
    fi
}

# Configure based on detected runtime
echo "Step 2: Configuring container runtime..."
echo ""

if [ "$RUNTIME" = "containerd" ]; then
    configure_containerd
elif [ "$RUNTIME" = "docker" ]; then
    configure_docker
fi

echo ""
echo "==================================================================="
echo "Configuration Complete!"
echo "==================================================================="
echo ""
echo "Next steps:"
echo "1. If you have multiple Kubernetes nodes, run this script on each node"
echo "2. Build and push your application images to $REGISTRY_HOST"
echo "3. Restart your deployments: kubectl rollout restart deployment -n <namespace>"
echo ""
echo "Test registry access:"
echo "  curl http://$REGISTRY_HOST/v2/_catalog"
echo ""
