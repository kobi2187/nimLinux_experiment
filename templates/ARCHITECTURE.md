# Architecture — living map

## Module tree (what the boundaries ARE)
Status legend: BUILT / PARTIAL / STUBBED / PLANNED / SPAWNED
- <module>/   [PLANNED]   iface: <the public interface — functions/types it exposes>
- <module>/   [BUILT]     iface: <...>

## Assembly plan (how the parts are MEANT to connect)
- <module A> depends on <module B> because <reason> — <wired / not yet wired>.
- <planned module> will depend on <...> — interface stubbed for now.
- <the next big seam to define>: <description>.

## Seams under tension (boundaries likely to move)
- <stubbed/uncertain interface>: <what will change once it's real>.

## Spawned sub-projects (black boxes behind a frozen API)
- <module> → sub-project at <path/repo>, API: <interface>, status: <reported>.

## Drift log (architecture changes made mid-flight)
- <date>: <what moved and why, in one line> → see DECISIONS <ADR-id>.
