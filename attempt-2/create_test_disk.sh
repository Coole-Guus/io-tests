#!/bin/bash

# Create a robust test disk for the IO performance comparison

echo "Creating test disk..."
dd if=/dev/zero of=./test_disk.ext4 bs=1M count=1000 >/dev/null 2>&1

echo "Formatting with robust ext4 options..."
mkfs.ext4 -F -O ^64bit -E lazy_itable_init=0,lazy_journal_init=0 ./test_disk.ext4 >/dev/null 2>&1

echo "Verifying filesystem integrity..."
if e2fsck -n ./test_disk.ext4; then
    echo "✓ Test disk created successfully and passed integrity check"
    ls -lh test_disk.ext4
else
    echo "✗ Test disk creation failed integrity check"
    exit 1
fi
