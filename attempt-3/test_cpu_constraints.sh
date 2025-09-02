#!/bin/bash

# CPU constraint verification script
# This script helps verify that both container and VM are properly limited to 0.5 vCPU

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

echo "=== CPU Constraint Verification ==="
echo "Target vCPU allocation: $VCPU_COUNT"
echo "Memory limit: ${MEMORY_SIZE_MIB}MB"
echo ""

echo "=== Host CPU Information ==="
echo "Total CPU cores: $(nproc)"
echo "CPU 0 (dedicated for testing): $(lscpu | grep 'Model name' | cut -d: -f2 | xargs)"
echo ""

echo "=== Container CPU Constraints ==="
if docker ps --filter "name=io_test_container" --filter "status=running" | grep -q io_test_container; then
    CONTAINER_ID=$(docker ps -q --filter "name=io_test_container")
    echo "Container Status: Running (ID: $CONTAINER_ID)"
    
    # Check container CPU limits
    CONTAINER_CPU_LIMIT=$(docker inspect io_test_container | grep -i cpu | head -5 || echo "No CPU limits found")
    echo "Container CPU Configuration:"
    echo "$CONTAINER_CPU_LIMIT" | sed 's/^/  /'
    
    # Check container processes
    echo ""
    echo "Container processes:"
    docker exec io_test_container ps aux | head -5 | sed 's/^/  /'
    
    # Test container CPU usage with a brief load
    echo ""
    echo "Testing container CPU constraint (5 second load test)..."
    docker exec -d io_test_container /bin/bash -c "yes > /dev/null" 2>/dev/null || true
    sleep 2
    CONTAINER_CPU=$(docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}" io_test_container | tail -1 | awk '{print $2}')
    echo "Container CPU usage during load: $CONTAINER_CPU"
    docker exec io_test_container pkill yes 2>/dev/null || true
else
    echo "Container Status: Not running"
fi

echo ""
echo "=== Firecracker VM CPU Constraints ==="

# Check if Firecracker is running
if pgrep -f firecracker >/dev/null; then
    FC_PID=$(pgrep -f firecracker | head -1)
    echo "Firecracker monitor PID: $FC_PID"
    
    # Check Firecracker process details
    echo "Firecracker process CPU affinity: $(taskset -cp $FC_PID 2>/dev/null | cut -d: -f2 | tr -d ' ' || echo 'unknown')"
    
    # Find vCPU threads
    echo ""
    echo "Firecracker threads and CPU constraints:"
    ps -T -p $FC_PID -o pid,tid,psr,pcpu,comm 2>/dev/null | sed 's/^/  /' || echo "  Could not list threads"
    
    # Check cgroup constraints
    echo ""
    echo "CPU cgroup status:"
    if [ -d "/sys/fs/cgroup/firecracker_io_test" ]; then
        echo "  cgroup exists: /sys/fs/cgroup/firecracker_io_test"
        if [ -f "/sys/fs/cgroup/firecracker_io_test/cpu.max" ]; then
            CPU_MAX=$(cat /sys/fs/cgroup/firecracker_io_test/cpu.max 2>/dev/null || echo "unknown")
            echo "  CPU limit (cgroup v2): $CPU_MAX"
        fi
        if [ -f "/sys/fs/cgroup/firecracker_io_test/cgroup.procs" ]; then
            PROCS_IN_CGROUP=$(cat /sys/fs/cgroup/firecracker_io_test/cgroup.procs 2>/dev/null | wc -l)
            echo "  Processes in cgroup: $PROCS_IN_CGROUP"
            cat /sys/fs/cgroup/firecracker_io_test/cgroup.procs 2>/dev/null | sed 's/^/    PID: /'
        fi
    elif [ -d "/sys/fs/cgroup/cpu/firecracker_io_test" ]; then
        echo "  cgroup exists: /sys/fs/cgroup/cpu/firecracker_io_test (v1)"
        CPU_PERIOD=$(cat /sys/fs/cgroup/cpu/firecracker_io_test/cpu.cfs_period_us 2>/dev/null || echo "unknown")
        CPU_QUOTA=$(cat /sys/fs/cgroup/cpu/firecracker_io_test/cpu.cfs_quota_us 2>/dev/null || echo "unknown")
        echo "  CPU period: ${CPU_PERIOD}us"
        echo "  CPU quota: ${CPU_QUOTA}us"
        if [ "$CPU_QUOTA" != "unknown" ] && [ "$CPU_PERIOD" != "unknown" ] && [ "$CPU_QUOTA" -gt 0 ] && [ "$CPU_PERIOD" -gt 0 ]; then
            CPU_RATIO=$(echo "scale=2; $CPU_QUOTA / $CPU_PERIOD" | bc 2>/dev/null || echo "unknown")
            echo "  Effective CPU limit: ${CPU_RATIO} cores"
        fi
    else
        echo "  No cgroup found - CPU constraints may not be active"
    fi
    
    # Test VM responsiveness
    if [ -S "$API_SOCKET" ]; then
        echo ""
        echo "VM Status: API socket available"
        
        # Check if we can SSH to the VM to test CPU constraint
        if ping -c 1 -W 2 "$GUEST_IP" >/dev/null 2>&1; then
            echo "VM Network: Reachable at $GUEST_IP"
            echo ""
            echo "Testing VM CPU constraint (5 second load test)..."
            
            # Create a CPU load in the VM and monitor host CPU usage
            ssh -i "./ubuntu-24.04.id_rsa" -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$GUEST_IP" "nohup yes > /dev/null 2>&1 & echo \$! > /tmp/load_pid" 2>/dev/null || true
            sleep 2
            
            # Monitor CPU usage of vCPU threads
            echo "Host CPU usage by Firecracker threads:"
            ps -T -p $FC_PID -o tid,pcpu,psr,comm --no-headers 2>/dev/null | sed 's/^/  /' || echo "  Could not measure"
            
            # Stop the load
            ssh -i "./ubuntu-24.04.id_rsa" -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$GUEST_IP" "kill \$(cat /tmp/load_pid 2>/dev/null) 2>/dev/null; rm -f /tmp/load_pid" 2>/dev/null || true
            
        else
            echo "VM Network: Not reachable"
        fi
    else
        echo "VM Status: API socket not available"
    fi
    
else
    echo "Firecracker Status: Not running"
fi

echo ""
echo "=== Summary ==="
echo "Expected behavior:"
echo "  - Container should be limited to ${VCPU_COUNT} CPU (${VCPU_COUNT}00% max CPU usage)"
echo "  - VM vCPU threads should be pinned to CPU 0"
echo "  - VM vCPU threads should use max ${VCPU_COUNT}00% of CPU 0"
echo "  - Both workloads should show similar performance characteristics"

if [[ "$VCPU_COUNT" =~ ^0\.[0-9]+$ ]]; then
    EXPECTED_PERCENT=$(echo "$VCPU_COUNT * 100" | bc)
    echo ""
    echo "With ${VCPU_COUNT} vCPU limit, you should see:"
    echo "  - CPU usage peaks around ${EXPECTED_PERCENT}% per process"
    echo "  - Fair comparison between container and VM performance"
fi
