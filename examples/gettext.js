const gettext = require("std/gettext");

const po = [
  'msgid ""', 'msgstr ""',
  '"Project-Id-Version: carne-demo\\n"',
  '"Language: fr\\n"',
  '"Plural-Forms: nplurals=2; plural=(n > 1);\\n"',
  '',
  '#: src/app.js:12',
  'msgid "Hello"', 'msgstr "Bonjour"',
  '',
  'msgid "apple"', 'msgid_plural "apples"',
  'msgstr[0] "pomme"', 'msgstr[1] "pommes"',
  ''
].join("\n");

// Catalog structure.
const cat = gettext.parse(po);
console.log("language: " + cat.headers["Language"]);
for (const e of cat.entries)
  console.log("entry: " + e.msgid + " -> " + e.msgstr.join(" / "));

// Runtime translation with fallback and plurals.
console.log(gettext.translate(po, "Hello"));
console.log(gettext.translate(po, "Untranslated string"));
for (const n of [1, 3])
  console.log(n + " " + gettext.ntranslate(po, "apple", "apples", n));

// Binary catalogs load from a file path instead of a string.
const mo = "tests/fixtures/gettext.mo";
console.log("mo: " + gettext.translateMo(mo, "Hello"));
console.log("mo plural: " + gettext.ntranslateMo(mo, "apple", "apples", 3));
