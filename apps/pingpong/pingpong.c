/*
 * pingpong.c — NimixOS WASM app demonstrating actor-mailbox IPC
 *
 * Compiled with:
 *   clang --target=wasm32 -nostdlib -Wl,--no-entry -Wl,--export=_start \
 *         -Wl,--allow-undefined -O2 -o pingpong.wasm pingpong.c
 *
 * Flow:
 *   1. Subscribe to "pong" events (get a token back)
 *   2. Send "ping" to ping_server's mailbox via chan_send
 *   3. Block on event_wait until "pong" event arrives
 *   4. Print the reply payload to serial
 *   5. Exit
 *
 * This proves the full actor-mailbox round-trip:
 *   WASM app → [chan_send] → kernel → ping_server mailbox
 *   ping_server → [event_publish] → kernel → WASM app wakes
 */

/* Host imports from NimixOS kernel */
__attribute__((import_module("env"), import_name("serial_write")))
void serial_write(const char *ptr, int len);

__attribute__((import_module("env"), import_name("chan_send")))
void chan_send(const char *server_name, const char *data, int len);

__attribute__((import_module("env"), import_name("event_subscribe")))
int event_subscribe(const char *topic);

__attribute__((import_module("env"), import_name("event_wait")))
int event_wait(int token, char *buf, int max_len);

__attribute__((import_module("env"), import_name("sip_exit")))
void sip_exit(int code);

/* Minimal helpers — no libc */
static int mystrlen(const char *s) {
    int n = 0; while (*s++) n++; return n;
}
static void print(const char *msg) {
    serial_write(msg, mystrlen(msg));
}

/* Reply buffer in WASM linear memory */
static char reply_buf[64];

void _start(void) {
    print("[pingpong] starting\n");

    /* Step 1: subscribe to "pong" events before sending ping
     * (subscribe first to avoid missing the reply if ping_server is fast) */
    int token = event_subscribe("pong");
    print("[pingpong] subscribed to 'pong'\n");

    /* Step 2: send "ping" to ping_server's mailbox */
    const char *msg = "ping";
    chan_send("ping_server", msg, mystrlen(msg));
    print("[pingpong] sent ping to ping_server\n");

    /* Step 3: block until we receive the "pong" event */
    print("[pingpong] waiting for pong...\n");
    int replyLen = event_wait(token, reply_buf, sizeof(reply_buf) - 1);

    /* Step 4: print the reply */
    if (replyLen > 0) {
        reply_buf[replyLen] = '\0';
        print("[pingpong] got reply: ");
        serial_write(reply_buf, replyLen);
        print("\n");
        print("[pingpong] ping-pong complete!\n");
    } else {
        print("[pingpong] timeout or error waiting for pong\n");
    }

    sip_exit(0);
}
