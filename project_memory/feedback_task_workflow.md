---
name: feedback-task-workflow
description: "How to use taskwarrior in this project — create/complete freely, layer tags drive ordering"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 2aeec000-d2c7-4794-ad9a-e8cd0ef40956
---

Use taskwarrior (`task` CLI) for all work tracking. Create and complete tasks freely — don't ask for permission.

**Why:** The user manages this project via taskwarrior; keeping it up to date is part of the workflow, not overhead.

**How to apply:**
- Project tag: always `nimixos`
- Layer tags (`layer0`–`layer9`) encode the dependency graph — lower layers must be done before higher ones
- Module tags for area: gui, drivers, dispatcher, fs, network, audio, foundation, etc.
- Priority: H/M/L but layer ordering takes precedence over priority for sequencing
- When picking next work: find leaf nodes at the lowest unfinished layer — those are ready to execute
- When finishing a task: `task <id> done`
- When discovering new work: `task add project:nimixos +<layer> +<area> "<description>"`
- Don't create tasks for things already done; don't leave tasks open after the code lands
