# Carne std/crypto: hashing, AEAD sealing, signatures, passwords,
# X25519, AES-GCM, ECDSA and RSA.
#
#   const crypto = require("std/crypto");
#   crypto.hash.sha256hex("abc")     -> hex digest (lowercase)
#   crypto.hash.md5("abc")           -> hex digest (lowercase, legacy interop only)
#   crypto.aead.seal(text, keyHex)   -> {nonce, mac, cipher} (hex)
#   crypto.aead.open(env, keyHex)    -> text (throws on MAC failure)
#   crypto.sign.keypair()            -> {publicKey, secretKey} hex
#   crypto.sign.sign(secretHex, msg) -> sigHex (ed25519)
#   crypto.sign.verify(pubHex, msg, sigHex) -> bool
#   crypto.password.hash(pw)         -> "hex(salt):hex(hash)" (argon2id)
#   crypto.password.verify(pw, stored) -> bool
#   crypto.x25519.keypair([secretHex]) -> {secret, public} hex
#   crypto.x25519.sharedKey(mySecretHex, theirPublicHex[, infoHex]) -> hex
#   crypto.aes.seal(text, keyHex[, nonceHex[, adHex]]) -> {nonce, tag, cipher}
#   crypto.aes.open({nonce, tag, cipher}, keyHex[, adHex]) -> text
#   crypto.ecdsa.keypair(curve)      -> {privateKey, x, y, curve}
#   crypto.ecdsa.sign(privHex, text, curve) -> sigHex (R||S)
#   crypto.ecdsa.verify(xHex, yHex, text, sigHex, curve) -> bool
#   crypto.ecdsa.sharedKey(privHex, xHex, yHex, curve[, infoHex]) -> hex
#   crypto.rsa.keypair([bits])       -> {privateKey, publicKey}
#   crypto.rsa.sign(privObj, text, hash[, padding]) -> sigHex
#   crypto.rsa.verify(pubObj, text, sigHex, hash[, padding]) -> bool
#   crypto.rsa.encrypt(pubObj, text, hash) -> cipherHex (OAEP)
#   crypto.rsa.decrypt(privObj, cipherHex, hash) -> text
#
# All binary values cross the boundary as lowercase hex strings.
# Hex input is case-insensitive. Keys/sigs/envelopes are length-checked
# with explicit errors. `open`/`decrypt` throw on failure; `verify`
# returns false on mismatch instead (verification is not exceptional),
# and `password.verify` returns false on malformed stored strings.
#
# Like std/sql, the groups are built as setup with define-only
# `ctx.registerFn` callbacks sharing one helper per operation.

import std/strutils

import javascriptcore

import pkg/nimcypher/[hash, encrypt, sign, password, utils, aes, ecdsa, rsa]
import pkg/nimcypher/algos/bigint_ext

import ../bridge

proc hexOut(data: openArray[byte]): string =
  ## nimcypher hex is uppercase; the JS side is lowercase.
  toHex(data).toLowerAscii()

proc parseBytes(s, field: string): seq[byte] =
  ## Variable-length hex -> bytes. Raises ValueError with context.
  ## Callers prefix the function name.
  if s.len == 0 or s.len mod 2 != 0:
    raise newException(ValueError, field & " must be non-empty even-length hex")
  result = newSeq[byte](s.len div 2)
  try:
    for i in 0 ..< result.len:
      result[i] = byte(parseHexInt(s[i * 2 .. i * 2 + 1]))
  except ValueError:
    raise newException(ValueError, field & " is not valid hex")

proc parseKey32(s: string): Key32 =
  if s.len != 64:
    raise newException(ValueError, "key must be 64 hex chars (32 bytes)")
  try:
    fromHex[32, uint8](s)
  except ValueError:
    raise newException(ValueError, "key is not valid hex")

proc cryptoErr(ctx: JSContextRef; docBlock, name, detail: string;
    exception: ptr JSValueRef) =
  ## Domain-error throw with the JSDoc block first (CLI info).
  var msg = ""
  if docBlock.len > 0:
    msg = docBlock & "\n"
  throwError(ctx, msg & name & ": " & detail, exception)

# -- hash ------------------------------------------------------------

proc doSha256(ctx: JSContextRef; text: string; docBlock: string;
    exception: ptr JSValueRef): JSValueRef =
  const name = "hash.sha256hex"
  try:
    toJS(ctx, hexOut(sha256(text)))
  except CatchableError as e:
    cryptoErr(ctx, docBlock, name, e.msg, exception)
    nil

proc doMd5(ctx: JSContextRef; text: string; docBlock: string;
    exception: ptr JSValueRef): JSValueRef =
  const name = "hash.md5"
  try:
    toJS(ctx, md5Hex(text).toLowerAscii())
  except CatchableError as e:
    cryptoErr(ctx, docBlock, name, e.msg, exception)
    nil

proc doSha384(ctx: JSContextRef; text: string; docBlock: string;
    exception: ptr JSValueRef): JSValueRef =
  const name = "hash.sha384hex"
  try:
    toJS(ctx, hexOut(sha384(text)))
  except CatchableError as e:
    cryptoErr(ctx, docBlock, name, e.msg, exception)
    nil

proc doSha512(ctx: JSContextRef; text: string; docBlock: string;
    exception: ptr JSValueRef): JSValueRef =
  const name = "hash.sha512hex"
  try:
    toJS(ctx, hexOut(sha512(text)))
  except CatchableError as e:
    cryptoErr(ctx, docBlock, name, e.msg, exception)
    nil

