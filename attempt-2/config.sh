#!/bin/bash

# Configuration file for IO Performance Comparison Framework
# This file contains all configuration variables and test patterns

# Test configuration (use existing values if already set)
TEST_DURATION=${TEST_DURATION:-30}
DATA_SIZE_MB=${DATA_SIZE_MB:-500}
ITERATIONS=${ITERATIONS:-3}  # Reduced to 3 for faster comprehensive testing
RESULTS_DIR="./io_benchmark_results_$(date +%Y%m%d_%H%M%S)"

# Test mode selection
QUICK_TEST=${QUICK_TEST:-false}  # Set to true to run subset of tests for faster validation
COMPREHENSIVE_TEST=${COMPREHENSIVE_TEST:-false}  # Set to true to run ALL tests (17 patterns)
FOCUSED_BLOCK_SIZE=${FOCUSED_BLOCK_SIZE:-""}  # Set to "4k", "64k", "1m", etc. to test only specific block size

# Network configuration
TAP_DEV="tap1"  # Using tap1 to avoid conflicts with existing setup
TAP_IP="172.17.0.1"
GUEST_IP="172.17.0.2"
MASK_SHORT="/30"
FC_MAC="06:00:AC:11:00:02"

# Firecracker configuration
API_SOCKET="/tmp/firecracker-io-test.socket"
LOGFILE="./firecracker-io-test.log"

# Shared storage for fair comparison
LOOP_DEVICE=""

# Test patterns configuration with multiple block sizes and IO sizes (using smaller files to fit in VM space)
if [ ${#IO_PATTERNS[@]} -eq 0 ]; then
    declare -A IO_PATTERNS=(
        # Small block size tests (4K) - typical for database/transactional workloads
        ["random_write_4k"]="fio --name=random_write_4k --rw=randwrite --size=8M --bs=4k --numjobs=1 --runtime=10s --time_based --group_reporting --filename=rand_4k_file --fsync=1 --direct=1"
        ["random_read_4k"]="fio --name=random_read_4k --rw=randread --size=8M --bs=4k --numjobs=1 --runtime=10s --time_based --group_reporting --filename=rand_4k_file --direct=1"
        ["sequential_write_4k"]="fio --name=seq_write_4k --rw=write --size=8M --bs=4k --numjobs=1 --runtime=10s --time_based --group_reporting --filename=seq_4k_file --fsync=1 --direct=1"
        ["sequential_read_4k"]="fio --name=seq_read_4k --rw=read --size=8M --bs=4k --numjobs=1 --runtime=10s --time_based --group_reporting --filename=seq_4k_file --direct=1"
        
        # Medium block size tests (64K) - typical for streaming/multimedia workloads  
        ["random_write_64k"]="fio --name=random_write_64k --rw=randwrite --size=10M --bs=64k --numjobs=1 --runtime=10s --time_based --group_reporting --filename=rand_64k_file --fsync=1 --direct=1"
        ["random_read_64k"]="fio --name=random_read_64k --rw=randread --size=10M --bs=64k --numjobs=1 --runtime=10s --time_based --group_reporting --filename=rand_64k_file --direct=1"
        ["sequential_write_64k"]="fio --name=seq_write_64k --rw=write --size=10M --bs=64k --numjobs=1 --runtime=10s --time_based --group_reporting --filename=seq_64k_file --fsync=1 --direct=1"
        ["sequential_read_64k"]="fio --name=seq_read_64k --rw=read --size=10M --bs=64k --numjobs=1 --runtime=10s --time_based --group_reporting --filename=seq_64k_file --direct=1"
        
        # Large block size tests (1M) - typical for backup/bulk transfer workloads
        ["random_write_1m"]="fio --name=random_write_1m --rw=randwrite --size=12M --bs=1M --numjobs=1 --runtime=10s --time_based --group_reporting --filename=rand_1m_file --fsync=1 --direct=1"
        ["random_read_1m"]="fio --name=random_read_1m --rw=randread --size=12M --bs=1M --numjobs=1 --runtime=10s --time_based --group_reporting --filename=rand_1m_file --direct=1"
        ["sequential_write_1m"]="fio --name=seq_write_1m --rw=write --size=12M --bs=1M --numjobs=1 --runtime=10s --time_based --group_reporting --filename=seq_1m_file --fsync=1 --direct=1"
        ["sequential_read_1m"]="fio --name=seq_read_1m --rw=read --size=12M --bs=1M --numjobs=1 --runtime=10s --time_based --group_reporting --filename=seq_1m_file --direct=1"
        
        # Mixed workload tests at different scales
        ["mixed_4k"]="fio --name=mixed_4k --rw=randrw --rwmixread=70 --size=8M --bs=4k --numjobs=1 --runtime=10s --time_based --group_reporting --filename=mixed_4k_file --fsync=1 --direct=1"
        ["mixed_64k"]="fio --name=mixed_64k --rw=randrw --rwmixread=70 --size=10M --bs=64k --numjobs=1 --runtime=10s --time_based --group_reporting --filename=mixed_64k_file --fsync=1 --direct=1"
        ["mixed_1m"]="fio --name=mixed_1m --rw=randrw --rwmixread=70 --size=12M --bs=1M --numjobs=1 --runtime=10s --time_based --group_reporting --filename=mixed_1m_file --fsync=1 --direct=1"
        
        # Ultra-small block size test (512 bytes) - edge case for very granular I/O
        ["random_write_512b"]="fio --name=random_write_512b --rw=randwrite --size=8M --bs=512 --numjobs=1 --runtime=10s --time_based --group_reporting --filename=rand_512b_file --fsync=1 --direct=1"
        ["random_read_512b"]="fio --name=random_read_512b --rw=randread --size=8M --bs=512 --numjobs=1 --runtime=10s --time_based --group_reporting --filename=rand_512b_file --direct=1"
    )
fi
