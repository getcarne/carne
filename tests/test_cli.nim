import unittest

import carne/cli

test "confirm declines without a tty":
  ## Test runners pipe stdin, so this deterministically takes the
  ## non-interactive path (never blocks, never confirms).
  check confirm("Remove foo?") == false

test "spinner stays idle without a tty":
  ## Test runners pipe stdout: no thread starts, stop is a no-op.
  check spinnerActive() == false
  var s = startSpinner("Installing packages...")
  check s.running == false
  check spinnerActive() == false
  stopSpinner(s)
  check spinnerActive() == false

test "withSpinner runs the body without a tty":
  var ran = false
  withSpinner("Installing packages..."):
    ran = true
  check ran == true
  check spinnerActive() == false

test "withSpinner propagates exceptions after stopping":
  expect CatchableError:
    withSpinner("Installing packages..."):
      raise newException(CatchableError, "boom")
  check spinnerActive() == false
