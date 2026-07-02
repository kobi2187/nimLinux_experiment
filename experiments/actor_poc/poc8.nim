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
  echo "inboxReady before post: ", inboxReady(a.inbox)
  discard post(inbox, mkMsg(42))
  echo "inboxReady after post: ", inboxReady(a.inbox), " mbCount=", mbCount(inbox.mb)
  a = pump(a)
  echo "after pump: log=", log, " got=", a.got
main()
