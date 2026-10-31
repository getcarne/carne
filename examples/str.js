const str = require("std/str");

console.log(str.indexOf("hello world", "world"));
console.log(str.count("aaa", "aa"));
console.log(str.trim("  padded  "));
console.log(str.toUpperCase("hello"));
console.log(JSON.stringify(str.lines("a\nb\nc")));
console.log(str.camelCase("hello-world_foo"));
console.log(str.snakeCase("helloWorld"));
console.log(str.slugify("Hello, World!"));
console.log(str.levenshtein("kitten", "sitting"));
console.log(str.escapeHtml("<a>&"));
console.log(str.wordWrap("aa bb cc dd ee", 8));
console.log(str.stripAnsi("\x1B[31mred\x1B[0m"));
