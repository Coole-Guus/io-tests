#!/bin/bash

# CPU-Constrained IO Performance Comparison Framework
# Tests the impact of CPU limitations on IO performance
# Compares Firecracker VMs vs Docker containers under CPU stress

set -e

# Configuration
TEST_DURATION=${TEST_DURATION:-30}
DATA_SIZE_MB=${DATA_SIZE_MB:-500}
ITERATIONS=${ITERATIONS:-3}
RESULTS_DIR="./cpu_constrained_io_results_$(date +%Y%m%d_%H%M%S)"

# CPU constraint configurations to test
declare -A CPU_CONSTRAINTS=(
    ["baseline"]="No CPU constraints (baseline)"
    ["cpu_50"]="50% CPU allocation"
    ["cpu_25"]="25% CPU allocation" 
    ["cpu_10"]="10% CPU allocation"
    ["high_load"]="High CPU contention (stress test)"
)

# Test patterns - focused on representative scenarios
declare -A IO_PATTERNS=(
    ["random_write_4k"]="fio --name=random_write_4k --rw=randwrite --size=8M --bs=4k --numjobs=1 --runtime=15s --time_based --group_reporting --filename=rand_4k_file --fsync=1 --direct=1"
    ["random_read_4k"]="fio --name=random_read_4k --rw=randread --size=8M --bs=4k --numjobs=1 --runtime=15s --time_based --group_reporting --filename=rand_4k_file --direct=1"
    ["mixed_4k"]="fio --name=mixed_4k --rw=randrw --rwmixread=70 --size=8M --bs=4k --numjobs=1 --runtime=15s --time_based --group_reporting --filename=mixed_4k_file --fsync=1 --direct=1"
    ["sequential_write_64k"]="fio --name=seq_write_64k --rw=write --size=10M --bs=64k --numjobs=1 --runtime=15s --time_based --group_reporting --filename=seq_64k_file --fsync=1 --direct=1"
    ["random_read_64k"]="fio --name=random_read_64k --rw=randread --size=10M --bs=64k --numjobs=1 --runtime=15s --time_based --group_reporting --filename=rand_64k_file --direct=1"
)

# Network configuration
TAP_DEV="tap1"
TAP_IP="172.17.0.1"
GUEST_IP="172.17.0.2"
MASK_SHORT="/30"
FC_MAC="06:00:AC:11:00:02"

# Firecracker configuration
API_SOCKET="/tmp/firecracker-cpu-test.socket"
LOGFILE="./logs/firecracker-cpu-test.log"

# CPU stress control variables
STRESS_PIDS=()
CONTAINER_STRESS_PID=""

# Cleanup function
cleanup() {
    echo "Cleaning up CPU constraint test environment..."
    
    # Stop all stress processes
    for pid in "${STRESS_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            echo "Stopping stress process $pid"
            kill "$pid" 2>/dev/null || true
        fi
    done
    STRESS_PIDS=()
    
    # Stop container stress process
    if [ -n "$CONTAINER_STRESS_PID" ]; then
        docker exec io_test_container pkill -f "stress|dd" 2>/dev/null || true
    fi
    
    # Stop Firecracker VM
    if [ -S "$API_SOCKET" ]; then
        echo "Stopping Firecracker VM..."
        sudo curl -X PUT --unix-socket "${API_SOCKET}" \
            --data '{"action_type": "SendCtrlAltDel"}' \
            "http://localhost/actions" 2>/dev/null || true
        sleep 2
        sudo pkill -f "firecracker.*${API_SOCKET}" 2>/dev/null || true
    fi
    
    # Remove socket
    sudo rm -f "$API_SOCKET"
    
    # Cleanup container
    docker stop io_test_container 2>/dev/null || true
    docker rm io_test_container 2>/dev/null || true
    
    # Cleanup network
    sudo ip link del "$TAP_DEV" 2>/dev/null || true
    
    echo "CPU constraint test cleanup complete"
}

trap cleanup EXIT

# Get host network interface
get_host_interface() {
    ip route | grep default | awk '{print $5}' | head -1
}

