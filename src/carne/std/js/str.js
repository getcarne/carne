// Carne std/str: string utilities (pure JS).
//
//   const str = require("std/str");
//   str.indexOf(hay, needle)  -> int (-1 when absent)
//   str.toUpperCase(s)        -> string
//   str.lines(s)              -> array of strings
//   str.isEmail(s)            -> bool
//
// Free-function style: the subject string is always the first argument.
// Semantics are exactly the JS builtins' wherever one exists (UTF-16
// indices, locale-independent Unicode case mapping); the extras follow
// the documented rules below. Argument types are checked strictly
// (non-strings throw); validators instead return false on non-strings.
"use strict";
/*
 * @typedef {Array<string>} StrArray - Array of strings.
 */

// -- guards ----------------------------------------------------------------

/*
 * JS typeof name for type-mismatch errors (null/array distinguished).
 * @param {any} v - Value to classify.
 * @returns {string} The JS type name.
 */
function jsKind(v) {
  if (v === null) return "null";
  if (Array.isArray(v)) return "array";
  return typeof v;
}

/*
 * Requires at least `min` arguments.
 * @param {string} fname - Function name for errors.
 * @param {number} given - arguments.length at the call site.
 * @param {number} min - Minimum accepted arity.
 * @returns {void} Throws on too few arguments.
 */
function arity(fname, given, min) {
  if (given < min) {
    throw new Error(fname + ": expected at least " + min +
      " argument(s), got " + given);
  }
}

/*
 * Requires a string argument.
 * @param {string} fname - Function name for errors.
 * @param {string} pname - Parameter name for errors.
 * @param {any} v - The value to check.
 * @returns {string} The value, narrowed to string.
 */
function reqStr(fname, pname, v) {
  if (typeof v !== "string") {
    throw new Error(fname + ": type mismatch parameter: `" + pname +
      "`. Got `" + jsKind(v) + "`, expected `string`");
  }
  return v;
}

/*
 * Requires a number argument.
 * @param {string} fname - Function name for errors.
 * @param {string} pname - Parameter name for errors.
 * @param {any} v - The value to check.
 * @returns {number} The value, narrowed to number.
 */
function reqNum(fname, pname, v) {
  if (typeof v !== "number") {
    throw new Error(fname + ": type mismatch parameter: `" + pname +
      "`. Got `" + jsKind(v) + "`, expected `number`");
  }
  return v;
}

// -- search ------------------------------------------------------------------

/*
 * First UTF-16 offset of needle at/after from, -1 when absent.
 * @param {string} s - Haystack.
 * @param {string} needle - Needle.
 * @param {number} [from] - Start offset (default 0).
 * @returns {number} The offset or -1.
 */
function indexOf(s, needle, from) {
  arity("indexOf", arguments.length, 2);
  reqStr("indexOf", "s", s);
  reqStr("indexOf", "needle", needle);
  return from === undefined ? s.indexOf(needle) : s.indexOf(needle, from);
}

/*
 * Last UTF-16 offset of needle at/before from, -1 when absent.
 * @param {string} s - Haystack.
 * @param {string} needle - Needle.
 * @param {number} [from] - End offset (default: end of string).
 * @returns {number} The offset or -1.
 */
function lastIndexOf(s, needle, from) {
  arity("lastIndexOf", arguments.length, 2);
  reqStr("lastIndexOf", "s", s);
  reqStr("lastIndexOf", "needle", needle);
  return from === undefined ? s.lastIndexOf(needle) :
    s.lastIndexOf(needle, from);
}

/*
 * True when needle occurs at/after from.
 * @param {string} s - Haystack.
 * @param {string} needle - Needle.
 * @param {number} [from] - Start offset (default 0).
 * @returns {boolean} Found or not.
 */
function includes(s, needle, from) {
  arity("includes", arguments.length, 2);
  reqStr("includes", "s", s);
  reqStr("includes", "needle", needle);
  return from === undefined ? s.includes(needle) :
    s.includes(needle, from);
}

