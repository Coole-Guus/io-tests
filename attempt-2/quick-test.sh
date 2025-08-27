#!/bin/bash

# Quick test version of IO comparison framework  
# Runs with reduced iterations for faster testing

# We need to override these BEFORE sourcing the main script
export TEST_DURATION=10
export ITERATIONS=3

# Override IO patterns for quick test (only one pattern)
declare -A IO_PATTERNS=(
    ["sequential_write"]="dd if=/dev/zero of=/tmp/test_seq bs=1M count=10 oflag=direct 2>&1"
)

# Source the main framework script
source ./io-comparison-framework.sh
