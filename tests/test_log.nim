# SPDX-License-Identifier: GPL-2.0
## Tests for log level types (no serial hardware needed)

import ../core/log_types

proc testLogLevels() =
  assert ord(llDebug) < ord(llInfo),  "DEBUG must be lower than INFO"
  assert ord(llInfo)  < ord(llWarn),  "INFO must be lower than WARN"
  assert ord(llWarn)  < ord(llError), "WARN must be lower than ERROR"
  assert ord(llError) < ord(llPanic), "ERROR must be lower than PANIC"
  echo "PASS: log levels ordered correctly"

proc testLogLevelValues() =
  assert ord(llDebug) == 0
  assert ord(llInfo)  == 1
  assert ord(llWarn)  == 2
  assert ord(llError) == 3
  assert ord(llPanic) == 4
  echo "PASS: log level values are correct"

proc testKernelLogLevelDefault() =
  assert KernelLogLevel == 1, "Default log level should be INFO (1)"
  echo "PASS: default kernel log level is INFO"

when isMainModule:
  testLogLevels()
  testLogLevelValues()
  testKernelLogLevelDefault()
  echo "All log tests passed."
