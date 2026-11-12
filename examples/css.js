const css = require("std/css");

// Stylesheet structure.
const sheet = css.parse([
  "/* theme */",
  ":root { --brand: #3498db; }",
  ".card, #main .card:hover {",
  "  color: var(--brand);",
  "  margin: 0 auto !important;",
  "}",
  "@media screen and (max-width: 600px) {",
  "  .card { width: 100%; }",
  "}"
].join("\n"));

for (const rule of sheet.rules) {
  if (rule.kind === "RuleSet")
    console.log("rule: " + rule.selectors.map(s => s.parts.join("")).join(", ") +
      " [" + rule.declarations.map(d => d.property).join(", ") + "]");
  else if (rule.kind === "AtRule")
    console.log("at-rule: @" + rule.name + " " + rule.prelude +
      " (" + rule.rules.length + " nested)");
  else
    console.log("comment: " + rule.text.trim());
}

// Declaration lint: clean sheets report nothing.
const bad = "a { colour: red; width: nope; margin: 0; }";
for (const p of css.validate(bad))
  console.log("problem: " + p.property + " = " + p.value + " -> " +
    p.errors[0].message);
console.log("clean: " + JSON.stringify(css.validate("a { margin: 0; }")));

// Serialization roundtrip through the AST.
const cssOut = css.stringify(sheet);
console.log("stringify has rule: " + cssOut.includes(".card"));
console.log("re-parse rules: " + css.parse(cssOut).rules.length);
