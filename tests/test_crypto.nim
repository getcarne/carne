import std/strutils
import unittest

import carne
import carne/modules
import carne/std/crypto

registerStd("std/crypto", crypto.install)

test "crypto hash known answers":
  check runCode(
    "require('std/crypto').hash.md5('abc')") ==
    "900150983cd24fb0d6963f7d28e17f72"
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
  check runCode(
    "const c = require('std/crypto').aead;" &
    "c.open(c.seal('', '00'.repeat(32)), '00'.repeat(32)).length") == "0"

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

test "crypto x25519 fixed vector and symmetry":
  check runCode(
    "require('std/crypto').x25519.keypair(" &
    "'000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f').public") ==
    "8f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f"
  check runCode(
    "const x = require('std/crypto').x25519;" &
    "const a = x.keypair(), b = x.keypair();" &
    "a.secret.length + ',' + a.public.length + ',' + " &
    "(x.sharedKey(a.secret, b.public) === x.sharedKey(b.secret, a.public))") ==
    "64,64,true"
  check runCode(
    "const x = require('std/crypto').x25519;" &
    "x.sharedKey(" &
    "'000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'," &
    "'8f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f')") ==
    "bb153242f6dfa9c624e73b4b5c5fcf8c2f1fdd2892cd019fc5bd6738d0517081"
  expect CarneError:
    discard runCode("require('std/crypto').x25519.keypair('short')")
  expect CarneError:
    discard runCode(
      "require('std/crypto').x25519.sharedKey('short', '00'.repeat(32))")

test "crypto aes-gcm fixed vector and roundtrip":
  check runCode(
    "const a = require('std/crypto').aes;" &
    "const e = a.seal('hello', '000102030405060708090a0b0c0d0e0f'," &
    "'000102030405060708090a0b', '');" &
    "e.tag + ',' + e.cipher") ==
    "892a5290e6a1cc5c447671d2fdb399f0,fb09cba209"
  check runCode(
    "const a = require('std/crypto').aes;" &
    "a.open(a.seal('hello', '000102030405060708090a0b0c0d0e0f'," &
    "'000102030405060708090a0b', ''), " &
    "'000102030405060708090a0b0c0d0e0f')") == "hello"
  check runCode(
    "const a = require('std/crypto').aes;" &
    "const e = a.seal('', '00'.repeat(16), '00'.repeat(12), '');" &
    "e.tag") == "58e2fccefa7e3061367f1d57a4e7455a"
  check runCode(
    "const a = require('std/crypto').aes;" &
    "a.open(a.seal('', '00'.repeat(16)), '00'.repeat(16)).length") == "0"
  check runCode(
    "const a = require('std/crypto').aes;" &
    "const k = '00'.repeat(24);" &
    "a.open(a.seal('roundtrip', k), k)") == "roundtrip"
  expect CarneError:
    discard runCode(
      "const a = require('std/crypto').aes;" &
      "const e = a.seal('x', '00'.repeat(16));" &
      "e.tag = 'ff' + e.tag.slice(2); a.open(e, '00'.repeat(16))")
  expect CarneError:
    discard runCode("require('std/crypto').aes.seal('x', 'short')")
  expect CarneError:
    discard runCode(
      "require('std/crypto').aes.seal('x', '00'.repeat(16), 'short')")

test "crypto ecdsa sign/verify per curve":
  for curve in ["P-256", "P-384", "P-521", "secp256k1"]:
    check runCode(
      "const e = require('std/crypto').ecdsa;" &
      "const kp = e.keypair('" & curve & "');" &
      "const sig = e.sign(kp.privateKey, 'hello', '" & curve & "');" &
      "e.verify(kp.x, kp.y, 'hello', sig, '" & curve & "') + ',' +" &
      " e.verify(kp.x, kp.y, 'bye', sig, '" & curve & "')") == "true,false"
  check runCode(
    "require('std/crypto').ecdsa.sign('" & "00".repeat(31) & "01', " &
    "'hello', 'P-256')") ==
    "fe485cf09056db3fec44540ce06a9abf8ac1498d5cae2fa5c36519afaff98487" &
    "448fcd767dfeee08940317d1e01d4296b9bd323629771d118ea10674dbb47755"
  check runCode(
    "const e = require('std/crypto').ecdsa;" &
    "const a = e.keypair('P-256'), b = e.keypair('P-256');" &
    "(e.sharedKey(a.privateKey, b.x, b.y, 'P-256') === " &
    "e.sharedKey(b.privateKey, a.x, a.y, 'P-256'))") == "true"
  expect CarneError:
    discard runCode("require('std/crypto').ecdsa.keypair('bad-curve')")
  expect CarneError:
    discard runCode(
      "require('std/crypto').ecdsa.sign('short', 'x', 'P-256')")

test "crypto rsa 1024 roundtrip":
  check runCode(
    "const r = require('std/crypto').rsa;" &
    "const kp = r.keypair(1024);" &
    "const sig = r.sign(kp.privateKey, 'hello', 'SHA-256');" &
    "r.verify(kp.publicKey, 'hello', sig, 'SHA-256') + ',' +" &
    " r.verify(kp.publicKey, 'bye', sig, 'SHA-256')") == "true,false"
  check runCode(
    "const r = require('std/crypto').rsa;" &
    "const kp = r.keypair(1024);" &
    "r.decrypt(kp.privateKey, r.encrypt(kp.publicKey, 'hello', " &
    "'SHA-256'), 'SHA-256')") == "hello"
  check runCode(
    "const r = require('std/crypto').rsa;" &
    "const kp = r.keypair(1024);" &
    "kp.privateKey.k + ',' + kp.publicKey.k") == "128,128"
  expect CarneError:
    discard runCode("require('std/crypto').rsa.keypair(512)")
  expect CarneError:
    discard runCode(
      "const r = require('std/crypto').rsa;" &
      "const kp = r.keypair(1024);" &
      "r.sign(kp.privateKey, 'x', 'SHA-1')")

test "crypto exposes all eight groups":
  check runCode(
    "Object.keys(require('std/crypto')).sort().join(',')") ==
    "aead,aes,ecdsa,hash,password,rsa,sign,x25519"
