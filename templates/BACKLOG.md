# Backlog — dependency tree

Tags: CLEAR (execute) / FUZZY (resolve) / OPEN (park) / PARENT (decompose) /
SPAWN (too big — its own sub-project)

## Task <n>: <name>  [PARENT]
Outcome: <intent of the whole>
Children:
  <n>.1 [CLEAR] <name>
        Outcome: <observable result>
        Module/iface: <which module + interface it touches>
        Path: <files + approach in 1-2 sentences>
        Done-check: <test / command / observable behavior>
        Depends: <other tasks/modules, or none>
  <n>.2 [FUZZY] <name>
        Outcome: <known>
        Uncertainty: <what's unclear>
        Plan: <research X, lean toward Y per vision; reversible -> proceed & log>
  <n>.3 [SPAWN] <name>
        Why: <large, self-contained, one clean interface>
        Draft API: <interface to converge with human, then freeze>
