# Carne strsimd: byte-level string kernels with SIMD fast paths.
#
# Dispatch per call: scalar below vector width; SSE2 on amd64 (x86_64
# baseline, no compiler flags needed); NEON on arm64; AVX2 through
# `target("avx2")`-attributed C with no global `-mavx2`, so the x86_64
# baseline stays SSE2-era and pre-AVX2 CPUs keep working (Nim's
# {.passC.} is TU-global, which is why the AVX2 kernels live in C).
# `-d:carneStrNoSimd` forces scalar everywhere.
#
# Safety contract: kernels only ever read full 16/32-byte chunks inside
# [start, stop) via unaligned loads, with scalar tails. They never rely
# on Nim's string terminator for over-read. Callers must guarantee
# start <= stop and a non-empty string before taking addresses.

import std/bitops

const useSimd = not defined(carneStrNoSimd)

when useSimd and defined(amd64):
  import nimsimd/sse2
  import nimsimd/runtimecheck
  const hasSse2 = true
  let cpuHasAvx2 = checkInstructionSets({AVX2})

  {.emit: """
#include <immintrin.h>
#include <stdint.h>

__attribute__((target("avx2")))
static int str_findNeedle_avx2(const char *buf, int start, int stop,
    char c1, char c2) {
  __m256i v1 = _mm256_set1_epi8(c1);
  __m256i v2 = _mm256_set1_epi8(c2);
  int i = start;
  for (; i + 32 <= stop; i += 32) {
    __m256i chunk = _mm256_loadu_si256((const __m256i *)(buf + i));
    __m256i m = _mm256_or_si256(_mm256_cmpeq_epi8(chunk, v1),
                                _mm256_cmpeq_epi8(chunk, v2));
    int mask = _mm256_movemask_epi8(m);
    if (mask) return i + __builtin_ctz((unsigned)mask);
  }
  for (; i < stop; i++) {
    if (buf[i] == c1 || buf[i] == c2) return i;
  }
  return -1;
}

__attribute__((target("avx2")))
static int str_findNeedleLast_avx2(const char *buf, int start, int stop,
    char c1, char c2) {
  __m256i v1 = _mm256_set1_epi8(c1);
  __m256i v2 = _mm256_set1_epi8(c2);
  int p = stop;
  for (; p - 32 >= start; p -= 32) {
    __m256i chunk = _mm256_loadu_si256((const __m256i *)(buf + p - 32));
    __m256i m = _mm256_or_si256(_mm256_cmpeq_epi8(chunk, v1),
                                _mm256_cmpeq_epi8(chunk, v2));
    int mask = _mm256_movemask_epi8(m);
    if (mask) return p - 32 + 31 - __builtin_clz((unsigned)mask);
  }
  for (p = p - 1; p >= start; p--) {
    if (buf[p] == c1 || buf[p] == c2) return p;
  }
  return -1;
}

__attribute__((target("avx2")))
static int str_wsPrefix_avx2(const char *buf, int start, int stop) {
  __m256i sp = _mm256_set1_epi8(' ');
  __m256i tb = _mm256_set1_epi8('\t');
  __m256i nl = _mm256_set1_epi8('\n');
  __m256i cr = _mm256_set1_epi8('\r');
  __m256i vt = _mm256_set1_epi8('\v');
  __m256i ff = _mm256_set1_epi8('\f');
  __m256i ones = _mm256_set1_epi8((char)0xFF);
  int i = start;
  for (; i + 32 <= stop; i += 32) {
    __m256i chunk = _mm256_loadu_si256((const __m256i *)(buf + i));
    __m256i ws = _mm256_or_si256(
      _mm256_or_si256(_mm256_cmpeq_epi8(chunk, sp),
                      _mm256_cmpeq_epi8(chunk, tb)),
      _mm256_or_si256(
        _mm256_or_si256(_mm256_cmpeq_epi8(chunk, nl),
                        _mm256_cmpeq_epi8(chunk, cr)),
        _mm256_or_si256(_mm256_cmpeq_epi8(chunk, vt),
                        _mm256_cmpeq_epi8(chunk, ff))));
    int mask = _mm256_movemask_epi8(_mm256_andnot_si256(ws, ones));
    if (mask) return i + __builtin_ctz((unsigned)mask);
  }
  for (; i < stop; i++) {
    char c = buf[i];
    if (c != ' ' && c != '\t' && c != '\n' && c != '\r' &&
        c != '\v' && c != '\f') return i;
  }
  return stop;
}

__attribute__((target("avx2")))
static int str_countByte_avx2(const char *buf, int start, int stop, char c) {
  __m256i v = _mm256_set1_epi8(c);
  int n = 0, i = start;
  for (; i + 32 <= stop; i += 32) {
    __m256i chunk = _mm256_loadu_si256((const __m256i *)(buf + i));
    n += __builtin_popcount(
      (unsigned)_mm256_movemask_epi8(_mm256_cmpeq_epi8(chunk, v)));
  }
  for (; i < stop; i++) if (buf[i] == c) n++;
  return n;
}

__attribute__((target("avx2")))
static int str_asciiLower_avx2(char *dest, const char *src, int start,
    int stop) {
  __m256i lo = _mm256_set1_epi8('A' - 1);
  __m256i hi = _mm256_set1_epi8('Z' + 1);
  __m256i add = _mm256_set1_epi8(32);
  int high = 0, i = start;
  for (; i + 32 <= stop; i += 32) {
    __m256i chunk = _mm256_loadu_si256((const __m256i *)(src + i));
    if (_mm256_movemask_epi8(chunk)) high = 1;
    __m256i m = _mm256_and_si256(_mm256_cmpgt_epi8(chunk, lo),
                                 _mm256_cmpgt_epi8(hi, chunk));
    _mm256_storeu_si256((__m256i *)(dest + i),
      _mm256_add_epi8(chunk, _mm256_and_si256(m, add)));
  }
  for (; i < stop; i++) {
    unsigned char c = (unsigned char)src[i];
    if (c >= 0x80) high = 1;
    dest[i] = (char)((c >= 'A' && c <= 'Z') ? (c + 32) : c);
  }
  return high;
}

__attribute__((target("avx2")))
static int str_asciiUpper_avx2(char *dest, const char *src, int start,
    int stop) {
  __m256i lo = _mm256_set1_epi8('a' - 1);
  __m256i hi = _mm256_set1_epi8('z' + 1);
  __m256i sub = _mm256_set1_epi8((char)(256 - 32));
  int high = 0, i = start;
  for (; i + 32 <= stop; i += 32) {
    __m256i chunk = _mm256_loadu_si256((const __m256i *)(src + i));
    if (_mm256_movemask_epi8(chunk)) high = 1;
    __m256i m = _mm256_and_si256(_mm256_cmpgt_epi8(chunk, lo),
                                 _mm256_cmpgt_epi8(hi, chunk));
    _mm256_storeu_si256((__m256i *)(dest + i),
      _mm256_add_epi8(chunk, _mm256_and_si256(m, sub)));
  }
  for (; i < stop; i++) {
    unsigned char c = (unsigned char)src[i];
    if (c >= 0x80) high = 1;
    dest[i] = (char)((c >= 'a' && c <= 'z') ? (c - 32) : c);
  }
  return high;
}
""".}

  proc findNeedleAvx2(buf: pointer; start, stop: cint;
      c1, c2: cchar): cint {.importc: "str_findNeedle_avx2", nodecl.}
  proc findNeedleLastAvx2(buf: pointer; start, stop: cint;
      c1, c2: cchar): cint {.importc: "str_findNeedleLast_avx2", nodecl.}
  proc wsPrefixAvx2(buf: pointer; start, stop: cint): cint
    {.importc: "str_wsPrefix_avx2", nodecl.}
  proc countByteAvx2(buf: pointer; start, stop: cint;
      c: cchar): cint {.importc: "str_countByte_avx2", nodecl.}
  proc asciiLowerAvx2(dest, src: pointer; start, stop: cint): cint
    {.importc: "str_asciiLower_avx2", nodecl.}
  proc asciiUpperAvx2(dest, src: pointer; start, stop: cint): cint
    {.importc: "str_asciiUpper_avx2", nodecl.}
