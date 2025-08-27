#!/bin/bash
# filepath: /home/guus/firecracker-tutorial/10-cpu-preemption-io-fixed.sh

KEY_NAME=./$(ls *.id_rsa 2>/dev/null | tail -1)

echo "=== FIRECRACKER CPU PREEMPTION I/O IMPACT TEST (FIXED) ==="
echo "Testing I/O performance when VM is preempted at different CPU quota levels"
echo "This creates REAL preemption where VM is frozen during CPU quota exhaustion"
echo ""

# Global variables
STRESS_PID=""
BASELINE_VERIFIED=false

# Function to ensure clean baseline environment
ensure_clean_baseline() {
    echo "=== ENSURING CLEAN BASELINE ENVIRONMENT ==="
    
    FC_PID=$(pgrep -f "^./firecracker" | head -1)
    if [ -z "$FC_PID" ]; then
        echo "Error: Firecracker not running"
        return 1
    fi
    
    echo "Firecracker PID: $FC_PID"
    
    # Kill any existing stress processes
    echo "Killing any existing stress processes..."
    pkill -f stress-ng || true
    sleep 2
    
    # Remove ALL cgroup constraints
    echo "Removing all cgroup constraints..."
    sudo sh -c "echo $FC_PID > /sys/fs/cgroup/cgroup.procs" 2>/dev/null || true
    for tid in $(ls /proc/$FC_PID/task/ 2>/dev/null); do
        sudo sh -c "echo $tid > /sys/fs/cgroup/cgroup.procs" 2>/dev/null || true
    done
    
    # Move any KVM threads back to root cgroup
    kvm_threads=$(ps -eLo pid,tid,comm | grep -E "(kvm|vhost)" | awk '{print $2}' 2>/dev/null || true)
    for tid in $kvm_threads; do
        sudo sh -c "echo $tid > /sys/fs/cgroup/cgroup.procs" 2>/dev/null || true
    done
    
    # Reset CPU affinity to ALL CPUs
    all_cpus="0-$(($(nproc)-1))"
    echo "Resetting CPU affinity to: $all_cpus"
    sudo taskset -cp $all_cpus $FC_PID 2>/dev/null || true
    for tid in $(ls /proc/$FC_PID/task/ 2>/dev/null); do
        sudo taskset -cp $all_cpus $tid 2>/dev/null || true
    done
    
    # Remove any leftover cgroups
    sudo rmdir /sys/fs/cgroup/firecracker_preemption 2>/dev/null || true
    sudo rmdir /sys/fs/cgroup/kvm_preemption 2>/dev/null || true
    sudo rmdir /sys/fs/cgroup/vm_cpu_limit 2>/dev/null || true
    
    # Wait for system to settle
    echo "Waiting for system to settle..."
    sleep 5
    
    # Verify clean baseline by doing a quick test
    echo "Verifying baseline performance..."
    wall_start=$(date +%s.%N)
    
    dd_output=$(ssh -i $KEY_NAME -o StrictHostKeyChecking=no root@172.16.0.2 "
        sync
        dd if=/dev/zero of=/dev/vdb bs=1M count=4 oflag=direct 2>&1
    " 2>/dev/null)
    
    wall_end=$(date +%s.%N)
    
    if [ -n "$dd_output" ]; then
        dd_time_line=$(echo "$dd_output" | grep "copied")
        dd_reported_seconds=$(echo "$dd_time_line" | grep -o '[0-9.]\+ s' | head -1 | cut -d' ' -f1)
        
        if [ -n "$dd_reported_seconds" ]; then
            wall_clock_ms=$(echo "($wall_end - $wall_start) * 1000" | bc -l)
            dd_reported_ms=$(echo "$dd_reported_seconds * 1000" | bc -l)
            latency_inflation=$(echo "scale=2; $wall_clock_ms / $dd_reported_ms" | bc -l)
            
            echo "Baseline verification:"
            echo "  Wall clock: ${wall_clock_ms}ms"
            echo "  DD reported: ${dd_reported_ms}ms" 
            echo "  Latency inflation: ${latency_inflation}x"
            
            # Check if baseline is reasonable (< 1.5x inflation)
            baseline_ok=$(echo "$latency_inflation < 1.5" | bc -l)
            if [ "$baseline_ok" = "1" ]; then
                echo "✅ Baseline is clean (latency inflation < 1.5x)"
                BASELINE_VERIFIED=true
            else
                echo "⚠️  WARNING: Baseline still shows high latency inflation (${latency_inflation}x)"
                echo "   This may indicate system-level issues affecting the VM"
                BASELINE_VERIFIED=false
            fi
        fi
    fi
    
    echo "Clean baseline setup complete"
    echo ""
}

# Function to create REAL CPU preemption
setup_cpu_preemption() {
    local cpu_quota_percent="$1"  # e.g., 50 for 50%
    
    echo "=== SETTING UP CPU PREEMPTION: ${cpu_quota_percent}% ==="
    
    FC_PID=$(pgrep -f "^./firecracker" | head -1)
    if [ -z "$FC_PID" ]; then
        echo "Error: Firecracker not running"
        exit 1
    fi
    
    echo "Firecracker PID: $FC_PID"
    
    # Method 1: CPU Pinning + Controlled Competition (Most Reliable)
    echo "Method 1: CPU pinning with controlled competition"
    
    # Pin Firecracker to CPU 0
    echo "Pinning Firecracker to CPU 0..."
    sudo taskset -cp 0 $FC_PID
    for tid in $(ls /proc/$FC_PID/task/ 2>/dev/null); do
        sudo taskset -cp 0 $tid 2>/dev/null || true
    done
    
    # Create competing CPU load to achieve desired quota
    competing_load=$((100 - cpu_quota_percent))
    echo "Creating ${competing_load}% competing load on CPU 0..."
    
    stress-ng --cpu 1 --cpu-load $competing_load --timeout 600s &
    STRESS_PID=$!
    sudo taskset -cp 0 $STRESS_PID
    
    # Method 2: cgroup CPU quota (Additional enforcement)
    echo ""
    echo "Method 2: cgroup CPU quota enforcement"
    
    CGROUP_FC_PATH="/sys/fs/cgroup/firecracker_preemption"
    sudo mkdir -p $CGROUP_FC_PATH
    
    if [ -f "/sys/fs/cgroup/cgroup.controllers" ]; then
        # cgroup v2
        echo "Using cgroup v2 for additional CPU enforcement"
        sudo sh -c "echo '+cpu' > $CGROUP_FC_PATH/cgroup.subtree_control" 2>/dev/null || true
        
        # Set CPU quota
        quota_us=$((cpu_quota_percent * 1000))
        sudo sh -c "echo '${quota_us} 100000' > $CGROUP_FC_PATH/cpu.max"
        
        # Add Firecracker process to cgroup
        sudo sh -c "echo $FC_PID > $CGROUP_FC_PATH/cgroup.procs"
        
        # Also add all Firecracker threads
        for tid in $(ls /proc/$FC_PID/task/ 2>/dev/null); do
            sudo sh -c "echo $tid > $CGROUP_FC_PATH/cgroup.procs" 2>/dev/null || true
        done
        
        echo "CPU quota set: $(cat $CGROUP_FC_PATH/cpu.max)"
        echo "Processes in cgroup: $(cat $CGROUP_FC_PATH/cgroup.procs | wc -l)"
    fi
    
    # Method 3: Find and limit KVM threads if possible
    echo ""
    echo "Method 3: KVM thread limitation (if applicable)"
    
    # Look for VM-specific KVM threads
    kvm_threads=$(ps -eLf | grep -E "\[kvm.*\]" | awk '{print $2}' | head -5)  # Limit to first few
    
    if [ -n "$kvm_threads" ]; then
        echo "Found potential KVM threads to limit:"
        ps -eLf | grep -E "\[kvm.*\]" | head -5
        
        CGROUP_KVM_PATH="/sys/fs/cgroup/kvm_preemption"
        sudo mkdir -p $CGROUP_KVM_PATH
        sudo sh -c "echo '+cpu' > $CGROUP_KVM_PATH/cgroup.subtree_control" 2>/dev/null || true
        sudo sh -c "echo '${quota_us} 100000' > $CGROUP_KVM_PATH/cpu.max"
        
        # Limit only a few KVM threads to avoid system instability
        limited_count=0
        for tid in $kvm_threads; do
            if [ $limited_count -lt 3 ]; then  # Limit only first 3 threads
                echo "  Limiting KVM thread $tid"
                sudo sh -c "echo $tid > $CGROUP_KVM_PATH/cgroup.procs" 2>/dev/null || true
                limited_count=$((limited_count + 1))
            fi
        done
        
        echo "Limited $limited_count KVM threads"
    else
        echo "No specific KVM threads found for limitation"
    fi
    
    echo ""
    echo "Setup complete - VM should now be limited to ~${cpu_quota_percent}% CPU"
    sleep 3
    
    # Verify the setup is working
    echo "=== VERIFYING CPU PREEMPTION SETUP ==="
    for i in {1..5}; do
        fc_cpu=$(ps -p $FC_PID -o %cpu --no-headers | tr -d ' ' || echo "N/A")
        stress_cpu=$(ps -p $STRESS_PID -o %cpu --no-headers | tr -d ' ' 2>/dev/null || echo "N/A")
        load_avg=$(cat /proc/loadavg | cut -d' ' -f1)
        
        # Check cgroup CPU usage if available
        if [ -f "$CGROUP_FC_PATH/cpu.stat" ]; then
            cgroup_throttled=$(grep "throttled_usec" $CGROUP_FC_PATH/cpu.stat 2>/dev/null | cut -d' ' -f2)
        else
            cgroup_throttled="N/A"
        fi
        
        echo "  Check $i: FC_CPU=${fc_cpu}%, Stress_CPU=${stress_cpu}%, Load=${load_avg}, Throttled=${cgroup_throttled}us"
        sleep 1
    done
    
    echo "CPU preemption setup verification complete"
    echo ""
}

# Function to remove CPU preemption
cleanup_cpu_preemption() {
    echo ""
    echo "=== CLEANING UP CPU PREEMPTION SETUP ==="
    
    # Kill stress process
    if [ -n "$STRESS_PID" ]; then
        echo "Killing stress process PID: $STRESS_PID"
        kill $STRESS_PID 2>/dev/null || true
        wait $STRESS_PID 2>/dev/null || true
        STRESS_PID=""
    fi
    
    # Move processes back to root cgroup
    FC_PID=$(pgrep -f "^./firecracker" | head -1)
    if [ -n "$FC_PID" ]; then
        # Reset CPU affinity
        all_cpus="0-$(($(nproc)-1))"
        echo "Resetting CPU affinity to: $all_cpus"
        sudo taskset -cp $all_cpus $FC_PID 2>/dev/null || true
        for tid in $(ls /proc/$FC_PID/task/ 2>/dev/null); do
            sudo taskset -cp $all_cpus $tid 2>/dev/null || true
        done
        
        # Move back to root cgroup
        sudo sh -c "echo $FC_PID > /sys/fs/cgroup/cgroup.procs" 2>/dev/null || true
        for tid in $(ls /proc/$FC_PID/task/ 2>/dev/null); do
            sudo sh -c "echo $tid > /sys/fs/cgroup/cgroup.procs" 2>/dev/null || true
        done
    fi
    
    # Move KVM threads back
    kvm_threads=$(ps -eLo pid,tid,comm | grep -E "(kvm|vhost)" | awk '{print $2}' 2>/dev/null || true)
    for tid in $kvm_threads; do
        sudo sh -c "echo $tid > /sys/fs/cgroup/cgroup.procs" 2>/dev/null || true
    done
    
    # Remove cgroups
    sudo rmdir /sys/fs/cgroup/firecracker_preemption 2>/dev/null || true
    sudo rmdir /sys/fs/cgroup/kvm_preemption 2>/dev/null || true
    
    # Wait for cleanup to settle
    sleep 3
    
    echo "CPU preemption cleanup complete"
}

# Function to test I/O performance under CPU preemption
test_io_with_preemption() {
    local test_name="$1"
    local output_file="preemption_io_results_${test_name}_$(date +%s).csv"
    
    echo ""
    echo "=== Testing I/O Performance: $test_name ==="
    echo "Measuring I/O latency and throughput under current CPU configuration"
    
    # CSV header
    echo "test_name,io_pattern,block_size,total_size,operation,iterations,wall_clock_ms,dd_reported_time_ms,actual_throughput_mbps,dd_reported_throughput_mbps,preemption_overhead_ms,effective_cpu_percent" > $output_file
    
    # Test configurations focused on preemption impact
    declare -a test_configs=(
        "4k,256,1MB,Small_IO_Preemption,6"
        "64k,32,2MB,Medium_IO_Preemption,5"  
        "1M,8,8MB,Large_IO_Preemption,4"
        "4M,4,16MB,Huge_IO_Preemption,3"
    )
    
    for config in "${test_configs[@]}"; do
        IFS=',' read -r block_size count total_size pattern_name iterations <<< "$config"
        
        echo ""
        echo "Testing $pattern_name: ${block_size} x ${count} (${total_size}) - ${iterations} iterations"
        
        for iteration in $(seq 1 $iterations); do
            echo "  Iteration $iteration/$iterations..."
            
            # Ensure VM is responsive before test
            if ! ssh -i $KEY_NAME -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@172.16.0.2 "echo ready" >/dev/null 2>&1; then
                echo "    Warning: VM not responsive, skipping iteration"
                continue
            fi
            
            # Measure wall clock time vs dd reported time
            wall_start=$(date +%s.%N)
            
            dd_output=$(ssh -i $KEY_NAME -o StrictHostKeyChecking=no -o ConnectTimeout=30 root@172.16.0.2 "
                sync
                dd if=/dev/zero of=/dev/vdb bs=${block_size} count=${count} oflag=direct 2>&1
            " 2>/dev/null)
            
            wall_end=$(date +%s.%N)
            
            if [ -n "$dd_output" ]; then
                # Extract dd reported time and throughput
                dd_time_line=$(echo "$dd_output" | grep "copied")
                dd_reported_seconds=$(echo "$dd_time_line" | grep -o '[0-9.]\+ s' | head -1 | cut -d' ' -f1)
                dd_reported_throughput=$(echo "$dd_time_line" | grep -o '[0-9.]\+ MB/s' | head -1 | cut -d' ' -f1)
                
                if [ -n "$dd_reported_seconds" ] && [ -n "$dd_reported_throughput" ]; then
                    # Calculate metrics with proper error handling
                    wall_clock_ms=$(echo "($wall_end - $wall_start) * 1000" | bc -l)
                    dd_reported_ms=$(echo "$dd_reported_seconds * 1000" | bc -l)
                    
                    # Calculate actual throughput based on wall clock time
                    case $block_size in
                        *k) size_factor=$(echo "$block_size" | sed 's/k//' | bc -l) ;;
                        *M) size_factor=$(echo "$(echo "$block_size" | sed 's/M//') * 1024" | bc -l) ;;
                        *) size_factor=$block_size ;;
                    esac
                    
                    total_kb=$(echo "$count * $size_factor" | bc -l)
                    total_mb=$(echo "scale=3; $total_kb / 1024" | bc -l)
                    actual_throughput=$(echo "scale=2; $total_mb / ($wall_clock_ms / 1000)" | bc -l)
                    
                    # Calculate preemption metrics
                    preemption_overhead=$(echo "scale=2; $wall_clock_ms - $dd_reported_ms" | bc -l)
                    
                    # Calculate effective CPU percentage (key metric!)
                    if (( $(echo "$wall_clock_ms > 0" | bc -l) )); then
                        effective_cpu_percent=$(echo "scale=1; ($dd_reported_ms / $wall_clock_ms) * 100" | bc -l)
                    else
                        effective_cpu_percent="0.0"
                    fi
                    
                    echo "    Wall clock: ${wall_clock_ms}ms, DD reported: ${dd_reported_ms}ms"
                    echo "    Actual throughput: ${actual_throughput} MB/s, DD reported: ${dd_reported_throughput} MB/s" 
                    echo "    Preemption overhead: ${preemption_overhead}ms, Effective CPU: ${effective_cpu_percent}%"
                    
                    # Save to CSV
                    echo "$test_name,$pattern_name,$block_size,$total_size,write,$iteration,$wall_clock_ms,$dd_reported_ms,$actual_throughput,$dd_reported_throughput,$preemption_overhead,$effective_cpu_percent" >> $output_file
                else
                    echo "    Error: Could not parse dd output"
                fi
            else
                echo "    Error: No dd output received"
            fi
            
            sleep 1
        done
    done
    
    echo ""
    echo "Test results saved to: $output_file"
    
    # Analyze the results immediately
    analyze_preemption_results "$output_file" "$test_name"
}

