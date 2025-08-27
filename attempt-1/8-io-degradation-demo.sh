#!/bin/bash

KEY_NAME=./$(ls *.id_rsa 2>/dev/null | tail -1)

if [ ! -f "$KEY_NAME" ]; then
    echo "Error: SSH key not found"
    exit 1
fi

# Function to find Firecracker processes
find_firecracker_processes() {
    FC_PID=$(pgrep -f "firecracker.*api-sock" | head -1)
    if [ -z "$FC_PID" ]; then
        echo "Error: Firecracker process not found"
        exit 1
    fi
    
    # Get vCPU thread PIDs
    VCPU_PIDS=$(ps -eLf | grep $FC_PID | awk '{if($4 != "'$FC_PID'") print $4}' | sort -u | head -2)
    
    echo "Firecracker main PID: $FC_PID"
    echo "Current vCPU thread PIDs: $VCPU_PIDS"
}

# Function to run intensive IO test that bypasses cache
run_intensive_io_test() {
    local test_name="$1"
    local output_file="io_results_${test_name}_$(date +%s).log"
    
    echo "=== Running intensive IO test: $test_name ==="
    
    echo "timestamp,test_type,throughput_mb_s,latency_ms,cpu_utilization" > $output_file
    
    # Clear any existing cache first
    ssh -i $KEY_NAME -o StrictHostKeyChecking=no root@172.16.0.2 "sync; echo 3 > /proc/sys/vm/drop_caches" 2>/dev/null
    
    for i in {1..3}; do
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo "  Iteration $i/3..."
        
        # Large sequential write test with direct IO to bypass cache
        # Using larger block sizes and counts to see real performance
        result=$(ssh -i $KEY_NAME -o StrictHostKeyChecking=no root@172.16.0.2 "
            sync
            echo 3 > /proc/sys/vm/drop_caches
            time dd if=/dev/zero of=/dev/vdb bs=1M count=100 oflag=direct 2>&1
        " 2>/dev/null)
        
        echo "Debug - Write result: $result"
        
        # Extract throughput from dd output
        throughput=$(echo "$result" | grep -o '[0-9.]\+ MB/s' | head -1 | cut -d' ' -f1)
        # Extract time from 'time' command
        real_time=$(echo "$result" | grep "real" | awk '{print $2}' | sed 's/[ms]//g')
        
        if [ -n "$throughput" ]; then
            # Convert time to milliseconds if needed
            if echo "$real_time" | grep -q "m"; then
                minutes=$(echo "$real_time" | cut -d'm' -f1)
                seconds=$(echo "$real_time" | cut -d'm' -f2)
                latency_ms=$(echo "($minutes * 60 + $seconds) * 1000" | bc 2>/dev/null || echo "0")
            else
                latency_ms=$(echo "$real_time * 1000" | bc 2>/dev/null || echo "0")
            fi
            
            echo "$timestamp,write,$throughput,$latency_ms,0" >> $output_file
            echo "    Write: ${throughput} MB/s (${real_time})"
        fi
        
        # Random IO test to stress the system more
        result=$(ssh -i $KEY_NAME -o StrictHostKeyChecking=no root@172.16.0.2 "
            sync
            echo 3 > /proc/sys/vm/drop_caches
            time dd if=/dev/vdb of=/dev/null bs=4k count=10000 iflag=direct 2>&1
        " 2>/dev/null)
        
        throughput=$(echo "$result" | grep -o '[0-9.]\+ MB/s' | head -1 | cut -d' ' -f1)
        real_time=$(echo "$result" | grep "real" | awk '{print $2}' | sed 's/[ms]//g')
        
        if [ -n "$throughput" ]; then
            if echo "$real_time" | grep -q "m"; then
                minutes=$(echo "$real_time" | cut -d'm' -f1)
                seconds=$(echo "$real_time" | cut -d'm' -f2)
                latency_ms=$(echo "($minutes * 60 + $seconds) * 1000" | bc 2>/dev/null || echo "0")
            else
                latency_ms=$(echo "$real_time * 1000" | bc 2>/dev/null || echo "0")
            fi
            
            echo "$timestamp,read,$throughput,$latency_ms,0" >> $output_file
            echo "    Read: ${throughput} MB/s (${real_time})"
        fi
        
        sleep 2  # Allow system to settle between iterations
    done
    
    echo "Results saved to: $output_file"
}

# Function to create heavy CPU contention
create_heavy_cpu_contention() {
    local duration=${1:-30}
    echo "Creating HEAVY CPU contention for $duration seconds..."
    
    # Create multiple stress processes per core to overwhelm the scheduler
    for core in 0 1; do
        for instance in {1..4}; do
            taskset -c $core stress-ng --cpu 1 --cpu-load 100 --timeout ${duration}s &
        done
    done
    
    STRESS_PIDS=$(jobs -p)
    echo "Started multiple stress processes on cores 0,1: $STRESS_PIDS"
    
    return 0
}

# Function to aggressively migrate vCPUs
migrate_vcpus_aggressively() {
    local duration=${1:-20}
    echo "Aggressively migrating vCPUs for $duration seconds..."
    
    local end_time=$(($(date +%s) + duration))
    local cycle=0
    
    while [ $(date +%s) -lt $end_time ]; do
        cycle=$((cycle + 1))
        echo "  Migration cycle $cycle"
        
        # Get current vCPU PIDs
        CURRENT_VCPU_PIDS=$(ps -eLf | grep $FC_PID | awk '{if($4 != "'$FC_PID'") print $4}' | sort -u | head -2)
        
        # Rapidly migrate between different core sets
        case $((cycle % 4)) in
            0) target_cores="0,1" ;;
            1) target_cores="2,3" ;;
            2) target_cores="4,5" ;;
            3) target_cores="6,7" ;;
        esac
        
        for pid in $CURRENT_VCPU_PIDS; do
            if [ -f /proc/$pid/stat ]; then
                sudo taskset -cp $target_cores $pid 2>/dev/null
                echo "    Moved PID $pid to cores $target_cores"
            fi
        done
        
        sleep 0.5  # Very frequent migrations
    done
}

