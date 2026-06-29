# SPDX-License-Identifier: GPL-2.0
## B+ Tree metadata database with probe/search separation.
##
## Provides two query patterns:
## - keyExists(): fast bool probe (does key exist?)
## - keySearch(): retrieves value by output parameter, returns bool for success
## This separation avoids overhead for existence checks.

import ../core/serial

const
  PageSize* = 4096
  MaxKeysPerNode* = 16

type
  PageId* = uint32

  BPlusNode* = ref object
    id*: PageId
    isLeaf*: bool
    keys*: seq[string]
    children*: seq[PageId]   # Children Page IDs (for internal nodes, length = keys.len + 1)
    values*: seq[uint64]     # File IDs (for leaf nodes, length = keys.len)
    nextLeaf*: PageId        # Linked list of leaves

  MetadataDB* = ref object
    rootId*: PageId
    nextFreeId*: PageId
    nodes*: seq[BPlusNode]

proc serializeNode*(node: BPlusNode; buf: var openArray[byte]) =
  for i in 0 ..< PageSize: buf[i] = 0
  buf[0] = if node.isLeaf: 1'u8 else: 0'u8
  
  let numKeys = node.keys.len.uint16
  buf[1] = byte(numKeys and 0xFF)
  buf[2] = byte((numKeys shr 8) and 0xFF)
  
  let nextLeaf = node.nextLeaf
  buf[3] = byte(nextLeaf and 0xFF)
  buf[4] = byte((nextLeaf shr 8) and 0xFF)
  buf[5] = byte((nextLeaf shr 16) and 0xFF)
  buf[6] = byte((nextLeaf shr 24) and 0xFF)
  
  var offset = 7
  if node.isLeaf:
    for v in node.values:
      for b in 0..7:
        buf[offset + b] = byte((v shr (b * 8)) and 0xFF)
      offset += 8
  else:
    for c in node.children:
      for b in 0..3:
        buf[offset + b] = byte((c shr (b * 8)) and 0xFF)
      offset += 4
      
  for key in node.keys:
    let kl = min(key.len, 255)
    buf[offset] = byte(kl)
    inc offset
    for i in 0 ..< kl:
      buf[offset] = byte(key[i])
      inc offset

proc deserializeNode*(id: PageId; buf: openArray[byte]): BPlusNode =
  let node = BPlusNode(id: id)
  node.isLeaf = buf[0] == 1'u8
  
  let numKeys = uint16(buf[1]) or (uint16(buf[2]) shl 8)
  
  node.nextLeaf = uint32(buf[3]) or (uint32(buf[4]) shl 8) or 
                  (uint32(buf[5]) shl 16) or (uint32(buf[6]) shl 24)
                  
  var offset = 7
  node.keys = @[]
  if node.isLeaf:
    node.values = @[]
    for i in 0 ..< int(numKeys):
      var v: uint64 = 0
      for b in 0..7:
        v = v or (uint64(buf[offset + b]) shl (b * 8))
      node.values.add(v)
      offset += 8
  else:
    node.children = @[]
    for i in 0 .. int(numKeys):
      var c: uint32 = 0
      for b in 0..3:
        c = c or (uint32(buf[offset + b]) shl (b * 8))
      node.children.add(c)
      offset += 4
      
  for i in 0 ..< int(numKeys):
    let kl = int(buf[offset])
    inc offset
    var key = ""
    for j in 0 ..< kl:
      key.add(char(buf[offset]))
      inc offset
    node.keys.add(key)
    
  node

proc initDB*(): MetadataDB =
  let db = MetadataDB(nodes: @[])
  db.rootId = 1
  db.nextFreeId = 2
  let root = BPlusNode(id: 1, isLeaf: true)
  db.nodes.add(root)
  db

proc splitLeaf(db: MetadataDB; node: BPlusNode): (string, PageId) =
  let newId = db.nextFreeId
  inc db.nextFreeId
  
  let newNode = BPlusNode(id: newId, isLeaf: true)
  db.nodes.add(newNode)
  
  let mid = node.keys.len div 2
  newNode.keys = node.keys[mid .. ^1]
  newNode.values = node.values[mid .. ^1]
  
  node.keys = node.keys[0 ..< mid]
  node.values = node.values[0 ..< mid]
  
  newNode.nextLeaf = node.nextLeaf
  node.nextLeaf = newId
  
  (newNode.keys[0], newId)

