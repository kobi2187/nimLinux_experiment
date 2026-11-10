/* SPDX-License-Identifier: GPL-2.0
 * Host test for libnimix's keymap (libnimix/nimix_keymap.h):
 *   1. characters: reproduces, for every evdev code 0..127 under every shift/caps/ctrl
 *      combination, tests/libnimix/key_vectors.txt, generated from the Nim authority
 *      input/evdev_keymap.nim (gen_key_vectors.nim);
 *   2. key values: every mapped evdev key equals raylib 6.2's own KeyboardKey enum
 *      (this file includes raylib.h), so a raylib renumbering fails here. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "raylib.h"
#include "nimix_keymap.h"

static int bad;
#define EXPECT(cond, ...) do { if (!(cond)) { bad++; printf("FAIL: " __VA_ARGS__); printf("\n"); } } while (0)

static void test_chars(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) { perror(path); exit(1); }
    char line[128];
    int n = 0;
    while (fgets(line, sizeof line, f)) {
        if (line[0] == '#' || line[0] == '\n') continue;
        unsigned code; int flags, want;
        if (sscanf(line, "%u %d %d", &code, &flags, &want) != 3) { printf("bad line: %s", line); exit(1); }
        NimixKeyState ks = { 0, 0, 0 };
        if (flags & 1) nimix_key_feed(&ks, 42, 1);
        if (flags & 2) nimix_key_feed(&ks, 58, 1);
        if (flags & 4) nimix_key_feed(&ks, 29, 1);
        int got = nimix_key_feed(&ks, code, 1);
        EXPECT(got == want, "code %u flags %d: C %d != Nim %d", code, flags, got, want);
        n++;
    }
    fclose(f);
    printf("PASS: %d character vectors equal the Nim keymap\n", n);
}

static void test_modifiers(void) {
    NimixKeyState ks = { 0, 0, 0 };
    EXPECT(nimix_key_feed(&ks, 30, 1) == 'a', "plain a");
    nimix_key_feed(&ks, 42, 1);
    EXPECT(nimix_key_feed(&ks, 30, 1) == 'A', "shift a");
    nimix_key_feed(&ks, 42, 0);
    EXPECT(nimix_key_feed(&ks, 30, 1) == 'a', "shift released");
    EXPECT(nimix_key_feed(&ks, 30, 0) == NIMIX_NO_CHAR, "a release types nothing");
    EXPECT(nimix_key_feed(&ks, 30, 2) == 'a', "autorepeat types again");
    nimix_key_feed(&ks, 58, 1); nimix_key_feed(&ks, 58, 0);
    EXPECT(nimix_key_feed(&ks, 30, 1) == 'A', "caps lock inverts letters");
    EXPECT(nimix_key_feed(&ks, 2, 1) == '1', "caps lock leaves digits");
    nimix_key_feed(&ks, 58, 1);
    nimix_key_feed(&ks, 29, 1);
    EXPECT(nimix_key_feed(&ks, 46, 1) == 3, "ctrl-c is 0x03");
    printf("PASS: modifier tracking\n");
}

static void test_raylib_keys(void) {
    static const struct { unsigned code; int key; const char *name; } map[] = {
        {1, KEY_ESCAPE, "ESCAPE"}, {2, KEY_ONE, "ONE"}, {3, KEY_TWO, "TWO"}, {4, KEY_THREE, "THREE"},
        {5, KEY_FOUR, "FOUR"}, {6, KEY_FIVE, "FIVE"}, {7, KEY_SIX, "SIX"}, {8, KEY_SEVEN, "SEVEN"},
        {9, KEY_EIGHT, "EIGHT"}, {10, KEY_NINE, "NINE"}, {11, KEY_ZERO, "ZERO"}, {12, KEY_MINUS, "MINUS"},
        {13, KEY_EQUAL, "EQUAL"}, {14, KEY_BACKSPACE, "BACKSPACE"}, {15, KEY_TAB, "TAB"},
        {16, KEY_Q, "Q"}, {17, KEY_W, "W"}, {18, KEY_E, "E"}, {19, KEY_R, "R"}, {20, KEY_T, "T"},
        {21, KEY_Y, "Y"}, {22, KEY_U, "U"}, {23, KEY_I, "I"}, {24, KEY_O, "O"}, {25, KEY_P, "P"},
        {26, KEY_LEFT_BRACKET, "LEFT_BRACKET"}, {27, KEY_RIGHT_BRACKET, "RIGHT_BRACKET"},
        {28, KEY_ENTER, "ENTER"}, {29, KEY_LEFT_CONTROL, "LEFT_CONTROL"},
        {30, KEY_A, "A"}, {31, KEY_S, "S"}, {32, KEY_D, "D"}, {33, KEY_F, "F"}, {34, KEY_G, "G"},
        {35, KEY_H, "H"}, {36, KEY_J, "J"}, {37, KEY_K, "K"}, {38, KEY_L, "L"},
        {39, KEY_SEMICOLON, "SEMICOLON"}, {40, KEY_APOSTROPHE, "APOSTROPHE"}, {41, KEY_GRAVE, "GRAVE"},
        {42, KEY_LEFT_SHIFT, "LEFT_SHIFT"}, {43, KEY_BACKSLASH, "BACKSLASH"},
        {44, KEY_Z, "Z"}, {45, KEY_X, "X"}, {46, KEY_C, "C"}, {47, KEY_V, "V"}, {48, KEY_B, "B"},
        {49, KEY_N, "N"}, {50, KEY_M, "M"}, {51, KEY_COMMA, "COMMA"}, {52, KEY_PERIOD, "PERIOD"},
        {53, KEY_SLASH, "SLASH"}, {54, KEY_RIGHT_SHIFT, "RIGHT_SHIFT"}, {56, KEY_LEFT_ALT, "LEFT_ALT"},
        {57, KEY_SPACE, "SPACE"}, {58, KEY_CAPS_LOCK, "CAPS_LOCK"},
        {59, KEY_F1, "F1"}, {60, KEY_F2, "F2"}, {61, KEY_F3, "F3"}, {62, KEY_F4, "F4"}, {63, KEY_F5, "F5"},
        {64, KEY_F6, "F6"}, {65, KEY_F7, "F7"}, {66, KEY_F8, "F8"}, {67, KEY_F9, "F9"}, {68, KEY_F10, "F10"},
        {87, KEY_F11, "F11"}, {88, KEY_F12, "F12"}, {97, KEY_RIGHT_CONTROL, "RIGHT_CONTROL"},
        {100, KEY_RIGHT_ALT, "RIGHT_ALT"}, {102, KEY_HOME, "HOME"}, {103, KEY_UP, "UP"},
        {104, KEY_PAGE_UP, "PAGE_UP"}, {105, KEY_LEFT, "LEFT"}, {106, KEY_RIGHT, "RIGHT"},
        {107, KEY_END, "END"}, {108, KEY_DOWN, "DOWN"}, {109, KEY_PAGE_DOWN, "PAGE_DOWN"},
        {110, KEY_INSERT, "INSERT"}, {111, KEY_DELETE, "DELETE"},
    };
    int n = (int)(sizeof map / sizeof map[0]);
    for (int i = 0; i < n; i++)
        EXPECT(nimix_evdev_to_raylib(map[i].code) == map[i].key, "evdev %u -> %d, raylib KEY_%s = %d",
               map[i].code, nimix_evdev_to_raylib(map[i].code), map[i].name, map[i].key);
    /* codes with no mapping must give 0, never a stray value */
    int mapped[128] = { 0 };
    for (int i = 0; i < n; i++) mapped[map[i].code] = 1;
    for (unsigned c = 0; c < 128; c++)
        if (!mapped[c]) EXPECT(nimix_evdev_to_raylib(c) == 0, "unmapped evdev %u gives %d", c, nimix_evdev_to_raylib(c));
    EXPECT(nimix_evdev_to_raylib(100000) == 0, "huge code");
    printf("PASS: %d keys equal raylib's KeyboardKey enum; unmapped codes give 0\n", n);
}

int main(int argc, char **argv) {
    test_chars(argc > 1 ? argv[1] : "tests/libnimix/key_vectors.txt");
    test_modifiers();
    test_raylib_keys();
    if (bad) { printf("FAIL: %d problems\n", bad); return 1; }
    printf("All keymap tests passed.\n");
    return 0;
}
