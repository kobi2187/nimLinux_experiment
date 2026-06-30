# SPDX-License-Identifier: GPL-2.0
## Boot Helpers - Early Debug and Parsing (called before runKernel)

import ../../core/types
import ../../core/debug
import ../../arch/common/boot_info
import ../../boot/bootloader

proc earlyLogMagic*(magicReg: uint32) =
  earlyPutString("[BOOT] magicReg = ");          earlyPutHex(uint64(magicReg));            earlyPutString("\n")
  earlyPutString("[BOOT] MULTIBOOT2_MAGIC = ");  earlyPutHex(uint64(MULTIBOOT2_MAGIC));    earlyPutString("\n")
  earlyPutString("[BOOT] MULTIBOOT1_MAGIC = ");  earlyPutHex(uint64(MULTIBOOT1_MAGIC_BOOT)); earlyPutString("\n")

proc earlyLogProtocol*(proto: BootloaderProtocol) =
  earlyPutString("[BOOT] Detected protocol: ")
  case proto
  of bpMultiboot1: earlyPutString("Multiboot1\n")
  of bpMultiboot2: earlyPutString("Multiboot2\n")
  of bpLimine:     earlyPutString("Limine\n")
  of bpUnknown:    earlyPutString("UNKNOWN\n")

proc earlyLogInfoPtr*(infoPtr: pointer) =
  earlyPutString("[BOOT] infoPtr = ");       earlyPutHex(cast[uint64](infoPtr)); earlyPutString("\n")
  earlyPutString("[BOOT] infoPtr & 0xFFF = ")
  earlyPutHex(uint64(cast[uint64](infoPtr) and 0xFFF))
  earlyPutString(" (should be 0 if page-aligned)\n")

proc earlyLogMb2Header*(infoPtr: pointer; proto: BootloaderProtocol) =
  if proto != bpMultiboot2: return
  let base = cast[uint64](infoPtr)
  let totalSize = cast[ptr uint32](base)[]
  earlyPutString("[INFO] Multiboot2: total_size="); earlyPutInt(int64(totalSize))
  earlyPutString(" end=0x"); earlyPutHex(base + uint64(totalSize)); earlyPutString("\n")

proc earlyDebug*(magicReg: uint32; infoPtr: pointer): BootloaderProtocol =
  earlyPutString("\n\n\n╔════════════════════════════════════════╗\n")
  earlyPutString("║        NimixOS Kernel — EARLY DEBUG   ║\n")
  earlyPutString("╚════════════════════════════════════════╝\n\n")
  earlyLogMagic(magicReg)
  let proto = detectProtocol(magicReg, infoPtr)
  earlyLogProtocol(proto)
  earlyLogInfoPtr(infoPtr)
  earlyLogMb2Header(infoPtr, proto)
  proto

proc fallbackBootInfo*(bi: var BootInfo) =
  for i in 0..<32: bi.bootProtocol[i] = '\0'
  let proto = "Fallback"
  for i in 0..<proto.len: bi.bootProtocol[i] = proto[i]
  bi.cpuCount = 1
  bi.memoryMap.count = 2
  bi.memoryMap.regions[0] = MemoryRegion(base: PhysAddr(0), length: 640 * KiB, regionType: memAvailable)
  bi.memoryMap.regions[1] = MemoryRegion(base: PhysAddr(1 * MiB), length: 127 * MiB, regionType: memAvailable)

proc parseOrFallback*(magicReg: uint32; infoPtr: pointer; bi: var BootInfo) =
  earlyPutString("\n[PARSE] Calling parseBootInfo...\n")
  let res = parseBootInfo(magicReg, infoPtr, bi)
  earlyPutString("[PARSE] parseBootInfo returned\n")
  if res.isErr:
    earlyPutString("[PARSE] ERROR: ")
    earlyPutString(cstring(bootErrorToString(res.error)))
    earlyPutString("\n")
    fallbackBootInfo(bi)
  else:
    earlyPutString("[PARSE] SUCCESS\n")
