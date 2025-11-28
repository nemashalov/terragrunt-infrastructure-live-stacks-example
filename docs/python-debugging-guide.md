# Debugging Python Processes on EKS - Finding Spinlocked Methods

When debugging Python processes (like JupyterLab) with high CPU utilization, you need Python-specific profiling tools, not just system call tracers like `strace`.

## Understanding the Problem

- **strace** traces system calls (syscalls) - useful for I/O bottlenecks, not Python code execution
- **Python profiling** shows which Python functions are consuming CPU
- **Spinlocked methods** are functions stuck in tight loops consuming CPU

## Solution 1: py-spy (Recommended - Works with perf_event_paranoid = 4)

`py-spy` uses `ptrace` (not perf events), so it works even with `perf_event_paranoid = 4`.

### Installation and Usage

```bash
# Option A: Install py-spy in your debug pod
kubectl exec -it <your-pod-name> -- bash
apt-get update && apt-get install -y python3-pip
pip3 install py-spy

# Option B: Use a pre-built image with py-spy
kubectl run py-debug --image=python:3.11 --rm -it -- bash
pip install py-spy

# Find your Python process PID
ps aux | grep python
# or
ps aux | grep jupyter

# Record stack traces for 30 seconds
py-spy record -o profile.svg --pid <PID> --duration 30

# Or get a live top-like view
py-spy top --pid <PID>

# Or dump current stack traces
py-spy dump --pid <PID>

# For multi-threaded applications (like JupyterLab)
py-spy top --pid <PID> --subprocesses
py-spy record -o profile.svg --pid <PID> --duration 30 --subprocesses
```

### Using py-spy from Debug Pod

```bash
# Create debug pod on same node
NODE=$(kubectl get pod <jupyter-pod> -o jsonpath='{.spec.nodeName}')

kubectl run py-debug-$(date +%s) \
  --image=python:3.11 \
  --overrides='{"spec":{"nodeName":"'$NODE'","hostPID":true,"containers":[{"name":"debug","image":"python:3.11","stdin":true,"tty":true,"securityContext":{"privileged":true},"command":["bash"]}]}}' \
  --rm -it -- bash

# Inside debug pod
pip install py-spy
ps aux | grep python  # Find JupyterLab PID
py-spy top --pid <PID> --subprocesses
```

## Solution 2: Python cProfile (Built-in, No External Tools)

If you can modify your JupyterLab startup, add profiling:

```python
# Add to your JupyterLab startup script
import cProfile
import pstats
import signal
import sys

profiler = cProfile.Profile()

def signal_handler(sig, frame):
    profiler.disable()
    stats = pstats.Stats(profiler)
    stats.sort_stats('cumulative')
    stats.print_stats(20)  # Top 20 functions
    sys.exit(0)

signal.signal(signal.SIGUSR1, signal_handler)
profiler.enable()

# Your JupyterLab code here
```

Then trigger profiling:
```bash
kubectl exec <pod-name> -- kill -USR1 <PID>
```

## Solution 3: GDB with Python Extensions

```bash
# Install gdb and Python debugging tools
kubectl exec -it <pod-name> -- bash
apt-get update && apt-get install -y gdb python3-dbg

# Attach to Python process
gdb -p <PID>

# In gdb:
(gdb) py-bt          # Python backtrace
(gdb) py-list        # Show Python source
(gdb) py-print <var> # Print Python variable
(gdb) info threads    # Show all threads
(gdb) thread apply all py-bt  # Stack trace for all threads
```

## Solution 4: Thread Stack Inspection (Find Spinlocks)

For finding spinlocked methods, inspect all threads:

```bash
# Get Python process PID
PID=$(kubectl exec <pod-name> -- pgrep -f jupyter)

# Dump all thread stacks
kubectl exec <pod-name> -- gdb -batch -ex "attach $PID" -ex "thread apply all bt" -ex "detach" -ex "quit"

# Or use py-spy to see thread activity
kubectl exec <pod-name> -- py-spy dump --pid $PID
```

## Solution 5: Custom Debug Container for Python

Create a debug container specifically for Python debugging:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: python-debug-pod
spec:
  hostPID: true
  containers:
  - name: debug
    image: python:3.11
    command: ["sleep", "3600"]
    stdin: true
    tty: true
    securityContext:
      privileged: true
      capabilities:
        add:
        - SYS_PTRACE
    volumeMounts:
    - name: proc
      mountPath: /host/proc
      readOnly: true
  volumes:
  - name: proc
    hostPath:
      path: /proc
