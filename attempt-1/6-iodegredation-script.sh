#!/bin/bash

# Function to find Firecracker processes more reliably
find_firecracker_processes() {
    FC_PID=$(pgrep -f "firecracker.*api-sock" | head -1)
    if [ -z "$FC_PID" ]; then
        echo "Error: Firecracker process not found"
        exit 1
    fi
    
    # Get all child threads of Firecracker
    VCPU_PIDS=$(ps -eLf | grep $FC_PID | grep -v "$FC_PID.*firecracker" | awk '{print $4}' | sort -u)
    
    echo "Firecracker main PID: $FC_PID"
    echo "vCPU/worker thread PIDs: $VCPU_PIDS"
    
    # Alternative method using /proc
    if [ -z "$VCPU_PIDS" ]; then
        VCPU_PIDS=$(find /proc/$FC_PID/task/ -name "[0-9]*" -exec basename {} \; | grep -v "^$FC_PID$")
        echo "Alternative vCPU detection found: $VCPU_PIDS"
    fi
}

# Function to monitor context switches with timestamps
monitor_context_switches() {
    local output_file="context_switches_$(date +%s).log"
    echo "=== Context Switch Monitoring (logging to $output_file) ==="
    
    echo "timestamp,pid,voluntary_switches,nonvoluntary_switches" > $output_file
    
    for i in {1..60}; do
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        for pid in $VCPU_PIDS; do
            if [ -f /proc/$pid/status ]; then
                vol=$(grep voluntary_ctxt_switches /proc/$pid/status | awk '{print $2}')
                nonvol=$(grep nonvoluntary_ctxt_switches /proc/$pid/status | awk '{print $2}')
                echo "$timestamp,$pid,$vol,$nonvol" >> $output_file
                echo "$timestamp: PID $pid - Vol: $vol, NonVol: $nonvol"
            fi
        done
        sleep 1
    done
}

# Function to monitor CPU affinity and migrations
monitor_cpu_affinity() {
    local output_file="cpu_affinity_$(date +%s).log"
    echo "=== CPU Affinity Monitoring (logging to $output_file) ==="
    
    echo "timestamp,pid,cpu_core,cpu_affinity" > $output_file
    
    while true; do
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        for pid in $VCPU_PIDS; do
            if [ -f /proc/$pid/stat ]; then
                # Current CPU core (field 39 in /proc/pid/stat)
                cpu=$(awk '{print $39}' /proc/$pid/stat 2>/dev/null)
                # CPU affinity
                affinity=$(taskset -cp $pid 2>/dev/null | cut -d: -f2 | tr -d ' ')
                echo "$timestamp,$pid,$cpu,$affinity" >> $output_file
                echo "$timestamp: PID $pid running on CPU $cpu, affinity: $affinity"
            fi
        done
        sleep 1
    done
}

# Function to create controlled CPU contention
create_cpu_contention() {
    local duration=${1:-30}
    echo "Creating CPU contention for $duration seconds..."
    
    # Create stress on cores 0 and 1 (where vCPUs are pinned)
    stress-ng --cpu 2 --cpu-ops 1000000 --timeout ${duration}s --taskset 0,1 &
    STRESS_PID=$!
    echo "Started stress-ng with PID: $STRESS_PID on cores 0,1"
    
    return $STRESS_PID
}

# Function to simulate vCPU migration
simulate_vcpu_migration() {
    local cycles=${1:-5}
    echo "Simulating vCPU migration for $cycles cycles..."
    
    for i in $(seq 1 $cycles); do
        echo "Migration cycle $i/$cycles"
        
        # Move vCPUs to cores 2,3
        for pid in $VCPU_PIDS; do
            if [ -f /proc/$pid/stat ]; then
                sudo taskset -cp 2,3 $pid 2>/dev/null
                echo "  Moved PID $pid to cores 2,3"
            fi
        done
        sleep 3
        
        # Move vCPUs back to cores 0,1
        core=0
        for pid in $VCPU_PIDS; do
            if [ -f /proc/$pid/stat ]; then
                sudo taskset -cp $core $pid 2>/dev/null
                echo "  Moved PID $pid back to core $core"
                core=$((core + 1))
            fi
        done
        sleep 3
    done
}

# Function to monitor IO performance correlation
monitor_io_correlation() {
    echo "=== IO Performance Correlation Monitor ==="
    
    # This would require the VM to be running and accessible
    # We'll monitor host-side IO stats for the backing files
    
    local rootfs_file="./$(ls *.ext4 2>/dev/null | head -1)"
    local test_disk="./test-disk.ext4"
    
    if [ -f "$rootfs_file" ] || [ -f "$test_disk" ]; then
        echo "Monitoring IO stats for backing files..."
        iostat -x 1 30 | grep -E "(Device|vd|loop)" | tee io_stats_$(date +%s).log
    else
        echo "No backing files found to monitor"
    fi
}

# Main execution
echo "=== Advanced Firecracker vCPU Monitoring ==="
echo "Finding Firecracker processes..."

find_firecracker_processes

if [ -z "$VCPU_PIDS" ]; then
    echo "No vCPU threads found. Make sure Firecracker VM is running."
    exit 1
fi

echo ""
echo "Choose monitoring mode:"
echo "1) Basic context switch monitoring (60 seconds)"
echo "2) CPU affinity monitoring (press Ctrl+C to stop)"
echo "3) CPU contention test (30 seconds)"
echo "4) vCPU migration test (5 cycles)"
echo "5) Full correlation test (context switches + contention + migration)"
echo "6) IO correlation monitoring"

read -p "Enter choice (1-6): " choice

case $choice in
    1)
        monitor_context_switches
        ;;
    2)
        echo "Starting CPU affinity monitoring (press Ctrl+C to stop)..."
        monitor_cpu_affinity
        ;;
    3)
        monitor_context_switches &
        MONITOR_PID=$!
        sleep 5
        create_cpu_contention 30
        wait $MONITOR_PID
        ;;
    4)
        monitor_cpu_affinity &
        MONITOR_PID=$!
        sleep 5
        simulate_vcpu_migration 5
        kill $MONITOR_PID 2>/dev/null
        ;;
    5)
        echo "Starting full correlation test..."
        monitor_context_switches &
        CONTEXT_PID=$!
        monitor_cpu_affinity &
        AFFINITY_PID=$!
        
        sleep 10
        echo "Starting CPU contention phase..."
        create_cpu_contention 20
        
        sleep 5
        echo "Starting vCPU migration phase..."
        simulate_vcpu_migration 3
        
        sleep 5
        kill $CONTEXT_PID $AFFINITY_PID 2>/dev/null
        echo "Full test completed. Check log files for results."
        ;;
    6)
        monitor_io_correlation
        ;;
    *)
        echo "Invalid choice"
        ;;
esac

echo "Monitoring completed. Log files have been generated with timestamps."