# Apply CPU constraints to containers
apply_container_cpu_constraint() {
    local constraint_type="$1"
    local container_name="io_test_container"
    
    echo "Applying container CPU constraint: $constraint_type"
    
    case "$constraint_type" in
        "baseline")
            echo "No CPU constraints applied to container"
            ;;
        "cpu_50")
            docker update --cpus="0.5" "$container_name"
            echo "Container CPU limited to 50%"
            ;;
        "cpu_25")
            docker update --cpus="0.25" "$container_name"
            echo "Container CPU limited to 25%"
            ;;
        "cpu_10")
            docker update --cpus="0.1" "$container_name"
            echo "Container CPU limited to 10%"
            ;;
        "high_load")
            docker update --cpus="1.0" "$container_name"
            echo "Starting CPU stress inside container..."
            # Start CPU stress inside container (background process)
            docker exec -d "$container_name" stress --cpu 2 --timeout 300 2>/dev/null || \
            docker exec -d "$container_name" sh -c 'for i in {1..2}; do dd if=/dev/zero of=/dev/null bs=1M & done; sleep 300; pkill dd' &
            CONTAINER_STRESS_PID=$!
            echo "Container under high CPU load"
            ;;
        *)
            echo "Unknown container constraint type: $constraint_type"
            return 1
            ;;
    esac
}

