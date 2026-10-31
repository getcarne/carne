const { test, describe, it, expect, assert } = require("std/test");

test("adds", () => {
  expect(1 + 1).toBe(2);
});

describe("strings", () => {
  it("concatenates", () => {
    expect("a" + "b").toBe("ab");
  });

  it("matches", () => {
    expect("hello world").toMatch(/world/);
  });
});

test("assert style", () => {
  assert.ok(true);
  assert.strictEqual(2 * 3, 6);
  assert.deepEqual({ a: [1, 2] }, { a: [1, 2] });
  assert.throws(() => {
    throw new Error("boom");
  }, "boom");
});

test("async works", async () => {
  const v = await new Promise((resolve) => {
    setTimeout(() => resolve(41), 5);
  });
  expect(v + 1).toBe(42);
});