else:
  const hasSse2 = false

when useSimd and defined(arm64):
  import nimsimd/neon
  const hasNeon = true
else:
  const hasNeon = false

# ---------------------------------------------------------------------------
# Scalar fallbacks (always compiled)
# ---------------------------------------------------------------------------

proc findNeedleScalar(buf: ptr UncheckedArray[char]; start, stop: int;
    c1, c2: char): int {.inline.} =
  for i in start ..< stop:
    if buf[i] == c1 or buf[i] == c2:
      return i
  -1

proc findNeedleLastScalar(buf: ptr UncheckedArray[char]; start,
    stop: int; c1, c2: char): int {.inline.} =
  for i in countdown(stop - 1, start):
    if buf[i] == c1 or buf[i] == c2:
      return i
  -1

proc wsPrefixScalar(buf: ptr UncheckedArray[char]; start,
    stop: int): int {.inline.} =
  var i = start
  while i < stop and buf[i] in {' ', '\t', '\n', '\r', '\v', '\f'}:
    inc i
  i

proc wsSuffixScalar(buf: ptr UncheckedArray[char]; start,
    stop: int): int {.inline.} =
  var p = stop
  while p > start and buf[p - 1] in {' ', '\t', '\n', '\r', '\v', '\f'}:
    dec p
  p

