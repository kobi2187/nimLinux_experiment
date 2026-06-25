# SPDX-License-Identifier: GPL-2.0
# NimixOS Makefile — fast development cycle
#
# Usage:
#   make          # build kernel, create ISO, boot in QEMU with UEFI+serial
#   make build    # just compile the kernel (all 3 models)
#   make apps     # compile WASM apps from C source → update embedded arrays
#   make iso      # create ISO from built kernel
#   make iso-all  # create ISO with all 3 kernel models in GRUB menu
#   make qemu     # boot ISO in QEMU (UEFI, serial, no display)
#   make qemu-gui # boot with VGA display
#   make qemu-debug # boot with GDB server on :1234 (paused at start)
#   make test      # run host-side unit tests
#   make test-qemu # boot ISO in QEMU and run serial test suite
#   make clean     # remove build artifacts
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
            -d:release -d:danger -d:kernelFull --noMain --outdir:build \
            --nimblePath:nimcache

# Kernel models to build
KERNEL_MODELS = microkernel sasos monolithic

# Source
KERNEL_SRC = kernel/init/main.nim
KERNEL_OUT = build/main
ISO_OUT    = nimixos.iso
ISO_ALL_OUT = nimixos-all-kernels.iso

.PHONY: all build apps nim-apps iso iso-all qemu qemu-all qemu-gui qemu-debug run clean test test-qemu test-arc

# Default target: full cycle
all: build iso qemu

# ── Compile WASM apps from C source ──────────────────────────────
# Rebuilds .wasm from .c and regenerates the embedded Nim byte array.
CLANG_WASM = clang --target=wasm32 -nostdlib -Wl,--no-entry \
             -Wl,--export=_start -Wl,--allow-undefined -O2

# ── Compile Nim userspace apps (PIE, --os:standalone) ────────────────────────
# These are native Nim binaries that link against the kernel ABI.
# Always compiled as PIE so the SASOS loader can place them anywhere.
# Weak stub .o — provides nimixWrite/nimixExit/etc as weak symbols so the linker
# resolves them. The kernel loader overwrites them with jmp <real_addr> at runtime.
build/nimix_abi_stub.o: kernel/abi/nimix_abi_stub.c
	@mkdir -p build
	gcc -c -fPIC -ffreestanding -fno-stack-protector -o $@ $<

NIM_APP = $(NIM) c --skipParentCfg --skipUserCfg \
          --os:standalone --mm:arc --cpu:amd64 --noMain \
          -d:StandaloneHeapSize=1048576 \
          -d:noSignalHandler -d:nimNoLentIterators \
          --passC:"-ffreestanding -fno-stack-protector -mno-red-zone -fPIC" \
          --passC:"-I$(CURDIR)/kernel/abi" \
          --passL:"-nostdlib -pie $(CURDIR)/build/nimix_abi_stub.o" \
          --path:$(CURDIR) \
          --path:$(CURDIR)/apps/nim \
          --nimblePath:$(HOME)/.nimble/pkgs2

nim-apps: build/apps/hello.elf build/apps/ping_server.elf \
          build/apps/ps.elf build/apps/kill.elf \
          build/apps/stats.elf build/apps/ls.elf \
          build/apps/top.elf build/apps/dispatch_server.elf \
          build/apps/fs_server.elf

build/apps/hello.elf: apps/nim/hello/hello.nim kernel/abi/nimix_abi.h build/nimix_abi_stub.o
	@mkdir -p build/apps
	$(NIM_APP) -o:$@ $<

build/apps/ping_server.elf: servers/ping/ping_server_elf.nim servers/ping/ping_logic.nim kernel/abi/nimix_abi.h build/nimix_abi_stub.o
	@mkdir -p build/apps
	$(NIM_APP) --path:$(CURDIR)/servers/ping --path:$(CURDIR)/apps/nim -o:$@ $<

