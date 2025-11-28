#!/bin/bash
# Debug JupyterLab High CPU Usage - Find Spinlocked Methods
# Usage: ./debug-jupyterlab.sh <jupyter-pod-name> [namespace]

set -e

POD_NAME="${1}"
NAMESPACE="${2:-default}"

if [ -z "$POD_NAME" ]; then
    echo "Usage: $0 <jupyter-pod-name> [namespace]"
    echo ""
    echo "Example:"
    echo "  $0 jupyterlab-deployment-abc123"
    echo "  $0 jupyterlab-deployment-abc123 production"
    exit 1
fi

echo "🔍 Debugging JupyterLab pod: $POD_NAME in namespace: $NAMESPACE"
echo ""

# Check if pod exists
if ! kubectl get pod "$POD_NAME" -n "$NAMESPACE" &>/dev/null; then
    echo "❌ Error: Pod '$POD_NAME' not found in namespace '$NAMESPACE'"
    exit 1
fi

# Get pod information
POD_INFO=$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o json)
NODE_NAME=$(echo "$POD_INFO" | jq -r '.spec.nodeName')

echo "📍 Pod is running on node: $NODE_NAME"
echo ""

# Find JupyterLab process PID
echo "🔎 Finding JupyterLab process..."
PIDS=$(kubectl exec "$POD_NAME" -n "$NAMESPACE" -- sh -c "pgrep -f 'jupyter.*lab' || pgrep -f python" 2>/dev/null || echo "")

if [ -z "$PIDS" ]; then
    echo "⚠️  Could not find JupyterLab process. Trying to find any Python process..."
    PIDS=$(kubectl exec "$POD_NAME" -n "$NAMESPACE" -- pgrep python 2>/dev/null || echo "")
fi

if [ -z "$PIDS" ]; then
    echo "❌ Error: Could not find Python/JupyterLab process in pod"
    echo "   Make sure the pod is running and contains a Python process"
    exit 1
fi

# Use first PID
PID=$(echo "$PIDS" | head -1)
echo "✅ Found process PID: $PID"
echo ""

# Generate unique debug pod name
DEBUG_POD_NAME="py-debug-$(date +%s)"

echo "🚀 Creating Python debug pod: $DEBUG_POD_NAME"
echo "   This pod will have py-spy installed for profiling"
echo ""

# Create debug pod with environment variable for PID
kubectl run "$DEBUG_POD_NAME" \
  --image=python:3.11-slim \
  --overrides="
{
  \"spec\": {
    \"nodeName\": \"$NODE_NAME\",
    \"hostPID\": true,
    \"containers\": [{
      \"name\": \"debug\",
      \"image\": \"python:3.11-slim\",
      \"stdin\": true,
      \"tty\": true,
      \"env\": [{
        \"name\": \"TARGET_PID\",
        \"value\": \"$PID\"
      }],
      \"securityContext\": {
        \"privileged\": true,
        \"capabilities\": {
          \"add\": [\"SYS_PTRACE\"]
        }
      },
      \"command\": [\"bash\", \"-c\", \"
        echo '📦 Installing py-spy...' && \\
        pip install --quiet --no-cache-dir py-spy 2>/dev/null || { \\
          apt-get update -qq >/dev/null 2>&1 && \\
          apt-get install -y -qq gcc python3-dev >/dev/null 2>&1 && \\
          pip install --quiet --no-cache-dir py-spy; \\
        } && \\
        echo '✅ py-spy installed' && \\
        echo '' && \\
        PID=\\\${TARGET_PID:-\\$(pgrep -f 'jupyter.*lab' | head -1 || pgrep python | head -1)} && \\
        if [ -z \\\"\\\$PID\\\" ] || ! ps -p \\\"\\\$PID\\\" >/dev/null 2>&1; then \\
          echo '⚠️  Could not find target process. Searching...' && \\
          PID=\\\$(pgrep -f 'jupyter.*lab' | head -1 || pgrep python | head -1) && \\
          if [ -z \\\"\\\$PID\\\" ]; then \\
            echo '❌ No Python process found' && \\
            exit 1; \\
          fi; \\
        fi && \\
        echo '🎯 Target PID: '\\\$PID && \\
        echo '' && \\
        echo '📊 Quick start commands:' && \\
        echo '  py-spy top --pid '\\\$PID' --subprocesses    # Live CPU view' && \\
        echo '  py-spy dump --pid '\\\$PID' --subprocesses   # Current stacks' && \\
        echo '  py-spy record -o /tmp/profile.svg --pid '\\\$PID' --duration 30 --subprocesses' && \\
        echo '' && \\
        echo '💡 Tip: Look for functions with high %Own that stay at top' && \\
        echo '' && \\
        exec bash
      \"],
      \"resources\": {
        \"requests\": {
          \"memory\": \"256Mi\",
          \"cpu\": \"200m\"
        }
      }
    }]
  }
}" \
  --rm -it --restart=Never