# Apply CPU constraints to Firecracker VM (via host-side stress)
apply_firecracker_cpu_constraint() {
    local constraint_type="$1"
    
    echo "Applying Firecracker CPU constraint: $constraint_type"
    
    # Clean up any existing stress processes
    for pid in "${STRESS_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done
    STRESS_PIDS=()
    
    case "$constraint_type" in
        "baseline")
            echo "No CPU constraints applied to Firecracker VM"
            ;;
        "cpu_50"|"cpu_25"|"cpu_10")
            # For Firecracker, we create host-side CPU contention
            # This affects the VM indirectly by competing for CPU resources
            local stress_intensity
            case "$constraint_type" in
                "cpu_50") stress_intensity=1 ;;  # Light stress
                "cpu_25") stress_intensity=2 ;;  # Medium stress  
                "cpu_10") stress_intensity=3 ;;  # Heavy stress
            esac
            
            echo "Starting host-side CPU stress (intensity: $stress_intensity) to constrain Firecracker VM"
            for i in $(seq 1 $stress_intensity); do
                # CPU spinning process with nice priority to not completely block system
                nice -n 10 bash -c 'while true; do :; done' &
                STRESS_PIDS+=($!)
            done
            echo "Started ${#STRESS_PIDS[@]} CPU stress processes for Firecracker constraint"
            ;;
        "high_load")
            echo "Starting intensive host-side CPU stress for Firecracker VM"
            # Create significant CPU contention on host
            for i in $(seq 1 4); do
                nice -n 10 bash -c 'while true; do :; done' &
                STRESS_PIDS+=($!)
            done
            # Also create some I/O stress that might affect VM performance
            nice -n 10 bash -c 'while true; do dd if=/dev/zero of=/dev/null bs=1M count=100 2>/dev/null; done' &
            STRESS_PIDS+=($!)
            echo "Started ${#STRESS_PIDS[@]} intensive stress processes for Firecracker"
            ;;
        *)
            echo "Unknown Firecracker constraint type: $constraint_type"
            return 1
            ;;
    esac
    
    # Give stress processes time to start
    if [ ${#STRESS_PIDS[@]} -gt 0 ]; then
        sleep 3
        echo "CPU constraint applied, load average: $(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}')"
    fi
}

# Setup network for Firecracker
setup_network() {
    echo "Setting up network..."
    
    # Remove existing tap device if it exists
    sudo ip link del "$TAP_DEV" 2>/dev/null || true
    
    # Create and configure tap device
    sudo ip tuntap add "$TAP_DEV" mode tap
    sudo ip addr add "${TAP_IP}${MASK_SHORT}" dev "$TAP_DEV"
    sudo ip link set dev "$TAP_DEV" up
    
    # Enable IP forwarding and setup iptables
    sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
    sudo iptables -t nat -A POSTROUTING -o "$(get_host_interface)" -j MASQUERADE
}

# Setup Firecracker VM
setup_firecracker_vm() {
    echo "Setting up Firecracker VM..."
    
    # Ensure clean state
    sudo pkill -f "firecracker.*${API_SOCKET}" 2>/dev/null || true
    sudo rm -f "$API_SOCKET"
    
    setup_network
    
    # Start Firecracker
    sudo ../firecracker --api-sock "${API_SOCKET}" --log-path "${LOGFILE}" --level Debug &
    sleep 2
    
    # Configure VM
    sudo curl -X PUT --unix-socket "${API_SOCKET}" \
        --data '{
            "kernel_image_path": "./vmlinux-6.1.128",
            "boot_args": "console=ttyS0 reboot=k panic=1 pci=off"
        }' \
        "http://localhost/boot-source"
    
    sudo curl -X PUT --unix-socket "${API_SOCKET}" \
        --data '{
            "drives": [
                {
                    "drive_id": "rootfs",
                    "path_on_host": "./ubuntu-24.04.ext4",
                    "is_root_device": true,
                    "is_read_only": false
                }
            ]
        }' \
        "http://localhost/drives/rootfs"
    
    sudo curl -X PUT --unix-socket "${API_SOCKET}" \
        --data '{
            "network_interfaces": [
                {
                    "iface_id": "eth0",
                    "guest_mac": "'${FC_MAC}'",
                    "host_dev_name": "'${TAP_DEV}'"
                }
            ]
        }' \
        "http://localhost/network-interfaces/eth0"
    
    sudo curl -X PUT --unix-socket "${API_SOCKET}" \
        --data '{
            "vcpu_count": 1,
            "mem_size_mib": 256
        }' \
        "http://localhost/machine-config"
    
    # Start VM
    sudo curl -X PUT --unix-socket "${API_SOCKET}" \
        --data '{"action_type": "InstanceStart"}' \
        "http://localhost/actions"
    
    # Wait for VM to boot
    echo "Waiting for VM to boot..."
    local count=0
    while [ $count -lt 30 ]; do
        if timeout 5 ssh -i "./ubuntu-24.04.id_rsa" -o StrictHostKeyChecking=no root@"$GUEST_IP" "echo 'VM Ready'" 2>/dev/null; then
            break
        fi
        count=$((count + 1))
        sleep 2
    done
    
    # Setup test environment in VM
    ssh -i "./ubuntu-24.04.id_rsa" -o StrictHostKeyChecking=no root@"$GUEST_IP" "
        mkdir -p /root/test_data
        cd /root/test_data && rm -rf ./* 2>/dev/null || true
        apt-get update -qq && apt-get install -y fio sysstat bc
        echo 'Firecracker VM ready for CPU constraint testing'
    "
}

# Setup container
setup_container() {
    echo "Setting up test container for CPU constraint testing..."
    
    # Stop any existing container
    docker stop io_test_container 2>/dev/null || true
    docker rm io_test_container 2>/dev/null || true
    
    # Start container (will be constrained later)
    docker run -d \
        --name io_test_container \
        --network host \
        --privileged \
        ubuntu:20.04 \
        /bin/bash -c "
            apt-get update -qq && 
            apt-get install -y fio sysstat bc stress procps && 
            mkdir -p /root/test_data &&
            cd /root/test_data && rm -rf ./* 2>/dev/null || true &&
            echo 'Container ready for CPU constraint testing' && 
            sleep 3600
        "
    
    # Wait for container to be ready
    echo "Waiting for container to be ready..."
    local count=0
    while [ $count -lt 60 ]; do
        if docker exec io_test_container fio --version >/dev/null 2>&1; then
            echo "Container is ready"
            return 0
        fi
        count=$((count + 1))
        sleep 2
    done
    
    echo "Container setup failed"
    return 1
}

# Run IO test on container with CPU constraints
run_container_io_test() {
    local test_name="$1"
    local constraint_type="$2"
    local io_command="$3"
    local output_file="$4"
    
    echo "Running container test: $test_name with $constraint_type constraint"
    
    # Apply CPU constraint
    apply_container_cpu_constraint "$constraint_type"
    
    # Wait a moment for constraints to take effect
    sleep 2
    
    # Run the test
    local start_time=$(date +%s.%N)
    
    # Check CPU utilization before test
    local pre_cpu=$(docker exec io_test_container sh -c "grep 'cpu ' /proc/stat | awk '{usage=(\$2+\$4)*100/(\$2+\$3+\$4+\$5)} END {print usage}'" 2>/dev/null || echo "0")
    
    # Execute fio test
    docker exec io_test_container /bin/bash -c "cd /root/test_data && $io_command" > /tmp/container_fio_output.txt 2>&1
    local exit_code=$?
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)
    
    # Check CPU utilization after test  
    local post_cpu=$(docker exec io_test_container sh -c "grep 'cpu ' /proc/stat | awk '{usage=(\$2+\$4)*100/(\$2+\$3+\$4+\$5)} END {print usage}'" 2>/dev/null || echo "0")
    
    # Parse fio output
    local throughput="0"
    local latency="0"
    local iops="0"
    
    if [ $exit_code -eq 0 ]; then
        # Parse mixed workload (separate read/write stats)
        if grep -q "read:" /tmp/container_fio_output.txt && grep -q "write:" /tmp/container_fio_output.txt; then
            local read_bw=$(grep "read:" /tmp/container_fio_output.txt | grep -o "BW=[0-9.]*[KMG]*B/s" | sed 's/BW=//' | head -1)
            local write_bw=$(grep "write:" /tmp/container_fio_output.txt | grep -o "BW=[0-9.]*[KMG]*B/s" | sed 's/BW=//' | head -1)
            local read_lat=$(grep "read:" /tmp/container_fio_output.txt | grep -o "lat.*avg=[^,]*" | grep -o "[0-9.]*" | head -1)
            local write_lat=$(grep "write:" /tmp/container_fio_output.txt | grep -o "lat.*avg=[^,]*" | grep -o "[0-9.]*" | head -1)
            
            # Convert and combine throughput
            read_bw_mb=$(echo "$read_bw" | sed 's/[KMG]*B\/s//' | awk '{if(index($0,"K")) print $0/1024; else if(index($0,"G")) print $0*1024; else print $0}' 2>/dev/null || echo "0")
            write_bw_mb=$(echo "$write_bw" | sed 's/[KMG]*B\/s//' | awk '{if(index($0,"K")) print $0/1024; else if(index($0,"G")) print $0*1024; else print $0}' 2>/dev/null || echo "0")
            throughput=$(echo "$read_bw_mb + $write_bw_mb" | bc 2>/dev/null || echo "0")
            
            # Weighted average latency (70% read, 30% write)
            if [ "$read_lat" != "" ] && [ "$write_lat" != "" ]; then
                latency=$(echo "scale=2; ($read_lat * 0.7) + ($write_lat * 0.3)" | bc 2>/dev/null || echo "0")
            fi
        else
            # Single operation type
            throughput=$(grep -o "BW=[0-9.]*[KMG]*B/s" /tmp/container_fio_output.txt | sed 's/BW=//' | head -1 | sed 's/[KMG]*B\/s//' | awk '{if(index($0,"K")) print $0/1024; else if(index($0,"G")) print $0*1024; else print $0}' 2>/dev/null || echo "0")
            latency=$(grep -o "lat.*avg=[^,]*" /tmp/container_fio_output.txt | grep -o "[0-9.]*" | head -1 || echo "0")
        fi
        
        iops=$(grep -o "IOPS=[0-9.]*[km]*" /tmp/container_fio_output.txt | sed 's/IOPS=//' | head -1 | awk '{if(index($0,"k")) print $0*1000; else if(index($0,"m")) print $0*1000000; else print $0}' 2>/dev/null || echo "0")
    fi
    
    # Get system load
    local load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')
    
    # Save results
    echo "test_name,constraint_type,platform,throughput_mbps,latency_us,iops,duration_s,cpu_before,cpu_after,load_avg,exit_code" > "$output_file"
    echo "$test_name,$constraint_type,container,$throughput,$latency,$iops,$duration,$pre_cpu,$post_cpu,$load_avg,$exit_code" >> "$output_file"
    
    echo "Container test completed: $throughput MB/s, ${latency}μs latency"
    
    # Reset CPU constraints to baseline
    apply_container_cpu_constraint "baseline"
    
    # Cleanup test files
    docker exec io_test_container /bin/bash -c "cd /root/test_data && rm -f *_4k_* *_64k_* *_1m_* *.file 2>/dev/null && sync" >/dev/null 2>&1 || true
}

# Run IO test on Firecracker with CPU constraints  
run_firecracker_io_test() {
    local test_name="$1"
    local constraint_type="$2"
    local io_command="$3"
    local output_file="$4"
    
    echo "Running Firecracker test: $test_name with $constraint_type constraint"
    
    # Apply CPU constraint
    apply_firecracker_cpu_constraint "$constraint_type"
    
    # Wait for constraints to take effect
    sleep 2
    
    # Run the test
    local start_time=$(date +%s.%N)
    
    # Get host load before test
    local pre_load=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')
    
    # Execute fio test
    local io_output=$(timeout 60 ssh -i "./ubuntu-24.04.id_rsa" -o StrictHostKeyChecking=no root@"$GUEST_IP" "cd /root/test_data && $io_command" 2>&1 || echo "timeout_or_error")
    local exit_code=$?
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc)
    
    # Get host load after test
    local post_load=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')
    
    # Parse fio output (same logic as container)
    local throughput="0"
    local latency="0"
    local iops="0"
    
    if [ $exit_code -eq 0 ] && [[ "$io_output" != "timeout_or_error" ]]; then
        # Parse mixed workload
        if echo "$io_output" | grep -q "read:" && echo "$io_output" | grep -q "write:"; then
            local read_bw=$(echo "$io_output" | grep "read:" | grep -o "BW=[0-9.]*[KMG]*B/s" | sed 's/BW=//' | head -1)
            local write_bw=$(echo "$io_output" | grep "write:" | grep -o "BW=[0-9.]*[KMG]*B/s" | sed 's/BW=//' | head -1)
            local read_lat=$(echo "$io_output" | grep "read:" | grep -o "lat.*avg=[^,]*" | grep -o "[0-9.]*" | head -1)
            local write_lat=$(echo "$io_output" | grep "write:" | grep -o "lat.*avg=[^,]*" | grep -o "[0-9.]*" | head -1)
            
            # Convert and combine throughput
            read_bw_mb=$(echo "$read_bw" | sed 's/[KMG]*B\/s//' | awk '{if(index($0,"K")) print $0/1024; else if(index($0,"G")) print $0*1024; else print $0}' 2>/dev/null || echo "0")
            write_bw_mb=$(echo "$write_bw" | sed 's/[KMG]*B\/s//' | awk '{if(index($0,"K")) print $0/1024; else if(index($0,"G")) print $0*1024; else print $0}' 2>/dev/null || echo "0")
            throughput=$(echo "$read_bw_mb + $write_bw_mb" | bc 2>/dev/null || echo "0")
            
            # Weighted average latency
            if [ "$read_lat" != "" ] && [ "$write_lat" != "" ]; then
                latency=$(echo "scale=2; ($read_lat * 0.7) + ($write_lat * 0.3)" | bc 2>/dev/null || echo "0")
            fi
        else
            # Single operation type
            throughput=$(echo "$io_output" | grep -o "BW=[0-9.]*[KMG]*B/s" | sed 's/BW=//' | head -1 | sed 's/[KMG]*B\/s//' | awk '{if(index($0,"K")) print $0/1024; else if(index($0,"G")) print $0*1024; else print $0}' 2>/dev/null || echo "0")
            latency=$(echo "$io_output" | grep -o "lat.*avg=[^,]*" | grep -o "[0-9.]*" | head -1 || echo "0")
        fi
        
        iops=$(echo "$io_output" | grep -o "IOPS=[0-9.]*[km]*" | sed 's/IOPS=//' | head -1 | awk '{if(index($0,"k")) print $0*1000; else if(index($0,"m")) print $0*1000000; else print $0}' 2>/dev/null || echo "0")
    fi
    
    # Save results
    echo "test_name,constraint_type,platform,throughput_mbps,latency_us,iops,duration_s,load_before,load_after,constraint_processes,exit_code" > "$output_file"
    echo "$test_name,$constraint_type,firecracker,$throughput,$latency,$iops,$duration,$pre_load,$post_load,${#STRESS_PIDS[@]},$exit_code" >> "$output_file"
    
    echo "Firecracker test completed: $throughput MB/s, ${latency}μs latency"
    
    # Clean up constraints
    apply_firecracker_cpu_constraint "baseline"
    
    # Cleanup test files
    timeout 15 ssh -i "./ubuntu-24.04.id_rsa" -o StrictHostKeyChecking=no root@"$GUEST_IP" "cd /root/test_data && rm -f *_4k_* *_64k_* *_1m_* *.file 2>/dev/null && sync" >/dev/null 2>&1 || true
}

# Main test execution function
main() {
    echo "🔥 CPU-Constrained I/O Performance Comparison Framework 🔥"
    echo "=========================================================="
    echo "Testing CPU constraint impact on I/O performance"
    echo "Constraints to test: ${!CPU_CONSTRAINTS[@]}"
    echo "I/O patterns: ${!IO_PATTERNS[@]}"
    echo "Results directory: $RESULTS_DIR"
    echo
    
    # Create results directory
    mkdir -p "$RESULTS_DIR"
    
    # Setup environments
    echo "Setting up test environments..."
    setup_firecracker_vm
    setup_container
    
    # Summary file
    local summary_file="$RESULTS_DIR/cpu_constraint_summary.csv"
    echo "test_name,constraint_type,container_throughput,container_latency,firecracker_throughput,firecracker_latency,fc_advantage_throughput,fc_advantage_latency" > "$summary_file"
    
    echo
    echo "🚀 Starting CPU-constrained I/O performance tests..."
    echo "========================================================"
    
    # Run tests for each constraint type and I/O pattern
    for constraint_type in "${!CPU_CONSTRAINTS[@]}"; do
        echo
        echo "🎯 Testing with constraint: $constraint_type (${CPU_CONSTRAINTS[$constraint_type]})"
        echo "----------------------------------------"
        
        for pattern_name in "${!IO_PATTERNS[@]}"; do
            local command="${IO_PATTERNS[$pattern_name]}"
            
            echo
            echo "📊 Running pattern: $pattern_name"
            echo "Command: $command"
            
            # Run container test
            local container_result_file="${RESULTS_DIR}/container_${constraint_type}_${pattern_name}.csv"
            run_container_io_test "$pattern_name" "$constraint_type" "$command" "$container_result_file"
            
            # Run Firecracker test  
            local firecracker_result_file="${RESULTS_DIR}/firecracker_${constraint_type}_${pattern_name}.csv"
            run_firecracker_io_test "$pattern_name" "$constraint_type" "$command" "$firecracker_result_file"
            
            # Extract results for summary
            local container_throughput=$(tail -1 "$container_result_file" | cut -d',' -f4)
            local container_latency=$(tail -1 "$container_result_file" | cut -d',' -f5)
            local firecracker_throughput=$(tail -1 "$firecracker_result_file" | cut -d',' -f4)
            local firecracker_latency=$(tail -1 "$firecracker_result_file" | cut -d',' -f5)
            
            # Calculate advantages
            local throughput_advantage="N/A"
            local latency_advantage="N/A"
            
            if [ "$container_throughput" != "0" ] && [ "$container_throughput" != "" ]; then
                throughput_advantage=$(echo "scale=2; $firecracker_throughput / $container_throughput" | bc 2>/dev/null || echo "N/A")
            fi
            
            if [ "$container_latency" != "0" ] && [ "$container_latency" != "" ]; then
                latency_advantage=$(echo "scale=2; $container_latency / $firecracker_latency" | bc 2>/dev/null || echo "N/A")
            fi
            
            # Add to summary
            echo "${pattern_name},${constraint_type},${container_throughput},${container_latency},${firecracker_throughput},${firecracker_latency},${throughput_advantage},${latency_advantage}" >> "$summary_file"
            
            echo "✅ Pattern completed: Container(${container_throughput}MB/s, ${container_latency}μs) vs Firecracker(${firecracker_throughput}MB/s, ${firecracker_latency}μs)"
        done
    done
    
    echo
    echo "🎉 CPU-constrained I/O testing completed!"
    echo "=========================================="
    echo "Results saved to: $RESULTS_DIR"
    echo "Summary: $summary_file"
    echo
    echo "📊 Quick Summary:"
    echo "Total tests run: $((${#CPU_CONSTRAINTS[@]} * ${#IO_PATTERNS[@]} * 2)) (container + firecracker)"
    echo "CPU constraints tested: ${#CPU_CONSTRAINTS[@]}"
    echo "I/O patterns tested: ${#IO_PATTERNS[@]}"
}

# Check if script has required dependencies
check_dependencies() {
    local missing_deps=()
    
    if ! command -v docker >/dev/null; then
        missing_deps+=("docker")
    fi
    
    if ! command -v firecracker >/dev/null && [ ! -x "../firecracker" ]; then
        missing_deps+=("firecracker")
    fi
    
    if ! command -v ssh >/dev/null; then
        missing_deps+=("ssh")
    fi
    
    if ! command -v bc >/dev/null; then
        missing_deps+=("bc")
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo "❌ Missing required dependencies: ${missing_deps[*]}"
        echo "Please install missing dependencies before running this script"
        exit 1
    fi
    
    # Check for required files
    if [ ! -f "./vmlinux-6.1.128" ]; then
        echo "❌ Missing kernel file: vmlinux-6.1.128"
        exit 1
    fi
    
    if [ ! -f "./ubuntu-24.04.ext4" ]; then
        echo "❌ Missing rootfs file: ubuntu-24.04.ext4"
        exit 1
    fi
    
    if [ ! -f "./ubuntu-24.04.id_rsa" ]; then
        echo "❌ Missing SSH key: ubuntu-24.04.id_rsa"
        exit 1
    fi
    
    echo "✅ All dependencies and files available"
}

# Validate environment and run main function
check_dependencies
main "$@"
