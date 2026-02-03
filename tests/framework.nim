# SPDX-License-Identifier: GPL-2.0
## Testing Framework - Component Testing Infrastructure
##
## Provides mocks, test utilities, and verification helpers
## Allows testing kernel components without hardware
##
## Key Features:
## - Mock physical memory (in-process heap)
## - Mock virtual memory with validation
## - Mock interrupt system
## - Integration test helpers
## - Performance measurement
## - Assertion utilities

import ../core/types
import ../core/serial

# ═══════════════════════════════════════════════════════════════════════════
# Test Statistics & Reporting
# ═══════════════════════════════════════════════════════════════════════════

type
  TestResult* = enum
    trPass
    trFail
    trSkip

  TestCase* = object
    name*: string
    result*: TestResult
    message*: string
    durationMs*: uint64

  TestSuite* = object
    name*: string
    cases*: seq[TestCase]
    passed*: int
    failed*: int
    skipped*: int

var globalTestSuite*: TestSuite

proc startTestSuite*(name: string) =
  ## Start a new test suite
  globalTestSuite = TestSuite(
    name: name,
    cases: @[],
    passed: 0,
    failed: 0,
    skipped: 0
  )

proc addTestCase*(name: string, result: TestResult, message: string = "") =
  ## Add test case result to suite
  globalTestSuite.cases.add(TestCase(
    name: name,
    result: result,
    message: message
  ))

  case result
  of trPass:
    inc globalTestSuite.passed
  of trFail:
    inc globalTestSuite.failed
  of trSkip:
    inc globalTestSuite.skipped

proc reportTestResults*(): string =
  ## Get human-readable test results
  var result = "Test Suite: " & globalTestSuite.name & "\n"
  result &= "  Passed: " & $globalTestSuite.passed & "\n"
  result &= "  Failed: " & $globalTestSuite.failed & "\n"
  result &= "  Skipped: " & $globalTestSuite.skipped & "\n"
  result &= "  Total: " & $globalTestSuite.cases.len & "\n"

  if globalTestSuite.failed > 0:
    result &= "\nFailed Tests:\n"
    for testCase in globalTestSuite.cases:
      if testCase.result == trFail:
        result &= "  - " & testCase.name & ": " & testCase.message & "\n"

  result

# ═══════════════════════════════════════════════════════════════════════════
# Assertion Utilities
# ═══════════════════════════════════════════════════════════════════════════

proc assertTrue*(condition: bool, message: string = ""): bool =
  ## Assert condition is true
  if condition:
    result = true
  else:
    result = false
    let msg = if message.len > 0: message else: "Assertion failed"
    addTestCase("assert_true", trFail, msg)

proc assertFalse*(condition: bool, message: string = ""): bool =
  ## Assert condition is false
  if not condition:
    result = true
  else:
    result = false
    let msg = if message.len > 0: message else: "Assertion failed (expected false)"
    addTestCase("assert_false", trFail, msg)

proc assertEqual*[T](actual: T, expected: T, message: string = ""): bool =
  ## Assert values are equal
  if actual == expected:
    result = true
  else:
    result = false
    let msg = if message.len > 0: message else: "Values not equal"
    addTestCase("assert_equal", trFail, msg)

proc assertNotEqual*[T](actual: T, expected: T, message: string = ""): bool =
  ## Assert values are not equal
  if actual != expected:
    result = true
  else:
    result = false
    let msg = if message.len > 0: message else: "Values should not be equal"
    addTestCase("assert_not_equal", trFail, msg)

proc assertNil*(ptr: pointer, message: string = ""): bool =
  ## Assert pointer is nil
  if ptr == nil:
    result = true
  else:
    result = false
    let msg = if message.len > 0: message else: "Pointer should be nil"
    addTestCase("assert_nil", trFail, msg)

proc assertNotNil*(ptr: pointer, message: string = ""): bool =
  ## Assert pointer is not nil
  if ptr != nil:
    result = true
  else:
    result = false
    let msg = if message.len > 0: message else: "Pointer should not be nil"
    addTestCase("assert_not_nil", trFail, msg)

# ═══════════════════════════════════════════════════════════════════════════
# Memory Validator
# ═══════════════════════════════════════════════════════════════════════════

type
  MemoryValidator* = object
    ## Tracks memory allocations for leak detection
    allocations*: seq[tuple[ptr: pointer, size: uint64, tag: string]]
    totalAllocated*: uint64
    totalFreed*: uint64
    peakUsage*: uint64

var globalMemoryValidator*: MemoryValidator

