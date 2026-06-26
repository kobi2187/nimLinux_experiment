#!/usr/bin/env bash
# Spawn a tiny-lib sub-project: same protocol, scoped to one module behind a frozen API.
# Usage: ./spawn-subproject.sh <module-name> [target-dir]
# NOTE: freeze the API and converge with the human BEFORE running this (see AGENTS.md SPAWN).
set -euo pipefail
MOD="${1:?usage: spawn-subproject.sh <module-name> [target-dir]}"
DIR="${2:-subprojects/$MOD}"
KIT="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$DIR/.claude/commands"
cp "$KIT/AGENTS.md" "$DIR/AGENTS.md"
cp "$KIT/.claude/commands/orient.md" "$DIR/.claude/commands/orient.md"
for f in VISION ARCHITECTURE BACKLOG STATE DECISIONS HANDOFF; do
  cp "$KIT/templates/$f.md" "$DIR/$f.md"
done

echo "Spawned sub-project '$MOD' at $DIR"
echo "Next: fill $DIR/VISION.md (north-star = implement the frozen API), then run /orient inside it."
echo "Its first task should be a SURVEY for a mature lib that satisfies the API."
