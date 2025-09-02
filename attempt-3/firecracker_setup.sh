#!/bin/bash

# Firecracker VM setup for the IO Performance Comparison Framework
# Handles Firecracker VM initialization and configuration

# Source configuration and utils
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

# Function to create CPU cgroup for limiting
create_cpu_cgroup() {
    local cgroup_name="firecracker_io_test"
    local quota_us=$(echo "$VCPU_COUNT * 100000" | bc | cut -d. -f1)
    local period_us=100000
    
    # Try cgroup v2 first
    if [ -d "/sys/fs/cgroup/system.slice" ]; then
        CGROUP_PATH="/sys/fs/cgroup/$cgroup_name"
        
        # Clean up any existing cgroup first
        if [ -d "$CGROUP_PATH" ]; then
            echo "Cleaning up existing cgroup..."
            # First, try to move any processes to the root cgroup
            if [ -f "$CGROUP_PATH/cgroup.procs" ]; then
                while IFS= read -r pid; do
                    if [ -n "$pid" ] && [ "$pid" != "0" ]; then
                        echo "$pid" | sudo tee /sys/fs/cgroup/cgroup.procs >/dev/null 2>&1 || true
                    fi
                done < "$CGROUP_PATH/cgroup.procs" 2>/dev/null || true
            fi
            # Now try to remove the directory
            sudo rmdir "$CGROUP_PATH" 2>/dev/null || {
                echo "Warning: Could not remove existing cgroup, will try to reuse it"
            }
        fi
        
        # Create or reuse cgroup
        if sudo mkdir -p "$CGROUP_PATH" 2>/dev/null; then
            # Try to write CPU limits with error handling
            if echo "$quota_us $period_us" | sudo tee "$CGROUP_PATH/cpu.max" >/dev/null 2>&1; then
                echo "cgroups v2: Created $CGROUP_PATH with ${VCPU_COUNT} CPU limit"
                return 0
            else
                echo "Warning: Failed to write to cgroup cpu.max, continuing without CPU limits"
                return 1
            fi
        else
            echo "Warning: Could not create cgroup directory, continuing without CPU limits"
            return 1
        fi
    fi
    
    # Fall back to cgroups v1
    if [ -d "/sys/fs/cgroup/cpu" ]; then
        CGROUP_PATH="/sys/fs/cgroup/cpu/$cgroup_name"
        sudo mkdir -p "$CGROUP_PATH" 2>/dev/null || true
        
        if echo "$quota_us" | sudo tee "$CGROUP_PATH/cpu.cfs_quota_us" >/dev/null 2>&1 && \
           echo "$period_us" | sudo tee "$CGROUP_PATH/cpu.cfs_period_us" >/dev/null 2>&1; then
            echo "cgroups v1: Created $CGROUP_PATH with ${VCPU_COUNT} CPU limit"
            return 0
        else
            echo "Warning: Failed to write to cgroup v1, continuing without CPU limits"
            return 1
        fi
    fi
    
    echo "Warning: Could not create CPU cgroup - cgroups not available"
    return 1
}

