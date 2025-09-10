#!/bin/bash

# Test prerequisites and configuration
# This script tests if all required dependencies and files are available

# Get script directory
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"

# Source configuration and utils
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/utils.sh"

echo "=== TESTING PREREQUISITES ==="
echo "Checking if all required components are available..."

# Run the prerequisite check
check_prerequisites

echo ""
echo "=== TESTING CONFIGURATION ==="
echo "Configuration variables:"
echo "  TEST_DURATION: $TEST_DURATION"
echo "  DATA_SIZE_MB: $DATA_SIZE_MB"  
echo "  ITERATIONS: $ITERATIONS"
echo "  RESULTS_DIR: $RESULTS_DIR"
echo "  QUICK_TEST: $QUICK_TEST"
echo "  COMPREHENSIVE_TEST: $COMPREHENSIVE_TEST"
echo "  FOCUSED_BLOCK_SIZE: $FOCUSED_BLOCK_SIZE"

echo ""
echo "Network configuration:"
echo "  TAP_DEV: $TAP_DEV"
echo "  TAP_IP: $TAP_IP"
echo "  GUEST_IP: $GUEST_IP"
echo "  MASK_SHORT: $MASK_SHORT"
echo "  FC_MAC: $FC_MAC"

echo ""
echo "Firecracker configuration:"
echo "  API_SOCKET: $API_SOCKET"
echo "  LOGFILE: $LOGFILE"

echo ""
echo "=== TESTING IO PATTERNS ==="
echo "Available IO patterns: ${#IO_PATTERNS[@]}"
for pattern in "${!IO_PATTERNS[@]}"; do
    echo "  $pattern: ${IO_PATTERNS[$pattern]}"
done

echo ""
echo "=== TESTING TEST SELECTION ==="
echo "Selected tests with current configuration:"
readarray -t selected_tests < <(get_test_list)
echo "Total selected: ${#selected_tests[@]}"
for test in "${selected_tests[@]}"; do
    echo "  $test"
done

echo ""
echo "Prerequisites test completed successfully!"
