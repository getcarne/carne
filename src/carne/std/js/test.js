// Carne std/test: minimal test runner (JS + std/terminal colors).
//
//   const { test, describe, it, expect, assert } = require("std/test");
//   test("adds", () => { expect(1 + 1).toBe(2); });
//   describe("math", () => {
//     it("throws", () => { assert.throws(() => bad()); });
//   });
//
// Two styles, user decides: `expect` matchers or Node-style `assert`.
// Registration is synchronous; execution is deferred through a
// zero-delay timer so tests run after the file finishes evaluating
// (works under both `carne run` and `carne test`). Each `carne test`
// file runs in a fresh runtime, so state never leaks between files.
// Async test functions (promise-returning) are awaited serially.
// Results print as `[ok] <name>` / `[failed] <name>` lines (green/red
// on TTYs via std/terminal, plain on pipes) plus a summary; any
// failure throws at the end (exit 1). `describe` bodies
// must stay synchronous (grouping only, no assertions).
"use strict";

var terminal = require("std/terminal");
/*
 * @typedef {object} TestStats - Runner counters.
 * @typedef {object} Expectation - Matcher set from expect().
 */

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
 * Requires a function argument.
 * @param {string} fname - Function name for errors.
 * @param {string} pname - Parameter name for errors.
 * @param {any} v - The value to check.
 * @returns {Function} The value, narrowed to function.
 */
