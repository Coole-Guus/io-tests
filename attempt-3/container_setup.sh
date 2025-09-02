#!/bin/bash

# Container setup for the IO Performance Comparison Framework
# Handles Docker container initialization and configuration

# Source configuration and utils
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

# Container setup
setup_container() {
    echo "Setting up test container..."
    
    # Stop any existing container
    docker stop io_test_container 2>/dev/null || true
    docker rm io_test_container 2>/dev/null || true
    
    # Create a dedicated volume for fair IO comparison
    docker volume rm io_test_volume 2>/dev/null || true
    docker volume create io_test_volume
    
    # Clean up any existing loop devices for our disk image first
    if [ -f "./docker_test_disk.img" ]; then
        echo "Cleaning up any existing loop devices..."
        OLD_LOOPS=$(sudo losetup -j "$(pwd)/docker_test_disk.img" 2>/dev/null | cut -d: -f1 || true)
        for old_loop in $OLD_LOOPS; do
            if [ -n "$old_loop" ]; then
                sudo losetup -d "$old_loop" 2>/dev/null || true
            fi
        done
        rm -f ./docker_test_disk.img
    fi
    
    # Create raw disk image for Docker (same as Firecracker)
    echo "Creating raw disk image for Docker container (${DISK_SIZE_MB}MB)..."
    dd if=/dev/zero of="./docker_test_disk.img" bs=1M count="$DISK_SIZE_MB" 2>/dev/null
    
    # Create loop device for the raw disk
    LOOP_DEVICE=$(sudo losetup --find --show "$(pwd)/docker_test_disk.img")
    if [ -z "$LOOP_DEVICE" ]; then
        echo "Error: Failed to create loop device"
        return 1
    fi
    echo "Created loop device: $LOOP_DEVICE"
    
    # Format the loop device with ext4 (same as Firecracker)
    sudo mkfs.ext4 -F "$LOOP_DEVICE" >/dev/null 2>&1
    echo "Formatted $LOOP_DEVICE with ext4 filesystem"
    
    # Store loop device for cleanup
    echo "$LOOP_DEVICE" > ./.docker_loop_device
    
    # Start container with raw block device access for fair comparison
    echo "Starting container with raw block device access..."
    docker run -d \
        --name io_test_container \
        --network host \
        --privileged \
        --cpus="$VCPU_COUNT" \
        --memory="${MEMORY_SIZE_MIB}m" \
        --shm-size=1g \
        --tmpfs /tmp:noexec,nosuid,size=100m \
        --device="$LOOP_DEVICE:/dev/test_disk" \
        -e LOOP_DEVICE="/dev/test_disk" \
        ubuntu:20.04 \
        /bin/bash -c "
            echo 'CONTAINER_STARTING' && 
            echo 'nameserver 8.8.8.8' > /etc/resolv.conf &&
            echo 'nameserver 8.8.4.4' >> /etc/resolv.conf &&
            apt-get update -qq && 
            apt-get install -y fio sysstat bc procps && 
            
            # Setup test directory and mount the dedicated block device for fair comparison
            mkdir -p /mnt/test_data &&
            mount /dev/test_disk /mnt/test_data &&
            chmod 777 /mnt/test_data &&
            cd /mnt/test_data && rm -rf ./* 2>/dev/null || true &&
            sync &&
            
            echo 'Container filesystem info:' &&
            echo 'Container test volume (used for IO tests):' &&
            df -h /mnt/test_data &&
            echo 'Available space on test volume:' &&
            df -h /mnt/test_data | tail -1 | awk '{print \"Available: \" \$4 \" (\" \$5 \" used)\"}' &&
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
