# SPDX-License-Identifier: GPL-2.0
## App manifests and the system policy (S3): what a program may be given.
##
## Static separation, decided once at spawn (docs/proposals/capabilities.md §3.5): an app's manifest
## NAMES the kinds of authority it needs; the system policy NAMES what the machine allows; the
## launcher grants the intersection. Nothing here runs at call time and nothing here is authority:
## the kernel only enforces conservation. These are two small text files a human can read:
##
##     # tools/ls.mf                   # etc/system.policy
##     grant files                     allow files
##     grant display                   allow display
##                                     allow spawn
##
## Rules: one directive per line, `#` starts a comment, blank lines are ignored, names are lower
## case. A manifest says `grant <name>`; the policy says `allow <name>`. An unknown verb or name, a
## directive in the wrong file, or a line over 120 characters makes the whole file INVALID, and the
## launcher then grants nothing: a typo can only remove authority, never add it. A missing manifest
## means "nothing"; a missing policy means "nothing allowed".
##
## Pure and allocation-free: usable in the kernel's launcher and on the host.

type
  GrantName* = enum
    gnSpawn        ## the right to start programs (a process handle)
    gnDispatcher   ## an endpoint of the dispatcher, badged with the app's identity
    gnDisplay      ## the single-client display port
    gnInput        ## the input stream of the focused window
    gnFiles        ## a directory scope on the file server
    gnNet          ## the network

  GrantSet* = set[GrantName]

  ParseResult* = object
    ok*: bool
    line*: int         ## 1-based line of the first error (0 when ok)
    grants*: GrantSet

const
  MaxLine = 120
  names: array[GrantName, string] = ["spawn", "dispatcher", "display", "input", "files", "net"]

func nameOf*(g: GrantName): string = names[g]

func lookupName(w: openArray[char]): int =
  for g in GrantName:
    let n = names[g]
    if n.len == w.len:
      var same = true
      for i in 0 ..< w.len:
        if w[i] != n[i]: same = false
      if same: return ord(g)
  -1

proc parseFile(text: openArray[char]; verb: string): ParseResult =
  var line = 1
  var i = 0
  result.ok = true
  while i < text.len:
    var j = i
    while j < text.len and text[j] != '\n': inc j
    template ln: untyped = text.toOpenArray(i, j - 1)    # the line without its newline
    var k = 0
    template fail() =
      return ParseResult(ok: false, line: line)
    if ln.len > MaxLine: fail()
    while k < ln.len and (ln[k] == ' ' or ln[k] == '\t' or ln[k] == '\r'): inc k
    if k < ln.len and ln[k] != '#':
      var e = k
      while e < ln.len and ln[e] != ' ' and ln[e] != '\t' and ln[e] != '\r': inc e
      if e - k != verb.len: fail()
      for q in 0 ..< verb.len:
        if ln[k + q] != verb[q]: fail()
      k = e
      while k < ln.len and (ln[k] == ' ' or ln[k] == '\t'): inc k
      e = k
      while e < ln.len and ln[e] != ' ' and ln[e] != '\t' and ln[e] != '\r': inc e
      if e == k: fail()
      let g = lookupName(ln.toOpenArray(k, e - 1))
      if g < 0: fail()
      k = e
      while k < ln.len and (ln[k] == ' ' or ln[k] == '\t' or ln[k] == '\r'): inc k
      if k < ln.len and ln[k] != '#': fail()           # nothing but a comment may follow
      result.grants.incl GrantName(g)
    i = j + 1
    inc line

proc parseManifest*(text: openArray[char]): ParseResult =
  ## `grant <name>` lines: what the app asks for. Invalid file: ok = false and no grants.
  result = parseFile(text, "grant")
  if not result.ok: result.grants = {}

proc parsePolicy*(text: openArray[char]): ParseResult =
  ## `allow <name>` lines: what the system permits.
  result = parseFile(text, "allow")
  if not result.ok: result.grants = {}

func effectiveGrants*(manifest, policy: ParseResult): GrantSet =
  ## What the launcher gives: asked for AND allowed. An invalid file contributes nothing.
  if manifest.ok and policy.ok: manifest.grants * policy.grants else: {}
