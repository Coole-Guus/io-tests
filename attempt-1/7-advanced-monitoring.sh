#!/bin/bash

KEY_NAME=./$(ls *.id_rsa 2>/dev/null | tail -1)

if [ ! -f "$KEY_NAME" ]; then
    echo "Error: SSH key not found"
    exit 1
fi

# Function to run IO test inside VM
run_vm_io_test() {
    local test_name="$1"
    local duration=${2:-30}
    
    echo "=== Running IO test: $test_name (${duration}s) ==="
    
    # Simple dd-based IO test that doesn't require additional tools
    ssh -i $KEY_NAME -o StrictHostKeyChecking=no root@172.16.0.2 "
        echo 'Starting IO test: $test_name'
        sync
        start_time=\$(date +%s)
        
        # Write test
        dd if=/dev/zero of=/tmp/iotest bs=4k count=10000 oflag=direct 2>&1 | grep -E 'copied|GB/s|MB/s'
        
        # Read test  
        dd if=/tmp/iotest of=/dev/null bs=4k iflag=direct 2>&1 | grep -E 'copied|GB/s|MB/s'
        
        # Random IO test using /dev/vdb if available
        if [ -b /dev/vdb ]; then
            echo 'Testing random IO on /dev/vdb'
            dd if=/dev/urandom of=/dev/vdb bs=4k count=1000 oflag=direct 2>&1 | grep -E 'copied|GB/s|MB/s'
        fi
        
        rm -f /tmp/iotest
        end_time=\$(date +%s)
        echo \"Test $test_name completed in \$((end_time - start_time)) seconds\"
    " 2>&1 | tee "io_test_${test_name}_$(date +%s).log"
}

# Wait for VM to be ready
echo "Waiting for VM to be ready..."
for i in {1..30}; do
    if ssh -i $KEY_NAME -o StrictHostKeyChecking=no -o ConnectTimeout=2 root@172.16.0.2 echo "ready" 2>/dev/null; then
        echo "VM is ready!"
        break
    fi
    sleep 1
done

# Run baseline test
run_vm_io_test "baseline" 30

echo "IO degradation test completed. Run the monitoring script to see vCPU scheduling effects."