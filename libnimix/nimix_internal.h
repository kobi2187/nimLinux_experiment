/* SPDX-License-Identifier: GPL-2.0 — libnimix internals shared between its files. */
#pragma once

/* Write out what stdio has buffered for the console (before any direct write). */
void nimix_console_flush(void);

/* Monotonic nanoseconds: the time page (no syscall), or whole seconds of uptime
 * if the kernel published no usable clock. */
unsigned long long nimix_now_ns(void);
