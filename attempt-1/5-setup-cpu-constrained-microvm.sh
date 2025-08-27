#!/bin/bash

TAP_DEV="tap0"
TAP_IP="172.16.0.1"
MASK_SHORT="/30"

# Setup network interface
sudo ip link del "$TAP_DEV" 2> /dev/null || true
sudo ip tuntap add dev "$TAP_DEV" mode tap
sudo ip addr add "${TAP_IP}${MASK_SHORT}" dev "$TAP_DEV"
sudo ip link set dev "$TAP_DEV" up

# Enable ip forwarding
sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
sudo iptables -P FORWARD ACCEPT

HOST_IFACE=$(ip -j route list default |jq -r '.[0].dev')
sudo iptables -t nat -D POSTROUTING -o "$HOST_IFACE" -j MASQUERADE || true
sudo iptables -t nat -A POSTROUTING -o "$HOST_IFACE" -j MASQUERADE

API_SOCKET="/tmp/firecracker.socket"
LOGFILE="./firecracker.log"

# Remove existing socket and start fresh
sudo rm -f "${API_SOCKET}"

# Start Firecracker daemon first (fix the log-level argument)
sudo ./firecracker --api-sock "${API_SOCKET}" --log-path "${LOGFILE}" --level Debug &
FC_PID=$!
echo "Started Firecracker with PID: $FC_PID"

# Wait for socket to be ready
sleep 2

# Check if we have the required files
KERNEL="./$(ls vmlinux* 2>/dev/null | tail -1)"
# Fix rootfs selection - exclude test-disk.ext4
ROOTFS="./$(ls *.ext4 2>/dev/null | grep -v test-disk | tail -1)"

if [ ! -f "$KERNEL" ]; then
    echo "Error: No kernel file found (vmlinux*)"
    exit 1
fi

if [ ! -f "$ROOTFS" ]; then
    echo "Error: No rootfs file found (*.ext4, excluding test-disk.ext4)"
    echo "Available .ext4 files:"
    ls -la *.ext4 2>/dev/null || echo "None found"
    exit 1
fi

echo "Using kernel: $KERNEL"
echo "Using rootfs: $ROOTFS"

KERNEL_BOOT_ARGS="console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw"

ARCH=$(uname -m)
if [ ${ARCH} = "aarch64" ]; then
    KERNEL_BOOT_ARGS="keep_bootcon ${KERNEL_BOOT_ARGS}"
fi

# Set boot source
sudo curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"kernel_image_path\": \"${KERNEL}\",
        \"boot_args\": \"${KERNEL_BOOT_ARGS}\"
    }" \
    "http://localhost/boot-source"

# Set rootfs (note: using vda as root device)
sudo curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"drive_id\": \"rootfs\",
        \"path_on_host\": \"${ROOTFS}\",
        \"is_root_device\": true,
        \"is_read_only\": false
    }" \
    "http://localhost/drives/rootfs"

# Create a test disk for IO benchmarking
if [ ! -f "./test-disk.ext4" ]; then
    echo "Creating test disk..."
    dd if=/dev/zero of=./test-disk.ext4 bs=1M count=512
fi

# Add the test disk as vdb
sudo curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"drive_id\": \"test_disk\",
        \"path_on_host\": \"./test-disk.ext4\",
        \"is_root_device\": false,
        \"is_read_only\": false
    }" \
    "http://localhost/drives/test_disk"

FC_MAC="06:00:AC:10:00:02"

sudo curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"iface_id\": \"net1\",
        \"guest_mac\": \"$FC_MAC\",
        \"host_dev_name\": \"$TAP_DEV\"
    }" \
    "http://localhost/network-interfaces/net1"

# Configure with 2 vCPUs for testing
sudo curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"vcpu_count\": 1,
        \"mem_size_mib\": 1024
    }" \
    "http://localhost/machine-config"

sleep 0.5

# Start microVM
sudo curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"action_type\": \"InstanceStart\"
    }" \
    "http://localhost/actions"

echo "VM starting, waiting for boot..."
sleep 5

# Get the actual Firecracker process PID
FC_PID=$(pgrep firecracker)
echo "Firecracker PID: $FC_PID"

# Get vCPU thread PIDs (they are children of the main process)
VCPU_PIDS=$(pgrep -P $FC_PID 2>/dev/null | head -2)
echo "vCPU thread PIDs: $VCPU_PIDS"

# Pin vCPU threads to specific cores
if [ -n "$VCPU_PIDS" ]; then
    i=0
    for pid in $VCPU_PIDS; do
        sudo taskset -cp $i $pid 2>/dev/null && echo "Pinned vCPU thread $pid to core $i"
        i=$((i+1))
    done
else
    echo "Warning: Could not find vCPU threads"
fi

echo "Setup complete. VM should be running on 172.16.0.2"
echo "You can now run the monitoring and IO degradation tests."