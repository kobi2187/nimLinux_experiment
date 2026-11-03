#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Every binary's Nim heap backing store must be page-aligned: Nim's allocator
# finds chunk headers with p & ~PageMask. Kernel: theHeap (kernel.ld aligns
# it). Apps: nimix_arena (nimix_page_arena.h); apps must not contain theHeap.
status=0
for f in "$@"; do
  for sym in theHeap nimix_arena; do
    addr=$(nm "$f" | awk -v s="$sym" '$3 ~ "^"s {print $1; exit}')
    [ -z "$addr" ] && continue
    if [ $(( 0x$addr & 0xfff )) -ne 0 ]; then
      echo "FAIL: $f $sym at 0x$addr is not page-aligned"; status=1
    fi
  done
  case "$f" in *.elf)
    if nm "$f" | grep -q " theHeap"; then
      echo "FAIL: $f uses Nim's unaligned theHeap (missing -d:nimAllocPagesViaMalloc?)"; status=1
    fi;;
  esac
done
[ $status -eq 0 ] && echo "heap alignment OK ($# binaries)"
exit $status
