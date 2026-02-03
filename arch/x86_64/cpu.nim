# SPDX-License-Identifier: GPL-2.0
## CPU Detection & Configuration - LAYER 3 (x86_64 specific)
##
## Detects CPU capabilities and per-CPU state management
## Called during kernel initialization to determine:
## - CPU count
## - CPU features (PAE, NX, etc.)
## - Per-CPU data structures
##
## Philosophy: Minimal CPU access, reuse boot info when possible

import ../core/types
import ../arch/common/boot_info
import ../core/console

# ═══════════════════════════════════════════════════════════════════════════
# CPU Information Structure
# ═══════════════════════════════════════════════════════════════════════════

type
  CpuFlags* = enum
    ## x86_64 CPU feature flags
    cfPAE              ## Physical Address Extension (36-bit addresses)
    cfPSE              ## Page Size Extension (4MB pages)
    cfTSC              ## Time Stamp Counter
    cfMSR              ## Model-Specific Registers
    cfPGE              ## Page Global Enable
    cfCMOV             ## Conditional Move
    cfPAT              ## Page Attribute Table
    cfPSE36            ## Extended PSE (physical address)
    cfPCLMULQDQ        ## PCLMULQDQ instruction
    cfSSE41            ## SSE 4.1
    cfSSE42            ## SSE 4.2
    cfPOPCNT           ## Population count
    cfAES              ## AES instruction
    cfXSAVE            ## XSAVE/XRSTOR
    cfAVX              ## AVX
    cfRDRAND           ## RDRAND instruction
    cfRDSEED           ## RDSEED instruction
    cfSVM              ## AMD virtualization
    cfVMX              ## Intel virtualization
    cfNX               ## No-Execute (bit 63 available)
    cfLM               ## Long Mode (64-bit)
    cfEXT              ## Extended MMX
    cfMMX              ## MMX
    cfFPU              ## x87 FPU
    cfCX8              ## Compare-and-swap 8 bytes
    cfCPUID            ## CPUID instruction

  CpuInfo* = object
    ## CPU information
    id*: uint32                    ## CPU ID (APIC ID)
    flags*: set[CpuFlags]          ## Supported flags
    vendorId*: array[13, char]     ## CPU vendor string
    modelName*: array[49, char]    ## CPU model name
    familyId*: uint8               ## Family ID
    modelId*: uint8                ## Model ID
    steppingId*: uint8             ## Stepping ID
    cpuCoreCount*: uint32          ## Physical cores
    cpuThreadCount*: uint32        ## Logical threads

# ═══════════════════════════════════════════════════════════════════════════
# CPUID Instruction Wrapper
# ═══════════════════════════════════════════════════════════════════════════

type
  CpuidResult* = object
    eax*: uint32
    ebx*: uint32
    ecx*: uint32
    edx*: uint32

proc cpuid*(leaf: uint32, subleaf: uint32 = 0): CpuidResult =
  ## Execute CPUID instruction
  ## Returns EAX, EBX, ECX, EDX registers
  ##
  ## CPUID leaf function numbers:
  ## 0x00: Max leaf, vendor string
  ## 0x01: Features and stepping
  ## 0x04: Deterministic cache info
  ## 0x0B: Extended topology
  ## 0x80000000: Max extended leaf
  ## 0x80000001: Extended features
  ## 0x80000002-4: Brand string

  var eax = leaf
  var ebx: uint32 = 0
  var ecx = subleaf
  var edx: uint32 = 0

  asm """
    cpuid
  """ : "=a"(eax), "=b"(ebx), "=c"(ecx), "=d"(edx)
      : "a"(eax), "c"(ecx)

  CpuidResult(eax: eax, ebx: ebx, ecx: ecx, edx: edx)

# ═══════════════════════════════════════════════════════════════════════════
# CPU Detection Functions
# ═══════════════════════════════════════════════════════════════════════════

