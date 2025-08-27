#!/bin/bash

# Prerequisite checker for IO Comparison Framework

echo "=== IO COMPARISON FRAMEWORK PREREQUISITE CHECKER ==="
echo ""

EXIT_CODE=0

# Check commands
echo "Checking required commands..."
REQUIRED_COMMANDS="curl jq docker fio bc"
for cmd in $REQUIRED_COMMANDS; do
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "  ✓ $cmd found"
    else
        echo "  ✗ $cmd NOT FOUND"
        EXIT_CODE=1
    fi
done

# Check optional commands
echo ""
echo "Checking optional commands..."
if command -v python3 >/dev/null 2>&1; then
    echo "  ✓ python3 found (for analysis)"
else
    echo "  ⚠ python3 not found (analysis will be skipped)"
fi

# Check Docker
echo ""
echo "Checking Docker..."
if docker ps >/dev/null 2>&1; then
    echo "  ✓ Docker is running"
else
    echo "  ✗ Docker is NOT running or not accessible"
    EXIT_CODE=1
fi

# Check required files
echo ""
echo "Checking required files..."
FILES=(
    "../firecracker:Firecracker binary"
    "../vmlinux-6.1.128:Linux kernel"
    "../ubuntu-24.04.ext4:Root filesystem"
    "../ubuntu-24.04.id_rsa:SSH private key"
)

for file_desc in "${FILES[@]}"; do
    file_path="${file_desc%%:*}"
    file_name="${file_desc##*:}"
    
    if [ -f "$file_path" ]; then
        echo "  ✓ $file_name found"
    else
        echo "  ✗ $file_name NOT FOUND: $file_path"
        EXIT_CODE=1
    fi
done

# Check network availability
echo ""
echo "Checking network setup..."
if ip link show tap1 >/dev/null 2>&1; then
    echo "  ⚠ tap1 interface already exists (will be recreated)"
else
    echo "  ✓ tap1 interface available"
fi

# Check sudo access
echo ""
echo "Checking sudo access..."
if sudo -n true 2>/dev/null; then
    echo "  ✓ sudo access available"
else
    echo "  ⚠ sudo access may require password prompt"
fi

# Summary
echo ""
echo "=== SUMMARY ==="
if [ $EXIT_CODE -eq 0 ]; then
    echo "✓ All prerequisites met! You can run the framework."
    echo ""
    echo "To start the IO comparison:"
    echo "  ./io-comparison-framework.sh"
else
    echo "✗ Some prerequisites are missing. Please address the issues above."
fi

echo ""
exit $EXIT_CODE
