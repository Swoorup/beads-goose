// Deterministic row ids: the name-based (SHA-1, version 5) UUIDs beads
// derives for rows that must get the same id in every clone, such as an
// imported comment or a dependency edge.

namespace rowid;

import std;
import .sha256;

fn rotl(x: u32, n: u32) -> u32 { (x << n) | (x >> (32 - n)) }

// Folds one 64-byte block into the running SHA-1 state.
fn compress(h: u32[5]&, chunk: const u8[:]) {
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
        if i < 20 { f = (b & c) | (~b & d); k = 0x5A827999; }
        else if i < 40 { f = b ^ c ^ d; k = 0x6ED9EBA1; }
        else if i < 60 { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC; }
        else { f = b ^ c ^ d; k = 0xCA62C1D6; }
        let t = rotl(a, 5) + f + e + k + w[i];
        e = d; d = c; c = rotl(b, 30); b = a; a = t;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e;
}

// The SHA-1 digest of data (FIPS 180-4), which version 5 UUIDs are made of.
fn sha1(data: const u8[:]) -> u8[20] {
    var h: u32[5] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0];
    let whole = data.len - data.len % 64;
    var at = 0;
    while at < whole {
        compress(h, data[at..at + 64]);
        at += 64;
    }
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

// A UUID's 16 bytes from its text form; the namespaces below are constants.
fn parse_uuid(text: const u8[:]) -> u8[16] {
    var out: u8[16] = [0; 16];
    var n = 0;
    var i = 0;
    while i < text.len {
        if text[i] == '-' { i++; continue; }
        let hi, ok_hi = parse_int(text[i..i + 1], 16);
        let lo, ok_lo = parse_int(text[i + 1..i + 2], 16);
        out[n] = (hi * 16 + lo) as! u8;
        n++;
        i += 2;
    }
    return out;
}

// The version 5 UUID of a name in a namespace, in its text form, as Go's
// uuid.NewSHA1 makes it.
fn uuid5(space: const u8[:], name: const u8[:]) -> u8[>..] {
    var data: u8[>..] = [];
    data.append(parse_uuid(space));
    data.append(name);
    var u = sha1(data);
    u[6] = (u[6] & 0x0F) | 0x50;
    u[8] = (u[8] & 0x3F) | 0x80;
    var out: u8[>..] = [];
    for k in 16 {
        if k == 4 || k == 6 || k == 8 || k == 10 { out.push('-'); }
        sha256::format_hex(out, u[k..k + 1]);
    }
    return out;
}

// Where beads' row ids live: one namespace for content rows (comments and
// the like), one for dependency edges. Their parts are joined by a unit
// separator.
let ROW_NAMESPACE = "92da14b5-20a8-5252-8eb2-3839e97b2156";
let DEPENDENCY_NAMESPACE = "bdd74eb9-a20a-554a-985b-54b8f3e64d8b";
let SEP = "\x1f";

// The digest of a row's identifying fields: each as v<length>:<text>, the
// whole hashed with SHA-256, in hex.
fn digest(fields: const (const u8[:])[:]) -> u8[>..] {
    var b: u8[>..] = [];
    for f in fields { format(b, "v", f.len, ":", f); }
    return sha256::hex_digest(b);
}

// The id of the `ordinal`th row of `table` with this digest.
fn row_id(table: const u8[:], ordinal: i64, digest: const u8[:]) -> u8[>..] {
    uuid5(ROW_NAMESPACE, str(table, SEP, ordinal, SEP, digest))
}

// The id of an imported comment: its issue, author, text and time (as
// "2006-01-02 15:04:05" in UTC) identify it.
fn comment_id(issue_id: const u8[:], author: const u8[:], text: const u8[:], created_at: const u8[:]) -> u8[>..] {
    row_id("comments", 0, digest([issue_id, author, text, created_at]))
}

// The id of the dependency edge from issue_id to target.
fn dependency_id(issue_id: const u8[:], target: const u8[:]) -> u8[>..] {
    uuid5(DEPENDENCY_NAMESPACE, str(issue_id, SEP, target))
}
