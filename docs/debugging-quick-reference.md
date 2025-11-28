# EKS Debugging Quick Reference

## Problem
`kernel.perf_event_paranoid = 4` prevents debugging tools from working on EKS.

## Quick Solutions

### 1. Use the Helper Script (Easiest)
```bash
./docs/debug-helper.sh <your-pod-name> [namespace]
```

### 2. Create Privileged Debug Pod Manually
```bash
# Get node name
NODE=$(kubectl get pod <pod-name> -o jsonpath='{.spec.nodeName}')

# Create debug pod
kubectl run debug-$(date +%s) \
  --image=ubuntu:latest \
  --overrides='{"spec":{"nodeName":"'$NODE'","hostPID":true,"hostNetwork":true,"containers":[{"name":"debug","image":"ubuntu:latest","stdin":true,"tty":true,"securityContext":{"privileged":true},"command":["bash"]}]}}' \
  --rm -it -- bash
```

### 3. Use Alternative Debugging Tools

#### strace (trace system calls)
```bash
kubectl exec -it <pod-name> -- strace -p <PID>
```

#### gdb (GNU Debugger)
```bash
kubectl exec -it <pod-name> -- gdb -p <PID>
```

#### tcpdump (network debugging)
```bash
kubectl exec -it <pod-name> -- tcpdump -i any
```

### 4. Application-Specific Debugging

#### Node.js
```bash
# Enable inspector
node --inspect=0.0.0.0:9229 app.js

# Port forward
kubectl port-forward <pod-name> 9229:9229

# Connect Chrome DevTools to chrome://inspect
```

#### Python
```bash
# Use pdb
python -m pdb your_script.py

# Or remote debugging with debugpy
pip install debugpy
python -m debugpy --listen 0.0.0.0:5678 your_script.py
kubectl port-forward <pod-name> 5678:5678
```

#### Go
```bash
# Use Delve
dlv attach <PID>
# Or
dlv exec ./your-app --headless --listen=:2345 --api-version=2
kubectl port-forward <pod-name> 2345:2345
```

### 5. Modify Node Sysctl (Requires Node Access)

#### Via SSM Session Manager
```bash
# Get instance ID
INSTANCE_ID=$(kubectl get node <node-name> -o jsonpath='{.spec.providerID}' | cut -d'/' -f5)

# Connect via SSM
aws ssm start-session --target $INSTANCE_ID

# Modify sysctl
sudo sysctl -w kernel.perf_event_paranoid=-1
```

#### Via Custom AMI
Add to node user data:
```bash
echo "kernel.perf_event_paranoid = -1" >> /etc/sysctl.conf
sysctl -p
```

## Common Commands Inside Debug Pod

```bash
# Check perf_event_paranoid
cat /proc/sys/kernel/perf_event_paranoid

# Find application PID
ps aux | grep <app-name>

# View process tree
pstree -p

# Check open files
lsof -p <PID>

# Monitor system calls
strace -p <PID> -f

# Network connections
netstat -tulpn
ss -tulpn

# Memory usage
cat /proc/<PID>/status | grep -i vm

# CPU usage
top -p <PID>
```

## Security Notes

⚠️ **Warning**: Privileged pods can access host resources. Use only in:
- Development environments
- Isolated debug clusters
- With proper RBAC restrictions

## Files Created

- `docs/eks-debugging-guide.md` - Comprehensive guide
- `docs/debug-pod.yaml` - Kubernetes manifest for debug pod
- `docs/debug-helper.sh` - Helper script for quick debugging

## See Also

For detailed explanations and more solutions, see [eks-debugging-guide.md](./eks-debugging-guide.md)
