import unittest, strutils, os

import carne
import carne/modules
import carne/std/markdown

registerStd("std/markdown", markdown.install)

proc mdProbe(call: string): string =
  ## "<ctor>|<first message line>" or "none" when nothing threw.
  runCode("""
    (() => { try { const m = require('std/markdown'); """ & call & """;
      return 'none'; } catch (e) {
      return e.constructor.name + '|' + String(e.message).split('\n')[0]; } })()""")

proc fixturesDir(): string =
  currentSourcePath.parentDir / "fixtures"

test "markdown toHtml heading with anchors":
  check runCode("require('std/markdown').toHtml('# hi')") ==
    "<h1 id=\"hi\"><a href=\"#hi\" class=\"anchor-link\">\u{1F517}</a>hi</h1>"

test "markdown toHtml heading without anchors":
  check runCode(
    "require('std/markdown').toHtml('# hi', {enableAnchors: false})") ==
    "<h1>hi</h1>"

test "markdown toHtml custom anchor icon":
  check runCode(
    "require('std/markdown').toHtml('# hi', {anchorIcon: '\u00A7'})") ==
    "<h1 id=\"hi\"><a href=\"#hi\" class=\"anchor-link\">\u00A7</a>hi</h1>"

test "markdown toHtml inline formatting":
  check runCode(
    "require('std/markdown').toHtml('**bold** *it* ~~s~~ `c`')") ==
    "<p><strong>bold</strong> <em>it</em> <del>s</del> <code>c</code></p>"

test "markdown toHtml links images autolinks":
  check runCode(
    "require('std/markdown').toHtml('[t](https://x.test \"cap\")')") ==
    "<p><a href=\"https://x.test\" title=\"cap\">t</a></p>"
  check runCode(
    "require('std/markdown').toHtml('![a](i.png)')") ==
    "<img src=\"i.png\" alt=\"a\" title=\"\" />"
  check runCode(
    "require('std/markdown').toHtml('see https://x.test/y')") ==
    "<p>see <a href=\"https://x.test/y\">https://x.test/y</a></p>"

test "markdown toHtml email autolinks opt in":
  check runCode("require('std/markdown').toHtml('<a@b.test>')") ==
    "<p><a@b.test></p>"
  check runCode(
    "require('std/markdown').toHtml('<a@b.test>', " &
    "{enableEmailAutolinks: true})") ==
    "<p><a href=\"mailto:a@b.test\">a@b.test</a></p>"

test "markdown toHtml raw html gating follows allowed":
  check runCode(
    "require('std/markdown').toHtml('<div>raw</div>')") ==
    "<p><div>raw</div></p>"
  check runCode(
    "require('std/markdown').toHtml('<div>raw</div>', " &
    "{allowed: ['div']})") == "<div>raw</div>"
  check runCode(
    "require('std/markdown').toHtml('<div>\\nhello\\n</div>')") ==
    "<p><div>\nhello\n</div></p>"
  check runCode(
    "require('std/markdown').toHtml('<div>\\nhello\\n</div>', " &
    "{allowed: ['div']})") == "<div>hello </div>"

test "markdown toHtml task lists and alerts":
  check runCode(
    "require('std/markdown').toHtml('- [x] done\\n- [ ] todo')") ==
    "<ul><li><input type=\"checkbox\" checked disabled>done</li>" &
    "<li><input type=\"checkbox\" disabled>todo</li></ul>"
  check runCode(
    "require('std/markdown').toHtml('> [!NOTE]\\n> hey')") ==
    "<div class=\"alert alert-info rounded-4\" role=\"alert\">" &
    "<div class=\"alert-content\">hey</div></div>"

test "markdown toHtml fenced code keeps language":
  check runCode(
    "require('std/markdown').toHtml('```nim\\nlet x = 1\\n```')") ==
    "<pre><code class=\"language-nim\">let x = 1</code></pre>"

test "markdown toHtml tables with footer and classes":
  check runCode(
    "require('std/markdown').toHtml('| a | b |\\n|---|---|\\n| 1 | 2 |')") ==
    "<table><thead><tr><th>a</th><th>b</th></tr></thead>" &
    "<tbody><tr><td>1</td><td>2</td></tr></tbody></table>"
  check runCode(
    "require('std/markdown').toHtml('| n | r |\\n|---|---|\\n| a | 1 |" &
    "\\n|---|---|\\n| t | 2 |')") ==
    "<table><thead><tr><th>n</th><th>r</th></tr></thead>" &
    "<tbody><tr><td>a</td><td>1</td></tr></tbody>" &
    "<tfoot><tr><td>t</td><td>2</td></tr></tfoot></table>"
  check runCode(
    "require('std/markdown').toHtml('| a |\\n|---|\\n| 1 |', " &
    "{htmlTableClasses: ['table']})") ==
    "<table class=\"table\"><thead><tr><th>a</th></tr></thead>" &
    "<tbody><tr><td>1</td></tr></tbody></table>"

test "markdown toHtml footnotes and showFootnotes":
  check runCode(
    "require('std/markdown').toHtml('hi[^1]\\n\\n[^1]: note')") ==
    "<p>hi<sup class=\"footnote-ref\"><a href=\"#fn-1\">1</a></sup></p>" &
    "<hr><div class=\"footnotes\"><div class=\"footnote\" id=\"fn-1\">" &
    "<sup>1</sup> note</div></div>"
  check runCode(
    "require('std/markdown').toHtml('hi[^1]\\n\\n[^1]: note', " &
    "{showFootnotes: false})") ==
    "<p>hi<sup class=\"footnote-ref\"><a href=\"#fn-1\">1</a></sup></p>"

