const crypto = require("std/crypto");

// Hashing: one-shot digests as lowercase hex.
console.log("sha256: " + crypto.hash.sha256hex("abc"));
console.log("sha512 length: " + crypto.hash.sha512hex("abc").length);
console.log("blake2b-128: " + crypto.hash.blake2bhex("abc", 16));
console.log("hmac: " + crypto.hash.hmacSha256hex("6b6579",
  "The quick brown fox jumps over the lazy dog"));

// AEAD: seal with a random nonce, open with the envelope.
const key = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
const env = crypto.aead.seal("attack at dawn", key);
console.log("sealed: nonce=" + env.nonce.length / 2 + "B mac=" +
  env.mac.length / 2 + "B cipher=" + env.cipher.length / 2 + "B");
console.log("opened: " + crypto.aead.open(env, key));

// Tampering is detected.
const tampered = {nonce: env.nonce, mac: env.mac, cipher: "ff" + env.cipher.slice(2)};
try {
  crypto.aead.open(tampered, key);
} catch (e) {
  console.log("tamper rejected: " + e.message.split("\n")[0]);
}

// Signatures: deterministic from a seed, random otherwise.
const kp = crypto.sign.keypairFromSeed(key);
console.log("pub: " + kp.publicKey);
const sig = crypto.sign.sign(kp.secretKey, "transfer 100");
console.log("valid: " + crypto.sign.verify(kp.publicKey, "transfer 100", sig));
console.log("forged: " + crypto.sign.verify(kp.publicKey, "transfer 999", sig));

// Passwords: argon2id hash, constant-time verify.
const stored = crypto.password.hash("correct horse");
console.log("stored: " + stored.slice(0, 12) + "...");
console.log("login ok: " + crypto.password.verify("correct horse", stored));
console.log("login bad: " + crypto.password.verify("wrong horse", stored));

// X25519: hashed shared secret, symmetric both ways.
const alice = crypto.x25519.keypair();
const bob = crypto.x25519.keypair();
console.log("x25519 sym: " +
  (crypto.x25519.sharedKey(alice.secret, bob.public) ===
   crypto.x25519.sharedKey(bob.secret, alice.public)));

// AES-GCM: random-nonce seal, deterministic seal with explicit nonce.
const aesKey = "000102030405060708090a0b0c0d0e0f";
const aesEnv = crypto.aes.seal("attack at dawn", aesKey);
console.log("aes opened: " + crypto.aes.open(aesEnv, aesKey));
const aesFixed = crypto.aes.seal("hello", aesKey,
  "000102030405060708090a0b", "");
console.log("aes tag: " + aesFixed.tag);

// ECDSA: per-curve keypair, RFC6979 sign, hashed ECDH.
const ec = crypto.ecdsa.keypair("P-256");
const ecSig = crypto.ecdsa.sign(ec.privateKey, "transfer 100", "P-256");
console.log("ecdsa valid: " +
  crypto.ecdsa.verify(ec.x, ec.y, "transfer 100", ecSig, "P-256"));

// RSA: 1024-bit in examples for speed (2048+ in production).
const rsaKp = crypto.rsa.keypair(1024);
const rsaSig = crypto.rsa.sign(rsaKp.privateKey, "transfer 100", "SHA-256");
console.log("rsa valid: " +
  crypto.rsa.verify(rsaKp.publicKey, "transfer 100", rsaSig, "SHA-256"));
const rsaCt = crypto.rsa.encrypt(rsaKp.publicKey, "hello", "SHA-256");
console.log("rsa dec: " +
  crypto.rsa.decrypt(rsaKp.privateKey, rsaCt, "SHA-256"));
