#!/bin/bash

# Test single benchmark
# This script runs a single benchmark test to verify the complete pipeline

# Get script directory
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"

# Source all modules
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/utils.sh"
source "$SCRIPT_DIR/cleanup.sh"
source "$SCRIPT_DIR/network_setup.sh"
source "$SCRIPT_DIR/firecracker_setup.sh"
source "$SCRIPT_DIR/container_setup.sh"
source "$SCRIPT_DIR/container_test_runner.sh"
source "$SCRIPT_DIR/firecracker_test_runner.sh"
source "$SCRIPT_DIR/analysis.sh"

echo "=== TESTING SINGLE BENCHMARK ==="
echo "Running a single test to verify the complete pipeline..."

# Override config for a quick test
ITERATIONS=1
export ITERATIONS

# Choose a simple, fast test
TEST_NAME="sequential_write_4k"
TEST_COMMAND="${IO_PATTERNS[$TEST_NAME]}"

echo "Test: $TEST_NAME"
echo "Command: $TEST_COMMAND"
echo "Iterations: $ITERATIONS"
echo ""

# Create a temporary results directory
RESULTS_DIR="./test_benchmark_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"
echo "Results directory: $RESULTS_DIR"

# Setup environment
echo "Setting up environment..."
setup_network
setup_firecracker_vm
setup_container

echo ""
echo "=== RUNNING CONTAINER TEST ==="
run_container_io_test "$TEST_NAME" "$TEST_COMMAND" "${RESULTS_DIR}/container_${TEST_NAME}.csv"

echo ""
echo "=== RUNNING FIRECRACKER TEST ==="
run_firecracker_io_test "$TEST_NAME" "$TEST_COMMAND" "${RESULTS_DIR}/firecracker_${TEST_NAME}.csv"

echo ""
echo "=== ANALYZING RESULTS ==="
analyze_results

echo ""
echo "=== VERIFYING OUTPUT FILES ==="
if [ -f "${RESULTS_DIR}/container_${TEST_NAME}.csv" ]; then
    echo "Container results file created"
    echo "Container results:"
    cat "${RESULTS_DIR}/container_${TEST_NAME}.csv"
else
    echo "Container results file missing"
fi

echo ""
if [ -f "${RESULTS_DIR}/firecracker_${TEST_NAME}.csv" ]; then
    echo "Firecracker results file created"
    echo "Firecracker results:"
    cat "${RESULTS_DIR}/firecracker_${TEST_NAME}.csv"
else
    echo "Firecracker results file missing"
fi

echo ""
if [ -f "${RESULTS_DIR}/analyze_results.py" ]; then
    echo "Analysis script created"
else
    echo "Analysis script missing"
fi

echo ""
echo "Single benchmark test completed!"
echo "Results saved in: $RESULTS_DIR"
echo "Note: Cleanup will be performed automatically on script exit"
