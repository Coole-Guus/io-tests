# Standalone IO Performance Comparison Framework

This framework provides an independent setup to compare IO performance between Docker containers and Firecracker VMs.

## Features

- **Independent Setup**: Runs completely separately from existing benchmarking implementations
- **Comprehensive Testing**: Sequential/random read/write and mixed workload patterns
- **Dual Environment**: Automated testing in both containers and Firecracker VMs
- **Performance Monitoring**: CPU, memory, and IO metrics collection
- **Statistical Analysis**: Automated comparison with ratios and performance insights

## Prerequisites

Before running the framework, ensure you have:

1. **Required Commands**: 
   - `curl`, `jq`, `docker`, `fio`
   - `bc` (for calculations)
   - `python3` (optional, for analysis)

2. **Required Files** (in parent directory):
   - `../firecracker` - Firecracker binary
   - `../vmlinux-6.1.128` - Linux kernel
   - `../ubuntu-24.04.ext4` - Root filesystem
   - `../ubuntu-24.04.id_rsa` - SSH private key

3. **System Requirements**:
   - Root/sudo access for network setup
   - Docker daemon running
   - Available network interface `tap1`

## Usage

Simply run the script:

```bash
./io-comparison-framework.sh
```

The framework will:
1. Check all prerequisites
2. Set up an independent network interface (tap1)
3. Launch a fresh Firecracker VM
4. Create a test container
5. Run identical IO tests in both environments
6. Collect performance metrics
7. Generate comparative analysis

## Network Configuration

The framework uses its own network setup to avoid conflicts:
- TAP device: `tap1`
- Host IP: `172.17.0.1/30`
- VM IP: `172.17.0.2`
- API socket: `/tmp/firecracker-io-test.socket`

## Test Patterns

The framework tests five IO patterns:
- Sequential write operations
- Sequential read operations  
- Random write operations
- Random read operations
- Mixed read/write workloads

## Output

Results are saved to `./io_benchmark_results_TIMESTAMP/` containing:
- `container_*.csv` - Container performance data
- `firecracker_*.csv` - Firecracker performance data
- `*_cpu.log` - CPU utilization logs
- `analyze_results.py` - Analysis script
- `firecracker-io-test.log` - VM operation logs

## Analysis

The framework automatically generates comparative analysis showing:
- Latency comparisons (average, standard deviation)
- Throughput comparisons (when available)
- CPU load ratios
- Performance overhead ratios

## Cleanup

The script automatically cleans up all resources on exit:
- Stops Firecracker VM
- Removes test container
- Cleans up network interface
- Removes temporary files

## Troubleshooting

If the script fails:
1. Check that all prerequisite files exist
2. Ensure Docker is running
3. Verify you have sudo access
4. Check that tap1 interface is available
5. Review logs in the results directory

## Independence

This framework is completely independent from other benchmarking implementations:
- Uses separate network interfaces
- Uses different API sockets
- Creates its own temporary files
- Does not interfere with existing VMs or containers
