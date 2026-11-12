import unittest

import carne
import carne/modules
import carne/std/vcard

registerStd("std/vcard", vcard.install)

const sampleCard =
  "\"BEGIN:VCARD\\r\\nVERSION:4.0\\r\\nFN:Ada Lovelace\\r\\n" &
  "N:Lovelace;Ada;;;\\r\\nEMAIL;TYPE=work:ada@example.com\\r\\n" &
  "TEL;TYPE=voice:+1000\\r\\nEND:VCARD\\r\\n\""

test "vcard parse contact":
  check runCode(
    "require('std/vcard').parse(" & sampleCard & ")[0].fn") ==
    "Ada Lovelace"
  check runCode(
    "require('std/vcard').parse(" & sampleCard & ")[0].n.family") ==
    "Lovelace"
  check runCode(
    "require('std/vcard').parse(" & sampleCard & ")[0].emails[0].value") ==
    "ada@example.com"
  check runCode(
    "JSON.stringify(require('std/vcard').parse(" & sampleCard &
    ")[0].tels[0].types)") == """["voice"]"""

test "vcard parse error throws":
  expect CarneError:
    discard runCode("require('std/vcard').parse('not a vcard')")

test "vcard stringify roundtrip":
  check runCode(
    "require('std/vcard').stringify(require('std/vcard').parse(" &
    sampleCard & ")[0]).includes('FN:Ada Lovelace')") == "true"
  check runCode(
    "require('std/vcard').parse(require('std/vcard').stringify(" &
    "require('std/vcard').parse(" & sampleCard & ")[0]))[0].fn") ==
    "Ada Lovelace"

test "vcard stringify rejects non-objects":
  expect CarneError:
    discard runCode("require('std/vcard').stringify(42)")
