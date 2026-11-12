const csv = require("std/csv");

const rows = csv.parse('name,age,city\nada,36,London\n"grace, h.",85,New York\n');
console.log("rows: " + rows.length);
console.log("first: " + rows[1].join(" | "));

const people = csv.parse('name,age\nada,36\ngrace,85', {headers: true});
console.log("ada is " + people[0].age);
console.log("grace lives nowhere yet: '" + (people[1].city || "") + "'");

const semi = csv.parse('a;b\n1;2', {delimiter: ";"});
console.log("custom delimiter: " + JSON.stringify(semi));

console.log("stringify rows: " + csv.stringify([["a", "b"], ["1", "2"]]));
console.log("stringify objects: " +
  csv.stringify([{name: "ada", age: 36}, {name: "grace", age: 85}]));
console.log("roundtrip: " +
  JSON.stringify(csv.parse(csv.stringify([["a", "b"], ["x,y", "3"]]))));
