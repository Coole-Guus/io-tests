#!/bin/bash

# Test script to verify CPU constraints are working
set -e

source ./config.sh
source ./utils.sh

echo "=== Testing CPU Constraints ==="
echo "Target vCPU: ${VCPU_COUNT}"

# Set CPU constraint variables
export USE_CPU_LIMIT=true  
export DEDICATED_CPU=0

echo "1. Testing Firecracker setup with CPU constraints..."
./firecracker_setup.sh

echo "2. Checking if cgroups were created..."
ls -la /sys/fs/cgroup/ | grep -i fire || echo "No firecracker cgroups found"

echo "3. Testing single I/O operation..."
ssh -i "./ubuntu-24.04.id_rsa" -o StrictHostKeyChecking=no root@"$GUEST_IP" "
    echo 'Running quick I/O test inside VM...'
    cd /mnt/test_data || cd /tmp
    fio --name=test --rw=write --size=10M --bs=4k --runtime=5s --time_based --filename=test_file --direct=1 --sync=1
"

echo "4. Cleanup..."
./cleanup.sh

echo "Test completed!"
