const svg = require("std/svg");

const doc = svg.parse([
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">',
  '  <rect x="10" y="10" width="80" height="80" fill="rebeccapurple"/>',
  '  <circle cx="50" cy="50" r="30" fill="white"/>',
  '  <text x="50" y="55">hi</text>',
  '</svg>'
].join("\n"));

console.log("root: " + doc.tag + " " + doc.attrs.viewBox);
for (const el of doc.children.filter(c => c.kind === "element"))
  console.log("child: " + el.tag + " " + JSON.stringify(el.attrs));
const text = doc.children.find(c => c.tag === "text");
console.log("caption: " + text.children[0].text);
console.log("remake: " + svg.stringify(doc).slice(0, 60) + "...");
