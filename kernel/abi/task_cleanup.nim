# SPDX-License-Identifier: GPL-2.0
## Task cleanup — release everything a task owns when it exits or is killed.
##
## Resources follow their owner: the app's region (and its user window),
## server channels it created (with their receive capabilities), and its event
## subscriptions. Before this, a killed fs_server kept "fs" registered forever
## (restart refused), and subscriptions leaked until the 256-slot table filled.

import ../../ipc/server_chan
import ../../kernel/event_server
import ../../kernel/cap/capability as cap
import ../../mm/region_allocator
import ../../mm/user_window

proc releaseTaskResources*(pid: uint32; regionSlot: int) =
  for ch in ownedChannels():
    let tok = CapToken(ch.recvCap)
    if cap.capOwner(tok) == pid:
      serverChanRelease(ch)
      cap.capRevoke(tok)
  eventReleaseOwner(pid)
  if regionSlot >= 0:
    discard appRegionUserAccess(RegionHandle(regionSlot), false)
    regionFree(RegionHandle(regionSlot))
