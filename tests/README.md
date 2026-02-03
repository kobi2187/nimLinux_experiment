# NimixOS Testing Framework

This directory contains comprehensive tests for all NimixOS kernel components.

## Overview

The testing framework allows you to:
- **Test components in isolation** without hardware
- **Mock external dependencies** for controlled testing
- **Verify component interactions** with integration tests
- **Detect memory leaks** and resource issues
- **Validate boot sequences** before hardware testing

## Test Structure

### Unit Tests (Component-Level)

Each component has its own test file:

- `test_bootloader.nim` - Bootloader parsing, boot info validation
- `test_physical_memory.nim` - Frame allocation, zones, fragmentation
- `test_virtual_memory.nim` - Page tables, address translation, mappings
- `test_heap_allocator.nim` - Memory allocation, coalescing, statistics
- `test_interrupts.nim` - IDT setup, exception handling, dispatch
- `test_cpu_primitives.nim` - CPU operations (when available)

**Run unit tests:**
```bash
nim c -r tests/test_bootloader.nim
nim c -r tests/test_physical_memory.nim
nim c -r tests/test_virtual_memory.nim
nim c -r tests/test_heap_allocator.nim
nim c -r tests/test_interrupts.nim
```

### Integration Tests

`test_integration.nim` verifies components work together:

- Boot info → Physical memory initialization
- Physical → Virtual → Heap pipeline
- Memory zones function correctly
- Interrupt system initialization
- Exception dispatch through system
- Page fault handling with memory context
- Complete boot sequence simulation

**Run integration tests:**
```bash
nim c -r tests/test_integration.nim
```

### Testing Framework

`framework.nim` provides infrastructure:

- **Assertion utilities**: `assertTrue`, `assertEqual`, `assertNil`, etc.
- **Test reporting**: Track pass/fail/skip, generate reports
- **Memory tracking**: Detect leaks, monitor usage
- **Mock systems**:
  - `MockPhysicalMemory` - In-process memory for testing
  - `MockInterruptSystem` - Interrupt logging and validation

## Usage Examples

### Simple Component Test

```nim
import unittest
import ../mm/heap_allocator
import ../core/types

suite "Heap Allocator - Basic":
  test "Allocate and free":
    var buffer: array[4096, byte]
    var alloc = new HeapAllocator

    let result = alloc.init(addr buffer[0], 4096)
    check result.isOk()

    let ptr = alloc.allocate(256, 8).value
    check ptr != nil

    let freeResult = alloc.deallocate(ptr)
    check freeResult.isOk()
```

### Integration Test with Mocks

```nim
import ./framework

suite "Memory Subsystem":
  test "Boot info to physical memory":
    var bootInfo: BootInfo
    bootInfo.memoryMap.regions[0] = MemoryRegion(
      base: PhysAddr(0),
      length: 256 * MiB,
      regionType: memAvailable
    )

    check bootInfo.getTotalMemory() == 256 * MiB
```

### Testing with Memory Validation

```nim
import ./framework

test "Verify no memory leaks":
  var mockMem = initMockPhysicalMemory(4096)
  let addr = mockMem.allocateMockPhysical(256)

  check addr.isSome()
  check checkMemoryLeaks() == 0
```

## Component Test Coverage

| Component | Unit Tests | Integration | Status |
|-----------|-----------|----------------|--------|
| Bootloader | ✅ 11 | ✅ Yes | Complete |
| Physical Memory | ✅ 19 | ✅ Yes | Complete |
| Virtual Memory | ✅ 22 | ✅ Yes | Complete |
| Heap Allocator | ✅ 28 | ✅ Yes | Complete |
| Interrupt System | ✅ 30 | ✅ Yes | Complete |
| CPU Primitives | ⏳ | - | Pending |
| Task Library | ⏳ | - | Pending |
| Scheduler | ⏳ | - | Pending |

## Running All Tests

```bash
# Run all component tests
nim c -r tests/test_bootloader.nim
nim c -r tests/test_physical_memory.nim
nim c -r tests/test_virtual_memory.nim
nim c -r tests/test_heap_allocator.nim
nim c -r tests/test_interrupts.nim

# Run integration tests
nim c -r tests/test_integration.nim

# Or use a test runner (if available)
# make test
```

## Test Output

Each test produces:
- **Pass/Fail/Skip** status for each test case
- **Detailed failure messages** with context
- **Memory report** showing allocation/leakage
- **Statistics** on test coverage

Example output:
```
Interrupt System - Component Tests
  ✓ Exception constants are valid
  ✓ IRQ offset is correct
  ✓ IDT flags constants
  ✓ ExceptionContext size is reasonable
  ✓ IdtEntry size matches x86_64 spec

Passed: 5
Failed: 0
Skipped: 0
```

## Debugging Failed Tests

1. **Check assertions** - Each failed assertion shows expected vs actual
2. **Review context** - Exception handlers show CPU state
3. **Memory tracking** - Framework shows memory usage at failure
4. **Interrupt logs** - Mock system records interrupt history

### Example Debug Session

```bash
# Run single component test
$ nim c -r tests/test_virtual_memory.nim

# Get verbose output
$ nim c -d:debug -r tests/test_virtual_memory.nim

# Check memory leaks
$ nim c -d:memSanitizer -r tests/test_physical_memory.nim
```

## Testing Strategy

### Before Hardware Boot

1. **Unit tests** - Verify each component works in isolation
2. **Integration tests** - Verify components interact correctly
3. **Memory tests** - Verify no leaks or corruption
4. **Exception tests** - Verify error handling
5. **Boot simulation** - Simulate complete boot sequence

### After Hardware Boot

1. **Hardware integration** - Test on real hardware
2. **Performance validation** - Benchmark against expectations
3. **Stress tests** - Load testing and stability
4. **Real-world scenarios** - Test actual workloads

## Adding New Tests

To add tests for a new component:

1. **Create test file**: `tests/test_<component>.nim`
2. **Follow pattern**: Import component, create suite, write assertions
3. **Use framework**: Leverage mocks and utilities from `framework.nim`
4. **Document**: Add comments explaining what's being tested
5. **Run**: Execute test to verify it works

Example template:
```nim
# SPDX-License-Identifier: GPL-2.0
## Tests for <Component>

import unittest
import ../<path>/<component>
import ../core/types
import ./framework

suite "<Component> - Component Tests":
  test "Basic functionality":
    # Your test here
    check true
```

## Known Limitations

1. **No real hardware interaction** - Tests use mocks
2. **No real interrupt handling** - Uses mock dispatch
3. **No real memory paging** - Uses in-process heap
4. **Single-threaded** - Tests run sequentially
5. **Limited stress testing** - Basic load scenarios only

These are intentional - they allow safe testing in development without risking kernel stability.

## Performance Benchmarks

Component performance metrics (optional, when available):

- **Physical Memory**: Frame allocation time
- **Virtual Memory**: Address translation time
- **Heap Allocator**: Allocation/deallocation time
- **Interrupt System**: Handler dispatch latency

Track in `tests/benchmarks.nim` if needed.

## Contributing Tests

When contributing:

1. Write tests FIRST (TDD)
2. Make tests pass
3. Add edge case tests
4. Document complex scenarios
5. Update this README
6. Ensure tests run cleanly

## Questions?

Refer to:
- Individual test files for examples
- Component documentation in source
- Integration tests for usage patterns
- Framework utilities for testing helpers

---

Last Updated: 2026-02-03
Framework Version: 1.0
