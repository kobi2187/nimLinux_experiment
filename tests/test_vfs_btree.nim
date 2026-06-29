# SPDX-License-Identifier: GPL-2.0
## Host-side test for B+ Tree and VFS

import fs/vfs
import fs/metadata_db
import unittest

suite "VFS & B+ Tree Metadata tests":
  test "VFS Prefix Routing":
    var fatMounted = false
    var fatRead = false
    
    let drv = FSDriver(
      name: "fatfs",
      prefix: "/fat/",
      mount: proc(): bool {.nimcall.} =
        fatMounted = true
        true,
      readInto: proc(path: cstring; buf: ptr byte; len: int): int {.nimcall.} =
        fatRead = true
        123
    )
    registerDriver(drv)
    
    var stripped: cstring
    let found = getDriver("/fat/foo/bar.txt", stripped)
    check found != nil
    check found.name == "fatfs"
    check $stripped == "foo/bar.txt"
    
    let readLen = vfsReadInto("/fat/foo/bar.txt", nil, 10)
    check readLen == 123
    check fatRead == true

  test "B+ Tree Operations":
    let db = initDB()
    
    var val: uint64
    check(not db.get("nonexistent", val))
    
    db.insert("user:name:alice", 1001)
    db.insert("user:name:bob", 1002)
    db.insert("user:name:charlie", 1003)
    
    check(db.get("user:name:alice", val))
    check(val == 1001)
    check(db.get("user:name:bob", val))
    check(val == 1002)
    check(db.get("user:name:charlie", val))
    check(val == 1003)
    
    let results = db.queryPrefix("user:name:")
    check(results.len == 3)
    check(results[0].key == "user:name:alice")
    check(results[0].val == 1001)
    check(results[1].key == "user:name:bob")
    check(results[1].val == 1002)
    check(results[2].key == "user:name:charlie")
    check(results[2].val == 1003)

  test "B+ Tree Serialization Roundtrip":
    let db = initDB()
    db.insert("tag:music:genre:electronic", 42)
    db.insert("tag:music:genre:rock", 43)
    
    let serialized = db.serializeDB()
    check(serialized.len >= 8)
    
    let db2 = deserializeDB(serialized)
    var val: uint64
    check(db2.get("tag:music:genre:electronic", val))
    check(val == 42)
    check(db2.get("tag:music:genre:rock", val))
    check(val == 43)

  test "B+ Tree Kernel Scenario":
    let db = initDB()
    db.insert("artist:Daft Punk:1", 101)
    db.insert("artist:Daft Punk:2", 102)
    db.insert("artist:Kraftwerk:1", 201)
    db.insert("title:Around the World:1", 101)
    
    var val: uint64
    check(db.get("artist:Kraftwerk:1", val))
    check(val == 201)
    
    let results = db.queryPrefix("artist:Daft Punk:")
    check(results.len == 2)
    check(results[0].key == "artist:Daft Punk:1")
    check(results[0].val == 101)
    check(results[1].key == "artist:Daft Punk:2")
    check(results[1].val == 102)
