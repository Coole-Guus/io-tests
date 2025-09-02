#!/bin/bash

# Diagnostic script to analyze why container IO performance is lower than VM
# This helps identify bottlenecks and configuration issues

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

echo "=== IO Performance Diagnostic ==="
echo "Configuration:"
echo "  VCPU_COUNT: $VCPU_COUNT"
echo "  MEMORY_SIZE_MIB: $MEMORY_SIZE_MIB"
echo "  DISK_SIZE_MB: $DISK_SIZE_MB"
echo ""

echo "=== Host System Information ==="
echo "CPU Info:"
lscpu | grep -E "(Model name|CPU\(s\)|Thread|Core)"
echo ""

echo "Memory Info:"
free -h
echo ""

echo "Storage Info:"
df -h / | head -2
echo ""

echo "Docker Info:"
docker info | grep -E "(Storage Driver|Backing Filesystem|Kernel Version)" | head -3
echo ""

echo "=== Performance Comparison Test ==="

# Test host filesystem performance first
echo "Testing host filesystem performance..."
cd /tmp
fio --name=host_test --rw=write --size=10M --bs=64k --numjobs=1 --runtime=5s --time_based --group_reporting --filename=host_test_file --direct=1 --fsync=1 2>/dev/null | grep -E "(write.*MB/s|lat.*usec)"
rm -f host_test_file

echo ""
echo "Testing Docker container performance..."

# Setup container for testing
echo "Setting up test container..."
docker stop io_perf_test 2>/dev/null || true
docker rm io_perf_test 2>/dev/null || true
docker volume rm io_perf_volume 2>/dev/null || true
docker volume create io_perf_volume >/dev/null

# Test with overlay2 (default)
echo "Test 1: Container with overlay2 filesystem"
docker run --rm \
    --cpus="$VCPU_COUNT.0" \
    --memory="${MEMORY_SIZE_MIB}m" \
    ubuntu:20.04 \
    /bin/bash -c "
        apt-get update -qq && apt-get install -y fio >/dev/null 2>&1
        mkdir -p /root/test_data && cd /root/test_data
        fio --name=container_overlay_test --rw=write --size=10M --bs=64k --numjobs=1 --runtime=5s --time_based --group_reporting --filename=test_file --direct=1 --fsync=1 2>/dev/null
    " | grep -E "(write.*MB/s|lat.*usec)"

echo ""
echo "Test 2: Container with dedicated volume"
docker run --rm \
    --cpus="$VCPU_COUNT.0" \
    --memory="${MEMORY_SIZE_MIB}m" \
    --mount source=io_perf_volume,target=/mnt/test_data \
    ubuntu:20.04 \
    /bin/bash -c "
        apt-get update -qq && apt-get install -y fio >/dev/null 2>&1
        cd /mnt/test_data
        fio --name=container_volume_test --rw=write --size=10M --bs=64k --numjobs=1 --runtime=5s --time_based --group_reporting --filename=test_file --direct=1 --fsync=1 2>/dev/null
    " | grep -E "(write.*MB/s|lat.*usec)"

echo ""
echo "Test 3: Container with tmpfs (memory-based)"
docker run --rm \
    --cpus="$VCPU_COUNT.0" \
    --memory="${MEMORY_SIZE_MIB}m" \
    --tmpfs /mnt/test_data:rw,noexec,nosuid,size=100m \
    ubuntu:20.04 \
    /bin/bash -c "
        apt-get update -qq && apt-get install -y fio >/dev/null 2>&1
        cd /mnt/test_data
        fio --name=container_tmpfs_test --rw=write --size=10M --bs=64k --numjobs=1 --runtime=5s --time_based --group_reporting --filename=test_file --fsync=1 2>/dev/null
    " | grep -E "(write.*MB/s|lat.*usec)"

# Cleanup
docker volume rm io_perf_volume 2>/dev/null || true

echo ""
echo "=== Analysis ==="
echo "If you see significant performance differences:"
echo "1. Host performance = baseline reference"
echo "2. Container overlay2 = typically 10-30% slower due to filesystem layers"
echo "3. Container volume = should be closer to host performance"
echo "4. Container tmpfs = should be fastest (memory-based)"
echo ""
echo "Expected results for your configuration:"
echo "- VM performance: Using direct ext4 access on dedicated disk"
echo "- Container performance: Should be similar with volume mount"
echo ""
echo "If container is still much slower, consider:"
echo "- Docker storage driver optimization"
echo "- Host filesystem type (ext4 vs others)"
echo "- Hardware-specific limitations"
echo "- Container resource limits"
