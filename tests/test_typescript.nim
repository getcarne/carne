import std/[os, strutils, unittest]

import carne
import carne/tslower
import carne/pkg/loader

proc tx(code: string): string =
  transpileTS(code, "t.ts").code

proc txr(code: string): TsLowered =
  transpileTS(code, "t.ts")

suite "ts transpile":
  test "smoke erasure":
    let r = txr("let x: Foo<Bar> = 1;\nlet y = 2;\n")
    check r.code == "let x" & " ".repeat(11) & "= 1;\nlet y = 2;\n"
    check r.lines == @[1, 2]

  test "annotations erase in place":
    for c in ["let x: number = 1;", "let v = x as string;",
        "let v = y satisfies P;", "let v = <string>x;", "let v = x!;",
        "function f<T>(x: T): T { return x; }",
        "class C extends Base<T> implements I { private x: number = 1; }",
        "abstract class C { m(): void {} }"]:
      let r = txr(c)
      check r.code.len == c.len
      check r.code.count('\n') == c.count('\n')
    check "number" notin tx("let x: number = 1;")
    check "as string" notin tx("let v = x as string;")
    check "satisfies" notin tx("let v = y satisfies P;")
    check "<string>" notin tx("let v = <string>x;")
    check "!" notin tx("let v = x!;")
    check "<T>" notin tx("function f<T>(x: T): T { return x; }")
    check "private" notin tx("class C { private x = 1; }")
    check "abstract" notin tx("abstract class C {}")
    check "private" notin tx("class C { constructor(private x) {} }")
    check "this.x = x" in tx("class C { constructor(private x) {} }")

  test "type-only declarations vanish":
    for c in ["type A = string;", "interface I { x: string; }",
        "declare const x: number;", "import type { A } from \"m\";",
        "export type { A };", "export interface I { x: string; }"]:
      check tx(c).strip().len == 0

  test "overloads keep the implementation":
    let o = tx("function f(x: string): void; function f(x: any) { return 1; }")
    check o.len == "function f(x: string): void; function f(x: any) { return 1; }".len
    check "function f(" in o
    check o.count("function") == 1
    check ": string" notin o
    check ": void" notin o
    check ": any" notin o

  test "enum lowers tsc-style":
    check tx("enum E { A, B = 2, C = \"x\" };") ==
      "var E;(function(E){\n" &
      "E[E[\"A\"]=0]=\"A\";\n" &
      "E[E[\"B\"]=2]=\"B\";\n" &
      "E[\"C\"]=\"x\";\n" &
      "})(E||(E={}));\n"

  test "namespace lowers to IIFE":
    check tx("namespace N { export const x: number = 1; }") ==
      "var N;(function(N){\n" &
      " ".repeat(8) & "const x" & " ".repeat(8) & " = 1; \n" &
      "N.x=x;\n" &
      "})(N=N||({}));\n"

  test "param props synthesize assignments":
    check tx("class C { constructor(private x: number) {} }") ==
      "class C { constructor(" & " ".repeat(8) & "x" & " ".repeat(8) &
      ") {\nthis.x = x;}" &
      " }"

  test "using and import-assign become const":
    check tx("using r = get();") == "const r = get();"
    check tx("import x = require(\"m\");") == "const  x = require(\"m\");"
    check tx("import x = A.B.C;") == "const  x = A.B.C;"

  test "export-eq becomes module.exports":
    check tx("export = foo;") == "module.exports = foo;"

  test "unsupported constructs raise with position":
    expect CarneError:
      discard tx("@dec class C {}")
    try:
      discard tx("function f(x: string): void;")
      check false
    except CarneError as e:
      check "t.ts:1" in e.msg
      check "lacks an implementation" in e.msg
    try:
      discard tx("line one\n@dec\nclass C {}")
      check false
    except CarneError as e:
      check "t.ts:2" in e.msg

