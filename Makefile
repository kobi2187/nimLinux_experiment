# SPDX-License-Identifier: GPL-2.0
# NimixOS Makefile — fast development cycle
#
# Usage:
#   make          # build kernel, create ISO, boot in QEMU with UEFI+serial
#   make build    # just compile the kernel (all 3 models)
#   make apps     # compile WASM apps from C source → update embedded arrays
#   make iso      # create ISO from built kernel
#   make iso-all  # create ISO with all 3 kernel models in GRUB menu
#   make qemu     # boot ISO in QEMU (UEFI, serial, no display; DEVICES=all)
#   make qemu-gui # window + every virtio device
#   make qemu-debug / gdb-attach  # paused gdb stub :1234 / gdb with helpers
#   make symbolize LOG=serial.log # name the frames of a serial crash report
#   make test      # run host-side unit tests (test-valgrind, test-asan too)
#   make test-qemu # boot ISO in QEMU and run serial test suite
#   make test-devices # virtio devices verified on the host + crash reports
#   make clean     # remove build artifacts
#
# Config:
#   NIM      = path to nim compiler (default: nim on PATH)
#   OVMF     = path to OVMF.fd     (default: /usr/share/ovmf/OVMF.fd)
#   QEMU_MEM = memory in MB        (default: 256)

NIM     ?= nim
OVMF    ?= /usr/share/ovmf/OVMF.fd
QEMU_MEM ?= 256

# Nim flags for kernel build.
# DANGER is OFF by default so runtime checks (bounds/index/nil/assert) stay live
# and surface real defects on serial via panicoverride. Opt into the optimized,
# unchecked build with:  make DANGER=-d:danger   (or the `release` target).
DANGER ?=
# DEBUG=1: DWARF debug info for gdb source lines / addr2line (make gdb-attach).
DEBUG ?=
NIM_FLAGS = c --os:any --mm:arc --panics:on -d:StandaloneHeapSize=16777216 --passC:-fdata-sections \
            -d:release $(DANGER) $(if $(DEBUG),--debugger:native,) -d:kernelFull --noMain --outdir:build \
            --nimblePath:nimcache

# Kernel models to build
KERNEL_MODELS = microkernel sasos monolithic

# Source
KERNEL_SRC = kernel/init/main.nim
KERNEL_OUT = build/main
ISO_OUT    = nimixos.iso
ISO_ALL_OUT = nimixos-all-kernels.iso

.PHONY: all build apps nim-apps wasm-apps test-wasm iso iso-all qemu qemu-all qemu-gui qemu-debug gdb-attach symbolize run clean test test-valgrind test-asan test-qemu test-qemu-models test-devices test-arc test-p0 test-v7 test-v2 picolibc c-apps

# Default target: full cycle
all: build iso qemu

# ── Compile WASM apps from C source ──────────────────────────────
# Rebuilds .wasm from .c and regenerates the embedded Nim byte array.
CLANG_WASM = clang --target=wasm32 -nostdlib -Wl,--no-entry \
             -Wl,--export=_start -Wl,--allow-undefined -O2

# ── Regular apps: Nim → WASM ─────────────────────────────────────────────────
# Regular apps are WASM (sandboxed, capability-limited); system tools and
# servers are ELF. wasm32-wasi headers only (apt: wasi-libc) — nothing from
# WASI libc is linked: apps/wasm/nimix_wasm_rt.c supplies the few libc
# symbols, so a module imports only NimixOS host calls (env.*).
WASI_INCLUDE ?= /usr/include/wasm32-wasi
NIM_WASM = $(NIM) c --skipParentCfg --skipUserCfg --hints:off \
           --os:standalone --cpu:wasm32 --mm:arc --threads:off --noMain \
           -d:release -d:StandaloneHeapSize=65536 -d:nimAllocPagesViaMalloc \
           --cc:clang --clang.exe=clang --clang.linkerexe=clang \
           --passC:"--target=wasm32-wasi -nostdlib -isystem $(WASI_INCLUDE)" \
           --passL:"--target=wasm32-wasi -nostdlib -Wl,--no-entry \
                    -Wl,--export=_start -Wl,--allow-undefined"