proc countByteScalar(buf: ptr UncheckedArray[char]; start, stop: int;
    c: char): int {.inline.} =
  var n = 0
  for i in start ..< stop:
    if buf[i] == c:
      inc n
  n

proc isAsciiScalar(s: string): bool {.inline.} =
  for c in s:
    if c >= '\x80':
      return false
  true

# ---------------------------------------------------------------------------
# SSE2 paths
# ---------------------------------------------------------------------------

when hasSse2:
  proc findNeedleSse2(buf: ptr UncheckedArray[char]; start, stop: int;
      c1, c2: char): int =
    let v1 = mm_set1_epi8(c1)
    let v2 = mm_set1_epi8(c2)
    var i = start
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(addr buf[i])
      let mask = mm_movemask_epi8(mm_or_si128(mm_cmpeq_epi8(chunk, v1),
        mm_cmpeq_epi8(chunk, v2)))
      if mask != 0:
        return i + countTrailingZeroBits(cast[uint32](mask))
      i += 16
    findNeedleScalar(buf, i, stop, c1, c2)

  proc findNeedleLastSse2(buf: ptr UncheckedArray[char]; start,
      stop: int; c1, c2: char): int =
    let v1 = mm_set1_epi8(c1)
    let v2 = mm_set1_epi8(c2)
    var p = stop
    while p - 16 >= start:
      let chunk = mm_loadu_si128(addr buf[p - 16])
      let mask = mm_movemask_epi8(mm_or_si128(mm_cmpeq_epi8(chunk, v1),
        mm_cmpeq_epi8(chunk, v2)))
      if mask != 0:
        return p - 16 + 32 - countLeadingZeroBits(cast[uint32](mask)) - 1
      p -= 16
    findNeedleLastScalar(buf, start, p, c1, c2)

  proc wsPrefixSse2(buf: ptr UncheckedArray[char]; start,
      stop: int): int =
    let sp = mm_set1_epi8(' ')
    let tb = mm_set1_epi8('\t')
    let nl = mm_set1_epi8('\n')
    let cr = mm_set1_epi8('\r')
    let vt = mm_set1_epi8('\v')
    let ff = mm_set1_epi8('\f')
    let ones = mm_set1_epi8(cast[int8](-1))
    var i = start
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(addr buf[i])
      let ws = mm_or_si128(
        mm_or_si128(mm_cmpeq_epi8(chunk, sp), mm_cmpeq_epi8(chunk, tb)),
        mm_or_si128(
          mm_or_si128(mm_cmpeq_epi8(chunk, nl), mm_cmpeq_epi8(chunk, cr)),
          mm_or_si128(mm_cmpeq_epi8(chunk, vt), mm_cmpeq_epi8(chunk, ff))))
      let mask = mm_movemask_epi8(mm_andnot_si128(ws, ones))
      if mask != 0:
        return i + countTrailingZeroBits(cast[uint32](mask))
      i += 16
    wsPrefixScalar(buf, i, stop)

  proc wsSuffixSse2(buf: ptr UncheckedArray[char]; start,
      stop: int): int =
    let sp = mm_set1_epi8(' ')
    let tb = mm_set1_epi8('\t')
    let nl = mm_set1_epi8('\n')
    let cr = mm_set1_epi8('\r')
    let vt = mm_set1_epi8('\v')
    let ff = mm_set1_epi8('\f')
    let ones = mm_set1_epi8(cast[int8](-1))
    var p = stop
    while p - 16 >= start:
      let chunk = mm_loadu_si128(addr buf[p - 16])
      let ws = mm_or_si128(
        mm_or_si128(mm_cmpeq_epi8(chunk, sp), mm_cmpeq_epi8(chunk, tb)),
        mm_or_si128(
          mm_or_si128(mm_cmpeq_epi8(chunk, nl), mm_cmpeq_epi8(chunk, cr)),
          mm_or_si128(mm_cmpeq_epi8(chunk, vt), mm_cmpeq_epi8(chunk, ff))))
      let mask = mm_movemask_epi8(mm_andnot_si128(ws, ones))
      if mask != 0:
        return p - 16 + 32 - countLeadingZeroBits(cast[uint32](mask))
      p -= 16
    wsSuffixScalar(buf, start, p)

  proc countByteSse2(buf: ptr UncheckedArray[char]; start, stop: int;
      c: char): int =
    let v = mm_set1_epi8(c)
    var n = 0
    var i = start
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(addr buf[i])
      n += countSetBits(cast[uint32](
        mm_movemask_epi8(mm_cmpeq_epi8(chunk, v))))
      i += 16
    n + countByteScalar(buf, i, stop, c)

  proc isAsciiSse2(s: string): bool =
    let buf = cast[ptr UncheckedArray[char]](unsafeAddr s[0])
    let stop = s.len
    var i = 0
    while i + 16 <= stop:
      if mm_movemask_epi8(mm_loadu_si128(addr buf[i])) != 0:
        return false
      i += 16
    for j in i ..< stop:
      if buf[j] >= '\x80':
        return false
    true

  proc asciiLowerSse2(dest, src: ptr UncheckedArray[char]; start,
      stop: int): bool =
    let lo = mm_set1_epi8(cast[int8](ord('A') - 1))
    let hi = mm_set1_epi8(cast[int8](ord('Z') + 1))
    let add = mm_set1_epi8(cast[int8](32))
    var high = false
    var i = start
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(addr src[i])
      if mm_movemask_epi8(chunk) != 0:
        high = true
      let m = mm_and_si128(mm_cmpgt_epi8(chunk, lo),
        mm_cmpgt_epi8(hi, chunk))
      mm_storeu_si128(addr dest[i],
        mm_add_epi8(chunk, mm_and_si128(m, add)))
      i += 16
    for j in i ..< stop:
      let c = src[j]
      if c >= '\x80':
        high = true
      dest[j] =
        if c >= 'A' and c <= 'Z': chr(ord(c) + 32)
        else: c
    high

  proc asciiUpperSse2(dest, src: ptr UncheckedArray[char]; start,
      stop: int): bool =
    let lo = mm_set1_epi8(cast[int8](ord('a') - 1))
    let hi = mm_set1_epi8(cast[int8](ord('z') + 1))
    let sub = mm_set1_epi8(cast[int8](-32))
    var high = false
    var i = start
    while i + 16 <= stop:
      let chunk = mm_loadu_si128(addr src[i])
      if mm_movemask_epi8(chunk) != 0:
        high = true
      let m = mm_and_si128(mm_cmpgt_epi8(chunk, lo),
        mm_cmpgt_epi8(hi, chunk))
      mm_storeu_si128(addr dest[i],
        mm_add_epi8(chunk, mm_and_si128(m, sub)))
      i += 16
    for j in i ..< stop:
      let c = src[j]
      if c >= '\x80':
        high = true
      dest[j] =
        if c >= 'a' and c <= 'z': chr(ord(c) - 32)
        else: c
    high

