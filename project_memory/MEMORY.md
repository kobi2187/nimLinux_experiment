# NimixOS Project Memory

## Code style
- [Code size rule](feedback_code_size.md) — files >~100 lines should be split into focused imported modules; keep code simple, readable, elegant
- [Stdlib preference](feedback_stdlib.md) — prefer Nim stdlib and high-level abstractions; low-level pointer/bit code only when stdlib genuinely unavailable (kernel --os:any context)
- [Complexity rule](feedback_complexity.md) — Forth philosophy: extract named procs, keep cyclomatic complexity ≤5, refactor before adding features if a proc is already complex
- [Performance rule](feedback_performance.md) — no premature optimization; let data structure choice and system design drive performance, not micro-optimizations

## Project context
- [Vision](project_vision.md) — OS-as-a-library north star: composable modules → 3 kernel models, dispatcher QoS hub, raylib graphics, cap tokens only
- [Architecture](project_architecture.md) — 3 models (monolithic/microkernel/sasos), vtable traits, ELF servers + WASM apps, MsgPack control + FlatBuffers data
- [Build system](project_build_system.md) — make targets, -d:kernelModel flag, ISO structure, key file paths
- [Concurrency model](project_concurrency.md) — preemptive kernel scheduler + CPS dispatcher; why split; future CPS/rump directions

## Workflow
- [Task workflow](feedback_task_workflow.md) — taskwarrior, project:nimixos, layer tags drive ordering, create/complete freely