WASM_APPS = build/apps/hello.wasm build/apps/cat.wasm

wasm-apps: $(WASM_APPS)

# Host tests for WASM apps (wasmtime; skipped when not installed).
test-wasm: wasm-apps
	python3 tests/test_wasm_apps.py build/apps

.SECONDEXPANSION:
build/apps/%.wasm: apps/wasm/$$*/$$*.nim apps/wasm/nimix_wasm.nim apps/wasm/nimix_wasm_rt.c kernel/abi/nimix_page_arena.h
	@mkdir -p build/apps
	$(NIM_WASM) -o:$@ $<

# ── Compile Nim userspace apps (PIE, --os:standalone) ────────────────────────
# --threads:off: NimixOS has fibers/actors, not OS threads, and sets up no TLS.
# With threads on, threadvars compile to %fs-relative loads (FS base = 0) and
# every app page-faulted on its first error-flag access.
# These are native Nim binaries that link against the kernel ABI.
# Always compiled as PIE so the SASOS loader can place them anywhere.
# Weak stub .o — provides nimixWrite/nimixExit/etc as weak symbols so the linker
# resolves them. The kernel loader overwrites them with jmp <real_addr> at runtime.
build/nimix_abi_stub.o: kernel/abi/nimix_abi_stub.c kernel/abi/nimix_abi_weak.c kernel/abi/nimix_page_arena.h
	@mkdir -p build
	gcc -c -fPIC -ffreestanding -fno-stack-protector -o $@ $<

# The same weak ABI stubs without Nim's mini-libc: for C programs (picolibc).
build/nimix_abi_weak.o: kernel/abi/nimix_abi_weak.c
	@mkdir -p build
	gcc -c -fPIC -ffreestanding -fno-stack-protector -o $@ $<

NIM_APP = $(NIM) c --skipParentCfg --skipUserCfg \
          --os:standalone --mm:arc --threads:off --cpu:amd64 --noMain \
          -d:StandaloneHeapSize=1048576 -d:nimAllocPagesViaMalloc \
          -d:noSignalHandler -d:nimNoLentIterators \
          --passC:"-ffreestanding -fno-stack-protector -mno-red-zone -fPIC -fno-omit-frame-pointer" \
          --passC:"-I$(CURDIR)/kernel/abi" \
          --passL:"-nostdlib -pie $(CURDIR)/build/nimix_abi_stub.o" \
          --path:$(CURDIR) \
          --path:$(CURDIR)/apps/nim \
          --nimblePath:$(HOME)/.nimble/pkgs2

NIM_TOOLS = ps kill stats ls top fault buftest clocktest

nim-apps: build/apps/ping_server.elf \
          $(addprefix build/apps/,$(addsuffix .elf,$(NIM_TOOLS))) \
          build/apps/dispatch_server.elf \
          build/apps/fs_server.elf build/apps/user_tests.elf
	@sh tests/check_heap_alignment.sh $^

# ── C apps: libnimix + picolibc (V2b) ───────────────────────────────────────
# Any C program can run on NimixOS: picolibc is the libc/libm, libnimix/ the OS
# layer under it (appMain, stdio, heap, time, files). Same code generation as the
# Nim apps (PIC, no red zone, frame pointers); the loader patches the weak ABI
# stubs in build/nimix_abi_stub.o and finds `appMain` by name, so the image must
# keep its symbol table (no strip).
PICOLIBC_INSTALL = build/picolibc/install
C_APPS = libctest fputest gfxtest rldemo
CC_INC := $(shell gcc -print-file-name=include)
LIBGCC := $(shell gcc -print-libgcc-file-name)
C_FLAGS = -O2 -Wall -Wextra -fPIC -ffreestanding -fno-stack-protector -mno-red-zone \
          -fno-omit-frame-pointer -ffunction-sections -fdata-sections -D_GNU_SOURCE -U_FORTIFY_SOURCE -nostdinc \
          -isystem $(PICOLIBC_INSTALL)/include -isystem $(CC_INC) \
          -I$(CURDIR)/kernel/abi -I$(CURDIR)/libnimix
