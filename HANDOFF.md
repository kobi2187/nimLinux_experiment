# HANDOFF.md — Session Exit Note

Last updated: 2026-06-26

## What happened this session

Ran `/orient` — discovered the 5 orchestrator files (VISION, ARCHITECTURE, BACKLOG, STATE, HANDOFF) were missing. Interviewed the user to fill gaps in the docs. Created all 5 files and the project_memory/ folder with 5 memory files covering vision, architecture, build system, concurrency model, and task workflow.

Key things clarified vs. what the old docs said:
- The "3 ISOs" are 3 separate compilations via `-d:kernelModel=X`; `make iso-all` puts them in one GRUB menu
- Taskwarrior is the authoritative task tracker — create/complete freely
- CPS is the dispatcher's internal model, not a kernel scheduler replacement; kernel stays preemptive
- Rump kernel is a long-term direction, blocked on `irqSubscribe` + userspace DMA — don't touch
- Model parity: monolithic was furthest ahead; others catching up; gaps can lag if solution unclear
- 68 taskwarrior tasks across layers 0–9

## Where to resume

**Layer 0 frontier — both CLEAR, no blockers:**
- TW#48: Syscall gate — fix ring-3 transition; ABI vtable dispatch currently a no-op
- TW#37: CI pipeline — GitHub Actions for all 3 models + tests

Pick one and SURVEY → EXECUTE.

## State of the orchestrator files

All 5 just created. BACKLOG.md mirrors taskwarrior but adds structure. STATE.md will need updating as tasks complete — keep it in sync.
