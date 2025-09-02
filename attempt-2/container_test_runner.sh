#!/bin/bash

# Container IO test runner for the IO Performance Comparison Framework
# Handles execution of IO tests in Docker containers

# Source configuration and modules
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/metrics_parser.sh"

# Container IO testing
run_container_io_test() {
    local test_name="$1"
    local io_command="$2"
    local output_file="$3"
    
    echo "Running container IO test: $test_name"
    echo "timestamp,operation,latency_us,throughput_mbps,cpu_usage" > "$output_file"
    
    for i in $(seq 1 $ITERATIONS); do
        echo "  Container test $i/$ITERATIONS..."
        
        # Check if container is still running
        if ! docker ps --filter "name=io_test_container" --filter "status=running" | grep -q io_test_container; then
            echo "  Container stopped unexpectedly, restarting..."
            source "$(dirname "${BASH_SOURCE[0]}")/container_setup.sh"
            setup_container
            sleep 2
        fi
        
        # Execute IO operation and extract fio metrics - use root filesystem instead of loop device
        # Clean up previous test files first
        docker exec io_test_container /bin/bash -c "
            cd /root/test_data 2>/dev/null || mkdir -p /root/test_data
            # Remove all test files
            rm -rf test_seq *.fio fio_test_file random_* mixed* testfile* seq_test_file rand_test_file mixed_test_file *_4k_* *_64k_* *_1m_* *_512b_* *.file 2>/dev/null || true
            sync
        " >/dev/null 2>&1 || true
        
        # Execute the actual test
        result=$(docker exec io_test_container /bin/bash -c "cd /root/test_data && $io_command" 2>&1)
        
        # Clean up the test file immediately after the test
        docker exec io_test_container /bin/bash -c "cd /root/test_data && rm -f *_4k_* *_64k_* *_1m_* *_512b_* *.file 2>/dev/null && sync" >/dev/null 2>&1 || true
        
        # Debug: show first few lines of fio output
        echo "    Debug: fio output preview:"
        echo "$result" | head -n 10 | sed 's/^/      /'
        
        # Extract metrics from fio output
        latency_us="0"
        throughput_mb="0"
        iops="0"
        
        if [[ "$result" == "timeout_or_error" ]] || echo "$result" | grep -q "docker:.*not found\|Error response from daemon"; then
            echo "    Error: Container execution failed"
            echo "    Skipping this iteration"
            latency_us="0"
            throughput_mb="0"
        elif [[ "$result" != "timeout_or_error" ]] && echo "$result" | grep -q "Run status"; then
            # Use metrics parser functions
            latency_us=$(parse_latency "$result")
            throughput_mb=$(parse_throughput "$result")
            
            # Extract IOPS from the main line
            # Format: "write: IOPS=13.5k, BW=52.6MiB/s"
            if echo "$result" | grep -q "IOPS="; then
                iops_raw=$(echo "$result" | grep "IOPS=" | sed -n 's/.*IOPS=\([0-9.k]*\).*/\1/p')
                # Convert k notation (e.g., "13.5k" -> "13500")
                if echo "$iops_raw" | grep -q "k"; then
                    iops_num=$(echo "$iops_raw" | sed 's/k//')
                    if [[ "$iops_num" =~ ^[0-9.]+$ ]]; then
                        iops=$(echo "$iops_num * 1000" | bc -l | cut -d. -f1)
                    fi
                elif [[ "$iops_raw" =~ ^[0-9.]+$ ]]; then
                    iops="$iops_raw"
                fi
            fi
        elif echo "$result" | grep -q "copied"; then
            # Handle dd output format (keeping for backwards compatibility)
            # Format: "104857600 bytes (105 MB, 100 MiB) copied, 0.280155 s, 374 MB/s"
            if echo "$result" | grep -oE '[0-9.]+ [GM]B/s'; then
                dd_throughput=$(echo "$result" | grep -oE '[0-9.]+ [GM]B/s' | tail -1)
                if echo "$dd_throughput" | grep -q "GB/s"; then
                    throughput_gb=$(echo "$dd_throughput" | sed 's/ GB\/s//')
                    if [[ "$throughput_gb" =~ ^[0-9.]+$ ]]; then
                        throughput_mb=$(echo "$throughput_gb * 1000" | bc -l | xargs printf "%.2f")
                    fi
                elif echo "$dd_throughput" | grep -q "MB/s"; then
                    throughput_mb=$(echo "$dd_throughput" | sed 's/ MB\/s//')
                fi
            fi
            
            # For dd, we don't have latency info, so leave it as 0
            latency_us="0"
        else
            echo "    Warning: IO command produced unexpected output format"
            echo "    Output preview: $(echo "$result" | head -n 2 | tr '\n' ' ')"
        fi
        
        # Get CPU usage (with error handling)
        cpu_usage=$(docker exec io_test_container cat /host_proc/loadavg 2>/dev/null | awk '{print $1}' || echo "0")
        
        timestamp=$(date '+%Y-%m-%d %H:%M:%S.%3N')
        echo "$timestamp,$test_name,$latency_us,$throughput_mb,$cpu_usage" >> "$output_file"
        
        if [[ "$throughput_mb" != "0" ]]; then
            echo "    Latency: ${latency_us}μs, Throughput: ${throughput_mb} MB/s"
        else
            echo "    Latency: ${latency_us}μs, No throughput data"
        fi
        
        sleep 2
    done
    
    echo "Container IO test completed for $test_name"
}