build/apps/ps.elf: apps/nim/ps/ps.nim kernel/abi/nimix_abi_stub.c build/nimix_abi_stub.o
	@mkdir -p build/apps
	$(NIM_APP) --path:$(CURDIR)/apps/nim/ps -o:$@ $<

build/apps/kill.elf: apps/nim/kill/kill.nim kernel/abi/nimix_abi_stub.c build/nimix_abi_stub.o
	@mkdir -p build/apps
	$(NIM_APP) --path:$(CURDIR)/apps/nim/kill -o:$@ $<

build/apps/stats.elf: apps/nim/stats/stats.nim kernel/abi/nimix_abi_stub.c build/nimix_abi_stub.o
	@mkdir -p build/apps
	$(NIM_APP) --path:$(CURDIR)/apps/nim/stats -o:$@ $<

build/apps/ls.elf: apps/nim/ls/ls.nim kernel/abi/nimix_abi_stub.c build/nimix_abi_stub.o
	@mkdir -p build/apps
	$(NIM_APP) --path:$(CURDIR)/apps/nim/ls -o:$@ $<

build/apps/top.elf: apps/nim/top/top.nim build/nimix_abi_stub.o
	@mkdir -p build/apps
	$(NIM_APP) --path:$(CURDIR)/apps/nim/top -o:$@ $<

build/apps/dispatch_server.elf: servers/dispatch/dispatch_server_elf.nim servers/dispatch/dispatch_logic.nim servers/dispatch/priority_queue.nim servers/dispatch/qos_policy.nim servers/dispatch/dispatch_wire.nim build/nimix_abi_stub.o
	@mkdir -p build/apps
	$(NIM_APP) --path:$(CURDIR)/servers/dispatch --path:$(CURDIR)/apps/nim -d:dispatchNoCps -o:$@ $<

build/apps/fs_server.elf: servers/fs/fs_server_elf.nim servers/fs/fs_logic.nim servers/dispatch/dispatch_wire.nim build/nimix_abi_stub.o
	@mkdir -p build/apps
	$(NIM_APP) --path:$(CURDIR)/servers/fs --path:$(CURDIR)/servers/dispatch --path:$(CURDIR)/apps/nim -o:$@ $<

apps: apps/ping/ping_embedded.nim

apps/ping/ping.wasm: apps/ping/ping.c
	$(CLANG_WASM) -o $@ $<

apps/ping/ping_embedded.nim: apps/ping/ping.wasm
	@echo "# SPDX-License-Identifier: GPL-2.0"                         > $@
	@echo "## Embedded ping.wasm — generated from apps/ping/ping.c"   >> $@
	@echo "## Rebuild with: make apps"                                 >> $@
	@python3 -c "                                                        \
	data = open('apps/ping/ping.wasm','rb').read();                      \
	print('const pingWasm*: array['+str(len(data))+', byte] = [');      \
	[print('  '+', '.join(f'0x{b:02x}' for b in data[i:i+16])+',')      \
	 for i in range(0,len(data),16)];                                    \
	print(']')"                                                        >> $@

# ── Compile kernel ────────────────────────────────────────────────
build: $(addprefix build/kernel-,$(KERNEL_MODELS))

# Build targets for each kernel model
build/kernel-%:
	$(NIM) $(NIM_FLAGS) -d:kernelModel=$* $(KERNEL_SRC)
	mv build/main $@

# ── Create bootable ISO ───────────────────────────────────────────
iso: $(ISO_OUT)

$(ISO_OUT): build/kernel-monolithic
	rm -rf iso
	mkdir -p iso/boot/grub
	cp build/kernel-monolithic iso/boot/kernel.elf
	printf 'set timeout=2\nset default=0\nmenuentry "NimixOS" { multiboot2 /boot/kernel.elf }\n' > iso/boot/grub/grub.cfg
	grub-mkrescue -o $(ISO_OUT) iso/
	rm -rf iso

# ── Create bootable ISO with all kernel variants ───────────────────────────────────────────
iso-all: $(ISO_ALL_OUT)