/*
 * Counts non-overlapping occurrences; empty needle gives length + 1.
 * @param {string} s - Haystack.
 * @param {string} needle - Needle (must not be undefined).
 * @returns {number} The count.
 */
function count(s, needle) {
  arity("count", arguments.length, 2);
  reqStr("count", "s", s);
  reqStr("count", "needle", needle);
  if (needle === "") return s.length + 1;
  var n = 0, pos = 0;
  for (;;) {
    var hit = s.indexOf(needle, pos);
    if (hit < 0) return n;
    n++;
    pos = hit + needle.length;
  }
}

/*
 * True for an exact (===) match.
 * @param {string} a - First string.
 * @param {string} b - Second string.
 * @returns {boolean} Equal or not.
 */
function equals(a, b) {
  arity("equals", arguments.length, 2);
  reqStr("equals", "a", a);
  reqStr("equals", "b", b);
  return a === b;
}

/*
 * True when s starts with prefix.
 * @param {string} s - Haystack.
 * @param {string} prefix - Prefix.
 * @returns {boolean} Match or not.
 */
function startsWith(s, prefix) {
  arity("startsWith", arguments.length, 2);
  reqStr("startsWith", "s", s);
  reqStr("startsWith", "prefix", prefix);
  return s.startsWith(prefix);
}

/*
 * True when s ends with suffix.
 * @param {string} s - Haystack.
 * @param {string} suffix - Suffix.
 * @returns {boolean} Match or not.
 */
function endsWith(s, suffix) {
  arity("endsWith", arguments.length, 2);
  reqStr("endsWith", "s", s);
  reqStr("endsWith", "suffix", suffix);
  return s.endsWith(suffix);
}

// -- case and trim -------------------------------------------------------------

/*
 * Upper-cases (JS semantics, locale-independent).
 * @param {string} s - Input.
 * @returns {string} The upper-cased string.
 */
function toUpperCase(s) {
  arity("toUpperCase", arguments.length, 1);
  reqStr("toUpperCase", "s", s);
  return s.toUpperCase();
}

/*
 * Lower-cases (JS semantics, locale-independent).
 * @param {string} s - Input.
 * @returns {string} The lower-cased string.
 */
function toLowerCase(s) {
  arity("toLowerCase", arguments.length, 1);
  reqStr("toLowerCase", "s", s);
  return s.toLowerCase();
}

/*
 * Strips leading and trailing JS whitespace.
 * @param {string} s - Input.
 * @returns {string} The trimmed string.
 */
function trim(s) {
  arity("trim", arguments.length, 1);
  reqStr("trim", "s", s);
  return s.trim();
}

/*
 * Strips leading JS whitespace.
 * @param {string} s - Input.
 * @returns {string} The trimmed string.
 */
function trimStart(s) {
  arity("trimStart", arguments.length, 1);
  reqStr("trimStart", "s", s);
  return s.trimStart();
}

/*
 * Strips trailing JS whitespace.
 * @param {string} s - Input.
 * @returns {string} The trimmed string.
 */
function trimEnd(s) {
  arity("trimEnd", arguments.length, 1);
  reqStr("trimEnd", "s", s);
  return s.trimEnd();
}

/*
 * True when every UTF-16 unit is below 0x80.
 * @param {string} s - Input.
 * @returns {boolean} ASCII-only or not.
 */
function isAscii(s) {
  arity("isAscii", arguments.length, 1);
  reqStr("isAscii", "s", s);
  return /^[\x00-\x7F]*$/.test(s);
}

/*
 * True when empty or all JS whitespace.
 * @param {string} s - Input.
 * @returns {boolean} Blank or not.
 */
function isBlank(s) {
  arity("isBlank", arguments.length, 1);
  reqStr("isBlank", "s", s);
  return s.trim() === "";
}

// -- split and join --------------------------------------------------------------

/*
 * Splits on \n, stripping one trailing \r per line. "" gives [""].
 * @param {string} s - Input.
 * @returns {StrArray} The lines.
 */
