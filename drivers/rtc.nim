# SPDX-License-Identifier: GPL-2.0
## RTC — CMOS Real-Time Clock driver
##
## Reads date/time from the MC146818-compatible CMOS RTC (I/O ports 0x70/0x71).
## Exposes two procs:
##   rtcReadDateTime() → RtcDateTime   (full calendar time)
##   rtcUptimeSecs()   → uint64        (seconds since boot, via PIT ticks)
##
## Protocol:
##   - Write register index to port 0x70 (bit 7 = NMI disable while reading)
##   - Read value from port 0x71
##   - Registers are BCD-encoded unless Status Register B bit 2 is set
##   - Spin on register 0x0A bit 7 (Update-In-Progress) before reading

when not defined(noKernelHardware):
  import ../arch/x86_64/cpu_primitives
  import ./pit

const
  CmosIndex* = 0x70'u16
  CmosData*  = 0x71'u16

  CmosSeconds*  = 0x00'u8
  CmosMinutes*  = 0x02'u8
  CmosHours*    = 0x04'u8
  CmosWeekday*  = 0x06'u8
  CmosDay*      = 0x07'u8
  CmosMonth*    = 0x08'u8
  CmosYear*     = 0x09'u8
  CmosCentury*  = 0x32'u8   ## Not present on all hardware; 0 if unsupported
  CmosStatusA*  = 0x0A'u8
  CmosStatusB*  = 0x0B'u8

  UpdateInProgress* = 0x80'u8  ## StatusA bit 7 — RTC is mid-update, don't read

type
  RtcDateTime* = object
    second*, minute*, hour*: uint8
    day*, month*:             uint8
    year*:                    uint16

when not defined(noKernelHardware):
  proc cmosRead(reg: uint8): uint8 {.inline.} =
    outb(CmosIndex, reg or 0x80'u8)  # bit 7 disables NMI during read
    inb(CmosData)

  proc bcdToBin(v: uint8): uint8 {.inline.} =
    (v shr 4) * 10 + (v and 0x0F)

  proc rtcUpdateInProgress(): bool {.inline.} =
    (cmosRead(CmosStatusA) and UpdateInProgress) != 0

  proc rtcReadDateTime*(): RtcDateTime =
    ## Read current date/time from CMOS RTC.
    ## Spins until a stable read (two consecutive identical reads) to avoid
    ## catching the RTC mid-update.
    var a, b: RtcDateTime

    template readAll(dt: RtcDateTime) =
      while rtcUpdateInProgress(): discard
      dt.second = cmosRead(CmosSeconds)
      dt.minute = cmosRead(CmosMinutes)
      dt.hour   = cmosRead(CmosHours)
      dt.day    = cmosRead(CmosDay)
      dt.month  = cmosRead(CmosMonth)
      dt.year   = cmosRead(CmosYear)

    readAll(a)
    while true:
      readAll(b)
      if a.second == b.second and a.minute == b.minute and
         a.hour   == b.hour   and a.day    == b.day    and
         a.month  == b.month  and a.year   == b.year:
        break
      a = b

    let statusB = cmosRead(CmosStatusB)
    let isBcd = (statusB and 0x04'u8) == 0

    if isBcd:
      b.second = bcdToBin(b.second)
      b.minute = bcdToBin(b.minute)
      b.hour   = bcdToBin(b.hour)
      b.day    = bcdToBin(b.day)
      b.month  = bcdToBin(b.month)
      b.year   = bcdToBin(uint8(b.year))

    let century = cmosRead(CmosCentury)
    let c = if isBcd: bcdToBin(century) else: century
    b.year = if c > 0: c.uint16 * 100 + b.year else: 2000'u16 + b.year

    b

  proc rtcUptimeSecs*(): uint64 {.inline.} =
    ## Seconds since boot, derived from PIT tick counter (100 Hz).
    pitTicks() div 100
