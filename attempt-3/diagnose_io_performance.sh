#!/bin/bash

# Advanced diagnostic script to investigate IO performance discrepancies
cd /home/guus/code-projects/io-tests/attempt-3

source config.sh
source utils.sh
source network_setup.sh
source firecracker_setup.sh
source container_setup.sh

echo "DIAGNOSING IO PERFORMANCE FAIRNESS ISSUES"
echo "==============================================="

# Start both systems
echo "Starting network and systems..."
setup_network
setup_firecracker_vm &
setup_container &

# Wait for both to be ready
wait

echo
echo "SYSTEM RESOURCE VERIFICATION"
echo "==============================================="

echo "Host CPU usage:"
top -bn1 | grep -E "(Cpu|firecracker|docker)" | head -5

echo
echo "Host memory usage:"
free -h

echo
echo "Host disk I/O:"
iostat -x 1 1 2>/dev/null || echo "iostat not available"

echo
echo "CONTAINER STORAGE ANALYSIS"
echo "==============================================="

echo "Container loop device:"
docker exec io_test_container lsblk | grep test_disk
echo "Container mount info:"
docker exec io_test_container df -h /mnt/test_data
echo "Container block device info:"
docker exec io_test_container lsblk -f /dev/test_disk 2>/dev/null || echo "Block device info not available"
echo "Container CPU constraints:"
docker stats io_test_container --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"

echo
echo "Container test write (10MB):"
docker exec io_test_container /bin/bash -c "cd /mnt/test_data && dd if=/dev/zero of=test_write bs=1M count=10 conv=fsync 2>&1 | grep -E 'bytes|MB/s'"

echo
echo "FIRECRACKER VM STORAGE ANALYSIS"  
echo "==============================================="

echo "VM block devices:"
ssh -i "./ubuntu-24.04.id_rsa" -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@172.17.0.2 "lsblk"
echo "VM mount info:"
ssh -i "./ubuntu-24.04.id_rsa" -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@172.17.0.2 "df -h /mnt/test_data"
echo "VM block device details:"
ssh -i "./ubuntu-24.04.id_rsa" -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@172.17.0.2 "lsblk -f /dev/vdb"

echo
echo "VM test write (10MB):"
ssh -i "./ubuntu-24.04.id_rsa" -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@172.17.0.2 "cd /mnt/test_data && dd if=/dev/zero of=test_write bs=1M count=10 conv=fsync 2>&1 | grep -E 'bytes|MB/s'"

echo
echo "BASIC FIO COMPARISON TEST"
echo "==============================================="

echo "Container simple random read test:"
docker exec io_test_container /bin/bash -c "cd /mnt/test_data && fio --name=test --rw=randread --size=50M --bs=4k --numjobs=1 --runtime=5s --time_based --group_reporting --filename=testfile --direct=1 | grep -E '(read:|aggrb=)'"

echo
echo "Firecracker simple random read test:"
ssh -i "./ubuntu-24.04.id_rsa" -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@172.17.0.2 "cd /mnt/test_data && fio --name=test --rw=randread --size=50M --bs=4k --numjobs=1 --runtime=5s --time_based --group_reporting --filename=testfile --direct=1 | grep -E '(read:|aggrb=)'"

echo
echo "HOST STORAGE BACKEND ANALYSIS"
echo "==============================================="

echo "Host loop devices in use:"
sudo losetup -a | grep -E "(test_disk|\.ext4)"

echo "Host disk files:"
ls -la *.ext4 test_disk* 2>/dev/null | head -5

echo "Host filesystem cache status:"
echo "Available memory: $(free -h | awk '/Available/ {print $7}')"
echo "Cached: $(free -h | awk '/^Mem:/ {print $6}')"

echo
echo "FAIRNESS ISSUES IDENTIFIED:"
echo "==============================================="

# Check if both are using the same underlying storage
container_loop=$(docker exec io_test_container lsblk /dev/test_disk -no FSTYPE 2>/dev/null || echo "unknown")
vm_filesystem=$(ssh -i "./ubuntu-24.04.id_rsa" -o StrictHostKeyChecking=no root@172.17.0.2 "lsblk /dev/vdb -no FSTYPE" 2>/dev/null || echo "unknown")

echo "Container filesystem: $container_loop"
echo "VM filesystem: $vm_filesystem"

if [ "$container_loop" = "$vm_filesystem" ]; then
    echo "Same filesystem type"
else
    echo "Different filesystem types - potential unfairness!"
fi

# Check CPU constraints
echo "Container CPU limit: $(docker inspect io_test_container | grep -i cpu | head -2)"
echo "VM process CPU constraints: $(ps -o pid,comm,psr -p $(pgrep firecracker) 2>/dev/null || echo 'VM not found')"

echo
echo "Diagnosis complete! Check for discrepancies above."
