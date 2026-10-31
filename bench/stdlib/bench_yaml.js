// bench/stdlib/bench_yaml.js — std/yaml (Nim/openparser) vs yaml_js.js.
// Run: bin/carne run bench/stdlib/bench_yaml.js
// Equivalence is asserted first; any mismatch throws before timing.
var nim = require("std/yaml");
var js = require("./yaml_js.js");
var benchmark = require("std/benchmark");

function eq(a, b, what) {
  var sa = JSON.stringify(a), sb = JSON.stringify(b);
  if (sa !== sb) throw new Error("MISMATCH " + what + ": got=" + sa + " want=" + sb);
}

var SMALL = "name: ada\nn: 3\nflag: true\nratio: 1.5\nnothing: null\n" +
  "tags:\n  - fast\n  - typed\nport: 8080\n";
var smallObj = {name: "ada", n: 3, flag: true, ratio: 1.5, nothing: null,
  tags: ["fast", "typed"], port: 8080};

var MEDIUM = "";
for (var i = 0; i < 30; i++) {
  MEDIUM += "svc" + i + ":\n";
  MEDIUM += "  host: node" + i + ".local\n";
  MEDIUM += "  port: " + (8000 + i) + "\n";
  MEDIUM += "  enabled: true\n";
  MEDIUM += "  weight: 0.5\n";
  MEDIUM += "  tags:\n    - web\n    - v" + (i % 3) + "\n";
}
var medObj = nim.parse(MEDIUM);

eq(nim.parse(SMALL), smallObj, "nim parses SMALL");
eq(js.parse(SMALL), smallObj, "js parses SMALL");
eq(nim.parse(MEDIUM), js.parse(MEDIUM), "parse MEDIUM agree");
eq(nim.parse(nim.stringify(smallObj)), smallObj, "nim roundtrip");
eq(js.parse(js.stringify(smallObj)), smallObj, "js roundtrip");
eq(nim.parse(js.stringify(smallObj)), smallObj, "nim reads js output");
eq(js.parse(nim.stringify(smallObj)), smallObj, "js reads nim output");

var out = benchmark.compare({
  "nim parse small": function () { nim.parse(SMALL); },
  "js parse small": function () { js.parse(SMALL); },
  "nim parse medium": function () { nim.parse(MEDIUM); },
  "js parse medium": function () { js.parse(MEDIUM); },
  "nim stringify": function () { nim.stringify(medObj); },
  "js stringify": function () { js.stringify(medObj); }
}, {iterations: 500, warmup: 50});

var names = ["nim parse small", "js parse small", "nim parse medium",
  "js parse medium", "nim stringify", "js stringify"];
console.log("op | nim us | js us | winner");
for (var i = 0; i < names.length; i += 2) {
  var n = out.results[names[i]], j = out.results[names[i + 1]];
  var w = n.meanMs < j.meanMs ? "nim" : "js";
  console.log(names[i].slice(4) + " | " + (n.meanMs * 1000).toFixed(2) + " | " +
    (j.meanMs * 1000).toFixed(2) + " | " + w + " x" +
    (Math.max(n.meanMs, j.meanMs) / Math.min(n.meanMs, j.meanMs)).toFixed(2));
}
console.log("medium doc lines: " + MEDIUM.split("\n").length);
