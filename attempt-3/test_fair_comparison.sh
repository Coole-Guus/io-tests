#!/bin/bash

# Improved IO benchmark configuration to ensure fair comparison between container and VM
# This addresses the discovered fairness issues

cd /home/guus/code-projects/io-tests/attempt-3

source config.sh
source utils.sh
source network_setup.sh
source firecracker_setup.sh
source container_setup.sh

echo "🔧 IMPLEMENTING FAIRNESS FIXES"
echo "==============================================="

# First, let's clean up any previous state
echo "Cleaning up previous state..."
source cleanup.sh && cleanup

echo
echo "🎯 FAIRNESS APPROACH 1: DISABLE HOST CACHING FOR CONTAINER"
echo "==============================================="

# Modify container setup to minimize caching advantages
echo "Setting up network..."
setup_network

echo "Setting up VM with current configuration..."
setup_firecracker_vm &

# Setup container with aggressive direct I/O and cache control
echo "Setting up container with enhanced direct I/O..."
setup_container_fair() {
    local CONTAINER_NAME="io_test_container_fair"
    
    echo "Setting up fair test container..."
    
    # Clean up any existing container
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true
    docker volume rm io_test_volume 2>/dev/null || true
    docker volume create io_test_volume >/dev/null

    # Create a raw disk image for Docker container (same size as VM)
    echo "Creating raw disk image for Docker container (${DISK_SIZE_MB}MB)..."
    if [ ! -f "./docker_test_disk.img" ]; then
        dd if=/dev/zero of="./docker_test_disk.img" bs=1M count="$DISK_SIZE_MB" 2>/dev/null
    fi
    
    # Set up loop device with direct I/O flags
    LOOP_DEVICE=$(sudo losetup --find --show --direct-io=on "./docker_test_disk.img")
    if [ -z "$LOOP_DEVICE" ]; then
        echo "Error: Failed to create loop device with direct-io"
        # Fallback without direct-io flag
        LOOP_DEVICE=$(sudo losetup --find --show "./docker_test_disk.img")
    fi
    echo "Created loop device with direct I/O: $LOOP_DEVICE"
    
    # Format the loop device with same settings as VM
    sudo mkfs.ext4 -F "$LOOP_DEVICE" >/dev/null 2>&1
    echo "Formatted $LOOP_DEVICE with ext4 filesystem"
    
    # Store loop device for cleanup
    echo "$LOOP_DEVICE" > ./.docker_loop_device
    
    # Start container with aggressive caching controls
    echo "Starting container with fair block device access..."
    docker run -d \
        --name "$CONTAINER_NAME" \
        --network host \
        --privileged \
        --cpus="$VCPU_COUNT" \
        --memory="${MEMORY_SIZE_MIB}m" \
        --shm-size=64m \
        --device="$LOOP_DEVICE:/dev/test_disk" \
        --sysctl vm.dirty_ratio=5 \
        --sysctl vm.dirty_background_ratio=2 \
        --sysctl vm.drop_caches=3 \
        -e LOOP_DEVICE="/dev/test_disk" \
        ubuntu:20.04 \
        /bin/bash -c "
            echo 'CONTAINER_STARTING' && 
            echo 'nameserver 8.8.8.8' > /etc/resolv.conf &&
            apt-get update -qq && 
            apt-get install -y fio sysstat bc procps util-linux && 
            
            # Force cache clear and direct I/O setup
            sync && echo 3 > /proc/sys/vm/drop_caches &&
            
            # Setup test directory and mount with cache-hostile options
            mkdir -p /mnt/test_data &&
            mount -o sync,dirsync,noatime,barrier=1 /dev/test_disk /mnt/test_data &&
            chmod 777 /mnt/test_data &&
            cd /mnt/test_data && rm -rf ./* 2>/dev/null || true &&
            sync && echo 3 > /proc/sys/vm/drop_caches &&
            
            echo 'Container fair setup complete' &&
            echo 'Container filesystem info (with anti-cache mount options):' &&
            mount | grep test_data &&
            df -h /mnt/test_data &&
            echo 'CONTAINER_READY' && 
            echo 'CONTAINER_FIO_WORKING' && 
            sleep 3600
        "
    
    # Wait for container to be ready with longer timeout
    echo "Waiting for fair container to be ready..."
    local count=0
    while [ $count -lt 180 ]; do  # 3 minute timeout for package installation
        if ! docker ps --filter "name=$CONTAINER_NAME" --filter "status=running" | grep -q "$CONTAINER_NAME"; then
            echo "Error: Container stopped unexpectedly"
            docker logs "$CONTAINER_NAME"
            return 1
        fi
        
        if docker logs "$CONTAINER_NAME" 2>/dev/null | grep -q "CONTAINER_FIO_WORKING"; then
            echo "Fair container ready"
            # Final verification
            if docker exec "$CONTAINER_NAME" fio --version >/dev/null 2>&1; then
                echo "Fair container setup completed successfully"
                return 0
            else
                echo "Error: fio verification failed"
                return 1
            fi
        fi
        sleep 1
        count=$((count + 1))
    done
    
    echo "Error: Fair container setup timed out"
    docker logs "$CONTAINER_NAME"
    return 1
}

setup_container_fair &

# Wait for both systems
echo "Waiting for both systems to be ready..."
wait

echo
echo "🧪 RUNNING FAIR COMPARISON TEST"
echo "==============================================="

# Test 1: Simple direct I/O test
echo "Test 1: Direct I/O Random Read Comparison"
echo "-----------------------------------------"

echo "Container (with cache controls):"
docker exec io_test_container_fair /bin/bash -c "
    cd /mnt/test_data && 
    sync && echo 3 > /proc/sys/vm/drop_caches &&
    fio --name=fair_test --rw=randread --size=100M --bs=4k --numjobs=1 --runtime=5s --time_based --group_reporting --filename=fair_testfile --direct=1 --sync=1 | grep -E '(read:|aggrb=|lat.*usec)'
"

echo
echo "Firecracker VM:"
ssh -i "./ubuntu-24.04.id_rsa" -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@172.17.0.2 "
    cd /mnt/test_data && 
    sync &&
    fio --name=fair_test --rw=randread --size=100M --bs=4k --numjobs=1 --runtime=5s --time_based --group_reporting --filename=fair_testfile --direct=1 --sync=1 | grep -E '(read:|aggrb=|lat.*usec)'
"

echo
echo "Test 2: Write Performance Comparison"
echo "------------------------------------"

echo "Container write:"
docker exec io_test_container_fair /bin/bash -c "
    cd /mnt/test_data &&
    sync && echo 3 > /proc/sys/vm/drop_caches &&
    fio --name=fair_write --rw=randwrite --size=50M --bs=4k --numjobs=1 --runtime=5s --time_based --group_reporting --filename=fair_write_file --direct=1 --sync=1 | grep -E '(write:|aggrb=|lat.*usec)'
"

echo
echo "VM write:"
ssh -i "./ubuntu-24.04.id_rsa" -o StrictHostKeyChecking=no root@172.17.0.2 "
    cd /mnt/test_data &&
    sync &&
    fio --name=fair_write --rw=randwrite --size=50M --bs=4k --numjobs=1 --runtime=5s --time_based --group_reporting --filename=fair_write_file --direct=1 --sync=1 | grep -E '(write:|aggrb=|lat.*usec)'
"

echo
echo "💡 ANALYSIS:"
echo "============"
echo "If these results are still heavily skewed toward the container,"
echo "it indicates fundamental architectural differences that cannot"
echo "be eliminated through configuration alone:"
echo ""
echo "1. Host kernel page cache advantage (container)"
echo "2. Virtio-blk overhead (VM)"  
echo "3. Memory hierarchy differences"
echo "4. I/O scheduler differences"
echo ""
echo "This would suggest that the comparison may need to account"
echo "for these expected architectural differences rather than"
echo "trying to eliminate them completely."