proc doBlake2b(ctx: JSContextRef; text: string; size: int;
    docBlock: string; exception: ptr JSValueRef): JSValueRef =
  const name = "hash.blake2bhex"
  if size < 1 or size > 64:
    cryptoErr(ctx, docBlock, name, "size must be 1..64", exception)
    return nil
  try:
    toJS(ctx, blakeHex(text, size).toLowerAscii())
  except CatchableError as e:
    cryptoErr(ctx, docBlock, name, e.msg, exception)
    nil

proc doHmacSha256(ctx: JSContextRef; keyHex, text: string;
    docBlock: string; exception: ptr JSValueRef): JSValueRef =
  const name = "hash.hmacSha256hex"
  try:
    let key = parseBytes(keyHex, "key")
    toJS(ctx, hexOut(sha256Hmac(key, toBytes(text))))
  except CatchableError as e:
    cryptoErr(ctx, docBlock, name, e.msg, exception)
    nil

# -- aead (XChaCha20-Poly1305) ----------------------------------------

proc doSeal(ctx: JSContextRef; text, keyHex: string; docBlock: string;
    exception: ptr JSValueRef): JSValueRef =
  const name = "aead.seal"
  try:
    let msg = seal(text, parseKey32(keyHex))
    let obj = newObject(ctx)
    if not setPropChecked(ctx, obj, "nonce", toJS(ctx, hexOut(msg.nonce)),
        name, exception):
      cryptoErr(ctx, docBlock, name, "could not convert result to JS",
        exception)
      return nil
    if not setPropChecked(ctx, obj, "mac", toJS(ctx, hexOut(msg.mac)),
        name, exception):
      cryptoErr(ctx, docBlock, name, "could not convert result to JS",
        exception)
      return nil
    if not setPropChecked(ctx, obj, "cipher",
        toJS(ctx, hexOut(msg.cipherText)), name, exception):
      cryptoErr(ctx, docBlock, name, "could not convert result to JS",
        exception)
      return nil
    obj
  except CatchableError as e:
    cryptoErr(ctx, docBlock, name, e.msg, exception)
    nil

proc doOpen(ctx: JSContextRef; envObj: JSValueRef; keyHex: string;
    docBlock: string; exception: ptr JSValueRef): JSValueRef =
  const name = "aead.open"
  try:
    var err = ""
    var nonceHex, macHex, cipherHex: string
    for (field, dst) in [("nonce", addr nonceHex), ("mac", addr macHex),
        ("cipher", addr cipherHex)]:
      let f = getField(ctx, envObj, field, err)
      if err != "":
        raise newException(ValueError, "envelope." & field & " " & err)
      if f.kind != nvkString:
        raise newException(ValueError, "envelope needs hex \"" & field & "\"")
      dst[] = f.s
    if nonceHex.len != 48:
      raise newException(ValueError,
        "envelope.nonce must be 48 hex chars (24 bytes)")
    if macHex.len != 32:
      raise newException(ValueError,
        "envelope.mac must be 32 hex chars (16 bytes)")
    let msg = SealedMessage(nonce: fromHex[24, uint8](nonceHex),
      mac: fromHex[16, uint8](macHex),
      cipherText: if cipherHex.len == 0: @[]
        else: parseBytes(cipherHex, "envelope.cipher"))
    toJS(ctx, toString(unseal(msg, parseKey32(keyHex))))
  except CatchableError as e:
    cryptoErr(ctx, docBlock, name, e.msg, exception)
    nil

# -- sign (ed25519) ---------------------------------------------------

proc doKeypair(ctx: JSContextRef; docBlock: string;
    exception: ptr JSValueRef): JSValueRef =
  const name = "sign.keypair"
  try:
    let kp = generateSigningKeyPair()
    let obj = newObject(ctx)
    if not setPropChecked(ctx, obj, "publicKey",
        toJS(ctx, publicKeyToHex(kp.publicKey).toLowerAscii()), name,
        exception):
      cryptoErr(ctx, docBlock, name, "could not convert result to JS",
        exception)
      return nil
    if not setPropChecked(ctx, obj, "secretKey",
        toJS(ctx, secretKeyToHex(kp.secretKey).toLowerAscii()), name,
        exception):
      cryptoErr(ctx, docBlock, name, "could not convert result to JS",
        exception)
      return nil
    obj
  except CatchableError as e:
    cryptoErr(ctx, docBlock, name, e.msg, exception)
    nil

proc doKeypairFromSeed(ctx: JSContextRef; seedHex: string;
    docBlock: string; exception: ptr JSValueRef): JSValueRef =
  const name = "sign.keypairFromSeed"
  try:
    if seedHex.len != 64:
      raise newException(ValueError, "seed must be 64 hex chars (32 bytes)")
    let kp = generateSigningKeyPair(fromHex[32, uint8](seedHex))
    let obj = newObject(ctx)
    if not setPropChecked(ctx, obj, "publicKey",
        toJS(ctx, publicKeyToHex(kp.publicKey).toLowerAscii()), name,
        exception):
      cryptoErr(ctx, docBlock, name, "could not convert result to JS",
        exception)
      return nil
    if not setPropChecked(ctx, obj, "secretKey",
        toJS(ctx, secretKeyToHex(kp.secretKey).toLowerAscii()), name,
        exception):
      cryptoErr(ctx, docBlock, name, "could not convert result to JS",
        exception)
      return nil
    obj
  except CatchableError as e:
    cryptoErr(ctx, docBlock, name, e.msg, exception)
    nil

