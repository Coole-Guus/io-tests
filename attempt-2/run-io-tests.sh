#!/bin/bash

# Quick Test Runner for Comprehensive IO Benchmarking
# This script demonstrates different ways to run the expanded test suite

echo "🚀 Comprehensive IO Performance Test Runner"
echo "============================================="
echo ""

# Check if the main script exists
if [ ! -f "./io-comparison-framework.sh" ]; then
    echo "❌ Error: io-comparison-framework.sh not found in current directory"
    exit 1
fi

# Make sure it's executable
chmod +x ./io-comparison-framework.sh

echo "Available test modes:"
echo ""
echo "1. 🔥 Quick Test (4 representative tests - ~15 minutes)"
echo "   Tests one operation from each block size category"
echo ""  
echo "2. 🎯 Focused Block Size Testing"
echo "   a) 4KB blocks only (5 tests - database/transactional workloads)"
echo "   b) 64KB blocks only (5 tests - streaming/multimedia workloads)" 
echo "   c) 1MB blocks only (5 tests - backup/bulk transfer workloads)"
echo ""
echo "3. 📊 Full Comprehensive Test (18 tests - ~60+ minutes)"
echo "   All block sizes, all operations, complete analysis"
echo ""
echo "4. 🧪 Custom Test"
echo "   Set your own parameters"
echo ""

read -p "Select test mode (1-4): " choice

case $choice in
    1)
        echo ""
        echo "🔥 Starting Quick Test Mode..."
        echo "Selected tests: random_write_4k, random_read_64k, sequential_write_1m, mixed_4k"
        export QUICK_TEST=true
        export ITERATIONS=3
        ./io-comparison-framework.sh
        ;;
    2)
        echo ""
        echo "Select block size focus:"
        echo "a) 4KB blocks (database/OLTP workloads)"
        echo "b) 64KB blocks (streaming/multimedia)"
        echo "c) 1MB blocks (backup/bulk transfer)"
        read -p "Choice (a/b/c): " block_choice
        
        case $block_choice in
            a|A)
                echo "🎯 Testing 4KB block operations..."
                export FOCUSED_BLOCK_SIZE="4k"
                ;;
            b|B)  
                echo "🎯 Testing 64KB block operations..."
                export FOCUSED_BLOCK_SIZE="64k"
                ;;
            c|C)
                echo "🎯 Testing 1MB block operations..."
                export FOCUSED_BLOCK_SIZE="1m"
                ;;
            *)
                echo "Invalid choice, defaulting to 4KB"
                export FOCUSED_BLOCK_SIZE="4k"
                ;;
        esac
        export ITERATIONS=3
        ./io-comparison-framework.sh
        ;;
    3)
        echo ""
        echo "📊 Starting Full Comprehensive Test..."
        echo "⚠️  This will run 18 different test patterns and may take 60+ minutes"
        read -p "Continue? (y/N): " confirm
        if [[ $confirm =~ ^[Yy]$ ]]; then
            export QUICK_TEST=false
            export FOCUSED_BLOCK_SIZE=""
            export ITERATIONS=3
            ./io-comparison-framework.sh
        else
            echo "Test cancelled"
        fi
        ;;
    4)
        echo ""
        echo "🧪 Custom Test Configuration"
        echo "Current defaults:"
        echo "  - Iterations per test: 3"
        echo "  - Test duration: 10s per iteration"
        echo ""
        
        read -p "Set iterations per test (default 3): " custom_iterations
        read -p "Enable quick test mode? (y/N): " quick_mode
        read -p "Focus on specific block size (4k/64k/1m or leave empty): " block_focus
        
        export ITERATIONS=${custom_iterations:-3}
        
        if [[ $quick_mode =~ ^[Yy]$ ]]; then
            export QUICK_TEST=true
        else
            export QUICK_TEST=false
        fi
        
        if [ -n "$block_focus" ]; then
            export FOCUSED_BLOCK_SIZE="$block_focus"
        else
            export FOCUSED_BLOCK_SIZE=""
        fi
        
        echo "Running with custom settings..."
        ./io-comparison-framework.sh
        ;;
    *)
        echo "Invalid selection. Exiting."
        exit 1
        ;;
esac

echo ""
echo "🎉 Test execution complete!"
echo ""
echo "💡 Tip: Check the generated results directory for:"
echo "   • CSV files with raw performance data"
echo "   • CPU utilization logs" 
echo "   • Comprehensive analysis with recommendations"
echo ""
echo "🔍 The analysis includes:"
echo "   • Block size performance comparisons"
echo "   • Operation type analysis (sequential/random/mixed)"
echo "   • Performance improvement percentages"  
echo "   • Recommendations for optimal Firecracker use cases"
