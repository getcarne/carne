# std/crypto expansion — DONE (all 39 tests pass via `clue test`)
Uses local `~/development/nimbase/ports/nimcypher` through `clue`
(`clue.lock` develop path, `clue build` / `clue test`), not nimble.

## Goal
Close `README.md` gap: `std/crypto: X25519 exchange, RSA/ECDSA, AES-GCM`.
Keep hex-string contract, sync-only, `verify -> bool`, `open/decrypt -> throw`.

## nimcypher@0.2.5 inventory (already pinned, no bump needed)
- `encrypt.nim`: `x25519KeyPair([secret])`, `sharedSecretHashed(secret, pub[, info])`
- `aes.nim`: `gcmSeal(text,key[,ad])`, `gcmOpen`, key 16/24/32B, nonce 12B, tag 16B
- `ecdsa.nim`: curves P256/P384/P521/Secp256k1, `generateEcKeyPair`,
  `ecdsaSign/Verify` (R||S), `ecdhHashedSecret`
- `rsa.nim`: `generateRsaKeyPair(bits=2048)`, PKCS1v15/PSS sign/verify,
  OAEP encrypt/decrypt, PKCS1v15 encrypt/decrypt
- No PEM/DER/JWK codec — carne serializes BigInts as fixed-width hex.

## API (all hex lowercase, case-insensitive in)
- `x25519.keypair([secretHex64]) -> {secret, public}` (64 hex each)
- `x25519.sharedKey(mySecretHex, theirPublicHex[, infoHex]) -> 64 hex`
  (HKDF-SHA256, never raw)
- `aes.gcmSeal(text, keyHex[, adHex]) -> {nonce, tag, cipher}`
  key 32/48/64 hex, nonce 24 hex, tag 32 hex
- `aes.gcmOpen({nonce,tag,cipher}, keyHex[, adHex]) -> text` (throws on tag fail)
- `ecdsa.keypair(curve) -> {privateKey, x, y, curve}`
  curve in `P-256,P-384,P-521,secp256k1`; x/y zero-padded to coordLen
- `ecdsa.sign(privateHex, text, curve) -> sigHex`
- `ecdsa.verify(xHex, yHex, text, sigHex, curve) -> bool`
- `ecdsa.sharedKey(privHex, xHex, yHex, curve[, infoHex]) -> 64 hex`
- `rsa.keypair([bits]) -> {n,e,d,p,q,dp,dq,qinv,k,bits}` hex + ints
  default 2048, allow 1024 only for tests (slow, blocks loop — document)
- `rsa.sign(privJson, text, hash, padding="pss"|"pkcs1v15") -> sigHex`
- `rsa.verify(pubJson, text, sigHex, hash, padding) -> bool`
- `rsa.encrypt(pubJson, text, hash) -> cipherHex` (OAEP)
- `rsa.decrypt(privJson, cipherHex, hash) -> text`
  hash in `SHA-256,SHA-384,SHA-512` (sign), `SHA-1,SHA-256` (OAEP)
  RSA keys pass as objects (not bare hex) until `exportClass` lands.

## Serialization
- `BigInt <-> fixed-width hex` via `bigints.toBytesBE/fromBytesBE`,
  pad to `k` (RSA) / `coordLen` (EC).
- RSA: carry full CRT params in keypair object so sign/decrypt
  reconstruct without re-factoring.
- ECDSA: `d` padded to orderLen, `x/y` to coordLen; validate with
  `ecValidatePublicKey`.

## Files
- `src/carne/std/crypto.nim`: new `do*` + `registerFn` per op,
  new `x25519Ns/aesNs/rsaNs/ecdsaNs`, wire into `module.ns`.
- `tests/test_crypto.nim`: KATs (AES-GCM NIST, ECDSA RFC6979,
  X25519 RFC7748 hashed, RSA roundtrip), tamper/wrong-key throws,
  malformed-hex/curve/hash/bits errors, update `Object.keys` test.
- `examples/crypto.js`: extend walkthrough.
- `README.md`: check off roadmap item, update `std/crypto` bullet.

## Test plan
- `nimble test` (full) + `carne run examples/crypto.js`
- Deterministic vectors where possible; RSA 1024 in tests for speed,
  2048 in example smoke only.

## Deferred
Streaming GCM/AEAD, JWK/PEM import, Secp256k1 hash agility,
hardware storage, async keygen.
