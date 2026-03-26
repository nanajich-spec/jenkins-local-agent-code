#!/bin/bash
# Quick test script to demonstrate pushing images to the registry

REGISTRY="132.186.17.22:5000"

echo "================================================================================"
echo "🧪 REGISTRY PUSH TEST DEMONSTRATION"
echo "================================================================================"
echo ""
echo "Registry URL: $REGISTRY"
echo "Web UI:       http://132.186.17.22:8080"
echo ""
echo "This script will:"
echo "  1. Pull a small test image (Alpine Linux)"
echo "  2. Tag it for your local registry"
echo "  3. Push it to your registry"
echo "  4. Verify it's available"
echo ""
read -p "Press ENTER to continue or Ctrl+C to cancel..."
echo ""

echo "Step 1: Pulling alpine:latest (small ~7MB image)..."
echo "────────────────────────────────────────────────────"
podman pull docker.io/alpine:latest

if [ $? -ne 0 ]; then
    echo "❌ Failed to pull alpine image"
    exit 1
fi
echo "✅ Successfully pulled alpine:latest"
echo ""

echo "Step 2: Tagging image for local registry..."
echo "────────────────────────────────────────────────────"
podman tag docker.io/alpine:latest $REGISTRY/test-alpine:latest

if [ $? -ne 0 ]; then
    echo "❌ Failed to tag image"
    exit 1
fi
echo "✅ Successfully tagged as $REGISTRY/test-alpine:latest"
echo ""

echo "Step 3: Pushing to local registry..."
echo "────────────────────────────────────────────────────"
podman push $REGISTRY/test-alpine:latest --tls-verify=false

if [ $? -ne 0 ]; then
    echo "❌ Failed to push image"
    exit 1
fi
echo "✅ Successfully pushed to $REGISTRY"
echo ""

echo "Step 4: Verifying image in registry..."
echo "────────────────────────────────────────────────────"
echo ""
echo "📋 All images in registry:"
curl -s http://$REGISTRY/v2/_catalog | jq .
echo ""

echo "🏷️  Tags for test-alpine:"
curl -s http://$REGISTRY/v2/test-alpine/tags/list | jq .
echo ""

echo "================================================================================"
echo "✅ TEST COMPLETED SUCCESSFULLY!"
echo "================================================================================"
echo ""
echo "🌐 View in your browser:"
echo "   http://132.186.17.22:8080"
echo ""
echo "   You should now see 'test-alpine' in the web interface!"
echo ""
echo "📦 To use this pattern for your real images:"
echo ""
echo "For catool:"
echo "  docker build -t $REGISTRY/catool:1-0-0-beta /path/to/catool/"
echo "  docker push $REGISTRY/catool:1-0-0-beta"
echo ""
echo "For catool-ns:"
echo "  docker build -t $REGISTRY/catool-ns:67-g0a02ff6 /path/to/catool-ns/"
echo "  docker push $REGISTRY/catool-ns:67-g0a02ff6"
echo ""
echo "For catool-ui:"
echo "  docker build -t $REGISTRY/catool-ui:259-g0719cf3 /path/to/catool-ui/"
echo "  docker push $REGISTRY/catool-ui:259-g0719cf3"
echo ""
echo "================================================================================"