proc splitInternal(db: MetadataDB; node: BPlusNode): (string, PageId) =
  let newId = db.nextFreeId
  inc db.nextFreeId
  
  let newNode = BPlusNode(id: newId, isLeaf: false)
  db.nodes.add(newNode)
  
  let mid = node.keys.len div 2
  let splitKey = node.keys[mid]
  
  newNode.keys = node.keys[mid + 1 .. ^1]
  newNode.children = node.children[mid + 1 .. ^1]
  
  node.keys = node.keys[0 ..< mid]
  node.children = node.children[0 .. mid]
  
  (splitKey, newId)

proc findInsertIndex(keys: seq[string]; key: string): int =
  var idx = 0
  while idx < keys.len and keys[idx] < key:
    inc idx
  idx

proc insertRecursive(db: MetadataDB; nodeId: PageId; key: string; val: uint64;
                     splitKey: var string; splitId: var PageId): bool =
  var node: BPlusNode = nil
  for n in db.nodes:
    if n.id == nodeId:
      node = n
      break
  if node == nil: return false
  
  if node.isLeaf:
    let idx = findInsertIndex(node.keys, key)
    doAssert idx >= 0 and idx <= node.keys.len, "insert index out of bounds"
    node.keys.insert(key, idx)
    node.values.insert(val, idx)

    if node.keys.len > MaxKeysPerNode:
      let (sk, sid) = splitLeaf(db, node)
      splitKey = sk
      splitId = sid
      return true
    return false
  else:
    let idx = findInsertIndex(node.keys, key)
    doAssert idx >= 0 and idx < node.children.len, "child index out of bounds"
    let childId = node.children[idx]

    var promoKey: string
    var promoId: PageId
    if insertRecursive(db, childId, key, val, promoKey, promoId):
      let insIdx = findInsertIndex(node.keys, promoKey)
      doAssert insIdx >= 0 and insIdx <= node.keys.len, "promotion insert index out of bounds"
      node.keys.insert(promoKey, insIdx)
      node.children.insert(promoId, insIdx + 1)
      
      if node.keys.len > MaxKeysPerNode:
        let (sk, sid) = splitInternal(db, node)
        splitKey = sk
        splitId = sid
        return true
    return false

proc insert*(db: MetadataDB; key: string; val: uint64) =
  var promoKey: string
  var promoId: PageId
  if insertRecursive(db, db.rootId, key, val, promoKey, promoId):
    let newRootId = db.nextFreeId
    inc db.nextFreeId
    
    let newRoot = BPlusNode(id: newRootId, isLeaf: false)
    newRoot.keys = @[promoKey]
    newRoot.children = @[db.rootId, promoId]
    
    db.nodes.add(newRoot)
    db.rootId = newRootId

proc searchNode(db: MetadataDB; nodeId: PageId; key: string): BPlusNode =
  var node: BPlusNode = nil
  for n in db.nodes:
    if n.id == nodeId:
      node = n
      break
  if node == nil: return nil
  
  if node.isLeaf:
    return node
  else:
    let idx = findInsertIndex(node.keys, key)
    return searchNode(db, node.children[idx], key)

proc keyExists*(db: MetadataDB; key: string): bool =
  ## Fast probe: check if key exists without retrieving value.
  let leaf = searchNode(db, db.rootId, key)
  if leaf == nil: return false
  for i in 0 ..< leaf.keys.len:
    if leaf.keys[i] == key:
      return true
  false

proc keySearch*(db: MetadataDB; key: string; val: var uint64): bool =
  ## Retrieve value for key, returning true if found, false otherwise.
  let leaf = searchNode(db, db.rootId, key)
  if leaf == nil: return false
  for i in 0 ..< leaf.keys.len:
    if leaf.keys[i] == key:
      val = leaf.values[i]
      return true
  false

proc get*(db: MetadataDB; key: string; val: var uint64): bool =
  ## Legacy alias: use keySearch() for clarity.
  keySearch(db, key, val)

proc startsWith(s, prefix: string): bool =
  if prefix.len > s.len: return false
  for i in 0 ..< prefix.len:
    if s[i] != prefix[i]: return false
  true

proc queryPrefix*(db: MetadataDB; prefix: string): seq[tuple[key: string, val: uint64]] =
  var res: seq[tuple[key: string, val: uint64]] = @[]
  var leaf = searchNode(db, db.rootId, prefix)
  
  while leaf != nil:
    var matchedInLeaf = false
    for i in 0 ..< leaf.keys.len:
      let k = leaf.keys[i]
      if startsWith(k, prefix):
        res.add((k, leaf.values[i]))
        matchedInLeaf = true
      elif k > prefix and matchedInLeaf:
        return res
    
    if leaf.nextLeaf == 0: break
    var nextNode: BPlusNode = nil
    for n in db.nodes:
      if n.id == leaf.nextLeaf:
        nextNode = n
        break
    leaf = nextNode
  res

