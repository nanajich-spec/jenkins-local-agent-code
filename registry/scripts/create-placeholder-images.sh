#!/bin/bash
# Script to create placeholder images for testing the registry setup

REGISTRY="132.186.17.22:5000"

echo "========================================================================="
echo "Creating Placeholder Images for Registry Testing"
echo "========================================================================="
echo ""
echo "⚠️  NOTE: These are PLACEHOLDER images for testing the registry only!"
echo "    Real application images need to be built from source or pulled from"
echo "    the original registry when it becomes accessible."
echo ""

# Function to create a placeholder image
create_placeholder() {
    local image_name=$1
    local image_tag=$2
    local full_name="${REGISTRY}/${image_name}:${image_tag}"
    
    echo "Creating placeholder for ${image_name}:${image_tag}..."
    
    # Create a simple Dockerfile
    cat > /tmp/Dockerfile.${image_name} << EOF
FROM docker.io/alpine:latest
LABEL app="${image_name}"
LABEL version="${image_tag}"
LABEL placeholder="true"
RUN echo "This is a placeholder image for ${image_name}:${image_tag}" > /README.txt
RUN echo "Please replace with the actual application image" >> /README.txt
CMD ["sh", "-c", "echo 'Placeholder for ${image_name}:${image_tag}. Replace with real image!' && tail -f /dev/null"]
EOF
    
    # Build the placeholder image
    podman build -f /tmp/Dockerfile.${image_name} -t ${full_name} /tmp/
    
    if [ $? -eq 0 ]; then
        echo "✓ Built placeholder image: ${full_name}"
        
        # Push to registry
        podman push ${full_name} --tls-verify=false
        
        if [ $? -eq 0 ]; then
            echo "✓ Pushed to registry: ${full_name}"
            echo ""
        else
            echo "✗ Failed to push ${full_name}"
            echo ""
            return 1
        fi
    else
        echo "✗ Failed to build placeholder for ${image_name}:${image_tag}"
        echo ""
        return 1
    fi
    
    # Cleanup
    rm -f /tmp/Dockerfile.${image_name}
}

# Create placeholder images
echo "Step 1: Creating placeholder images..."
echo "----------------------------------------"
create_placeholder "catool" "1-0-0-beta"
create_placeholder "catool-ns" "67-g0a02ff6"
create_placeholder "catool-ui" "259-g0719cf3"

echo "========================================================================="
echo "✓ Placeholder images created and pushed to registry!"
echo "========================================================================="
echo ""
echo "Check your registry web UI: http://132.186.17.22:8080"
echo ""
echo "⚠️  IMPORTANT: These are PLACEHOLDER images only!"
echo ""
echo "To replace with real application images:"
echo ""
echo "Option 1: Build from source (if you have Dockerfiles)"
echo "------------------------------------------------------"
echo "cd /path/to/catool/source"
echo "podman build -t ${REGISTRY}/catool:1-0-0-beta ."
echo "podman push ${REGISTRY}/catool:1-0-0-beta --tls-verify=false"
echo ""
echo "cd /path/to/catool-ns/source"
echo "podman build -t ${REGISTRY}/catool-ns:67-g0a02ff6 ."
echo "podman push ${REGISTRY}/catool-ns:67-g0a02ff6 --tls-verify=false"
echo ""
echo "cd /path/to/catool-ui/source"
echo "podman build -t ${REGISTRY}/catool-ui:259-g0719cf3 ."
echo "podman push ${REGISTRY}/catool-ui:259-g0719cf3 --tls-verify=false"
echo ""
echo "Option 2: Load from tar archives (if you have image tars)"
echo "-----------------------------------------------------------"
echo "podman load -i catool-1-0-0-beta.tar"
echo "podman tag <loaded-image-id> ${REGISTRY}/catool:1-0-0-beta"
echo "podman push ${REGISTRY}/catool:1-0-0-beta --tls-verify=false"
echo ""
echo "Option 3: Pull from original registry (when accessible)"
echo "---------------------------------------------------------"
echo "podman pull perfteam-registry.advantest.com/catool:1-0-0-beta"
echo "podman tag perfteam-registry.advantest.com/catool:1-0-0-beta \\"
echo "           ${REGISTRY}/catool:1-0-0-beta"
echo "podman push ${REGISTRY}/catool:1-0-0-beta --tls-verify=false"
echo ""
echo "========================================================================="
echo ""
echo "Next steps to test deployments with placeholders:"
echo ""
echo "1. Configure Kubernetes nodes for insecure registry:"
echo "   bash /root/Downloads/configure-k8s-insecure-registry.sh"
echo ""
echo "2. Restart deployments:"
echo "   kubectl rollout restart deployment -n catool"
echo "   kubectl rollout restart deployment -n catool-ns"
echo "   kubectl rollout restart deployment -n catool-ui"
echo ""
echo "3. Check pod status:"
echo "   kubectl get pods -n catool"
echo ""
echo "========================================================================="
