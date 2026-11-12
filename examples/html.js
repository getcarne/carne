const html = require("std/html");

const doc = html.parse("<p>hi <b>ada</b></p>");
console.log("nodes: " + doc.length);
console.log("tag: " + doc[0].tag);
console.log("text: " + html.innerText(doc));
console.log("bold: " + html.innerText(doc[0].children[1]));
console.log("div is block: " + html.isBlock("div"));
console.log("span is inline: " + html.isInline("span"));
console.log("stringify: " + html.stringify(doc));
console.log("re-parse tag: " + html.parse(html.stringify(doc))[0].tag);
