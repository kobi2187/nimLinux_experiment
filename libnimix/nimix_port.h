/* SPDX-License-Identifier: GPL-2.0
 * Device ports for C programs (K3): the wire form shared by every port, and how a program finds its port
 * among the handles it was given at spawn. Header-only. Layout mirrors ipc/ports/port.nim.
 *
 * A message: byte 0 class, 1 status, 2-3 op, 4-7 seq, 8-9 payload length, 10-11 zero, then the payload;
 * little endian, at most NIMIX_PORT_MSG bytes. The class and status numbers, the payload structs and the
 * operation numbers all come from the GENERATED libnimix/nimix_contract.h (never retyped here). */
#pragma once
#include <stdint.h>
#include "nimix_abi.h"
#include "nimix_contract.h"

_Static_assert(NIMIX_PORT_MSG == NIMIX_CONTRACT_MSG_BYTES, "the C and Nim message sizes must agree");
#define NIMIX_PORT_INPUT   NIMIX_PortKind_pkInput
#define NIMIX_PORT_DISPLAY NIMIX_PortKind_pkDisplay

static inline unsigned nimix_le16(const unsigned char *p) { return (unsigned)p[0] | ((unsigned)p[1] << 8); }
static inline int32_t nimix_le32(const unsigned char *p) {
    return (int32_t)((uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24));
}

/* Send one request through a port handle: `payload` (plen bytes) with operation `op`. The reply message
 * (wire form) is written to `reply` (NIMIX_PORT_MSG bytes). Returns the reply status (0 ok, > 0 a port status)
 * or -1 if the call itself failed (bad handle, bad message). The reply payload starts at reply + NIMIX_PORT_HEADER. */
static inline int nimix_port_request(NimixHandle h, unsigned op, const void *payload, unsigned plen, unsigned char *reply) {
    if (plen > NIMIX_PORT_MSG - NIMIX_PORT_HEADER) return -1;
    unsigned char *m = reply;
    for (int i = 0; i < NIMIX_PORT_MSG; i++) m[i] = 0;
    m[2] = (unsigned char)(op & 0xFF); m[3] = (unsigned char)(op >> 8);
    m[8] = (unsigned char)(plen & 0xFF); m[9] = (unsigned char)(plen >> 8);
    for (unsigned i = 0; i < plen; i++) m[NIMIX_PORT_HEADER + i] = ((const unsigned char *)payload)[i];
    int n = nimixPortCall(h, m, (int)(NIMIX_PORT_HEADER + plen), NIMIX_PORT_MSG);
    if (n < NIMIX_PORT_HEADER || m[0] != NIMIX_MsgClass_mcReply) return -1;
    return m[1];
}

/* Which of the handles given at spawn is the port of this kind? 0 if none. Asks each handle "what port
 * are you?" (the describe request every port answers); handles of other kinds just refuse. */
static inline NimixHandle nimix_find_port(unsigned kind) {
    for (unsigned i = 0; i < 8; i++) {
        NimixHandle h = NIMIX_BOOTSTRAP_HANDLE + i;
        unsigned char m[NIMIX_PORT_MSG] = { 0 };                         /* request, status 0, seq 0, len 0 */
        m[2] = (unsigned char)(NIMIX_PORT_DESCRIBE_OP & 0xFF); m[3] = (unsigned char)(NIMIX_PORT_DESCRIBE_OP >> 8);
        int n = nimixPortCall(h, m, NIMIX_PORT_HEADER, sizeof m);
        if (n == NIMIX_PORT_HEADER + 1 && m[0] == NIMIX_MsgClass_mcReply && m[1] == NIMIX_PortStatus_psOk && m[NIMIX_PORT_HEADER] == kind) return h;
    }
    return 0;
}