# ---------------------------------------------------------------------------
# NEON paths (arm64)
# ---------------------------------------------------------------------------

when hasNeon:
  proc findNeedleNeon(buf: ptr UncheckedArray[char]; start, stop: int;
      c1, c2: char): int =
    let v1 = vmovq_n_u8(cast[uint8](c1))
    let v2 = vmovq_n_u8(cast[uint8](c2))
    var tmp: array[16, uint8]
    var i = start
    while i + 16 <= stop:
      let chunk = vld1q_u8(cast[pointer](addr buf[i]))
      let m = vorrq_u8(vceqq_u8(chunk, v1), vceqq_u8(chunk, v2))
      if vmaxvq_u8(m) != 0:
        vst1q_u8(cast[pointer](addr tmp[0]), m)
        for k in 0 ..< 16:
          if tmp[k] != 0:
            return i + k
      i += 16
    findNeedleScalar(buf, i, stop, c1, c2)

  proc findNeedleLastNeon(buf: ptr UncheckedArray[char]; start,
      stop: int; c1, c2: char): int =
    let v1 = vmovq_n_u8(cast[uint8](c1))
    let v2 = vmovq_n_u8(cast[uint8](c2))
    var tmp: array[16, uint8]
    var p = stop
    while p - 16 >= start:
      let chunk = vld1q_u8(cast[pointer](addr buf[p - 16]))
      let m = vorrq_u8(vceqq_u8(chunk, v1), vceqq_u8(chunk, v2))
      if vmaxvq_u8(m) != 0:
        vst1q_u8(cast[pointer](addr tmp[0]), m)
        for k in countdown(15, 0):
          if tmp[k] != 0:
            return p - 16 + k
      p -= 16
    findNeedleLastScalar(buf, start, p, c1, c2)

  proc wsPrefixNeon(buf: ptr UncheckedArray[char]; start,
      stop: int): int =
    let vs = vmovq_n_u8(cast[uint8](' '))
    let vt = vmovq_n_u8(cast[uint8]('\t'))
    let vn = vmovq_n_u8(cast[uint8]('\n'))
    let vr = vmovq_n_u8(cast[uint8]('\r'))
    let vv = vmovq_n_u8(cast[uint8]('\v'))
    let vf = vmovq_n_u8(cast[uint8]('\f'))
    var tmp: array[16, uint8]
    var i = start
    while i + 16 <= stop:
      let chunk = vld1q_u8(cast[pointer](addr buf[i]))
      var m = vorrq_u8(vceqq_u8(chunk, vs), vceqq_u8(chunk, vt))
      m = vorrq_u8(m, vceqq_u8(chunk, vn))
      m = vorrq_u8(m, vceqq_u8(chunk, vr))
      m = vorrq_u8(m, vceqq_u8(chunk, vv))
      m = vorrq_u8(m, vceqq_u8(chunk, vf))
      if vmaxvq_u8(vmvnq_u8(m)) != 0:
        vst1q_u8(cast[pointer](addr tmp[0]), m)
        for k in 0 ..< 16:
          if tmp[k] == 0:
            return i + k
        i += 16
      else:
        i += 16
    wsPrefixScalar(buf, i, stop)

  proc wsSuffixNeon(buf: ptr UncheckedArray[char]; start,
      stop: int): int =
    let vs = vmovq_n_u8(cast[uint8](' '))
    let vt = vmovq_n_u8(cast[uint8]('\t'))
    let vn = vmovq_n_u8(cast[uint8]('\n'))
    let vr = vmovq_n_u8(cast[uint8]('\r'))
    let vv = vmovq_n_u8(cast[uint8]('\v'))
    let vf = vmovq_n_u8(cast[uint8]('\f'))
    var tmp: array[16, uint8]
    var p = stop
    while p - 16 >= start:
      let chunk = vld1q_u8(cast[pointer](addr buf[p - 16]))
      var m = vorrq_u8(vceqq_u8(chunk, vs), vceqq_u8(chunk, vt))
      m = vorrq_u8(m, vceqq_u8(chunk, vn))
      m = vorrq_u8(m, vceqq_u8(chunk, vr))
      m = vorrq_u8(m, vceqq_u8(chunk, vv))
      m = vorrq_u8(m, vceqq_u8(chunk, vf))
      if vmaxvq_u8(vmvnq_u8(m)) != 0:
        vst1q_u8(cast[pointer](addr tmp[0]), m)
        for k in countdown(15, 0):
          if tmp[k] == 0:
            return p - 16 + k + 1
      p -= 16
    wsSuffixScalar(buf, start, p)

  proc countByteNeon(buf: ptr UncheckedArray[char]; start, stop: int;
      c: char): int =
    let v = vmovq_n_u8(cast[uint8](c))
    var tmp: array[16, uint8]
    var n = 0
    var i = start
    while i + 16 <= stop:
      let chunk = vld1q_u8(cast[pointer](addr buf[i]))
      let m = vceqq_u8(chunk, v)
      if vmaxvq_u8(m) != 0:
        vst1q_u8(cast[pointer](addr tmp[0]), m)
        for k in 0 ..< 16:
          if tmp[k] != 0:
            inc n
      i += 16
    n + countByteScalar(buf, i, stop, c)

  proc isAsciiNeon(s: string): bool =
    let buf = cast[ptr UncheckedArray[char]](unsafeAddr s[0])
    let stop = s.len
    var i = 0
    while i + 16 <= stop:
      if vmaxvq_u8(vld1q_u8(cast[pointer](addr buf[i]))) > 127:
        return false
      i += 16
    for j in i ..< stop:
      if buf[j] >= '\x80':
        return false
    true

  proc asciiLowerNeon(dest, src: ptr UncheckedArray[char]; start,
      stop: int): bool =
    let bA = vmovq_n_u8(cast[uint8]('A'))
    let bZ1 = vmovq_n_u8(cast[uint8]('Z') + 1)
    let b80 = vmovq_n_u8(cast[uint8](0x80))
    let b32 = vmovq_n_u8(cast[uint8](32))
    var high = false
    var i = start
    while i + 16 <= stop:
      let chunk = vld1q_u8(cast[pointer](addr src[i]))
      if vmaxvq_u8(vmvnq_u8(vcltq_u8(chunk, b80))) != 0:
        high = true
      let geA = vmvnq_u8(vcltq_u8(chunk, bA))
      let leZ = vcltq_u8(chunk, bZ1)
      let m = vandq_u8(geA, leZ)
      vst1q_u8(cast[pointer](addr dest[i]),
        vaddq_u8(chunk, vandq_u8(m, b32)))
      i += 16
    for j in i ..< stop:
      let c = src[j]
      if c >= '\x80':
        high = true
      dest[j] =
        if c >= 'A' and c <= 'Z': chr(ord(c) + 32)
        else: c
    high

  proc asciiUpperNeon(dest, src: ptr UncheckedArray[char]; start,
      stop: int): bool =
    let ba = vmovq_n_u8(cast[uint8]('a'))
    let bz1 = vmovq_n_u8(cast[uint8]('z') + 1)
    let b80 = vmovq_n_u8(cast[uint8](0x80))
    let b32 = vmovq_n_u8(cast[uint8](32))
    var high = false
    var i = start
    while i + 16 <= stop:
      let chunk = vld1q_u8(cast[pointer](addr src[i]))
      if vmaxvq_u8(vmvnq_u8(vcltq_u8(chunk, b80))) != 0:
        high = true
      let gea = vmvnq_u8(vcltq_u8(chunk, ba))
      let lez = vcltq_u8(chunk, bz1)
      let m = vandq_u8(gea, lez)
      vst1q_u8(cast[pointer](addr dest[i]),
        vsubq_u8(chunk, vandq_u8(m, b32)))
      i += 16
    for j in i ..< stop:
      let c = src[j]
      if c >= '\x80':
        high = true
      dest[j] =
        if c >= 'a' and c <= 'z': chr(ord(c) - 32)
        else: c
    high

