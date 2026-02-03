#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# NimixOS Phase 1 Build Script

set -e

# Configuration
PROJECT_ROOT="/home/user/nimLinux_experiment"
BUILD_DIR="$PROJECT_ROOT/build"
ARCH="x86_64"
KERNEL_IMAGE="$BUILD_DIR/kernel.elf"
KERNEL_ISO="$BUILD_DIR/kernel.iso"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         NimixOS Phase 1 - Build Script                    ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Step 1: Assemble boot.asm
echo -e "${YELLOW}[1/3] Assembling boot.asm...${NC}"
if nasm -f elf64 "$PROJECT_ROOT/arch/x86_64/boot.asm" -o "$BUILD_DIR/boot.o" 2>&1 | grep -v "warning"; then
    echo -e "${GREEN}✓ boot.asm assembled${NC}"
else
    # nasm might have warnings but still succeed
    if [ -f "$BUILD_DIR/boot.o" ]; then
        echo -e "${GREEN}✓ boot.asm assembled (with warnings)${NC}"
    else
        echo -e "${RED}✗ Failed to assemble boot.asm${NC}"
        exit 1
    fi
fi

# Step 2: Compile Nim code to C
echo -e "${YELLOW}[2/3] Compiling Nim kernel code...${NC}"

# Create a main compilation wrapper that calls kernelMain
cat > "$BUILD_DIR/kernel_entry.nim" << 'EOF'
# Nim entry point for kernel
import ../kern/kernel_main
import ../arch/x86_64/early_init

# Called from boot.asm as _start
proc kernelEntry*() {.exportc: "_nim_start", noReturn.} =
  ## Entry point called from boot.asm
  ## boot.asm jumps here after early setup
  kernelMain()

# Keep kernelMain available for linking
proc kernelMainWrapper*() {.exportc: "kernelMain".} =
  kernelMain()
EOF

# Compile with Nim
cd "$PROJECT_ROOT"
nim c --os:any --gc:none -d:release -d:danger \
    --passL:"$BUILD_DIR/linker.ld" \
    --outdir:"$BUILD_DIR" \
    --nimcache:"$BUILD_DIR/nimcache" \
    "$BUILD_DIR/kernel_entry.nim" 2>&1 | head -20 || true

# Check if Nim generated C code
if [ -f "$BUILD_DIR/kernel_entry.c" ]; then
    echo -e "${GREEN}✓ Nim code compiled to C${NC}"

    # Compile generated C code
    gcc -c -O2 -mcmodel=kernel -ffreestanding -fno-stack-protector \
        -mno-red-zone -nostdlib -fno-builtin \
        "$BUILD_DIR/kernel_entry.c" -o "$BUILD_DIR/kernel_code.o" 2>&1 | head -10 || true

    if [ -f "$BUILD_DIR/kernel_code.o" ]; then
        echo -e "${GREEN}✓ C code compiled to object file${NC}"
    fi
fi

# Step 3: Link everything together
echo -e "${YELLOW}[3/3] Linking kernel image...${NC}"

# Try to link with ld
if ld -T "$BUILD_DIR/linker.ld" -o "$KERNEL_IMAGE" \
    "$BUILD_DIR/boot.o" "$BUILD_DIR/kernel_code.o" 2>&1; then
    echo -e "${GREEN}✓ Kernel linked successfully${NC}"
    ls -lh "$KERNEL_IMAGE"
else
    echo -e "${RED}✗ Failed to link kernel${NC}"
    echo "Debug: Checking object files..."
    ls -lh "$BUILD_DIR"/*.o || true
    exit 1
fi

# Verify it's a valid ELF
if file "$KERNEL_IMAGE" | grep -q "ELF"; then
    echo -e "${GREEN}✓ Valid ELF kernel image${NC}"
else
    echo -e "${RED}✗ Kernel image is not valid ELF${NC}"
    file "$KERNEL_IMAGE"
    exit 1
fi

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Build Complete!                                          ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}Kernel image: $KERNEL_IMAGE${NC}"
echo ""
echo "To test on QEMU:"
echo "  qemu-system-x86_64 -kernel $KERNEL_IMAGE -serial stdio -nographic"
echo ""
