#!/bin/bash

# Firecracker VM setup for the IO Performance Comparison Framework
# Handles Firecracker VM initialization and configuration

# Source configuration and utils
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

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
