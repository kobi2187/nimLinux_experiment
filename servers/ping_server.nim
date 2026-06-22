# SPDX-License-Identifier: GPL-2.0
## Compatibility shim — re-exports kernel module scaffold from new location.
## All existing imports of servers/ping_server continue to work unchanged.
import ping/ping_kmod
export ping_kmod
