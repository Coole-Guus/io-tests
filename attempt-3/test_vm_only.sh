#!/bin/bash

# Quick test to verify VM connectivity without hanging
cd /home/guus/code-projects/io-tests/attempt-3

source config.sh
source utils.sh  
source network_setup.sh
source firecracker_setup.sh

echo "=== Setting up network ==="
setup_network

echo "=== Starting Firecracker VM ==="
# Set up everything until the SSH connection
setup_firecracker_vm() {
    local VM_NAME="${INSTANCE_NAME:-io-test-vm}"
    local GUEST_IP="$FC_VM_IP"
    local TAP_IP="$FC_HOST_IP"
    
    echo "Setting up Firecracker VM..."
    
    # Ensure adequate storage space for IO tests
    if [ "$USE_DEDICATED_TEST_DISK" = "true" ]; then
        echo "Creating dedicated test disk (${DISK_SIZE_MB}MB) for IO tests..."
        dd if=/dev/zero of="./test_disk.ext4" bs=1M count="$DISK_SIZE_MB" 2>/dev/null
        mkfs.ext4 -F "./test_disk.ext4" >/dev/null 2>&1
        echo "Created ${DISK_SIZE_MB}MB test disk"
    fi
    
    # Set up CPU constraints
    echo "Configuring Firecracker for ${FC_VCPU_COUNT} vCPU (${FC_VCPU_QUOTA_US}.0us quota per ${FC_VCPU_PERIOD_US}us period)"
    echo "Setting up CPU constraints using cgroups..."
    
    # Create cgroup directory for this test
    sudo mkdir -p /sys/fs/cgroup/firecracker_io_test 2>/dev/null || true
    
    # Configure CPU limit
    echo "${FC_VCPU_QUOTA_US}" | sudo tee /sys/fs/cgroup/firecracker_io_test/cpu.max > /dev/null
    echo "Successfully created cgroup with CPU limit: ${FC_VCPU_QUOTA_US}.0/${FC_VCPU_PERIOD_US}"
    
    # Start Firecracker in cgroup and pin to specific CPU
    taskset -c $FC_CPU_CORE sudo cgexec -g cpu:firecracker_io_test \
        ./firecracker --api-sock /tmp/firecracker-${VM_NAME}.socket > ./firecracker-${VM_NAME}.log 2>&1 &
    
    local FC_PID=$!
    echo "Started Firecracker monitor PID: $FC_PID on CPU $FC_CPU_CORE"
    
    # Set up configuration 
    sleep 1
    curl -X PUT 'http://localhost/' \
        -H 'Accept: application/json' \
        -H 'Content-Type: application/json' \
        --unix-socket "/tmp/firecracker-${VM_NAME}.socket" \
        -d '{
            "log_path": "'$(pwd)'/firecracker-'${VM_NAME}'.log",
            "level": "Info",
            "show_level": true,
            "show_log_origin": true
        }'

    curl -X PUT 'http://localhost/boot-source' \
        -H 'Accept: application/json' \
        -H 'Content-Type: application/json' \
        --unix-socket "/tmp/firecracker-${VM_NAME}.socket" \
        -d '{
            "kernel_image_path": "./vmlinux-6.1.141",
            "boot_args": "console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw"
        }'

    curl -X PUT 'http://localhost/drives/rootfs' \
        -H 'Accept: application/json' \
        -H 'Content-Type: application/json' \
        --unix-socket "/tmp/firecracker-${VM_NAME}.socket" \
        -d '{
            "drive_id": "rootfs",
            "path_on_host": "./ubuntu-24.04.ext4",
            "is_root_device": true,
            "is_read_only": false
        }'

    if [ "$USE_DEDICATED_TEST_DISK" = "true" ]; then
        echo "Adding dedicated test disk to VM..."
        curl -X PUT 'http://localhost/drives/test_disk' \
            -H 'Accept: application/json' \
            -H 'Content-Type: application/json' \
            --unix-socket "/tmp/firecracker-${VM_NAME}.socket" \
            -d '{
                "drive_id": "test_disk", 
                "path_on_host": "./test_disk.ext4",
                "is_root_device": false,
                "is_read_only": false
            }'
        echo "VM will use dedicated ${DISK_SIZE_MB}MB test disk (/dev/vdb)"
    fi

    curl -X PUT 'http://localhost/network-interfaces/eth0' \
        -H 'Accept: application/json' \
        -H 'Content-Type: application/json' \
        --unix-socket "/tmp/firecracker-${VM_NAME}.socket" \
        -d '{
            "iface_id": "eth0",
            "guest_mac": "'$FC_VM_MAC'",
            "host_dev_name": "'$TAP_INTERFACE'"
        }'

    curl -X PUT 'http://localhost/machine-config' \
        -H 'Accept: application/json' \
        -H 'Content-Type: application/json' \
        --unix-socket "/tmp/firecracker-${VM_NAME}.socket" \
        -d '{
            "vcpu_count": '$FC_VCPU_COUNT',
            "mem_size_mib": '$FC_MEMORY_MB',
            "smt": false
        }'

    curl -X PUT 'http://localhost/actions' \
        -H 'Accept: application/json' \
        -H 'Content-Type: application/json' \
        --unix-socket "/tmp/firecracker-${VM_NAME}.socket" \
        -d '{
            "action_type": "InstanceStart"
        }'

    echo "Waiting for VM to boot..."
    sleep 5
    
    echo "Waiting for connectivity to $GUEST_IP..."
    local count=0
    while [ $count -lt 30 ]; do
        if ping -c 1 -W 1 "$GUEST_IP" >/dev/null 2>&1; then
            echo "Connectivity established"
            break
        fi
        sleep 1
        count=$((count + 1))
    done

    if [ $count -eq 30 ]; then
        echo "Error: Could not establish connectivity to VM"
        return 1
    fi

    # Test SSH connectivity and internet access
    echo "Testing SSH connectivity..."
    if timeout 10 ssh -i "./ubuntu-24.04.id_rsa" -o StrictHostKeyChecking=no -o PasswordAuthentication=no -o ConnectTimeout=5 root@"$GUEST_IP" "echo 'SSH working'"; then
        echo "SSH connection successful"
        
        echo "Testing internet connectivity from VM..."
        if timeout 10 ssh -i "./ubuntu-24.04.id_rsa" -o StrictHostKeyChecking=no -o PasswordAuthentication=no -o ConnectTimeout=5 root@"$GUEST_IP" "ping -c 1 8.8.8.8"; then
            echo "Internet connectivity working"
        else
            echo "WARNING: VM has no internet connectivity - package installation will fail"
            echo "This might be why the full setup hangs"
        fi
    else
        echo "ERROR: SSH connection failed"
        return 1
    fi
    
    return 0
}

setup_firecracker_vm
