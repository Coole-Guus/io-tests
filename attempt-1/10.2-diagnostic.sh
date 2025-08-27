#!/bin/bash
# filepath: /home/guus/firecracker-tutorial/10-cgroup-diagnostic.sh

KEY_NAME=./$(ls *.id_rsa 2>/dev/null | tail -1)

echo "=== DEFINITIVE CGROUP CPU LIMITATION DIAGNOSTIC ==="

# Find Firecracker process
FC_PID=$(pgrep -f "^./firecracker" | head -1)
if [ -z "$FC_PID" ]; then
    echo "Error: Firecracker not running"
    exit 1
fi

echo "Firecracker PID: $FC_PID"

# Test 1: CPU stress WITHOUT cgroup limitation
echo ""
echo "=== TEST 1: CPU STRESS WITHOUT LIMITATION ==="
echo "Starting 100% CPU stress in VM..."

ssh -i $KEY_NAME -o StrictHostKeyChecking=no root@172.16.0.2 "
    stress-ng --cpu 1 --cpu-load 100 --timeout 10s > /dev/null 2>&1 &
    echo 'CPU stress started'
" &

echo "Monitoring Firecracker CPU usage (should be high):"
for i in {1..8}; do
    cpu_usage=$(ps -p $FC_PID -o %cpu --no-headers | tr -d ' ')
    load_avg=$(cat /proc/loadavg | cut -d' ' -f1)
    echo "  Second $i: Firecracker CPU=${cpu_usage}%, System Load=${load_avg}"
    sleep 1
done

echo "Waiting for stress to finish..."
sleep 3

# Test 2: Setup cgroup and test again
echo ""
echo "=== TEST 2: SETTING UP 25% CPU LIMITATION ==="

# Detect cgroup version
if [ -f "/sys/fs/cgroup/cgroup.controllers" ]; then
    CGROUP_VERSION=2
    CGROUP_PATH="/sys/fs/cgroup/firecracker_test"
    echo "Using cgroup v2"
    
    # Clean up existing
    if [ -d "$CGROUP_PATH" ]; then
        sudo sh -c "cat $CGROUP_PATH/cgroup.procs > /sys/fs/cgroup/cgroup.procs" 2>/dev/null || true
        sudo rmdir "$CGROUP_PATH" 2>/dev/null || true
    fi
    
    # Create new cgroup
    sudo mkdir -p "$CGROUP_PATH"
    sudo sh -c "echo '+cpu' > $CGROUP_PATH/cgroup.subtree_control" 2>/dev/null || true
    sudo sh -c "echo '25000 100000' > $CGROUP_PATH/cpu.max" 2>/dev/null
    
    # Add ALL threads
    for tid in $(ls /proc/$FC_PID/task/); do
        sudo sh -c "echo $tid > $CGROUP_PATH/cgroup.procs" 2>/dev/null || true
        echo "Added thread $tid to cgroup"
    done
    
    echo "cgroup setup:"
    echo "  CPU limit: $(cat $CGROUP_PATH/cpu.max)"
    echo "  Threads in cgroup: $(cat $CGROUP_PATH/cgroup.procs | wc -l)"
    
else
    echo "cgroup v1 not implemented in this diagnostic"
    exit 1
fi

sleep 2

echo ""
echo "=== TEST 3: CPU STRESS WITH 25% LIMITATION ==="
echo "Starting 100% CPU stress in VM with cgroup limitation..."

ssh -i $KEY_NAME -o StrictHostKeyChecking=no root@172.16.0.2 "
    stress-ng --cpu 1 --cpu-load 100 --timeout 10s > /dev/null 2>&1 &
    echo 'CPU stress started with limitation'
" &