# ---------------------------------------------------------------------------
# Unified dispatch
# ---------------------------------------------------------------------------

proc findNeedle*(s: string; start: int; c1, c2: char): int =
  ## First index of `c1`|`c2` at/after `start`, -1 when absent.
  let stop = s.len
  if start >= stop:
    return -1
  let buf = cast[ptr UncheckedArray[char]](unsafeAddr s[0])
  when hasSse2:
    if cpuHasAvx2 and stop - start >= 32:
      return findNeedleAvx2(cast[pointer](buf), start.cint, stop.cint,
        c1.cchar, c2.cchar).int
    if stop - start >= 16:
      return findNeedleSse2(buf, start, stop, c1, c2)
  when hasNeon:
    if stop - start >= 16:
      return findNeedleNeon(buf, start, stop, c1, c2)
  findNeedleScalar(buf, start, stop, c1, c2)

proc findNeedleLast*(s: string; stop: int; c1, c2: char): int
    =
  ## Last index of `c1`|`c2` strictly below `stop`, -1 when absent.
  if stop <= 0 or s.len == 0:
    return -1
  let stopClamped = min(stop, s.len)
  let buf = cast[ptr UncheckedArray[char]](unsafeAddr s[0])
  when hasSse2:
    if cpuHasAvx2 and stopClamped >= 32:
      return findNeedleLastAvx2(cast[pointer](buf), 0,
        stopClamped.cint, c1.cchar, c2.cchar).int
    if stopClamped >= 16:
      return findNeedleLastSse2(buf, 0, stopClamped, c1, c2)
  when hasNeon:
    if stopClamped >= 16:
      return findNeedleLastNeon(buf, 0, stopClamped, c1, c2)
  findNeedleLastScalar(buf, 0, stopClamped, c1, c2)

