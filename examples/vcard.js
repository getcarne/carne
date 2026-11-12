const vcard = require("std/vcard");

const cards = vcard.parse([
  "BEGIN:VCARD",
  "VERSION:4.0",
  "FN:Ada Lovelace",
  "N:Lovelace;Ada;;;",
  "NICKNAME:Queen of Numbers",
  "EMAIL;TYPE=work:ada@example.com",
  "TEL;TYPE=voice:+1000",
  "ORG:Analytical Engines;Research",
  "END:VCARD",
  "BEGIN:VCARD",
  "VERSION:4.0",
  "FN:Grace Hopper",
  "EMAIL:grace@example.com",
  "END:VCARD",
  ""
].join("\r\n"));

console.log("cards: " + cards.length);
console.log("first: " + cards[0].fn + " (" + cards[0].n.given +
  " " + cards[0].n.family + ")");
console.log("nicknames: " + cards[0].nicknames.join(", "));
console.log("email: " + cards[0].emails[0].value +
  " [" + cards[0].emails[0].types.join(", ") + "]");
console.log("org: " + cards[0].org.name);
console.log("second phone count: " + cards[1].tels.length);

const out = vcard.stringify(cards);
console.log("stringify has VCARD: " + out.includes("BEGIN:VCARD"));
console.log("re-parse fn: " + vcard.parse(out)[0].fn);
