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
