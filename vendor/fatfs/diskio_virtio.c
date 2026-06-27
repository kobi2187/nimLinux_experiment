/*
 * diskio_virtio.c — FatFs disk I/O layer backed by virtio-blk.
 *
 * Replaces diskio.c (ATA PIO). Calls Nim-exported nimixBlkRead /
 * nimixBlkWrite / nimixBlkReady which forward to the virtio-blk driver.
 *
 * One sector = 512 bytes. FatFs issues one call per sector; virtio-blk
 * also operates one sector at a time in our synchronous implementation.
 */

#include "ff.h"
#include "diskio.h"
#include <stdint.h>

/* Nim-exported symbols from drivers/virtio/diskio_virtio.nim */
extern int nimixBlkReady(void);
extern int nimixBlkRead(uint64_t sector, void *buf);
extern int nimixBlkWrite(uint64_t sector, const void *buf);

DSTATUS disk_status(BYTE pdrv) {
    if (pdrv != 0) return STA_NOINIT;
    return nimixBlkReady() ? 0 : STA_NODISK;
}

DSTATUS disk_initialize(BYTE pdrv) {
    if (pdrv != 0) return STA_NOINIT;
    return nimixBlkReady() ? 0 : STA_NODISK;
}

DRESULT disk_read(BYTE pdrv, BYTE *buf, LBA_t sector, UINT count) {
    if (pdrv != 0 || !nimixBlkReady()) return RES_NOTRDY;
    for (UINT i = 0; i < count; i++) {
        if (nimixBlkRead((uint64_t)(sector + i), buf + i * 512) != 0)
            return RES_ERROR;
    }
    return RES_OK;
}

DRESULT disk_write(BYTE pdrv, const BYTE *buf, LBA_t sector, UINT count) {
    if (pdrv != 0 || !nimixBlkReady()) return RES_NOTRDY;
    for (UINT i = 0; i < count; i++) {
        if (nimixBlkWrite((uint64_t)(sector + i), buf + i * 512) != 0)
            return RES_ERROR;
    }
    return RES_OK;
}

DRESULT disk_ioctl(BYTE pdrv, BYTE cmd, void *buf) {
    if (pdrv != 0) return RES_PARERR;
    switch (cmd) {
        case CTRL_SYNC:       return RES_OK;
        case GET_SECTOR_SIZE: *(WORD  *)buf = 512; return RES_OK;
        case GET_BLOCK_SIZE:  *(DWORD *)buf = 1;   return RES_OK;
        default:              return RES_PARERR;
    }
}

DWORD get_fattime(void) {
    return ((DWORD)(2026 - 1980) << 25) | (1 << 21) | (1 << 16);
}
