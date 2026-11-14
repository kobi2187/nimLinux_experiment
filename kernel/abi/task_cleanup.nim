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
import ../buffers/kbuffers
import ../display/display
import ../handles/khandles
import ../space/kspace

proc releaseTaskResources*(pid: uint32; regionSlot: int) =
  for ch in ownedChannels():
    let tok = CapToken(ch.recvCap)
    if cap.capOwner(tok) == pid:
      serverChanRelease(ch)
      cap.capRevoke(tok)
  eventReleaseOwner(pid)
  khReleasePid(pid)                         # handles close; channels, in-flight handles released
  kbufReleasePid(pid)                       # buffers: lends return, handles close
  displayRelease(pid)                       # the display goes back to the console
  cap.capRevokeAllOf(pid)
  # The task's address space dies with it (back to the kernel's tables first if it is the loaded one).
  if regionSlot >= 0:
    ksDestroy(regionSlot)
    regionFree(RegionHandle(regionSlot))        # the slot is recycled at its last reference