test "markdown toHtml reference links":
  check runCode(
    "require('std/markdown').toHtml('[t][r]\\n\\n[r]: https://x.test')") ==
    "<p><a href=\"https://x.test\">t</a></p>"

test "markdown toHtml lazyload rewrites image src":
  check runCode(
    "require('std/markdown').toHtml('![a](i.png)', " &
    "{lazyloadImages: true})") ==
    "<img data-src=\"i.png\" alt=\"a\" title=\"\" />"

test "markdown toAst returns the node tree":
  check runCode(
    "JSON.stringify(require('std/markdown').toAst('# hi'))") ==
    "[{\"kind\":\"mdkHeading\",\"level\":1,\"textAnchor\":null," &
    "\"children\":{\"items\":[{\"kind\":\"mdkText\",\"text\":\"hi\"," &
    "\"children\":null,\"line\":1}]},\"line\":1}]"
  check runCode(
    "Array.isArray(require('std/markdown').toAst('# hi'))") == "true"

test "markdown frontMatter parses yaml block":
  check runCode(
    "JSON.stringify(require('std/markdown').frontMatter(" &
    "'---\\ntitle: t\\nn: 2\\n---\\n# hi'))") == "{\"title\":\"t\",\"n\":2}"
  check runCode(
    "JSON.stringify(require('std/markdown').frontMatter('# hi'))") == "{}"
  check runCode(
    "JSON.stringify(require('std/markdown').frontMatter(" &
    "'---\\ntitle: t\\n---\\n# hi', {parseYaml: false}))") == "{}"

test "markdown toc lists headings in order":
  check runCode(
    "JSON.stringify(require('std/markdown').toc('# a\\n## b\\n# c'))") ==
    "[{\"level\":1,\"anchor\":\"a\",\"title\":\"a\"}," &
    "{\"level\":2,\"anchor\":\"b\",\"title\":\"b\"}," &
    "{\"level\":1,\"anchor\":\"c\",\"title\":\"c\"}]"
  check runCode(
    "JSON.stringify(require('std/markdown').toc('# a\\n## b', " &
    "{enableAnchors: false}))") == "[]"

test "markdown title is the first heading":
  check runCode(
    "require('std/markdown').title('# hello\\n\\ntext')") == "hello"
  check runCode(
    "require('std/markdown').title('plain text')") == "Untitled document"

test "markdown components include files when enabled":
  check runCode(
    "require('std/markdown').toHtml('@include(\"md_card.html\")', " &
    "{componentBaseDir: '" & fixturesDir() & "'})") ==
    "<p>@include(\"md_card.html\")</p>"
  let withComponents = runCode(
    "require('std/markdown').toHtml('@include(\"md_card.html\")', " &
    "{enableComponents: true, componentBaseDir: '" & fixturesDir() & "'})")
  check withComponents.contains("Cards")
  check withComponents.contains("v1")
  check not withComponents.contains("$title")

test "markdown unknown options throw TypeError with fn prefix":
  check mdProbe("m.toHtml('# hi', {nope: 1})").startsWith(
    "TypeError|toHtml: unknown option \"nope\"")
  check mdProbe("m.toc('# hi', {nope: 1})").startsWith(
    "TypeError|toc: unknown option \"nope\"")

test "markdown option type mismatches throw TypeError with fn prefix":
  check mdProbe("m.toHtml('# hi', {allowTagsByType: 'everything'})")
    .startsWith(
      "TypeError|toHtml: options.allowTagsByType must be one of")
  check mdProbe("m.toHtml('# hi', {allowed: 'div'})").startsWith(
    "TypeError|toHtml: options.allowed must be an array of tag names")
  check mdProbe("m.toHtml('# hi', {allowed: ['notatag']})").startsWith(
    "TypeError|toHtml: unknown html tag in options.allowed")
  check mdProbe("m.toHtml('# hi', {enableAnchors: 'yes'})").startsWith(
    "TypeError|toHtml: options.enableAnchors must be a boolean")
  check mdProbe("m.toHtml('# hi', {htmlTableClasses: 'table'})").startsWith(
    "TypeError|toHtml: options.htmlTableClasses must be an array")
  check mdProbe("m.toHtml('# hi', {anchorIcon: 5})").startsWith(
    "TypeError|toHtml: options.anchorIcon must be a string")
  check mdProbe("m.toHtml('# hi', {parseYaml: 1})").startsWith(
    "TypeError|toHtml: options.parseYaml must be a boolean")

test "markdown arity and type mismatches are TypeErrors":
  check mdProbe("m.toHtml(5)").startsWith(
    "TypeError|type mismatch parameter:")
  check mdProbe("m.toHtml()").startsWith("TypeError|toHtml: expected")
  check mdProbe("m.toc()").startsWith("TypeError|toc: expected")

test "markdown allowTagsByType accepts all four values":
  for v in ["none", "inline", "block", "all"]:
    check mdProbe("m.toHtml('<b>x</b>', {allowTagsByType: '" & v & "'})") ==
      "none"

test "markdown valid calls do not throw":
  check mdProbe("m.toHtml('# hi')") == "none"
  check mdProbe("m.toAst('# hi')") == "none"
  check mdProbe("m.frontMatter('# hi')") == "none"
  check mdProbe("m.toc('# hi')") == "none"
  check mdProbe("m.title('# hi')") == "none"