```

Then install tools:
```bash
kubectl exec -it python-debug-pod -- bash
pip install py-spy pyinstrument
apt-get update && apt-get install -y gdb strace
```

## Solution 6: JupyterLab-Specific Debugging

Since you're debugging JupyterLab specifically:

### Check JupyterLab Extensions

```bash
kubectl exec <pod-name> -- jupyter labextension list
kubectl exec <pod-name> -- jupyter server extension list
```

### Enable JupyterLab Debug Logging

```bash
# Set debug logging
kubectl exec <pod-name> -- jupyter lab --debug

# Or check logs
kubectl logs <pod-name> -f
```

### Profile JupyterLab Server

```python
# Create a JupyterLab extension to profile
# Save as profile_jupyter.py
import cProfile
import pstats
import io
from IPython.core.magics.execution import _format_time

profiler = cProfile.Profile()
profiler.enable()

# After some time, get stats
profiler.disable()
s = io.StringIO()
ps = pstats.Stats(profiler, stream=s)
ps.sort_stats('cumulative')
ps.print_stats(20)
print(s.getvalue())
```

## Practical Example: Finding Spinlocked Methods in JupyterLab

Here's a complete workflow:

```bash
#!/bin/bash
# Debug JupyterLab high CPU usage

POD_NAME="your-jupyterlab-pod"
NAMESPACE="default"

# Step 1: Get the Python process PID
echo "Finding JupyterLab process..."
PID=$(kubectl exec $POD_NAME -n $NAMESPACE -- pgrep -f "jupyter.*lab" | head -1)
echo "JupyterLab PID: $PID"

# Step 2: Create debug pod on same node
NODE=$(kubectl get pod $POD_NAME -n $NAMESPACE -o jsonpath='{.spec.nodeName}')
echo "Node: $NODE"

# Step 3: Create debug pod with py-spy
DEBUG_POD="py-debug-$(date +%s)"
kubectl run $DEBUG_POD \
  --image=python:3.11 \
  --overrides="{\"spec\":{\"nodeName\":\"$NODE\",\"hostPID\":true,\"containers\":[{\"name\":\"debug\",\"image\":\"python:3.11\",\"stdin\":true,\"tty\":true,\"securityContext\":{\"privileged\":true,\"capabilities\":{\"add\":[\"SYS_PTRACE\"]}},\"command\":[\"bash\"]}]}}" \
  --rm -it --restart=Never -- bash <<EOF

# Install py-spy
pip install py-spy --quiet

# Get live view of CPU usage by function
echo "=== Live CPU usage (press Ctrl+C to stop) ==="
py-spy top --pid $PID --subprocesses

# Record for 30 seconds
echo "=== Recording for 30 seconds ==="
py-spy record -o /tmp/profile.svg --pid $PID --duration 30 --subprocesses

# Dump current stack traces
echo "=== Current stack traces ==="
py-spy dump --pid $PID --subprocesses

EOF

# Step 4: Copy profile if needed
# kubectl cp $DEBUG_POD:/tmp/profile.svg ./profile.svg
```

## Analyzing Results

### py-spy Output Interpretation

```
%Own   %Total  OwnTime  TotalTime  Function (filename:line)
 45.2%  45.2%   12.3s    12.3s     spinlock_method (file.py:123)
 30.1%  30.1%    8.1s     8.1s     another_method (file.py:456)
```

- **%Own**: Percentage of time spent in this function
- **%Total**: Percentage including sub-functions
- **spinlock_method**: Function stuck in a loop

### Common Spinlock Patterns in Python

1. **Busy-wait loops**
```python
while True:
    if condition:
        break
    # No sleep - CPU spins
```

2. **Tight polling loops**
```python
while not ready:
    pass  # Spins CPU
```

3. **Event loops without proper yielding**
```python
while True:
    process_events()  # If this never blocks
```

## Quick Reference Commands

```bash
# Install py-spy in pod
kubectl exec <pod> -- pip install py-spy

# Live CPU view
kubectl exec <pod> -- py-spy top --pid <PID>

# Record profile
kubectl exec <pod> -- py-spy record -o profile.svg --pid <PID> --duration 30

# Dump stacks
kubectl exec <pod> -- py-spy dump --pid <PID>

# Thread-specific (for JupyterLab)
kubectl exec <pod> -- py-spy top --pid <PID> --subprocesses
```

## Why py-spy Works with perf_event_paranoid = 4

- `py-spy` uses `ptrace` (process tracing), not `perf_events`
- `ptrace` is controlled by `ptrace_scope`, not `perf_event_paranoid`
- Works in containers with `SYS_PTRACE` capability (which privileged containers have)

## Security Note

`py-spy` requires:
- `SYS_PTRACE` capability (included in privileged containers)
- Access to `/proc/<pid>` (available with `hostPID: true`)

This is safer than full privileged access but still requires careful RBAC controls.
