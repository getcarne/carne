// bench/stdlib/bench_yaml_full.js — full-grammar std/yaml characterization.
// Run: bin/carne run bench/stdlib/bench_yaml_full.js
// Covers what the bench subset cannot parse: anchors/merge, tags,
// timestamps (-> Date), block scalars, flow, quotes, directives.
// Roundtrip equivalence is asserted first; any mismatch throws.
var yaml = require("std/yaml");
var benchmark = require("std/benchmark");

function canon(v) {
  if (v instanceof Date) return "Date:" + v.toISOString();
  if (Array.isArray(v)) return v.map(canon);
  if (v !== null && typeof v === "object") {
    var o = {};
    for (var k in v) {
      if (Object.prototype.hasOwnProperty.call(v, k)) o[k] = canon(v[k]);
    }
    return o;
  }
  return v;
}

function eq(a, b, what) {
  var sa = JSON.stringify(canon(a)), sb = JSON.stringify(canon(b));
  if (sa !== sb) throw new Error("MISMATCH " + what);
}

// Representative service-config doc exercising the full grammar.
var FULL = "%YAML 1.2\n---\n" +
  "defaults: &def\n" +
  "  retries: 3\n" +
  "  timeout: 1.5\n" +
  "  enabled: true\n" +
  "  tags: [stable, !!str 42]\n" +
  "services:\n" +
  "  - name: web\n" +
  "    <<: *def\n" +
  "    host: node0.local\n" +
  "    port: 8080\n" +
  "    since: 2001-02-03\n" +
  "    deployed: 2001-12-15T02:59:43.1Z\n" +
  "    blurb: |\n" +
  "      Serves traffic.\n" +
  "      Two lines.\n" +
  "    notes: >\n" +
  "      Folded\n" +
  "      prose here.\n" +
  "    opts: {tls: true, weight: 0.5, label: \"quoted: value\"}\n" +
  "  - name: db\n" +
  "    <<: *def\n" +
  "    host: node1.local\n" +
  "    port: 5432\n" +
  "    since: 2002-12-14\n" +
  "    deployed: 2003-01-02 03:04:05\n" +
  "    blurb: |-\n" +
  "      No trailing break.\n" +
  "    notes: 'single ''quoted'''\n" +
  "    opts: {tls: false, weight: 1.0, extra: null}\n" +
  "misc:\n" +
  "  ratio: .inf\n" +
  "  missing: ~\n" +
  "  hex: 0xFF\n" +
  "  oct: 0o17\n" +
  "  big: 1_000_000\n" +
  "  legacy: [yes, no, on, 1:20]\n";

var fullObj = yaml.parse(FULL);
eq(yaml.parse(yaml.stringify(fullObj)), fullObj, "full roundtrip");

var out = benchmark.compare({
  "parse full": function () { yaml.parse(FULL); },
  "stringify full": function () { yaml.stringify(fullObj); }
}, {iterations: 300, warmup: 30});

var kb = FULL.length / 1024;
var p = out.results["parse full"], s = out.results["stringify full"];
console.log("op | mean us | KB/s");
console.log("parse full | " + (p.meanMs * 1000).toFixed(2) + " | " +
  (kb / p.meanMs * 1000).toFixed(1));
console.log("stringify full | " + (s.meanMs * 1000).toFixed(2) + " | " +
  (kb / s.meanMs * 1000).toFixed(1));
console.log("doc bytes: " + FULL.length + ", lines: " + FULL.split("\n").length);
console.log("dates parsed: " + (fullObj.services[0].since instanceof Date));
