# Debugging Applications on EKS with perf_event_paranoid = 4

When debugging applications on AWS EKS, you may encounter `kernel.perf_event_paranoid = 4`, which prevents many debugging tools from working. This guide provides several solutions to work around this limitation.

## Understanding the Problem

`kernel.perf_event_paranoid = 4` is the most restrictive setting and prevents:
- Perf-based profiling tools
- Many debugging tools that rely on kernel events
- Even `kubectl debug` ephemeral containers inherit this restriction

## Solutions

### Solution 1: Use Privileged Ephemeral Containers (Recommended for Quick Debugging)

Create a privileged ephemeral container that can modify sysctl settings:

```bash
# Create a debug pod with privileged access
kubectl run debug-pod --image=busybox --rm -it --privileged --overrides='
{
  "spec": {
    "hostPID": true,
    "hostNetwork": true,
    "containers": [{
      "name": "debug-pod",
      "image": "busybox",
      "stdin": true,
      "tty": true,
      "securityContext": {
        "privileged": true
      },
      "command": ["sh"]
    }]
  }
}'

# Once inside, you can modify sysctl (if you have node access)
# Note: This requires node-level permissions
```

### Solution 2: Use Node Debug Pod with sysctl Modification

Create a DaemonSet or Job that runs on the node with privileged access:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: node-debug-pod
spec:
  hostPID: true
  hostNetwork: true
  hostIPC: true
  containers:
  - name: debug
    image: busybox:latest
    command: ["sleep", "3600"]
    securityContext:
      privileged: true
    volumeMounts:
    - name: sys
      mountPath: /sys
  volumes:
  - name: sys
    hostPath:
      path: /sys
```

Then exec into it and modify sysctl:

```bash
kubectl apply -f node-debug-pod.yaml
kubectl exec -it node-debug-pod -- sh
# Inside the pod:
echo -1 > /proc/sys/kernel/perf_event_paranoid
# Or if you need to modify it for the entire node:
sysctl -w kernel.perf_event_paranoid=-1
```

### Solution 3: Modify EKS Node Configuration

If you control the EKS node configuration, you can modify the sysctl settings at the node level:

#### Option A: Using EKS Node User Data

Add to your node launch template/user data:

```bash
#!/bin/bash
# Modify perf_event_paranoid for debugging
echo "kernel.perf_event_paranoid = -1" >> /etc/sysctl.conf
sysctl -p
```

#### Option B: Using Kubernetes sysctls (Limited Support)

Note: Kubernetes has limited support for sysctls. For `kernel.perf_event_paranoid`, you typically need node-level access.

### Solution 4: Use Alternative Debugging Methods

Instead of perf-based tools, use alternatives that don't require perf events:

#### A. Use strace/ptrace-based debugging

```bash
# Create a debug pod
kubectl run debug --image=busybox --rm -it -- sh

# Install strace (if using a distro image)
apt-get update && apt-get install -y strace

# Attach to your application process
strace -p <PID> -f
```

#### B. Use gdb (GNU Debugger)

```bash
# Use a debug image with gdb
kubectl run gdb-debug --image=alpine:latest --rm -it -- sh

# Install gdb
apk add --no-cache gdb

# Attach to process
gdb -p <PID>
```

#### C. Use Delve for Go applications

```bash
# For Go applications, use Delve debugger
kubectl run delve-debug --image=dlv:latest --rm -it -- sh
```

#### D. Use Node.js Inspector (for Node.js apps)

```bash
# Enable inspector in your Node.js app
node --inspect=0.0.0.0:9229 your-app.js

# Then port-forward and connect with Chrome DevTools
kubectl port-forward <pod-name> 9229:9229
```

### Solution 5: Use kubectl debug with Custom Image

Create a custom debug image with necessary tools:

```dockerfile
FROM ubuntu:latest
RUN apt-get update && apt-get install -y \
    strace \
    gdb \
    tcpdump \
    curl \
    netcat \
    && rm -rf /var/lib/apt/lists/*
CMD ["/bin/bash"]
```

Then use it:

```bash
kubectl debug <pod-name> -it --image=your-debug-image:latest --target=<container-name>
```

### Solution 6: Use AWS Systems Manager (SSM) Session Manager

If your nodes have SSM agent installed, you can access them directly:

```bash
# Get node instance ID
kubectl get node <node-name> -o jsonpath='{.spec.providerID}' | cut -d'/' -f5

# Start SSM session
aws ssm start-session --target <instance-id>

# Once on the node, modify sysctl
sudo sysctl -w kernel.perf_event_paranoid=-1
```

### Solution 7: Use EKS Node Group with Custom AMI

Create a custom AMI with modified sysctl settings:

```bash
# In your node AMI build process
echo "kernel.perf_event_paranoid = -1" >> /etc/sysctl.conf
sysctl -p
```

Then use this AMI for your EKS node group.

## Practical Example: Debugging a Running Pod

Here's a complete example for debugging a pod named `my-app`:

```bash
# 1. Find the node where the pod is running
NODE=$(kubectl get pod my-app -o jsonpath='{.spec.nodeName}')

# 2. Create a privileged debug pod on the same node
kubectl run debug-$(date +%s) \
  --image=busybox \
  --overrides="
{
  \"spec\": {
    \"nodeName\": \"$NODE\",
    \"hostPID\": true,
    \"hostNetwork\": true,
    \"containers\": [{
      \"name\": \"debug\",
      \"image\": \"busybox\",
      \"stdin\": true,
      \"tty\": true,
      \"securityContext\": {
        \"privileged\": true
      },
      \"command\": [\"sh\"]
    }]
  }
}" \
  --rm -it -- sh

# 3. Inside the debug pod, find your application's PID
# (assuming your app is in a container)
ps aux | grep your-app

# 4. Use alternative debugging tools
strace -p <PID>  # If available
# Or use other debugging methods mentioned above
```

## Security Considerations

⚠️ **Warning**: Many of these solutions require privileged access, which poses security risks:

1. **Privileged containers** can access host resources
2. **Modifying sysctls** affects the entire node
3. **Host PID/Network namespaces** break container isolation

**Best Practices**:
- Use these methods only in non-production environments
- Remove debug pods immediately after use
- Use RBAC to restrict who can create privileged pods
- Consider using separate debug node pools
- Audit and log all debug access

## Recommended Approach by Scenario

| Scenario | Recommended Solution |
|----------|---------------------|
| Quick debugging in dev | Solution 1 (Privileged ephemeral container) |
| Production debugging | Solution 4 (Alternative debugging methods) |
| Long-term debugging setup | Solution 7 (Custom AMI) |
| One-time node access | Solution 6 (SSM Session Manager) |
| Container-level debugging | Solution 5 (Custom debug image) |

## Troubleshooting

### kubectl debug still shows perf_event_paranoid = 4

This is expected - ephemeral containers inherit the node's sysctl settings. Use one of the privileged solutions above.

### Permission denied when modifying sysctl

You need either:
- Privileged container access
- Node-level access (SSM, SSH)
- Root access on the node

### Debug tools not working

Try:
1. Verify you're using the correct debugging tool for your use case
2. Check if the tool requires perf events or can use alternatives
3. Consider using application-level debugging (logs, metrics, traces)

## Additional Resources

- [Kubernetes Debugging Documentation](https://kubernetes.io/docs/tasks/debug/)
- [EKS Node Configuration](https://docs.aws.amazon.com/eks/latest/userguide/create-managed-node-group.html)
- [Linux perf_event_paranoid Documentation](https://www.kernel.org/doc/html/latest/admin-guide/perf-security.html)
