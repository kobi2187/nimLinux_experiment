# NimixOS Research - Key Sources Quick Reference

## Must-Study Nim Kernel Projects

### Primary Reference Implementations

| Project | Link | Stars/Status | Key Features | Priority |
|---------|------|--------------|--------------|----------|
| **Axiom** | https://github.com/khaledh/axiom | 64-bit Nim kernel | UEFI, Hardware detection, ACPI, PCI, VGA, AHCI | ⭐⭐⭐ CRITICAL |
| **Fusion OS** | https://github.com/khaledh/fusion | 64-bit Nim OS | Memory management, Scheduling, Multitasking, ELF loader, Docs | ⭐⭐⭐ CRITICAL |
| **Fusion Docs** | https://0xc0ffee.netlify.app/osdev/ | Tutorial/Guide | Step-by-step kernel development walkthrough | ⭐⭐⭐ CRITICAL |
| **nimkernel** | https://github.com/dom96/nimkernel | Simple starter kernel | Basic bootloader, text output, error handling | ⭐⭐ Good for learning |

---

## Core Libraries & Tools

### Synchronization & Concurrency

| Library | Link | Type | Features | Status |
|---------|------|------|----------|--------|
| **arsenal** | https://github.com/kobi2187/arsenal | Dependency | RWLock, SPSC/MPMC queues | ✅ Integrated |
| **nimsync** | https://github.com/codenimja/nimsync | Alternative | Lock-free async runtime | Production-ready v1.1.0 |
| **lockfreequeues** | https://github.com/elijahr/lockfreequeues | Alternative | SPSC/MPSC queues | Stable |

### Hardware & Communication

| Library | Link | Type | Purpose |
|---------|------|------|---------|
| **serial.nim** | https://github.com/euantorano/serial.nim | Communication | Serial port/UART I/O |
| **serialport** | https://github.com/nimious/serialport | Communication | libserialport FFI bindings |

### C Interoperability Tools

| Tool | Link | Purpose |
|------|------|---------|
| **nimterop** | https://github.com/nimterop/nimterop | Automatic C/C++ wrapper generation |
| **c2nim** | https://github.com/nim-lang/c2nim | C to Nim translation tool |

### Filesystem Reference (C-based, for binding or study)

| Library | Link | Format | Status |
|---------|------|--------|--------|
| **lwext4** | https://github.com/gkostka/lwext4 | ext2/3/4 | Microcontroller-optimized |

---

## Language Documentation & Guides

### Nim Official Documentation

| Resource | Link | Content |
|----------|------|---------|
| Nim Compiler Docs | https://nim-lang.org/docs/nimc.html | Cross-compilation, build system |
| Inline Assembly | https://nim-lang.github.io/Nim/manual_experimental.html | ASM integration guide |
| Atomic Operations | https://vladar4.github.io/sdl2_nim/private/atomics.html | Atomic operations API |
| unittest Module | https://nim-lang.org/docs/unittest.html | Built-in testing framework |
| logging Module | https://nim-lang.org/docs/logging.html | Logging infrastructure |
| tables Module | https://nim-lang.org/docs/tables.html | Hash maps and collections |
| bitops Module | https://nim-lang.org/docs/bitops.html | Bit manipulation utilities |
| dynlib Module | https://nim-lang.org/docs/dynlib.html | Dynamic library symbols |

### Nim Metaprogramming & Advanced Features

| Resource | Link | Topic |
|----------|------|-------|
| Metaprogramming Intro | https://hookrace.net/blog/introduction-to-metaprogramming-in-nim/ | Macros and templates |
| Nim Tutorial Part III | https://nim-lang.org/docs/tut3.html | Advanced metaprogramming |
| Macros Documentation | https://nim-lang.org/docs/macros.html | Macro API reference |
| OOP Documentation | https://nim-by-example.github.io/oop/ | Object-oriented patterns |
| Strings Guide | https://nim-by-example.github.io/strings/ | String handling patterns |

### Cross-Compilation & Build

| Resource | Link | Focus |
|----------|------|-------|
| Cross-Compilation Adventures | https://crushingcode.nisrulz.com/blog/cross-compilation-adventures/ | Practical cross-compilation |
| UEFI Bootloader Nim | https://0xc0ffee.netlify.app/osdev/05-bootloader-p1 | Nim UEFI bootloader guide |

---

## Hardware/Architecture References (General)

### Essential x86_64 Resources

| Resource | Link | Topic |
|----------|------|-------|
| **OSDev IDT** | https://wiki.osdev.org/Interrupt_Descriptor_Table | IDT structure and implementation |
| **OSDev Interrupts** | https://wiki.osdev.org/Interrupts_Tutorial | x86 interrupt handling |
| **OSDev ELF** | https://wiki.osdev.org/ELF_Tutorial | ELF format and loading |
| **OSDev Ext2/Ext4** | https://wiki.osdev.org/Ext2 / https://wiki.osdev.org/Ext4 | Filesystem specifications |
| **OSDev Multiboot** | https://wiki.osdev.org/Multiboot | Multiboot specification |
| **OSDev Spinlock** | https://wiki.osdev.org/Spinlock | Spinlock implementation |

### Linux Kernel References

