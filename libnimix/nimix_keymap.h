/* SPDX-License-Identifier: GPL-2.0
 * Keyboard events for C programs (V5c): evdev key codes (what the virtio keyboard
 * delivers on the "input" event topic) to raylib's KeyboardKey values and to
 * characters. Pure, header-only, host-tested:
 *   - characters equal input/evdev_keymap.nim (the authority) on golden vectors;
 *   - key values equal raylib 6.2's own KeyboardKey enum (tests/libnimix/test_keymap.c). */
#pragma once
#include <stdint.h>

#define NIMIX_EV_KEY 1u
#define NIMIX_NO_CHAR (-1)

/* evdev keycode (KEY_ESC = 1 ... KEY_SPACE = 57) -> character, US layout. Same text
 * as `Plain` and `Shifted` in input/evdev_keymap.nim. */
static const char nimix_plain[58]   = "\0\033" "1234567890-=\b\tqwertyuiop[]\r\0asdfghjkl;'`\0\\zxcvbnm,./\0*\0 ";
static const char nimix_shifted[58] = "\0\033" "!@#$%^&*()_+\b\tQWERTYUIOP{}\r\0ASDFGHJKL:\"~\0|ZXCVBNM<>?\0*\0 ";

typedef struct { int shift, ctrl, caps; } NimixKeyState;

static inline int nimix_is_letter(int c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }

/* Feed one EV_KEY event (value 1 = press, 2 = autorepeat, 0 = release). Tracks the
 * modifiers; returns the character a press types, or NIMIX_NO_CHAR. */
static inline int nimix_key_feed(NimixKeyState *ks, unsigned code, int value) {
    switch (code) {
    case 42: case 54: ks->shift = value != 0; return NIMIX_NO_CHAR;     /* shifts */
    case 29: case 97: ks->ctrl = value != 0; return NIMIX_NO_CHAR;      /* ctrls */
    case 58: if (value) ks->caps = !ks->caps; return NIMIX_NO_CHAR;     /* caps lock toggles on press */
    }
    if (value == 0 || code >= sizeof nimix_plain) return NIMIX_NO_CHAR;
    int c = (unsigned char)(ks->shift ? nimix_shifted[code] : nimix_plain[code]);
    if (c == 0) return NIMIX_NO_CHAR;
    if (ks->caps && nimix_is_letter(c)) c = (c >= 'a' && c <= 'z') ? c - 32 : c + 32;
    if (ks->ctrl && nimix_is_letter(c)) return (c | 0x20) - 'a' + 1;    /* Ctrl-A ... Ctrl-Z */
    return c;
}

/* evdev keycode -> raylib KeyboardKey (GLFW-style values), 0 if the key has none here. */
static inline int nimix_evdev_to_raylib(unsigned code) {
    static const short row_q[] = { 'Q','W','E','R','T','Y','U','I','O','P' };      /* codes 16..25 */
    static const short row_a[] = { 'A','S','D','F','G','H','J','K','L' };          /* codes 30..38 */
    static const short row_z[] = { 'Z','X','C','V','B','N','M' };                  /* codes 44..50 */
    if (code >= 2 && code <= 10) return '1' + (int)(code - 2);                     /* 1..9 */
    if (code >= 16 && code <= 25) return row_q[code - 16];
    if (code >= 30 && code <= 38) return row_a[code - 30];
    if (code >= 44 && code <= 50) return row_z[code - 44];
    if (code >= 59 && code <= 68) return 290 + (int)(code - 59);                   /* F1..F10 */
    switch (code) {
    case 1: return 256;   /* ESCAPE */      case 11: return '0';
    case 12: return '-';  case 13: return '=';
    case 14: return 259;  /* BACKSPACE */   case 15: return 258;   /* TAB */
    case 26: return '[';  case 27: return ']';
    case 28: return 257;  /* ENTER */       case 29: return 341;   /* LEFT CONTROL */
    case 39: return ';';  case 40: return '\''; case 41: return '`';
    case 42: return 340;  /* LEFT SHIFT */  case 43: return '\\';
    case 51: return ',';  case 52: return '.';  case 53: return '/';
    case 54: return 344;  /* RIGHT SHIFT */ case 56: return 342;   /* LEFT ALT */
    case 57: return ' ';  case 58: return 280;  /* CAPS LOCK */
    case 87: return 300;  /* F11 */         case 88: return 301;   /* F12 */
    case 97: return 345;  /* RIGHT CONTROL */ case 100: return 346; /* RIGHT ALT */
    case 102: return 268; /* HOME */        case 103: return 265;  /* UP */
    case 104: return 266; /* PAGE UP */     case 105: return 263;  /* LEFT */
    case 106: return 262; /* RIGHT */       case 107: return 269;  /* END */
    case 108: return 264; /* DOWN */        case 109: return 267;  /* PAGE DOWN */
    case 110: return 260; /* INSERT */      case 111: return 261;  /* DELETE */
    }
    return 0;
}
