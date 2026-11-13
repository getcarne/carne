import unittest

import carne
import carne/modules
import carne/std/benchmark

registerStd("std/benchmark", benchmark.install)

test "measure returns stats with requested iteration count":
  check runCode(
    "const r = require('std/benchmark').measure(() => 1, {iterations: 20}); " &
    "JSON.stringify([r.iterations, typeof r.totalMs, typeof r.meanMs, " &
    "typeof r.medianMs, typeof r.minMs, typeof r.maxMs, " &
    "typeof r.stddevMs, typeof r.opsPerSec, typeof r.cpuMs, " &
    "typeof r.rssPeak, typeof r.heapDelta])") ==
    """[20,"number","number","number","number","number","number","number","number","number","number"]"""

test "measure stats are ordered and positive":
  check runCode(
    "const r = require('std/benchmark').measure(() => Math.sqrt(2), " &
    "{iterations: 50, warmup: 5}); " &
    "JSON.stringify([r.minMs <= r.medianMs && r.medianMs <= r.maxMs, " &
    "r.minMs >= 0, r.totalMs >= r.maxMs, r.opsPerSec > 0, r.rssPeak > 0])") ==
    """[true,true,true,true,true]"""

test "measure defaults to 100 iterations":
  check runCode(
    "require('std/benchmark').measure(() => 1).iterations") == "100"

test "measure rejects bad options":
  expect CarneError:
    discard runCode("require('std/benchmark').measure(() => 1, {iterations: 0})")
  expect CarneError:
    discard runCode(
      "require('std/benchmark').measure(() => 1, {iterations: 1.5})")
  expect CarneError:
    discard runCode("require('std/benchmark').measure(42)")

test "measure propagates the original throw":
  check runCode(
    "try { require('std/benchmark').measure(() => { throw new Error('boom'); }); " &
    "} catch (e) { e.message; }") == "boom"

test "compare ranks two functions and anchors speedup":
  # Workloads differ by ~1000x in absolute ms terms (not just a loop
  # ratio at the microsecond scale), with warmup so JIT tier-up
  # happens before sampling: on noisy virtualized runners 20 raw
  # samples of microsecond bodies invert (macos-15-intel did).
  check runCode(
    "const b = require('std/benchmark'); " &
    "const slow = () => { let s = 0; for (let i = 0; i < 200000; i++) s += Math.sqrt(i); return s; }; " &
    "const fast = () => { let s = 0; for (let i = 0; i < 50; i++) s += Math.sqrt(i); return s; }; " &
    "const c = b.compare({slow: slow, fast: fast}, {iterations: 30, warmup: 10}); " &
    "JSON.stringify([c.fastest, c.ranking[0], c.ranking.length, " &
    "c.speedup.slow === 1, c.speedup.fast > 1, " &
    "Object.keys(c.results).length])") ==
    """["fast","fast",2,true,true,2]"""

test "compare needs at least one function":
  expect CarneError:
    discard runCode("require('std/benchmark').compare({})")

test "clocks and memory snapshots read sane":
  check runCode(
    "const b = require('std/benchmark'); " &
    "const t = b.now(); " &
    "JSON.stringify([t > 1700000000000, b.cpu() >= 0, " &
    "b.memory().rssPeak > 0, b.memory().heap >= 0])") ==
    """[true,true,true,true]"""
