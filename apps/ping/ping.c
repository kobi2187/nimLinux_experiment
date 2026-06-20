/*
 * ping.c — NimixOS WASM app (C source)
 *
 * Compiled to WASM with:
 *   clang --target=wasm32 -nostdlib -Wl,--no-entry -Wl,--export=_start \
 *         -Wl,--import-undefined -O2 -o ping.wasm ping.c
 *
 * Host ABI imports (provided by NimixOS kernel):
 *   env.serial_write(ptr, len)     — write bytes to COM1 serial
 *   env.sip_exit(code)             — terminate this SIP
 */

/* Declare host functions we import from the kernel */
__attribute__((import_module("env"), import_name("serial_write")))
void serial_write(const char *ptr, int len);

__attribute__((import_module("env"), import_name("sip_exit")))
void sip_exit(int code);

/* Simple strlen — no libc */
static int mystrlen(const char *s) {
    int n = 0;
    while (*s++) n++;
    return n;
}

static void print(const char *msg) {
    serial_write(msg, mystrlen(msg));
}

void _start(void) {
    print("ping!\n");
    print("Hello from a C-compiled WASM app running in NimixOS.\n");
    sip_exit(0);
}
