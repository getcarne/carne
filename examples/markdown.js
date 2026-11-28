const md = require("std/markdown");

const doc = "# Hello\n\n**bold**, *italic* and ~~struck~~.\n\n- [x] shipped\n- [ ] docs\n";
console.log("html: " + md.toHtml(doc));
console.log("no anchors: " + md.toHtml("# Hello", {enableAnchors: false}));
console.log("toc: " + JSON.stringify(md.toc("# Hello\n## World")));
console.log("title: " + md.title("# Hello\n\nbody text"));
console.log("fields: " +
  JSON.stringify(md.frontMatter("---\ntitle: Hi\nversion: 2\n---\n# Hello")));
console.log("ast kind: " + md.toAst("# Hello")[0].kind);
console.log("table: " +
  md.toHtml("| a | b |\n|---|---|\n| 1 | 2 |", {htmlTableClasses: ["table"]}));
console.log("footnote: " + md.toHtml("hi[^1]\n\n[^1]: a note"));
console.log("email: " + md.toHtml("<a@b.test>", {enableEmailAutolinks: true}));
console.log("gated: " + md.toHtml("<div>\nraw\n</div>", {allowed: ["div"]}));