function reqFn(fname, pname, v) {
  if (typeof v !== "function") {
    throw new Error(fname + ": type mismatch parameter: `" + pname +
      "`. Got `" + jsKind(v) + "`, expected `function`");
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

// -- registry and deferred runner ----------------------------------------------

var suiteStack = [];
var queue = [];
var queueIndex = 0;
var scheduled = false;
var finished = false;
var passCount = 0;
var failCount = 0;

/*
 * Full name with describe prefixes (`a > b > case`).
 * @param {string} name - The bare case name.
 * @returns {string} The prefixed name.
 */
function fullName(name) {
  return suiteStack.length > 0 ? suiteStack.join(" > ") + " > " + name :
    name;
}

/*
 * Schedules the deferred run on first registration. Importing alone
 * schedules nothing, so helpers can require this module freely.
 * @returns {void} Schedules at most one flush.
 */
function ensureScheduled() {
  if (scheduled) return;
  scheduled = true;
  if (typeof setTimeout === "function") {
    setTimeout(runNext, 0);
  } else {
    runAllSync();
  }
}

/*
 * Records a pass and prints it.
 * @param {object} t - The test entry.
 * @returns {void} Prints green `[ok] <name>`.
 */
function recordPass(t) {
  passCount++;
  console.log(terminal.green("[ok]") + " " + t.name);
}

/*
 * Records a failure and prints it with an indented message.
 * @param {object} t - The test entry.
 * @param {any} e - The thrown value.
 * @returns {void} Prints red `[failed] <name>` plus detail.
 */
function recordFail(t, e) {
  failCount++;
  var msg = e && e.message !== undefined ? String(e.message) : String(e);
  console.log(terminal.red("[failed]") + " " + t.name);
  console.log("  " + msg.split("\n").join("\n  "));
}

/*
 * Schedules the next test tick.
 * @returns {void} Queues runNext via a zero-delay timer.
 */
function scheduleNext() {
  setTimeout(runNext, 0);
}

/*
 * Prints the summary; throws when anything failed (exit 1).
 * @returns {void} Throws on failures.
 */
function finish() {
  finished = true;
  scheduled = false;
  if (queue.length === 0) {
    console.log("no tests found");
    return;
  }
  var total = queue.length;
  var summary = (failCount === 0 ? "pass " : "fail ") + passCount + "/" +
    total + " tests";
  console.log(failCount === 0 ? terminal.green(summary) :
    terminal.red(summary));
  if (failCount > 0) {
    var names = [];
    for (var i = 0; i < queue.length; i++) {
      if (queue[i].failed) names.push(queue[i].name);
    }
    throw new Error("test run failed (" + passCount + " passed, " +
      failCount + " failed): " + names.join(", "));
  }
}

/*
 * Runs one test per timer tick; async (thenable) results resume on
 * settlement so the loop stays alive through real async work.
 * @returns {void} Advances the queue.
 */
function runNext() {
  if (queueIndex >= queue.length) {
    finish();
    return;
  }
  var t = queue[queueIndex++];
  var result;
  try {
    result = t.fn();
  } catch (e) {
    t.failed = true;
    recordFail(t, e);
    scheduleNext();
    return;
  }
  if (result !== null &&
      (typeof result === "object" || typeof result === "function") &&
      typeof result.then === "function") {
    result.then(function () {
      recordPass(t);
      scheduleNext();
    }, function (e) {
      t.failed = true;
      recordFail(t, e);
      scheduleNext();
    });
    return;
  }
  recordPass(t);
  scheduleNext();
}

/*
 * Fallback when no timer global exists: runs sync tests inline.
 * Async entries resolve on their own without reporting.
 * @returns {void} Runs the queue without deferral.
 */
function runAllSync() {
  while (queueIndex < queue.length) {
    var t = queue[queueIndex++];
    try {
      t.fn();
    } catch (e) {
      t.failed = true;
      recordFail(t, e);
      continue;
    }
    recordPass(t);
  }
  finish();
}

// -- registration ----------------------------------------------------------------

/*
 * Registers one case (`fn` may return a promise, which is awaited).
 * @param {string} name - Case name.
 * @param {Function} fn - Case body.
 * @returns {void} Queues the case.
 */
function test(name, fn) {
  arity("test", arguments.length, 2);
  reqStr("test", "name", name);
  reqFn("test", "fn", fn);
  queue.push({name: fullName(name), fn: fn, failed: false});
  ensureScheduled();
}

/*
 * Alias of test.
 * @param {string} name - Case name.
 * @param {Function} fn - Case body.
 * @returns {void} Queues the case.
 */
function it(name, fn) {
  arity("it", arguments.length, 2);
  test(name, fn);
}

/*
 * Groups cases under a shared prefix (body runs immediately and must
 * stay synchronous; a throwing body becomes one failing setup case).
 * @param {string} name - Suite name.
 * @param {Function} fn - Grouping body.
 * @returns {void} Collects the inner cases.
 */
function describe(name, fn) {
  arity("describe", arguments.length, 2);
  reqStr("describe", "name", name);
  reqFn("describe", "fn", fn);
  suiteStack.push(name);
  try {
    fn();
  } catch (e) {
    queue.push({
      name: fullName("(setup)"),
      fn: (function (err) {
        return function () { throw err; };
      }(e)),
      failed: false
    });
  }
  suiteStack.pop();
  ensureScheduled();
}

/*
 * Current runner counters (valid after the deferred run settles).
 * @returns {TestStats} {total, passed, failed, done}.
 */
function stats() {
  return {
    total: queue.length,
    passed: passCount,
    failed: failCount,
    done: finished
  };
}

// -- values -------------------------------------------------------------------------

/*
 * Short stable rendering for failure messages.
 * @param {any} v - Value to render.
 * @returns {string} The rendered value.
 */
function fmt(v) {
  try {
    if (typeof v === "string") return JSON.stringify(v);
    if (v === undefined) return "undefined";
    if (typeof v === "function") return "[Function]";
    var s = JSON.stringify(v);
    return s === undefined ? String(v) : s;
  } catch (e) {
    return String(v);
  }
}

/*
 * Structural equality (arrays, plain objects, Date, RegExp;
 * NaN equals NaN; cycles terminate as equal when paired before).
 * @param {any} a - First value.
 * @param {any} b - Second value.
 * @param {Array<Array<any>>} [seen] - Compared pairs for cycle guard.
 * @returns {boolean} Structurally equal or not.
 */
function deepEqual(a, b, seen) {
  if (Object.is(a, b)) return true;
  if (typeof a !== typeof b) return false;
  if (a === null || b === null) return false;
  if (typeof a !== "object") return false;
  if (a instanceof Date || b instanceof Date) {
    return a instanceof Date && b instanceof Date &&
      a.getTime() === b.getTime();
  }
  if (a instanceof RegExp || b instanceof RegExp) {
    return a instanceof RegExp && b instanceof RegExp &&
      String(a) === String(b);
  }
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  seen = seen || [];
  for (var i = 0; i < seen.length; i++) {
    if (seen[i][0] === a && seen[i][1] === b) return true;
  }
  seen.push([a, b]);
  var ka = Object.keys(a), kb = Object.keys(b);
  if (ka.length !== kb.length) return false;
  for (var j = 0; j < ka.length; j++) {
    var k = ka[j];
    if (!Object.prototype.hasOwnProperty.call(b, k)) return false;
    if (!deepEqual(a[k], b[k], seen)) return false;
  }
  return true;
}

/*
 * Calls fn, capturing the thrown value (or null when it returns).
 * @param {Function} fn - Function to probe.
 * @returns {any} The thrown value, or null.
 */
function captureThrow(fn) {
  try {
    fn();
  } catch (e) {
    return e === undefined ? new Error("threw undefined") : e;
  }
  return null;
}

/*
 * Checks an optional toThrow expectation against a thrown value.
 * @param {any} thrown - The captured throw.
 * @param {any} expected - String substring, RegExp, or constructor.
 * @returns {string|null} Mismatch detail, or null when satisfied.
 */
function matchThrow(thrown, expected) {
  if (expected === undefined) return null;
  var msg = thrown && thrown.message !== undefined ?
    String(thrown.message) : String(thrown);
  if (typeof expected === "string") {
    return msg.indexOf(expected) >= 0 ? null :
      "expected throw containing " + fmt(expected) + ", got " + fmt(msg);
  }
  if (expected instanceof RegExp) {
    return expected.test(msg) ? null :
      "expected throw matching " + String(expected) + ", got " + fmt(msg);
  }
  if (typeof expected === "function") {
    return thrown instanceof expected ? null :
      "expected throw to be instanceof " + (expected.name || "Error");
  }
  return "toThrow: expected a string, RegExp, or constructor";
}

// -- expect ---------------------------------------------------------------------------

/*
 * Builds an expectation; `negated` flips every matcher.
 * @param {any} actual - Value under test.
 * @param {boolean} negated - Whether `.not` was used.
 * @returns {Expectation} The matcher set.
 */
function makeExpect(actual, negated) {
  /*
   * Throws unless `pass` (flipped under `.not`).
   * @param {boolean} pass - Raw matcher outcome.
   * @param {string} msg - Failure detail.
   * @returns {void} Throws on mismatch.
   */
  function check(pass, msg) {
    if (negated ? pass : !pass) throw new Error(msg);
  }
  var self = {
    /*
     * Identity (Object.is: NaN equals NaN, +0 differs from -0).
     * @param {any} expected - Expected value.
     * @returns {void} Throws on mismatch.
     */
    toBe: function (expected) {
      check(Object.is(actual, expected),
        "expected " + fmt(actual) + (negated ? " not" : "") + " toBe " +
        fmt(expected));
    },
    /*
     * Structural equality (see deepEqual).
     * @param {any} expected - Expected value.
     * @returns {void} Throws on mismatch.
     */
    toEqual: function (expected) {
      check(deepEqual(actual, expected),
        "expected " + fmt(actual) + (negated ? " not" : "") + " toEqual " +
        fmt(expected));
    },
    /*
     * Truthiness check.
     * @returns {void} Throws on mismatch.
     */
    toBeTruthy: function () {
      check(!!actual, "expected " + fmt(actual) + " toBeTruthy");
    },
    /*
     * Falsiness check.
     * @returns {void} Throws on mismatch.
     */
    toBeFalsy: function () {
      check(!actual, "expected " + fmt(actual) + " toBeFalsy");
    },
    /*
     * Null check (=== null).
     * @returns {void} Throws on mismatch.
     */
    toBeNull: function () {
      check(actual === null, "expected " + fmt(actual) + " toBeNull");
    },
    /*
     * Undefined check.
     * @returns {void} Throws on mismatch.
     */
    toBeUndefined: function () {
      check(actual === undefined,
        "expected " + fmt(actual) + " toBeUndefined");
    },
    /*
     * Defined check (!== undefined).
     * @returns {void} Throws on mismatch.
     */
    toBeDefined: function () {
      check(actual !== undefined,
        "expected " + fmt(actual) + " toBeDefined");
    },
    /*
     * NaN check.
     * @returns {void} Throws on mismatch.
     */
    toBeNaN: function () {
      check(actual !== actual, "expected " + fmt(actual) + " toBeNaN");
    },
    /*
     * Array membership (Object.is) or string substring.
     * @param {any} item - Member or substring.
     * @returns {void} Throws on mismatch.
     */
    toContain: function (item) {
      arity("toContain", arguments.length, 1);
      var found = false;
      if (typeof actual === "string" && typeof item === "string") {
        found = actual.indexOf(item) >= 0;
      } else if (Array.isArray(actual)) {
        for (var i = 0; i < actual.length; i++) {
          if (Object.is(actual[i], item)) {
            found = true;
            break;
          }
        }
      } else {
        throw new Error("toContain: actual must be an array or string," +
          " got " + jsKind(actual));
      }
      check(found, "expected " + fmt(actual) + (negated ? " not" : "") +
        " toContain " + fmt(item));
    },
    /*
     * String match (substring or RegExp).
     * @param {string|RegExp} expected - Substring or pattern.
     * @returns {void} Throws on mismatch.
     */
    toMatch: function (expected) {
      arity("toMatch", arguments.length, 1);
      if (typeof actual !== "string") {
        throw new Error("toMatch: actual must be a string, got " +
          jsKind(actual));
      }
      var hit;
      if (typeof expected === "string") {
        hit = actual.indexOf(expected) >= 0;
      } else if (expected instanceof RegExp) {
        hit = expected.test(actual);
      } else {
        throw new Error("toMatch: expected a string or RegExp, got " +
          jsKind(expected));
      }
      check(hit, "expected " + fmt(actual) + (negated ? " not" : "") +
        " toMatch " + String(expected));
    },
    /*
     * Throw check (actual must be a function; expected is an
     * optional message substring, RegExp, or constructor).
     * @param {string|RegExp|Function} [expected] - Throw filter.
     * @returns {void} Throws on mismatch.
     */
    toThrow: function (expected) {
      if (typeof actual !== "function") {
        throw new Error("toThrow: actual must be a function, got " +
          jsKind(actual));
      }
      var thrown = captureThrow(actual);
      if (thrown === null) {
        check(false, "expected function to throw");
        return;
      }
      var detail = matchThrow(thrown, expected);
      if (detail === null) {
        check(true, "");
      } else if (typeof expected === "string" ||
          expected instanceof RegExp || typeof expected === "function") {
        check(false, detail);
      } else {
        throw new Error(detail);
      }
    },
    /*
     * Numeric greater-than.
     * @param {number} n - Bound.
     * @returns {void} Throws on mismatch.
     */
    toBeGreaterThan: function (n) {
      arity("toBeGreaterThan", arguments.length, 1);
      reqNum("toBeGreaterThan", "n", n);
      if (typeof actual !== "number") {
        throw new Error("toBeGreaterThan: actual must be a number, got " +
          jsKind(actual));
      }
      check(actual > n, "expected " + fmt(actual) +
        " toBeGreaterThan " + fmt(n));
    },
    /*
     * Numeric less-than.
     * @param {number} n - Bound.
     * @returns {void} Throws on mismatch.
     */
    toBeLessThan: function (n) {
      arity("toBeLessThan", arguments.length, 1);
      reqNum("toBeLessThan", "n", n);
      if (typeof actual !== "number") {
        throw new Error("toBeLessThan: actual must be a number, got " +
          jsKind(actual));
      }
      check(actual < n, "expected " + fmt(actual) +
        " toBeLessThan " + fmt(n));
    },
    /*
     * Numeric greater-than-or-equal.
     * @param {number} n - Bound.
     * @returns {void} Throws on mismatch.
     */
    toBeGreaterThanOrEqual: function (n) {
      arity("toBeGreaterThanOrEqual", arguments.length, 1);
      reqNum("toBeGreaterThanOrEqual", "n", n);
      if (typeof actual !== "number") {
        throw new Error("toBeGreaterThanOrEqual: actual must be a number," +
          " got " + jsKind(actual));
      }
      check(actual >= n, "expected " + fmt(actual) +
        " toBeGreaterThanOrEqual " + fmt(n));
    },
    /*
     * Numeric less-than-or-equal.
     * @param {number} n - Bound.
     * @returns {void} Throws on mismatch.
     */
    toBeLessThanOrEqual: function (n) {
      arity("toBeLessThanOrEqual", arguments.length, 1);
      reqNum("toBeLessThanOrEqual", "n", n);
      if (typeof actual !== "number") {
        throw new Error("toBeLessThanOrEqual: actual must be a number," +
          " got " + jsKind(actual));
      }
      check(actual <= n, "expected " + fmt(actual) +
        " toBeLessThanOrEqual " + fmt(n));
    },
    /*
     * Float proximity (|diff| below half the last-place at precision).
     * @param {number} expected - Expected value.
     * @param {number} [precision] - Decimal places (default 2).
     * @returns {void} Throws on mismatch.
     */
    toBeCloseTo: function (expected, precision) {
      arity("toBeCloseTo", arguments.length, 1);
      reqNum("toBeCloseTo", "expected", expected);
      if (precision === undefined) precision = 2;
      reqNum("toBeCloseTo", "precision", precision);
      if (typeof actual !== "number") {
        throw new Error("toBeCloseTo: actual must be a number, got " +
          jsKind(actual));
      }
      check(Math.abs(actual - expected) < Math.pow(10, -precision) / 2,
        "expected " + fmt(actual) + " toBeCloseTo " + fmt(expected));
    }
  };
  Object.defineProperty(self, "not", {
    /*
     * Negated expectation.
     * @returns {Expectation} Flipped matcher set.
     */
    get: function () { return makeExpect(actual, !negated); }
  });
  return self;
}

/*
 * Starts an expectation.
 * @param {any} actual - Value under test.
 * @returns {Expectation} The matcher set.
 */
function expect(actual) {
  arity("expect", arguments.length, 1);
  return makeExpect(actual, false);
}

// -- assert (Node-style, callable with properties) -----------------------------------

/*
 * Truthiness assertion.
 * @param {any} value - Value under test.
 * @param {string} [message] - Failure message override.
 * @returns {void} Throws when falsy.
 */
function assert(value, message) {
  arity("assert", arguments.length, 1);
  if (!value) throw new Error(message || "assert: expected truthy value," +
    " got " + fmt(value));
}

/*
 * Truthiness assertion (assert.ok alias).
 * @param {any} value - Value under test.
 * @param {string} [message] - Failure message override.
 * @returns {void} Throws when falsy.
 */
assert.ok = function (value, message) {
  if (arguments.length < 1) {
    throw new Error("assert.ok: expected at least 1 argument(s), got 0");
  }
  if (!value) throw new Error(message || "assert.ok: expected truthy" +
    " value, got " + fmt(value));
};

/*
 * Loose equality (== on purpose; use strictEqual otherwise).
 * @param {any} a - First value.
 * @param {any} b - Second value.
 * @param {string} [message] - Failure message override.
 * @returns {void} Throws on mismatch.
 */
assert.equal = function (a, b, message) {
  if (arguments.length < 2) {
    throw new Error("assert.equal: expected at least 2 argument(s)," +
      " got " + arguments.length);
  }
  // eslint-disable-next-line eqeqeq
  if (a != b) throw new Error(message || "assert.equal: expected " +
    fmt(a) + " == " + fmt(b));
};

/*
 * Identity (Object.is: NaN equals NaN, +0 differs from -0).
 * @param {any} a - First value.
 * @param {any} b - Second value.
 * @param {string} [message] - Failure message override.
 * @returns {void} Throws on mismatch.
 */
assert.strictEqual = function (a, b, message) {
  if (arguments.length < 2) {
    throw new Error("assert.strictEqual: expected at least 2" +
      " argument(s), got " + arguments.length);
  }
  if (!Object.is(a, b)) throw new Error(message ||
    "assert.strictEqual: expected " + fmt(a) + " toBe " + fmt(b));
};

/*
 * Structural equality (see deepEqual).
 * @param {any} a - First value.
 * @param {any} b - Second value.
 * @param {string} [message] - Failure message override.
 * @returns {void} Throws on mismatch.
 */
assert.deepEqual = function (a, b, message) {
  if (arguments.length < 2) {
    throw new Error("assert.deepEqual: expected at least 2" +
      " argument(s), got " + arguments.length);
  }
  if (!deepEqual(a, b)) throw new Error(message ||
    "assert.deepEqual: expected " + fmt(a) + " toEqual " + fmt(b));
};

/*
 * Throw assertion (expected is an optional message substring,
 * RegExp, or constructor).
 * @param {Function} fn - Function to probe.
 * @param {string|RegExp|Function} [expected] - Throw filter.
 * @param {string} [message] - Failure message override.
 * @returns {void} Throws on mismatch.
 */
assert.throws = function (fn, expected, message) {
  if (arguments.length < 1) {
    throw new Error("assert.throws: expected at least 1 argument(s)," +
      " got 0");
  }
  if (typeof fn !== "function") {
    throw new Error("assert.throws: type mismatch parameter: `fn`." +
      " Got `" + jsKind(fn) + "`, expected `function`");
  }
  var thrown = captureThrow(fn);
  if (thrown === null) {
    throw new Error(message || "assert.throws: expected function" +
      " to throw");
  }
  var detail = matchThrow(thrown, expected);
  if (detail !== null &&
      (typeof expected === "string" || expected instanceof RegExp ||
        typeof expected === "function")) {
    throw new Error(message || "assert.throws: " + detail);
  }
  if (detail !== null) throw new Error(detail);
};

/*
 * No-throw assertion.
 * @param {Function} fn - Function to probe.
 * @param {string} [message] - Failure message override.
 * @returns {void} Throws when fn throws.
 */
assert.doesNotThrow = function (fn, message) {
  if (arguments.length < 1) {
    throw new Error("assert.doesNotThrow: expected at least 1" +
      " argument(s), got 0");
  }
  if (typeof fn !== "function") {
    throw new Error("assert.doesNotThrow: type mismatch parameter: `fn`." +
      " Got `" + jsKind(fn) + "`, expected `function`");
  }
  var thrown = captureThrow(fn);
  if (thrown !== null) {
    throw new Error(message || "assert.doesNotThrow: unexpected throw " +
      fmt(thrown && thrown.message !== undefined ? thrown.message :
        thrown));
  }
};

/*
 * Unconditional failure.
 * @param {string} [message] - Failure message.
 * @returns {void} Always throws.
 */
assert.fail = function (message) {
  throw new Error(message || "assert.fail() called");
};

module.exports = {
  test: test,
  it: it,
  describe: describe,
  expect: expect,
  assert: assert,
  stats: stats
};
