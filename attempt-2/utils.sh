#!/bin/bash

# Utility functions for the IO Performance Comparison Framework
# Contains shared utility functions used across multiple components

# Source configuration
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

# Test selection and filtering
get_test_list() {
    local all_tests=("${!IO_PATTERNS[@]}")
    local selected_tests=()
    
    # Apply comprehensive test mode (run everything)
    if [ "$COMPREHENSIVE_TEST" = "true" ]; then
        echo "🚀 Comprehensive test mode enabled - running ALL 17 test patterns" >&2
        selected_tests=("${all_tests[@]}")
    # Apply quick test filter (select comprehensive but efficient subset)
    elif [ "$QUICK_TEST" = "true" ]; then
        echo "⚡ Quick test mode enabled - running comprehensive subset of tests" >&2
        for test in "${all_tests[@]}"; do
            # Include representative tests from each block size and operation type
            # This gives us good coverage across the matrix of block sizes and operations
            if [[ "$test" =~ (random_write_512b|random_read_512b|sequential_write_4k|random_read_4k|mixed_4k|sequential_write_64k|random_read_64k|mixed_64k|sequential_write_1m|random_read_1m|mixed_1m) ]]; then
                selected_tests+=("$test")
            fi
        done
    # Apply focused block size filter
    elif [ -n "$FOCUSED_BLOCK_SIZE" ]; then
        echo "🎯 Focused testing on block size: $FOCUSED_BLOCK_SIZE" >&2
        for test in "${all_tests[@]}"; do
            if [[ "$test" =~ "_${FOCUSED_BLOCK_SIZE}_" ]]; then
                selected_tests+=("$test")
            fi
        done
    else
        # Default: Run ALL tests (same as comprehensive mode)
        echo "📊 Default mode - running ALL 17 test patterns" >&2
        selected_tests=("${all_tests[@]}")
    fi
    
    printf '%s\n' "${selected_tests[@]}"
}

# Utility functions
get_host_interface() {
    ip -j route list default | jq -r '.[0].dev' 2>/dev/null || echo "eth0"
}

wait_for_connectivity() {
    local ip="$1"
    local timeout=30
    local count=0
    
    echo "Waiting for connectivity to $ip..."
    while [ $count -lt $timeout ]; do
        if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
            echo "Connectivity established"
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done
    
    echo "Failed to establish connectivity to $ip"
    return 1
}

# Check prerequisites
check_prerequisites() {
    echo "Checking prerequisites..."
    
    # Check for required commands
    local required_commands="curl jq docker fio e2fsck"
    for cmd in $required_commands; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: Required command '$cmd' not found"
            echo "Please install: $cmd"
            exit 1
        fi
    done
    
    # Check for firecracker binary
    if [ ! -f "../firecracker" ]; then
        echo "Error: Firecracker binary not found"
        echo "Expected: ../firecracker"
        exit 1
    fi
    
    # Check for kernel
    if [ ! -f "../vmlinux-6.1.128" ]; then
        echo "Error: Kernel not found"
        echo "Expected: ../vmlinux-6.1.128"
        exit 1
    fi
    
    # Check for rootfs
    if [ ! -f "../ubuntu-24.04.ext4" ]; then
        echo "Error: Root filesystem not found"
        echo "Expected: ../ubuntu-24.04.ext4"
        exit 1
    fi
    
    # Check for SSH key
    if [ ! -f "../ubuntu-24.04.id_rsa" ]; then
        echo "Error: SSH key not found"
        echo "Expected: ../ubuntu-24.04.id_rsa"
        exit 1
    fi
    
    echo "Prerequisites check passed"
}

# Performance monitoring
monitor_system_metrics() {
    local test_name="$1"
    local duration="$2"
    local output_prefix="$3"
    
    echo "  Starting monitoring for ${output_prefix} (${duration}s)"
    
    # CPU monitoring (run in background, don't wait)
    mpstat -P ALL 1 "$duration" > "${RESULTS_DIR}/${output_prefix}_cpu.log" &
    local cpu_pid=$!
    
    echo "$cpu_pid"
}

stop_monitoring() {
    local pids="$1"
    echo "  Stopping monitoring (PIDs: $pids)"
    for pid in $pids; do
        kill "$pid" 2>/dev/null || true
    done
    # Don't wait for processes to finish, let them complete in background
}