proc doSign(ctx: JSContextRef; secretHex, text: string;
    docBlock: string; exception: ptr JSValueRef): JSValueRef =
  const name = "sign.sign"
  try:
    let sig = sign(secretKeyFromHex(secretHex), text)
    toJS(ctx, signatureToHex(sig).toLowerAscii())
  except CatchableError as e:
    cryptoErr(ctx, docBlock, name, e.msg, exception)
    nil

proc doVerify(ctx: JSContextRef; publicHex, text, sigHex: string;
    docBlock: string; exception: ptr JSValueRef): JSValueRef =
  const name = "sign.verify"
  try:
    toJS(ctx, verify(publicKeyFromHex(publicHex), text,
      signatureFromHex(sigHex)))
  except CatchableError as e:
    cryptoErr(ctx, docBlock, name, e.msg, exception)
    nil

# -- password (argon2id) -----------------------------------------------

proc doPwHash(ctx: JSContextRef; pw: string; docBlock: string;
    exception: ptr JSValueRef): JSValueRef =
  const name = "password.hash"
  try:
    # nimcypher hex is uppercase; the JS side is lowercase (verify
    # accepts both, so stored strings stay interoperable).
    toJS(ctx, hashPassword(pw).toLowerAscii())
  except CatchableError as e:
    cryptoErr(ctx, docBlock, name, e.msg, exception)
    nil

proc doPwVerify(ctx: JSContextRef; pw, stored: string;
    docBlock: string; exception: ptr JSValueRef): JSValueRef =
  const name = "password.verify"
  try:
    toJS(ctx, verifyPassword(pw, stored))
  except CatchableError as e:
    cryptoErr(ctx, docBlock, name, e.msg, exception)
    nil

# -- x25519 ------------------------------------------------------------

proc doXKeypair(ctx: JSContextRef; secretHex: string; docBlock: string;
    exception: ptr JSValueRef): JSValueRef =
  const name = "x25519.keypair"
  try:
    var sec, pub: Key32
    if secretHex.len == 0:
      (sec, pub) = x25519KeyPair()
    else:
      if secretHex.len != 64:
        raise newException(ValueError,
          "secret must be 64 hex chars (32 bytes)")
      (sec, pub) = x25519KeyPair(fromHex[32, uint8](secretHex))
    let obj = newObject(ctx)
    if not setPropChecked(ctx, obj, "secret", toJS(ctx, hexOut(sec)),
        name, exception):
      cryptoErr(ctx, docBlock, name, "could not convert result to JS",
        exception)
      return nil
    if not setPropChecked(ctx, obj, "public", toJS(ctx, hexOut(pub)),
        name, exception):
      cryptoErr(ctx, docBlock, name, "could not convert result to JS",
        exception)
      return nil
    obj
  except CatchableError as e:
    cryptoErr(ctx, docBlock, name, e.msg, exception)
    nil

proc doXShared(ctx: JSContextRef; mySecretHex, theirPublicHex,
    infoHex: string; docBlock: string;
    exception: ptr JSValueRef): JSValueRef =
  const name = "x25519.sharedKey"
  try:
    if mySecretHex.len != 64:
      raise newException(ValueError,
        "secret must be 64 hex chars (32 bytes)")
    if theirPublicHex.len != 64:
      raise newException(ValueError,
        "public must be 64 hex chars (32 bytes)")
    let sec = fromHex[32, uint8](mySecretHex)
    let pub = fromHex[32, uint8](theirPublicHex)
    var info: seq[byte] = @[]
    if infoHex.len > 0:
      info = parseBytes(infoHex, "info")
    let shared = sharedSecretHashed(sec, pub, info)
    toJS(ctx, hexOut(shared.data))
  except CatchableError as e:
    cryptoErr(ctx, docBlock, name, e.msg, exception)
    nil

# -- aes-gcm -----------------------------------------------------------

proc parseAesKey(s: string): seq[byte] =
  ## 16/24/32-byte key from hex. Raises ValueError.
  if s.len notin [32, 48, 64]:
    raise newException(ValueError,
      "key must be 32, 48 or 64 hex chars (16, 24 or 32 bytes)")
  parseBytes(s, "key")

proc parseGcmNonce(s: string): array[12, uint8] =
  if s.len != 24:
    raise newException(ValueError,
      "nonce must be 24 hex chars (12 bytes)")
  try:
    fromHex[12, uint8](s)
  except ValueError:
    raise newException(ValueError, "nonce is not valid hex")

proc parseGcmTag(s: string): array[16, uint8] =
  if s.len != 32:
    raise newException(ValueError,
      "tag must be 32 hex chars (16 bytes)")
  try:
    fromHex[16, uint8](s)
  except ValueError:
    raise newException(ValueError, "tag is not valid hex")

