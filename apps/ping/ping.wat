;; ping.wat — minimal WASM app that prints "ping!\n" to serial
;; Compile with: wat2wasm ping.wat -o ping.wasm
;;
;; Imports:
;;   env.serial_write(ptr: i32, len: i32)  — write bytes to COM1
;;   env.sip_exit(code: i32)               — terminate this SIP
;;
;; Memory layout:
;;   offset 0: "ping!\n"  (6 bytes)

(module
  (import "env" "serial_write" (func $serial_write (param i32 i32)))
  (import "env" "sip_exit"     (func $sip_exit     (param i32)))

  (memory 1)
  (data (i32.const 0) "ping!\n")

  (func (export "_start")
    ;; print "ping!\n"
    i32.const 0   ;; ptr
    i32.const 6   ;; len
    call $serial_write

    ;; exit cleanly
    i32.const 0
    call $sip_exit))
