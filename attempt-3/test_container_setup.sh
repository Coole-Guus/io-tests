#!/bin/bash

# Test container setup
# This script tests the container configuration independently

# Get script directory
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"

# Source modules
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/utils.sh"
source "$SCRIPT_DIR/cleanup.sh"
source "$SCRIPT_DIR/container_setup.sh"

echo "=== TESTING CONTAINER SETUP ==="
echo "Setting up and testing container configuration..."

# Run container setup
setup_container

echo ""
echo "=== VERIFYING CONTAINER SETUP ==="

# Check if container is running
if docker ps --filter "name=io_test_container" --filter "status=running" | grep -q io_test_container; then
    echo "Container 'io_test_container' is running"
    
    # Test fio availability
    if docker exec io_test_container fio --version >/dev/null 2>&1; then
        fio_version=$(docker exec io_test_container fio --version 2>/dev/null | head -1)
        echo "fio is available: $fio_version"
    else
        echo "fio is not available in container"
    fi
    
    # Test working directory
    if docker exec io_test_container test -d /root/test_data; then
        echo "Test data directory '/root/test_data' exists"
    else
        echo "Test data directory '/root/test_data' not found"
    fi
    
    # Check available disk space
    disk_info=$(docker exec io_test_container df -h /root | tail -1)
    echo "Container disk space: $disk_info"
    
    # Test a simple IO operation
    echo "Testing simple IO operation..."
    if docker exec io_test_container /bin/bash -c "cd /root/test_data && echo 'test' > test_file && cat test_file && rm test_file" >/dev/null 2>&1; then
        echo "Basic file I/O operations work"
    else
        echo "Basic file I/O operations failed"
    fi
    
    # Test fio with a simple job
    echo "Testing fio with simple job..."
    simple_fio_result=$(docker exec io_test_container /bin/bash -c "cd /root/test_data && fio --name=test --rw=write --size=1M --bs=4k --numjobs=1 --time_based --runtime=2s --filename=test_fio_file --direct=1" 2>&1)
    
    if echo "$simple_fio_result" | grep -q "Run status"; then
        echo "Simple fio test completed successfully"
        # Clean up test file
        docker exec io_test_container rm -f /root/test_data/test_fio_file 2>/dev/null || true
    else
        echo "Simple fio test failed"
        echo "Output: $(echo "$simple_fio_result" | head -3)"
    fi
    
else
    echo "Container 'io_test_container' is not running"
    # Show container logs for debugging
    echo "Container logs:"
    docker logs io_test_container 2>/dev/null | tail -10
fi

echo ""
echo "Container setup test completed!"
echo "Note: Cleanup will be performed automatically on script exit"
