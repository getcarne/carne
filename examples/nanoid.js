const {nanoid, customAlphabet} = require("std/nanoid");

console.log("id: " + nanoid().length);
console.log("short: " + nanoid(10));
console.log("custom: " + customAlphabet("abc123", 8));
console.log("alphabet: " + require("std/nanoid").urlAlphabet.length);