# Firecracker VM setup
setup_firecracker_vm() {
    echo "Setting up Firecracker VM..."
    
    # Create results directory
    mkdir -p "$RESULTS_DIR"
    
    # Copy required files to local directory for absolute paths
    cp "../firecracker" "./firecracker"
    cp "../vmlinux-6.1.128" "./vmlinux-6.1.128"
    cp "../ubuntu-24.04.ext4" "./ubuntu-24.04.ext4"
    cp "../ubuntu-24.04.id_rsa" "./ubuntu-24.04.id_rsa"
    chmod 600 "./ubuntu-24.04.id_rsa"
    
    # Ensure adequate storage space for IO tests
    if [ "$USE_DEDICATED_TEST_DISK" = "true" ]; then
        echo "Creating dedicated test disk (${DISK_SIZE_MB}MB) for IO tests..."
        dd if=/dev/zero of="./test_disk.ext4" bs=1M count="$DISK_SIZE_MB" 2>/dev/null
        mkfs.ext4 -F "./test_disk.ext4" >/dev/null 2>&1
        echo "Created ${DISK_SIZE_MB}MB test disk"
    else
        echo "Resizing root disk image to provide adequate space for IO tests..."
        # Create a backup and resize method
        cp "./ubuntu-24.04.ext4" "./ubuntu-24.04.ext4.backup"
        
        # Extend the image file first
        dd if=/dev/zero bs=1M count="$((DISK_SIZE_MB - 400))" >> "./ubuntu-24.04.ext4" 2>/dev/null
        
        # Resize the filesystem
        if ! e2fsck -f -p "./ubuntu-24.04.ext4" >/dev/null 2>&1; then
            echo "Filesystem check failed, restoring backup..."
            mv "./ubuntu-24.04.ext4.backup" "./ubuntu-24.04.ext4"
            echo "Warning: Could not resize root filesystem, using original"
        elif ! resize2fs "./ubuntu-24.04.ext4" >/dev/null 2>&1; then
            echo "Resize failed, restoring backup..."
            mv "./ubuntu-24.04.ext4.backup" "./ubuntu-24.04.ext4"
            echo "Warning: Could not resize root filesystem, using original"
        else
            echo "Successfully resized root filesystem to ~${DISK_SIZE_MB}MB"
            rm -f "./ubuntu-24.04.ext4.backup"
        fi
    fi
    
    # Make firecracker executable
    chmod +x "./firecracker"
    
    # Remove existing socket
    sudo rm -f "$API_SOCKET"
    
    # Determine CPU allocation for Firecracker VM
    if [[ "$VCPU_COUNT" =~ ^0\.[0-9]+$ ]]; then
        # Fractional vCPU: use cgroups to limit CPU time
        VM_VCPU_COUNT=1  # VM still needs at least 1 vCPU
        USE_CPU_LIMIT=true
        CPU_QUOTA=$(echo "$VCPU_COUNT * 100000" | bc)  # Convert to microseconds for 100ms period
        CPU_PERIOD=100000  # 100ms period
        DEDICATED_CPU=0  # Use CPU 0 for dedicated access
        echo "Configuring Firecracker for ${VCPU_COUNT} vCPU (${CPU_QUOTA}us quota per ${CPU_PERIOD}us period)"
    else
        # Integer vCPU count
        VM_VCPU_COUNT=$(echo "$VCPU_COUNT" | cut -d. -f1)
        USE_CPU_LIMIT=false
        echo "Configuring Firecracker for ${VM_VCPU_COUNT} vCPU(s)"
    fi
    
    # Create cgroup for CPU limiting if needed
    if [ "$USE_CPU_LIMIT" = "true" ]; then
        # Create cgroup v2 for Firecracker (try both systemd-style and manual)
        echo "Setting up CPU constraints using cgroups..."
        
        # Try cgroup v2 first - use simple path
        CGROUP_PATH="/sys/fs/cgroup/firecracker_io_test"
        
        # Clean up any existing cgroup and processes
        if [ -d "$CGROUP_PATH" ]; then
            echo "Cleaning up existing cgroup processes..."
            # Move any existing processes to root cgroup
            if [ -f "$CGROUP_PATH/cgroup.procs" ]; then
                while IFS= read -r pid; do
                    [ -n "$pid" ] && echo "$pid" | sudo tee /sys/fs/cgroup/cgroup.procs >/dev/null 2>&1 || true
                done < "$CGROUP_PATH/cgroup.procs" 2>/dev/null || true
            fi
            sudo rmdir "$CGROUP_PATH" 2>/dev/null || true
        fi
        
        # Create new cgroup
        if sudo mkdir -p "$CGROUP_PATH" 2>/dev/null; then
            # Set CPU limits (format: quota period) - be more careful with writes
            if echo "$CPU_QUOTA $CPU_PERIOD" | sudo tee "$CGROUP_PATH/cpu.max" >/dev/null 2>&1; then
                echo "Successfully created cgroup with CPU limit: $CPU_QUOTA/$CPU_PERIOD"
            else
                echo "Warning: Could not set CPU limits in cgroup, continuing without limits"
                USE_CPU_LIMIT=false
            fi
        else
            echo "Warning: Could not create cgroup, continuing without CPU limits"
            USE_CPU_LIMIT=false
        fi
    fi
    
    # Start Firecracker with CPU constraints
    if [ "$USE_CPU_LIMIT" = "true" ]; then
        # Use taskset to pin to specific CPU
        taskset -c $DEDICATED_CPU ./firecracker --api-sock "$API_SOCKET" --no-seccomp &
        FIRECRACKER_PID=$!
        echo "Started Firecracker monitor PID: $FIRECRACKER_PID on CPU $DEDICATED_CPU"
        
        # Add process to cgroup if cgroup was successfully created
        if [ -d "$CGROUP_PATH" ] && [ -f "$CGROUP_PATH/cgroup.procs" ]; then
            echo "Adding Firecracker process to cgroup..."
            echo "$FIRECRACKER_PID" | sudo tee "$CGROUP_PATH/cgroup.procs" >/dev/null 2>&1 || echo "Warning: Could not add process to cgroup"
        fi
    else
        ./firecracker --api-sock "$API_SOCKET" --no-seccomp &
        FIRECRACKER_PID=$!
        echo "Started Firecracker monitor PID: $FIRECRACKER_PID"
    fi
    
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
            \"kernel_image_path\": \"$(pwd)/vmlinux-6.1.128\",
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

    # Add dedicated test disk if configured
    if [ "$USE_DEDICATED_TEST_DISK" = "true" ] && [ -f "./test_disk.ext4" ]; then
        echo "Adding dedicated test disk to VM..."
        sudo curl -X PUT --unix-socket "${API_SOCKET}" \
            --data "{
                \"drive_id\": \"test_disk\",
                \"path_on_host\": \"$(pwd)/test_disk.ext4\",
                \"is_root_device\": false,
                \"is_read_only\": false
            }" \
            "http://localhost/drives/test_disk"
        echo "VM will use dedicated ${DISK_SIZE_MB}MB test disk (/dev/vdb)"
    else
        echo "VM will use root filesystem for testing"
    fi
    
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
            \"vcpu_count\": $VM_VCPU_COUNT,
            \"mem_size_mib\": $MEMORY_SIZE_MIB
        }" \
        "http://localhost/machine-config"
    
    # Start the VM
    sleep 0.1
    sudo curl -X PUT --unix-socket "${API_SOCKET}" \
        --data "{
            \"action_type\": \"InstanceStart\"
        }" \
        "http://localhost/actions"
    
    # Apply CPU limits to the actual KVM process (not just the Firecracker monitor)
    if [ "$USE_CPU_LIMIT" = "true" ]; then
        # Create CPU cgroup for limits
        create_cpu_cgroup
        
        echo "Waiting for VM vCPU threads to start..."
        sleep 3
        
        # Find vCPU threads created by Firecracker
        # Firecracker creates threads for vCPUs that we need to limit
        VCPU_THREADS=""
        for i in {1..15}; do
            # Look for threads that are children of the Firecracker process
            CHILD_THREADS=$(ps -T -p $FIRECRACKER_PID -o pid,tid,comm 2>/dev/null | grep -v "PID\|firecracker" | awk '{print $2}' || true)
            
            if [ -n "$CHILD_THREADS" ]; then
                VCPU_THREADS="$CHILD_THREADS"
                echo "Found Firecracker vCPU threads: $VCPU_THREADS"
                break
            fi
            
            # Alternative: look for threads with names containing 'vcpu' or similar patterns
            VCPU_NAMED=$(pgrep -f "vcpu" 2>/dev/null | head -n2 || true)
            if [ -n "$VCPU_NAMED" ]; then
                VCPU_THREADS="$VCPU_NAMED"
                echo "Found vCPU-named threads: $VCPU_THREADS"
                break
            fi
            
            # Fallback: look for high-CPU threads that started recently
            HIGH_CPU_RECENT=$(ps -eTo pid,tid,%cpu,etime,comm --sort=-%cpu | awk 'NR>1 && $3 > 5 && $4 ~ /00:0[0-9]/ {print $2}' | head -n2 || true)
            if [ -n "$HIGH_CPU_RECENT" ]; then
                VCPU_THREADS="$HIGH_CPU_RECENT"
                echo "Found recent high-CPU threads (likely vCPU): $VCPU_THREADS"
                break
            fi
            
            sleep 1
            echo "  Attempt $i/15: Searching for vCPU threads..."
        done
        
        if [ -n "$VCPU_THREADS" ]; then
            echo "Applying CPU constraints to vCPU threads..."
            for THREAD_ID in $VCPU_THREADS; do
                if [ -n "$THREAD_ID" ] && [ "$THREAD_ID" != "$FIRECRACKER_PID" ]; then
                    echo "  Constraining thread $THREAD_ID"
                    
                    # Pin thread to the dedicated CPU
                    sudo taskset -cp $DEDICATED_CPU $THREAD_ID 2>/dev/null || true
                    
                    # Move thread to cgroup for CPU limiting
                    if [ -n "$CGROUP_PATH" ] && [ -d "$CGROUP_PATH" ]; then
                        echo $THREAD_ID | sudo tee "$CGROUP_PATH/cgroup.procs" >/dev/null 2>&1 || true
                    fi
                    
                    # Verify affinity
                    AFFINITY=$(taskset -cp $THREAD_ID 2>/dev/null | cut -d: -f2 | tr -d ' ' || echo 'unknown')
                    echo "    Thread $THREAD_ID CPU affinity: $AFFINITY"
                fi
            done
            
            echo "Applied ${VCPU_COUNT} vCPU limit to VM threads on CPU $DEDICATED_CPU"
        else
            echo "Warning: Could not identify vCPU threads for CPU limiting"
            echo "Applying constraints to main Firecracker process as fallback"
            
            # Fallback: constrain the main Firecracker process
            sudo taskset -cp $DEDICATED_CPU $FIRECRACKER_PID 2>/dev/null || true
            echo $FIRECRACKER_PID | sudo tee /sys/fs/cgroup/firecracker_io_test/cgroup.procs >/dev/null 2>&1 || \
            echo $FIRECRACKER_PID | sudo tee /sys/fs/cgroup/cpu/firecracker_io_test/cgroup.procs >/dev/null 2>&1 || true
        fi
    fi
    
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
        # Setup networking
        ip route add default via $TAP_IP dev eth0 2>/dev/null || true
        echo 'nameserver 8.8.8.8' > /etc/resolv.conf
        
        # Install required packages
        apt-get update -qq
        apt-get install -y fio sysstat bc procps >/dev/null 2>&1
        
        # Setup test directory based on configuration
        if [ '$USE_DEDICATED_TEST_DISK' = 'true' ] && [ -b /dev/vdb ]; then
            echo 'Setting up dedicated test disk...'
            mkdir -p /mnt/test_data
            mount /dev/vdb /mnt/test_data
            chmod 777 /mnt/test_data
            cd /mnt/test_data && rm -rf ./* 2>/dev/null || true
            sync
            
            echo 'Firecracker storage configuration:'
            echo '==================================='
            echo 'Storage backend: Raw block device (virtio-blk)'
            echo 'Device: /dev/vdb'
            echo 'Mount point: /mnt/test_data'
            echo 'Filesystem: ext4'
            mount | grep test_data
            echo ''
            echo 'VM using dedicated test disk:'
            df -h /mnt/test_data
            echo 'Available space on test disk:'
            df -h /mnt/test_data | tail -1 | awk '{print \"Available: \" \$4 \" (\" \$5 \" used)\"}'
            echo ''
            echo 'Block device info:'
            lsblk /dev/vdb 2>/dev/null || true
        else
            echo 'Setting up root filesystem for testing...'
            mkdir -p /root/test_data
            cd /root/test_data && rm -rf ./* 2>/dev/null || true
            sync
            
            echo 'VM using root filesystem:'
            df -h /root
            echo 'Available space on root fs:'
            df -h /root | tail -1 | awk '{print \"Available: \" \$4 \" (\" \$5 \" used)\"}'
        fi
        
        # Verify adequate space
        if [ '$USE_DEDICATED_TEST_DISK' = 'true' ] && [ -b /dev/vdb ]; then
            available_mb=\$(df -m /mnt/test_data | tail -1 | awk '{print \$4}')
            test_location='/mnt/test_data'
        else
            available_mb=\$(df -m /root | tail -1 | awk '{print \$4}')
            test_location='/root/test_data'
        fi
        
        echo \"Test location: \$test_location\"
        echo \"Available space: \${available_mb}MB\"
        
        if [ \"\$available_mb\" -lt 100 ]; then
            echo 'ERROR: Insufficient disk space for IO tests!'
            echo 'Available: '\$available_mb'MB, Minimum required: 100MB'
            exit 1
        else
            echo 'Adequate space confirmed for IO testing'
        fi
        
        echo 'VM setup completed successfully'
    " || {
        echo "Error: VM setup failed"
        return 1
    }
    
    echo "Firecracker VM setup complete"
}
