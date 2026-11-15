# SPDX-License-Identifier: GPL-2.0
## Manifest and system policy parsing (launch/manifest.nim): what an app asks for, what the system
## allows, and that a mistake can only remove authority.
import std/[unittest, random, strutils]
import ../launch/manifest

proc m(s: string): ParseResult = parseManifest(s)
proc p(s: string): ParseResult = parsePolicy(s)

suite "manifest":
  test "grant lines, comments, blanks, CRLF":
    let r = m("# an app\n\ngrant files\n  grant display   # trailing comment\r\ngrant spawn\n")
    check r.ok and r.grants == {gnFiles, gnDisplay, gnSpawn}
    check m("").ok and m("").grants == {}
    check m("grant net").grants == {gnNet}               # no final newline

  test "an invalid file is refused whole and grants nothing":
    for bad in ["grant\n", "grant nothing\n", "grants files\n", "allow files\n", "grant files extra\n",
                "grant files\ngrant bogus\n", "GRANT files\n", "grant Files\n"]:
      let r = m(bad)
      check not r.ok and r.grants == {}
    check m("grant files\ngrant bogus\n").line == 2
    check m("grant " & "x".repeat(130) & "\n").line == 1

  test "policy uses allow, manifest uses grant; the wrong verb is an error":
    check p("allow files\nallow spawn\n").grants == {gnFiles, gnSpawn}
    check not p("grant files\n").ok

  test "effective = asked AND allowed; an invalid file on either side gives nothing":
    let ask = m("grant files\ngrant display\ngrant net\n")
    let pol = p("allow files\nallow net\nallow spawn\n")
    check effectiveGrants(ask, pol) == {gnFiles, gnNet}
    check effectiveGrants(ask, p("")) == {}              # no policy: nothing allowed
    check effectiveGrants(m(""), pol) == {}               # no manifest: nothing asked
    check effectiveGrants(m("grant oops\n"), pol) == {}
    check effectiveGrants(ask, p("allow oops\n")) == {}

  test "random text never grants more than the names it contains (no crash, no widening)":
    var rng = initRand(5)
    const alphabet = " \t\n\r#grantallowspawndisplayinputfilesnetdispatcher"
    for i in 0 ..< 20000:
      var s = ""
      for k in 0 ..< rng.rand(200): s.add alphabet[rng.rand(alphabet.high)]
      let r = m(s)
      if not r.ok: check r.grants == {}
      let both = effectiveGrants(r, p(s))
      check both <= r.grants
