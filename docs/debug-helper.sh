#!/bin/bash
# EKS Debugging Helper Script
# This script helps debug applications on EKS when perf_event_paranoid = 4

set -e

POD_NAME="${1}"
NAMESPACE="${2:-default}"
DEBUG_IMAGE="${DEBUG_IMAGE:-ubuntu:latest}"

if [ -z "$POD_NAME" ]; then
    echo "Usage: $0 <pod-name> [namespace]"
    echo ""
    echo "Examples:"
    echo "  $0 my-app-pod"
    echo "  $0 my-app-pod production"
    echo ""
    echo "Environment variables:"
    echo "  DEBUG_IMAGE - Debug container image (default: ubuntu:latest)"
    exit 1
fi

echo "🔍 Finding pod: $POD_NAME in namespace: $NAMESPACE"

# Get pod information
POD_INFO=$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o json 2>/dev/null || {
    echo "❌ Error: Pod '$POD_NAME' not found in namespace '$NAMESPACE'"
    exit 1
})

NODE_NAME=$(echo "$POD_INFO" | jq -r '.spec.nodeName')
CONTAINER_NAME=$(echo "$POD_INFO" | jq -r '.spec.containers[0].name // "main"')

echo "📍 Pod is running on node: $NODE_NAME"
echo "📦 Container name: $CONTAINER_NAME"

# Generate unique debug pod name
DEBUG_POD_NAME="debug-$(date +%s)-$(echo $POD_NAME | cut -c1-10)"

echo "🚀 Creating privileged debug pod: $DEBUG_POD_NAME"

# Create debug pod
kubectl run "$DEBUG_POD_NAME" \
  --image="$DEBUG_IMAGE" \
  --overrides="
{
  \"spec\": {
    \"nodeName\": \"$NODE_NAME\",
    \"hostPID\": true,
    \"hostNetwork\": true,
    \"hostIPC\": true,
    \"containers\": [{
      \"name\": \"debug\",
      \"image\": \"$DEBUG_IMAGE\",
      \"stdin\": true,
      \"tty\": true,
      \"securityContext\": {
        \"privileged\": true,
        \"capabilities\": {
          \"add\": [\"SYS_ADMIN\", \"SYS_PTRACE\", \"NET_ADMIN\"]
        }
      },
      \"command\": [\"bash\"],
      \"volumeMounts\": [{
        \"name\": \"sys\",
        \"mountPath\": \"/sys\"
      }, {
        \"name\": \"proc\",
        \"mountPath\": \"/host/proc\",
        \"readOnly\": true
      }]
    }],
    \"volumes\": [{
      \"name\": \"sys\",
      \"hostPath\": {
        \"path\": \"/sys\"
      }
    }, {
      \"name\": \"proc\",
      \"hostPath\": {
        \"path\": \"/proc\"
      }
    }]
  }
}" \
  --rm -it --restart=Never -- bash || {
    echo "❌ Failed to create debug pod"
    exit 1
}

# Cleanup function
cleanup() {
    echo ""
    echo "🧹 Cleaning up debug pod..."
    kubectl delete pod "$DEBUG_POD_NAME" --ignore-not-found=true 2>/dev/null || true
}

trap cleanup EXIT

echo ""
echo "✅ Debug pod created. You're now in a privileged container."
echo ""
echo "📋 Useful commands inside the debug container:"
echo "   # Check current perf_event_paranoid value"
echo "   cat /proc/sys/kernel/perf_event_paranoid"
echo ""
echo "   # Find your application's PID"
echo "   ps aux | grep <your-app-name>"
echo ""
echo "   # List processes (including host processes)"
echo "   ps aux"
echo ""
echo "   # Use strace (if available)"
echo "   strace -p <PID>"
echo ""
echo "   # Use gdb (if available)"
echo "   gdb -p <PID>"
echo ""
echo "⚠️  Note: Modifying sysctls may require node-level access."
echo "   The debug pod has privileged access but sysctl changes"
echo "   may not persist or affect the entire node."
echo ""
