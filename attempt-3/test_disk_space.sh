#!/bin/bash

# Test script to verify adequate disk space is available
# This helps ensure the "Limited disk space" warning never appears

# Source configuration
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

echo "=== Disk Space Test ==="
echo "Configuration:"
echo "  USE_DEDICATED_TEST_DISK: $USE_DEDICATED_TEST_DISK"
echo "  DISK_SIZE_MB: $DISK_SIZE_MB MB"
echo "  VCPU_COUNT: $VCPU_COUNT"
echo "  MEMORY_SIZE_MIB: $MEMORY_SIZE_MIB MB"
echo ""

# Test dedicated test disk creation
if [ "$USE_DEDICATED_TEST_DISK" = "true" ]; then
    echo "Testing dedicated test disk creation..."
    dd if=/dev/zero of="./test_disk_sample.ext4" bs=1M count=100 2>/dev/null
    mkfs.ext4 -F "./test_disk_sample.ext4" >/dev/null 2>&1
    
    if [ -f "./test_disk_sample.ext4" ]; then
        echo "✓ Successfully created 100MB test disk"
        
        # Test mounting and space check
        mkdir -p /tmp/test_mount
        sudo mount -o loop "./test_disk_sample.ext4" /tmp/test_mount 2>/dev/null
        if [ $? -eq 0 ]; then
            available_space=$(df -m /tmp/test_mount | tail -1 | awk '{print $4}')
            echo "✓ Test disk mounted successfully"
            echo "  Available space: ${available_space}MB"
            
            if [ "$available_space" -gt 50 ]; then
                echo "✓ Adequate space confirmed (>50MB available)"
            else
                echo "✗ Warning: Limited space on test disk"
            fi
            
            sudo umount /tmp/test_mount
        else
            echo "✗ Failed to mount test disk"
        fi
        
        rm -f "./test_disk_sample.ext4"
        rmdir /tmp/test_mount 2>/dev/null
    else
        echo "✗ Failed to create test disk"
    fi
else
    echo "Testing root filesystem resize..."
    # Copy original image for testing
    if [ -f "../ubuntu-24.04.ext4" ]; then
        cp "../ubuntu-24.04.ext4" "./test_resize.ext4"
        original_size=$(ls -lh "./test_resize.ext4" | awk '{print $5}')
        echo "  Original image size: $original_size"
        
        # Test extending the image
        dd if=/dev/zero bs=1M count=100 >> "./test_resize.ext4" 2>/dev/null
        new_size=$(ls -lh "./test_resize.ext4" | awk '{print $5}')
        echo "  Extended image size: $new_size"
        
        # Test filesystem check and resize
        if e2fsck -f -p "./test_resize.ext4" >/dev/null 2>&1; then
            if resize2fs "./test_resize.ext4" >/dev/null 2>&1; then
                echo "✓ Successfully extended and resized filesystem"
            else
                echo "✗ Failed to resize filesystem"
            fi
        else
            echo "✗ Filesystem check failed"
        fi
        
        rm -f "./test_resize.ext4"
    else
        echo "✗ Original ubuntu image not found"
    fi
fi

echo ""
echo "=== Configuration Recommendations ==="

if [ "$USE_DEDICATED_TEST_DISK" = "true" ]; then
    if [ "$DISK_SIZE_MB" -lt 512 ]; then
        echo "⚠ Consider increasing DISK_SIZE_MB to at least 512MB for comprehensive tests"
    else
        echo "✓ DISK_SIZE_MB ($DISK_SIZE_MB MB) should provide adequate space"
    fi
else
    echo "ℹ Using root filesystem resize method"
    echo "  Consider setting USE_DEDICATED_TEST_DISK=true for better isolation"
fi

echo ""
echo "To run with maximum disk space (up to 30GB as requested):"
echo "DISK_SIZE_MB=30720 ./run_io_benchmark.sh"
echo ""
echo "For quick tests with adequate space:"
echo "DISK_SIZE_MB=1024 ./run_io_benchmark.sh"
