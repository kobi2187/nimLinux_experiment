/*
 * diskio.c — FatFs disk I/O layer for NimixOS
 *
 * Implements FatFs's disk_read/disk_write/disk_ioctl using ATA PIO.
 * ATA PIO uses port I/O — no DMA, no driver needed beyond inb/outb.
 *
 * QEMU presents a disk added with -hda as an ATA device on port 0x1F0.
 */

#include "ff.h"
#include "diskio.h"

/* ATA PIO register offsets from base port 0x1F0 */
#define ATA_DATA        0x1F0
#define ATA_ERROR       0x1F1
#define ATA_SECCOUNT    0x1F2
#define ATA_LBA_LO      0x1F3
#define ATA_LBA_MID     0x1F4
#define ATA_LBA_HI      0x1F5
#define ATA_DRIVE_HEAD  0x1F6
#define ATA_STATUS      0x1F7
#define ATA_CMD         0x1F7

#define ATA_SR_BSY      0x80
#define ATA_SR_DRDY     0x40
#define ATA_SR_DRQ      0x08
#define ATA_SR_ERR      0x01

#define ATA_CMD_READ    0x20
#define ATA_CMD_WRITE   0x30
#define ATA_CMD_IDENTIFY 0xEC

/* Port I/O — match Nim's inb/outb */
static inline unsigned char inb(unsigned short port) {
    unsigned char val;
    __asm__ volatile("inb %1, %0" : "=a"(val) : "Nd"(port));
    return val;
}
static inline void outb(unsigned short port, unsigned char val) {
    __asm__ volatile("outb %0, %1" :: "a"(val), "Nd"(port));
}
static inline unsigned short inw(unsigned short port) {
    unsigned short val;
    __asm__ volatile("inw %1, %0" : "=a"(val) : "Nd"(port));
    return val;
}
static inline void outw(unsigned short port, unsigned short val) {
    __asm__ volatile("outw %0, %1" :: "a"(val), "Nd"(port));
}

static void ata_wait_bsy(void) {
    while (inb(ATA_STATUS) & ATA_SR_BSY) {}
}
static void ata_wait_drq(void) {
    while (!(inb(ATA_STATUS) & ATA_SR_DRQ)) {}
}

static int ata_disk_present = -1;  /* -1=unknown, 0=no, 1=yes */

static int ata_detect(void) {
    if (ata_disk_present >= 0) return ata_disk_present;
    outb(ATA_DRIVE_HEAD, 0xA0);   /* select master drive */
    outb(ATA_CMD, ATA_CMD_IDENTIFY);
    unsigned char status = inb(ATA_STATUS);
    if (status == 0) { ata_disk_present = 0; return 0; }
    ata_wait_bsy();
    if (inb(ATA_LBA_MID) != 0 || inb(ATA_LBA_HI) != 0) {
        ata_disk_present = 0; return 0;  /* not ATA (ATAPI) */
    }
    while (!(inb(ATA_STATUS) & (ATA_SR_DRQ | ATA_SR_ERR))) {}
    ata_disk_present = (inb(ATA_STATUS) & ATA_SR_ERR) ? 0 : 1;
    /* drain IDENTIFY data */
    for (int i = 0; i < 256; i++) inw(ATA_DATA);
    return ata_disk_present;
}

/* ── FatFs interface ──────────────────────────────────────────────────────── */

DSTATUS disk_status(BYTE pdrv) {
    if (pdrv != 0) return STA_NOINIT;
    return ata_detect() ? 0 : STA_NODISK;
}

DSTATUS disk_initialize(BYTE pdrv) {
    if (pdrv != 0) return STA_NOINIT;
    return ata_detect() ? 0 : STA_NODISK;
}

DRESULT disk_read(BYTE pdrv, BYTE *buf, LBA_t sector, UINT count) {
    if (pdrv != 0 || !ata_detect()) return RES_NOTRDY;

    for (UINT i = 0; i < count; i++) {
        ata_wait_bsy();
        outb(ATA_DRIVE_HEAD, 0xE0 | ((sector >> 24) & 0x0F));
        outb(ATA_SECCOUNT,   1);
        outb(ATA_LBA_LO,     (unsigned char)(sector));
        outb(ATA_LBA_MID,    (unsigned char)(sector >> 8));
        outb(ATA_LBA_HI,     (unsigned char)(sector >> 16));
        outb(ATA_CMD,        ATA_CMD_READ);
        ata_wait_bsy();
        ata_wait_drq();
        if (inb(ATA_STATUS) & ATA_SR_ERR) return RES_ERROR;
        unsigned short *dst = (unsigned short *)buf;
        for (int j = 0; j < 256; j++) *dst++ = inw(ATA_DATA);
        buf += 512;
        sector++;
    }
    return RES_OK;
}

DRESULT disk_write(BYTE pdrv, const BYTE *buf, LBA_t sector, UINT count) {
    if (pdrv != 0 || !ata_detect()) return RES_NOTRDY;

    for (UINT i = 0; i < count; i++) {
        ata_wait_bsy();
        outb(ATA_DRIVE_HEAD, 0xE0 | ((sector >> 24) & 0x0F));
        outb(ATA_SECCOUNT,   1);
        outb(ATA_LBA_LO,     (unsigned char)(sector));
        outb(ATA_LBA_MID,    (unsigned char)(sector >> 8));
        outb(ATA_LBA_HI,     (unsigned char)(sector >> 16));
        outb(ATA_CMD,        ATA_CMD_WRITE);
        ata_wait_bsy();
        ata_wait_drq();
        const unsigned short *src = (const unsigned short *)buf;
        for (int j = 0; j < 256; j++) outw(ATA_DATA, *src++);
        buf += 512;
        sector++;
    }
    return RES_OK;
}

DRESULT disk_ioctl(BYTE pdrv, BYTE cmd, void *buf) {
    if (pdrv != 0) return RES_PARERR;
    switch (cmd) {
        case CTRL_SYNC:   return RES_OK;
        case GET_SECTOR_SIZE: *(WORD *)buf = 512; return RES_OK;
        case GET_BLOCK_SIZE:  *(DWORD *)buf = 1;  return RES_OK;
        default: return RES_PARERR;
    }
}

/* FatFs needs a timestamp source — return a fixed date (2026-01-01) */
DWORD get_fattime(void) {
    return ((DWORD)(2026 - 1980) << 25) | (1 << 21) | (1 << 16);
}
