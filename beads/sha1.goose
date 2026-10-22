// SHA-1 (FIPS 180-4), for the name-based UUIDs (version 5) beads gives its
// dependency edges with Go's uuid.NewSHA1. Not for anything that needs a
// strong hash: beads only uses it to derive stable names.

namespace sha1;

fn rotl(x: u32, n: u32) -> u32 { (x << n) | (x >> (32 - n)) }

// Folds one 64-byte block into the running hash.
fn compress(h: u32[5]&, chunk: const u8[:]) {
    assert(chunk.len == 64);
    var w: u32[80] = [0; 80];
    for i in 16 {
        w[i] = (chunk[4 * i] as u32 << 24) | (chunk[4 * i + 1] as u32 << 16) |
               (chunk[4 * i + 2] as u32 << 8) | chunk[4 * i + 3];
    }
    for i in 16..80 { w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1); }
    var a = h[0]; var b = h[1]; var c = h[2]; var d = h[3]; var e = h[4];
    for i in 80 {
        var f: u32 = 0;
        var k: u32 = 0;
        if i < 20 { f = (b & c) | (~b & d); k = 0x5a827999; }
        else if i < 40 { f = b ^ c ^ d; k = 0x6ed9eba1; }
        else if i < 60 { f = (b & c) | (b & d) | (c & d); k = 0x8f1bbcdc; }
        else { f = b ^ c ^ d; k = 0xca62c1d6; }
        let t = rotl(a, 5) + f + e + k + w[i];
        e = d; d = c; c = rotl(b, 30); b = a; a = t;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e;
}

// The SHA-1 digest of data.
fn digest(data: const u8[:]) -> u8[20] {
    var h: u32[5] = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0];
    let whole = data.len - data.len % 64;
    var at = 0;
    while at < whole {
        compress(h, data[at..at + 64]);
        at += 64;
    }
    // The tail, the 0x80 marker and the bit length fill one or two blocks.
    var tail: u8[128] = [0; 128];
    let rest = data.len - whole;
    for i in rest { tail[i] = data[whole + i]; }
    tail[rest] = 0x80;
    let end = if rest < 56 { 64 } else { 128 };
    let bits = (data.len as u64) * 8;
    for i in 8 { tail[end - 1 - i] = (bits >> (8 * i as u64)) as! u8; }
    compress(h, tail[0..64]);
    if end == 128 { compress(h, tail[64..128]); }
    var out: u8[20] = [0; 20];
    for i in 5 {
        out[4 * i] = (h[i] >> 24) as! u8;
        out[4 * i + 1] = (h[i] >> 16) as! u8;
        out[4 * i + 2] = (h[i] >> 8) as! u8;
        out[4 * i + 3] = h[i] as! u8;
    }
    return out;
}