function lines(s) {
  arity("lines", arguments.length, 1);
  reqStr("lines", "s", s);
  var parts = s.split("\n");
  for (var i = 0; i < parts.length; i++) {
    var line = parts[i];
    if (line.length > 0 && line[line.length - 1] === "\r") {
      parts[i] = line.slice(0, -1);
    }
  }
  return parts;
}

/*
 * Splits on a separator ("" splits into UTF-16 units, like JS).
 * @param {string} s - Input.
 * @param {string} sep - Separator.
 * @returns {StrArray} The pieces.
 */
function split(s, sep) {
  arity("split", arguments.length, 2);
  reqStr("split", "s", s);
  reqStr("split", "sep", sep);
  return s.split(sep);
}

/*
 * Joins a string array; every element must be a string.
 * @param {Array<any>} parts - Pieces to join.
 * @param {string} [sep] - Separator (default ",").
 * @returns {string} The joined string.
 */
function join(parts, sep) {
  arity("join", arguments.length, 1);
  if (!Array.isArray(parts)) {
    throw new Error("join: type mismatch parameter: `parts`. Got `" +
      jsKind(parts) + "`, expected `array`");
  }
  if (sep === undefined) sep = ",";
  reqStr("join", "sep", sep);
  for (var i = 0; i < parts.length; i++) {
    if (typeof parts[i] !== "string") {
      throw new Error("join: type mismatch parameter: `parts[" + i +
        "]`. Got `" + jsKind(parts[i]) + "`, expected `string`");
    }
  }
  return parts.join(sep);
}

/*
 * Splits on JS-whitespace runs, dropping empties ("" gives []).
 * @param {string} s - Input.
 * @returns {StrArray} The words.
 */
function words(s) {
  arity("words", arguments.length, 1);
  reqStr("words", "s", s);
  var t = s.trim();
  return t === "" ? [] : t.split(/\s+/);
}

// -- replace ---------------------------------------------------------------------

/*
 * Replaces the first occurrence ("" inserts at 0, like JS).
 * @param {string} s - Input.
 * @param {string} search - Search string.
 * @param {string} replacement - Replacement.
 * @returns {string} The result.
 */
function replace(s, search, replacement) {
  arity("replace", arguments.length, 3);
  reqStr("replace", "s", s);
  reqStr("replace", "search", search);
  reqStr("replace", "replacement", replacement);
  return s.replace(search, function () { return replacement; });
}

/*
 * Replaces every non-overlapping occurrence ("" wraps every unit).
 * @param {string} s - Input.
 * @param {string} search - Search string.
 * @param {string} replacement - Replacement.
 * @returns {string} The result.
 */
function replaceAll(s, search, replacement) {
  arity("replaceAll", arguments.length, 3);
  reqStr("replaceAll", "s", s);
  reqStr("replaceAll", "search", search);
  reqStr("replaceAll", "replacement", replacement);
  if (search === "") {
    return replacement + s.split("").join(replacement) + replacement;
  }
  return s.split(search).join(replacement);
}

// -- shape -------------------------------------------------------------------------

/*
 * JS slice (UTF-16 units, negatives count from the end).
 * @param {string} s - Input.
 * @param {number} [start] - Start index (default 0).
 * @param {number} [end] - End index (default end of string).
 * @returns {string} The slice.
 */
function slice(s, start, end) {
  arity("slice", arguments.length, 1);
  reqStr("slice", "s", s);
  if (start !== undefined) reqNum("slice", "start", start);
  if (end !== undefined) reqNum("slice", "end", end);
  return s.slice(start, end);
}

/*
 * Pads on the left to width (UTF-16 units, like JS).
 * @param {string} s - Input.
 * @param {number} width - Target width.
 * @param {string} [pad] - Fill string (default " ").
 * @returns {string} The padded string.
 */
function padStart(s, width, pad) {
  arity("padStart", arguments.length, 2);
  reqStr("padStart", "s", s);
  reqNum("padStart", "width", width);
  if (pad !== undefined) reqStr("padStart", "pad", pad);
  return pad === undefined ? s.padStart(width) : s.padStart(width, pad);
}

/*
 * Pads on the right to width (UTF-16 units, like JS).
 * @param {string} s - Input.
 * @param {number} width - Target width.
 * @param {string} [pad] - Fill string (default " ").
 * @returns {string} The padded string.
 */
