## Tests for metadata_db improvements: probe vs value queries, bounds checking

import ../fs/metadata_db

proc testProbeQueries*() =
  ## RED: Test separating keyExists (bool) from keySearch (Option)
  let db = initDB()

  # Insert a key
  db.insert("file.txt", 42'u64)

  # Test keyExists returns bool
  doAssert db.keyExists("file.txt") == true, "keyExists should return true for existing key"
  doAssert db.keyExists("missing.txt") == false, "keyExists should return false for missing key"

  # Test keySearch returns bool
  var val: uint64
  let found = db.keySearch("file.txt", val)
  doAssert found == true, "keySearch should return true for existing key"
  doAssert val == 42'u64, "keySearch should return correct value"

  let notFound = db.keySearch("missing.txt", val)
  doAssert notFound == false, "keySearch should return false for missing key"

  echo "✓ testProbeQueries passed"

proc testBoundsChecking*() =
  ## RED: Test that insert bounds checks work
  let db = initDB()

  # Insert keys up to max capacity
  for i in 0 ..< MaxKeysPerNode:
    db.insert("key" & $i, uint64(i))

  # This insert should trigger split; no bounds error
  db.insert("extra", 999'u64)

  # Verify all keys are present
  doAssert db.keyExists("key0") == true
  doAssert db.keyExists("extra") == true

  echo "✓ testBoundsChecking passed"

proc testMultipleInserts*() =
  ## GREEN: Verify basic multi-insert works correctly
  let db = initDB()

  db.insert("alice", 1'u64)
  db.insert("bob", 2'u64)
  db.insert("charlie", 3'u64)

  doAssert db.keyExists("alice") == true
  doAssert db.keyExists("bob") == true
  doAssert db.keyExists("charlie") == true
  doAssert db.keyExists("dave") == false

  echo "✓ testMultipleInserts passed"

when isMainModule:
  testMultipleInserts()
  testProbeQueries()
  testBoundsChecking()
