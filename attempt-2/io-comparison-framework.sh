#!/bin/bash

# Standalone IO Performance Comparison Framework
# Compares Firecracker VMs vs Docker containers for IO operations
# Independent setup that doesn't rely on existing benchmarking scripts

set -e

# Configuration (use existing values if already set)
TEST_DURATION=${TEST_DURATION:-30}
DATA_SIZE_MB=${DATA_SIZE_MB:-500}
ITERATIONS=${ITERATIONS:-3}  # Reduced to 3 for faster comprehensive testing
RESULTS_DIR="./io_benchmark_results_$(date +%Y%m%d_%H%M%S)"

# Test mode selection
QUICK_TEST=${QUICK_TEST:-false}  # Set to true to run subset of tests for faster validation
COMPREHENSIVE_TEST=${COMPREHENSIVE_TEST:-false}  # Set to true to run ALL tests (17 patterns)
FOCUSED_BLOCK_SIZE=${FOCUSED_BLOCK_SIZE:-""}  # Set to "4k", "64k", "1m", etc. to test only specific block size

# Network configuration
TAP_DEV="tap1"  # Using tap1 to avoid conflicts with existing setup
TAP_IP="172.17.0.1"
GUEST_IP="172.17.0.2"
MASK_SHORT="/30"
FC_MAC="06:00:AC:11:00:02"

# Firecracker configuration
API_SOCKET="/tmp/firecracker-io-test.socket"
LOGFILE="./firecracker-io-test.log"

# Shared storage for fair comparison
LOOP_DEVICE=""