proc doAesSeal(ctx: JSContextRef; text, keyHex, nonceHex,
    adHex: string; docBlock: string;
    exception: ptr JSValueRef): JSValueRef =
  const name = "aes.seal"
  try:
    let key = parseAesKey(keyHex)
    var ad: seq[byte] = @[]
    if adHex.len > 0:
      ad = parseBytes(adHex, "ad")
    var sealed: GcmSealed
    if nonceHex.len == 0:
      sealed = gcmSeal(text, key, ad)
    else:
      let nonce = parseGcmNonce(nonceHex)
      let (ct, tag) = aesGcmEncrypt(key, nonce, toBytes(text), ad)
      sealed = GcmSealed(nonce: nonce, tag: tag, cipherText: ct)
    let obj = newObject(ctx)
    if not setPropChecked(ctx, obj, "nonce", toJS(ctx, hexOut(sealed.nonce)),
        name, exception):
      cryptoErr(ctx, docBlock, name, "could not convert result to JS",
        exception)
      return nil
    if not setPropChecked(ctx, obj, "tag", toJS(ctx, hexOut(sealed.tag)),
        name, exception):
      cryptoErr(ctx, docBlock, name, "could not convert result to JS",
        exception)
      return nil
    if not setPropChecked(ctx, obj, "cipher",
        toJS(ctx, hexOut(sealed.cipherText)), name, exception):
      cryptoErr(ctx, docBlock, name, "could not convert result to JS",
        exception)
      return nil
    obj
  except CatchableError as e:
    cryptoErr(ctx, docBlock, name, e.msg, exception)
    nil

proc doAesOpen(ctx: JSContextRef; envObj: JSValueRef; keyHex,
    adHex: string; docBlock: string;
    exception: ptr JSValueRef): JSValueRef =
  const name = "aes.open"
  try:
    let key = parseAesKey(keyHex)
    var ad: seq[byte] = @[]
    if adHex.len > 0:
      ad = parseBytes(adHex, "ad")
    var err = ""
    var nonceHex, tagHex, cipherHex: string
    for (field, dst) in [("nonce", addr nonceHex), ("tag", addr tagHex),
        ("cipher", addr cipherHex)]:
      let f = getField(ctx, envObj, field, err)
      if err != "":
        raise newException(ValueError, "envelope." & field & " " & err)
      if f.kind != nvkString:
        raise newException(ValueError, "envelope needs hex \"" & field & "\"")
      dst[] = f.s
    let msg = GcmSealed(nonce: parseGcmNonce(nonceHex),
      tag: parseGcmTag(tagHex),
      cipherText: if cipherHex.len == 0: @[]
        else: parseBytes(cipherHex, "envelope.cipher"))
    toJS(ctx, gcmOpenStr(msg, key, ad))
  except CatchableError as e:
    cryptoErr(ctx, docBlock, name, e.msg, exception)
    nil

# -- ecdsa / ecdh ------------------------------------------------------

proc parseCurve(s: string): EcCurve =
  case s
  of "P-256": P256
  of "P-384": P384
  of "P-521": P521
  of "secp256k1": Secp256k1
  else:
    raise newException(ValueError,
      "curve must be one of P-256, P-384, P-521, secp256k1")

proc coordLenFor(c: EcCurve): int =
  case c
  of P256: 32
  of P384: 48
  of P521: 66
  of Secp256k1: 32

proc bigFromHex(s, field: string): auto =
  ## Hex -> BigInt. Raises ValueError.
  if s.len == 0 or s.len mod 2 != 0:
    raise newException(ValueError,
      field & " must be non-empty even-length hex")
  parseBytes(s, field).fromBytesBE()

proc bigToHexFixed(x: auto; width: int): string =
  hexOut(x.toBytesBE(width))

proc doEcKeypair(ctx: JSContextRef; curveName: string;
    docBlock: string; exception: ptr JSValueRef): JSValueRef =
  const name = "ecdsa.keypair"
  try:
    let curve = parseCurve(curveName)
    let (priv, pub) = generateEcKeyPair(curve)
    let n = coordLenFor(curve)
    let obj = newObject(ctx)
    if not setPropChecked(ctx, obj, "privateKey",
        toJS(ctx, bigToHexFixed(priv.d, n)), name, exception):
      cryptoErr(ctx, docBlock, name, "could not convert result to JS",
        exception)
      return nil
    if not setPropChecked(ctx, obj, "x",
        toJS(ctx, bigToHexFixed(pub.x, n)), name, exception):
      cryptoErr(ctx, docBlock, name, "could not convert result to JS",
        exception)
      return nil
    if not setPropChecked(ctx, obj, "y",
        toJS(ctx, bigToHexFixed(pub.y, n)), name, exception):
      cryptoErr(ctx, docBlock, name, "could not convert result to JS",
        exception)
      return nil
    if not setPropChecked(ctx, obj, "curve", toJS(ctx, curveName),
        name, exception):
      cryptoErr(ctx, docBlock, name, "could not convert result to JS",
        exception)
      return nil
    obj
  except CatchableError as e:
    cryptoErr(ctx, docBlock, name, e.msg, exception)
    nil

proc doEcSign(ctx: JSContextRef; privHex, text, curveName: string;
    docBlock: string; exception: ptr JSValueRef): JSValueRef =
  const name = "ecdsa.sign"
  try:
    let curve = parseCurve(curveName)
    let n = coordLenFor(curve)
    if privHex.len != n * 2:
      raise newException(ValueError, "privateKey must be " & $(n * 2) &
        " hex chars (" & $n & " bytes for " & curveName & ")")
    let priv = EcPrivateKey(curve: curve,
      d: bigFromHex(privHex, "privateKey"))
    toJS(ctx, hexOut(ecdsaSign(priv, text)))
  except CatchableError as e:
    cryptoErr(ctx, docBlock, name, e.msg, exception)
    nil

