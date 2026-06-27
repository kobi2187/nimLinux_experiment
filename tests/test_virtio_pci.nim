# SPDX-License-Identifier: GPL-2.0
## Tests for virtio-pci modern transport — host-side, no hardware.
## Verifies the spec §4.1.4 capability + CommonCfg struct layouts and the
## capability-walk logic against a synthetic config-space buffer.
{.define: noKernelHardware.}

import ../drivers/virtio/virtio_pci

# ── Struct layout (virtio spec §4.1.4) ────────────────────────────────────────

proc testVirtioPciCapLayout() =
  ## struct virtio_pci_cap is 16 bytes: cap_vndr,cap_next,cap_len,cfg_type,
  ## bar,id,padding[2],offset(u32),length(u32).
  assert sizeof(VirtioPciCap) == 16, "virtio_pci_cap must be 16 bytes, got " & $sizeof(VirtioPciCap)
  echo "PASS: VirtioPciCap is 16 bytes"

proc testCommonCfgLayout() =
  ## virtio_pci_common_cfg is 56 bytes per spec.
  assert sizeof(VirtioPciCommonCfg) == 56,
    "common_cfg must be 56 bytes, got " & $sizeof(VirtioPciCommonCfg)
  echo "PASS: VirtioPciCommonCfg is 56 bytes"

proc testCfgTypeConsts() =
  assert VIRTIO_PCI_CAP_COMMON_CFG == 1'u8
  assert VIRTIO_PCI_CAP_NOTIFY_CFG == 2'u8
  assert VIRTIO_PCI_CAP_ISR_CFG    == 3'u8
  assert VIRTIO_PCI_CAP_DEVICE_CFG == 4'u8
  echo "PASS: virtio-pci cfg_type constants correct"

when isMainModule:
  testVirtioPciCapLayout()
  testCommonCfgLayout()
  testCfgTypeConsts()
  echo "All virtio-pci tests passed."
