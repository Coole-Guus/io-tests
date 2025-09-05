#!/bin/bash

# Test Firecracker setup
# This script tests the Firecracker VM configuration independently

# Get script directory
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"

# Source modules
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/utils.sh"
source "$SCRIPT_DIR/cleanup.sh"
source "$SCRIPT_DIR/network_setup.sh"
source "$SCRIPT_DIR/firecracker_setup.sh"

echo "=== TESTING FIRECRACKER SETUP ==="
echo "Setting up and testing Firecracker VM configuration..."

# Setup network first
setup_network

# Run Firecracker setup
setup_firecracker_vm

echo ""
echo "=== VERIFYING FIRECRACKER SETUP ==="

# Check if Firecracker process is running
if pgrep -f "firecracker.*${API_SOCKET}" >/dev/null; then
    echo "✓ Firecracker process is running"
else
    echo "❌ Firecracker process not found"
fi

# Check if API socket exists
if [ -S "$API_SOCKET" ]; then
    echo "✓ API socket exists: $API_SOCKET"
else
    echo "❌ API socket not found: $API_SOCKET"
fi

# Test VM connectivity
if wait_for_connectivity "$GUEST_IP"; then
    echo "✓ VM is reachable at $GUEST_IP"
    
    # Test SSH connectivity
    if timeout 10 ssh -i "./ubuntu-24.04.id_rsa" -o StrictHostKeyChecking=no root@"$GUEST_IP" "echo 'SSH test successful'" >/dev/null 2>&1; then
        echo "✓ SSH connectivity works"
        
        # Test fio availability in VM
        if timeout 10 ssh -i "./ubuntu-24.04.id_rsa" -o StrictHostKeyChecking=no root@"$GUEST_IP" "fio --version" >/dev/null 2>&1; then
            fio_version=$(timeout 10 ssh -i "./ubuntu-24.04.id_rsa" -o StrictHostKeyChecking=no root@"$GUEST_IP" "fio --version" 2>/dev/null | head -1)
            echo "✓ fio is available in VM: $fio_version"
        else
            echo "❌ fio is not available in VM"
        fi
        
        # Test working directory
        if timeout 10 ssh -i "./ubuntu-24.04.id_rsa" -o StrictHostKeyChecking=no root@"$GUEST_IP" "test -d /mnt/test_data" >/dev/null 2>&1; then
            echo "✓ Test data directory '/mnt/test_data' exists in VM"
            test_dir="/mnt/test_data"
        elif timeout 10 ssh -i "./ubuntu-24.04.id_rsa" -o StrictHostKeyChecking=no root@"$GUEST_IP" "test -d /root/test_data" >/dev/null 2>&1; then
            echo "✓ Test data directory '/root/test_data' exists in VM"
            test_dir="/root/test_data"
        else
            echo "❌ Test data directory not found in VM"
            test_dir="/root/test_data"  # fallback
        fi
        
        # Check available disk space
        disk_info=$(timeout 10 ssh -i "./ubuntu-24.04.id_rsa" -o StrictHostKeyChecking=no root@"$GUEST_IP" "df -h /root" 2>/dev/null | tail -1)
        echo "VM disk space: $disk_info"
        
        # Test a simple IO operation
        echo "Testing simple IO operation in VM..."
        if timeout 10 ssh -i "./ubuntu-24.04.id_rsa" -o StrictHostKeyChecking=no root@"$GUEST_IP" "cd $test_dir && echo 'test' > test_file && cat test_file && rm test_file" >/dev/null 2>&1; then
            echo "✓ Basic file I/O operations work in VM"
        else
            echo "❌ Basic file I/O operations failed in VM"
        fi
        
        # Test fio with a simple job
        echo "Testing fio with simple job in VM..."
        simple_fio_result=$(timeout 15 ssh -i "./ubuntu-24.04.id_rsa" -o StrictHostKeyChecking=no root@"$GUEST_IP" "cd $test_dir && fio --name=test --rw=write --size=1M --bs=4k --numjobs=1 --time_based --runtime=2s --filename=test_fio_file --direct=1" 2>&1)
        
        if echo "$simple_fio_result" | grep -q "Run status"; then
            echo "✓ Simple fio test completed successfully in VM"
            # Clean up test file
            timeout 10 ssh -i "./ubuntu-24.04.id_rsa" -o StrictHostKeyChecking=no root@"$GUEST_IP" "rm -f $test_dir/test_fio_file" 2>/dev/null || true
        else
            echo "❌ Simple fio test failed in VM"
            echo "Output: $(echo "$simple_fio_result" | head -3)"
        fi
        
    else
        echo "❌ SSH connectivity failed"
    fi
else
    echo "❌ VM is not reachable at $GUEST_IP"
fi

# Check log file
if [ -f "$LOGFILE" ]; then
    echo "✓ Firecracker log file created: $LOGFILE"
    log_size=$(stat -f%z "$LOGFILE" 2>/dev/null || stat -c%s "$LOGFILE" 2>/dev/null || echo "0")
    echo "Log file size: $log_size bytes"
else
    echo "❌ Firecracker log file not found: $LOGFILE"
fi

echo ""
echo "✅ Firecracker setup test completed!"
echo "Note: Cleanup will be performed automatically on script exit"
