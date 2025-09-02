# IO Performance Comparison Framework - Modular Version

This is a modular breakdown of the comprehensive IO performance comparison framework. The original monolithic script has been split into multiple focused components for easier testing, debugging, and maintenance.

## Components Overview

### Core Modules
- **`config.sh`** - Configuration variables and IO test patterns
- **`utils.sh`** - Shared utility functions (connectivity tests, prerequisites, etc.)
- **`cleanup.sh`** - Cleanup functions and trap handling
- **`metrics_parser.sh`** - FIO output parsing and metrics extraction

### Setup Modules
- **`network_setup.sh`** - Network configuration for Firecracker VM
- **`firecracker_setup.sh`** - Firecracker VM initialization
- **`container_setup.sh`** - Docker container setup

### Test Execution Modules
- **`container_test_runner.sh`** - Container IO test execution
- **`firecracker_test_runner.sh`** - Firecracker VM IO test execution
- **`analysis.sh`** - Results analysis and reporting

### Main Scripts
- **`run_io_benchmark.sh`** - Main orchestrator (equivalent to original script)
- **`io-comparison-framework.sh`** - Original monolithic script (kept for reference)

### Test Scripts
- **`test_prerequisites.sh`** - Test dependencies and configuration
- **`test_network_setup.sh`** - Test network setup in isolation
- **`test_container_setup.sh`** - Test container setup in isolation
- **`test_firecracker_setup.sh`** - Test Firecracker setup in isolation
- **`test_single_benchmark.sh`** - Run a single benchmark test

## Usage

### Running the Complete Benchmark
```bash
# Run the full benchmark suite (equivalent to original script)
./run_io_benchmark.sh
```

### Testing Individual Components
```bash
# Test prerequisites and configuration
./test_prerequisites.sh

# Test network setup
./test_network_setup.sh

# Test container setup
./test_container_setup.sh

# Test Firecracker VM setup  
./test_firecracker_setup.sh

# Test a single benchmark
./test_single_benchmark.sh
```

### Configuration Options
You can customize the behavior by setting environment variables:

```bash
# Quick test mode (runs subset of tests)
QUICK_TEST=true ./run_io_benchmark.sh

# Comprehensive test mode (runs all tests)
COMPREHENSIVE_TEST=true ./run_io_benchmark.sh

# Focus on specific block size
FOCUSED_BLOCK_SIZE="4k" ./run_io_benchmark.sh

# Custom iteration count
ITERATIONS=5 ./run_io_benchmark.sh
```

## Debugging Strategy

1. **Start with prerequisites**: Run `./test_prerequisites.sh` to ensure all dependencies are available

2. **Test network setup**: Run `./test_network_setup.sh` to verify TAP device and routing

3. **Test container setup**: Run `./test_container_setup.sh` to verify Docker container and fio installation

4. **Test VM setup**: Run `./test_firecracker_setup.sh` to verify Firecracker VM boot and SSH connectivity

5. **Test single benchmark**: Run `./test_single_benchmark.sh` to verify the complete pipeline with one test

6. **Run full benchmark**: Once all components work, run `./run_io_benchmark.sh`

## Component Testing Benefits

- **Isolation**: Test each component independently
- **Faster debugging**: Identify which specific component is failing
- **Incremental development**: Develop and test features piece by piece
- **Better error messages**: More focused error reporting per component
- **Parallel development**: Different team members can work on different modules

## File Dependencies

```
config.sh (base configuration)
├── utils.sh (uses config.sh)
├── cleanup.sh (uses config.sh)
├── metrics_parser.sh (uses config.sh)
├── network_setup.sh (uses config.sh, utils.sh)
├── firecracker_setup.sh (uses config.sh, utils.sh)
├── container_setup.sh (uses config.sh, utils.sh)
├── container_test_runner.sh (uses config.sh, utils.sh, metrics_parser.sh)
├── firecracker_test_runner.sh (uses config.sh, utils.sh, metrics_parser.sh)
├── analysis.sh (uses config.sh)
└── run_io_benchmark.sh (uses all modules)
```

## Troubleshooting

### Common Issues and Solutions

1. **Permission errors**: Ensure all scripts are executable with `chmod +x *.sh`

2. **Network setup fails**: 
   - Check if TAP device name conflicts with existing interfaces
   - Verify sudo permissions for network commands

3. **Firecracker fails to start**:
   - Check if required files exist (firecracker binary, kernel, rootfs)
   - Verify API socket permissions

4. **Container setup fails**:
   - Check Docker daemon is running
   - Verify internet connectivity for package installation

5. **Tests produce no data**:
   - Run individual test scripts to isolate the issue
   - Check disk space in both container and VM

## Performance Tips

- Use `QUICK_TEST=true` for rapid validation
- Use `FOCUSED_BLOCK_SIZE` to test specific scenarios
- Reduce `ITERATIONS` for faster testing during development
- Check system resources (CPU, memory, disk) before running comprehensive tests

## Output Files

When running tests, the following files are generated:
- `io_benchmark_results_YYYYMMDD_HHMMSS/` - Results directory
- `container_*.csv` - Container performance data
- `firecracker_*.csv` - Firecracker performance data  
- `*_cpu.log` - CPU utilization logs
- `analyze_results.py` - Python analysis script
- `firecracker-io-test.log` - VM execution logs
