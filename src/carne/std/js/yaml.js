// Carne std/yaml: YAML parsing and serialization (pure JS).
//
// Single-document in v1: content after a second `---` or a `...`
// end-marker is ignored. Core Schema value resolution, no legacy
// 1.1 bools (`yes`/`no`/`on`/`off` stay strings).
//
//   const yaml = require("std/yaml");
//   yaml.parse("name: ada\nn: 3") -> {name: "ada", n: 3}
//   yaml.stringify({a: 1})        -> "a: 1\n"
//
// Timestamps resolve to Date objects (`2001-02-03`, full datetimes
// with optional fraction/zone, `!!timestamp`). Unknown tags throw.
"use strict";
/*
 * @typedef {object} YamlLine - One significant source line.
 * @typedef {object} Props - Node properties parsed from a line prefix.
 */

/*
 * JS typeof name for type-mismatch errors (null/array distinguished).
 * @param {any} v - Value to classify.
 * @returns {string} The JS type name.
 */
function jsKind(v) {
  if (v === null) return "null";
  if (Array.isArray(v)) return "array";
  var t = typeof v;
  if (t === "number" || t === "string" || t === "boolean" ||
      t === "undefined" || t === "function" || t === "symbol" ||
      t === "bigint") return t;
  if (v instanceof Date) return "object";
  return "object";
}

/*
 * True for values stringify() must skip in objects / null in arrays.
 * @param {any} v - Candidate value.
 * @returns {boolean} Skipped or not.
 */
function isSkipped(v) {
  return v === undefined || typeof v === "function" ||
    typeof v === "symbol";
}

/*
 * Throws a parse Error with the std prefix and optional line number.
 * @param {string} msg - Reason.
 * @param {number|undefined} line - 1-based line number, if known.
 * @returns {never} Always throws.
 */
function perr(msg, line) {
  if (line !== undefined) throw new Error("parse: line " + line + ": " + msg);
  throw new Error("parse: " + msg);
}

/*
 * Throws a stringify Error with the std prefix.
 * @param {string} msg - Reason.
 * @returns {never} Always throws.
 */
function serr(msg) {
  throw new Error("stringify: " + msg);
}

// -- scalars ---------------------------------------------------------------

/*
 * True for Core Schema null texts (empty handled by callers).
 * @param {string} s - Plain scalar text.
 * @returns {boolean} Null or not.
 */
function isNullText(s) {
  return s === "~" || s === "null" || s === "Null" || s === "NULL";
}

/*
 * Core Schema bool, or null when the text is not a bool.
 * @param {string} s - Plain scalar text.
 * @returns {boolean|null} The bool, or null.
 */
function boolOf(s) {
  if (s === "true" || s === "True" || s === "TRUE") return true;
  if (s === "false" || s === "False" || s === "FALSE") return false;
  return null;
}

/*
 * Validates strict underscore placement (no leading/trailing/double).
 * @param {string} s - Digits with underscores.
 * @returns {boolean} Placed correctly or not.
 */
function underscoresOk(s) {
  if (s.length === 0) return false;
  if (s[0] === "_" || s[s.length - 1] === "_") return false;
  return s.indexOf("__") < 0;
}

/*
 * Parses a Core Schema integer, or null when the text is not one.
 * @param {string} s - Plain scalar text.
 * @returns {number|null} The integer, or null.
 */
function intOf(s) {
  var t = s;
  if (t[0] === "+" || t[0] === "-") t = t.slice(1);
  if (t.length === 0) return null;
  var body = t, base = 10;
  if (t.length > 2 && t[0] === "0" && (t[1] === "x" || t[1] === "X")) {
    body = t.slice(2);
    base = 16;
    if (!/^[0-9a-fA-F_]+$/.test(body) || !underscoresOk(body)) return null;
  } else if (t.length > 2 && t[0] === "0" && (t[1] === "o" || t[1] === "O")) {
    body = t.slice(2);
    base = 8;
    if (!/^[0-7_]+$/.test(body) || !underscoresOk(body)) return null;
  } else {
    if (!/^[0-9_]+$/.test(body) || !underscoresOk(body)) return null;
  }
  var digits = body.replace(/_/g, "");
  var v = base === 10 ? parseInt((s[0] === "-" ? "-" : "") + digits, 10) :
    parseInt(digits, base);
  if (Number.isNaN(v)) return null;
  return (s[0] === "-" && base !== 10) ? -v : v;
}

/*
 * Parses a Core Schema float, or null when the text is not one.
 * @param {string} s - Plain scalar text.
 * @returns {number|null} The float, or null.
 */
function floatOf(s) {
  var low = s.toLowerCase();
  if (low === ".inf" || low === "+.inf") return Infinity;
  if (low === "-.inf") return -Infinity;
  if (low === ".nan" || low === "+.nan" || low === "-.nan") return NaN;
  var t = s;
  if (t[0] === "+" || t[0] === "-") t = t.slice(1);
  if (!/^[0-9_.]+([eE][+-]?[0-9]+)?$/.test(t)) return null;
  var core = t.replace(/_[0-9]/g, "0").replace(/_/g, "");
  var hasDot = core.indexOf(".") >= 0;
  var hasExp = /[eE]/.test(core);
  if (!hasDot && !hasExp) return null;
  if (!/^[0-9]*\.?[0-9]*([eE][+-]?[0-9]+)?$/.test(core)) return null;
  if (core === "." || core === "") return null;
  var v = parseFloat(s.replace(/_/g, ""));
  return Number.isNaN(v) ? null : v;
}

/*
 * Days in a month for timestamp validation (leap-year aware).
 * @param {number} y - Full year.
 * @param {number} m - Month 1..12.
 * @returns {number} Days in the month.
 */