LIBNIMIX_OBJS = $(patsubst libnimix/%.c,build/libnimix/%.o,$(wildcard libnimix/*.c))

$(PICOLIBC_INSTALL)/lib/libc.a:
	sh tools/picolibc_build.sh

build/libnimix/%.o: libnimix/%.c $(wildcard libnimix/*.h) kernel/abi/nimix_abi.h $(PICOLIBC_INSTALL)/lib/libc.a
	@mkdir -p $(dir $@)
	gcc $(C_FLAGS) -c -o $@ $<

build/libnimix/libnimix.a: $(LIBNIMIX_OBJS)
	ar rcs $@ $^


# ── raylib for NimixOS (V5b): PLATFORM_NIMIX = the memory platform + the display ABI ──
# tools/raylib_nimix.py builds a symlink view of vendor/raylib/src with the platform
# file generated from the pinned original (exact substitutions, see the script).
RAYLIB_NIMIX = build/raylib-nimix
RAYLIB_NIMIX_ABS = $(CURDIR)/build/raylib-nimix
# no rmodels: the 3D model module (a 2D UI toolkit never calls it) is most of the dead weight
RL_OBJS = $(addprefix $(RAYLIB_NIMIX)/,rcore.o rshapes.o rtextures.o rtext.o)

$(RAYLIB_NIMIX)/src/platforms/rcore_memory.c: tools/raylib_nimix.py vendor/raylib/src/platforms/rcore_memory.c
	python3 tools/raylib_nimix.py

$(RAYLIB_NIMIX)/%.o: $(RAYLIB_NIMIX)/src/platforms/rcore_memory.c $(PICOLIBC_INSTALL)/lib/libc.a kernel/abi/nimix_abi.h
	gcc $(C_FLAGS) -w -DPLATFORM_MEMORY -DGRAPHICS_API_OPENGL_SOFTWARE -DSUPPORT_MODULE_RAUDIO=0 -DSUPPORT_MODULE_RMODELS=0 \
	    -I$(RAYLIB_NIMIX_ABS)/src -c -o $@ $(RAYLIB_NIMIX_ABS)/src/$*.c

$(RAYLIB_NIMIX)/librl.a: $(RL_OBJS)
	ar rcs $@ $^

# per-app extras for the generic C-app rule below
LIBS_rldemo = $(RAYLIB_NIMIX)/librl.a
CFLAGS_rldemo = -I$(RAYLIB_NIMIX_ABS)/src

$(addprefix build/apps/,$(addsuffix .elf,$(C_APPS))): build/apps/%.elf: apps/c/$$*/$$*.c build/libnimix/libnimix.a build/nimix_abi_weak.o $$(LIBS_$$*)
	@mkdir -p build/apps
	gcc $(C_FLAGS) $(CFLAGS_$*) -c -o build/apps/$*.o $<
	gcc -nostdlib -pie -fPIC -Wl,--gc-sections -Wl,--strip-debug -Wl,-u,appMain -o $@ build/apps/$*.o $(LIBS_$*) build/libnimix/libnimix.a \
	    $(PICOLIBC_INSTALL)/lib/libc.a $(LIBGCC) build/nimix_abi_weak.o

c-apps: $(addprefix build/apps/,$(addsuffix .elf,$(C_APPS)))

NIM_APP_TEST = $(NIM_APP) -d:nimixUserspace

build/apps/user_tests.elf: tests/user_tests/main.nim tests/user_tests/panicoverride.nim tests/test_protocol.nim kernel/abi/nimix_abi.h build/nimix_abi_stub.o
	@mkdir -p build/apps
	$(NIM_APP_TEST) -o:$@ $<

build/apps/ping_server.elf: servers/ping/ping_server_elf.nim servers/ping/ping_logic.nim kernel/abi/nimix_abi.h build/nimix_abi_stub.o
	@mkdir -p build/apps
	$(NIM_APP) --path:$(CURDIR)/servers/ping --path:$(CURDIR)/apps/nim -o:$@ $<

# System tools: apps/nim/<name>/<name>.nim → build/apps/<name>.elf
$(addprefix build/apps/,$(addsuffix .elf,$(NIM_TOOLS))): build/apps/%.elf: apps/nim/$$*/$$*.nim kernel/abi/nimix_abi_stub.c build/nimix_abi_stub.o
	@mkdir -p build/apps
	$(NIM_APP) --path:$(CURDIR)/apps/nim/$* -o:$@ $<

build/apps/mount_test.elf: apps/mount_test.nim kernel/abi/nimix_abi_stub.c build/nimix_abi_stub.o
	@mkdir -p build/apps
	$(NIM_APP) -o:$@ $<

# cps tracing off: debug builds otherwise give EVERY continuation a 4096-entry
# trace deque — sized for a host malloc, not a 1 MB static app heap.
build/apps/dispatch_server.elf: servers/dispatch/dispatch_server_elf.nim servers/dispatch/dispatch_logic.nim servers/dispatch/priority_queue.nim servers/dispatch/qos_policy.nim servers/dispatch/dispatch_wire.nim runtime/actor.nim ipc/mailbox.nim build/nimix_abi_stub.o
	@mkdir -p build/apps
	$(subst --os:standalone,--os:any,$(NIM_APP)) --panics:on \
		-d:cpsTraceDeque=false -d:cpsStackFrames=false \
		--path:$(CURDIR)/servers/dispatch --path:$(CURDIR)/apps/nim -o:$@ $<

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
# Default `build` keeps runtime checks ON (DANGER empty) for observable defects.
build: $(addprefix build/kernel-,$(KERNEL_MODELS))
	@sh tests/check_heap_alignment.sh $^

# Optimized, unchecked build (production). Runtime checks compiled out.
release:
	$(MAKE) build DANGER=-d:danger

# Build targets for each kernel model. FORCE: the rules list no Nim sources,
# so without it a stale kernel is never rebuilt (nim's own cache keeps it fast).
build/kernel-%: FORCE
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

# One ISO per kernel model (for automated testing of each model).
nimixos-%.iso: build/kernel-%
	rm -rf build/iso-$*
	mkdir -p build/iso-$*/boot/grub
	cp build/kernel-$* build/iso-$*/boot/kernel.elf
	printf 'set timeout=0\nset default=0\nmenuentry "NimixOS $*" { multiboot2 /boot/kernel.elf }\n' > build/iso-$*/boot/grub/grub.cfg
	grub-mkrescue -o $@ build/iso-$*/ 2>/dev/null
	rm -rf build/iso-$*

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

# ── Run in QEMU — every target goes through tools/nimix_qemu.py ──────────────
# DEVICES: comma list of blk,net,gpu,snd,input or "all" (virtio-pci).
# Extra launcher flags: QEMU_ARGS="--pcap n.pcap --wav a.wav --log" etc.
DISK ?= disk.img
DEVICES ?= blk
GDB_PORT ?= 1234
LAUNCH = python3 tools/nimix_qemu.py run --bios $(OVMF) --mem $(QEMU_MEM) \
         --disk $(DISK) --devices $(DEVICES) $(QEMU_ARGS)

qemu: $(ISO_OUT) $(DISK)
	$(LAUNCH) --iso $(ISO_OUT)

qemu-all: $(ISO_ALL_OUT) $(DISK)
	$(LAUNCH) --iso $(ISO_ALL_OUT)

# Window + every virtio device (the virtio-gpu head shows `devtest gpu`).
qemu-gui: $(ISO_OUT) $(DISK)
	$(LAUNCH) --iso $(ISO_OUT) --gui --devices all

# Paused at reset with the gdb stub; attach from another terminal: make gdb-attach
qemu-debug: $(ISO_OUT) $(DISK)
	$(LAUNCH) --iso $(ISO_OUT) --gdb wait --gdb-port $(GDB_PORT)

# gdb with kernel symbols + NimixOS helpers (nimix-help). Build with DEBUG=1
# for source lines. GDB_KERNEL= to pick another model's ELF.
GDB_KERNEL ?= build/kernel-monolithic
gdb-attach:
	gdb -q -ex "set confirm off" -ex "file $(GDB_KERNEL)" -ex "source tools/gdb/nimix.gdb" \
	    -ex "target remote :$(GDB_PORT)" -ex "nimix-help"

# Symbolize a saved serial log: make symbolize LOG=serial.log [APP=build/apps/x.elf]
symbolize:
	python3 tools/symbolize.py $(LOG) --kernel $(GDB_KERNEL) $(if $(APP),--app $(APP),)

run: all

# ── Disk image management ─────────────────────────────────────────
# Create a fresh FAT16 disk image (32 MB) with WASM apps
disk: $(DISK)

$(DISK):
	dd if=/dev/zero of=$(DISK) bs=512 count=65536
	mkfs.fat -F 16 -n NIMIXOS $(DISK)
	$(MAKE) disk-add-apps

# Add/update WASM and ELF files on the disk image (uses mtools — no sudo)
# Regular apps (.wasm) + system tools and servers (.elf) + sample data.
disk-add-apps: apps/ping/ping.wasm apps/pingpong/pingpong.wasm nim-apps c-apps wasm-apps
	MTOOLS_SKIP_CHECK=1 mcopy -oi $(DISK) apps/ping/ping.wasm apps/pingpong/pingpong.wasm $(WASM_APPS) ::
	MTOOLS_SKIP_CHECK=1 mcopy -oi $(DISK) $(addprefix build/apps/,$(addsuffix .elf,$(NIM_TOOLS))) build/apps/dispatch_server.elf build/apps/fs_server.elf build/apps/ping_server.elf build/apps/user_tests.elf $(addprefix build/apps/,$(addsuffix .elf,$(C_APPS))) ::
	MTOOLS_SKIP_CHECK=1 mcopy -oi $(DISK) apps/data/notes.txt ::

# Add a single file: make disk-add FILE=myapp.wasm
disk-add:
	MTOOLS_SKIP_CHECK=1 mcopy -oi $(DISK) $(FILE) ::

# List disk contents
disk-ls:
	MTOOLS_SKIP_CHECK=1 mdir -i $(DISK) ::

# ── Unit tests (host, no QEMU needed) ────────────────────────────
# Uses --skipParentCfg to bypass kernel nim.cfg (-nostdlib, kernel.ld, etc.)
TEST_FLAGS = --skipParentCfg --mm:refc --path:$(CURDIR) --nimblePath:$(HOME)/.nimble/pkgs2 -d:noSignalHandler

HOST_TESTS = \
  tests/test_log.nim \
  tests/test_klog_ring.nim \
  tests/test_buffers_api.nim \
  tests/test_buffers_state.nim \
  tests/test_buffers_arena.nim \
  tests/test_buffers_ring.nim \
  tests/test_gfx.nim \
  tests/test_term.nim \
  tests/test_keymap.nim \
  tests/test_vga_text.nim \
  tests/test_traits.nim \
  tests/test_ps2_keyboard.nim \
  tests/test_ps2_mouse.nim \
  tests/test_pic.nim \
  tests/test_pci.nim \
  tests/test_pit.nim \
  tests/test_tsc_clock.nim \
  tests/test_display_checks.nim \
  tests/test_event_server.nim \
  tests/test_driver_registry.nim \
  tests/test_module_loader.nim \
  tests/test_kernel_module_integration.nim \
  tests/test_tss.nim \
  tests/test_server_chan.nim \
  tests/test_capability.nim \
  tests/test_cap_registry.nim \
  tests/test_region_allocator.nim \
  tests/test_sip_heap.nim \
  tests/test_zerocopy.nim \
  tests/test_stdlib_shim.nim \
  tests/test_dispatch_queue.nim \
  tests/test_flatbuffers.nim \
  tests/test_msgpack_chan.nim \
  tests/test_mailbox.nim \
  tests/test_audio_logic.nim \
  tests/test_fs_logic.nim \
  tests/test_virtio.nim \
  tests/test_bit_intrinsics.nim \
  tests/test_user_window.nim \
  tests/test_ramfs.nim
HOST_TESTS_TESTING = \
  tests/test_osalloc.nim \
  tests/test_fd_table.nim \
  tests/test_sync_ipc.nim \
  tests/test_sleep.nim
HOST_TESTS_NOHW = \
  tests/test_fatfs_write.nim \
  tests/test_virtio_pci.nim \
  tests/test_rtc.nim \
  tests/test_syscall_table.nim \
  tests/test_elf_loader.nim \
  tests/test_vfs_btree.nim

# $(call host_tests,<extra nim flags>,<runner>) — every host test once; with a
# runner (e.g. valgrind) build only, then run the binary under it.
# Every test runs through tools/check_run.sh: a test that dies on an unhandled
# exception must fail the build even when its exit code says 0 (see that script).
CHECK = sh $(CURDIR)/tools/check_run.sh
define host_tests
	@set -e; for t in $(HOST_TESTS); do \
	  $(NIM) c $(TEST_FLAGS) $(1) $$t; $(CHECK) $(2) ./$${t%.nim}; done
	@set -e; for t in $(HOST_TESTS_TESTING); do \
	  $(NIM) c $(TEST_FLAGS) -d:testing $(1) $$t; $(CHECK) $(2) ./$${t%.nim}; done
	@set -e; for t in $(HOST_TESTS_NOHW); do \
	  $(NIM) c $(TEST_FLAGS) -d:noKernelHardware $(1) $$t; $(CHECK) $(2) ./$${t%.nim}; done
endef

test:
	@echo "=== NimixOS Test Suite ==="
	$(call host_tests,,)
	$(NIM) c --skipParentCfg --mm:arc --panics:on --path:$(CURDIR) -d:noSignalHandler tests/test_cps_eval.nim
	$(CHECK) ./tests/test_cps_eval
	@echo "=== All tests passed ==="

# ── Native debugging of host-testable code ───────────────────────────────────
# Same host tests, built with the system allocator (-d:useMalloc) so the tools
# see every allocation. valgrind: memcheck, any error fails the run.
# asan: AddressSanitizer + UBSan (clang/gcc), aborts on the first error.
VALGRIND ?= valgrind --error-exitcode=1 --leak-check=full --errors-for-leak-kinds=definite --quiet \
           --suppressions=$(CURDIR)/tests/valgrind.supp   # Nim refc stack scan only
SAN_FLAGS = -d:useMalloc --debugger:native --passC:"-fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=undefined" --passL:"-fsanitize=address,undefined"

test-valgrind:
	@echo "=== Host tests under valgrind memcheck ==="
	$(call host_tests,-d:useMalloc --debugger:native,$(VALGRIND))
	@echo "=== valgrind: clean ==="

test-asan:
	@echo "=== Host tests under ASan + UBSan ==="
	$(call host_tests,$(SAN_FLAGS),)
	@echo "=== ASan/UBSan: clean ==="

TEST_FLAGS_ARC = --skipParentCfg --mm:arc --panics:on --path:$(CURDIR) --path:$(CURDIR)/apps/nim --nimblePath:$(HOME)/.nimble/pkgs2 -d:noSignalHandler

test-arc:
	@echo "=== NimixOS ARC Test Suite (dispatcher/CPS) ==="
	$(NIM) c $(TEST_FLAGS_ARC) tests/test_dispatch_logic.nim; $(CHECK) ./tests/test_dispatch_logic
	$(NIM) c $(TEST_FLAGS_ARC) tests/test_actor.nim; $(CHECK) ./tests/test_actor
	$(NIM) c $(TEST_FLAGS_ARC) --threads:on tests/test_mpsc_ring.nim; $(CHECK) ./tests/test_mpsc_ring
	@echo "=== ARC tests passed ==="

# Actor/CPS performance benchmark (release build; validates dispatcher cost model)
bench-arc:
	$(NIM) c -r $(TEST_FLAGS_ARC) -d:release tests/bench_actor.nim

# ── QEMU integration tests (serial pipe harness) ──────────────────
# Rebuilds nim apps and refreshes disk before booting so exec tests see
# up-to-date ELFs.
test-qemu: nim-apps disk-add-apps $(ISO_OUT)
	python3 tests/qemu_harness.py --iso $(ISO_OUT) --bios $(OVMF) \
		$(if $(wildcard $(DISK)),--disk $(DISK) --virtio-blk,)

# Same suite against every kernel model (vision goal 2: models interchangeable).
test-qemu-models: nim-apps disk-add-apps $(addprefix nimixos-,$(addsuffix .iso,$(KERNEL_MODELS)))
	@for m in $(KERNEL_MODELS); do echo "=== model: $$m ==="; \
	  python3 tests/qemu_harness.py --iso nimixos-$$m.iso --bios $(OVMF) \
	    --disk $(DISK) --virtio-blk || exit 1; done

# Every virtio device verified on the HOST (screendump pixels, wav tone, pcap
# frame, injected keys) + crash reports symbolized. See tests/qemu_devices.py.
test-devices: disk-add-apps $(ISO_OUT) build/term_replay build/v5/rldemo_host.ppm
	python3 tests/qemu_devices.py --iso $(ISO_OUT) --bios $(OVMF)

# The host reference for the raylib demo: the same scene drawn by raylib's own memory
# platform on the host. The NimixOS screendump must equal it (tests/qemu_devices.py).
build/v5/rldemo_host: tests/v5/rldemo_host.c apps/c/rldemo/rldemo_scene.h
	@mkdir -p build/v5
	gcc -O2 -w -DPLATFORM_MEMORY -DGRAPHICS_API_OPENGL_SOFTWARE -DSUPPORT_MODULE_RAUDIO=0 -D_GNU_SOURCE \
	    -I$(CURDIR)/vendor/raylib/src -I$(CURDIR)/apps/c/rldemo -o $@ $< \
	    $(addprefix $(CURDIR)/vendor/raylib/src/,rcore.c rshapes.c rtextures.c rtext.c rmodels.c) -lm

build/v5/rldemo_host.ppm: build/v5/rldemo_host
	./build/v5/rldemo_host $@ > /dev/null

# Host renderer of a console byte stream (same term/gfx code as the kernel).
build/term_replay: tools/term_replay.nim term/vt.nim term/term_render.nim gfx/canvas.nim gfx/bitmap_font.nim gfx/font_spleen8x16.nim gfx/utf8.nim
	@mkdir -p build
	$(NIM) c --skipParentCfg --skipProjCfg --hints:off --mm:arc -d:release -o:$@ $<

# Regenerate the console font from its BDF source.
gfx/font_spleen8x16.nim: vendor/fonts/spleen-8x16.bdf tools/bdf2nim.py
	python3 tools/bdf2nim.py $< spleen8x16 > $@

# P0: raylib bridge loopback (host only) — remote pixels == direct pixels and
# the steady-state frame within VISION's command budgets (BACKLOG P0).
test-v7:
	NIM=$(NIM) sh tests/v7/run_v7.sh

# libc/libm for server ELFs: picolibc (vendor/picolibc) builds, raylib+rlsw link against it,
# its libm is accurate. Needs meson + ninja.
picolibc:
	sh tools/picolibc_build.sh

test-v2:
	sh tests/v2/run_v2.sh

test-p0:
	NIM=$(NIM) sh tests/p0/run_p0.sh

# ── Structured in-kernel test suite ───────────────────────────────
# Boots a testMode kernel, parses TEST PASS/FAIL/DONE from serial.
TESTMODE_ISO = build/nimixos-test.iso

$(TESTMODE_ISO): build/kernel-test
	@mkdir -p iso/boot/grub
	cp build/kernel-test iso/boot/kernel.elf
	echo 'set timeout=0' > iso/boot/grub/grub.cfg
	echo 'set default=0' >> iso/boot/grub/grub.cfg
	echo 'menuentry "NimixOS testMode" { multiboot2 /boot/kernel.elf }' >> iso/boot/grub/grub.cfg
	grub-mkrescue -o $(TESTMODE_ISO) iso/ 2>/dev/null
	rm -rf iso

build/kernel-test: FORCE
	$(NIM) $(NIM_FLAGS) -d:kernelModel=monolithic -d:testMode $(KERNEL_SRC)
	mv build/main $@

test-structured: $(TESTMODE_ISO) disk-add-apps
	python3 tests/qemu_harness.py --iso $(TESTMODE_ISO) --bios $(OVMF) \
		--structured --timeout 30 \
		$(if $(wildcard $(DISK)),--disk $(DISK) --virtio-blk,)

# ── Debugging (see tests/qemu_debug.py) ───────────────────────────
# debug-log: autopsy — boots with -d int,cpu_reset,guest_errors -no-reboot and
#   captures faults/exceptions/CPU-state + a clean serial transcript. First tool
#   to reach for on a silent fault or triple fault. Override DISK= to attach one.
debug-log: $(ISO_OUT) disk-add-apps
	python3 tests/qemu_debug.py log --iso $(ISO_OUT) --bios $(OVMF) --timeout 30 \
		$(if $(wildcard $(DISK)),--disk $(DISK) --virtio-blk,) $(if $(UNTIL),--until "$(UNTIL)",)

# debug-log-test: same, but on the testMode kernel (catches early-boot faults).
debug-log-test: $(TESTMODE_ISO) disk-add-apps
	python3 tests/qemu_debug.py log --iso $(TESTMODE_ISO) --bios $(OVMF) --timeout 30 \
		--kernel build/kernel-test \
		$(if $(wildcard $(DISK)),--disk $(DISK) --virtio-blk,) $(if $(UNTIL),--until "$(UNTIL)",)

# debug-gdb: scalpel — boots paused with the GDB stub (:1234) + a .gdbinit that
#   loads kernel symbols and sets breakpoints. Attach with the printed command.
debug-gdb: $(ISO_OUT) disk-add-apps
	python3 tests/qemu_debug.py gdb --iso $(ISO_OUT) --bios $(OVMF) \
		--kernel build/kernel-monolithic \
		$(if $(wildcard $(DISK)),--disk $(DISK) --virtio-blk,)

# debug-qmp: automation — boot, wait for UNTIL=, run a MONITOR= command, quit.
debug-qmp: $(ISO_OUT) disk-add-apps
	python3 tests/qemu_debug.py qmp --iso $(ISO_OUT) --bios $(OVMF) --timeout 30 \
		$(if $(wildcard $(DISK)),--disk $(DISK) --virtio-blk,) \
		$(if $(UNTIL),--until "$(UNTIL)",) $(if $(MONITOR),--monitor "$(MONITOR)",)

# ── Clean ─────────────────────────────────────────────────────────
clean:
	rm -rf build/main build/kernel-* $(ISO_OUT) $(ISO_ALL_OUT) nimcache/ build/ iso/ qemu-debug/

FORCE:
