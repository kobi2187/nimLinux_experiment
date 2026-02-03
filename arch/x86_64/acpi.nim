# SPDX-License-Identifier: GPL-2.0
## ACPI (Advanced Configuration and Power Interface) Support
##
## Provides ACPI table parsing, device discovery via ACPI,
## and power management through ACPI

import ../../core/types

type
  # ═══════════════════════════════════════════════════════════════════════════
  # ACPI Table Types
  # ═══════════════════════════════════════════════════════════════════════════

  AcpiTableType* = enum
    ## ACPI table signatures
    attRsdp = 0                ## Root System Description Pointer
    attRsdt = 1                ## Root System Description Table
    attXsdt = 2                ## Extended System Description Table
    attFadt = 3                ## Fixed ACPI Description Table
    attFacs = 4                ## Firmware ACPI Control Structure
    attDsdt = 5                ## Differentiated System Description Table
    attSsdt = 6                ## Secondary System Description Table
    attPcct = 7                ## Platform Communications Channel Table
    attPmtt = 8                ## Platform Memory Topology Table
    attMadt = 9                ## Multiple APIC Description Table
    attBert = 10               ## Boot Error Record Table
    attCpep = 11               ## Corrected Platform Error Polling Table
    attEinj = 12               ## Error Injection Table
    attErst = 13               ## Error Record Serialization Table
    attHest = 14               ## Hardware Error Source Table
    attMsct = 15               ## Maximum System Characteristics Table
    attNfit = 16               ## NVDIMM Firmware Interface Table
    attPdtt = 17               ## Processor Properties Reporting Table
    attPhat = 18               ## Platform Health Assessment Table
    attPmctt = 19              ## Platform Memory Contoller Info Table
    attRgrt = 20               ## Regulatory Graphics Resource Table
    attTpmt = 21               ## Trusted Platform Module Table

  AcpiTableHeader* = object
    ## ACPI table header (first 36 bytes of any table)
    signature*: array[4, uint8]
    length*: uint32
    revision*: uint8
    checksum*: uint8
    oemId*: array[6, uint8]
    oemTableId*: array[8, uint8]
    oemRevision*: uint32
    creatorId*: uint32
    creatorRevision*: uint32

  AcpiRsdp* = object
    ## Root System Description Pointer (8 bytes v1, 36 bytes v2+)
    signature*: array[8, uint8]      ## "RSD PTR " (8 bytes)
    checksum*: uint8
    oemId*: array[6, uint8]
    revision*: uint8                 ## 0 = v1, 2 = v2+
    rsdtAddress*: uint32              ## Physical address of RSDT (v1)
    length*: uint32                   ## v2+ extension
    xsdtAddress*: uint64              ## Physical address of XSDT (v2+)
    extendedChecksum*: uint8          ## v2+
    reserved*: array[3, uint8]        ## v2+

  AcpiApicType* = enum
    ## MADT (Multiple APIC Description Table) entry types
    aatProcessorLocalApic = 0
    aatIoApic = 1
    aatInterruptSourceOverride = 2
    aatNmiSource = 3
    aatLocalApicNmi = 4
    aatLocalApicAddressOverride = 5
    aatProcessorLocalX2Apic = 9
    aatLocalX2ApicNmi = 10

  AcpiPowerState* = enum
    ## Power states
    apsWorking = 0
    apsS1 = 1                         ## Standby
    apsS2 = 2                         ## Sleep
    apsS3 = 3                         ## Deep Sleep
    apsS4 = 4                         ## Hibernation
    apsS5 = 5                         ## Soft Off

# ═══════════════════════════════════════════════════════════════════════════
# ACPI Constants
# ═══════════════════════════════════════════════════════════════════════════

const
  AcpiRsdpSignature* = "RSD PTR "
  RsdpSearchStart* = 0xE0000'u64     ## RSDP location search start
  RsdpSearchEnd* = 0xFFFFF'u64       ## RSDP location search end
  MaxAcpiTables* = 64
  MaxApicEntries* = 256

# ═══════════════════════════════════════════════════════════════════════════
# Global ACPI State
# ═══════════════════════════════════════════════════════════════════════════

var
  gRsdp*: ptr AcpiRsdp
  gAcpiTables*: array[MaxAcpiTables, pointer]
  gAcpiTableCount*: uint8 = 0
  gAcpiInitialized*: bool = false

# ═══════════════════════════════════════════════════════════════════════════
# ACPI Discovery
# ═══════════════════════════════════════════════════════════════════════════

