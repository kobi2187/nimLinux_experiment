# SPDX-License-Identifier: GPL-2.0
# NimixOS Makefile — fast development cycle
#
# Usage:
#   make          # build kernel, create ISO, boot in QEMU with UEFI+serial
#   make build    # just compile the kernel
#   make iso      # create ISO from built kernel
#   make qemu     # boot ISO in QEMU (UEFI, serial, no display)
#   make qemu-gui # boot with VGA display
#   make clean    # remove build artifacts
#
# Config:
#   NIM      = path to nim compiler (default: /home/kl/apps/Nim/bin/nim)
#   OVMF     = path to OVMF.fd     (default: /usr/share/ovmf/OVMF.fd)
#   QEMU_MEM = memory in MB        (default: 256)

NIM     ?= /home/kl/apps/Nim/bin/nim
OVMF    ?= /usr/share/ovmf/OVMF.fd
QEMU_MEM ?= 256

# Nim flags for kernel build
NIM_FLAGS = c --os:any --mm:arc -d:StandaloneHeapSize=16777216 \
            -d:release -d:danger --noMain --outdir:build \
            --nimblePath:nimcache

# Source
KERNEL_SRC = kernel/init/main.nim
KERNEL_OUT = build/main
ISO_OUT    = nimixos.iso

.PHONY: all build iso qemu qemu-gui run clean test

# Default target: full cycle
all: build iso qemu

# ── Compile kernel ────────────────────────────────────────────────
build: $(KERNEL_OUT)

$(KERNEL_OUT): $(KERNEL_SRC) $(shell find . -name '*.nim' -not -path './nimcache/*' -not -path './tests/*')
	$(NIM) $(NIM_FLAGS) $(KERNEL_SRC)

# ── Create bootable ISO ───────────────────────────────────────────
iso: $(ISO_OUT)

$(ISO_OUT): $(KERNEL_OUT)
	rm -rf iso
	mkdir -p iso/boot/grub
	cp $(KERNEL_OUT) iso/boot/kernel.elf
	printf 'set timeout=2\nset default=0\nmenuentry "NimixOS" { multiboot2 /boot/kernel.elf }\n' > iso/boot/grub/grub.cfg
	grub-mkrescue -o $(ISO_OUT) iso/
	rm -rf iso

# ── Run in QEMU (headless, serial only) ───────────────────────────
qemu: $(ISO_OUT)
	qemu-system-x86_64 -cdrom $(ISO_OUT) -bios $(OVMF) \
		-no-reboot -m $(QEMU_MEM)M -serial stdio -display none

# ── Run in QEMU (with VGA) ────────────────────────────────────────
qemu-gui: $(ISO_OUT)
	qemu-system-x86_64 -cdrom $(ISO_OUT) -bios $(OVMF) \
		-no-reboot -m $(QEMU_MEM)M -serial stdio

# ── Alias ─────────────────────────────────────────────────────────
run: all

# ── Unit tests (host, no QEMU needed) ────────────────────────────
# Uses --skipParentCfg to bypass kernel nim.cfg (-nostdlib, kernel.ld, etc.)
TEST_FLAGS = --skipParentCfg --mm:refc --path:$(CURDIR) -d:noSignalHandler

test:
	@echo "=== NimixOS Test Suite ==="
	$(NIM) c -r $(TEST_FLAGS) tests/test_log.nim
	$(NIM) c -r $(TEST_FLAGS) tests/test_vga_text.nim
	$(NIM) c -r $(TEST_FLAGS) tests/test_traits.nim
	$(NIM) c -r $(TEST_FLAGS) tests/test_ps2_keyboard.nim
	$(NIM) c -r $(TEST_FLAGS) tests/test_pic.nim
	$(NIM) c -r $(TEST_FLAGS) tests/test_pit.nim
	@echo "=== All tests passed ==="

# ── Clean ─────────────────────────────────────────────────────────
clean:
	rm -rf $(KERNEL_OUT) $(ISO_OUT) nimcache/ build/ iso/
