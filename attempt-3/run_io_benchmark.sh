#!/bin/bash

# Main orchestrator for IO tests
# Coordinates all components

# Don't exit on error
set +e

# Script directory
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"

# Source modules
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/utils.sh"
source "$SCRIPT_DIR/cleanup.sh"
source "$SCRIPT_DIR/network_setup.sh"
source "$SCRIPT_DIR/firecracker_setup.sh"
source "$SCRIPT_DIR/container_setup.sh"
source "$SCRIPT_DIR/container_test_runner.sh"
source "$SCRIPT_DIR/firecracker_test_runner.sh"
source "$SCRIPT_DIR/analysis.sh"

# Main function
main() {
    # Get test list
    readarray -t selected_tests < <(get_test_list)
    local total_tests=${#selected_tests[@]}
    
    echo "=== IO PERFORMANCE TESTS ==="
    echo "Blocks: 512B, 4KB, 64KB, 1MB"
    echo "Ops: Sequential/Random Read/Write, Mixed"
    echo "Sizes: 8MB (512B,4K), 10MB (64K), 12MB (1M)"
    echo "Tests: $total_tests patterns"
    echo "Results: $RESULTS_DIR"
    echo ""
    
    echo "Test Matrix:"
    echo "   512B: 2 tests - rand r/w on 8MB"
    echo "   4KB: 4 tests - seq/rand ops on 8MB" 
    echo "   64KB: 4 tests - seq/rand ops on 10MB"
    echo "   1MB: 4 tests - seq/rand ops on 12MB"
    echo "   Mixed: 3 tests - randrw ops"
    echo "   Runtime: ~$(($total_tests * 2 * $ITERATIONS * 12 / 60))m"
    echo ""
    
    check_prerequisites
    
    # Setup
    echo "Setting up environment..."
    setup_network
    setup_firecracker_vm
    setup_container
    
    # Storage backend info
    echo ""
    echo "Storage Backend:"
    echo "Both use raw block devices + ext4"
    echo "Firecracker: /dev/vdb → /mnt/test_data"
    echo "Docker: /dev/test_disk → /mnt/test_data"
    echo "Same filesystem + mount options"
    echo "Direct I/O flags removed"
    echo ""
    
    echo "Starting IO tests..."
    
    if [ $total_tests -eq 0 ]; then
        echo "No tests selected"
        exit 1
    fi
    
    echo "Selected: $total_tests/${#IO_PATTERNS[@]} patterns"
    
    # Run tests
    local test_count=0
    
    for pattern_name in "${selected_tests[@]}"; do
        test_count=$((test_count + 1))
        echo ""
        echo "[$test_count/$total_tests] Pattern: $pattern_name"
        echo "=============================="
        
        command="${IO_PATTERNS[$pattern_name]}"
        
        # Test Firecracker
        echo "Testing Firecracker..."
        monitor_pids=$(monitor_system_metrics "$pattern_name" $((ITERATIONS * 3)) "firecracker_${pattern_name}")
        run_firecracker_io_test "$pattern_name" "$command" "${RESULTS_DIR}/firecracker_${pattern_name}.csv"
        stop_monitoring "$monitor_pids"
        
        echo "   Firecracker done, wait 5s..."
        sleep 5

        # Test container
        echo "Testing container..."
        monitor_pids=$(monitor_system_metrics "$pattern_name" $((ITERATIONS * 3)) "container_${pattern_name}")
        run_container_io_test "$pattern_name" "$command" "${RESULTS_DIR}/container_${pattern_name}.csv"
        stop_monitoring "$monitor_pids"
        
        echo "   Container done, wait 5s..."
        sleep 5
        
        # Progress
        local remaining=$((total_tests - test_count))
        if [ $remaining -gt 0 ]; then
            echo "   $remaining remaining..."
        fi
    done
    
    # Analysis
    echo ""
    echo "Generating analysis..."
    analyze_results
    
    echo ""
    echo "TESTS COMPLETE!"
    echo "==============="
    echo "Results: $RESULTS_DIR"
    echo ""
    echo "Files:"
    echo "   ${#IO_PATTERNS[@]} container_*.csv"
    echo "   ${#IO_PATTERNS[@]} firecracker_*.csv"
    echo "   *_cpu.log - CPU utilization"
    echo "   analyze_results.py - Analysis script"
    echo "   firecracker-io-test.log - VM logs"
    echo ""
    echo "Analysis:"
    echo "   Block size comparison (512B → 1MB)"
    echo "   Op type analysis (Seq/Rand/Mixed)"
    echo "   Performance percentages"
    echo "   Use case recommendations"
}

# Execute main
main "$@"
