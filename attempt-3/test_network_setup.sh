#!/bin/bash

# Test network setup
# This script tests the network configuration independently

# Get script directory
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"

# Source modules
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/utils.sh"
source "$SCRIPT_DIR/cleanup.sh"
source "$SCRIPT_DIR/network_setup.sh"

echo "=== TESTING NETWORK SETUP ==="
echo "Setting up network configuration for testing..."

# Run network setup
setup_network

echo ""
echo "=== VERIFYING NETWORK SETUP ==="

# Check if TAP device was created
if ip link show "$TAP_DEV" >/dev/null 2>&1; then
    echo "✓ TAP device '$TAP_DEV' created successfully"
    
    # Check IP configuration
    tap_ip=$(ip addr show "$TAP_DEV" | grep "inet " | awk '{print $2}')
    if [[ "$tap_ip" == "${TAP_IP}${MASK_SHORT}" ]]; then
        echo "✓ TAP device IP configured correctly: $tap_ip"
    else
        echo "❌ TAP device IP configuration incorrect. Expected: ${TAP_IP}${MASK_SHORT}, Got: $tap_ip"
    fi
    
    # Check if interface is up
    if ip link show "$TAP_DEV" | grep -q "UP"; then
        echo "✓ TAP device is UP"
    else
        echo "❌ TAP device is not UP"
    fi
else
    echo "❌ TAP device '$TAP_DEV' not found"
fi

# Check IP forwarding
ip_forward=$(cat /proc/sys/net/ipv4/ip_forward)
if [[ "$ip_forward" == "1" ]]; then
    echo "✓ IP forwarding enabled"
else
    echo "❌ IP forwarding not enabled"
fi

# Check iptables NAT rule
if sudo iptables -t nat -L POSTROUTING | grep -q MASQUERADE; then
    echo "✓ NAT masquerading rule found"
else
    echo "❌ NAT masquerading rule not found"
fi

# Check host interface
host_iface=$(get_host_interface)
echo "Host interface: $host_iface"

echo ""
echo "✅ Network setup test completed!"
echo "Note: Cleanup will be performed automatically on script exit"
