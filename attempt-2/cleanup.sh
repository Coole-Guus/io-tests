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

# Function to get host interface (needed for cleanup)
get_host_interface() {
    ip -j route list default | jq -r '.[0].dev' 2>/dev/null || echo "eth0"
}

# Set trap for cleanup
trap cleanup EXIT