echo "Monitoring Firecracker CPU usage (should be ~25% max):"
for i in {1..8}; do
    cpu_usage=$(ps -p $FC_PID -o %cpu --no-headers | tr -d ' ')
    load_avg=$(cat /proc/loadavg | cut -d' ' -f1)
    
    # Check cgroup CPU usage
    if [ -f "$CGROUP_PATH/cpu.stat" ]; then
        cgroup_usage=$(grep "usage_usec" $CGROUP_PATH/cpu.stat 2>/dev/null | cut -d' ' -f2)
    else
        cgroup_usage="N/A"
    fi
    
    echo "  Second $i: Firecracker CPU=${cpu_usage}%, Load=${load_avg}, cgroup_usage=${cgroup_usage}"
    sleep 1
done

# Test 4: IO performance comparison
echo ""
echo "=== TEST 4: IO PERFORMANCE COMPARISON ==="

# Remove limitation
sudo sh -c "cat $CGROUP_PATH/cgroup.procs > /sys/fs/cgroup/cgroup.procs" 2>/dev/null || true
sudo rmdir "$CGROUP_PATH" 2>/dev/null || true

echo "Testing IO without CPU limitation..."
no_limit_time=$(ssh -i $KEY_NAME -o StrictHostKeyChecking=no root@172.16.0.2 "
    time dd if=/dev/zero of=/dev/vdb bs=4k count=1000 oflag=direct 2>&1 | grep real | cut -d'm' -f2 | cut -d's' -f1
" 2>/dev/null)

echo "IO without limitation: ${no_limit_time}s"

# Setup limitation again
sudo mkdir -p "$CGROUP_PATH"
sudo sh -c "echo '+cpu' > $CGROUP_PATH/cgroup.subtree_control" 2>/dev/null || true
sudo sh -c "echo '25000 100000' > $CGROUP_PATH/cpu.max" 2>/dev/null
for tid in $(ls /proc/$FC_PID/task/); do
    sudo sh -c "echo $tid > $CGROUP_PATH/cgroup.procs" 2>/dev/null || true
done

sleep 1

echo "Testing IO with 25% CPU limitation..."
limited_time=$(ssh -i $KEY_NAME -o StrictHostKeyChecking=no root@172.16.0.2 "
    time dd if=/dev/zero of=/dev/vdb bs=4k count=1000 oflag=direct 2>&1 | grep real | cut -d'm' -f2 | cut -d's' -f1
" 2>/dev/null)

echo "IO with 25% CPU limit: ${limited_time}s"

# Calculate difference
if [ -n "$no_limit_time" ] && [ -n "$limited_time" ]; then
    difference=$(echo "scale=2; $limited_time - $no_limit_time" | bc -l 2>/dev/null || echo "calc_error")
    percentage=$(echo "scale=2; ($limited_time - $no_limit_time) / $no_limit_time * 100" | bc -l 2>/dev/null || echo "calc_error")
    
    echo ""
    echo "=== RESULTS ANALYSIS ==="
    echo "IO time without limitation: ${no_limit_time}s"
    echo "IO time with 25% CPU limit: ${limited_time}s"
    echo "Difference: ${difference}s (${percentage}% slower)"
    
    if [ "$percentage" != "calc_error" ]; then
        if (( $(echo "$percentage < 5" | bc -l) )); then
            echo "⚠️  WARNING: Less than 5% difference - CPU limitation may not be effective!"
        elif (( $(echo "$percentage < 0" | bc -l) )); then
            echo "🚨 ERROR: CPU limited version is FASTER - cgroup is not working!"
        else
            echo "✅ SUCCESS: CPU limitation is working as expected"
        fi
    fi
else
    echo "❌ ERROR: Could not measure IO times properly"
fi

# Cleanup
sudo sh -c "cat $CGROUP_PATH/cgroup.procs > /sys/fs/cgroup/cgroup.procs" 2>/dev/null || true
sudo rmdir "$CGROUP_PATH" 2>/dev/null || true

echo ""
echo "=== DIAGNOSTIC SUMMARY ==="
echo "1. Check if CPU usage was high without limitation (should be ~100%)"
echo "2. Check if CPU usage was limited with cgroup (should be ~25%)"
echo "3. Check if IO performance degraded with CPU limitation"
echo "4. If any of these don't work as expected, the cgroup setup is faulty"