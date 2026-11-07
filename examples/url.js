const url = require("std/url");

const u = url.parse("https://user:pw@host:8080/p?q=1&r=#frag");
console.log("host: " + u.hostname + ":" + u.port);
console.log("query: " + u.query.length);
console.log("roundtrip: " + url.format(u));
console.log("encode: " + url.encode("a b/c"));
console.log("query: " + url.stringifyQuery({a: "1", b: "x y"}));
