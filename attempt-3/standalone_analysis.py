#!/usr/bin/env python3
"""
Standalone IO Performance Analysis Script
Analyzes results from any benchmark results directory
"""

import os
import sys
import csv
import statistics
from pathlib import Path

def analyze_performance(container_file, firecracker_file, test_name):
    """Analyze performance differences between container and Firecracker"""
    try:
        # Read container data
        with open(container_file, 'r') as f:
            reader = csv.DictReader(f)
            container_data = list(reader)
        
        # Read Firecracker data  
        with open(firecracker_file, 'r') as f:
            reader = csv.DictReader(f)
            firecracker_data = list(reader)
        
        if not container_data or not firecracker_data:
            print(f"Warning: Missing data for {test_name}")
            return None
        
        # Calculate averages (skip zero values)
        container_latencies = [float(d['latency_us']) for d in container_data if float(d['latency_us']) > 0]
        firecracker_latencies = [float(d['latency_us']) for d in firecracker_data if float(d['latency_us']) > 0]
        
        container_throughputs = [float(d['throughput_mbps']) for d in container_data if float(d['throughput_mbps']) > 0]
        firecracker_throughputs = [float(d['throughput_mbps']) for d in firecracker_data if float(d['throughput_mbps']) > 0]
        
        result = {
            'test_name': test_name,
            'container_latency_avg': statistics.mean(container_latencies) if container_latencies else 0,
            'firecracker_latency_avg': statistics.mean(firecracker_latencies) if firecracker_latencies else 0,
            'container_throughput_avg': statistics.mean(container_throughputs) if container_throughputs else 0,
            'firecracker_throughput_avg': statistics.mean(firecracker_throughputs) if firecracker_throughputs else 0
        }
        
        # Calculate improvements
        if result['container_latency_avg'] > 0 and result['firecracker_latency_avg'] > 0:
            if result['container_latency_avg'] > result['firecracker_latency_avg']:
                result['latency_improvement'] = ((result['container_latency_avg'] - result['firecracker_latency_avg']) / result['container_latency_avg']) * 100
                result['latency_winner'] = 'Firecracker'
            else:
                result['latency_improvement'] = ((result['firecracker_latency_avg'] - result['container_latency_avg']) / result['firecracker_latency_avg']) * 100
                result['latency_winner'] = 'Container'
        else:
            result['latency_improvement'] = 0
            result['latency_winner'] = 'Unknown'
            
        if result['container_throughput_avg'] > 0 and result['firecracker_throughput_avg'] > 0:
            if result['firecracker_throughput_avg'] > result['container_throughput_avg']:
                result['throughput_improvement'] = ((result['firecracker_throughput_avg'] - result['container_throughput_avg']) / result['container_throughput_avg']) * 100
                result['throughput_winner'] = 'Firecracker'
            else:
                result['throughput_improvement'] = ((result['container_throughput_avg'] - result['firecracker_throughput_avg']) / result['firecracker_throughput_avg']) * 100
                result['throughput_winner'] = 'Container'
        else:
            result['throughput_improvement'] = 0
            result['throughput_winner'] = 'Unknown'
        
        print(f"\n🧪 {test_name}")
        print(f"{'='*60}")
        print(f"Container    | Latency: {result['container_latency_avg']:.2f}μs | Throughput: {result['container_throughput_avg']:.2f} MB/s")
        print(f"Firecracker  | Latency: {result['firecracker_latency_avg']:.2f}μs | Throughput: {result['firecracker_throughput_avg']:.2f} MB/s")
        
        if result['latency_winner'] != 'Unknown':
            print(f"Latency Winner: {result['latency_winner']} ({result['latency_improvement']:.1f}% better)")
        if result['throughput_winner'] != 'Unknown':
            print(f"Throughput Winner: {result['throughput_winner']} ({result['throughput_improvement']:.1f}% better)")
        
        return result
        
    except Exception as e:
        print(f"Error analyzing {test_name}: {e}")
        return None

def main(results_dir):
    results_dir = Path(results_dir)
    
    if not results_dir.exists():
        print(f"Error: Results directory {results_dir} does not exist")
        return
    
    print(f"\n{'='*60}")
    print("📊 IO PERFORMANCE ANALYSIS REPORT")
    print(f"{'='*60}")
    print(f"Results Directory: {results_dir}")
    
    # Find all test result pairs
    container_files = list(results_dir.glob("container_*.csv"))
    all_results = []
    
    if not container_files:
        print("No container CSV files found in results directory")
        return
    
    for container_file in container_files:
        test_name = container_file.name.replace("container_", "").replace(".csv", "")
        firecracker_file = results_dir / f"firecracker_{test_name}.csv"
        
        if firecracker_file.exists():
            result = analyze_performance(container_file, firecracker_file, test_name)
            if result:
                all_results.append(result)
        else:
            print(f"Missing Firecracker data for {test_name}")
    
    # Generate summary
    if all_results:
        print(f"\n{'='*60}")
        print("📈 SUMMARY")
        print(f"{'='*60}")
        
        firecracker_latency_wins = sum(1 for r in all_results if r['latency_winner'] == 'Firecracker')
        container_latency_wins = sum(1 for r in all_results if r['latency_winner'] == 'Container')
        
        firecracker_throughput_wins = sum(1 for r in all_results if r['throughput_winner'] == 'Firecracker')
        container_throughput_wins = sum(1 for r in all_results if r['throughput_winner'] == 'Container')
        
        print(f"Total tests analyzed: {len(all_results)}")
        print(f"\nLatency comparison:")
        print(f"  • Firecracker wins: {firecracker_latency_wins}")
        print(f"  • Container wins: {container_latency_wins}")
        
        print(f"\nThroughput comparison:")
        print(f"  • Firecracker wins: {firecracker_throughput_wins}")
        print(f"  • Container wins: {container_throughput_wins}")
    else:
        print("No matching result pairs found for analysis")
    
    print(f"\n{'='*60}")
    print("🏁 ANALYSIS COMPLETE")
    print(f"{'='*60}")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python3 standalone_analysis.py <results_dir>")
        print("Example: python3 standalone_analysis.py io_benchmark_results_20250905_102004")
        sys.exit(1)
    
    main(sys.argv[1])