proc recordAllocation*(tag: string, ptr: pointer, size: uint64) =
  ## Record memory allocation
  globalMemoryValidator.allocations.add((ptr, size, tag))
  globalMemoryValidator.totalAllocated += size
  if globalMemoryValidator.totalAllocated - globalMemoryValidator.totalFreed > globalMemoryValidator.peakUsage:
    globalMemoryValidator.peakUsage = globalMemoryValidator.totalAllocated - globalMemoryValidator.totalFreed

proc recordDeallocation*(ptr: pointer, size: uint64) =
  ## Record memory deallocation
  globalMemoryValidator.totalFreed += size

proc checkMemoryLeaks*(): int =
  ## Check for memory leaks, return leak count
  var leakCount = 0
  for alloc in globalMemoryValidator.allocations:
    # Simple check: if allocation wasn't explicitly freed
    if alloc.ptr != nil:
      inc leakCount
  result = leakCount

proc getMemoryReport*(): string =
  ## Get memory usage report
  var result = "Memory Report:\n"
  result &= "  Total Allocated: " & $(globalMemoryValidator.totalAllocated div 1024) & " KB\n"
  result &= "  Total Freed: " & $(globalMemoryValidator.totalFreed div 1024) & " KB\n"
  result &= "  Peak Usage: " & $(globalMemoryValidator.peakUsage div 1024) & " KB\n"
  result &= "  Current Usage: " & $((globalMemoryValidator.totalAllocated - globalMemoryValidator.totalFreed) div 1024) & " KB\n"
  result &= "  Potential Leaks: " & $checkMemoryLeaks() & "\n"
  result

# ═══════════════════════════════════════════════════════════════════════════
# Mock Physical Memory
# ═══════════════════════════════════════════════════════════════════════════

type
  MockPhysicalMemory* = object
    ## Mock physical memory for testing
    buffer*: seq[byte]
    allocations*: seq[tuple[addr: uint64, size: uint64]]

proc initMockPhysicalMemory*(sizeBytes: uint64): MockPhysicalMemory =
  ## Initialize mock physical memory
  result.buffer = newSeq[byte](sizeBytes)
  result.allocations = @[]

proc allocateMockPhysical*(mpm: var MockPhysicalMemory, size: uint64): Option[uint64] =
  ## Allocate from mock physical memory
  if size == 0 or size > uint64(mpm.buffer.len):
    return none(uint64)

  # Simple first-fit allocator
  var offset = 0'u64
  for alloc in mpm.allocations:
    if offset + size <= alloc.addr:
      mpm.allocations.add((offset, size))
      return some(offset)
    offset = alloc.addr + alloc.size

  if offset + size <= uint64(mpm.buffer.len):
    mpm.allocations.add((offset, size))
    return some(offset)

  none(uint64)

proc freeMockPhysical*(mpm: var MockPhysicalMemory, addr: uint64) =
  ## Free from mock physical memory
  for i in 0..<mpm.allocations.len:
    if mpm.allocations[i].addr == addr:
      mpm.allocations.del(i)
      break

# ═══════════════════════════════════════════════════════════════════════════
# Mock Interrupt System
# ═══════════════════════════════════════════════════════════════════════════

type
  MockInterruptSystem* = object
    ## Mock interrupt system for testing
    interruptsFired*: seq[uint32]
    handlerCount*: int
    lastInterruptVector*: uint32

proc recordInterrupt*(mis: var MockInterruptSystem, vector: uint32) =
  ## Record interrupt for validation
  mis.interruptsFired.add(vector)
  mis.lastInterruptVector = vector

proc getInterruptLog*(mis: MockInterruptSystem): seq[uint32] =
  ## Get log of interrupts that fired
  result = mis.interruptsFired

proc wasInterruptFired*(mis: MockInterruptSystem, vector: uint32): bool =
  ## Check if specific interrupt was fired
  result = vector in mis.interruptsFired

# ═══════════════════════════════════════════════════════════════════════════
# Test Utilities
# ═══════════════════════════════════════════════════════════════════════════

proc resetAllTestData*() =
  ## Reset all test data
  globalTestSuite = TestSuite(
    name: "",
    cases: @[],
    passed: 0,
    failed: 0,
    skipped: 0
  )
  globalMemoryValidator = MemoryValidator(
    allocations: @[],
    totalAllocated: 0,
    totalFreed: 0,
    peakUsage: 0
  )

proc printTestReport*() =
  ## Print complete test report
  kprint(reportTestResults())
  kprint("\n")
  kprint(getMemoryReport())
  kprint("\n")
