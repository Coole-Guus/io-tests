#!/bin/bash

# Cleanup functions for the IO Performance Comparison Framework
# Handles proper cleanup of resources

# Source configuration
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

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
    
    # Clean up cgroups - more thorough cleanup
    CGROUP_PATHS=("/sys/fs/cgroup/firecracker_io_test" "/sys/fs/cgroup/cpu/firecracker_io_test" "/sys/fs/cgroup/system.slice/firecracker_io_test.service")
    
    for cgroup_path in "${CGROUP_PATHS[@]}"; do
        if [ -d "$cgroup_path" ]; then
            echo "Cleaning up cgroup: $cgroup_path"
            # Move any processes to root cgroup first
            if [ -f "$cgroup_path/cgroup.procs" ]; then
                while IFS= read -r pid; do
                    [ -n "$pid" ] && echo "$pid" | sudo tee /sys/fs/cgroup/cgroup.procs >/dev/null 2>&1 || true
                done < "$cgroup_path/cgroup.procs" 2>/dev/null || true
            fi
            sudo rmdir "$cgroup_path" 2>/dev/null || true
        fi
    done
    
    # Remove socket
    sudo rm -f "$API_SOCKET"
    
    # Cleanup container
    docker stop io_test_container 2>/dev/null || true
    docker rm io_test_container 2>/dev/null || true
    docker volume rm io_test_volume 2>/dev/null || true
    
    # Cleanup loop device
    if [ -n "${LOOP_DEVICE:-}" ] && [ -e "$LOOP_DEVICE" ]; then
        sudo losetup -d "$LOOP_DEVICE" 2>/dev/null || true
    fi
    
    # Clean up Docker loop device
    if [ -f "./.docker_loop_device" ]; then
        LOOP_DEVICE=$(cat ./.docker_loop_device 2>/dev/null || echo "")
        if [ -n "$LOOP_DEVICE" ]; then
            echo "Detaching loop device: $LOOP_DEVICE"
            sudo losetup -d "$LOOP_DEVICE" 2>/dev/null || true
        fi
        rm -f ./.docker_loop_device
    fi
    
    # Alternative: Find and clean up any loop devices associated with our disk image
    if [ -f "./docker_test_disk.img" ]; then
        # Find loop devices using our disk image
        LOOP_DEVS=$(sudo losetup -j "$(pwd)/docker_test_disk.img" 2>/dev/null | cut -d: -f1 || true)
        for loop_dev in $LOOP_DEVS; do
            if [ -n "$loop_dev" ]; then
                echo "Detaching loop device: $loop_dev"
                sudo losetup -d "$loop_dev" 2>/dev/null || true
            fi
        done
    fi
    
    # Clean up disk images
    rm -f ./docker_test_disk.img 2>/dev/null || true    
    # Cleanup network
    sudo ip link del "$TAP_DEV" 2>/dev/null || true
    
    # Remove iptables rules
    sudo iptables -t nat -D POSTROUTING -o "$(get_host_interface)" -j MASQUERADE 2>/dev/null || true
    
    # Clean up any corrupted test disk (optional - comment out to preserve for debugging)
    # if [ -f "./test_disk.ext4" ]; then
    #     echo "Removing test disk..."
    #     rm -f "./test_disk.ext4"
    # fi
    
    # Clean up resized disk images to save space (keep original in parent directory)
    if [ -f "./ubuntu-24.04.ext4" ] && [ -f "../ubuntu-24.04.ext4" ]; then
        echo "Removing resized disk image (original preserved)..."
        rm -f "./ubuntu-24.04.ext4"
    fi
    
    # Clean up test disk if using dedicated disk
    if [ -f "./test_disk.ext4" ]; then
        echo "Removing dedicated test disk..."
        rm -f "./test_disk.ext4"
    fi
    
    # Clean up copied files to save space
    rm -f "./firecracker" "./vmlinux-6.1.128" "./ubuntu-24.04.id_rsa" "./ubuntu-24.04.ext4.backup" 2>/dev/null || true
    
    echo "Cleanup complete"
}

# Function to get host interface (needed for cleanup)
get_host_interface() {
    ip -j route list default | jq -r '.[0].dev' 2>/dev/null || echo "eth0"
}

# Set trap for cleanup
trap cleanup EXIT
