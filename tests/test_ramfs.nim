# SPDX-License-Identifier: GPL-2.0
## Host-side test for the ramfs VFS driver
import fs/vfs
import fs/ramfs
import unittest
import std/strutils

suite "ramfs VFS driver":
  test "Mount and File lifecycle":
    registerRamFs()
    
    var stripped: cstring
    let drv = getDriver("/ram/test.txt", stripped)
    check drv != nil
    check drv.name == "ramfs"
    check $stripped == "test.txt"
    
    check drv.mount()
    
    let content = "Hello operating system developers!"
    let writeRes = drv.writeFile("ram_file.txt", cast[pointer](unsafeAddr content[0]), content.len)
    check writeRes == 0
    
    var readBuf: array[64, byte]
    let readLen = drv.readInto("ram_file.txt", addr readBuf[0], readBuf.len)
    check readLen == content.len
    
    var readStr = ""
    for i in 0..<readLen:
      readStr.add(char(readBuf[i]))
    check readStr == content
    
    var dirBuf: array[256, byte]
    let dirLen = drv.dirList("", addr dirBuf[0], dirBuf.len)
    check dirLen > 0
    
    var dirStr = ""
    for i in 0..<dirLen:
      dirStr.add(char(dirBuf[i]))
    check dirStr.contains("ram_file.txt")
