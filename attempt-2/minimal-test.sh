#!/bin/bash

# Minimal test script for debugging

# Override test parameters for very quick test
TEST_DURATION=5
ITERATIONS=2

# Test only one pattern
declare -A IO_PATTERNS=(
    ["sequential_write"]="dd if=/dev/zero of=/tmp/test_seq bs=1M count=10 oflag=direct 2>&1"
)

# Source the main framework script
source ./io-comparison-framework.sh