function daysInMonth(y, m) {
  if (m === 2) {
    var leap = (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
    return leap ? 29 : 28;
  }
  if (m === 4 || m === 6 || m === 9 || m === 11) return 30;
  return 31;
}

/*
 * Parses a YAML timestamp to a Date, or null when not a timestamp.
 * Invalid calendar values (month 13, day 40) stay strings.
 * @param {string} s - Plain scalar text.
 * @returns {Date|null} The instant, or null.
 */
function dateOf(s) {
  var m = /^(\d{4})-(\d{1,2})-(\d{1,2})(?:[Tt ](\d{1,2}):(\d{2}):(\d{2})(\.\d+)?([ \t]*(Z|z|[+-]\d{1,2}(?::?[0-5]?\d)?))?)?$/.exec(s);
  if (!m) return null;
  var y = parseInt(m[1], 10), mo = parseInt(m[2], 10), d = parseInt(m[3], 10);
  if (mo < 1 || mo > 12 || d < 1 || d > daysInMonth(y, mo)) return null;
  var hh = 0, mm = 0, ss = 0, ms = 0, offMin = 0, hasTime = m[4] !== undefined;
  if (hasTime) {
    hh = parseInt(m[4], 10);
    mm = parseInt(m[5], 10);
    ss = parseInt(m[6], 10);
    if (hh > 23 || mm > 59 || ss > 59) return null;
    if (m[7] !== undefined) {
      var frac = (m[7].slice(1) + "000").slice(0, 3);
      ms = parseInt(frac, 10);
    }
    var z = m[8];
    if (z !== undefined) {
      var zt = z.replace(/[ \t]/g, "");
      if (zt !== "Z" && zt !== "z") {
        var sign = zt[0] === "-" ? -1 : 1;
        var rest = zt.slice(1).replace(":", "");
        var oh, om = 0;
        if (rest.length > 2) {
          oh = parseInt(rest.slice(0, rest.length - 2), 10);
          om = parseInt(rest.slice(rest.length - 2), 10);
        } else {
          oh = parseInt(rest, 10);
        }
        if (oh > 23 || om > 59) return null;
        offMin = sign * (oh * 60 + om);
      }
    }
  }
  var t = Date.UTC(y, mo - 1, d, hh, mm, ss, ms) - offMin * 60000;
  var dt = new Date(t);
  return Number.isNaN(dt.getTime()) ? null : dt;
}

/*
 * Resolves a plain scalar per the Core Schema (no legacy 1.1 forms).
 * Order: null, bool, int, float, timestamp, string.
 * @param {string} s - Plain scalar text.
 * @returns {any} The resolved value.
 */
function resolvePlain(s) {
  if (s === "") return null;
  if (isNullText(s)) return null;
  var b = boolOf(s);
  if (b !== null) return b;
  var iv = intOf(s);
  if (iv !== null) return iv;
  var fv = floatOf(s);
  if (fv !== null) return fv;
  var dt = dateOf(s);
  if (dt !== null) return dt;
  return s;
}

/*
 * Renders a resolved scalar for use as a mapping key.
 * @param {any} v - Resolved value.
 * @returns {string} The key text.
 */
function keyToString(v) {
  if (v === null) return "null";
  if (v === true) return "true";
  if (v === false) return "false";
  if (typeof v === "number") return String(v);
  if (v instanceof Date) return v.toISOString();
  if (typeof v === "string") return v;
  var j = JSON.stringify(v);
  return j === undefined ? String(v) : j;
}

/*
 * Unescapes a double-quoted scalar body (no surrounding quotes).
 * @param {string} s - Inner text.
 * @param {number|undefined} line - Line number for errors.
 * @returns {string} The unescaped value.
 */
function unescapeDouble(s, line) {
  var out = "";
  for (var i = 0; i < s.length; i++) {
    var c = s[i];
    if (c !== "\\") {
      out += c;
      continue;
    }
    i++;
    if (i >= s.length) perr("bad escape at end of string", line);
    var e = s[i];
    if (e === "0") out += "\0";
    else if (e === "a") out += "\x07";
    else if (e === "b") out += "\b";
    else if (e === "t" || e === "\t") out += "\t";
    else if (e === "n") out += "\n";
    else if (e === "v") out += "\v";
    else if (e === "f") out += "\f";
    else if (e === "r") out += "\r";
    else if (e === "e") out += "\x1b";
    else if (e === " ") out += " ";
    else if (e === "\"") out += "\"";
    else if (e === "\\") out += "\\";
    else if (e === "N") out += "\x85";
    else if (e === "_") out += "\xa0";
    else if (e === "L") out += "\u2028";
    else if (e === "P") out += "\u2029";
    else if (e === "x" || e === "u" || e === "U") {
      var want = e === "x" ? 2 : e === "u" ? 4 : 8;
      var hex = s.slice(i + 1, i + 1 + want);
      if (!new RegExp("^[0-9a-fA-F]{" + want + "}$").test(hex)) {
        perr("bad \\" + e + " escape", line);
      }
      out += String.fromCharCode(parseInt(hex, 16));
      i += want;
    } else if (e === "\n") {
      out += " ";
    } else {
      perr("unknown escape \\" + e, line);
    }
  }
  return out;
}

// -- lines -----------------------------------------------------------------

/*
 * Counts leading spaces; throws on tab indentation.
 * @param {string} raw - Raw source line.
 * @param {number} line - 1-based line number.
 * @returns {number} The indent in spaces.
 */
function indentOf(raw, line) {
  var i = 0;
  while (i < raw.length && (raw[i] === " " || raw[i] === "\t")) {
    if (raw[i] === "\t") {
      perr("tabs must not be used for indentation", line);
    }
    i++;
  }
  return i;
}

/*
 * Strips a ` #` comment outside single/double quotes.
 * @param {string} line - Source line.
 * @returns {string} The line without its comment, right-trimmed.
 */
function stripComment(line) {
  var inS = false, inD = false;
  for (var i = 0; i < line.length; i++) {
    var c = line[i];
    if (c === "'" && !inD) {
      if (inS && line[i + 1] === "'") {
        i++;
        continue;
      }
      inS = !inS;
    } else if (c === "\\" && inD) {
      i++;
    } else if (c === "\"" && !inS) {
      inD = !inD;
    } else if (c === "#" && !inS && !inD &&
        (i === 0 || line[i - 1] === " " || line[i - 1] === "\t")) {
      return line.slice(0, i).replace(/[ \t]+$/, "");
    }
  }
  return line;
}

/*
 * True for blank or comment-only lines.
 * @param {string} raw - Raw source line.
 * @returns {boolean} Blank or not.
 */
function isBlank(raw) {
  return stripComment(raw).replace(/^[ \t]+/, "") === "";
}

/*
 * Finds the `:` ending a mapping key: a colon followed by
 * space/tab/EOL, outside quotes and flow brackets.
 * @param {string} text - Comment-stripped line content.
 * @returns {number} The index, or -1.
 */
function findMappingColon(text) {
  var inS = false, inD = false, depth = 0;
  for (var i = 0; i < text.length; i++) {
    var c = text[i];
    if (c === "'" && !inD) {
      if (inS && text[i + 1] === "'") {
        i++;
        continue;
      }
      inS = !inS;
    } else if (c === "\\" && inD) {
      i++;
    } else if (c === "\"" && !inS) {
      inD = !inD;
    } else if (!inS && !inD) {
      if (c === "[" || c === "{") depth++;
      else if (c === "]" || c === "}") depth = Math.max(0, depth - 1);
      else if (c === ":" && depth === 0 &&
          (i + 1 >= text.length || text[i + 1] === " " ||
            text[i + 1] === "\t")) {
        return i;
      }
    }
  }
  return -1;
}

/*
 * True for a `-` sequence entry (dash followed by space/tab/EOL).
 * @param {string} text - Comment-stripped line content.
 * @returns {boolean} Entry or not.
 */
function isDashLine(text) {
  return text === "-" || text.slice(0, 2) === "- " ||
    text.slice(0, 2) === "-\t";
}

/*
 * True for a `?` explicit key (question followed by space/tab/EOL).
 * @param {string} text - Comment-stripped line content.
 * @returns {boolean} Explicit key or not.
 */
function isQuestionLine(text) {
  return text === "?" || text.slice(0, 2) === "? " ||
    text.slice(0, 2) === "?\t";
}

/*
 * Parses a block scalar header (`|`, `>`, chomping, indent).
 * @param {string} text - Header text.
 * @returns {object|null} {folded, chomp, indent} or null.
 */
function blockHeader(text) {
  var m = /^([|>])([+-]?[1-9]?|[1-9][+-]?)$/.exec(text);
  if (!m) return null;
  var rest = m[2], chomp = "clip", indent = 0;
  for (var i = 0; i < rest.length; i++) {
    if (rest[i] === "+") chomp = "keep";
    else if (rest[i] === "-") chomp = "strip";
    else indent = parseInt(rest[i], 10);
  }
  return {folded: m[1] === ">", chomp: chomp, indent: indent};
}

/*
 * Validates an anchor/alias name.
 * @param {string} name - The name without &/*.
 * @returns {boolean} Valid or not.
 */
function anchorNameOk(name) {
  return /^[A-Za-z0-9_\-]+$/.test(name);
}

// -- tags ------------------------------------------------------------------

/*
 * Known Core Schema tag suffixes.
 */
var KNOWN_TAGS = {
  str: 1, int: 1, float: 1, bool: 1, null: 1, seq: 1, map: 1, timestamp: 1
};

/*
 * Expands a tag token to `!!suffix`, a known full URI, or null
 * (bare `!`). Throws on anything else: local `!foo`, named
 * handles and unknown `!!bar` are rejected in v1.
 * @param {string} tok - Raw tag token.
 * @param {object} handles - %TAG handle table.
 * @param {number} line - Line number for errors.
 * @returns {string|null} The `!!suffix`, full URI, or null.
 */
function expandTag(tok, handles, line) {
  if (tok === "!") return null;
  if (tok.slice(0, 2) === "!!") {
    var suffix = tok.slice(2);
    if (!Object.prototype.hasOwnProperty.call(KNOWN_TAGS, suffix)) {
      perr("unknown tag `" + tok + "`", line);
    }
    return "!!" + suffix;
  }
  if (tok.slice(0, 2) === "!<" && tok[tok.length - 1] === ">") {
    var uri = tok.slice(2, -1);
    var prefix = "tag:yaml.org,2002:";
    if (uri.slice(0, prefix.length) === prefix) {
      var sfx = uri.slice(prefix.length);
      if (!Object.prototype.hasOwnProperty.call(KNOWN_TAGS, sfx)) {
        perr("unknown tag `" + tok + "`", line);
      }
      return "!!" + sfx;
    }
    perr("unknown tag `" + tok + "`", line);
  }
  var bang = tok.indexOf("!", 1);
  if (bang > 0) {
    var handle = tok.slice(0, bang + 1);
    if (Object.prototype.hasOwnProperty.call(handles, handle)) {
      var expanded = handles[handle] + tok.slice(bang + 1);
      var pfx = "tag:yaml.org,2002:";
      if (expanded.slice(0, pfx.length) === pfx) {
        var s2 = expanded.slice(pfx.length);
        if (!Object.prototype.hasOwnProperty.call(KNOWN_TAGS, s2)) {
          perr("unknown tag `" + tok + "`", line);
        }
        return "!!" + s2;
      }
    }
  }
  perr("unknown tag `" + tok + "`", line);
  return null;
}

/*
 * Applies a tag to a resolved node. Scalars coerce; collections
 * only accept their own kind; anything else throws.
 * @param {string|null} tag - `!!suffix` or null (non-specific).
 * @param {any} value - Resolved node.
 * @param {string} raw - Raw scalar text (for scalar coercion).
 * @param {number} line - Line number for errors.
 * @returns {any} The tagged value.
 */
function applyTag(tag, value, raw, line) {
  if (tag === null || tag === undefined) return value;
  var isColl = value !== null && typeof value === "object" &&
    !(value instanceof Date);
  var text = raw !== undefined ? raw : keyToString(value);
  if (!isColl) text = raw !== undefined ? raw : String(value);
  switch (tag) {
    case "!!str":
      if (isColl) perr("cannot resolve `!!str` from a collection", line);
      return text;
    case "!!null":
      return null;
    case "!!bool": {
      var b = boolOf(text);
      if (b === null) perr("cannot resolve `!!bool " + text + "`", line);
      return b;
    }
    case "!!int": {
      var iv = intOf(text);
      if (iv === null) perr("cannot resolve `!!int " + text + "`", line);
      return iv;
    }
    case "!!float": {
      var fv = floatOf(text);
      if (fv === null) perr("cannot resolve `!!float " + text + "`", line);
      return fv;
    }
    case "!!timestamp": {
      var dt = dateOf(text);
      if (dt === null) perr("cannot resolve `!!timestamp " + text + "`", line);
      return dt;
    }
    case "!!seq":
      if (value === null) return [];
      if (Array.isArray(value)) return value;
      perr("cannot resolve `!!seq` from a scalar", line);
      return value;
    case "!!map":
      if (value === null) return {};
      if (value !== null && typeof value === "object" &&
          !Array.isArray(value) && !(value instanceof Date)) return value;
      perr("cannot resolve `!!map` from a non-mapping", line);
      return value;
    default:
      perr("unknown tag `" + tag + "`", line);
      return value;
  }
}

// -- parser ----------------------------------------------------------------

/*
 * Folds real line breaks in a multiline quoted scalar: indentation
 * stripped, single breaks become spaces, empty lines become breaks.
 * @param {string} s - Inner quoted text with real newlines.
 * @returns {string} The folded text.
 */
function foldQuotedBreaks(s) {
  if (s.indexOf("\n") < 0) return s;
  var lines = s.split("\n");
  var out = lines[0].replace(/[ \t]+$/, "");
  var blanks = 0;
  for (var i = 1; i < lines.length; i++) {
    var t = lines[i].replace(/^[ \t]+/, "").replace(/[ \t]+$/, "");
    if (t === "") {
      blanks++;
      continue;
    }
    if (blanks > 0) {
      for (var k = 0; k < blanks; k++) out += "\n";
      blanks = 0;
    } else {
      out += " ";
    }
    out += t;
  }
  return out;
}

/*
 * Single-document YAML parser over raw source lines.
 * @param {Array<string>} raws - Raw source lines.
 */
function Parser(raws) {
  this.raws = raws;
  this.pos = 0;
  this.anchors = {};
  this.building = {};
  this.handles = {"!": "!", "!!": "tag:yaml.org,2002:"};
  this.depth = 0;
}

/*
 * Next significant line without consuming it.
 * @returns {object|null} {num, indent, text} or null at EOF.
 */
Parser.prototype.peek = function () {
  var i = this.pos;
  while (i < this.raws.length) {
    var raw = this.raws[i];
    var stripped = stripComment(raw);
    if (stripped.replace(/^[ \t]+/, "") === "") {
      i++;
      continue;
    }
    var num = i + 1;
    var indent = indentOf(raw, num);
    return {num: num, indent: indent, text: stripped.slice(indent)};
  }
  return null;
};

/*
 * Consumes and returns the next significant line.
 * @returns {object|null} {num, indent, text} or null at EOF.
 */
Parser.prototype.next = function () {
  var l = this.peek();
  if (l === null) return null;
  this.pos = l.num;
  return l;
};

/*
 * Throws when nesting exceeds the depth cap.
 * @param {number} line - Line number for errors.
 */
Parser.prototype.checkDepth = function (line) {
  if (this.depth > 64) perr("maximum nesting depth exceeded", line);
};

/*
 * Splits node properties (`&anchor`, `!tag`) off the front of a
 * text. Properties may appear in any order and repeat the loop.
 * @param {string} text - Remaining line text.
 * @param {number} line - Line number for errors.
 * @returns {object} {tag, anchor, rest}.
 */
Parser.prototype.splitProps = function (text, line) {
  var tag = null, anchor = null, rest = text;
  for (;;) {
    rest = rest.replace(/^[ \t]+/, "");
    if (rest[0] === "&") {
      var m = /^&([^\s,[\]{}]+)/.exec(rest);
      if (!m || !anchorNameOk(m[1])) perr("bad anchor", line);
      if (anchor !== null) perr("duplicate anchor", line);
      anchor = m[1];
      rest = rest.slice(m[0].length);
    } else if (rest[0] === "!") {
      var tm = /^(!<[^\s]*?>|![^\s,[\]{}]*)/.exec(rest);
      if (!tm) perr("bad tag", line);
      if (tag !== null) perr("duplicate tag", line);
      tag = expandTag(tm[1], this.handles, line);
      rest = rest.slice(tm[1].length);
    } else {
      break;
    }
  }
  return {tag: tag, anchor: anchor, rest: rest.replace(/^[ \t]+/, "")};
};

/*
 * Stores an anchor value and clears its in-progress mark.
 * @param {string|null} anchor - Name or null.
 * @param {any} value - Value to store.
 */
Parser.prototype.putAnchor = function (anchor, value) {
  if (anchor === null) return;
  this.anchors[anchor] = value;
  delete this.building[anchor];
};

/*
 * Resolves an alias to its anchored value.
 * @param {string} name - Alias name without *.
 * @param {number} line - Line number for errors.
 * @returns {any} The anchored value.
 */
Parser.prototype.getAlias = function (name, line) {
  if (!anchorNameOk(name)) perr("bad alias", line);
  if (Object.prototype.hasOwnProperty.call(this.building, name)) {
    perr("anchor `&" + name + "` cannot refer to itself", line);
  }
  if (!Object.prototype.hasOwnProperty.call(this.anchors, name)) {
    perr("undefined alias `*" + name + "`", line);
  }
  return this.anchors[name];
};

/*
 * Reads a block scalar body for a header on `hline`.
 * @param {object} h - Parsed header {folded, chomp, indent}.
 * @param {number} parentIndent - Indent of the header line.
 * @param {number} hline - Header line number.
 * @returns {string} The scalar value.
 */
Parser.prototype.readBlockScalar = function (h, parentIndent, hline) {
  var want = h.indent > 0 ? parentIndent + h.indent : -1;
  var det = -1, body = [], i = this.pos, n = this.raws.length;
  var k = i;
  while (k < n) {
    var raw = this.raws[k];
    if (stripComment(raw).replace(/^[ \t]+/, "") === "") {
      body.push({blank: true, text: ""});
      k++;
      continue;
    }
    var ind = indentOf(raw, k + 1);
    if (det < 0) {
      det = want > 0 ? want : ind;
      if (det <= parentIndent) {
        perr("bad block scalar indentation", k + 1);
      }
      if (want > 0 && ind < want) perr("bad block scalar indentation", k + 1);
    }
    if (ind < det) break;
    body.push({blank: false, text: raw.slice(det), verb: ind > det});
    k++;
  }
  this.pos = k;
  var lines = body.slice();
  var lastContent = -1;
  for (var li = 0; li < lines.length; li++) {
    if (!lines[li].blank) lastContent = li;
  }
  var val = "";
  if (!h.folded) {
    for (var a = 0; a < lines.length; a++) {
      val += lines[a].blank ? "\n" : lines[a].text + "\n";
    }
  } else {
    var pending = false, prevVerb = false;
    for (var b = 0; b < lines.length; b++) {
      if (lines[b].blank) {
        val += "\n";
        pending = false;
        prevVerb = false;
      } else if (!pending) {
        val += lines[b].text;
        pending = true;
        prevVerb = lines[b].verb;
      } else if (prevVerb || lines[b].verb) {
        val += "\n" + lines[b].text;
        prevVerb = lines[b].verb;
      } else {
        val += " " + lines[b].text;
      }
    }
    if (pending) val += "\n";
  }
  if (h.chomp === "strip") {
    while (val.length > 0 && val[val.length - 1] === "\n") {
      val = val.slice(0, -1);
    }
  } else if (h.chomp === "clip") {
    while (val.length > 0 && val[val.length - 1] === "\n") {
      val = val.slice(0, -1);
    }
    if (lastContent >= 0) val += "\n";
  }
  return val;
};

/*
 * Accumulates source lines until flow brackets balance.
 * @param {string} first - First line's remainder.
 * @param {number} line - Starting line number.
 * @returns {string} The joined flow text.
 */
Parser.prototype.readFlowText = function (first, line) {
  var parts = [first], blanks = 0, depth = 0;
  var inS = false, inD = false;
  var scan = function (t) {
    for (var i = 0; i < t.length; i++) {
      var c = t[i];
      if (c === "'" && !inD) {
        if (inS && t[i + 1] === "'") {
          i++;
          continue;
        }
        inS = !inS;
      } else if (c === "\\" && inD) {
        i++;
      } else if (c === "\"" && !inS) {
        inD = !inD;
      } else if (!inS && !inD) {
        if (c === "[" || c === "{") depth++;
        else if (c === "]" || c === "}") depth--;
      }
    }
  };
  scan(first);
  while (depth > 0) {
    if (this.pos >= this.raws.length) perr("unterminated flow collection", line);
    var raw = this.raws[this.pos];
    this.pos++;
    var t = stripComment(raw).replace(/^[ \t]+|[ \t]+$/g, "");
    if (t === "") {
      blanks++;
      continue;
    }
    if (blanks > 0) {
      parts.push("\n");
      blanks = 0;
    } else {
      parts.push(" ");
    }
    parts.push(t);
    scan(t);
    if (depth < 0) perr("unbalanced flow collection", line);
  }
  return parts.join("");
};

/*
 * Accumulates source lines until a quoted scalar closes.
 * @param {string} first - First line's remainder (starts with quote).
 * @param {string} q - Quote character.
 * @param {number} line - Starting line number.
 * @returns {string} The full quoted text including quotes.
 */
Parser.prototype.readQuotedText = function (first, q, line) {
  var parts = [first];
  var closed = function (t) {
    var inQ = false;
    for (var i = 0; i < t.length; i++) {
      if (q === "'") {
        if (t[i] === "'") {
          if (t[i + 1] === "'") {
            i++;
            continue;
          }
          inQ = !inQ;
        }
      } else {
        if (t[i] === "\\") {
          i++;
          continue;
        }
        if (t[i] === "\"") inQ = !inQ;
      }
    }
    return !inQ;
  };
  if (closed(first)) return first;
  while (!closed(parts.join("\n"))) {
    if (this.pos >= this.raws.length) perr("unterminated quoted scalar", line);
    parts.push(this.raws[this.pos]);
    this.pos++;
  }
  return parts.join("\n");
};

/*
 * Parses one flow value at `p.pos` in `p.text`.
 * @param {object} p - {text, pos} cursor (mutated).
 * @param {number} line - Line number for errors.
 * @param {boolean} isKey - True when parsing a mapping key.
 * @returns {any} The value.
 */
Parser.prototype.flowValue = function (p, line, isKey) {
  this.depth++;
  this.checkDepth(line);
  try {
    while (p.pos < p.text.length &&
        (p.text[p.pos] === " " || p.text[p.pos] === "\t" ||
          p.text[p.pos] === "\n")) p.pos++;
    if (p.pos >= p.text.length) {
      if (isKey) return null;
      perr("unexpected end of flow collection", line);
    }
    var c = p.text[p.pos];
    if (c === "*") {
      var am = /^\*([A-Za-z0-9_\-]+)/.exec(p.text.slice(p.pos));
      if (!am) perr("bad alias", line);
      p.pos += am[0].length;
      return this.getAlias(am[1], line);
    }
    if (c === "&" || c === "!") {
      var tag = null, anchor = null;
      for (;;) {
        while (p.pos < p.text.length &&
            (p.text[p.pos] === " " || p.text[p.pos] === "\t" ||
              p.text[p.pos] === "\n")) p.pos++;
        if (p.text[p.pos] === "&") {
          var nm = /^&([^\s,[\]{}]+)/.exec(p.text.slice(p.pos));
          if (!nm || !anchorNameOk(nm[1])) perr("bad anchor", line);
          anchor = nm[1];
          p.pos += nm[0].length;
        } else if (p.text[p.pos] === "!") {
          var tm = /^(!<[^\s]*?>|![^\s,[\]{}]*)/.exec(p.text.slice(p.pos));
          if (!tm) perr("bad tag", line);
          tag = expandTag(tm[1], this.handles, line);
          p.pos += tm[1].length;
        } else {
          break;
        }
      }
      if (anchor !== null) {
        this.building[anchor] = 1;
      }
      var v = this.flowValue(p, line, false);
      var anchorName = anchor;
      if (tag !== null) v = applyTag(tag, v, undefined, line);
      if (anchorName !== null) {
        this.anchors[anchorName] = v;
        delete this.building[anchorName];
      }
      return v;
    }
    if (c === "[") {
      p.pos++;
      var arr = [];
      for (;;) {
        while (p.pos < p.text.length &&
            (p.text[p.pos] === " " || p.text[p.pos] === "\t" ||
              p.text[p.pos] === "\n")) p.pos++;
        if (p.pos < p.text.length && p.text[p.pos] === "]") {
          p.pos++;
          return arr;
        }
        if (p.pos >= p.text.length) perr("unterminated flow collection", line);
        var item = this.flowValue(p, line, false);
        while (p.pos < p.text.length &&
            (p.text[p.pos] === " " || p.text[p.pos] === "\t" ||
              p.text[p.pos] === "\n")) p.pos++;
        if (p.pos < p.text.length && p.text[p.pos] === ":") {
          var after = p.text[p.pos + 1];
          if (after === " " || after === "\t" || after === "\n" ||
              after === "," || after === "]" || p.pos + 1 >= p.text.length) {
            p.pos++;
            var fv = null;
            var peekC = p.text[p.pos];
            if (peekC !== "," && peekC !== "]") fv = this.flowValue(p, line, false);
            while (p.pos < p.text.length &&
                (p.text[p.pos] === " " || p.text[p.pos] === "\t" ||
                  p.text[p.pos] === "\n")) p.pos++;
            var o = {};
            o[keyToString(item)] = fv;
            item = o;
          }
        }
        arr.push(item);
        while (p.pos < p.text.length &&
            (p.text[p.pos] === " " || p.text[p.pos] === "\t" ||
              p.text[p.pos] === "\n")) p.pos++;
        if (p.pos < p.text.length && p.text[p.pos] === ",") {
          p.pos++;
          continue;
        }
        if (p.pos < p.text.length && p.text[p.pos] === "]") {
          p.pos++;
          return arr;
        }
        perr("expected `,` or `]` in flow sequence", line);
      }
    }
    if (c === "{") {
      p.pos++;
      var obj = {}, explicit = {};
      var firstPair = true;
      for (;;) {
        while (p.pos < p.text.length &&
            (p.text[p.pos] === " " || p.text[p.pos] === "\t" ||
              p.text[p.pos] === "\n")) p.pos++;
        if (p.pos < p.text.length && p.text[p.pos] === "}") {
          p.pos++;
          return obj;
        }
        if (!firstPair) {
          if (p.pos < p.text.length && p.text[p.pos] === ",") {
            p.pos++;
            while (p.pos < p.text.length &&
                (p.text[p.pos] === " " || p.text[p.pos] === "\t" ||
                  p.text[p.pos] === "\n")) p.pos++;
            if (p.pos < p.text.length && p.text[p.pos] === "}") {
              p.pos++;
              return obj;
            }
          } else {
            perr("expected `,` or `}` in flow mapping", line);
          }
        }
        firstPair = false;
        if (p.pos < p.text.length && p.text[p.pos] === ":") {
          p.pos++;
          while (p.pos < p.text.length &&
              (p.text[p.pos] === " " || p.text[p.pos] === "\t" ||
                p.text[p.pos] === "\n")) p.pos++;
          var ev = this.flowValue(p, line, false);
          obj[""] = ev;
          explicit[""] = 1;
          continue;
        }
        var key = this.flowValue(p, line, true);
        while (p.pos < p.text.length &&
            (p.text[p.pos] === " " || p.text[p.pos] === "\t" ||
              p.text[p.pos] === "\n")) p.pos++;
        if (p.pos >= p.text.length || p.text[p.pos] !== ":") {
          perr("expected `:` in flow mapping", line);
        }
        p.pos++;
        while (p.pos < p.text.length &&
            (p.text[p.pos] === " " || p.text[p.pos] === "\t" ||
              p.text[p.pos] === "\n")) p.pos++;
        var val = null;
        if (p.pos < p.text.length && p.text[p.pos] !== "," &&
            p.text[p.pos] !== "}") {
          val = this.flowValue(p, line, false);
        }
        var ks = keyToString(key);
        if (ks === "<<") {
          this.mergeValue(obj, explicit, val, line);
        } else {
          if (Object.prototype.hasOwnProperty.call(explicit, ks)) {
            perr("duplicate key \"" + ks + "\"", line);
          }
          explicit[ks] = 1;
          obj[ks] = val;
        }
      }
    }
    if (c === "'" || c === "\"") {
      var q = c;
      if (q === "'") {
        var start = p.pos + 1, out = "", i = start;
        for (;;) {
          if (i >= p.text.length) perr("unterminated quoted scalar", line);
          if (p.text[i] === "'") {
            if (p.text[i + 1] === "'") {
              out += p.text.slice(start, i) + "'";
              i += 2;
              start = i;
              continue;
            }
            out += p.text.slice(start, i);
            p.pos = i + 1;
            return out;
          }
          i++;
        }
      }
      var inner = "", j = p.pos + 1;
      for (;;) {
        if (j >= p.text.length) perr("unterminated quoted scalar", line);
        if (p.text[j] === "\\") {
          j += 2;
          continue;
        }
        if (p.text[j] === "\"") break;
        j++;
      }
      inner = p.text.slice(p.pos + 1, j);
      p.pos = j + 1;
      return unescapeDouble(inner, line);
    }
    var end2 = p.pos;
    while (end2 < p.text.length) {
      var ec = p.text[end2];
      if (",[]{}\n".indexOf(ec) >= 0) break;
      if (isKey && ec === ":") {
        var fol = p.text[end2 + 1];
        if (fol === undefined || fol === " " || fol === "\t" ||
            fol === "\n" || fol === "," || fol === "]" || fol === "}") {
          break;
        }
      }
      end2++;
    }
    var word = p.text.slice(p.pos, end2).replace(/[ \t]+$/g, "");
    p.pos = end2;
    if (word === "") perr("unexpected character in flow collection", line);
    return resolvePlain(word);
  } finally {
    this.depth--;
  }
};

/*
 * Merges a `<<` value into a mapping. Existing keys always win;
 * a sequence merges each mapping in order (first wins).
 * @param {object} obj - Target mapping.
 * @param {object} explicit - Explicit-key set.
 * @param {any} val - Merge source.
 * @param {number} line - Line number for errors.
 */
Parser.prototype.mergeValue = function (obj, explicit, val, line) {
  var srcs = Array.isArray(val) ? val : [val];
  for (var i = 0; i < srcs.length; i++) {
    var s = srcs[i];
    if (s === null) continue;
    if (typeof s !== "object" || s instanceof Date || Array.isArray(s)) {
      perr("invalid merge value", line);
    }
    for (var k in s) {
      if (!Object.prototype.hasOwnProperty.call(s, k)) continue;
      if (!Object.prototype.hasOwnProperty.call(obj, k)) obj[k] = s[k];
    }
  }
};

/*
 * Parses the value of a `key:` entry whose remainder is `rest`.
 * @param {number} indent - Key indent.
 * @param {string} rest - Text after the colon.
 * @param {number} line - Key line number.
 * @returns {any} The value.
 */
Parser.prototype.mapValue = function (indent, rest, line) {
  var pr = this.splitProps(rest, line);
  if (pr.rest === "") {
    var l = this.peek();
    if (l !== null && l.indent > indent) {
      var v = this.blockNode(l.indent);
      if (pr.tag !== null) v = applyTag(pr.tag, v, undefined, line);
      this.putAnchor(pr.anchor, v);
      if (pr.anchor !== null && this.building[pr.anchor]) {
        delete this.building[pr.anchor];
      }
      return v;
    }
    if (l !== null && l.indent === indent && isDashLine(l.text)) {
      var sv2 = this.blockSeq(l.indent);
      if (pr.tag !== null) sv2 = applyTag(pr.tag, sv2, undefined, line);
      this.putAnchor(pr.anchor, sv2);
      return sv2;
    }
    var nv = pr.tag !== null ? applyTag(pr.tag, null, "", line) : null;
    this.putAnchor(pr.anchor, nv);
    return nv;
  }
  if (pr.rest[0] === "*") {
    var am = /^\*([A-Za-z0-9_\-]+)$/.exec(pr.rest);
    if (!am) perr("bad alias", line);
    var av = this.getAlias(am[1], line);
    if (pr.tag !== null) av = applyTag(pr.tag, av, undefined, line);
    this.putAnchor(pr.anchor, av);
    return av;
  }
  var h = blockHeader(pr.rest);
  if (h !== null) {
    if (pr.anchor !== null) this.building[pr.anchor] = 1;
    var sv = this.readBlockScalar(h, indent, line);
    if (pr.tag !== null) sv = applyTag(pr.tag, sv, sv, line);
    this.putAnchor(pr.anchor, sv);
    return sv;
  }
  if (pr.rest[0] === "[" || pr.rest[0] === "{") {
    if (pr.anchor !== null) this.building[pr.anchor] = 1;
    var cur = {text: this.readFlowText(pr.rest, line), pos: 0};
    var fv = this.flowValue(cur, line, false);
    while (cur.pos < cur.text.length &&
        (cur.text[cur.pos] === " " || cur.text[cur.pos] === "\t" ||
          cur.text[cur.pos] === "\n")) cur.pos++;
    if (cur.pos !== cur.text.length) {
      perr("unexpected content after a flow collection", line);
    }
    if (pr.tag !== null) fv = applyTag(pr.tag, fv, undefined, line);
    this.putAnchor(pr.anchor, fv);
    return fv;
  }
  if (pr.rest === "-" || pr.rest.slice(0, 2) === "- " ||
      pr.rest.slice(0, 2) === "-\t" || pr.rest === "?" ||
      pr.rest.slice(0, 2) === "? " || pr.rest.slice(0, 2) === "?\t") {
    perr("block indicators need their own line", line);
  }
  if (pr.rest[0] === "'" || pr.rest[0] === "\"") {
    var q = pr.rest[0];
    var full = this.readQuotedText(pr.rest, q, line);
    var innerRaw = q === "'" ?
      full.slice(1, full.lastIndexOf("'")) :
      full.slice(1, full.lastIndexOf("\""));
    innerRaw = foldQuotedBreaks(innerRaw);
    var qv = q === "'" ? innerRaw.replace(/''/g, "'") :
      unescapeDouble(innerRaw, line);
    var tail = full.slice(
      q === "'" ? full.lastIndexOf("'") + 1 : full.lastIndexOf("\"") + 1);
    if (tail.replace(/^[ \t\n]+/, "") !== "") {
      perr("unexpected content after a quoted scalar", line);
    }
    if (pr.tag !== null) qv = applyTag(pr.tag, qv, qv, line);
    this.putAnchor(pr.anchor, qv);
    return qv;
  }
  var text = pr.rest, parts = [text];
  for (;;) {
    var nx = this.peek();
    if (nx === null || nx.indent <= indent) break;
    if (isDashLine(nx.text) || isQuestionLine(nx.text)) break;
    if (findMappingColon(nx.text) >= 0) break;
    if (blockHeader(this.splitProps(nx.text, nx.num).rest) !== null) break;
    if (nx.text[0] === "[" || nx.text[0] === "{" || nx.text[0] === "]" ||
        nx.text[0] === "}" || nx.text[0] === "," || nx.text[0] === "*" ||
        nx.text === "---" || nx.text.slice(0, 4) === "--- " ||
        nx.text === "...") break;
    this.next();
    parts.push(nx.text);
  }
  var joined = parts.join(" ");
  var pv = resolvePlain(joined);
  if (pr.tag !== null) pv = applyTag(pr.tag, pv, joined, line);
  this.putAnchor(pr.anchor, pv);
  return pv;
};

/*
 * Resolves a mapping key text to its string form.
 * @param {string} keyText - Raw key text.
 * @param {number} line - Line number for errors.
 * @returns {string} The key.
 */
Parser.prototype.mapKey = function (keyText, line) {
  var t = keyText.replace(/^[ \t]+|[ \t]+$/g, "");
  if (t === "") return "";
  var pr = this.splitProps(t, line);
  var core = pr.rest;
  var v;
  if (core === "") {
    v = null;
  } else if (core[0] === "'" || core[0] === "\"") {
    var q = core[0];
    var last = q === "'" ? core.lastIndexOf("'") : core.lastIndexOf("\"");
    if (last <= 0) perr("unterminated quoted scalar", line);
    v = q === "'" ? core.slice(1, last).replace(/''/g, "'") :
      unescapeDouble(core.slice(1, last), line);
  } else if (core[0] === "[" || core[0] === "{") {
    var ft = {text: core, pos: 0};
    v = this.flowValue(ft, line, true);
  } else if (core[0] === "*") {
    var am = /^\*([A-Za-z0-9_\-]+)$/.exec(core);
    if (!am) perr("bad alias", line);
    v = this.getAlias(am[1], line);
  } else {
    v = resolvePlain(core);
  }
  if (pr.tag !== null) v = applyTag(pr.tag, v, core, line);
  if (pr.anchor !== null) this.putAnchor(pr.anchor, v);
  return keyToString(v);
};

/*
 * Renders a node in compact flow form for complex mapping keys.
 * @param {any} v - The key node.
 * @returns {string} The key text.
 */
function renderCompact(v) {
  if (v === null) return "null";
  if (v === true) return "true";
  if (v === false) return "false";
  if (typeof v === "number") return String(v);
  if (typeof v === "string") return v;
  if (v instanceof Date) return v.toISOString();
  if (Array.isArray(v)) {
    return "[" + v.map(renderCompact).join(", ") + "]";
  }
  var parts = [];
  for (var k in v) {
    if (!Object.prototype.hasOwnProperty.call(v, k)) continue;
    parts.push(k + ": " + renderCompact(v[k]));
  }
  return "{" + parts.join(", ") + "}";
}

/*
 * Parses a block mapping at `indent`.
 * @param {number} indent - Mapping indent.
 * @returns {object} The mapping.
 */
Parser.prototype.blockMap = function (indent) {
  this.depth++;
  this.checkDepth(0);
  try {
    var obj = {}, explicit = {};
    for (;;) {
      var l = this.peek();
      if (l === null || l.indent !== indent) return obj;
      if (l.text === "---" || l.text.slice(0, 4) === "--- " ||
          l.text === "..." || l.text.slice(0, 4) === "... ") return obj;
      if (isDashLine(l.text)) return obj;
      if (isQuestionLine(l.text)) {
        this.next();
        var qrest = l.text.length > 1 ? l.text.slice(1).replace(/^[ \t]+/, "") : "";
        var key;
        if (qrest === "") {
          var nl = this.peek();
          if (nl !== null && nl.indent > indent) {
            var nv = this.blockNode(nl.indent);
            key = keyToString(nv);
          } else {
            key = "";
          }
        } else if (findMappingColon(qrest) >= 0) {
          var sub = new Parser([qrest]);
          var sm = sub.blockMap(0);
          key = renderCompact(sm);
        } else {
          key = this.mapKey(qrest, l.num);
        }
        var cl = this.peek();
        var value = null;
        if (cl !== null && cl.indent === indent &&
            (cl.text === ":" || cl.text.slice(0, 2) === ": " ||
              cl.text.slice(0, 2) === ":\t")) {
          this.next();
          var crest = cl.text.length > 1 ?
            cl.text.slice(1).replace(/^[ \t]+/, "") : "";
          value = this.mapValue(indent, crest, cl.num);
        } else if (cl !== null && cl.indent > indent) {
          value = this.blockNode(cl.indent);
        }
        if (key === "<<") {
          this.mergeValue(obj, explicit, value, l.num);
        } else {
          if (Object.prototype.hasOwnProperty.call(explicit, key)) {
            perr("duplicate key \"" + key + "\"", l.num);
          }
          explicit[key] = 1;
          obj[key] = value;
        }
        continue;
      }
      if (l.text[0] === ":") {
        this.next();
        var erest = l.text.length > 1 ?
          l.text.slice(1).replace(/^[ \t]+/, "") : "";
        var ev = this.mapValue(indent, erest, l.num);
        if (Object.prototype.hasOwnProperty.call(explicit, "")) {
          perr("duplicate key \"\"", l.num);
        }
        explicit[""] = 1;
        obj[""] = ev;
        continue;
      }
      var ci = findMappingColon(l.text);
      if (ci < 0) return obj;
      var keyText = l.text.slice(0, ci);
      var rest = l.text.slice(ci + 1).replace(/^[ \t]+/, "");
      this.next();
      var k = this.mapKey(keyText, l.num);
      var vv = this.mapValue(indent, rest, l.num);
      if (k === "<<") {
        this.mergeValue(obj, explicit, vv, l.num);
      } else {
        if (Object.prototype.hasOwnProperty.call(explicit, k)) {
          perr("duplicate key \"" + k + "\"", l.num);
        }
        explicit[k] = 1;
        obj[k] = vv;
      }
    }
  } finally {
    this.depth--;
  }
};

/*
 * Parses one `-` item with remainder `rest`.
 * @param {number} indent - Dash indent.
 * @param {string} rest - Text after the dash.
 * @param {number} line - Dash line number.
 * @returns {any} The item.
 */
Parser.prototype.seqItem = function (indent, rest, line) {
  var pr = this.splitProps(rest, line);
  if (pr.rest === "") {
    var l = this.peek();
    if (l !== null && l.indent > indent) {
      var v = this.blockNode(l.indent);
      if (pr.tag !== null) v = applyTag(pr.tag, v, undefined, line);
      this.putAnchor(pr.anchor, v);
      return v;
    }
    var nv = pr.tag !== null ? applyTag(pr.tag, null, "", line) : null;
    this.putAnchor(pr.anchor, nv);
    return nv;
  }
  if (pr.rest[0] === "*") {
    var am = /^\*([A-Za-z0-9_\-]+)$/.exec(pr.rest);
    if (!am) perr("bad alias", line);
    var av = this.getAlias(am[1], line);
    if (pr.tag !== null) av = applyTag(pr.tag, av, undefined, line);
    this.putAnchor(pr.anchor, av);
    return av;
  }
  var h = blockHeader(pr.rest);
  if (h !== null) {
    if (pr.anchor !== null) this.building[pr.anchor] = 1;
    var sv = this.readBlockScalar(h, indent, line);
    if (pr.tag !== null) sv = applyTag(pr.tag, sv, sv, line);
    this.putAnchor(pr.anchor, sv);
    return sv;
  }
  this.raws.splice(this.pos, 0,
    new Array(indent + 2 + 1).join(" ") + pr.rest);
  var iv = this.blockNode(indent + 2);
  if (pr.tag !== null) iv = applyTag(pr.tag, iv, undefined, line);
  this.putAnchor(pr.anchor, iv);
  return iv;
};

/*
 * Parses a block sequence at `indent`.
 * @param {number} indent - Dash indent.
 * @returns {Array<any>} The sequence.
 */
Parser.prototype.blockSeq = function (indent) {
  this.depth++;
  this.checkDepth(0);
  try {
    var arr = [];
    for (;;) {
      var l = this.peek();
      if (l === null || l.indent !== indent || !isDashLine(l.text)) {
        return arr;
      }
      this.next();
      var rest = l.text.length > 1 ? l.text.slice(1).replace(/^[ \t]+/, "") : "";
      arr.push(this.seqItem(indent, rest, l.num));
    }
  } finally {
    this.depth--;
  }
};

/*
 * Parses a block scalar or plain scalar starting at line `l`.
 * Handles multiline plain folding and multiline quotes.
 * @param {object} l - Consumed line {num, indent, text}.
 * @returns {any} The scalar value.
 */
Parser.prototype.blockScalar = function (l) {
  var pr = this.splitProps(l.text, l.num);
  if (pr.rest === "") {
    var nx = this.peek();
    if (nx !== null && nx.indent > l.indent) {
      var v = this.blockNode(nx.indent);
      if (pr.tag !== null) v = applyTag(pr.tag, v, undefined, l.num);
      this.putAnchor(pr.anchor, v);
      return v;
    }
    var nv = pr.tag !== null ? applyTag(pr.tag, null, "", l.num) : null;
    this.putAnchor(pr.anchor, nv);
    return nv;
  }
  if (pr.rest[0] === "*") {
    var am = /^\*([A-Za-z0-9_\-]+)$/.exec(pr.rest);
    if (!am) perr("bad alias", l.num);
    var av = this.getAlias(am[1], l.num);
    if (pr.tag !== null) av = applyTag(pr.tag, av, undefined, l.num);
    this.putAnchor(pr.anchor, av);
    return av;
  }
  var h = blockHeader(pr.rest);
  if (h !== null) {
    if (pr.anchor !== null) this.building[pr.anchor] = 1;
    var sv = this.readBlockScalar(h, l.indent, l.num);
    if (pr.tag !== null) sv = applyTag(pr.tag, sv, sv, l.num);
    this.putAnchor(pr.anchor, sv);
    return sv;
  }
  if (pr.rest[0] === "[" || pr.rest[0] === "{") {
    if (pr.anchor !== null) this.building[pr.anchor] = 1;
    var cur = {text: this.readFlowText(pr.rest, l.num), pos: 0};
    var fv = this.flowValue(cur, l.num, false);
    while (cur.pos < cur.text.length &&
        (cur.text[cur.pos] === " " || cur.text[cur.pos] === "\t" ||
          cur.text[cur.pos] === "\n")) cur.pos++;
    if (cur.pos !== cur.text.length) {
      perr("unexpected content after a flow collection", l.num);
    }
    if (pr.tag !== null) fv = applyTag(pr.tag, fv, undefined, l.num);
    this.putAnchor(pr.anchor, fv);
    return fv;
  }
  if (pr.rest[0] === "'" || pr.rest[0] === "\"") {
    var q = pr.rest[0];
    var full = this.readQuotedText(pr.rest, q, l.num);
    var last = q === "'" ? full.lastIndexOf("'") : full.lastIndexOf("\"");
    var innerRaw2 = foldQuotedBreaks(full.slice(1, last));
    var qv = q === "'" ? innerRaw2.replace(/''/g, "'") :
      unescapeDouble(innerRaw2, l.num);
    var tail = full.slice(last + 1);
    if (tail.replace(/^[ \t\n]+/, "") !== "") {
      perr("unexpected content after a quoted scalar", l.num);
    }
    if (pr.tag !== null) qv = applyTag(pr.tag, qv, qv, l.num);
    this.putAnchor(pr.anchor, qv);
    return qv;
  }
  var parts = [pr.rest];
  for (;;) {
    var nx2 = this.peek();
    if (nx2 === null || nx2.indent <= l.indent) break;
    if (isDashLine(nx2.text) || isQuestionLine(nx2.text)) break;
    if (findMappingColon(nx2.text) >= 0) break;
    if (blockHeader(this.splitProps(nx2.text, nx2.num).rest) !== null) break;
    if (nx2.text === "---" || nx2.text.slice(0, 4) === "--- " ||
        nx2.text === "...") break;
    this.next();
    parts.push(nx2.text);
  }
  var joined = parts.join(" ");
  var pv = resolvePlain(joined);
  if (pr.tag !== null) pv = applyTag(pr.tag, pv, joined, l.num);
  this.putAnchor(pr.anchor, pv);
  return pv;
};

/*
 * Parses the block node starting at the next significant line.
 * @param {number} minIndent - Minimum accepted indent.
 * @returns {any} The node (undefined when nothing follows).
 */
Parser.prototype.blockNode = function (minIndent) {
  var l = this.peek();
  if (l === null || l.indent < minIndent) return undefined;
  if (l.text === "---" || l.text.slice(0, 4) === "--- " ||
      l.text === "..." || l.text.slice(0, 4) === "... ") {
    return undefined;
  }
  if (isDashLine(l.text)) return this.blockSeq(l.indent);
  if (isQuestionLine(l.text)) return this.blockMap(l.indent);
  if (l.text[0] === ":") return this.blockMap(l.indent);
  if (findMappingColon(l.text) >= 0) return this.blockMap(l.indent);
  this.next();
  return this.blockScalar(l);
};

/*
 * Validates a `%YAML` / `%TAG` directive line.
 * @param {string} text - Text after `%`.
 * @param {number} line - Line number for errors.
 */
Parser.prototype.directive = function (text, line) {
  var sp = text.indexOf(" ");
  var name = sp < 0 ? text : text.slice(0, sp);
  var rest = sp < 0 ? "" : text.slice(sp + 1).replace(/^[ \t]+/, "");
  if (name === "YAML") {
    var parts = rest.split(".");
    if (parts.length !== 2 || parts[0] === "" || parts[1] === "" ||
        !/^[0-9]+$/.test(parts[0]) || !/^[0-9]+$/.test(parts[1])) {
      perr("`%YAML` requires a version such as `%YAML 1.2`", line);
    }
    var major = parseInt(parts[0], 10), minor = parseInt(parts[1], 10);
    if (major !== 1 || minor > 2) {
      if (major > 1) perr("incompatible YAML version `%YAML " + rest + "`", line);
    }
  } else if (name === "TAG") {
    var ps = rest.split(/[ \t]+/);
    if (ps.length !== 2 || ps[0] === "" || ps[1] === "") {
      perr("`%TAG` requires a handle and a prefix", line);
    }
    this.handles[ps[0]] = ps[1];
  } else if (name === "") {
    perr("empty directive name after `%`", line);
  } else {
    perr("unknown directive `%" + name + "`", line);
  }
};

/*
 * Parses the single document and returns its value.
 * @returns {any} The document value (null for empty input).
 */
Parser.prototype.document = function () {
  var l = this.peek();
  while (l !== null && l.text[0] === "%") {
    this.next();
    this.directive(l.text.slice(1).replace(/^[ \t]+/, ""), l.num);
    l = this.peek();
  }
  if (l !== null && (l.text === "---" || l.text.slice(0, 4) === "--- ")) {
    this.next();
    var rest = l.text.length > 3 ?
      l.text.slice(3).replace(/^[ \t]+/, "") : "";
    if (rest !== "") {
      this.raws.splice(this.pos, 0, new Array(l.indent + 1).join(" ") + rest);
    }
    l = this.peek();
  }
  if (l === null || l.text === "..." ||
      l.text.slice(0, 4) === "... ") {
    return null;
  }
  var v;
  if (isDashLine(l.text)) {
    v = this.blockSeq(l.indent);
  } else if (isQuestionLine(l.text) || l.text[0] === ":" ||
      findMappingColon(l.text) >= 0) {
    v = this.blockMap(l.indent);
  } else {
    var pr0 = this.splitProps(l.text, l.num);
    if (pr0.rest === "" && (pr0.anchor !== null || pr0.tag !== null)) {
      this.next();
      var nv = this.blockNode(0);
      if (nv === undefined) nv = null;
      if (pr0.tag !== null) nv = applyTag(pr0.tag, nv, undefined, l.num);
      this.putAnchor(pr0.anchor, nv);
      v = nv;
    } else {
      this.next();
      v = this.blockScalar(l);
    }
  }
  if (v === undefined) v = null;
  var tail = this.peek();
  if (tail !== null && tail.text !== "..." &&
      tail.text.slice(0, 4) !== "... " && tail.text !== "---" &&
      tail.text.slice(0, 4) !== "--- ") {
    perr("bad indentation", tail.num);
  }
  return v;
};

// -- public API --------------------------------------------------------------

/*
 * yaml.parse(text) -> value. Throws on bad input and non-strings.
 * @param {string} text - YAML document text.
 * @returns {any} The parsed value (Date for timestamps).
 */
function parse(text) {
  if (typeof text !== "string") {
    throw new Error("parse: type mismatch parameter: `text`. Got `" +
      jsKind(text) + "`, expected `string`");
  }
  var src = text.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
  if (src.length > 0 && src.charCodeAt(0) === 0xFEFF) src = src.slice(1);
  var raws = src.split("\n");
  if (src.length > 0 && src[src.length - 1] === "\n") raws.pop();
  var p = new Parser(raws);
  var v = p.document();
  return v === undefined ? null : v;
}

// -- stringify ---------------------------------------------------------------

/*
 * Formats a float so Core Schema reads it back unchanged.
 * @param {number} f - The float.
 * @returns {string} The YAML text.
 */
function floatText(f) {
  if (Number.isNaN(f)) return ".nan";
  if (f === Infinity) return ".inf";
  if (f === -Infinity) return "-.inf";
  var t = String(f);
  if (t.slice(0, 1) === ".") t = "0" + t;
  else if (t.slice(0, 2) === "-.") t = "-0" + t.slice(1);
  if (t.indexOf("e") < 0 && t.indexOf("E") < 0 &&
      t.indexOf(".") < 0 && t.indexOf("inf") < 0) {
    t += ".0";
  }
  return t;
}

/*
 * True when a string can appear unquoted as a plain scalar.
 * @param {string} s - The string.
 * @returns {boolean} Plain-safe or not.
 */
function plainSafe(s) {
  if (s.length === 0) return false;
  if (/^[ \t]|[ \t]$/.test(s)) return false;
  if (/[\n\r\t,:[\]{}#&*!|>'\"%@?:-]/.test(s[0])) {
    if (!/^[A-Za-z0-9_]/.test(s[0])) return false;
  }
  if (/[,\n\r\t:[\]{}#]/.test(s)) {
    if (s.indexOf(": ") >= 0 || s[s.length - 1] === ":") return false;
    if (/[,\[\]{}#\n\r\t]/.test(s)) return false;
  }
  if (s.indexOf(" #") >= 0) return false;
  if (s === "---" || s === "...") return false;
  if (resolvePlain(s) !== s) return false;
  if (/^[|>]/.test(s)) return false;
  return true;
}

/*
 * Renders a string as a double-quoted YAML scalar.
 * @param {string} s - The string.
 * @returns {string} The quoted scalar.
 */
function quoteString(s) {
  var out = "\"";
  for (var i = 0; i < s.length; i++) {
    var c = s[i], o = s.charCodeAt(i);
    if (c === "\\") out += "\\\\";
    else if (c === "\"") out += "\\\"";
    else if (c === "\n") out += "\\n";
    else if (c === "\r") out += "\\r";
    else if (c === "\t") out += "\\t";
    else if (c === "\x85") out += "\\N";
    else if (c === "\xa0") out += "\\_";
    else if (c === "\u2028") out += "\\L";
    else if (c === "\u2029") out += "\\P";
    else if (o < 32) {
      var h = o.toString(16);
      out += "\\x" + (h.length === 1 ? "0" + h : h);
    } else {
      out += c;
    }
  }
  return out + "\"";
}

/*
 * Renders a string scalar, quoting only when required.
 * @param {string} s - The string.
 * @returns {string} Plain or quoted scalar.
 */
function emitScalar(s) {
  return plainSafe(s) ? s : quoteString(s);
}

/*
 * Renders a mapping key, quoting whenever plain is ambiguous.
 * @param {string} s - The key.
 * @returns {string} The key text.
 */
function emitKey(s) {
  if (s.length === 0) return "\"\"";
  for (var i = 0; i < s.length; i++) {
    var c = s[i];
    if (c === " " || c === "\t" || c === "\n" || c === "\r" ||
        c === ":" || c === "#") {
      return quoteString(s);
    }
  }
  return emitScalar(s);
}

/*
 * Block-scalar header for a multiline string, or "" when block
 * style would not round-trip (trailing spaces, blank-only, ...).
 * @param {string} s - The string.
 * @returns {string} The header (`|`, `|-`, `|+`, `|2`, ...) or "".
 */
function blockHeaderFor(s) {
  if (s.length === 0 || s.indexOf("\n") < 0) return "";
  if (s.replace(/[\n \t]/g, "") === "") return "";
  var lines = s.split("\n");
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].length > 0) {
      var last = lines[i][lines[i].length - 1];
      if (last === " " || last === "\t") return "";
    }
  }
  var trailing = 0, body = s;
  while (body.length > 0 && body[body.length - 1] === "\n") {
    body = body.slice(0, -1);
    trailing++;
  }
  body += "\n";
  var indicator = (body.length === 0 || body[0] === " " || body[0] === "\n") ?
    "2" : "";
  var chomp = trailing === 0 ? "-" : trailing === 1 ? "" : "+";
  return "|" + indicator + chomp;
}

/*
 * Stringify state: output buffer, depth guard and ancestry stack
 * for circular detection.
 */
function Emitter() {
  this.out = [];
  this.stack = [];
}

/*
 * Emits one node at `indent`; collections take their own block
 * unless `sameLine` continues a `-`/`key:` line.
 * @param {any} node - Value to emit.
 * @param {number} indent - Column of block content.
 * @param {boolean} sameLine - Caller already wrote the separator.
 */
Emitter.prototype.node = function (node, indent, sameLine) {
  if (node === undefined || typeof node === "function" ||
      typeof node === "symbol") {
    serr("value is not YAML-serializable");
  }
  if (typeof node === "bigint") {
    serr("value is not YAML-serializable (bigint)");
  }
  if (node === null) {
    this.out.push("null");
    return;
  }
  if (node === true) {
    this.out.push("true");
    return;
  }
  if (node === false) {
    this.out.push("false");
    return;
  }
  if (typeof node === "number") {
    if (!Number.isFinite(node)) {
      this.out.push("null");
      return;
    }
    if (node === Math.floor(node) && Math.abs(node) < 9223372036854775808) {
      this.out.push(String(node));
    } else {
      this.out.push(floatText(node));
    }
    return;
  }
  if (typeof node === "string") {
    var header = blockHeaderFor(node);
    if (header !== "") {
      this.out.push(header);
      var bodyIndent = indent + 2;
      if (header.indexOf("2") >= 0) bodyIndent = indent + 2;
      var lines = node.split("\n");
      var last = lines.length - 1;
      if (node[node.length - 1] === "\n") lines = lines.slice(0, -1);
      for (var i = 0; i < lines.length; i++) {
        if (lines[i] === "" && i >= last) continue;
        this.out.push("\n" + new Array(bodyIndent + 1).join(" ") + lines[i]);
      }
      if (header.slice(-1) === "-" || node[node.length - 1] !== "\n") {
        // strip chomping already reflected in header
      }
      return;
    }
    this.out.push(emitScalar(node));
    return;
  }
  if (node instanceof Date) {
    if (Number.isNaN(node.getTime())) serr("value is not YAML-serializable");
    this.out.push(node.toISOString());
    return;
  }
  if (this.stack.indexOf(node) >= 0) serr("circular structure");
  if (this.stack.length >= 64) serr("value is too deeply nested or circular");
  this.stack.push(node);
  try {
    if (Array.isArray(node)) {
      if (node.length === 0) {
        this.out.push("[]");
        return;
      }
      for (var k = 0; k < node.length; k++) {
        var item = node[k];
        if (!(k === 0 && sameLine)) {
          this.out.push("\n" + new Array(indent + 1).join(" "));
        }
        this.out.push("-");
        var coll = item !== null && typeof item === "object" &&
          !(item instanceof Date) &&
          (Array.isArray(item) || Object.keys(item).length > 0);
        if (coll) {
          this.node(item, indent + 2, false);
        } else {
          this.out.push(" ");
          this.node(item === undefined || typeof item === "function" ||
            typeof item === "symbol" ? null : item, indent + 2, true);
        }
      }
      return;
    }
    var keys = Object.keys(node);
    var live = [];
    for (var lj = 0; lj < keys.length; lj++) {
      if (!isSkipped(node[keys[lj]])) live.push(keys[lj]);
    }
    if (live.length === 0) {
      this.out.push("{}");
      return;
    }
    for (var j = 0; j < live.length; j++) {
      var key = live[j], val = node[key];
      if (!(j === 0 && sameLine)) {
        this.out.push("\n" + new Array(indent + 1).join(" "));
      }
      this.out.push(emitKey(key) + ":");
      var vcoll = val !== null && typeof val === "object" &&
        !(val instanceof Date) &&
        (Array.isArray(val) || Object.keys(val).length > 0);
      if (vcoll) {
        this.node(val, indent + 2, false);
      } else {
        this.out.push(" ");
        this.node(val, indent + 2, true);
      }
    }
  } finally {
    this.stack.pop();
  }
};

/*
 * yaml.stringify(value) -> string (single YAML document).
 * Dates emit ISO timestamps; holes mirror JSON (skipped in
 * objects, null in arrays); bigints and circular input throw.
 * @param {any} value - Value to serialize.
 * @returns {string} The YAML document text.
 */
function stringify(value) {
  var e = new Emitter();
  e.node(value, 0, false);
  var s = e.out.join("");
  if (s.replace(/\n/g, "") === "") return "{}\n";
  return s.replace(/^\n+/, "").replace(/\n+$/, "") + "\n";
}

module.exports = {parse: parse, stringify: stringify};