proc doEcVerify(ctx: JSContextRef; xHex, yHex, text, sigHex,
    curveName: string; docBlock: string;
    exception: ptr JSValueRef): JSValueRef =
  const name = "ecdsa.verify"
  try:
    let curve = parseCurve(curveName)
    let n = coordLenFor(curve)
    if xHex.len != n * 2:
      raise newException(ValueError, "x must be " & $(n * 2) &
        " hex chars (" & $n & " bytes for " & curveName & ")")
    if yHex.len != n * 2:
      raise newException(ValueError, "y must be " & $(n * 2) &
        " hex chars (" & $n & " bytes for " & curveName & ")")
    if sigHex.len != n * 4:
      raise newException(ValueError, "signature must be " & $(n * 4) &
        " hex chars (R||S for " & curveName & ")")
    let pub = EcPublicKey(curve: curve, x: bigFromHex(xHex, "x"),
      y: bigFromHex(yHex, "y"))
    toJS(ctx, ecdsaVerify(pub, text, parseBytes(sigHex, "signature")))
  except CatchableError as e:
    cryptoErr(ctx, docBlock, name, e.msg, exception)
    nil

proc doEcShared(ctx: JSContextRef; privHex, xHex, yHex, curveName,
    infoHex: string; docBlock: string;
    exception: ptr JSValueRef): JSValueRef =
  const name = "ecdsa.sharedKey"
  try:
    let curve = parseCurve(curveName)
    let n = coordLenFor(curve)
    if privHex.len != n * 2:
      raise newException(ValueError, "privateKey must be " & $(n * 2) &
        " hex chars (" & $n & " bytes for " & curveName & ")")
    if xHex.len != n * 2 or yHex.len != n * 2:
      raise newException(ValueError, "peer x/y must each be " & $(n * 2) &
        " hex chars for " & curveName)
    let priv = EcPrivateKey(curve: curve,
      d: bigFromHex(privHex, "privateKey"))
    let peer = EcPublicKey(curve: curve, x: bigFromHex(xHex, "x"),
      y: bigFromHex(yHex, "y"))
    var info: seq[byte] = @[]
    if infoHex.len > 0:
      info = parseBytes(infoHex, "info")
    toJS(ctx, hexOut(ecdhHashedSecret(priv, peer, info)))
  except CatchableError as e:
    cryptoErr(ctx, docBlock, name, e.msg, exception)
    nil

# -- rsa ---------------------------------------------------------------

proc parseRsaHash(s: string): RsaHash =
  case s
  of "SHA-256": rhSha256
  of "SHA-384": rhSha384
  of "SHA-512": rhSha512
  of "SHA-1": rhSha1
  else:
    raise newException(ValueError,
      "hash must be one of SHA-256, SHA-384, SHA-512, SHA-1 " &
      "(SHA-1 is OAEP-only)")

proc bigToHexTrimmed(x: auto): string =
  let b = x.toBytesBETrimmed()
  if b.len == 0:
    return "00"
  hexOut(b)

proc getStrHex(ctx: JSContextRef; obj: JSValueRef; key,
    what: string): string =
  var err = ""
  let f = getField(ctx, obj, key, err)
  if err != "":
    raise newException(ValueError, what & "." & key & " " & err)
  if f.kind != nvkString:
    raise newException(ValueError, what & "." & key & " must be hex")
  f.s

proc getIntField(ctx: JSContextRef; obj: JSValueRef; key,
    what: string): int =
  var err = ""
  let f = getField(ctx, obj, key, err)
  if err != "":
    raise newException(ValueError, what & "." & key & " " & err)
  try:
    int(f.asInt(what & "." & key))
  except CatchableError as e:
    raise newException(ValueError, e.msg)

proc readRsaPriv(ctx: JSContextRef; obj: JSValueRef): RsaPrivateKey =
  let what = "privateKey"
  let n = bigFromHex(getStrHex(ctx, obj, "n", what), what & ".n")
  let e = bigFromHex(getStrHex(ctx, obj, "e", what), what & ".e")
  let d = bigFromHex(getStrHex(ctx, obj, "d", what), what & ".d")
  let p = bigFromHex(getStrHex(ctx, obj, "p", what), what & ".p")
  let q = bigFromHex(getStrHex(ctx, obj, "q", what), what & ".q")
  let dp = bigFromHex(getStrHex(ctx, obj, "dp", what), what & ".dp")
  let dq = bigFromHex(getStrHex(ctx, obj, "dq", what), what & ".dq")
  let qinv = bigFromHex(getStrHex(ctx, obj, "qinv", what), what & ".qinv")
  let k = getIntField(ctx, obj, "k", what)
  if k < 128 or k > 512:
    raise newException(ValueError, what & ".k out of range (128..512)")
  RsaPrivateKey(n: n, e: e, d: d, p: p, q: q, dp: dp, dq: dq,
    qinv: qinv, k: k)

proc readRsaPub(ctx: JSContextRef; obj: JSValueRef): RsaPublicKey =
  let what = "publicKey"
  let n = bigFromHex(getStrHex(ctx, obj, "n", what), what & ".n")
  let e = bigFromHex(getStrHex(ctx, obj, "e", what), what & ".e")
  let k = getIntField(ctx, obj, "k", what)
  if k < 128 or k > 512:
    raise newException(ValueError, what & ".k out of range (128..512)")
  RsaPublicKey(n: n, e: e, k: k)

proc putRsaKey(ctx: JSContextRef; obj: JSObjectRef; name: string;
    key: auto; fname: string; exception: ptr JSValueRef): bool =
  setPropChecked(ctx, obj, name, toJS(ctx, bigToHexTrimmed(key)),
    fname, exception)

