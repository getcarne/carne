// bench/stdlib/bench_str.js — std/str vs native JS String builtins.
// Run: bin/carne run bench/stdlib/bench_str.js
// Equivalence is asserted first; any mismatch throws before timing.
var str = require("std/str");
var benchmark = require("std/benchmark");

function eq(a, b, what) {
  var sa = JSON.stringify(a), sb = JSON.stringify(b);
  if (sa !== sb) throw new Error("MISMATCH " + what + ": got=" + sa + " want=" + sb);
}

// ~256KB ASCII log-like corpus (SIMD path on both sides).
var BIG = "";
for (var i = 0; i < 4000; i++) {
  BIG += "2026-01-01 node" + (i % 64) + ".local svc=" + (i % 8) +
    " status=ok latency=" + (i % 97) + "ms path=/api/v1/items\n";
}
var NEEDLE = "latency=42ms";

eq(str.indexOf(BIG, NEEDLE), BIG.indexOf(NEEDLE), "indexOf hit");
eq(str.indexOf(BIG, "missing-needle-xyz"), BIG.indexOf("missing-needle-xyz"), "indexOf miss");
eq(str.lastIndexOf(BIG, NEEDLE), BIG.lastIndexOf(NEEDLE), "lastIndexOf");
eq(str.includes(BIG, NEEDLE), BIG.indexOf(NEEDLE) >= 0, "includes");
eq(str.count(BIG, "status=ok"), BIG.split("status=ok").length - 1, "count");
eq(str.trim("  " + BIG.slice(0, 1000) + "  "), BIG.slice(0, 1000).trim(), "trim");
eq(str.toUpperCase(BIG), BIG.toUpperCase(), "upper");
eq(str.toLowerCase(BIG), BIG.toLowerCase(), "lower");
eq(str.lines(BIG), BIG.split("\n"), "lines");
eq(str.startsWith(BIG, "2026"), true, "startsWith");
eq(str.endsWith(BIG, "\n"), true, "endsWith");

var out = benchmark.compare({
  "std indexOf hit": function () { str.indexOf(BIG, NEEDLE); },
  "js indexOf hit": function () { BIG.indexOf(NEEDLE); },
  "std indexOf miss": function () { str.indexOf(BIG, "missing-needle-xyz"); },
  "js indexOf miss": function () { BIG.indexOf("missing-needle-xyz"); },
  "std lastIndexOf": function () { str.lastIndexOf(BIG, NEEDLE); },
  "js lastIndexOf": function () { BIG.lastIndexOf(NEEDLE); },
  "std count": function () { str.count(BIG, "status=ok"); },
  "js count": function () { BIG.split("status=ok").length - 1; },
  "std trim": function () { str.trim("  " + BIG.slice(0, 1000) + "  "); },
  "js trim": function () { BIG.slice(0, 1000).trim(); },
  "std upper": function () { str.toUpperCase(BIG); },
  "js upper": function () { BIG.toUpperCase(); },
  "std lower": function () { str.toLowerCase(BIG); },
  "js lower": function () { BIG.toLowerCase(); },
  "std lines": function () { str.lines(BIG); },
  "js split": function () { BIG.split("\n"); }
}, {iterations: 200, warmup: 20});

var pairs = [["std indexOf hit", "js indexOf hit"],
  ["std indexOf miss", "js indexOf miss"],
  ["std lastIndexOf", "js lastIndexOf"],
  ["std count", "js count"],
  ["std trim", "js trim"],
  ["std upper", "js upper"],
  ["std lower", "js lower"],
  ["std lines", "js split"]];
console.log("op | std us | js us | winner");
for (var i = 0; i < pairs.length; i++) {
  var a = out.results[pairs[i][0]], b = out.results[pairs[i][1]];
  var w = a.meanMs < b.meanMs ? "std" : "js";
  console.log(pairs[i][0].slice(4) + " | " + (a.meanMs * 1000).toFixed(2) +
    " | " + (b.meanMs * 1000).toFixed(2) + " | " + w + " x" +
    (Math.max(a.meanMs, b.meanMs) / Math.min(a.meanMs, b.meanMs)).toFixed(2));
}
console.log("corpus bytes: " + BIG.length);
