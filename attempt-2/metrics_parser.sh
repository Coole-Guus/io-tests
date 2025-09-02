#!/bin/bash

# Metrics parsing functions for the IO Performance Comparison Framework
# Handles extraction and parsing of performance metrics from fio output

# Source configuration
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

# Parse latency from fio output
parse_latency() {
    local fio_output="$1"
    local latency_us="0"
    
    # Check if this is a mixed workload (has both read and write operations)
    if echo "$fio_output" | grep -q "read.*:" && echo "$fio_output" | grep -q "write.*:"; then
        # Mixed workload - extract both read and write latencies
        echo "    Debug: Mixed workload detected, extracting separate read/write latencies" >&2
        
        read_lat=""
        write_lat=""
        
        # Extract read latency
        if echo "$fio_output" | grep -A 10 "read.*:" | grep -q "clat (nsec)"; then
            read_lat=$(echo "$fio_output" | grep -A 10 "read.*:" | grep "clat (nsec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p' | head -1)
            if [[ "$read_lat" =~ ^[0-9.]+$ ]]; then
                read_lat=$(echo "$read_lat / 1000" | bc -l)
            fi
        elif echo "$fio_output" | grep -A 10 "read.*:" | grep -q "clat (usec)"; then
            read_lat=$(echo "$fio_output" | grep -A 10 "read.*:" | grep "clat (usec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p' | head -1)
        elif echo "$fio_output" | grep -A 10 "read.*:" | grep -q "clat (msec)"; then
            read_lat_msec=$(echo "$fio_output" | grep -A 10 "read.*:" | grep "clat (msec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p' | head -1)
            if [[ "$read_lat_msec" =~ ^[0-9.]+$ ]]; then
                read_lat=$(echo "$read_lat_msec * 1000" | bc -l)
            fi
        fi
        
        # Extract write latency
        if echo "$fio_output" | grep -A 10 "write.*:" | grep -q "clat (nsec)"; then
            write_lat=$(echo "$fio_output" | grep -A 10 "write.*:" | grep "clat (nsec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p' | head -1)
            if [[ "$write_lat" =~ ^[0-9.]+$ ]]; then
                write_lat=$(echo "$write_lat / 1000" | bc -l)
            fi
        elif echo "$fio_output" | grep -A 10 "write.*:" | grep -q "clat (usec)"; then
            write_lat=$(echo "$fio_output" | grep -A 10 "write.*:" | grep "clat (usec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p' | head -1)
        elif echo "$fio_output" | grep -A 10 "write.*:" | grep -q "clat (msec)"; then
            write_lat_msec=$(echo "$fio_output" | grep -A 10 "write.*:" | grep "clat (msec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p' | head -1)
            if [[ "$write_lat_msec" =~ ^[0-9.]+$ ]]; then
                write_lat=$(echo "$write_lat_msec * 1000" | bc -l)
            fi
        fi
        
        # Calculate weighted average latency (70% read, 30% write for randrw)
        if [[ "$read_lat" =~ ^[0-9.]+$ ]] && [[ "$write_lat" =~ ^[0-9.]+$ ]]; then
            latency_us=$(echo "($read_lat * 0.7) + ($write_lat * 0.3)" | bc -l | xargs printf "%.2f")
            echo "    Debug: Read lat: ${read_lat}μs, Write lat: ${write_lat}μs, Weighted avg: ${latency_us}μs" >&2
        elif [[ "$read_lat" =~ ^[0-9.]+$ ]]; then
            latency_us=$(printf "%.2f" "$read_lat")
            echo "    Debug: Using read latency: ${latency_us}μs" >&2
        elif [[ "$write_lat" =~ ^[0-9.]+$ ]]; then
            latency_us=$(printf "%.2f" "$write_lat")
            echo "    Debug: Using write latency: ${latency_us}μs" >&2
        fi
    else
        # Single operation workload - use original parsing logic
        if echo "$fio_output" | grep -q "clat (nsec)"; then
            # Format: "clat (nsec): min=871, max=1636.2k, avg=1776.38, stdev=1857.40"
            avg_lat_nsec=$(echo "$fio_output" | grep "clat (nsec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p')
            if [[ "$avg_lat_nsec" =~ ^[0-9.]+$ ]]; then
                latency_us=$(echo "$avg_lat_nsec / 1000" | bc -l | xargs printf "%.2f")
            fi
        elif echo "$fio_output" | grep -q "clat (usec)"; then
            # Format: "clat (usec): min=46, max=67734, avg=73.71, stdev=460.55"
            avg_lat_usec=$(echo "$fio_output" | grep "clat (usec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p')
            if [[ "$avg_lat_usec" =~ ^[0-9.]+$ ]]; then
                latency_us=$(printf "%.2f" "$avg_lat_usec")
            fi
        elif echo "$fio_output" | grep -q "lat (nsec)"; then
            # Format: "lat (nsec): min=36, max=1372, avg=57.76"
            avg_lat_nsec=$(echo "$fio_output" | grep "lat (nsec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p')
            if [[ "$avg_lat_nsec" =~ ^[0-9.]+$ ]]; then
                latency_us=$(echo "$avg_lat_nsec / 1000" | bc -l | xargs printf "%.2f")
            fi
        elif echo "$fio_output" | grep -q "lat (usec)"; then
            # Format: "lat (usec): min=36, max=1372, avg=57.76"
            avg_lat_usec=$(echo "$fio_output" | grep "lat (usec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p')
            if [[ "$avg_lat_usec" =~ ^[0-9.]+$ ]]; then
                latency_us=$(printf "%.2f" "$avg_lat_usec")
            fi
        elif echo "$fio_output" | grep -q "clat (msec)"; then
            # Format: "clat (msec): min=1, max=10, avg=5.23"
            avg_lat_msec=$(echo "$fio_output" | grep "clat (msec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p')
            if [[ "$avg_lat_msec" =~ ^[0-9.]+$ ]]; then
                latency_us=$(echo "$avg_lat_msec * 1000" | bc -l | xargs printf "%.2f")
            fi
        elif echo "$fio_output" | grep -q "lat (msec)"; then
            # Format: "lat (msec): min=1, max=10, avg=5.23"
            avg_lat_msec=$(echo "$fio_output" | grep "lat (msec)" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p')
            if [[ "$avg_lat_msec" =~ ^[0-9.]+$ ]]; then
                latency_us=$(echo "$avg_lat_msec * 1000" | bc -l | xargs printf "%.2f")
            fi
        fi
    fi
    
    echo "$latency_us"
}

# Parse throughput from fio output
parse_throughput() {
    local fio_output="$1"
    local throughput_mb="0"
    
    # Extract throughput from summary line
    # For mixed workloads, sum read and write throughput
    if echo "$fio_output" | grep -qE "(bw=|BW=)"; then
        if echo "$fio_output" | grep -q "read.*:" && echo "$fio_output" | grep -q "write.*:"; then
            # Mixed workload - sum read and write throughput
            echo "    Debug: Mixed workload throughput - summing read and write" >&2
            
            read_throughput_mb="0"
            write_throughput_mb="0"
            
            # Get read throughput
            read_line=$(echo "$fio_output" | grep -E "^\s*read\s*:" | head -1)
            if echo "$read_line" | grep -qi "([0-9.]*MB/s)"; then
                read_throughput_mb=$(echo "$read_line" | grep -oEi '\([0-9.]*MB/s\)' | head -1 | sed 's/[()MBmb/s]//g')
            elif echo "$read_line" | grep -qi "([0-9.]*kB/s)"; then
                read_throughput_kb=$(echo "$read_line" | grep -oEi '\([0-9.]*kB/s\)' | head -1 | sed 's/[()KBkb/s]//g')
                if [[ "$read_throughput_kb" =~ ^[0-9.]+$ ]]; then
                    read_throughput_mb=$(echo "scale=2; $read_throughput_kb / 1000" | bc -l)
                fi
            elif echo "$read_line" | grep -qi "bw=[0-9.]*MiB/s"; then
                read_throughput_mib=$(echo "$read_line" | grep -oEi 'bw=[0-9.]*MiB/s' | head -1 | sed 's/bw=\|MiB\/s//gI')
                if [[ "$read_throughput_mib" =~ ^[0-9.]+$ ]]; then
                    read_throughput_mb=$(echo "scale=2; $read_throughput_mib * 1.048576" | bc -l)
                fi
            elif echo "$read_line" | grep -qi "bw=[0-9.]*KiB/s"; then
                read_throughput_kib=$(echo "$read_line" | grep -oEi 'bw=[0-9.]*KiB/s' | head -1 | sed 's/bw=\|KiB\/s//gI')
                if [[ "$read_throughput_kib" =~ ^[0-9.]+$ ]]; then
                    read_throughput_mb=$(echo "scale=2; $read_throughput_kib * 1.024 / 1000" | bc -l)
                fi
            fi
            
            # Get write throughput  
            write_line=$(echo "$fio_output" | grep -E "^\s*write\s*:" | head -1)
            if echo "$write_line" | grep -qi "([0-9.]*MB/s)"; then
                write_throughput_mb=$(echo "$write_line" | grep -oEi '\([0-9.]*MB/s\)' | head -1 | sed 's/[()MBmb/s]//g')
            elif echo "$write_line" | grep -qi "([0-9.]*kB/s)"; then
                write_throughput_kb=$(echo "$write_line" | grep -oEi '\([0-9.]*kB/s\)' | head -1 | sed 's/[()KBkb/s]//g')
                if [[ "$write_throughput_kb" =~ ^[0-9.]+$ ]]; then
                    write_throughput_mb=$(echo "scale=2; $write_throughput_kb / 1000" | bc -l)
                fi
            elif echo "$write_line" | grep -qi "bw=[0-9.]*MiB/s"; then
                write_throughput_mib=$(echo "$write_line" | grep -oEi 'bw=[0-9.]*MiB/s' | head -1 | sed 's/bw=\|MiB\/s//gI')
                if [[ "$write_throughput_mib" =~ ^[0-9.]+$ ]]; then
                    write_throughput_mb=$(echo "scale=2; $write_throughput_mib * 1.048576" | bc -l)
                fi
            elif echo "$write_line" | grep -qi "bw=[0-9.]*KiB/s"; then
                write_throughput_kib=$(echo "$write_line" | grep -oEi 'bw=[0-9.]*KiB/s' | head -1 | sed 's/bw=\|KiB\/s//gI')
                if [[ "$write_throughput_kib" =~ ^[0-9.]+$ ]]; then
                    write_throughput_mb=$(echo "scale=2; $write_throughput_kib * 1.024 / 1000" | bc -l)
                fi
            fi
            
            # Sum read and write throughput
            if [[ "$read_throughput_mb" =~ ^[0-9.]+$ ]] && [[ "$write_throughput_mb" =~ ^[0-9.]+$ ]]; then
                throughput_mb=$(echo "scale=2; $read_throughput_mb + $write_throughput_mb" | bc -l)
                echo "    Debug: Read: ${read_throughput_mb} MB/s, Write: ${write_throughput_mb} MB/s, Total: ${throughput_mb} MB/s" >&2
            elif [[ "$read_throughput_mb" =~ ^[0-9.]+$ ]]; then
                throughput_mb="$read_throughput_mb"
            elif [[ "$write_throughput_mb" =~ ^[0-9.]+$ ]]; then
                throughput_mb="$write_throughput_mb"
            fi
        else
            # Single operation workload - use original parsing logic
            throughput_line=$(echo "$fio_output" | grep -E "(READ|write|READ|WRITE): .*(bw=|BW=)" | tail -1)
            
            # Look for MB/s in parentheses first (more standard)
            if echo "$throughput_line" | grep -qi "([0-9.]*MB/s)"; then
                throughput_mb=$(echo "$throughput_line" | grep -oEi '\([0-9.]*MB/s\)' | head -1 | sed 's/[()MBmb/s]//g')
            # Look for kB/s in parentheses and convert to MB/s
            elif echo "$throughput_line" | grep -qi "([0-9.]*kB/s)"; then
                throughput_kb=$(echo "$throughput_line" | grep -oEi '\([0-9.]*kB/s\)' | head -1 | sed 's/[()KBkb/s]//g')
                if [[ "$throughput_kb" =~ ^[0-9.]+$ ]]; then
                    throughput_mb=$(echo "scale=2; $throughput_kb / 1000" | bc -l)
                fi
            # Look for MiB/s directly
            elif echo "$throughput_line" | grep -qi "(bw=|BW=)[0-9.]*MiB/s"; then
                throughput_mib=$(echo "$throughput_line" | grep -oEi '(bw=|BW=)[0-9.]*MiB/s' | head -1 | sed 's/bw=\|BW=\|MiB\/s//gI')
                if [[ "$throughput_mib" =~ ^[0-9.]+$ ]]; then
                    throughput_mb=$(echo "scale=2; $throughput_mib * 1.048576" | bc -l)
                fi
            # Look for KiB/s directly and convert to MB/s  
            elif echo "$throughput_line" | grep -qi "(bw=|BW=)[0-9.]*KiB/s"; then
                throughput_kib=$(echo "$throughput_line" | grep -oEi '(bw=|BW=)[0-9.]*KiB/s' | head -1 | sed 's/bw=\|BW=\|KiB\/s//gI')
                if [[ "$throughput_kib" =~ ^[0-9.]+$ ]]; then
                    throughput_mb=$(echo "scale=2; $throughput_kib * 1.024 / 1000" | bc -l)
                fi
            # Look for MB/s directly
            elif echo "$throughput_line" | grep -qi "(bw=|BW=)[0-9.]*MB/s"; then
                throughput_mb=$(echo "$throughput_line" | grep -oEi '(bw=|BW=)[0-9.]*MB/s' | head -1 | sed 's/bw=\|BW=\|MB\/s//gI')
            fi
        fi
    fi
    
    echo "$throughput_mb"
}