# Function to monitor context switches with fixed CSV format
monitor_context_switches() {
    local duration=${1:-30}
    local output_file="context_switches_during_test_$(date +%s).log"
    
    echo "Monitoring context switches for $duration seconds..."
    echo "timestamp,pid,voluntary_switches,nonvoluntary_switches" > $output_file
    
    local end_time=$(($(date +%s) + duration))
    
    while [ $(date +%s) -lt $end_time ]; do
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        
        # Get current vCPU PIDs
        current_pids=$(ps -eLf | grep $FC_PID | awk '{if($4 != "'$FC_PID'") print $4}' | sort -u | head -2)
        
        for pid in $current_pids; do
            if [ -f /proc/$pid/status ]; then
                vol=$(grep voluntary_ctxt_switches /proc/$pid/status | awk '{print $2}')
                nonvol=$(grep nonvoluntary_ctxt_switches /proc/$pid/status | awk '{print $2}')
                # Fix CSV format - all on one line
                echo "$timestamp,$pid,$vol,$nonvol" >> $output_file
            fi
        done
        sleep 1
    done
    
    echo "Context switch data saved to: $output_file"
}

# Function to create IO stress inside the VM
create_vm_io_stress() {
    local duration=${1:-20}
    echo "Creating IO stress inside VM for $duration seconds..."
    
    # Start background IO operations in the VM
    ssh -i $KEY_NAME -o StrictHostKeyChecking=no root@172.16.0.2 "
        # Create multiple background IO processes
        for i in {1..4}; do
            dd if=/dev/zero of=/tmp/stress_file_\$i bs=1M count=50 &
        done
        
        # Wait for specified duration
        sleep $duration
        
        # Kill background processes
        killall dd 2>/dev/null || true
        rm -f /tmp/stress_file_*
    " &
    
    VM_STRESS_PID=$!
    echo "Started VM IO stress with PID: $VM_STRESS_PID"
}