proc doRsaKeypair(ctx: JSContextRef; bits: int64; docBlock: string;
    exception: ptr JSValueRef): JSValueRef =
  const name = "rsa.keypair"
  try:
    if bits != 1024 and bits != 2048 and bits != 3072 and bits != 4096:
      raise newException(ValueError,
        "bits must be one of 1024, 2048, 3072, 4096 (1024 is tests-only)")
    var priv = generateRsaKeyPair(int(bits), 65537, bits < 2048)
    defer: wipeRsaKey(priv)
    let pub = rsaPublicKey(priv)
    let privObj = newObject(ctx)
    if not putRsaKey(ctx, privObj, "n", priv.n, name, exception): return nil
    if not putRsaKey(ctx, privObj, "e", priv.e, name, exception): return nil
    if not putRsaKey(ctx, privObj, "d", priv.d, name, exception): return nil
    if not putRsaKey(ctx, privObj, "p", priv.p, name, exception): return nil
    if not putRsaKey(ctx, privObj, "q", priv.q, name, exception): return nil
    if not putRsaKey(ctx, privObj, "dp", priv.dp, name, exception): return nil
    if not putRsaKey(ctx, privObj, "dq", priv.dq, name, exception): return nil
    if not putRsaKey(ctx, privObj, "qinv", priv.qinv, name, exception):
      return nil
    if not setPropChecked(ctx, privObj, "k", toJS(ctx, priv.k), name,
        exception):
      return nil
    if not setPropChecked(ctx, privObj, "bits", toJS(ctx, int(bits)),
        name, exception):
      return nil
    let pubObj = newObject(ctx)
    if not putRsaKey(ctx, pubObj, "n", pub.n, name, exception): return nil
    if not putRsaKey(ctx, pubObj, "e", pub.e, name, exception): return nil
    if not setPropChecked(ctx, pubObj, "k", toJS(ctx, pub.k), name,
        exception):
      return nil
    if not setPropChecked(ctx, pubObj, "bits", toJS(ctx, int(bits)),
        name, exception):
      return nil
    let obj = newObject(ctx)
    if not setPropChecked(ctx, obj, "privateKey", privObj, name,
        exception):
      return nil
    if not setPropChecked(ctx, obj, "publicKey", pubObj, name, exception):
      return nil
    obj
  except CatchableError as e:
    cryptoErr(ctx, docBlock, name, e.msg, exception)
    nil

proc doRsaSign(ctx: JSContextRef; privObj: JSValueRef; text,
    hashName, padding: string; docBlock: string;
    exception: ptr JSValueRef): JSValueRef =
  const name = "rsa.sign"
  try:
    var priv = readRsaPriv(ctx, privObj)
    defer: wipeRsaKey(priv)
    let h = parseRsaHash(hashName)
    if h == rhSha1:
      raise newException(ValueError, "SHA-1 is OAEP-only, not for signing")
    let pad = if padding.len == 0: "pss" else: padding.toLowerAscii()
    let sig =
      case pad
      of "pss": rsaPssSign(priv, h, text)
      of "pkcs1v15", "pkcs1-v1_5": rsaPkcs1v15Sign(priv, h, text)
      else:
        raise newException(ValueError,
          "padding must be \"pss\" or \"pkcs1v15\"")
    toJS(ctx, hexOut(sig))
  except CatchableError as e:
    cryptoErr(ctx, docBlock, name, e.msg, exception)
    nil

proc doRsaVerify(ctx: JSContextRef; pubObj: JSValueRef; text,
    sigHex, hashName, padding: string; docBlock: string;
    exception: ptr JSValueRef): JSValueRef =
  const name = "rsa.verify"
  try:
    let pub = readRsaPub(ctx, pubObj)
    let h = parseRsaHash(hashName)
    let pad = if padding.len == 0: "pss" else: padding.toLowerAscii()
    let sig = parseBytes(sigHex, "signature")
    let ok =
      case pad
      of "pss": rsaPssVerify(pub, h, text, sig)
      of "pkcs1v15", "pkcs1-v1_5": rsaPkcs1v15Verify(pub, h, text, sig)
      else:
        raise newException(ValueError,
          "padding must be \"pss\" or \"pkcs1v15\"")
    toJS(ctx, ok)
  except CatchableError as e:
    cryptoErr(ctx, docBlock, name, e.msg, exception)
    nil

proc doRsaEncrypt(ctx: JSContextRef; pubObj: JSValueRef; text,
    hashName: string; docBlock: string;
    exception: ptr JSValueRef): JSValueRef =
  const name = "rsa.encrypt"
  try:
    let pub = readRsaPub(ctx, pubObj)
    let h = parseRsaHash(hashName)
    toJS(ctx, hexOut(rsaOaepEncrypt(pub, h, text)))
  except CatchableError as e:
    cryptoErr(ctx, docBlock, name, e.msg, exception)
    nil

proc doRsaDecrypt(ctx: JSContextRef; privObj: JSValueRef; cipherHex,
    hashName: string; docBlock: string;
    exception: ptr JSValueRef): JSValueRef =
  const name = "rsa.decrypt"
  try:
    var priv = readRsaPriv(ctx, privObj)
    defer: wipeRsaKey(priv)
    let h = parseRsaHash(hashName)
    let ct = parseBytes(cipherHex, "cipher")
    toJS(ctx, toString(rsaOaepDecrypt(priv, h, ct)))
  except CatchableError as e:
    cryptoErr(ctx, docBlock, name, e.msg, exception)
    nil