proc wsPrefixLen*(s: string; start: int): int =
  ## Index of the first non-ASCII-whitespace byte at/after `start`.
  let stop = s.len
  if start >= stop:
    return stop
  let buf = cast[ptr UncheckedArray[char]](unsafeAddr s[0])
  when hasSse2:
    if cpuHasAvx2 and stop - start >= 32:
      return wsPrefixAvx2(cast[pointer](buf), start.cint,
        stop.cint).int
    if stop - start >= 16:
      return wsPrefixSse2(buf, start, stop)
  when hasNeon:
    if stop - start >= 16:
      return wsPrefixNeon(buf, start, stop)
  wsPrefixScalar(buf, start, stop)

proc wsSuffixLen*(s: string; stop: int): int =
  ## Start index of the trailing ASCII-whitespace run before `stop`
  ## (== `stop` when the byte at `stop-1` is not whitespace).
  if stop <= 0:
    return 0
  let buf = cast[ptr UncheckedArray[char]](unsafeAddr s[0])
  when hasSse2:
    if stop >= 16:
      return wsSuffixSse2(buf, 0, stop)
  when hasNeon:
    if stop >= 16:
      return wsSuffixNeon(buf, 0, stop)
  wsSuffixScalar(buf, 0, stop)

proc countByte*(s: string; start: int; c: char): int =
  ## Occurrences of byte `c` at/after `start`.
  let stop = s.len
  if start >= stop:
    return 0
  let buf = cast[ptr UncheckedArray[char]](unsafeAddr s[0])
  when hasSse2:
    if cpuHasAvx2 and stop - start >= 32:
      return countByteAvx2(cast[pointer](buf), start.cint, stop.cint,
        c.cchar).int
    if stop - start >= 16:
      return countByteSse2(buf, start, stop, c)
  when hasNeon:
    if stop - start >= 16:
      return countByteNeon(buf, start, stop, c)
  countByteScalar(buf, start, stop, c)