| Resource | Link | Topic |
|----------|------|-------|
| **Linux Insides** | https://0xax.gitbooks.io/linux-insides/content/KernelStructures/linux-kernelstructure-1.html | Linux kernel IDT implementation |
| **Linux Devicetree** | https://kernel.org/doc/html//v5.17/firmware-guide/acpi/enumeration.html | Device enumeration |
| **Linux ACPI** | https://www.kernel.org/doc/Documentation/acpi/enumeration.txt | ACPI specifications |

### Bootloader & Firmware

| Resource | Link | Purpose |
|----------|------|---------|
| **Simple UEFI Bootloader** | https://github.com/KunYi/Simple-UEFI-Bootloader | Reference UEFI bootloader |
| **Multiboot Spec** | https://www.gnu.org/software/grub/manual/multiboot/multiboot.html | Multiboot specification |
| **Multiboot2 Spec** | https://www.gnu.org/software/grub/manual/multiboot2/multiboot.html | Multiboot2 specification |

### Device Support

| Resource | Link | Topic |
|----------|------|-------|
| **Devicetree Spec** | https://devicetree-specification.readthedocs.io/en/v0.1/flattened-format.html | Flat device tree format |
| **Kaitai Struct DTB** | https://formats.kaitai.io/dtb/ | Auto-generated DTB parser |

---

## Testing & Debugging Tools

### Testing Frameworks

| Framework | Link | Type | Status |
|-----------|------|------|--------|
| **unittest** | https://nim-lang.org/docs/unittest.html | Built-in | Lightweight, included |
| **unittest2** | https://github.com/status-im/nim-unittest2 | Third-party | Enhanced, xUnit-inspired |
| **Testament** | https://nim-lang.org/docs/testament.html | Third-party | Advanced, process isolation |
| **Einheit** | https://github.com/jyapayne/einheit | Third-party | Python unittest-inspired |

### QEMU & GDB Debugging

| Resource | Link | Focus |
|----------|------|-------|
| **QEMU GDB Guide** | https://medium.com/@alessandrozanni.dev/setup-linux-kernel-debugging-with-qemu-and-gdb-e5446c16cd85 | Kernel debugging setup |
| **QEMU Docs** | https://qemu-project.gitlab.io/qemu/system/gdb.html | QEMU GDB interface |
| **Linux Kernel Debugging** | https://nickdesaulniers.github.io/blog/2018/10/24/booting-a-custom-linux-kernel-in-qemu-and-debugging-it-with-gdb/ | Full debugging guide |
| **GDB Kernel Debugging** | https://www.kernel.org/doc/html/latest/process/debugging/gdb-kernel-debugging.html | GDB kernel utilities |

---

## Nim Community & Forums

| Resource | Link | Purpose |
|----------|------|---------|
| **Nim Forum** | https://forum.nim-lang.org/ | General community discussions |
| **Fusion OS Thread** | https://forum.nim-lang.org/t/12000 | Hobby kernel in Nim discussion |
| **Linux Kernel Module** | https://forum.nim-lang.org/t/10303 | Nim in kernel module context |
| **Inline Assembly** | https://forum.nim-lang.org/t/2441 | Inline ASM discussion |
| **String Handling** | https://forum.nim-lang.org/t/626 | Nim string implementation |

---

## Package Discovery

| Resource | Link | Purpose |
|----------|------|---------|
| **Nimble Directory** | https://nimble.directory/ | Official Nimble package registry |
| **NimPkgs** | https://nimpkgs.dayl.in/ | Alternative package search |
| **Nimble GitHub** | https://github.com/nim-lang/nimble | Package manager source |

---

## Architecture Support Status

| Architecture | Support | Notes |
|--------------|---------|-------|
| x86_64 | ✅ Full | All NimixOS work targets this |
| ARM64 | ✅ Growing | Binaries available |
| RISC-V 64 | ✅ Since 2018 | Mature support |
| RISC-V 32 | ❌ Not yet | Feature request exists |

---

## Quick Category Finder

### Need interrupt handling?
→ OSDev Wiki + Study Axiom/Fusion

### Need memory management?
→ Study Fusion OS memory implementation + Linux Insides

### Need scheduling?
→ Study Fusion OS scheduler + check archive for Linux process scheduling

### Need device drivers?
→ Study Axiom PCI/AHCI + create Nim patterns

### Need filesystems?
→ OSDev Wiki specs + lwext4 for reference + consider Kaitai Struct

### Need testing?
→ Testament + QEMU + GDB + unittest module

### Need synchronization?
→ arsenal (already integrated) + study spinlock.nim

### Need C library binding?
→ nimterop or c2nim

### Need serial debugging?
→ serial.nim library

### Need build system?
→ Current nimble setup good, consider linker script helpers

---

## Recommended Reading Order

1. **First Week**: Axiom & Fusion OS source code (understand architecture decisions)
2. **Second Week**: Fusion OS documentation (0xc0ffee.netlify.app) + OSDev Wiki
3. **Parallel**: Nim language features documentation for kernel programming
4. **As Needed**: Hardware-specific resources (x86_64, ACPI, PCI, etc.)

---

**Generated**: February 2026
**Last Updated**: Research completion
**Format**: Quick reference with 50+ key sources