## Builds the std/crypto namespace object.
init proc(module: Module) =
  let hashNs = newObject(module.ctx)
  let aeadNs = newObject(module.ctx)
  let signNs = newObject(module.ctx)
  let passwordNs = newObject(module.ctx)
  let xNs = newObject(module.ctx)
  let aesNs = newObject(module.ctx)
  let ecdsaNs = newObject(module.ctx)
  let rsaNs = newObject(module.ctx)

  ctx.registerFn hashSha256(text: string):
    ## hash.sha256hex(text) -> hex digest
    return doSha256(ctx, text, docBlock, exception)

  ctx.registerFn hashMd5(text: string):
    ## hash.md5(text) -> hex digest (legacy interop only, do not use for security)
    return doMd5(ctx, text, docBlock, exception)

  ctx.registerFn hashSha384(text: string):
    ## hash.sha384hex(text) -> hex digest
    return doSha384(ctx, text, docBlock, exception)

  ctx.registerFn hashSha512(text: string):
    ## hash.sha512hex(text) -> hex digest
    return doSha512(ctx, text, docBlock, exception)

  ctx.registerFn hashBlake2b(text: string, size: default(int64, Blake2bDefaultDigestSize)):
    ## hash.blake2bhex(text[, size]) -> hex digest (size 1..64, default 32)
    return doBlake2b(ctx, text, size, docBlock, exception)

  ctx.registerFn hashHmacSha256(keyHex: string, text: string):
    ## hash.hmacSha256hex(keyHex, text) -> hex mac
    return doHmacSha256(ctx, keyHex, text, docBlock, exception)

  ctx.registerFn aeadSeal(text: string, keyHex: string):
    ## aead.seal(text, keyHex) -> {nonce, mac, cipher}
    return doSeal(ctx, text, keyHex, docBlock, exception)

  ctx.registerFn aeadOpen(envObj: JSObjectRef, keyHex: string):
    ## aead.open({nonce, mac, cipher}, keyHex) -> text
    return doOpen(ctx, envObj, keyHex, docBlock, exception)

  ctx.registerFn signKeypair():
    ## sign.keypair() -> {publicKey, secretKey} hex
    return doKeypair(ctx, docBlock, exception)

  ctx.registerFn signKeypairFromSeed(seedHex: string):
    ## sign.keypairFromSeed(seedHex) -> {publicKey, secretKey} hex
    return doKeypairFromSeed(ctx, seedHex, docBlock, exception)

  ctx.registerFn signSign(secretHex: string, text: string):
    ## sign.sign(secretHex, text) -> hex signature
    return doSign(ctx, secretHex, text, docBlock, exception)

  ctx.registerFn signVerify(publicHex: string, text: string, sigHex: string):
    ## sign.verify(publicHex, text, sigHex) -> bool
    return doVerify(ctx, publicHex, text, sigHex, docBlock, exception)

  ctx.registerFn passwordHash(pw: string):
    ## password.hash(pw) -> "hex(salt):hex(hash)"
    return doPwHash(ctx, pw, docBlock, exception)

  ctx.registerFn passwordVerify(pw: string, stored: string):
    ## password.verify(pw, stored) -> bool
    return doPwVerify(ctx, pw, stored, docBlock, exception)

  ctx.registerFn xKeypair(secretHex ?: string):
    ## x25519.keypair([secretHex]) -> {secret, public} hex
    return doXKeypair(ctx, secretHex, docBlock, exception)

  ctx.registerFn xSharedKey(mySecretHex: string, theirPublicHex: string, infoHex ?: string):
    ## x25519.sharedKey(mySecretHex, theirPublicHex[, infoHex]) -> hex
    return doXShared(ctx, mySecretHex, theirPublicHex, infoHex, docBlock,
      exception)

  ctx.registerFn aesSeal(text: string, keyHex: string, nonceHex ?: string, adHex ?: string):
    ## aes.seal(text, keyHex[, nonceHex[, adHex]]) -> {nonce, tag, cipher}
    return doAesSeal(ctx, text, keyHex, nonceHex, adHex, docBlock, exception)

  ctx.registerFn aesOpen(envObj: JSObjectRef, keyHex: string, adHex ?: string):
    ## aes.open({nonce, tag, cipher}, keyHex[, adHex]) -> text
    return doAesOpen(ctx, envObj, keyHex, adHex, docBlock, exception)

  ctx.registerFn ecKeypair(curve: string):
    ## ecdsa.keypair(curve) -> {privateKey, x, y, curve}
    return doEcKeypair(ctx, curve, docBlock, exception)

  ctx.registerFn ecSign(privateHex: string, text: string, curve: string):
    ## ecdsa.sign(privateHex, text, curve) -> hex signature (R||S)
    return doEcSign(ctx, privateHex, text, curve, docBlock, exception)

  ctx.registerFn ecVerify(xHex: string, yHex: string, text: string, sigHex: string, curve: string):
    ## ecdsa.verify(xHex, yHex, text, sigHex, curve) -> bool
    return doEcVerify(ctx, xHex, yHex, text, sigHex, curve, docBlock,
      exception)

  ctx.registerFn ecSharedKey(privHex: string, xHex: string, yHex: string, curve: string, infoHex ?: string):
    ## ecdsa.sharedKey(privHex, xHex, yHex, curve[, infoHex]) -> hex
    return doEcShared(ctx, privHex, xHex, yHex, curve, infoHex, docBlock,
      exception)

  ctx.registerFn rsaKeypair(bits: default(int, 2048)):
    ## rsa.keypair([bits]) -> {privateKey, publicKey} (1024 is tests-only)
    return doRsaKeypair(ctx, bits, docBlock, exception)

  ctx.registerFn rsaSign(privObj: JSObjectRef, text: string, hashName: string, padding ?: string):
    ## rsa.sign(privateKey, text, hash[, padding]) -> hex signature
    return doRsaSign(ctx, privObj, text, hashName, padding, docBlock,
      exception)

  ctx.registerFn rsaVerify(pubObj: JSObjectRef, text: string, sigHex: string, hashName: string, padding ?: string):
    ## rsa.verify(publicKey, text, sigHex, hash[, padding]) -> bool
    return doRsaVerify(ctx, pubObj, text, sigHex, hashName, padding,
      docBlock, exception)

  ctx.registerFn rsaEncrypt(pubObj: JSObjectRef, text: string, hashName: string):
    ## rsa.encrypt(publicKey, text, hash) -> hex cipher (OAEP)
    return doRsaEncrypt(ctx, pubObj, text, hashName, docBlock, exception)

  ctx.registerFn rsaDecrypt(privObj: JSObjectRef, cipherHex: string, hashName: string):
    ## rsa.decrypt(privateKey, cipherHex, hash) -> text (OAEP)
    return doRsaDecrypt(ctx, privObj, cipherHex, hashName, docBlock,
      exception)

  # Plain-object property sets cannot throw; no setupEx in scope here.
  setProp(module.ctx, hashNs, "md5",
    makeFunction(module.ctx, "md5", hashMd5), nil)
  setProp(module.ctx, hashNs, "sha256hex",
    makeFunction(module.ctx, "sha256hex", hashSha256), nil)
  setProp(module.ctx, hashNs, "sha384hex",
    makeFunction(module.ctx, "sha384hex", hashSha384), nil)
  setProp(module.ctx, hashNs, "sha512hex",
    makeFunction(module.ctx, "sha512hex", hashSha512), nil)
  setProp(module.ctx, hashNs, "blake2bhex",
    makeFunction(module.ctx, "blake2bhex", hashBlake2b), nil)
  setProp(module.ctx, hashNs, "hmacSha256hex",
    makeFunction(module.ctx, "hmacSha256hex", hashHmacSha256), nil)

  setProp(module.ctx, aeadNs, "seal",
    makeFunction(module.ctx, "seal", aeadSeal), nil)
  setProp(module.ctx, aeadNs, "open",
    makeFunction(module.ctx, "open", aeadOpen), nil)

  setProp(module.ctx, signNs, "keypair",
    makeFunction(module.ctx, "keypair", signKeypair), nil)
  setProp(module.ctx, signNs, "keypairFromSeed",
    makeFunction(module.ctx, "keypairFromSeed", signKeypairFromSeed), nil)
  setProp(module.ctx, signNs, "sign",
    makeFunction(module.ctx, "sign", signSign), nil)
  setProp(module.ctx, signNs, "verify",
    makeFunction(module.ctx, "verify", signVerify), nil)

  setProp(module.ctx, passwordNs, "hash",
    makeFunction(module.ctx, "hash", passwordHash), nil)
  setProp(module.ctx, passwordNs, "verify",
    makeFunction(module.ctx, "verify", passwordVerify), nil)

  setProp(module.ctx, xNs, "keypair",
    makeFunction(module.ctx, "keypair", xKeypair), nil)
  setProp(module.ctx, xNs, "sharedKey",
    makeFunction(module.ctx, "sharedKey", xSharedKey), nil)

  setProp(module.ctx, aesNs, "seal",
    makeFunction(module.ctx, "seal", aesSeal), nil)
  setProp(module.ctx, aesNs, "open",
    makeFunction(module.ctx, "open", aesOpen), nil)

  setProp(module.ctx, ecdsaNs, "keypair",
    makeFunction(module.ctx, "keypair", ecKeypair), nil)
  setProp(module.ctx, ecdsaNs, "sign",
    makeFunction(module.ctx, "sign", ecSign), nil)
  setProp(module.ctx, ecdsaNs, "verify",
    makeFunction(module.ctx, "verify", ecVerify), nil)
  setProp(module.ctx, ecdsaNs, "sharedKey",
    makeFunction(module.ctx, "sharedKey", ecSharedKey), nil)

  setProp(module.ctx, rsaNs, "keypair",
    makeFunction(module.ctx, "keypair", rsaKeypair), nil)
  setProp(module.ctx, rsaNs, "sign",
    makeFunction(module.ctx, "sign", rsaSign), nil)
  setProp(module.ctx, rsaNs, "verify",
    makeFunction(module.ctx, "verify", rsaVerify), nil)
  setProp(module.ctx, rsaNs, "encrypt",
    makeFunction(module.ctx, "encrypt", rsaEncrypt), nil)
  setProp(module.ctx, rsaNs, "decrypt",
    makeFunction(module.ctx, "decrypt", rsaDecrypt), nil)

  setProp(module.ctx, module.ns, "hash", hashNs, nil)
  setProp(module.ctx, module.ns, "aead", aeadNs, nil)
  setProp(module.ctx, module.ns, "sign", signNs, nil)
  setProp(module.ctx, module.ns, "password", passwordNs, nil)
  setProp(module.ctx, module.ns, "x25519", xNs, nil)
  setProp(module.ctx, module.ns, "aes", aesNs, nil)
  setProp(module.ctx, module.ns, "ecdsa", ecdsaNs, nil)
  setProp(module.ctx, module.ns, "rsa", rsaNs, nil)