proc isAscii*(s: string): bool =
  ## True when every byte is below 0x80 (empty counts as ASCII).
  if s.len == 0:
    return true
  when hasSse2:
    if s.len >= 16:
      return isAsciiSse2(s)
  when hasNeon:
    if s.len >= 16:
      return isAsciiNeon(s)
  isAsciiScalar(s)

proc asciiLowerTo*(dest: var string; src: string): bool =
  ## Maps ASCII A-Z to a-z into `dest` (pre-sized to `src.len`).
  ## Returns true when a non-ASCII byte was seen (output is still
  ## written; the caller redoes the string through `unicode` then).
  let n = src.len
  if n == 0:
    return false
  let d = cast[ptr UncheckedArray[char]](addr dest[0])
  let b = cast[ptr UncheckedArray[char]](unsafeAddr src[0])
  when hasSse2:
    if cpuHasAvx2 and n >= 32:
      return asciiLowerAvx2(cast[pointer](d), cast[pointer](b), 0,
        n.cint).int != 0
    if n >= 16:
      return asciiLowerSse2(d, b, 0, n)
  when hasNeon:
    if n >= 16:
      return asciiLowerNeon(d, b, 0, n)
  var high = false
  for i in 0 ..< n:
    let c = b[i]
    if c >= '\x80':
      high = true
    d[i] =
      if c >= 'A' and c <= 'Z': chr(ord(c) + 32)
      else: c
  high

proc asciiUpperTo*(dest: var string; src: string): bool =
  ## Maps ASCII a-z to A-Z into `dest` (pre-sized to `src.len`).
  ## Returns true when a non-ASCII byte was seen (see `asciiLowerTo`).
  let n = src.len
  if n == 0:
    return false
  let d = cast[ptr UncheckedArray[char]](addr dest[0])
  let b = cast[ptr UncheckedArray[char]](unsafeAddr src[0])
  when hasSse2:
    if cpuHasAvx2 and n >= 32:
      return asciiUpperAvx2(cast[pointer](d), cast[pointer](b), 0,
        n.cint).int != 0
    if n >= 16:
      return asciiUpperSse2(d, b, 0, n)
  when hasNeon:
    if n >= 16:
      return asciiUpperNeon(d, b, 0, n)
  var high = false
  for i in 0 ..< n:
    let c = b[i]
    if c >= '\x80':
      high = true
    d[i] =
      if c >= 'a' and c <= 'z': chr(ord(c) - 32)
      else: c
  high