# Test patterns configuration with multiple block sizes and IO sizes (using smaller files to fit in VM space)
if [ ${#IO_PATTERNS[@]} -eq 0 ]; then
    declare -A IO_PATTERNS=(
        # Small block size tests (4K) - typical for database/transactional workloads
        ["random_write_4k"]="fio --name=random_write_4k --rw=randwrite --size=8M --bs=4k --numjobs=1 --runtime=10s --time_based --group_reporting --filename=rand_4k_file --fsync=1 --direct=1"
        ["random_read_4k"]="fio --name=random_read_4k --rw=randread --size=8M --bs=4k --numjobs=1 --runtime=10s --time_based --group_reporting --filename=rand_4k_file --direct=1"
        ["sequential_write_4k"]="fio --name=seq_write_4k --rw=write --size=8M --bs=4k --numjobs=1 --runtime=10s --time_based --group_reporting --filename=seq_4k_file --fsync=1 --direct=1"
        ["sequential_read_4k"]="fio --name=seq_read_4k --rw=read --size=8M --bs=4k --numjobs=1 --runtime=10s --time_based --group_reporting --filename=seq_4k_file --direct=1"
        
        # Medium block size tests (64K) - typical for streaming/multimedia workloads  
        ["random_write_64k"]="fio --name=random_write_64k --rw=randwrite --size=10M --bs=64k --numjobs=1 --runtime=10s --time_based --group_reporting --filename=rand_64k_file --fsync=1 --direct=1"
        ["random_read_64k"]="fio --name=random_read_64k --rw=randread --size=10M --bs=64k --numjobs=1 --runtime=10s --time_based --group_reporting --filename=rand_64k_file --direct=1"
        ["sequential_write_64k"]="fio --name=seq_write_64k --rw=write --size=10M --bs=64k --numjobs=1 --runtime=10s --time_based --group_reporting --filename=seq_64k_file --fsync=1 --direct=1"
        ["sequential_read_64k"]="fio --name=seq_read_64k --rw=read --size=10M --bs=64k --numjobs=1 --runtime=10s --time_based --group_reporting --filename=seq_64k_file --direct=1"
        
        # Large block size tests (1M) - typical for backup/bulk transfer workloads
        ["random_write_1m"]="fio --name=random_write_1m --rw=randwrite --size=12M --bs=1M --numjobs=1 --runtime=10s --time_based --group_reporting --filename=rand_1m_file --fsync=1 --direct=1"
        ["random_read_1m"]="fio --name=random_read_1m --rw=randread --size=12M --bs=1M --numjobs=1 --runtime=10s --time_based --group_reporting --filename=rand_1m_file --direct=1"
        ["sequential_write_1m"]="fio --name=seq_write_1m --rw=write --size=12M --bs=1M --numjobs=1 --runtime=10s --time_based --group_reporting --filename=seq_1m_file --fsync=1 --direct=1"
        ["sequential_read_1m"]="fio --name=seq_read_1m --rw=read --size=12M --bs=1M --numjobs=1 --runtime=10s --time_based --group_reporting --filename=seq_1m_file --direct=1"
        
        # Mixed workload tests at different scales
        ["mixed_4k"]="fio --name=mixed_4k --rw=randrw --rwmixread=70 --size=8M --bs=4k --numjobs=1 --runtime=10s --time_based --group_reporting --filename=mixed_4k_file --fsync=1 --direct=1"
        ["mixed_64k"]="fio --name=mixed_64k --rw=randrw --rwmixread=70 --size=10M --bs=64k --numjobs=1 --runtime=10s --time_based --group_reporting --filename=mixed_64k_file --fsync=1 --direct=1"
        ["mixed_1m"]="fio --name=mixed_1m --rw=randrw --rwmixread=70 --size=12M --bs=1M --numjobs=1 --runtime=10s --time_based --group_reporting --filename=mixed_1m_file --fsync=1 --direct=1"
        
        # Ultra-small block size test (512 bytes) - edge case for very granular I/O
        ["random_write_512b"]="fio --name=random_write_512b --rw=randwrite --size=8M --bs=512 --numjobs=1 --runtime=10s --time_based --group_reporting --filename=rand_512b_file --fsync=1 --direct=1"
        ["random_read_512b"]="fio --name=random_read_512b --rw=randread --size=8M --bs=512 --numjobs=1 --runtime=10s --time_based --group_reporting --filename=rand_512b_file --direct=1"
    )
fi

# Cleanup function
cleanup() {
    echo "Cleaning up..."
    
    # Stop Firecracker VM gracefully first
    if [ -S "$API_SOCKET" ]; then
        echo "Attempting graceful VM shutdown..."
        sudo curl -X PUT --unix-socket "${API_SOCKET}" \
            --data '{"action_type": "SendCtrlAltDel"}' \
            "http://localhost/actions" 2>/dev/null || true
        sleep 3
        
        # If still running, force shutdown
        if pgrep -f "firecracker.*${API_SOCKET}" >/dev/null; then
            echo "Force stopping VM..."
            sudo pkill -f "firecracker.*${API_SOCKET}" 2>/dev/null || true
            sleep 1
        fi
    fi
    
    # Remove socket
    sudo rm -f "$API_SOCKET"
    
    # Cleanup container
    docker stop io_test_container 2>/dev/null || true
    docker rm io_test_container 2>/dev/null || true
    
    # Cleanup loop device
    if [ -n "$LOOP_DEVICE" ] && [ -e "$LOOP_DEVICE" ]; then
        sudo losetup -d "$LOOP_DEVICE" 2>/dev/null || true
    fi
    
    # Cleanup network
    sudo ip link del "$TAP_DEV" 2>/dev/null || true
    
    # Remove iptables rules
    sudo iptables -t nat -D POSTROUTING -o "$(get_host_interface)" -j MASQUERADE 2>/dev/null || true
    
    # Clean up any corrupted test disk (optional - comment out to preserve for debugging)
    # if [ -f "./test_disk.ext4" ]; then
    #     echo "Removing test disk..."
    #     rm -f "./test_disk.ext4"
    # fi
    
    echo "Cleanup complete"
}

trap cleanup EXIT

# Test selection and filtering
get_test_list() {
    local all_tests=("${!IO_PATTERNS[@]}")
    local selected_tests=()
    
    # Apply comprehensive test mode (run everything)
    if [ "$COMPREHENSIVE_TEST" = "true" ]; then
        echo "🚀 Comprehensive test mode enabled - running ALL 17 test patterns" >&2
        selected_tests=("${all_tests[@]}")
    # Apply quick test filter (select comprehensive but efficient subset)
    elif [ "$QUICK_TEST" = "true" ]; then
        echo "⚡ Quick test mode enabled - running comprehensive subset of tests" >&2
        for test in "${all_tests[@]}"; do
            # Include representative tests from each block size and operation type
            # This gives us good coverage across the matrix of block sizes and operations
            if [[ "$test" =~ (random_write_512b|random_read_512b|sequential_write_4k|random_read_4k|mixed_4k|sequential_write_64k|random_read_64k|mixed_64k|sequential_write_1m|random_read_1m|mixed_1m) ]]; then
                selected_tests+=("$test")
            fi
        done
    # Apply focused block size filter
    elif [ -n "$FOCUSED_BLOCK_SIZE" ]; then
        echo "🎯 Focused testing on block size: $FOCUSED_BLOCK_SIZE" >&2
        for test in "${all_tests[@]}"; do
            if [[ "$test" =~ "_${FOCUSED_BLOCK_SIZE}_" ]]; then
                selected_tests+=("$test")
            fi
        done
    else
        # Default: Run a balanced selection (not all, not minimal)
        echo "📊 Default mode - running balanced test selection" >&2
        for test in "${all_tests[@]}"; do
            # Run most tests but skip some redundant ones to save time
            if [[ ! "$test" =~ (random_write_4k|sequential_read_4k|random_write_64k|sequential_read_64k|random_write_1m|sequential_read_1m) ]]; then
                selected_tests+=("$test")
            fi
        done
    fi
    
    printf '%s\n' "${selected_tests[@]}"
}

# Utility functions
get_host_interface() {
    ip -j route list default | jq -r '.[0].dev' 2>/dev/null || echo "eth0"
}

wait_for_connectivity() {
    local ip="$1"
    local timeout=30
    local count=0
    
    echo "Waiting for connectivity to $ip..."
    while [ $count -lt $timeout ]; do
        if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
            echo "Connectivity established"
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done
    
    echo "Failed to establish connectivity to $ip"
    return 1
}

# Check prerequisites
check_prerequisites() {
    echo "Checking prerequisites..."
    
    # Check for required commands
    local required_commands="curl jq docker fio e2fsck"
    for cmd in $required_commands; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: Required command '$cmd' not found"
            echo "Please install: $cmd"
            exit 1
        fi
    done
    
    # Check for firecracker binary
    if [ ! -f "../firecracker" ]; then
        echo "Error: Firecracker binary not found"
        echo "Expected: ../firecracker"
        exit 1
    fi
    
    # Check for kernel
    if [ ! -f "../vmlinux-6.1.141" ]; then
        echo "Error: Kernel not found"
        echo "Expected: ../vmlinux-6.1.141"
        exit 1
    fi
    
    # Check for rootfs
    if [ ! -f "../ubuntu-24.04.ext4" ]; then
        echo "Error: Root filesystem not found"
        echo "Expected: ../ubuntu-24.04.ext4"
        exit 1
    fi
    
    # Check for SSH key
    if [ ! -f "../ubuntu-24.04.id_rsa" ]; then
        echo "Error: SSH key not found"
        echo "Expected: ../ubuntu-24.04.id_rsa"
        exit 1
    fi
    
    echo "Prerequisites check passed"
}

# Network setup
setup_network() {
    echo "Setting up network interface..."
    
    # Remove existing interface if it exists
    sudo ip link del "$TAP_DEV" 2>/dev/null || true
    
    # Create TAP device
    sudo ip tuntap add dev "$TAP_DEV" mode tap
    sudo ip addr add "${TAP_IP}${MASK_SHORT}" dev "$TAP_DEV"
    sudo ip link set dev "$TAP_DEV" up
    
    # Enable IP forwarding
    sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
    sudo iptables -P FORWARD ACCEPT
    
    # Get host interface
    HOST_IFACE=$(get_host_interface)
    echo "Host interface: $HOST_IFACE"
    
    # Set up NAT for microVM internet access
    sudo iptables -t nat -D POSTROUTING -o "$HOST_IFACE" -j MASQUERADE 2>/dev/null || true
    sudo iptables -t nat -A POSTROUTING -o "$HOST_IFACE" -j MASQUERADE
    
    echo "Network setup complete"
}

# Firecracker VM setup
setup_firecracker_vm() {
    echo "Setting up Firecracker VM..."
    
    # Create results directory
    mkdir -p "$RESULTS_DIR"
    
    # Copy required files to local directory for absolute paths
    cp "../firecracker" "./firecracker"
    cp "../vmlinux-6.1.141" "./vmlinux-6.1.141"
    cp "../ubuntu-24.04.ext4" "./ubuntu-24.04.ext4"
    cp "../ubuntu-24.04.id_rsa" "./ubuntu-24.04.id_rsa"
    chmod 600 "./ubuntu-24.04.id_rsa"
    
    # Make firecracker executable
    chmod +x "./firecracker"
    
    # Remove existing socket
    sudo rm -f "$API_SOCKET"
    
    # Start Firecracker
    ./firecracker --api-sock "$API_SOCKET" --no-seccomp &
    FIRECRACKER_PID=$!
    
    # Wait for API socket
    local count=0
    while [ ! -S "$API_SOCKET" ] && [ $count -lt 10 ]; do
        sleep 0.5
        count=$((count + 1))
    done
    
    if [ ! -S "$API_SOCKET" ]; then
        echo "Error: Firecracker API socket not created"
        return 1
    fi
    
    # Ensure log file can be created
    touch "$LOGFILE"
    
    # Configure logging
    sudo curl -X PUT --unix-socket "${API_SOCKET}" \
        --data "{
            \"log_path\": \"$(pwd)/${LOGFILE#./}\",
            \"level\": \"Info\",
            \"show_level\": true,
            \"show_log_origin\": true
        }" \
        "http://localhost/logger"
    
    # Set boot source
    KERNEL_BOOT_ARGS="console=ttyS0 reboot=k panic=1 pci=off"
    sudo curl -X PUT --unix-socket "${API_SOCKET}" \
        --data "{
            \"kernel_image_path\": \"$(pwd)/vmlinux-6.1.141\",
            \"boot_args\": \"${KERNEL_BOOT_ARGS}\"
        }" \
        "http://localhost/boot-source"
    
    # Set rootfs
    sudo curl -X PUT --unix-socket "${API_SOCKET}" \
        --data "{
            \"drive_id\": \"rootfs\",
            \"path_on_host\": \"$(pwd)/ubuntu-24.04.ext4\",
            \"is_root_device\": true,
            \"is_read_only\": false
        }" \
        "http://localhost/drives/rootfs"

    # Skip adding a second disk for now to avoid ext4 corruption issues
    # VM will test on its root filesystem instead
    echo "VM will use root filesystem for testing to avoid shared disk corruption"
    
    # Set network interface
    sudo curl -X PUT --unix-socket "${API_SOCKET}" \
        --data "{
            \"iface_id\": \"net1\",
            \"guest_mac\": \"$FC_MAC\",
            \"host_dev_name\": \"$TAP_DEV\"
        }" \
        "http://localhost/network-interfaces/net1"
    
    # Set machine configuration
    sudo curl -X PUT --unix-socket "${API_SOCKET}" \
        --data "{
            \"vcpu_count\": 2,
            \"mem_size_mib\": 2048
        }" \
        "http://localhost/machine-config"
    
    # Start the VM
    sleep 0.1
    sudo curl -X PUT --unix-socket "${API_SOCKET}" \
        --data "{
            \"action_type\": \"InstanceStart\"
        }" \
        "http://localhost/actions"
    
    # Wait for VM to boot
    echo "Waiting for VM to boot..."
    sleep 10
    
    # Test SSH connectivity
    if ! wait_for_connectivity "$GUEST_IP"; then
        echo "Error: Cannot reach VM"
        return 1
    fi
    
    # Setup VM networking and install tools
    ssh -i "./ubuntu-24.04.id_rsa" -o StrictHostKeyChecking=no root@"$GUEST_IP" "
        ip route add default via $TAP_IP dev eth0 2>/dev/null || true
        echo 'nameserver 8.8.8.8' > /etc/resolv.conf
        apt-get update -qq
        apt-get install -y fio sysstat bc procfs >/dev/null 2>&1
        
        # Setup VM networking, install tools, and create test directory on root fs with more space
        ip route add default via $TAP_IP dev eth0 2>/dev/null || true
        echo 'nameserver 8.8.8.8' > /etc/resolv.conf
        apt-get update -qq
        apt-get install -y fio sysstat bc procfs >/dev/null 2>&1
        
        # Create test directory on root filesystem and check available space
        mkdir -p /root/test_data
        cd /root/test_data && rm -rf ./* 2>/dev/null || true
        sync
        
        echo 'VM filesystem info:'
        echo 'Root filesystem (used for IO tests):'
        df -h /root
        echo 'Available space on root fs:'
        df -h /root | tail -1 | awk '{print \"Available: \" \$4 \" (\" \$5 \" used)\"}'
        
        # Check if we have enough space for largest test files (100MB + overhead)
        available_mb=\$(df -m /root | tail -1 | awk '{print \$4}')
        if [ \"\$available_mb\" -lt 200 ]; then
            echo 'Warning: Limited disk space. Large file tests may fail.'
            echo 'Available: '\$available_mb'MB, Recommended: >200MB'
        else
            echo 'Sufficient space for all test file sizes (Available: '\$available_mb'MB)'
        fi
        
        echo 'VM setup completed'
    " || {
        echo "Warning: VM setup commands failed, but continuing..."
    }
    
    echo "Firecracker VM setup complete"
}

# Container setup
setup_container() {
    echo "Setting up test container..."
    
    # Stop any existing container
    docker stop io_test_container 2>/dev/null || true
    docker rm io_test_container 2>/dev/null || true
    
    # Start container with simple root filesystem for testing (no shared disk for now)
    docker run -d \
        --name io_test_container \
        --network host \
        --privileged \
        ubuntu:20.04 \
        /bin/bash -c "
            echo 'CONTAINER_STARTING' && 
            echo 'nameserver 8.8.8.8' > /etc/resolv.conf &&
            echo 'nameserver 8.8.4.4' >> /etc/resolv.conf &&
            apt-get update -qq && 
            apt-get install -y fio sysstat bc procps && 
            
            # Create test directory on container root filesystem
            mkdir -p /root/test_data &&
            cd /root/test_data && rm -rf ./* 2>/dev/null || true &&
            sync &&
            
            echo 'Container filesystem info:' &&
            echo 'Container root filesystem (used for IO tests):' &&
            df -h /root &&
            echo 'Available space:' &&
            df -h /root | tail -1 | awk '{print \"Available: \" \$4 \" (\" \$5 \" used)\"}' &&
            echo 'CONTAINER_READY' && 
            fio --version && 
            echo 'CONTAINER_FIO_WORKING' && 
            sleep 3600
        "
    
    # Wait for container to be ready
    echo "Waiting for container to be ready..."
    local count=0
    while [ $count -lt 120 ]; do  # Increased timeout to 120s for package installation
        # Check if container is still running
        if ! docker ps --filter "name=io_test_container" --filter "status=running" | grep -q io_test_container; then
            echo "Error: Container stopped unexpectedly"
            echo "Container logs:"
            docker logs io_test_container
            return 1
        fi
        
        # Check for completion markers in logs
        if docker logs io_test_container 2>/dev/null | grep -q "CONTAINER_FIO_WORKING"; then
            echo "Container ready"
            # Final verification
            if docker exec io_test_container fio --version >/dev/null 2>&1; then
                echo "Container setup completed successfully"
                return 0
            else
                echo "Error: fio verification failed"
                return 1
            fi
        fi
        sleep 1
        count=$((count + 1))
    done
    
    echo "Error: Container setup timed out"
    echo "Container logs:"
    docker logs io_test_container
    return 1
}

# Performance monitoring
monitor_system_metrics() {
    local test_name="$1"
    local duration="$2"
    local output_prefix="$3"
    
    echo "  Starting monitoring for ${output_prefix} (${duration}s)"
    
    # CPU monitoring (run in background, don't wait)
    mpstat -P ALL 1 "$duration" > "${RESULTS_DIR}/${output_prefix}_cpu.log" &
    local cpu_pid=$!
    
    echo "$cpu_pid"
}

stop_monitoring() {
    local pids="$1"
    echo "  Stopping monitoring (PIDs: $pids)"
    for pid in $pids; do
        kill "$pid" 2>/dev/null || true
    done
    # Don't wait for processes to finish, let them complete in background
}

# Container IO testing
run_container_io_test() {
    local test_name="$1"
    local io_command="$2"
    local output_file="$3"
    
    echo "Running container IO test: $test_name"
    echo "timestamp,operation,latency_us,throughput_mbps,cpu_usage" > "$output_file"
    
    for i in $(seq 1 $ITERATIONS); do
        echo "  Container test $i/$ITERATIONS..."
        
        # Check if container is still running
        if ! docker ps --filter "name=io_test_container" --filter "status=running" | grep -q io_test_container; then
            echo "  Container stopped unexpectedly, restarting..."
            setup_container
            sleep 2
        fi
        
        # Execute IO operation and extract fio metrics
        # First, create and execute the command
        # Execute IO operation and extract fio metrics - use root filesystem instead of loop device
        # Clean up previous test files first
        docker exec io_test_container /bin/bash -c "
            cd /root/test_data 2>/dev/null || mkdir -p /root/test_data
            # Remove all test files
            rm -rf test_seq *.fio fio_test_file random_* mixed* testfile* seq_test_file rand_test_file mixed_test_file *_4k_* *_64k_* *_1m_* *_512b_* *.file 2>/dev/null || true
            sync
        " >/dev/null 2>&1 || true
        
        # Execute the actual test
        docker exec io_test_container /bin/bash -c "cd /root/test_data && $io_command" > /tmp/container_fio_output.txt 2>&1
        result=$(cat /tmp/container_fio_output.txt)
        
        # Clean up the test file immediately after the test
        docker exec io_test_container /bin/bash -c "cd /root/test_data && rm -f *_4k_* *_64k_* *_1m_* *_512b_* *.file 2>/dev/null && sync" >/dev/null 2>&1 || true
        
        # Debug: show first few lines of fio output
        echo "    Debug: fio output preview:"
        echo "$result" | head -n 10 | sed 's/^/      /'
        
        # Extract metrics from fio output
        latency_us="0"
        throughput_mb="0"
        iops="0"
        
        if [[ "$result" == "timeout_or_error" ]] || echo "$result" | grep -q "docker:.*not found\|Error response from daemon"; then
            echo "    Error: Container execution failed"
            echo "    Skipping this iteration"
            latency_us="0"
            throughput_mb="0"
        elif [[ "$result" != "timeout_or_error" ]] && echo "$result" | grep -q "Run status"; then
            # Extract average latency (keep in microseconds for precision)
            # For mixed workloads, we need to calculate weighted average of read/write latencies
            
            # Check if this is a mixed workload (has both read and write operations)
            if echo "$result" | grep -q "read.*:" && echo "$result" | grep -q "write.*:"; then
                # Mixed workload - extract both read and write latencies
                echo "    Debug: Mixed workload detected, extracting separate read/write latencies"
                
                read_lat=""
                write_lat=""
                
                # Extract read latency
                if echo "$result" | grep -A 10 "read.*:" | grep -q "clat (nsec)"; then
                    read_lat=$(echo "$result" | grep -A 10 "read.*:" | grep "clat (nsec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p' | head -1)
                    if [[ "$read_lat" =~ ^[0-9.]+$ ]]; then
                        read_lat=$(echo "$read_lat / 1000" | bc -l)
                    fi
                elif echo "$result" | grep -A 10 "read.*:" | grep -q "clat (usec)"; then
                    read_lat=$(echo "$result" | grep -A 10 "read.*:" | grep "clat (usec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p' | head -1)
                elif echo "$result" | grep -A 10 "read.*:" | grep -q "clat (msec)"; then
                    read_lat_msec=$(echo "$result" | grep -A 10 "read.*:" | grep "clat (msec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p' | head -1)
                    if [[ "$read_lat_msec" =~ ^[0-9.]+$ ]]; then
                        read_lat=$(echo "$read_lat_msec * 1000" | bc -l)
                    fi
                fi
                
                # Extract write latency
                if echo "$result" | grep -A 10 "write.*:" | grep -q "clat (nsec)"; then
                    write_lat=$(echo "$result" | grep -A 10 "write.*:" | grep "clat (nsec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p' | head -1)
                    if [[ "$write_lat" =~ ^[0-9.]+$ ]]; then
                        write_lat=$(echo "$write_lat / 1000" | bc -l)
                    fi
                elif echo "$result" | grep -A 10 "write.*:" | grep -q "clat (usec)"; then
                    write_lat=$(echo "$result" | grep -A 10 "write.*:" | grep "clat (usec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p' | head -1)
                elif echo "$result" | grep -A 10 "write.*:" | grep -q "clat (msec)"; then
                    write_lat_msec=$(echo "$result" | grep -A 10 "write.*:" | grep "clat (msec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p' | head -1)
                    if [[ "$write_lat_msec" =~ ^[0-9.]+$ ]]; then
                        write_lat=$(echo "$write_lat_msec * 1000" | bc -l)
                    fi
                fi
                
                # Calculate weighted average latency (70% read, 30% write for randrw)
                if [[ "$read_lat" =~ ^[0-9.]+$ ]] && [[ "$write_lat" =~ ^[0-9.]+$ ]]; then
                    latency_us=$(echo "($read_lat * 0.7) + ($write_lat * 0.3)" | bc -l | xargs printf "%.2f")
                    echo "    Debug: Read lat: ${read_lat}μs, Write lat: ${write_lat}μs, Weighted avg: ${latency_us}μs"
                elif [[ "$read_lat" =~ ^[0-9.]+$ ]]; then
                    latency_us=$(printf "%.2f" "$read_lat")
                    echo "    Debug: Using read latency: ${latency_us}μs"
                elif [[ "$write_lat" =~ ^[0-9.]+$ ]]; then
                    latency_us=$(printf "%.2f" "$write_lat")
                    echo "    Debug: Using write latency: ${latency_us}μs"
                fi
            else
                # Single operation workload - use original parsing logic
                if echo "$result" | grep -q "clat (nsec)"; then
                    # Format: "clat (nsec): min=871, max=1636.2k, avg=1776.38, stdev=1857.40"
                    avg_lat_nsec=$(echo "$result" | grep "clat (nsec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p')
                    if [[ "$avg_lat_nsec" =~ ^[0-9.]+$ ]]; then
                        latency_us=$(echo "$avg_lat_nsec / 1000" | bc -l | xargs printf "%.2f")
                    fi
                elif echo "$result" | grep -q "clat (usec)"; then
                    # Format: "clat (usec): min=46, max=67734, avg=73.71, stdev=460.55"
                    avg_lat_usec=$(echo "$result" | grep "clat (usec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p')
                    if [[ "$avg_lat_usec" =~ ^[0-9.]+$ ]]; then
                        latency_us=$(printf "%.2f" "$avg_lat_usec")
                    fi
                elif echo "$result" | grep -q "lat (nsec)"; then
                    # Format: "lat (nsec): min=36, max=1372, avg=57.76"
                    avg_lat_nsec=$(echo "$result" | grep "lat (nsec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p')
                    if [[ "$avg_lat_nsec" =~ ^[0-9.]+$ ]]; then
                        latency_us=$(echo "$avg_lat_nsec / 1000" | bc -l | xargs printf "%.2f")
                    fi
                elif echo "$result" | grep -q "lat (usec)"; then
                    # Format: "lat (usec): min=36, max=1372, avg=57.76"
                    avg_lat_usec=$(echo "$result" | grep "lat (usec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p')
                    if [[ "$avg_lat_usec" =~ ^[0-9.]+$ ]]; then
                        latency_us=$(printf "%.2f" "$avg_lat_usec")
                    fi
                elif echo "$result" | grep -q "clat (msec)"; then
                    # Format: "clat (msec): min=1, max=10, avg=5.23"
                    avg_lat_msec=$(echo "$result" | grep "clat (msec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p')
                    if [[ "$avg_lat_msec" =~ ^[0-9.]+$ ]]; then
                        latency_us=$(echo "$avg_lat_msec * 1000" | bc -l | xargs printf "%.2f")
                    fi
                elif echo "$result" | grep -q "lat (msec)"; then
                    # Format: "lat (msec): min=1, max=10, avg=5.23"
                    avg_lat_msec=$(echo "$result" | grep "lat (msec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p')
                    if [[ "$avg_lat_msec" =~ ^[0-9.]+$ ]]; then
                        latency_us=$(echo "$avg_lat_msec * 1000" | bc -l | xargs printf "%.2f")
                    fi
                fi
            fi
            # Extract throughput from summary line
            # For mixed workloads, sum read and write throughput
            if echo "$result" | grep -qE "(bw=|BW=)"; then
                if echo "$result" | grep -q "read.*:" && echo "$result" | grep -q "write.*:"; then
                    # Mixed workload - sum read and write throughput
                    echo "    Debug: Mixed workload throughput - summing read and write"
                    
                    read_throughput_mb="0"
                    write_throughput_mb="0"
                    
                    # Get read throughput
                    read_line=$(echo "$result" | grep -E "^\s*read\s*:" | head -1)
                    if echo "$read_line" | grep -qi "([0-9.]*MB/s)"; then
                        read_throughput_mb=$(echo "$read_line" | grep -oEi '\([0-9.]*MB/s\)' | head -1 | sed 's/[()MBmb/s]//g')
                    elif echo "$read_line" | grep -qi "([0-9.]*kB/s)"; then
                        read_throughput_kb=$(echo "$read_line" | grep -oEi '\([0-9.]*kB/s\)' | head -1 | sed 's/[()KBkb/s]//g')
                        if [[ "$read_throughput_kb" =~ ^[0-9.]+$ ]]; then
                            read_throughput_mb=$(echo "scale=2; $read_throughput_kb / 1000" | bc -l)
                        fi
                    elif echo "$read_line" | grep -qi "bw=[0-9.]*MiB/s"; then
                        read_throughput_mib=$(echo "$read_line" | grep -oEi 'bw=[0-9.]*MiB/s' | head -1 | sed 's/bw=\|MiB\/s//gI')
                        if [[ "$read_throughput_mib" =~ ^[0-9.]+$ ]]; then
                            read_throughput_mb=$(echo "scale=2; $read_throughput_mib * 1.048576" | bc -l)
                        fi
                    elif echo "$read_line" | grep -qi "bw=[0-9.]*KiB/s"; then
                        read_throughput_kib=$(echo "$read_line" | grep -oEi 'bw=[0-9.]*KiB/s' | head -1 | sed 's/bw=\|KiB\/s//gI')
                        if [[ "$read_throughput_kib" =~ ^[0-9.]+$ ]]; then
                            read_throughput_mb=$(echo "scale=2; $read_throughput_kib * 1.024 / 1000" | bc -l)
                        fi
                    fi
                    
                    # Get write throughput  
                    write_line=$(echo "$result" | grep -E "^\s*write\s*:" | head -1)
                    if echo "$write_line" | grep -qi "([0-9.]*MB/s)"; then
                        write_throughput_mb=$(echo "$write_line" | grep -oEi '\([0-9.]*MB/s\)' | head -1 | sed 's/[()MBmb/s]//g')
                    elif echo "$write_line" | grep -qi "([0-9.]*kB/s)"; then
                        write_throughput_kb=$(echo "$write_line" | grep -oEi '\([0-9.]*kB/s\)' | head -1 | sed 's/[()KBkb/s]//g')
                        if [[ "$write_throughput_kb" =~ ^[0-9.]+$ ]]; then
                            write_throughput_mb=$(echo "scale=2; $write_throughput_kb / 1000" | bc -l)
                        fi
                    elif echo "$write_line" | grep -qi "bw=[0-9.]*MiB/s"; then
                        write_throughput_mib=$(echo "$write_line" | grep -oEi 'bw=[0-9.]*MiB/s' | head -1 | sed 's/bw=\|MiB\/s//gI')
                        if [[ "$write_throughput_mib" =~ ^[0-9.]+$ ]]; then
                            write_throughput_mb=$(echo "scale=2; $write_throughput_mib * 1.048576" | bc -l)
                        fi
                    elif echo "$write_line" | grep -qi "bw=[0-9.]*KiB/s"; then
                        write_throughput_kib=$(echo "$write_line" | grep -oEi 'bw=[0-9.]*KiB/s' | head -1 | sed 's/bw=\|KiB\/s//gI')
                        if [[ "$write_throughput_kib" =~ ^[0-9.]+$ ]]; then
                            write_throughput_mb=$(echo "scale=2; $write_throughput_kib * 1.024 / 1000" | bc -l)
                        fi
                    fi
                    
                    # Sum read and write throughput
                    if [[ "$read_throughput_mb" =~ ^[0-9.]+$ ]] && [[ "$write_throughput_mb" =~ ^[0-9.]+$ ]]; then
                        throughput_mb=$(echo "scale=2; $read_throughput_mb + $write_throughput_mb" | bc -l)
                        echo "    Debug: Read: ${read_throughput_mb} MB/s, Write: ${write_throughput_mb} MB/s, Total: ${throughput_mb} MB/s"
                    elif [[ "$read_throughput_mb" =~ ^[0-9.]+$ ]]; then
                        throughput_mb="$read_throughput_mb"
                    elif [[ "$write_throughput_mb" =~ ^[0-9.]+$ ]]; then
                        throughput_mb="$write_throughput_mb"
                    fi
                else
                    # Single operation workload - use original parsing logic
                    throughput_line=$(echo "$result" | grep -E "(READ|write|READ|WRITE): .*(bw=|BW=)" | tail -1)
                    
                    # Look for MB/s in parentheses first (more standard)
                    if echo "$throughput_line" | grep -qi "([0-9.]*MB/s)"; then
                        throughput_mb=$(echo "$throughput_line" | grep -oEi '\([0-9.]*MB/s\)' | head -1 | sed 's/[()MBmb/s]//g')
                    # Look for kB/s in parentheses and convert to MB/s
                    elif echo "$throughput_line" | grep -qi "([0-9.]*kB/s)"; then
                        throughput_kb=$(echo "$throughput_line" | grep -oEi '\([0-9.]*kB/s\)' | head -1 | sed 's/[()KBkb/s]//g')
                        if [[ "$throughput_kb" =~ ^[0-9.]+$ ]]; then
                            throughput_mb=$(echo "scale=2; $throughput_kb / 1000" | bc -l)
                        fi
                    # Look for MiB/s directly
                    elif echo "$throughput_line" | grep -qi "(bw=|BW=)[0-9.]*MiB/s"; then
                        throughput_mib=$(echo "$throughput_line" | grep -oEi '(bw=|BW=)[0-9.]*MiB/s' | head -1 | sed 's/bw=\|BW=\|MiB\/s//gI')
                        if [[ "$throughput_mib" =~ ^[0-9.]+$ ]]; then
                            throughput_mb=$(echo "scale=2; $throughput_mib * 1.048576" | bc -l)
                        fi
                    # Look for KiB/s directly and convert to MB/s  
                    elif echo "$throughput_line" | grep -qi "(bw=|BW=)[0-9.]*KiB/s"; then
                        throughput_kib=$(echo "$throughput_line" | grep -oEi '(bw=|BW=)[0-9.]*KiB/s' | head -1 | sed 's/bw=\|BW=\|KiB\/s//gI')
                        if [[ "$throughput_kib" =~ ^[0-9.]+$ ]]; then
                            throughput_mb=$(echo "scale=2; $throughput_kib * 1.024 / 1000" | bc -l)
                        fi
                    # Look for MB/s directly
                    elif echo "$throughput_line" | grep -qi "(bw=|BW=)[0-9.]*MB/s"; then
                        throughput_mb=$(echo "$throughput_line" | grep -oEi '(bw=|BW=)[0-9.]*MB/s' | head -1 | sed 's/bw=\|BW=\|MB\/s//gI')
                    fi
                fi
            fi
            
            # Extract IOPS from the main line
            # Format: "write: IOPS=13.5k, BW=52.6MiB/s"
            if echo "$result" | grep -q "IOPS="; then
                iops_raw=$(echo "$result" | grep "IOPS=" | sed -n 's/.*IOPS=\([0-9.k]*\).*/\1/p')
                # Convert k notation (e.g., "13.5k" -> "13500")
                if echo "$iops_raw" | grep -q "k"; then
                    iops_num=$(echo "$iops_raw" | sed 's/k//')
                    if [[ "$iops_num" =~ ^[0-9.]+$ ]]; then
                        iops=$(echo "$iops_num * 1000" | bc -l | cut -d. -f1)
                    fi
                elif [[ "$iops_raw" =~ ^[0-9.]+$ ]]; then
                    iops="$iops_raw"
                fi
            fi
        elif echo "$result" | grep -q "copied"; then
            # Handle dd output format (keeping for backwards compatibility)
            # Format: "104857600 bytes (105 MB, 100 MiB) copied, 0.280155 s, 374 MB/s"
            if echo "$result" | grep -oE '[0-9.]+ [GM]B/s'; then
                dd_throughput=$(echo "$result" | grep -oE '[0-9.]+ [GM]B/s' | tail -1)
                if echo "$dd_throughput" | grep -q "GB/s"; then
                    throughput_gb=$(echo "$dd_throughput" | sed 's/ GB\/s//')
                    if [[ "$throughput_gb" =~ ^[0-9.]+$ ]]; then
                        throughput_mb=$(echo "$throughput_gb * 1000" | bc -l | xargs printf "%.2f")
                    fi
                elif echo "$dd_throughput" | grep -q "MB/s"; then
                    throughput_mb=$(echo "$dd_throughput" | sed 's/ MB\/s//')
                fi
            fi
            
            # For dd, we don't have latency info, so leave it as 0
            latency_us="0"
        else
            echo "    Warning: IO command produced unexpected output format"
            echo "    Output preview: $(echo "$result" | head -n 2 | tr '\n' ' ')"
        fi
        
        # Get CPU usage (with error handling)
        cpu_usage=$(docker exec io_test_container cat /host_proc/loadavg 2>/dev/null | awk '{print $1}' || echo "0")
        
        timestamp=$(date '+%Y-%m-%d %H:%M:%S.%3N')
        echo "$timestamp,$test_name,$latency_us,$throughput_mb,$cpu_usage" >> "$output_file"
        
        if [[ "$throughput_mb" != "0" ]]; then
            echo "    Latency: ${latency_us}μs, Throughput: ${throughput_mb} MB/s"
        else
            echo "    Latency: ${latency_us}μs, No throughput data"
        fi
        
        sleep 2
    done
    
    echo "Container IO test completed for $test_name"
}