$(ISO_ALL_OUT): $(addprefix build/kernel-,$(KERNEL_MODELS))
	rm -rf iso
	mkdir -p iso/boot/kernel-variants
	cp build/kernel-monolithic iso/boot/kernel-variants/kernel-monolithic.elf
	cp build/kernel-sasos iso/boot/kernel-variants/kernel-sasos.elf
	cp build/kernel-microkernel iso/boot/kernel-variants/kernel-microkernel.elf
	mkdir -p iso/boot/grub
	echo 'set timeout=2' > iso/boot/grub/grub.cfg
	echo 'set default=0' >> iso/boot/grub/grub.cfg
	echo '' >> iso/boot/grub/grub.cfg
	echo 'menuentry "NimixOS (Monolithic - default)" {' >> iso/boot/grub/grub.cfg
	echo '    multiboot2 /boot/kernel-variants/kernel-monolithic.elf' >> iso/boot/grub/grub.cfg
	echo '}' >> iso/boot/grub/grub.cfg
	echo '' >> iso/boot/grub/grub.cfg
	echo 'menuentry "NimixOS (SASOS - software isolation)" {' >> iso/boot/grub/grub.cfg
	echo '    multiboot2 /boot/kernel-variants/kernel-sasos.elf' >> iso/boot/grub/grub.cfg
	echo '}' >> iso/boot/grub/grub.cfg
	echo '' >> iso/boot/grub/grub.cfg
	echo 'menuentry "NimixOS (Microkernel - hardware isolation)" {' >> iso/boot/grub/grub.cfg
	echo '    multiboot2 /boot/kernel-variants/kernel-microkernel.elf' >> iso/boot/grub/grub.cfg
	echo '}' >> iso/boot/grub/grub.cfg
	grub-mkrescue -o $(ISO_ALL_OUT) iso/
	rm -rf iso

# ── Run in QEMU (headless, serial only) ───────────────────────────
DISK ?= disk.img
DISK_FLAGS = $(if $(wildcard $(DISK)),-hda $(DISK),)

qemu: $(ISO_OUT)
	qemu-system-x86_64 -cdrom $(ISO_OUT) -bios $(OVMF) \
		$(DISK_FLAGS) \
		-no-reboot -m $(QEMU_MEM)M -serial stdio -display none

# ── Run in QEMU with all kernel variants ───────────────────────────────────────────
qemu-all: $(ISO_ALL_OUT)
	qemu-system-x86_64 -cdrom $(ISO_ALL_OUT) -bios $(OVMF) \
		$(DISK_FLAGS) \
		-no-reboot -m $(QEMU_MEM)M -serial stdio -display none

# ── Run in QEMU (with VGA) ────────────────────────────────────────
qemu-gui: $(ISO_OUT)
	qemu-system-x86_64 -cdrom $(ISO_OUT) -bios $(OVMF) \
		-no-reboot -m $(QEMU_MEM)M -serial stdio

# ── Run in QEMU with GDB server (paused at start) ─────────────────
qemu-debug: $(ISO_OUT)
	@echo "GDB: target remote :1234  —  symbol file: build/kernel-monolithic"
	qemu-system-x86_64 -cdrom $(ISO_OUT) -bios $(OVMF) \
		$(DISK_FLAGS) \
		-no-reboot -m $(QEMU_MEM)M -serial stdio -display none \
		-s -S

# ── Alias ─────────────────────────────────────────────────────────
run: all

# ── Disk image management ─────────────────────────────────────────
# Create a fresh FAT16 disk image (32 MB) with WASM apps
disk: $(DISK)

$(DISK):
	dd if=/dev/zero of=$(DISK) bs=512 count=65536
	mkfs.fat -F 16 -n NIMIXOS $(DISK)
	$(MAKE) disk-add-apps