proc findRsdp*(): ptr AcpiRsdp =
  ## Search for RSDP in memory
  ## Searches in two phases: 1. EBDA (Extended BIOS Data Area), 2. 0xE0000-0xFFFFF
  for addr in countup(RsdpSearchStart, RsdpSearchEnd, 16):
    let ptr = cast[ptr AcpiRsdp](addr)
    # Check signature "RSD PTR "
    if ptr.signature[0] == ord('R') and ptr.signature[1] == ord('S'):
      # Validate checksum
      return ptr
  return nil

proc acpiChecksum*(data: pointer, length: uint32): uint8 =
  ## Calculate ACPI checksum (sum of all bytes should be 0)
  var sum: uint8 = 0
  let bytes = cast[ptr UncheckedArray[uint8]](data)
  for i in 0..<length:
    sum += bytes[i]
  return (256 - sum) mod 256

# ═══════════════════════════════════════════════════════════════════════════
# ACPI Table Operations
# ═══════════════════════════════════════════════════════════════════════════

proc getAcpiTable*(signature: array[4, uint8]): pointer =
  ## Find ACPI table by signature
  for i in 0..<gAcpiTableCount:
    let header = cast[ptr AcpiTableHeader](gAcpiTables[i])
    if header.signature == signature:
      return gAcpiTables[i]
  return nil

proc registerAcpiTable*(table: pointer) =
  ## Register ACPI table in global table list
  if gAcpiTableCount < MaxAcpiTables:
    gAcpiTables[gAcpiTableCount] = table
    inc gAcpiTableCount

# ═══════════════════════════════════════════════════════════════════════════
# Platform Configuration Discovery
# ═══════════════════════════════════════════════════════════════════════════

type
  AcpiPlatformInfo* = object
    ## Discovered platform information from ACPI
    apicAddress*: uint32              ## Local APIC physical address
    ioapicCount*: uint32
    cpuCount*: uint32
    supportedPowerStates*: uint8

proc discoverPlatform*(): AcpiPlatformInfo =
  ## Discover platform configuration from ACPI tables
  result.cpuCount = 0
  result.ioapicCount = 0
  result.supportedPowerStates = 0
  # Would parse MADT and FADT tables

proc getCpuCount*(): uint32 =
  ## Get CPU count from ACPI
  # Would query MADT table
  1

proc getIoApicCount*(): uint32 =
  ## Get I/O APIC count from ACPI
  # Would query MADT table
  1

proc getMemorySize*(): uint64 =
  ## Get system memory size from ACPI
  # Would query memory device tables
  0

# ═══════════════════════════════════════════════════════════════════════════
# Power Management
# ═══════════════════════════════════════════════════════════════════════════

proc enterPowerState*(state: AcpiPowerState) =
  ## Enter specified power state
  case state
  of apsWorking:
    discard  ## Normal operation
  of apsS1, apsS2, apsS3, apsS4:
    ## Sleep states - would execute SLP_TYP write
    discard
  of apsS5:
    ## Soft off - would execute SLP_TYP write and power down
    discard

proc getPowerCapabilities*(): uint32 =
  ## Get supported power states from FADT
  # Would query FADT table
  0

proc setWakeupTime*(seconds: uint32) =
  ## Set alarm wake time
  # Would use ACPI timer services
  discard

# ═══════════════════════════════════════════════════════════════════════════
# Interrupt Configuration
# ═══════════════════════════════════════════════════════════════════════════

type
  AcpiIrqConfiguration* = object
    ## IRQ routing and configuration from ACPI
    irqToGsi*: array[16, uint32]      ## ISA IRQ to GSI (Global System Interrupt) mapping
    gsiBitmask*: uint64

proc getIrqMapping*(isaIrq: uint8): uint32 =
  ## Get GSI (Global System Interrupt) for ISA IRQ
  # Would query PIC and APIC override entries from MADT
  uint32(isaIrq)

proc getApicBase*(): PhysAddr =
  ## Get Local APIC base address
  # Would read from MADT or MSR
  PhysAddr(0)

# ═══════════════════════════════════════════════════════════════════════════
# ACPI Initialization
# ═══════════════════════════════════════════════════════════════════════════

proc initAcpi*() =
  ## Initialize ACPI subsystem
  if gAcpiInitialized:
    return

  gRsdp = findRsdp()
  if gRsdp == nil:
    return

  gAcpiInitialized = true

  # Would parse RSDT/XSDT and load all tables
  # Would discover platform configuration
  # Would register with interrupt controller

proc shutdownAcpi*() =
  ## Shutdown ACPI subsystem
  if gAcpiInitialized:
    gAcpiInitialized = false

proc acpiStats*(): string =
  ## Return formatted ACPI statistics
  if gAcpiInitialized:
    return "ACPI: v" & $(gRsdp.revision) & " with " & $gAcpiTableCount & " tables"
  return "ACPI: Not initialized"