# Firecracker IO testing
run_firecracker_io_test() {
    local test_name="$1"
    local io_command="$2"
    local output_file="$3"
    
    echo "Running Firecracker IO test: $test_name"
    echo "timestamp,operation,latency_us,throughput_mbps,cpu_usage" > "$output_file"
    
    for i in $(seq 1 $ITERATIONS); do
        echo "  Firecracker test $i/$ITERATIONS..."
        
        # Check if VM is still responsive
        if ! ping -c 1 -W 2 "$GUEST_IP" >/dev/null 2>&1; then
            echo "    Warning: VM not responsive, attempting to reconnect..."
            if ! wait_for_connectivity "$GUEST_IP"; then
                echo "    Error: VM connection lost, skipping this iteration"
                continue
            fi
        fi
        
        # Execute IO operation and extract fio metrics - use root filesystem
        # First, clean up any existing test files and check disk space
        cleanup_output=$(timeout 30 ssh -i "./ubuntu-24.04.id_rsa" -o StrictHostKeyChecking=no root@"$GUEST_IP" "
            cd /root/test_data 2>/dev/null || mkdir -p /root/test_data
            # Aggressive cleanup of all test files
            rm -rf test_seq *.fio fio_test_file random_* mixed* testfile* seq_test_file rand_test_file mixed_test_file *_4k_* *_64k_* *_1m_* *_512b_* *.file 2>/dev/null || true
            sync
            # Check available space
            df -h /root | tail -1 | awk '{print \"Available:\" \$4 \" (\" \$5 \" used)\"}'
        " 2>&1)
        
        echo "    VM disk status: $cleanup_output"
        
        # Execute the actual IO command
        io_output=$(timeout 60 ssh -i "./ubuntu-24.04.id_rsa" -o StrictHostKeyChecking=no root@"$GUEST_IP" "cd /root/test_data && $io_command" 2>&1 || echo "timeout_or_error")
        
        # Clean up the test file immediately after the test
        timeout 15 ssh -i "./ubuntu-24.04.id_rsa" -o StrictHostKeyChecking=no root@"$GUEST_IP" "cd /root/test_data && rm -f *_4k_* *_64k_* *_1m_* *_512b_* *.file 2>/dev/null && sync" >/dev/null 2>&1 || true
        
        # Debug: show first few lines of fio output
        echo "    Debug: fio output preview:"
        echo "$io_output" | head -n 10 | sed 's/^/      /'
        
        # Extract metrics from fio output
        latency_us="0"
        throughput_mb="0"
        iops="0"
        
        if [[ "$io_output" == "timeout_or_error" ]] || echo "$io_output" | grep -q "Connection.*refused\|Connection.*timed out\|No route to host"; then
            echo "    Error: SSH connection failed or timed out"
            echo "    Skipping this iteration"
            latency_us="0"
            throughput_mb="0"
        elif [[ "$io_output" != "timeout_or_error" ]] && echo "$io_output" | grep -q "Run status"; then
            # Extract average latency (keep in microseconds for precision)
            # For mixed workloads, we need to calculate weighted average of read/write latencies
            
            # Check if this is a mixed workload (has both read and write operations)
            if echo "$io_output" | grep -q "read.*:" && echo "$io_output" | grep -q "write.*:"; then
                # Mixed workload - extract both read and write latencies
                echo "    Debug: Mixed workload detected, extracting separate read/write latencies"
                
                read_lat=""
                write_lat=""
                
                # Extract read latency
                if echo "$io_output" | grep -A 10 "read.*:" | grep -q "clat (nsec)"; then
                    read_lat=$(echo "$io_output" | grep -A 10 "read.*:" | grep "clat (nsec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p' | head -1)
                    if [[ "$read_lat" =~ ^[0-9.]+$ ]]; then
                        read_lat=$(echo "$read_lat / 1000" | bc -l)
                    fi
                elif echo "$io_output" | grep -A 10 "read.*:" | grep -q "clat (usec)"; then
                    read_lat=$(echo "$io_output" | grep -A 10 "read.*:" | grep "clat (usec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p' | head -1)
                elif echo "$io_output" | grep -A 10 "read.*:" | grep -q "clat (msec)"; then
                    read_lat_msec=$(echo "$io_output" | grep -A 10 "read.*:" | grep "clat (msec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p' | head -1)
                    if [[ "$read_lat_msec" =~ ^[0-9.]+$ ]]; then
                        read_lat=$(echo "$read_lat_msec * 1000" | bc -l)
                    fi
                fi
                
                # Extract write latency
                if echo "$io_output" | grep -A 10 "write.*:" | grep -q "clat (nsec)"; then
                    write_lat=$(echo "$io_output" | grep -A 10 "write.*:" | grep "clat (nsec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p' | head -1)
                    if [[ "$write_lat" =~ ^[0-9.]+$ ]]; then
                        write_lat=$(echo "$write_lat / 1000" | bc -l)
                    fi
                elif echo "$io_output" | grep -A 10 "write.*:" | grep -q "clat (usec)"; then
                    write_lat=$(echo "$io_output" | grep -A 10 "write.*:" | grep "clat (usec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p' | head -1)
                elif echo "$io_output" | grep -A 10 "write.*:" | grep -q "clat (msec)"; then
                    write_lat_msec=$(echo "$io_output" | grep -A 10 "write.*:" | grep "clat (msec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p' | head -1)
                    if [[ "$write_lat_msec" =~ ^[0-9.]+$ ]]; then
                        write_lat=$(echo "$write_lat_msec * 1000" | bc -l)
                    fi
                fi
                
                # Calculate weighted average latency (70% read, 30% write for randrw)
                if [[ "$read_lat" =~ ^[0-9.]+$ ]] && [[ "$write_lat" =~ ^[0-9.]+$ ]]; then
                    latency_us=$(echo "($read_lat * 0.7) + ($write_lat * 0.3)" | bc -l | xargs printf "%.2f")
                    echo "    Debug: Read lat: ${read_lat}μs, Write lat: ${write_lat}μs, Weighted avg: ${latency_us}μs"
                elif [[ "$read_lat" =~ ^[0-9.]+$ ]]; then
                    latency_us=$(printf "%.2f" "$read_lat")
                    echo "    Debug: Using read latency: ${latency_us}μs"
                elif [[ "$write_lat" =~ ^[0-9.]+$ ]]; then
                    latency_us=$(printf "%.2f" "$write_lat")
                    echo "    Debug: Using write latency: ${latency_us}μs"
                fi
            else
                # Single operation workload - use original parsing logic
                if echo "$io_output" | grep -q "clat (nsec)"; then
                    # Format: "clat (nsec): min=871, max=1636.2k, avg=1776.38, stdev=1857.40"
                    avg_lat_nsec=$(echo "$io_output" | grep "clat (nsec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p')
                    if [[ "$avg_lat_nsec" =~ ^[0-9.]+$ ]]; then
                        latency_us=$(echo "$avg_lat_nsec / 1000" | bc -l | xargs printf "%.2f")
                    fi
                elif echo "$io_output" | grep -q "clat (usec)"; then
                    # Format: "clat (usec): min=46, max=67734, avg=73.71, stdev=460.55"
                    avg_lat_usec=$(echo "$io_output" | grep "clat (usec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p')
                    if [[ "$avg_lat_usec" =~ ^[0-9.]+$ ]]; then
                        latency_us=$(printf "%.2f" "$avg_lat_usec")
                    fi
                elif echo "$io_output" | grep -q "lat (nsec)"; then
                    # Format: "lat (nsec): min=36, max=1372, avg=57.76"
                    avg_lat_nsec=$(echo "$io_output" | grep "lat (nsec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p')
                    if [[ "$avg_lat_nsec" =~ ^[0-9.]+$ ]]; then
                        latency_us=$(echo "$avg_lat_nsec / 1000" | bc -l | xargs printf "%.2f")
                    fi
                elif echo "$io_output" | grep -q "lat (usec)"; then
                    # Format: "lat (usec): min=36, max=1372, avg=57.76"
                    avg_lat_usec=$(echo "$io_output" | grep "lat (usec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p')
                    if [[ "$avg_lat_usec" =~ ^[0-9.]+$ ]]; then
                        latency_us=$(printf "%.2f" "$avg_lat_usec")
                    fi
                elif echo "$io_output" | grep -q "clat (msec)"; then
                    # Format: "clat (msec): min=1, max=10, avg=5.23"
                    avg_lat_msec=$(echo "$io_output" | grep "clat (msec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p')
                    if [[ "$avg_lat_msec" =~ ^[0-9.]+$ ]]; then
                        latency_us=$(echo "$avg_lat_msec * 1000" | bc -l | xargs printf "%.2f")
                    fi
                elif echo "$io_output" | grep -q "lat (msec)"; then
                    # Format: "lat (msec): min=1, max=10, avg=5.23"
                    avg_lat_msec=$(echo "$io_output" | grep "lat (msec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p')
                    if [[ "$avg_lat_msec" =~ ^[0-9.]+$ ]]; then
                        latency_us=$(echo "$avg_lat_msec * 1000" | bc -l | xargs printf "%.2f")
                    fi
                fi
            fi
            
            # Extract throughput from summary line
            # For mixed workloads, sum read and write throughput
            if echo "$io_output" | grep -q "bw="; then
                if echo "$io_output" | grep -q "read.*:" && echo "$io_output" | grep -q "write.*:"; then
                    # Mixed workload - sum read and write throughput
                    echo "    Debug: Mixed workload throughput - summing read and write"
                    
                    read_throughput_mb="0"
                    write_throughput_mb="0"
                    
                    # Get read throughput
                    read_line=$(echo "$io_output" | grep -E "^\s*read\s*:" | head -1)
                    if echo "$read_line" | grep -q "([0-9.]*MB/s)"; then
                        read_throughput_mb=$(echo "$read_line" | grep -oE '\([0-9.]*MB/s\)' | head -1 | sed 's/[()MB/s]//g')
                    elif echo "$read_line" | grep -q "([0-9.]*kB/s)"; then
                        read_throughput_kb=$(echo "$read_line" | grep -oE '\([0-9.]*kB/s\)' | head -1 | sed 's/[()kB/s]//g')
                        if [[ "$read_throughput_kb" =~ ^[0-9.]+$ ]]; then
                            read_throughput_mb=$(echo "scale=2; $read_throughput_kb / 1000" | bc -l)
                        fi
                    elif echo "$read_line" | grep -q "bw=[0-9.]*MiB/s"; then
                        read_throughput_mib=$(echo "$read_line" | grep -oE 'bw=[0-9.]*MiB/s' | head -1 | sed 's/bw=\|MiB\/s//g')
                        if [[ "$read_throughput_mib" =~ ^[0-9.]+$ ]]; then
                            read_throughput_mb=$(echo "$read_throughput_mib * 1.048576" | bc -l | xargs printf "%.2f")
                        fi
                    elif echo "$read_line" | grep -q "bw=[0-9.]*MB/s"; then
                        read_throughput_mb=$(echo "$read_line" | grep -oE 'bw=[0-9.]*MB/s' | head -1 | sed 's/bw=\|MB\/s//g')
                    fi
                    
                    # Get write throughput  
                    write_line=$(echo "$io_output" | grep -E "^\s*write\s*:" | head -1)
                    if echo "$write_line" | grep -q "([0-9.]*MB/s)"; then
                        write_throughput_mb=$(echo "$write_line" | grep -oE '\([0-9.]*MB/s\)' | head -1 | sed 's/[()MB/s]//g')
                    elif echo "$write_line" | grep -q "([0-9.]*kB/s)"; then
                        write_throughput_kb=$(echo "$write_line" | grep -oE '\([0-9.]*kB/s\)' | head -1 | sed 's/[()kB/s]//g')
                        if [[ "$write_throughput_kb" =~ ^[0-9.]+$ ]]; then
                            write_throughput_mb=$(echo "scale=2; $write_throughput_kb / 1000" | bc -l)
                        fi
                    elif echo "$write_line" | grep -q "bw=[0-9.]*MiB/s"; then
                        write_throughput_mib=$(echo "$write_line" | grep -oE 'bw=[0-9.]*MiB/s' | head -1 | sed 's/bw=\|MiB\/s//g')
                        if [[ "$write_throughput_mib" =~ ^[0-9.]+$ ]]; then
                            write_throughput_mb=$(echo "$write_throughput_mib * 1.048576" | bc -l | xargs printf "%.2f")
                        fi
                    elif echo "$write_line" | grep -q "bw=[0-9.]*MB/s"; then
                        write_throughput_mb=$(echo "$write_line" | grep -oE 'bw=[0-9.]*MB/s' | head -1 | sed 's/bw=\|MB\/s//g')
                    fi
                    
                    # Sum read and write throughput
                    if [[ "$read_throughput_mb" =~ ^[0-9.]+$ ]] && [[ "$write_throughput_mb" =~ ^[0-9.]+$ ]]; then
                        throughput_mb=$(echo "scale=2; $read_throughput_mb + $write_throughput_mb" | bc -l)
                        echo "    Debug: Read: ${read_throughput_mb} MB/s, Write: ${write_throughput_mb} MB/s, Total: ${throughput_mb} MB/s"
                    elif [[ "$read_throughput_mb" =~ ^[0-9.]+$ ]]; then
                        throughput_mb="$read_throughput_mb"
                    elif [[ "$write_throughput_mb" =~ ^[0-9.]+$ ]]; then
                        throughput_mb="$write_throughput_mb"
                    fi
                else
                    # Single operation workload - use original parsing logic
                    throughput_line=$(echo "$io_output" | grep -E "(READ|WRITE): bw=" | tail -1)
                    
                    # Look for MB/s in parentheses first (more standard), then MiB/s
                    if echo "$throughput_line" | grep -q "([0-9.]*MB/s)"; then
                        throughput_mb=$(echo "$throughput_line" | grep -oE '\([0-9.]*MB/s\)' | head -1 | sed 's/[()MB/s]//g')
                    elif echo "$throughput_line" | grep -q "bw=[0-9.]*MiB/s"; then
                        throughput_mib=$(echo "$throughput_line" | grep -oE 'bw=[0-9.]*MiB/s' | head -1 | sed 's/bw=\|MiB\/s//g')
                        if [[ "$throughput_mib" =~ ^[0-9.]+$ ]]; then
                            throughput_mb=$(echo "$throughput_mib * 1.048576" | bc -l | xargs printf "%.2f")
                        fi
                    elif echo "$throughput_line" | grep -q "bw=[0-9.]*MB/s"; then
                        throughput_mb=$(echo "$throughput_line" | grep -oE 'bw=[0-9.]*MB/s' | head -1 | sed 's/bw=\|MB\/s//g')
                    fi
                fi
            fi
            
            # Extract IOPS from the main line
            # Format: "write: IOPS=13.5k, BW=52.6MiB/s"
            if echo "$io_output" | grep -q "IOPS="; then
                iops_raw=$(echo "$io_output" | grep "IOPS=" | sed -n 's/.*IOPS=\([0-9.k]*\).*/\1/p')
                # Convert k notation (e.g., "13.5k" -> "13500")
                if echo "$iops_raw" | grep -q "k"; then
                    iops_num=$(echo "$iops_raw" | sed 's/k//')
                    if [[ "$iops_num" =~ ^[0-9.]+$ ]]; then
                        iops=$(echo "$iops_num * 1000" | bc -l | cut -d. -f1)
                    fi
                elif [[ "$iops_raw" =~ ^[0-9.]+$ ]]; then
                    iops="$iops_raw"
                fi
            fi
        elif echo "$io_output" | grep -q "copied"; then
            # Handle dd output format
            # Format: "104857600 bytes (105 MB, 100 MiB) copied, 0.280155 s, 374 MB/s"
            if echo "$io_output" | grep -oE '[0-9.]+ [GM]B/s'; then
                dd_throughput=$(echo "$io_output" | grep -oE '[0-9.]+ [GM]B/s' | tail -1)
                if echo "$dd_throughput" | grep -q "GB/s"; then
                    throughput_gb=$(echo "$dd_throughput" | sed 's/ GB\/s//')
                    if [[ "$throughput_gb" =~ ^[0-9.]+$ ]]; then
                        throughput_mb=$(echo "$throughput_gb * 1000" | bc -l | xargs printf "%.2f")
                    fi
                elif echo "$dd_throughput" | grep -q "MB/s"; then
                    throughput_mb=$(echo "$dd_throughput" | sed 's/ MB\/s//')
                fi
            fi
            
            # For dd, we don't have latency info, so leave it as 0
            latency_us="0"
        else
            echo "    Warning: fio command failed or produced no output"
            echo "    Output: $io_output" | head -n 3
        fi
        
        # Get CPU usage
        cpu_usage=$(cat /proc/loadavg | awk '{print $1}')
        
        timestamp=$(date '+%Y-%m-%d %H:%M:%S.%3N')
        echo "$timestamp,$test_name,$latency_us,$throughput_mb,$cpu_usage" >> "$output_file"
        
        if [[ "$throughput_mb" != "0" ]]; then
            echo "    Latency: ${latency_us}μs, Throughput: ${throughput_mb} MB/s"
        else
            echo "    Latency: ${latency_us}μs, No throughput data"
        fi
        
        sleep 2
    done
    
    echo "Firecracker IO test completed for $test_name"
}

# Analysis function with block size categorization
analyze_results() {
    echo "=== PERFORMANCE ANALYSIS ==="
    
    # Create enhanced analysis script
    cat > "${RESULTS_DIR}/analyze_results.py" << 'EOF'
import pandas as pd
import numpy as np
import sys
from pathlib import Path
import re

def parse_test_name(test_name):
    """Extract block size, operation type, and data size from test name"""
    # Pattern: operation_blocksize_datasize (e.g., random_write_4k_20m)
    parts = test_name.split('_')
    if len(parts) >= 3:
        operation = '_'.join(parts[:-2])  # Handle multi-word operations like 'random_write'
        block_size = parts[-2]
        data_size = parts[-1]
        return operation, block_size, data_size
    return test_name, 'unknown', 'unknown'

def format_block_size(block_size):
    """Convert block size to human readable format"""
    size_mapping = {
        '512b': '512 bytes',
        '4k': '4KB',
        '64k': '64KB', 
        '1m': '1MB'
    }
    return size_mapping.get(block_size.lower(), block_size)

def analyze_performance(container_file, firecracker_file, test_name):
    try:
        container_df = pd.read_csv(container_file)
        firecracker_df = pd.read_csv(firecracker_file)
    except Exception as e:
        print(f"Error loading data for {test_name}: {e}")
        return None
    
    operation, block_size, data_size = parse_test_name(test_name)
    formatted_block_size = format_block_size(block_size)
    
    print(f"\n=== {test_name.upper().replace('_', ' ')} ===")
    print(f"Operation: {operation.replace('_', ' ').title()}, Block Size: {formatted_block_size}, Data Size: {data_size.upper()}")
    
    results = {'test_name': test_name, 'operation': operation, 'block_size': block_size, 'data_size': data_size}
    
    # Calculate statistics for each environment
    for env_name, df in [("Container", container_df), ("Firecracker", firecracker_df)]:
        if df.empty:
            continue
            
        print(f"\n{env_name} Performance:")
        
        # Handle latency_us column
        if 'latency_us' in df.columns:
            valid_latency = df[df['latency_us'] > 0]['latency_us']
            if not valid_latency.empty:
                latency_avg = valid_latency.mean()
                latency_std = valid_latency.std()
                latency_min = valid_latency.min()
                latency_max = valid_latency.max()
                print(f"  Latency - Avg: {latency_avg:.2f}μs, Std: {latency_std:.2f}μs, Range: {latency_min:.2f}-{latency_max:.2f}μs")
                results[f'{env_name.lower()}_latency_avg'] = latency_avg
                results[f'{env_name.lower()}_latency_std'] = latency_std
            else:
                print(f"  Latency - No valid data (all zeros)")
                results[f'{env_name.lower()}_latency_avg'] = 0
                results[f'{env_name.lower()}_latency_std'] = 0
        
        if 'throughput_mbps' in df.columns:
            valid_throughput = df[df['throughput_mbps'] > 0]['throughput_mbps']
            if not valid_throughput.empty:
                thr_avg = valid_throughput.mean()
                thr_std = valid_throughput.std()
                thr_min = valid_throughput.min()
                thr_max = valid_throughput.max()
                print(f"  Throughput - Avg: {thr_avg:.1f} MB/s, Std: {thr_std:.1f} MB/s, Range: {thr_min:.1f}-{thr_max:.1f} MB/s")
                results[f'{env_name.lower()}_throughput_avg'] = thr_avg
                results[f'{env_name.lower()}_throughput_std'] = thr_std
            else:
                print(f"  Throughput - No valid data")
                results[f'{env_name.lower()}_throughput_avg'] = 0
                results[f'{env_name.lower()}_throughput_std'] = 0
        
        if 'cpu_usage' in df.columns:
            cpu_avg = df['cpu_usage'].mean()
            print(f"  CPU Load - Avg: {cpu_avg:.3f}")
            results[f'{env_name.lower()}_cpu_avg'] = cpu_avg
    
    # Calculate performance ratios
    if not container_df.empty and not firecracker_df.empty:
        print(f"\n🔥 Firecracker vs Container Performance:")
        
        # Latency comparison (lower is better)
        container_lat = results.get('container_latency_avg', 0)
        firecracker_lat = results.get('firecracker_latency_avg', 0)
        
        if container_lat > 0 and firecracker_lat > 0:
            lat_improvement = ((container_lat - firecracker_lat) / container_lat) * 100
            if lat_improvement > 0:
                print(f"  ✅ Latency: {lat_improvement:.1f}% faster ({firecracker_lat:.2f}μs vs {container_lat:.2f}μs)")
            else:
                print(f"  ❌ Latency: {abs(lat_improvement):.1f}% slower ({firecracker_lat:.2f}μs vs {container_lat:.2f}μs)")
            results['latency_improvement_pct'] = lat_improvement
        
        # Throughput comparison (higher is better)  
        container_thr = results.get('container_throughput_avg', 0)
        firecracker_thr = results.get('firecracker_throughput_avg', 0)
        
        if container_thr > 0 and firecracker_thr > 0:
            thr_improvement = ((firecracker_thr - container_thr) / container_thr) * 100
            thr_ratio = firecracker_thr / container_thr
            if thr_improvement > 0:
                print(f"  ✅ Throughput: {thr_improvement:.1f}% faster ({firecracker_thr:.1f} vs {container_thr:.1f} MB/s) - {thr_ratio:.2f}x")
            else:
                print(f"  ❌ Throughput: {abs(thr_improvement):.1f}% slower ({firecracker_thr:.1f} vs {container_thr:.1f} MB/s) - {thr_ratio:.2f}x")
            results['throughput_improvement_pct'] = thr_improvement
            results['throughput_ratio'] = thr_ratio
        
        # CPU efficiency
        container_cpu = results.get('container_cpu_avg', 1)
        firecracker_cpu = results.get('firecracker_cpu_avg', 1)
        if container_cpu > 0:
            cpu_ratio = firecracker_cpu / container_cpu
            results['cpu_ratio'] = cpu_ratio
            if cpu_ratio < 1:
                print(f"  ✅ CPU Efficiency: {((1-cpu_ratio)*100):.1f}% less CPU load")
            else:
                print(f"  ⚠️  CPU Overhead: {((cpu_ratio-1)*100):.1f}% more CPU load")
    
    return results

def summarize_by_block_size(all_results):
    """Group results by block size and summarize trends"""
    print(f"\n{'='*60}")
    print("📊 BLOCK SIZE PERFORMANCE SUMMARY")
    print(f"{'='*60}")
    
    block_sizes = ['512b', '4k', '64k', '1m']
    size_labels = {'512b': '512B', '4k': '4KB', '64k': '64KB', '1m': '1MB'}
    
    print(f"\n{'Block Size':<10} {'Avg Latency Improve':<20} {'Avg Throughput Improve':<22} {'Best Operation':<15}")
    print(f"{'-'*75}")
    
    for block_size in block_sizes:
        size_results = [r for r in all_results if r and r.get('block_size') == block_size]
        if not size_results:
            continue
            
        # Calculate averages for this block size
        lat_improvements = [r['latency_improvement_pct'] for r in size_results if 'latency_improvement_pct' in r]
        thr_improvements = [r['throughput_improvement_pct'] for r in size_results if 'throughput_improvement_pct' in r]
        
        avg_lat_improve = np.mean(lat_improvements) if lat_improvements else 0
        avg_thr_improve = np.mean(thr_improvements) if thr_improvements else 0
        
        # Find best performing operation for this block size
        best_thr_result = max(size_results, key=lambda x: x.get('throughput_improvement_pct', -999), default=None)
        best_op = best_thr_result['operation'].replace('_', ' ').title() if best_thr_result else 'N/A'
        
        lat_status = "✅" if avg_lat_improve > 0 else "❌" if avg_lat_improve < 0 else "➖"
        thr_status = "✅" if avg_thr_improve > 0 else "❌" if avg_thr_improve < 0 else "➖"
        
        print(f"{size_labels[block_size]:<10} {lat_status} {avg_lat_improve:>+6.1f}%{'':<10} {thr_status} {avg_thr_improve:>+6.1f}%{'':<11} {best_op:<15}")

def generate_summary_recommendations(all_results):
    """Generate actionable insights based on test results"""
    print(f"\n{'='*60}")
    print("🎯 PERFORMANCE INSIGHTS & RECOMMENDATIONS")  
    print(f"{'='*60}")
    
    if not all_results:
        print("No results to analyze.")
        return
        
    # Find best and worst performing scenarios
    valid_results = [r for r in all_results if r and 'throughput_improvement_pct' in r]
    
    if valid_results:
        best_result = max(valid_results, key=lambda x: x['throughput_improvement_pct'])
        worst_result = min(valid_results, key=lambda x: x['throughput_improvement_pct'])
        
        print(f"\n🏆 BEST FIRECRACKER PERFORMANCE:")
        print(f"   Test: {best_result['test_name'].replace('_', ' ').title()}")
        print(f"   Throughput: +{best_result['throughput_improvement_pct']:.1f}% improvement")
        if 'latency_improvement_pct' in best_result:
            print(f"   Latency: {best_result['latency_improvement_pct']:+.1f}% change")
        
        print(f"\n⚠️  CHALLENGING SCENARIO:")
        print(f"   Test: {worst_result['test_name'].replace('_', ' ').title()}")
        print(f"   Throughput: {worst_result['throughput_improvement_pct']:+.1f}% change")
        if 'latency_improvement_pct' in worst_result:
            print(f"   Latency: {worst_result['latency_improvement_pct']:+.1f}% change")
    
    # Categorize results by improvement level
    excellent = [r for r in valid_results if r['throughput_improvement_pct'] > 50]
    good = [r for r in valid_results if 10 <= r['throughput_improvement_pct'] <= 50]
    moderate = [r for r in valid_results if -10 <= r['throughput_improvement_pct'] < 10]
    poor = [r for r in valid_results if r['throughput_improvement_pct'] < -10]
    
    print(f"\n📈 PERFORMANCE DISTRIBUTION:")
    print(f"   🚀 Excellent (>50% faster): {len(excellent)} tests")
    print(f"   ✅ Good (10-50% faster): {len(good)} tests")  
    print(f"   ➖ Moderate (±10%): {len(moderate)} tests")
    print(f"   ❌ Slower (<-10%): {len(poor)} tests")
    
    print(f"\n💡 KEY RECOMMENDATIONS:")
    if len(excellent) + len(good) > len(poor):
        print("   • Firecracker shows strong I/O performance advantages")
        if any(r['block_size'] == '4k' for r in excellent + good):
            print("   • Particularly effective for small block (4KB) operations")
        if any('random' in r['operation'] for r in excellent + good):
            print("   • Excellent for random I/O patterns typical in databases")
        print("   • Consider Firecracker for I/O-intensive microservices")
    else:
        print("   • Mixed results - choose Firecracker based on specific workload")
        print("   • Container might be better for specific use cases shown")
    
    print(f"\n📋 TESTING SUMMARY:")
    print(f"   • Total tests completed: {len(valid_results)}")
    print(f"   • Block sizes tested: 512B, 4KB, 64KB, 1MB")
    print(f"   • Operations: Random/Sequential Read/Write, Mixed workloads")
    print(f"   • Firecracker advantages: {len([r for r in valid_results if r['throughput_improvement_pct'] > 0])}/{len(valid_results)} tests")

if __name__ == "__main__":
    results_dir = Path(sys.argv[1])
    
    # Get all test result files
    container_files = list(results_dir.glob("container_*.csv"))
    all_results = []
    
    print("Analyzing comprehensive I/O performance comparison...")
    
    for container_file in container_files:
        # Extract test name from filename
        test_name = container_file.stem.replace('container_', '')
        firecracker_file = results_dir / f"firecracker_{test_name}.csv"
        
        if firecracker_file.exists():
            result = analyze_performance(container_file, firecracker_file, test_name)
            if result:
                all_results.append(result)
        else:
            print(f"Missing Firecracker data for {test_name}")
    
    # Generate summary analysis
    if all_results:
        summarize_by_block_size(all_results)
        generate_summary_recommendations(all_results)
    
    print(f"\n{'='*60}")
    print("🏁 ANALYSIS COMPLETE")
    print(f"{'='*60}")
    print(f"Detailed results saved in: {results_dir}")
    print("Files generated:")
    print("  • Individual CSV files with raw performance data")
    print("  • CPU utilization logs (*_cpu.log)")
    print("  • This analysis script (analyze_results.py)")
    print("  • Firecracker VM logs (firecracker-io-test.log)")
EOF

    # Run analysis if Python 3 is available
    if command -v /home/guus/.venv/bin/python >/dev/null 2>&1; then
        /home/guus/.venv/bin/python "${RESULTS_DIR}/analyze_results.py" "$RESULTS_DIR"
    elif command -v python3 >/dev/null 2>&1; then
        python3 "${RESULTS_DIR}/analyze_results.py" "$RESULTS_DIR"
    else
        echo "Python 3 not available for analysis. Raw data saved in $RESULTS_DIR"
    fi
}

# Main execution
main() {
    echo "=== COMPREHENSIVE IO PERFORMANCE COMPARISON FRAMEWORK ==="
    echo "🔬 Testing Multiple Block Sizes: 512B, 4KB, 64KB, 1MB"
    echo "🎯 Testing Multiple Operations: Sequential/Random Read/Write, Mixed Workloads"
    echo "📊 Data Sizes: 10MB (512B blocks), 20MB (4KB blocks), 50MB (64KB blocks), 100MB (1MB blocks)"
    echo "⚡ Total Tests: ${#IO_PATTERNS[@]} test patterns across both environments"
    echo "📁 Results will be saved to: $RESULTS_DIR"
    echo ""
    
    # Show test breakdown
    echo "📋 Test Matrix:"
    echo "   • Ultra-small (512B blocks): 2 tests - random read/write on 10MB files"
    echo "   • Small blocks (4KB): 5 tests - sequential/random/mixed operations on 20MB files" 
    echo "   • Medium blocks (64KB): 5 tests - sequential/random/mixed operations on 50MB files"
    echo "   • Large blocks (1MB): 5 tests - sequential/random/mixed operations on 100MB files"
    echo "   • Total runtime estimate: ~$((${#IO_PATTERNS[@]} * 2 * $ITERATIONS * 12 / 60)) minutes"
    echo ""
    
    # Check prerequisites
    check_prerequisites
    
    # Setup components
    setup_network
    setup_firecracker_vm
    setup_container
    
    echo "🚀 Starting comprehensive IO tests across multiple block sizes..."
    
    # Get selected test list
    readarray -t selected_tests < <(get_test_list)
    local total_tests=${#selected_tests[@]}
    
    if [ $total_tests -eq 0 ]; then
        echo "❌ No tests selected based on current filters"
        exit 1
    fi
    
    echo "📝 Selected tests: $total_tests/${#IO_PATTERNS[@]} total patterns"
    
    # Run tests for each selected pattern
    local test_count=0
    
    for pattern_name in "${selected_tests[@]}"; do
        test_count=$((test_count + 1))
        echo ""
        echo "🧪 [$test_count/$total_tests] Testing IO Pattern: $pattern_name"
        echo "=============================================================="
        
        command="${IO_PATTERNS[$pattern_name]}"
        
        # Test container performance
        echo "📦 Testing container performance..."
        monitor_pids=$(monitor_system_metrics "$pattern_name" $((ITERATIONS * 3)) "container_${pattern_name}")
        run_container_io_test "$pattern_name" "$command" "${RESULTS_DIR}/container_${pattern_name}.csv"
        stop_monitoring "$monitor_pids"
        
        echo "   Container testing complete, waiting 5s..."
        sleep 5
        
        # Test Firecracker performance
        echo "🔥 Testing Firecracker performance..."
        monitor_pids=$(monitor_system_metrics "$pattern_name" $((ITERATIONS * 3)) "firecracker_${pattern_name}")
        run_firecracker_io_test "$pattern_name" "$command" "${RESULTS_DIR}/firecracker_${pattern_name}.csv"
        stop_monitoring "$monitor_pids"
        
        echo "   Firecracker testing complete, waiting 5s..."
        sleep 5
        
        # Progress update
        local remaining=$((total_tests - test_count))
        if [ $remaining -gt 0 ]; then
            echo "   ⏳ $remaining tests remaining..."
        fi
    done
    
    # Analysis
    echo ""
    echo "📊 Generating comprehensive performance analysis..."
    analyze_results
    
    echo ""
    echo "🎉 COMPREHENSIVE EXPERIMENT COMPLETE!"
    echo "==============================================="
    echo "📁 All results saved to: $RESULTS_DIR"
    echo ""
    echo "📄 Generated Files:"
    echo "   • ${#IO_PATTERNS[@]} container_*.csv files - Container performance data"
    echo "   • ${#IO_PATTERNS[@]} firecracker_*.csv files - Firecracker performance data"
    echo "   • Multiple *_cpu.log files - CPU utilization during tests"
    echo "   • analyze_results.py - Advanced analysis script"
    echo "   • firecracker-io-test.log - VM execution logs"
    echo ""
    echo "🔍 Key Analysis Features:"
    echo "   • Block size performance comparison (512B → 1MB)"
    echo "   • Operation type analysis (Sequential/Random/Mixed)"
    echo "   • Performance improvement percentages"
    echo "   • Recommendations for optimal use cases"
}

# Execute main function
main "$@"