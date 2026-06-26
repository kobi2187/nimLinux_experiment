---
name: feedback-complexity
description: "Forth philosophy refactoring — extract named words, keep cyclomatic complexity low"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: b6b7a5b8-f231-4531-95b6-fb1a31457386
---

Refactor in the Forth philosophy: extract repeated or complex logic into small, named, composable procs. Never let cyclomatic complexity grow unchecked.

**Why:** Complex procs hide bugs, resist testing, and make the codebase fragile. A proc that does one thing and has one exit path is easier to verify correct.

**How to apply:**
- Any proc with more than 2-3 nested conditionals: extract branches into named procs
- Any repeated pattern (even 2 occurrences): give it a name and extract
- Prefer early-return guard clauses over nested if/else trees
- A proc with a `case` over many enum values is fine — that's dispatch, not complexity
- When adding a feature makes a proc grow past ~20 lines of logic: stop and refactor first
- Cyclomatic complexity > 5 in a single proc is a signal to split
- The goal: each proc reads like a sentence describing what it does, not how

**Examples of the pattern:**
- `cmdExec` was split into `runPieElf` + `runExecElf` — each does one thing
- `nimix_abi_impl.nim` was split into proc/fs/sysinfo modules
- `bufEmit`/`bufEmitUInt` extracted from duplicated inline loops
