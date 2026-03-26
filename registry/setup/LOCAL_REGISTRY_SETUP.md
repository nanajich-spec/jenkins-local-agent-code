# Local Docker Registry Setup - Summary

## Completed Tasks

### 1. Local Docker Registry Created
- **Registry URL**: `132.186.17.22:5000`
- **Container Name**: `registry`
- **Status**: Running and accessible

### 2. Public Images Migrated
The following public images have been successfully pulled and pushed to the local registry:

```
✓ 132.186.17.22:5000/postgres:16
✓ 132.186.17.22:5000/rabbitmq:3-management
✓ 132.186.17.22:5000/ubuntu:latest
```

### 3. Deployment Files Updated
All deployment files have been updated to use the local registry:

**Catool namespace:**
- catool-deployment.yml
- catool-worker-deployment.yml
- catool-postgres-deployment.yml
- catool-mq-deployment.yml
- utility-pod.yml

**Catool-ns namespace:**
- catool-ns-db-deployment.yml
- catool-ns-deployment.yml
- catool-ns-ws-deployment.yml

**Catool-ui namespace:**
- catool-ui-deployment.ym

### 4. Deployments Applied
All updated deployments have been applied to the Kubernetes cluster.

---

## Required Next Steps

### Step 1: Configure Kubernetes to Trust Insecure Registry

The local registry at `132.186.17.22:5000` is running without TLS. You need to configure each Kubernetes node to trust this insecure registry.

**For containerd (most common):**

On each Kubernetes node, edit `/etc/containerd/config.toml` and add:

```toml
[plugins."io.containerd.grpc.v1.cri".registry.configs."132.186.17.22:5000"]
  [plugins."io.containerd.grpc.v1.cri".registry.configs."132.186.17.22:5000".tls]
    insecure_skip_verify = true

[plugins."io.containerd.grpc.v1.cri".registry.mirrors."132.186.17.22:5000"]
  endpoint = ["http://132.186.17.22:5000"]
```

Then restart containerd:
```bash
systemctl restart containerd
```

**For Docker runtime:**

On each node, edit `/etc/docker/daemon.json`:
```json
{
  "insecure-registries": ["132.186.17.22:5000"]
}
```

Then restart Docker:
```bash
systemctl restart docker
```

### Step 2: Build and Push Application Images

The following custom application images need to be built and pushed to the local registry:

#### 1. Catool Application
```bash
# Navigate to catool source directory
cd /path/to/catool/source

# Build the image
podman build -t 132.186.17.22:5000/catool:1-0-0-beta .

# Push to local registry
podman push 132.186.17.22:5000/catool:1-0-0-beta --tls-verify=false
```

#### 2. Catool-NS Application
```bash
# Navigate to catool-ns source directory
cd /path/to/catool-ns/source

# Build the image
podman build -t 132.186.17.22:5000/catool-ns:67-g0a02ff6 .

# Push to local registry
podman push 132.186.17.22:5000/catool-ns:67-g0a02ff6 --tls-verify=false
```

#### 3. Catool-UI Application
```bash
# Navigate to catool-ui source directory
cd /path/to/catool-ui/source

# Build the image
podman build -t 132.186.17.22:5000/catool-ui:259-g0719cf3 .

# Push to local registry
podman push 132.186.17.22:5000/catool-ui:259-g0719cf3 --tls-verify=false
```

### Step 3: Restart Failed Deployments

After configuring the insecure registry and pushing all images:

```bash
# Delete old pods to trigger recreation
kubectl delete pods --all -n catool
kubectl delete pods --all -n catool-ns
kubectl delete pods --all -n catool-ui

# Or rollout restart deployments
kubectl rollout restart deployment -n catool
kubectl rollout restart deployment -n catool-ns
kubectl rollout restart deployment -n catool-ui
```

---

## Verification Commands

### Check Registry Contents
```bash
curl http://132.186.17.22:5000/v2/_catalog
```

### Check Image Tags
```bash
curl http://132.186.17.22:5000/v2/postgres/tags/list
curl http://132.186.17.22:5000/v2/rabbitmq/tags/list
curl http://132.186.17.22:5000/v2/ubuntu/tags/list
```

### Monitor Pod Status
```bash
kubectl get pods -n catool -w
kubectl get pods -n catool-ns -w
kubectl get pods -n catool-ui -w
```

### Check Pod Events (troubleshooting)
```bash
kubectl describe pod <pod-name> -n <namespace>
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
```

---

## Registry Management

### Stop Registry
```bash
podman stop registry
```

### Start Registry
```bash
podman start registry
```

### View Registry Logs
```bash
podman logs registry
```

### Remove Registry (if needed)
```bash
podman stop registry
podman rm registry
```

---

## Alternative: Pull from Original Registry

If you have access to the original registry (perfteam-registry.advantest.com), you can pull and re-push images:

```bash
# Example for catool
podman pull perfteam-registry.advantest.com/catool:1-0-0-beta
podman tag perfteam-registry.advantest.com/catool:1-0-0-beta 132.186.17.22:5000/catool:1-0-0-beta
podman push 132.186.17.22:5000/catool:1-0-0-beta --tls-verify=false
```

Repeat for all application images.

---

## Current Status

**Registry Status**: ✓ Running  
**Public Images**: ✓ Migrated (postgres, rabbitmq, ubuntu)  
**Application Images**: ⚠ Need to be built/pushed  
**K8s Configuration**: ⚠ Needs insecure registry configuration  
**Deployments**: ✓ Applied (waiting for images and registry config)