suite "ts runtime":
  test "annotations and casts run":
    check runCode(tx("let x: number = 1; x + 1;")) == "2"
    check runCode(tx("function id<T>(x: T): T { return x; } id<number>(41) + 1;")) == "42"
    check runCode(tx("let v = {a: 1} as const; v.a + 1;")) == "2"
    check runCode(tx("let v: string | null = \"a\"; v! + \"b\";")) == "ab"
    check runCode(tx("let v = <string>\"a\"; v + \"b\";")) == "ab"
    check runCode(tx("let v = <string>(\"a\" + \"b\"); v;")) == "ab"
    check runCode(tx("let f = (x: string) => x + \"!\"; f(\"hi\");")) == "hi!"
    check runCode(tx("let f = (x: string): string => x + \"!\"; f(\"hi\");")) == "hi!"
    check runCode(tx("let f = async (x: string) => x + \"!\"; f(\"hi\");")) == "hi!"
    check runCode(tx("let f = () => 41; f() + 1;")) == "42"
    check runCode(tx("let g: any = null; let h = g?.(\"x\"); h == null;")) == "true"
    check runCode(tx("let v = 5 as number; v * 2;")) == "10"

  test "enums run with reverse mappings":
    check runCode(tx("enum E { A, B = 2, C }; [E.A, E.B, E.C, E[0], E[2], E[3]].join(\",\");")) ==
      "0,2,3,A,B,C"
    check runCode(tx("enum S { X = \"x\", Y = \"y\" }; S.X + S.Y;")) == "xy"
    check runCode(tx("const enum F { P, Q = 5 }; F.P + F.Q;")) == "5"
    check runCode(tx("enum C { A = 1 + 2, B = A * 2 }; C.A + C.B;")) == "9"
    check runCode(tx("enum N { A = \"a\" }; N[\"A\"];")) == "a"
    check runCode(tx("enum E { B = 1, A = `x${B}y` }; E.A;")) == "x1y"

  test "namespaces run":
    check runCode(tx("namespace N { export const x: number = 1; export function f(): number { return x + 1; } } N.f();")) == "2"
    check runCode(tx("namespace N { export const x = 1; } namespace N { export const y = N.x + 1; } N.y;")) == "2"
    check runCode(tx("namespace A.B { export const v = 42; } A.B.v;")) == "42"
    check runCode(tx("namespace N { const h = 7; export function g() { return h; } } N.g();")) == "7"
    check runCode(tx("namespace N { export { a }; const a = 3; } N.a;")) == "3"

  test "classes run":
    check runCode(tx("class C { constructor(private x: number) {} get() { return this.x; } } new C(41).get() + 1;")) == "42"
    check runCode(tx("class B { v = 1; } class C extends B { w: number = 2; } new C().v + new C().w;")) == "3"
    check runCode(tx("function f(x: string): void; function f(x: any) { return x + \"!\"; } f(\"hi\");")) == "hi!"
    check runCode(tx("abstract class A { abstract m(): number; } class C extends A { m() { return 7; } } new C().m();")) == "7"
    check runCode(tx("class C { static s = 5; m<T>(x: T): T { return x; } } C.s + new C().m<number>(1);")) == "6"

  test "module interop forms run":
    check runCode("(function(module) { " & tx("export = 40 + 2;") &
      " return module.exports; })({});") == "42"
    check runCode(tx("using r = 41; r + 1;")) == "42"
    check runCode(tx("const m = {v: 6}; import x = m; x.v * 7;")) == "42"

  test "catch and loops run":
    check runCode(tx("let y = 0; try { throw new Error(\"x\"); } catch (e: any) { y = 1; } y;")) == "1"
    check runCode(tx("let s = 0; for (let i: number = 0; i < 3; i++) s += i; s;")) == "3"
    check runCode(tx("function f(x: number) { return x * 2; } f(21);")) == "42"
    check runCode(tx("function g(this: object, x: number) { return x * 2; } g(21);")) == "42"