function padEnd(s, width, pad) {
  arity("padEnd", arguments.length, 2);
  reqStr("padEnd", "s", s);
  reqNum("padEnd", "width", width);
  if (pad !== undefined) reqStr("padEnd", "pad", pad);
  return pad === undefined ? s.padEnd(width) : s.padEnd(width, pad);
}

/*
 * Centers in width (extra padding goes right; empty pad is a no-op).
 * @param {string} s - Input.
 * @param {number} width - Target width.
 * @param {string} [pad] - Fill string (default " ").
 * @returns {string} The padded string.
 */
function padCenter(s, width, pad) {
  arity("padCenter", arguments.length, 2);
  reqStr("padCenter", "s", s);
  reqNum("padCenter", "width", width);
  if (pad === undefined) pad = " ";
  reqStr("padCenter", "pad", pad);
  if (s.length >= width || pad === "") return s;
  var total = width - s.length, left = Math.floor(total / 2);
  var fill = "";
  while (fill.length < total) fill += pad;
  return fill.slice(0, left) + s + fill.slice(left, total);
}

/*
 * Repeats (native RangeError on negative/huge counts).
 * @param {string} s - Input.
 * @param {number} n - Repetitions.
 * @returns {string} The repeated string.
 */
function repeat(s, n) {
  arity("repeat", arguments.length, 2);
  reqStr("repeat", "s", s);
  reqNum("repeat", "n", n);
  return s.repeat(n);
}

/*
 * Reverses by code points (astral characters stay intact).
 * @param {string} s - Input.
 * @returns {string} The reversed string.
 */
function reverse(s) {
  arity("reverse", arguments.length, 1);
  reqStr("reverse", "s", s);
  return Array.from(s).reverse().join("");
}

/*
 * Cuts to maxLen code points, appending ellipsis when cut.
 * @param {string} s - Input.
 * @param {number} maxLen - Kept code points (must be >= 0).
 * @param {string} [ellipsis] - Suffix when cut (default "…").
 * @returns {string} The truncated string.
 */
function truncate(s, maxLen, ellipsis) {
  arity("truncate", arguments.length, 2);
  reqStr("truncate", "s", s);
  reqNum("truncate", "maxLen", maxLen);
  if (ellipsis === undefined) ellipsis = "…";
  reqStr("truncate", "ellipsis", ellipsis);
  if (maxLen < 0) throw new Error("truncate: maxLen must be >= 0");
  var points = Array.from(s);
  if (points.length <= maxLen) return s;
  return points.slice(0, maxLen).join("") + ellipsis;
}

/*
 * Drops one trailing newline (\n or \r\n).
 * @param {string} s - Input.
 * @returns {string} The chomped string.
 */
function chomp(s) {
  arity("chomp", arguments.length, 1);
  reqStr("chomp", "s", s);
  return s.replace(/\r?\n$/, "");
}

/*
 * Collapses JS-whitespace runs to one space and trims the ends.
 * @param {string} s - Input.
 * @returns {string} The collapsed string.
 */
function collapseWhitespace(s) {
  arity("collapseWhitespace", arguments.length, 1);
  reqStr("collapseWhitespace", "s", s);
  var t = s.trim();
  return t === "" ? "" : t.split(/\s+/).join(" ");
}

// -- case converters -----------------------------------------------------------------

/*
 * Splits into words: non-alphanumeric runs plus camel boundaries.
 * Non-ASCII rides along with the current word (never split mid-rune).
 * @param {string} s - Input.
 * @returns {StrArray} The words.
 */
