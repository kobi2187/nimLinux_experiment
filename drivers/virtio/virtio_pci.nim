# SPDX-License-Identifier: GPL-2.0
## Virtio modern (1.0) PCI transport — implements VirtioTransport via the
## PCI capability walk (virtio spec §4.1.4).
##
## A virtio-pci device advertises its register regions through vendor PCI
## capabilities (cap id 0x09). Each cap names a (bar, offset, length) and a
## cfg_type (COMMON / NOTIFY / ISR / DEVICE). We walk the capability list,
## map each region via pciBarDecode, and drive the device through CommonCfg.
##
## Struct layouts verified against linux/include/uapi/linux/virtio_pci.h
## (see subprojects/virtio-pci/DECISIONS.md V1 survey).

# ── Capability cfg_type values (spec §4.1.4) ──────────────────────────────────

const
  VIRTIO_PCI_CAP_COMMON_CFG* = 1'u8
  VIRTIO_PCI_CAP_NOTIFY_CFG* = 2'u8
  VIRTIO_PCI_CAP_ISR_CFG*    = 3'u8
  VIRTIO_PCI_CAP_DEVICE_CFG* = 4'u8
  PciCapIdVendor*            = 0x09'u8   ## vendor-specific cap → virtio cap

# ── struct virtio_pci_cap (16 bytes) ──────────────────────────────────────────

type
  VirtioPciCap* {.packed.} = object
    capVndr*:  uint8        ## 0x09 for virtio
    capNext*:  uint8        ## next cap offset in PCI config space
    capLen*:   uint8        ## this cap's length
    cfgType*:  uint8        ## VIRTIO_PCI_CAP_* selector
    bar*:      uint8        ## which BAR holds the region
    id*:       uint8
    padding*:  array[2, uint8]
    offset*:   uint32       ## offset of the region within the BAR
    length*:   uint32       ## length of the region

  VirtioPciNotifyCap* {.packed.} = object
    cap*:                 VirtioPciCap
    notifyOffMultiplier*: uint32

  VirtioPciCommonCfg* {.packed.} = object
    deviceFeatureSelect*: uint32
    deviceFeature*:       uint32
    guestFeatureSelect*:  uint32
    guestFeature*:        uint32
    msixConfig*:          uint16
    numQueues*:           uint16
    deviceStatus*:        uint8
    configGeneration*:    uint8
    queueSelect*:         uint16
    queueSize*:           uint16
    queueMsixVector*:     uint16
    queueEnable*:         uint16
    queueNotifyOff*:      uint16
    queueDescLo*:         uint32
    queueDescHi*:         uint32
    queueAvailLo*:        uint32
    queueAvailHi*:        uint32
    queueUsedLo*:         uint32
    queueUsedHi*:         uint32