# Add/update WASM and ELF files on the disk image (uses mtools — no sudo)
disk-add-apps: apps/ping/ping.wasm apps/pingpong/pingpong.wasm nim-apps
	MTOOLS_SKIP_CHECK=1 mcopy -oi $(DISK) apps/ping/ping.wasm apps/pingpong/pingpong.wasm ::
	MTOOLS_SKIP_CHECK=1 mcopy -oi $(DISK) build/apps/hello.elf build/apps/ps.elf build/apps/kill.elf build/apps/stats.elf build/apps/ls.elf build/apps/top.elf build/apps/dispatch_server.elf build/apps/fs_server.elf ::

# Add a single file: make disk-add FILE=myapp.wasm
disk-add:
	MTOOLS_SKIP_CHECK=1 mcopy -oi $(DISK) $(FILE) ::

# List disk contents
disk-ls:
	MTOOLS_SKIP_CHECK=1 mdir -i $(DISK) ::

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
	$(NIM) c -r $(TEST_FLAGS) tests/test_pci.nim
	$(NIM) c -r $(TEST_FLAGS) tests/test_pit.nim
	$(NIM) c -r $(TEST_FLAGS) tests/test_event_server.nim
	$(NIM) c -r $(TEST_FLAGS) tests/test_driver_registry.nim
	$(NIM) c -r $(TEST_FLAGS) tests/test_tss.nim
	$(NIM) c -r $(TEST_FLAGS) tests/test_server_chan.nim
	$(NIM) c -r $(TEST_FLAGS) tests/test_capability.nim
	$(NIM) c -r $(TEST_FLAGS) tests/test_cap_registry.nim
	$(NIM) c -r $(TEST_FLAGS) tests/test_region_allocator.nim
	$(NIM) c -r $(TEST_FLAGS) tests/test_sip_heap.nim
	$(NIM) c -r $(TEST_FLAGS) tests/test_zerocopy.nim
	$(NIM) c -r $(TEST_FLAGS) tests/test_stdlib_shim.nim
	$(NIM) c -r $(TEST_FLAGS) -d:testing tests/test_osalloc.nim
	$(NIM) c -r $(TEST_FLAGS) -d:testing tests/test_fd_table.nim
	$(NIM) c -r $(TEST_FLAGS) -d:testing tests/test_sync_ipc.nim
	$(NIM) c -r $(TEST_FLAGS) -d:testing tests/test_sleep.nim
	$(NIM) c -r $(TEST_FLAGS) tests/test_dispatch_queue.nim
	$(NIM) c -r $(TEST_FLAGS) tests/test_flatbuffers.nim
	$(NIM) c -r $(TEST_FLAGS) tests/test_msgpack_chan.nim
	$(NIM) c -r --skipParentCfg --mm:arc --panics:on --path:$(CURDIR) -d:noSignalHandler tests/test_cps_eval.nim
	$(NIM) c -r $(TEST_FLAGS) tests/test_fs_logic.nim
	$(NIM) c -r $(TEST_FLAGS) -d:noKernelHardware tests/test_fatfs_write.nim
	@echo "=== All tests passed ==="

TEST_FLAGS_ARC = --skipParentCfg --mm:arc --panics:on --path:$(CURDIR) --path:$(CURDIR)/apps/nim --nimblePath:$(HOME)/.nimble/pkgs2 -d:noSignalHandler

test-arc:
	@echo "=== NimixOS ARC Test Suite (dispatcher/CPS) ==="
	$(NIM) c -r $(TEST_FLAGS_ARC) tests/test_dispatch_logic.nim
	@echo "=== ARC tests passed ==="

# ── QEMU integration tests (serial pipe harness) ──────────────────
# Rebuilds nim apps and refreshes disk before booting so exec tests see
# up-to-date ELFs.
test-qemu: nim-apps disk-add-apps $(ISO_OUT)
	python3 tests/qemu_harness.py --iso $(ISO_OUT) --bios $(OVMF) \
		$(if $(wildcard $(DISK)),--disk $(DISK),)

# ── Clean ─────────────────────────────────────────────────────────
clean:
	rm -rf build/main build/kernel-* $(ISO_OUT) $(ISO_ALL_OUT) nimcache/ build/ iso/