suite "ts run and stack traces":
  test "runCode transpiles .ts sources":
    initPkgLoaderLazy()
    check runCode("let x: number = 40; x + 2;", "t.ts") == "42"
    check runCode("enum E { A, B = 2 }; E.B;", "t.ts") == "2"

  test "throw site maps to the ts line":
    try:
      discard runCode("let x: number = 1;\nfunction boom(): never {\n  throw new Error(\"k\");\n}\nboom();\n", "t.ts")
      check false
    except CarneError as e:
      check "t.ts:3:" in e.msg
      check "boom" in e.msg

  test "generated code maps to the declaration line":
    try:
      discard runCode("enum E { A };\nnamespace N {\n  export function boom(): never {\n    throw new Error(\"n\");\n  }\n}\nN.boom();\n", "t.ts")
      check false
    except CarneError as e:
      check "t.ts:4:" in e.msg

  test "carne run executes .ts files":
    let dir = getTempDir() / "carne_ts_run"
    if dirExists(dir):
      removeDir(dir)
    createDir(dir)
    writeFile(dir / "main.ts",
      "import { v } from \"./lib\";\nconsole.log(v + 1);\n")
    writeFile(dir / "lib.ts",
      "export const v: number = 41;\n")
    # ESM import stays rejected (CommonJS only), even from TS.
    try:
      discard runFile(dir / "main.ts")
      check false
    except CarneError as e:
      check "ESM" in e.msg
    writeFile(dir / "main.ts",
      "const m = require(\"./lib\");\nconsole.log(m.v + 1);\n")
    writeFile(dir / "lib.ts",
      "const v: number = 41;\nexport = { v };\n")
    check runFile(dir / "main.ts") == ""
    removeDir(dir)

  test "require of .ts maps failures to the ts line":
    let dir = getTempDir() / "carne_ts_req"
    if dirExists(dir):
      removeDir(dir)
    createDir(dir)
    # Module-init throw: formatted precisely at the require site.
    writeFile(dir / "lib.ts",
      "const v: number = 41;\nif (v > 0) {\n  throw new Error(\"init-boom\");\n}\nexport = { v };\n")
    writeFile(dir / "main.js",
      "const m = require(\"./lib\");\nconsole.log(m.v);\n")
    try:
      discard runFile(dir / "main.js")
      check false
    except CarneError as e:
      check "lib.ts:3:" in e.msg
      check "init-boom" in e.msg
    # Delayed call into the module: the message propagates.
    writeFile(dir / "lib.ts",
      "function boom(n: number): never {\n  throw new Error(\"r\" + n);\n}\n\nexport = { boom };\n")
    writeFile(dir / "main.js",
      "const m = require(\"./lib\");\nm.boom(7);\n")
    try:
      discard runFile(dir / "main.js")
      check false
    except CarneError as e:
      check "r7" in e.msg
    removeDir(dir)

  test "parse errors carry path and line":
    try:
      discard runCode("let x: number = ;\n", "t.ts")
      check false
    except CarneError as e:
      check "t.ts" in e.msg
      check "1:" in e.msg
    # The path goes on its own line so the parser's source context
    # block (offending line, caret, diagnostic) stays intact.
    try:
      discard runCode("let v = <string>(a + );\n", "t.ts")
      check false
    except CarneError as e:
      let lines = e.msg.splitLines()
      check lines[0] == "t.ts:"
      check lines[^1].startsWith("Error (")

  test "namespace edge cases":
    # Type-only members vanish with their export keyword.
    check tx("namespace N { export interface I { x: string; } }").strip() ==
      "var N;(function(N){\n" & " ".repeat(35) & "\n})(N=N||({}));"
    # Nested namespaces and export lists.
    let n = tx("namespace A.B { export const x = 1; export { x as y }; }")
    check "A.B.y" notin n
    check runCode(n & "\nA.B.y;") == "1"
    # Empty enum and namespace bodies lower cleanly.
    check runCode(tx("enum E {} Object.keys(E).length;")) == "0"
    check runCode(tx("namespace N {} typeof N;")) == "object"
    # Comments around export-eq survive structurally.
    check runCode("(function(module) { " & tx("export /*c*/ = 40 + 2;") &
      " return module.exports; })({});") == "42"

  test "async errors map too":
    try:
      discard runCode("setTimeout(() => { throw new Error(\"timer-boom\"); }, 5);", "t.ts")
      check false
    except CarneError as e:
      check "t.ts:1:" in e.msg
      check "timer-boom" in e.msg
    try:
      discard runCode("(async () => { throw new Error(\"rej-boom\"); })();", "t.ts")
      check false
    except CarneError as e:
      check "rej-boom" in e.msg