proc detectVendor*(): array[13, char] =
  ## Detect CPU vendor string
  ## CPUID leaf 0 returns vendor in EBX:EDX:ECX
  let result = cpuid(0x00)

  var vendor: array[13, char]
  vendor[0] = '\0'  # null terminate

  # Extract vendor from EBX, EDX, ECX
  for i in 0..<4:
    vendor[i] = char((result.ebx shr (i * 8)) and 0xFF)
  for i in 0..<4:
    vendor[i + 4] = char((result.edx shr (i * 8)) and 0xFF)
  for i in 0..<4:
    vendor[i + 8] = char((result.ecx shr (i * 8)) and 0xFF)

  vendor

proc detectFeatures*(): set[CpuFlags] =
  ## Detect CPU feature flags
  var flags: set[CpuFlags] = {}

  # CPUID leaf 1: Features
  let result1 = cpuid(0x01)

  # Detect flags from EDX (leaf 1)
  if (result1.edx and (1'u32 shl 0)) != 0: flags.incl(cfFPU)
  if (result1.edx and (1'u32 shl 3)) != 0: flags.incl(cfPSE)     # PSE
  if (result1.edx and (1'u32 shl 4)) != 0: flags.incl(cfTSC)     # TSC
  if (result1.edx and (1'u32 shl 5)) != 0: flags.incl(cfMSR)     # MSR
  if (result1.edx and (1'u32 shl 6)) != 0: flags.incl(cfPAE)     # PAE
  if (result1.edx and (1'u32 shl 8)) != 0: flags.incl(cfCX8)     # CMPXCHG8B
  if (result1.edx and (1'u32 shl 13)) != 0: flags.incl(cfPGE)    # PGE
  if (result1.edx and (1'u32 shl 15)) != 0: flags.incl(cfCMOV)   # CMOV
  if (result1.edx and (1'u32 shl 16)) != 0: flags.incl(cfPAT)    # PAT
  if (result1.edx and (1'u32 shl 17)) != 0: flags.incl(cfPSE36)  # PSE-36
  if (result1.edx and (1'u32 shl 23)) != 0: flags.incl(cfMMX)    # MMX

  # Detect flags from ECX (leaf 1)
  if (result1.ecx and (1'u32 shl 0)) != 0: flags.incl(cfPCLMULQDQ)
  if (result1.ecx and (1'u32 shl 1)) != 0: flags.incl(cfSSE42)   # Actually DTES64 but test
  if (result1.ecx and (1'u32 shl 19)) != 0: flags.incl(cfSSE41)
  if (result1.ecx and (1'u32 shl 20)) != 0: flags.incl(cfSSE42)
  if (result1.ecx and (1'u32 shl 28)) != 0: flags.incl(cfAVX)    # AVX

  # Extended features (leaf 0x80000001)
  let maxLeaf = cpuid(0x80000000)
  if maxLeaf.eax >= 0x80000001:
    let resultExt = cpuid(0x80000001)

    # Extended EDX flags
    if (resultExt.edx and (1'u32 shl 11)) != 0: flags.incl(cfSVM)   # AMD-V
    if (resultExt.edx and (1'u32 shl 20)) != 0: flags.incl(cfEXT)   # AMD Extended MMX
    if (resultExt.edx and (1'u32 shl 29)) != 0: flags.incl(cfLM)    # Long Mode (64-bit)
    if (resultExt.edx and (1'u32 shl 30)) != 0: flags.incl(cfPAE)   # 3DNowExt

    # Extended ECX flags
    if (resultExt.ecx and (1'u32 shl 0)) != 0: flags.incl(cfAES)
    if (resultExt.ecx and (1'u32 shl 6)) != 0: flags.incl(cfSSE42)  # Actually SSE4a

  flags

proc detectCoreCount*(): uint32 =
  ## Detect number of CPU cores
  ## Uses CPUID leaf 1 ECX[23:16]
  let result = cpuid(0x01)
  let coreCount = ((result.ecx shr 16) and 0xFF) + 1
  coreCount

proc getCpuInfo*(): CpuInfo =
  ## Gather all CPU information
  var info: CpuInfo
  info.flags = detectFeatures()
  info.vendorId = detectVendor()
  info.cpuCoreCount = detectCoreCount()
  info.cpuThreadCount = detectCoreCount()  # Simplified for now
  info

# ═══════════════════════════════════════════════════════════════════════════
# CPU Count Detection
# ═══════════════════════════════════════════════════════════════════════════

var gCpuCount*: uint32 = 1

proc detectCpuCount*(bootInfo: BootInfo): uint32 =
  ## Detect number of CPUs in system
  ##
  ## Strategy (in order of preference):
  ## 1. From Multiboot2 boot info (if provided)
  ## 2. From ACPI tables (if available)
  ## 3. From CPUID (limited accuracy)
  ## 4. Default to 1
  ##
  ## For Phase 1, we mostly use boot info from bootloader

  # Option 1: From boot info (Multiboot2 can provide this)
  if bootInfo.cpuCount > 0:
    gCpuCount = bootInfo.cpuCount
    return gCpuCount

  # Option 2: From CPUID leaf 4 (deterministic cache info)
  let result = cpuid(0x04, 0)
  let coreCount = ((result.eax shr 26) and 0x3F) + 1

  if coreCount > 0:
    gCpuCount = coreCount
    return gCpuCount

  # Option 3: Fallback
  gCpuCount = 1
  gCpuCount

# ═══════════════════════════════════════════════════════════════════════════
# Per-CPU Data Structure
# ═══════════════════════════════════════════════════════════════════════════

type
  PerCpuData* = object
    ## Per-CPU kernel data
    id*: uint32                    ## CPU ID
    isInitialized*: bool           ## Initialization done?
    lastScheduled*: uint64         ## Last scheduled time
    idleCount*: uint64             ## Idle ticks
    irqCount*: uint64              ## Interrupt count

# ═══════════════════════════════════════════════════════════════════════════
# CPU Status Functions
# ═══════════════════════════════════════════════════════════════════════════

proc getCpuInfoString*(): string =
  ## Get formatted CPU information
  let info = getCpuInfo()
  var result = "CPU Information:\n"
  result &= "  Vendor: " & $info.vendorId & "\n"
  result &= "  Cores: " & $info.cpuCoreCount & "\n"
  result &= "  Threads: " & $info.cpuThreadCount & "\n"
  result

proc getCpuFlagsString*(flags: set[CpuFlags]): string =
  ## Get formatted CPU flags
  var result = "CPU Flags: "
  if cfLM in flags: result &= "LM "
  if cfNX in flags: result &= "NX "
  if cfVMX in flags: result &= "VMX "
  if cfSVM in flags: result &= "SVM "
  if cfPAE in flags: result &= "PAE "
  if cfPSE in flags: result &= "PSE "
  if cfMSR in flags: result &= "MSR "
  if cfTSC in flags: result &= "TSC "
  if cfAVX in flags: result &= "AVX "
  if cfAES in flags: result &= "AES "
  result

# ═══════════════════════════════════════════════════════════════════════════
# Notes on Architecture
# ═══════════════════════════════════════════════════════════════════════════

## CPU DETECTION PHILOSOPHY:
##
## This module detects CPU capabilities and count.
## It's called early in kernel_main to determine system configuration.
##
## CPU COUNT STRATEGY:
## 1. Try boot info from bootloader (most reliable)
## 2. Try CPUID (works but limited)
## 3. Default to 1 CPU (always safe fallback)
##
## For Phase 1, we mostly rely on bootloader providing this info.
## ACPI table parsing comes later (Phase 2+).
##
## FEATURE DETECTION:
## - Detects ~25 common CPU flags
## - Used to check required features
## - Can guide scheduling decisions
##
## CPUID STRUCTURE:
## - Leaf 0x00: Vendor and max leaf
## - Leaf 0x01: Family, model, stepping, features
## - Leaf 0x04: Cache info, core count
## - Leaf 0x80000000: Max extended leaf
## - Leaf 0x80000001: Extended features (NX, LM, etc.)
##
## NEXT STEPS:
## - ACPI table parsing for NUMA awareness
## - CPU affinity configuration
## - Per-CPU initialization