# Main demonstration
echo "=== ENHANCED IO Degradation Demonstration ==="

# Check if VM is ready
echo "Checking VM connectivity..."
if ! ssh -i $KEY_NAME -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@172.16.0.2 echo "ready" 2>/dev/null; then
    echo "Error: Cannot connect to VM. Make sure it's running on 172.16.0.2"
    exit 1
fi

# Install bc in VM if needed for calculations
ssh -i $KEY_NAME -o StrictHostKeyChecking=no root@172.16.0.2 "command -v bc || (apt-get update && apt-get install -y bc)" 2>/dev/null

# Find Firecracker processes
find_firecracker_processes

echo ""
echo "=== Test 1: Baseline Performance (pinned vCPUs, no contention) ==="
run_intensive_io_test "baseline"

echo ""
echo "=== Test 2: Heavy CPU Contention ==="
monitor_context_switches 35 &
MONITOR_PID=$!

sleep 2
create_heavy_cpu_contention 30 &
STRESS_JOB=$!

sleep 2
run_intensive_io_test "heavy_cpu_contention"

wait $STRESS_JOB 2>/dev/null
wait $MONITOR_PID 2>/dev/null

# Kill any remaining stress processes
killall stress-ng 2>/dev/null || true

echo ""
echo "=== Test 3: Aggressive vCPU Migration + IO Stress ==="
monitor_context_switches 25 &
MONITOR_PID=$!

create_vm_io_stress 20 &
VM_IO_JOB=$!

sleep 2
migrate_vcpus_aggressively 20 &
MIGRATION_JOB=$!

sleep 1
run_intensive_io_test "aggressive_migration"

wait $MIGRATION_JOB 2>/dev/null
wait $VM_IO_JOB 2>/dev/null
wait $MONITOR_PID 2>/dev/null

echo ""
echo "=== RESULTS ANALYSIS ==="

# Function to analyze results
analyze_results() {
    local test_name="$1"
    local log_file=$(ls -t io_results_${test_name}_*.log 2>/dev/null | head -1)
    
    if [ -f "$log_file" ]; then
        echo "$test_name results:"
        write_avg=$(grep "write" "$log_file" | awk -F, '{sum+=$3; count++} END {if(count>0) printf "%.1f", sum/count}')
        read_avg=$(grep "read" "$log_file" | awk -F, '{sum+=$3; count++} END {if(count>0) printf "%.1f", sum/count}')
        write_latency=$(grep "write" "$log_file" | awk -F, '{sum+=$4; count++} END {if(count>0) printf "%.1f", sum/count}')
        read_latency=$(grep "read" "$log_file" | awk -F, '{sum+=$4; count++} END {if(count>0) printf "%.1f", sum/count}')
        
        echo "  Write: ${write_avg} MB/s (avg latency: ${write_latency}ms)"
        echo "  Read: ${read_avg} MB/s (avg latency: ${read_latency}ms)"
    else
        echo "$test_name: No results found"
    fi
}

analyze_results "baseline"
analyze_results "heavy_cpu_contention"
analyze_results "aggressive_migration"

echo ""
echo "Context switch analysis:"
for log in context_switches_during_test_*.log; do
    if [ -f "$log" ]; then
        echo "File: $log"
        echo "  Total voluntary switches: $(tail -n +2 "$log" | awk -F, '{sum+=$3} END {print sum}')"
        echo "  Total involuntary switches: $(tail -n +2 "$log" | awk -F, '{sum+=$4} END {print sum}')"
        echo "  Switch rate per second: $(tail -n +2 "$log" | wc -l)"
    fi
done