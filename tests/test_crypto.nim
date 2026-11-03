import unittest

import carne
import carne/modules
import carne/std/crypto

registerStd("std/crypto", crypto.install)

test "crypto hash known answers":
  check runCode(
    "require('std/crypto').hash.sha256hex('abc')") ==
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  check runCode(
    "require('std/crypto').hash.sha512hex('abc')") ==
    "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a" &
    "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
  check runCode(
    "require('std/crypto').hash.blake2bhex('abc')") ==
    "bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319"
  check runCode(
    "require('std/crypto').hash.hmacSha256hex('6b6579', 'The quick brown " &
    "fox jumps over the lazy dog')") ==
    "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"

test "crypto hash sizes":
  check runCode(
    "require('std/crypto').hash.blake2bhex('abc', 16).length") == "32"
  check runCode(
    "require('std/crypto').hash.blake2bhex('abc').length") == "64"
  expect CarneError:
    discard runCode("require('std/crypto').hash.blake2bhex('abc', 0)")
  expect CarneError:
    discard runCode("require('std/crypto').hash.blake2bhex('abc', 65)")

test "crypto aead seal/open roundtrip":
  check runCode(
    "const c = require('std/crypto').aead;" &
    "const k = '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';" &
    "c.open(c.seal('secret message', k), k)") == "secret message"

test "crypto aead tamper and wrong key throw":
  expect CarneError:
    discard runCode(
      "const c = require('std/crypto').aead;" &
      "const k = '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';" &
      "const e = c.seal('x', k); " &
      "e.cipher = (e.cipher.startsWith('ff') ? '00' : 'ff') + " &
      "e.cipher.slice(2); c.open(e, k)")
  expect CarneError:
    discard runCode(
      "const c = require('std/crypto').aead;" &
      "c.open(c.seal('x', '00'.repeat(32)), '11'.repeat(32))")
  expect CarneError:
    discard runCode("require('std/crypto').aead.seal('x', 'short')")

test "crypto sign deterministic seed roundtrip":
  check runCode(
    "const s = require('std/crypto').sign;" &
    "const kp = s.keypairFromSeed('000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f');" &
    "kp.publicKey") ==
    "f65333fa6303b6a23defd7de2af8aa461cb047ccbf12d4edd29ef3b1eba6706b"
  check runCode(
    "const s = require('std/crypto').sign;" &
    "const kp = s.keypairFromSeed('000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f');" &
    "const sig = s.sign(kp.secretKey, 'hello');" &
    "s.verify(kp.publicKey, 'hello', sig) + ',' + " &
    "s.verify(kp.publicKey, 'bye', sig)") == "true,false"

test "crypto sign keypair is random and well-formed":
  check runCode(
    "const s = require('std/crypto').sign;" &
    "const a = s.keypair(), b = s.keypair();" &
    "a.publicKey.length + ',' + a.secretKey.length + ',' + " &
    "(a.publicKey === b.publicKey)") == "64,128,false"
  expect CarneError:
    discard runCode("require('std/crypto').sign.sign('short', 'x')")

test "crypto password hash/verify roundtrip":
  check runCode(
    "const p = require('std/crypto').password;" &
    "const st = p.hash('s3cret');" &
    "p.verify('s3cret', st) + ',' + p.verify('wrong', st)") == "true,false"
  check runCode(
    "require('std/crypto').password.verify('x', 'garbage')") == "false"

test "crypto exposes exactly the four groups":
  check runCode(
    "Object.keys(require('std/crypto')).sort().join(',')") ==
    "aead,hash,password,sign"
