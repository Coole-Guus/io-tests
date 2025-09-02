#!/bin/bash

# Main orchestrator for the IO Performance Comparison Framework
# Coordinates all components to run comprehensive IO performance tests

set -e

# Get script directory for relative sourcing
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

# Main execution
main() {
    echo "=== COMPREHENSIVE IO PERFORMANCE COMPARISON FRAMEWORK ==="
    echo "🔬 Testing Multiple Block Sizes: 512B, 4KB, 64KB, 1MB"
    echo "🎯 Testing Multiple Operations: Sequential/Random Read/Write, Mixed Workloads"
    echo "📊 Data Sizes: 8MB (512B, 4K blocks), 10MB (64K blocks), 12MB (1M blocks)"
    echo "⚡ Total Tests: ${#IO_PATTERNS[@]} test patterns across both environments"
    echo "📁 Results will be saved to: $RESULTS_DIR"
    echo ""
    
    # Show test breakdown
    echo "📋 Test Matrix:"
    echo "   • Ultra-small (512B blocks): 2 tests - random read/write on 8MB files"
    echo "   • Small blocks (4KB): 4 tests - sequential/random operations on 8MB files" 
    echo "   • Medium blocks (64KB): 4 tests - sequential/random operations on 10MB files"
    echo "   • Large blocks (1MB): 4 tests - sequential/random operations on 12MB files"
    echo "   • Mixed workloads: 3 tests - randrw operations at different scales"
    echo "   • Total runtime estimate: ~$((${#IO_PATTERNS[@]} * 2 * $ITERATIONS * 12 / 60)) minutes"
    echo ""
    
    # Check prerequisites
    check_prerequisites
    
    # Setup components
    echo "🚀 Setting up test environment..."
    setup_network
    setup_firecracker_vm
    setup_container
    
    echo "🚀 Starting comprehensive IO tests across multiple block sizes..."
    
    # Get selected test list
    readarray -t selected_tests < <(get_test_list)
    local total_tests=${#selected_tests[@]}
    
    if [ $total_tests -eq 0 ]; then
        echo "❌ No tests selected based on current filters"
        exit 1
    fi
    
    echo "📝 Selected tests: $total_tests/${#IO_PATTERNS[@]} total patterns"
    
    # Run tests for each selected pattern
    local test_count=0
    
    for pattern_name in "${selected_tests[@]}"; do
        test_count=$((test_count + 1))
        echo ""
        echo "🧪 [$test_count/$total_tests] Testing IO Pattern: $pattern_name"
        echo "=============================================================="
        
        command="${IO_PATTERNS[$pattern_name]}"
        
        # Test container performance
        echo "📦 Testing container performance..."
        monitor_pids=$(monitor_system_metrics "$pattern_name" $((ITERATIONS * 3)) "container_${pattern_name}")
        run_container_io_test "$pattern_name" "$command" "${RESULTS_DIR}/container_${pattern_name}.csv"
        stop_monitoring "$monitor_pids"
        
        echo "   Container testing complete, waiting 5s..."
        sleep 5
        
        # Test Firecracker performance
        echo "🔥 Testing Firecracker performance..."
        monitor_pids=$(monitor_system_metrics "$pattern_name" $((ITERATIONS * 3)) "firecracker_${pattern_name}")
        run_firecracker_io_test "$pattern_name" "$command" "${RESULTS_DIR}/firecracker_${pattern_name}.csv"
        stop_monitoring "$monitor_pids"
        
        echo "   Firecracker testing complete, waiting 5s..."
        sleep 5
        
        # Progress update
        local remaining=$((total_tests - test_count))
        if [ $remaining -gt 0 ]; then
            echo "   ⏳ $remaining tests remaining..."
        fi
    done
    
    # Analysis
    echo ""
    echo "📊 Generating comprehensive performance analysis..."
    analyze_results
    
    echo ""
    echo "🎉 COMPREHENSIVE EXPERIMENT COMPLETE!"
    echo "==============================================="
    echo "📁 All results saved to: $RESULTS_DIR"
    echo ""
    echo "📄 Generated Files:"
    echo "   • ${#IO_PATTERNS[@]} container_*.csv files - Container performance data"
    echo "   • ${#IO_PATTERNS[@]} firecracker_*.csv files - Firecracker performance data"
    echo "   • Multiple *_cpu.log files - CPU utilization during tests"
    echo "   • analyze_results.py - Advanced analysis script"
    echo "   • firecracker-io-test.log - VM execution logs"
    echo ""
    echo "🔍 Key Analysis Features:"
    echo "   • Block size performance comparison (512B → 1MB)"
    echo "   • Operation type analysis (Sequential/Random/Mixed)"
    echo "   • Performance improvement percentages"
    echo "   • Recommendations for optimal use cases"
}

# Execute main function
main "$@"