proc serializeDB*(db: MetadataDB): seq[byte] =
  var buf = newSeq[byte](PageSize * (db.nodes.len + 1))
  
  let magic = "NIMIXDB\0"
  for i in 0 ..< 8: buf[i] = byte(magic[i])
  
  let rootId = db.rootId
  buf[8] = byte(rootId and 0xFF)
  buf[9] = byte((rootId shr 8) and 0xFF)
  buf[10] = byte((rootId shr 16) and 0xFF)
  buf[11] = byte((rootId shr 24) and 0xFF)
  
  let nextFreeId = db.nextFreeId
  buf[12] = byte(nextFreeId and 0xFF)
  buf[13] = byte((nextFreeId shr 8) and 0xFF)
  buf[14] = byte((nextFreeId shr 16) and 0xFF)
  buf[15] = byte((nextFreeId shr 24) and 0xFF)
  
  for node in db.nodes:
    let pageOffset = int(node.id) * PageSize
    if pageOffset + PageSize > buf.len:
      buf.setLen(pageOffset + PageSize)
    
    var pageBuf: array[PageSize, byte]
    serializeNode(node, pageBuf)
    
    for i in 0 ..< PageSize:
      buf[pageOffset + i] = pageBuf[i]
      
  buf

proc deserializeDB*(buf: openArray[byte]): MetadataDB =
  let db = MetadataDB(nodes: @[])
  if buf.len < PageSize:
    db.rootId = 1
    db.nextFreeId = 2
    let root = BPlusNode(id: 1, isLeaf: true)
    db.nodes.add(root)
    return db
    
  let magic = "NIMIXDB\0"
  var magicOk = true
  for i in 0 ..< 8:
    if buf[i] != byte(magic[i]): magicOk = false
  if not magicOk:
    db.rootId = 1
    db.nextFreeId = 2
    let root = BPlusNode(id: 1, isLeaf: true)
    db.nodes.add(root)
    return db
    
  db.rootId = uint32(buf[8]) or (uint32(buf[9]) shl 8) or 
              (uint32(buf[10]) shl 16) or (uint32(buf[11]) shl 24)
              
  db.nextFreeId = uint32(buf[12]) or (uint32(buf[13]) shl 8) or 
                  (uint32(buf[14]) shl 16) or (uint32(buf[15]) shl 24)
                  
  let numPages = buf.len div PageSize
  for p in 1 ..< int(numPages):
    let offset = p * PageSize
    var hasData = false
    for i in 0 ..< PageSize:
      if buf[offset + i] != 0:
        hasData = true
        break
    if hasData:
      var pageBuf: array[PageSize, byte]
      for i in 0 ..< PageSize:
        pageBuf[i] = buf[offset + i]
      let node = deserializeNode(uint32(p), pageBuf)
      db.nodes.add(node)
      
  db

proc dumpDB*(db: MetadataDB) =
  kprintln("--- dumpDB start ---")
  defaultSerial.putString("rootId = ")
  defaultSerial.putInt(int64(db.rootId))
  defaultSerial.putChar('\n')
  defaultSerial.putString("nodes.len = ")
  defaultSerial.putInt(int64(db.nodes.len))
  defaultSerial.putChar('\n')
  for n in db.nodes:
    defaultSerial.putString("  node id = ")
    defaultSerial.putInt(int64(n.id))
    defaultSerial.putString(" isLeaf = ")
    defaultSerial.putString(if n.isLeaf: "true" else: "false")
    defaultSerial.putChar('\n')
    defaultSerial.putString("    keys = [")
    for k in n.keys:
      defaultSerial.putString("\"")
      defaultSerial.putString(k)
      defaultSerial.putString("\", ")
    defaultSerial.putString("]\n")
    if n.isLeaf:
      defaultSerial.putString("    values = [")
      for v in n.values:
        defaultSerial.putInt(int64(v))
        defaultSerial.putString(", ")
      defaultSerial.putString("]\n")
    else:
      defaultSerial.putString("    children = [")
      for c in n.children:
        defaultSerial.putInt(int64(c))
        defaultSerial.putString(", ")
      defaultSerial.putString("]\n")
  kprintln("--- dumpDB end ---")