# Function to analyze preemption test results
analyze_preemption_results() {
    local output_file="$1"
    local test_name="$2"
    
    echo ""
    echo "=== IMMEDIATE ANALYSIS: $test_name ==="
    
    if [ -f "$output_file" ] && [ -s "$output_file" ]; then
        # Calculate key statistics
        stats=$(tail -n +2 "$output_file" | awk -F',' '
        BEGIN { 
            sum_overhead = 0
            sum_effective_cpu = 0
            sum_inflation = 0
            count = 0
            min_effective = 999
            max_effective = 0
        }
        NF >= 12 {
            overhead = $11  # preemption_overhead_ms
            effective_cpu = $12  # effective_cpu_percent
            wall_ms = $7
            dd_ms = $8
            
            if (wall_ms > 0 && dd_ms > 0) {
                inflation = wall_ms / dd_ms
                
                sum_overhead += overhead
                sum_effective_cpu += effective_cpu
                sum_inflation += inflation
                count++
                
                if (effective_cpu < min_effective) min_effective = effective_cpu
                if (effective_cpu > max_effective) max_effective = effective_cpu
            }
        }
        END {
            if (count > 0) {
                avg_overhead = sum_overhead / count
                avg_effective_cpu = sum_effective_cpu / count
                avg_inflation = sum_inflation / count
                
                printf "Records analyzed: %d\n", count
                printf "Average latency inflation: %.2fx\n", avg_inflation
                printf "Average effective CPU: %.1f%% (range: %.1f%% - %.1f%%)\n", avg_effective_cpu, min_effective, max_effective
                printf "Average preemption overhead: %.1f ms\n", avg_overhead
                
                # Determine test success
                if (avg_effective_cpu > 85) {
                    printf "⚠️  Result: Limited preemption detected\n"
                } else if (avg_effective_cpu > 60) {
                    printf "🔧 Result: Moderate preemption detected\n"  
                } else if (avg_effective_cpu > 40) {
                    printf "✅ Result: Significant preemption detected\n"
                } else if (avg_effective_cpu > 20) {
                    printf "✅ Result: Strong preemption detected\n"
                } else {
                    printf "🚨 Result: Extreme preemption detected\n"
                }
            } else {
                printf "❌ No valid records found for analysis\n"
            }
        }')
        
        echo "$stats"
    else
        echo "❌ No valid results file found or file is empty"
    fi
}

# Main execution
main() {
    echo "Starting CPU preemption I/O impact test..."
    echo "Host system: $(nproc) CPU cores, $(free -h | grep '^Mem:' | awk '{print $2}') RAM"
    echo ""
    
    # Check VM connectivity
    if ! ssh -i $KEY_NAME -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@172.16.0.2 echo "ready" 2>/dev/null; then
        echo "❌ Error: Cannot connect to VM"
        exit 1
    fi
    
    # Install required tools
    if ! command -v stress-ng &> /dev/null; then
        echo "Installing required tools..."
        sudo apt-get update && sudo apt-get install -y stress-ng bc
    fi
    
    # Phase 1: Ensure clean baseline
    ensure_clean_baseline
    
    # Phase 2: Test baseline (no preemption)
    echo "=== PHASE 1: BASELINE PERFORMANCE TEST ==="
    test_io_with_preemption "baseline_no_preemption"
    
    if [ "$BASELINE_VERIFIED" = false ]; then
        echo ""
        echo "⚠️  WARNING: Baseline verification failed!"
        echo "   The system may have underlying performance issues."
        echo "   Proceeding with tests, but results should be interpreted carefully."
        echo ""
    fi
    
    # Phase 3: Test 50% CPU preemption
    echo ""
    echo "=== PHASE 2: 50% CPU PREEMPTION TEST ==="
    setup_cpu_preemption 50
    test_io_with_preemption "50_percent_preemption"
    cleanup_cpu_preemption
    
    # Wait for system to settle
    sleep 5
    
    # Phase 4: Test 25% CPU preemption
    echo ""
    echo "=== PHASE 3: 25% CPU PREEMPTION TEST ==="
    setup_cpu_preemption 25
    test_io_with_preemption "25_percent_preemption"
    cleanup_cpu_preemption
    
    # Final summary
    echo ""
    echo "=" * 80
    echo "=== FINAL TEST SUMMARY ==="
    echo "=" * 80
    echo ""
    echo "🎯 Test Objectives:"
    echo "   • Measure I/O performance impact of CPU preemption"
    echo "   • Validate that CPU quotas create measurable latency inflation"
    echo "   • Establish fair comparison baseline for Docker containers"
    echo ""
    echo "📊 Expected Results:"
    echo "   • Baseline: ~1.0x latency inflation, ~100% effective CPU"
    echo "   • 50% preemption: ~2.0x latency inflation, ~50% effective CPU"
    echo "   • 25% preemption: ~4.0x latency inflation, ~25% effective CPU"
    echo ""
    echo "📁 Result Files:"
    ls -la preemption_io_results_*.csv 2>/dev/null | tail -3
    echo ""
    echo "🔬 Next Steps:"
    echo "   1. Analyze results using the Jupyter notebook"
    echo "   2. Compare with Docker container --cpus limitations"  
    echo "   3. Use effective_cpu_percent as key fairness metric"
    echo ""
    echo "Test completed successfully!"
}

# Execute main function
main "$@"