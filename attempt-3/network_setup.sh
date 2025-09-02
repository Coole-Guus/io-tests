#!/bin/bash

# Network setup for the IO Performance Comparison Framework
# Handles network configuration for Firecracker VM

# Source configuration and utils
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

# Network setup
setup_network() {
    echo "Setting up network interface..."
    
    # Remove existing interface if it exists
    sudo ip link del "$TAP_DEV" 2>/dev/null || true
    
    # Create TAP device
    sudo ip tuntap add dev "$TAP_DEV" mode tap
    sudo ip addr add "${TAP_IP}${MASK_SHORT}" dev "$TAP_DEV"
    sudo ip link set dev "$TAP_DEV" up
    
    # Enable IP forwarding
    sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
    sudo iptables -P FORWARD ACCEPT
    
    # Get host interface
    HOST_IFACE=$(get_host_interface)
    echo "Host interface: $HOST_IFACE"
    
    # Set up NAT for microVM internet access
    sudo iptables -t nat -D POSTROUTING -o "$HOST_IFACE" -j MASQUERADE 2>/dev/null || true
    sudo iptables -t nat -A POSTROUTING -o "$HOST_IFACE" -j MASQUERADE
    
    echo "Network setup complete"
}
