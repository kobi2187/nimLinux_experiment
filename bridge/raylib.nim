# SPDX-License-Identifier: GPL-2.0
## The raylib bridge (docs/proposals/draw_protocol.md §7): what RUI and raylib
## programs import. Same names and types as naylib; the backend is chosen at
## compile time:
##   default        direct  — in-process raylib (zero-cost forwards)
##   -d:rlRemote    remote  — draw ops become commands for the render server
## (`hybrid`, per-op routing with counted fallback, comes after P0.)

when defined(rlRemote):
  import rl_remote
  export rl_remote
else:
  import rl_direct
  export rl_direct