function asciiWords(s) {
  var points = Array.from(s), wordList = [], cur = "";
  var prevLower = false, prevUpper = false;
  function flush() {
    if (cur !== "") {
      wordList.push(cur);
      cur = "";
    }
  }
  function isAsciiAlnum(c) {
    return (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") ||
      (c >= "0" && c <= "9");
  }
  for (var i = 0; i < points.length; i++) {
    var c = points[i];
    if (c.length === 1 && isAsciiAlnum(c)) {
      var isU = c >= "A" && c <= "Z", isL = c >= "a" && c <= "z";
      var next = points[i + 1];
      var nextLower = typeof next === "string" && next.length === 1 &&
        next >= "a" && next <= "z";
      if (cur !== "" && isU && (prevLower || (prevUpper && nextLower))) {
        flush();
      }
      cur += c;
      prevLower = isL;
      prevUpper = isU;
    } else if (c.length === 1) {
      flush();
      prevLower = false;
      prevUpper = false;
    } else {
      cur += c;
      prevLower = false;
      prevUpper = false;
    }
  }
  flush();
  return wordList;
}

/*
 * Capitalizes the first code point, lower-cases the rest.
 * @param {string} w - Word.
 * @returns {string} The capitalized word.
 */
function capitalizeWord(w) {
  if (w === "") return w;
  var points = Array.from(w);
  return points[0].toUpperCase() + points.slice(1).join("").toLowerCase();
}

/*
 * hello-world_foo -> helloWorldFoo.
 * @param {string} s - Input.
 * @returns {string} camelCase.
 */
function camelCase(s) {
  arity("camelCase", arguments.length, 1);
  reqStr("camelCase", "s", s);
  var ws = asciiWords(s);
  if (ws.length === 0) return "";
  var out = ws[0].toLowerCase();
  for (var i = 1; i < ws.length; i++) {
    out += capitalizeWord(ws[i].toLowerCase());
  }
  return out;
}

/*
 * helloWorld -> hello_world.
 * @param {string} s - Input.
 * @returns {string} snake_case.
 */
function snakeCase(s) {
  arity("snakeCase", arguments.length, 1);
  reqStr("snakeCase", "s", s);
  return asciiWords(s).map(function (w) { return w.toLowerCase(); })
    .join("_");
}

/*
 * helloWorld -> hello-world.
 * @param {string} s - Input.
 * @returns {string} kebab-case.
 */
function kebabCase(s) {
  arity("kebabCase", arguments.length, 1);
  reqStr("kebabCase", "s", s);
  return asciiWords(s).map(function (w) { return w.toLowerCase(); })
    .join("-");
}

/*
 * hello world -> Hello World.
 * @param {string} s - Input.
 * @returns {string} Title Case.
 */
function titleCase(s) {
  arity("titleCase", arguments.length, 1);
  reqStr("titleCase", "s", s);
  return asciiWords(s).map(function (w) {
    return capitalizeWord(w.toLowerCase());
  }).join(" ");
}

/*
 * Lower-cases, maps non-alphanumeric runs to single dashes.
 * @param {string} s - Input.
 * @returns {string} The slug.
 */
function slugify(s) {
  arity("slugify", arguments.length, 1);
  reqStr("slugify", "s", s);
  var out = "", dash = false, started = false;
  var points = Array.from(s.toLowerCase());
  for (var i = 0; i < points.length; i++) {
    var c = points[i];
    if (/^[\p{L}\p{N}]$/u.test(c)) {
      out += c;
      dash = false;
      started = true;
    } else if (started && !dash) {
      out += "-";
      dash = true;
    }
  }
  if (dash && out.length > 0) out = out.slice(0, -1);
  return out;
}

// -- html ------------------------------------------------------------------------------

/*
 * Escapes &<>"' to entities.
 * @param {string} s - Input.
 * @returns {string} The escaped string.
 */
function escapeHtml(s) {
  arity("escapeHtml", arguments.length, 1);
  reqStr("escapeHtml", "s", s);
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;")
    .replace(/>/g, "&gt;").replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/*
 * Unescapes named and numeric entities; unknown ones pass through.
 * @param {string} s - Input.
 * @returns {string} The unescaped string.
 */
function unescapeHtml(s) {
  arity("unescapeHtml", arguments.length, 1);
  reqStr("unescapeHtml", "s", s);
  var named = {amp: "&", lt: "<", gt: ">", quot: "\"", "#39": "'",
    "#x27": "'", "#X27": "'"};
  return s.replace(/&(#?[xX]?[0-9a-zA-Z]{1,8});/g,
    function (match, ent) {
      if (Object.prototype.hasOwnProperty.call(named, ent)) {
        return named[ent];
      }
      var code = -1;
      if (ent[0] === "#") {
        if (ent[1] === "x" || ent[1] === "X") {
          if (/^[0-9a-fA-F]+$/.test(ent.slice(2))) {
            code = parseInt(ent.slice(2), 16);
          }
        } else if (/^[0-9]+$/.test(ent.slice(1))) {
          code = parseInt(ent.slice(1), 10);
        }
      }
      if (code >= 0 && code <= 0x10FFFF &&
          !(code >= 0xD800 && code <= 0xDFFF)) {
        return String.fromCodePoint(code);
      }
      return match;
    });
}

// -- distance ------------------------------------------------------------------------------

/*
 * Rune (code-point) edit distance; throws past 4M DP cells.
 * @param {string} a - First string.
 * @param {string} b - Second string.
 * @returns {number} The distance.
 */
function levenshtein(a, b) {
  arity("levenshtein", arguments.length, 2);
  reqStr("levenshtein", "a", a);
  reqStr("levenshtein", "b", b);
  var ra = Array.from(a), rb = Array.from(b);
  if ((ra.length + 1) * (rb.length + 1) > 4000000) {
    throw new Error("levenshtein: inputs too large (cap 4M cells)");
  }
  var prev = [], cur = [], i, j;
  for (j = 0; j <= rb.length; j++) prev[j] = j;
  for (i = 1; i <= ra.length; i++) {
    cur[0] = i;
    for (j = 1; j <= rb.length; j++) {
      var cost = ra[i - 1] === rb[j - 1] ? 0 : 1;
      cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost);
    }
    var tmp = prev;
    prev = cur;
    cur = tmp;
  }
  return prev[rb.length];
}

// -- layout ----------------------------------------------------------------------------------

/*
 * Greedy word wrap keeping blank-line paragraphs; long words overflow.
 * @param {string} s - Input.
 * @param {number} width - Column width (must be >= 1).
 * @returns {string} The wrapped text.
 */
function wordWrap(s, width) {
  arity("wordWrap", arguments.length, 2);
  reqStr("wordWrap", "s", s);
  reqNum("wordWrap", "width", width);
  if (width < 1) throw new Error("wordWrap: width must be >= 1");
  var paras = s.split("\n"), out = [];
  for (var p = 0; p < paras.length; p++) {
    var para = paras[p];
    if (para.length > 0 && para[para.length - 1] === "\r") {
      para = para.slice(0, -1);
    }
    var ws = para.trim() === "" ? [] : para.trim().split(/\s+/);
    var line = "", lineLen = 0;
    for (var k = 0; k < ws.length; k++) {
      var word = ws[k], wl = word.length;
      if (lineLen === 0) {
        line = word;
        lineLen = wl;
      } else if (lineLen + 1 + wl <= width) {
        line += " " + word;
        lineLen += 1 + wl;
      } else {
        out.push(line);
        line = word;
        lineLen = wl;
      }
    }
    out.push(line);
  }
  return out.join("\n");
}

/*
 * Prefixes every line (no phantom prefix past a trailing newline).
 * @param {string} s - Input.
 * @param {string} prefix - Line prefix.
 * @returns {string} The indented text.
 */
function indent(s, prefix) {
  arity("indent", arguments.length, 2);
  reqStr("indent", "s", s);
  reqStr("indent", "prefix", prefix);
  if (s === "") return "";
  var parts = s.split("\n"), out = [];
  for (var i = 0; i < parts.length; i++) {
    if (i === parts.length - 1 && parts[i] === "") break;
    out.push(prefix + parts[i]);
  }
  var trailing = s[s.length - 1] === "\n" ? "\n" : "";
  return out.join("\n") + trailing;
}

/*
 * Drops the common space/tab margin; blank lines become empty.
 * @param {string} s - Input.
 * @returns {string} The dedented text.
 */
function dedent(s) {
  arity("dedent", arguments.length, 1);
  reqStr("dedent", "s", s);
  var parts = s.split("\n"), margin = Infinity, i, j;
  for (i = 0; i < parts.length; i++) {
    var line = parts[i], lead = 0;
    while (lead < line.length &&
        (line[lead] === " " || line[lead] === "\t")) lead++;
    if (lead < line.length && lead < margin) margin = lead;
  }
  if (margin === Infinity) margin = 0;
  var out = [];
  for (i = 0; i < parts.length; i++) {
    var text = parts[i], cut = 0;
    while (cut < margin && cut < text.length &&
        (text[cut] === " " || text[cut] === "\t")) cut++;
    out.push(cut >= text.length ? "" : text.slice(cut));
  }
  return out.join("\n");
}

/*
 * Drops CSI/OSC/ESC escape sequences.
 * @param {string} s - Input.
 * @returns {string} The plain string.
 */
function stripAnsi(s) {
  arity("stripAnsi", arguments.length, 1);
  reqStr("stripAnsi", "s", s);
  return s.replace(/\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)|\x1B\[[0-?]*[ -/]*[@-~]|\x1B.|\x1B$/g, "");
}

// -- validators -------------------------------------------------------------------------------

/*
 * Practical email check (one @, dot-atom local, LDH domain, < 256).
 * Non-strings are false, not throws.
 * @param {any} s - Candidate.
 * @returns {boolean} Plausibly an email or not.
 */
function isEmail(s) {
  arity("isEmail", arguments.length, 1);
  if (typeof s !== "string" || s.length === 0 || s.length >= 256) {
    return false;
  }
  return /^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$/.test(s);
}

/*
 * LDH domain check (labels 1-63, total <= 253, alpha TLD).
 * Non-strings are false, not throws.
 * @param {any} s - Candidate.
 * @returns {boolean} Plausibly a domain or not.
 */
function isDomain(s) {
  arity("isDomain", arguments.length, 1);
  if (typeof s !== "string" || s.length === 0 || s.length > 253) {
    return false;
  }
  var labels = s.split(".");
  if (labels.length < 2) return false;
  for (var i = 0; i < labels.length; i++) {
    var label = labels[i];
    if (label.length === 0 || label.length > 63) return false;
    if (!/^[A-Za-z0-9-]+$/.test(label)) return false;
    if (label[0] === "-" || label[label.length - 1] === "-") return false;
  }
  return /^[A-Za-z]{2,}$/.test(labels[labels.length - 1]);
}

/*
 * Strict dotted-quad check (no leading zeros, 0-255 per part).
 * Non-strings are false, not throws.
 * @param {any} s - Candidate.
 * @returns {boolean} IPv4 or not.
 */
function isIPv4(s) {
  arity("isIPv4", arguments.length, 1);
  if (typeof s !== "string") return false;
  var parts = s.split(".");
  if (parts.length !== 4) return false;
  for (var i = 0; i < 4; i++) {
    var p = parts[i];
    if (!/^(0|[1-9][0-9]{0,2})$/.test(p)) return false;
    if (parseInt(p, 10) > 255) return false;
  }
  return true;
}

/*
 * Strict IPv6 check (8 groups or one :: squeeze, optional v4 tail).
 * Non-strings are false, not throws.
 * @param {any} s - Candidate.
 * @returns {boolean} IPv6 or not.
 */
function isIPv6(s) {
  arity("isIPv6", arguments.length, 1);
  if (typeof s !== "string" || s.length === 0) return false;
  var halves = s.split("::");
  if (halves.length > 2) return false;
  function checkGroups(text, want) {
    if (text === "") return true;
    var groups = text.split(":");
    var need = want === -1 ? -1 : want;
    var v4tail = groups.length > 0 &&
      groups[groups.length - 1].indexOf(".") >= 0;
    var limit = v4tail ? groups.length - 1 : groups.length;
    var count = 0;
    for (var i = 0; i < limit; i++) {
      if (!/^[0-9a-fA-F]{1,4}$/.test(groups[i])) return false;
      count++;
    }
    if (v4tail) {
      if (!isIPv4(groups[groups.length - 1])) return false;
      count += 2;
    }
    return need === -1 || count === need;
  }
  if (halves.length === 1) return checkGroups(s, 8);
  var left = halves[0] === "" ? 0 : halves[0].split(":").length;
  var right = halves[1] === "" ? 0 : halves[1].split(":").length;
  var v4extra = halves[1].indexOf(".") >= 0 ? 1 : 0;
  if (left + right + v4extra > 8) return false;
  if (left + right === 0 && v4extra === 0) return true;
  return checkGroups(halves[0], -1) && checkGroups(halves[1], -1) &&
    left + right + v4extra < 8;
}

/*
 * True for IPv4 or IPv6. Non-strings are false, not throws.
 * @param {any} s - Candidate.
 * @returns {boolean} IP or not.
 */
function isIP(s) {
  arity("isIP", arguments.length, 1);
  return isIPv4(s) || isIPv6(s);
}

/*
 * Practical http(s) URL check (scheme, host, no whitespace).
 * Non-strings are false, not throws.
 * @param {any} s - Candidate.
 * @returns {boolean} Plausibly a web URL or not.
 */
function isWebUrl(s) {
  arity("isWebUrl", arguments.length, 1);
  if (typeof s !== "string") return false;
  var m = /^(https?):\/\/([^\s/?#]+)([\s\S]*)$/.exec(s);
  if (!m) return false;
  var host = m[2];
  if (host[0] === "[" && host[host.length - 1] === "]") {
    return isIPv6(host.slice(1, -1));
  }
  var bare = host.split(":")[0];
  return isDomain(bare) || isIPv4(bare) || bare === "localhost";
}

/*
 * Canonical 8-4-4-4-12 hex check (any version). Non-strings are false.
 * @param {any} s - Candidate.
 * @returns {boolean} UUID or not.
 */
function isUUID(s) {
  arity("isUUID", arguments.length, 1);
  if (typeof s !== "string") return false;
  return /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(s);
}

/*
 * Integer port 0-65535 (accepts numeric strings; rejects floats).
 * Non-strings/non-numbers are false, not throws.
 * @param {any} v - Candidate.
 * @returns {boolean} Valid port or not.
 */
function isPort(v) {
  arity("isPort", arguments.length, 1);
  var n;
  if (typeof v === "number") {
    n = v;
  } else if (typeof v === "string") {
    if (!/^(0|[1-9][0-9]*)$/.test(v)) return false;
    n = parseInt(v, 10);
  } else {
    return false;
  }
  return n >= 0 && n <= 65535 && Math.floor(n) === n;
}

module.exports = {
  indexOf: indexOf,
  lastIndexOf: lastIndexOf,
  includes: includes,
  count: count,
  equals: equals,
  startsWith: startsWith,
  endsWith: endsWith,
  toUpperCase: toUpperCase,
  toLowerCase: toLowerCase,
  trim: trim,
  trimStart: trimStart,
  trimEnd: trimEnd,
  isAscii: isAscii,
  isBlank: isBlank,
  lines: lines,
  split: split,
  join: join,
  words: words,
  replace: replace,
  replaceAll: replaceAll,
  slice: slice,
  padStart: padStart,
  padEnd: padEnd,
  padCenter: padCenter,
  repeat: repeat,
  reverse: reverse,
  truncate: truncate,
  chomp: chomp,
  collapseWhitespace: collapseWhitespace,
  camelCase: camelCase,
  snakeCase: snakeCase,
  kebabCase: kebabCase,
  titleCase: titleCase,
  slugify: slugify,
  escapeHtml: escapeHtml,
  unescapeHtml: unescapeHtml,
  levenshtein: levenshtein,
  wordWrap: wordWrap,
  indent: indent,
  dedent: dedent,
  stripAnsi: stripAnsi,
  isEmail: isEmail,
  isDomain: isDomain,
  isIPv4: isIPv4,
  isIPv6: isIPv6,
  isIP: isIP,
  isWebUrl: isWebUrl,
  isUUID: isUUID,
  isPort: isPort
};
