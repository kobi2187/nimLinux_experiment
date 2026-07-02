import "/home/kl/prog/nimLinux_experiment/ipc/mailbox"
import "/home/kl/prog/nimLinux_experiment/runtime/actor"
import cps
var log: seq[int]
proc mkMsg(b: byte): MailMsg = (result.len = 1; result.data[0] = b)
proc worker() {.cps: Actor.} =
  while true:
    receive()
    if not self().blocked:
      log.add(int(self().pending.data[0]))
proc main() =
  let inbox = newInbox()
  var a = Actor(whelp worker())
  a.inbox = inbox
  discard post(inbox, mkMsg(42))
  a = pump(a)
  echo "pump1: log=", log, " blocked=", a.blocked, " mbCount=", mbCount(inbox.mb)
  discard post(inbox, mkMsg(99))
  echo "posted 99, mbCount=", mbCount(inbox.mb)
  a = pump(a)
  echo "pump2: log=", log, " blocked=", a.blocked, " mbCount=", mbCount(inbox.mb)
main()
