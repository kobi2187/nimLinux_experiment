import "/home/kl/prog/nimLinux_experiment/ipc/mailbox"
import "/home/kl/prog/nimLinux_experiment/runtime/actor"
import cps
var log: seq[int]
proc mkMsg(b: byte): MailMsg = (result.len = 1; result.data[0] = b)
proc worker() {.cps: Actor.} =
  while true:
    receive()
    log.add(int(self().pending.data[0]))
proc main() =
  let inbox = newInbox()
  var a = Actor(whelp worker())
  a.inbox = inbox
  discard post(inbox, mkMsg(42)); a = pump(a)
  echo "pump1: log=", log, " entries=", a.entries, " mb=", mbCount(inbox.mb)
  discard post(inbox, mkMsg(99)); a = pump(a)
  echo "pump2: log=", log, " entries=", a.entries, " mb=", mbCount(inbox.mb)
main()
