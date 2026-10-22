// Hash IDs, as beads mints them (internal/idgen and issueops'
// GenerateIssueIDInTable): `prefix-` and a few base36 characters of the
// SHA-256 of the issue's title, description, creator and creation time. The
// length grows with the number of issues so collisions stay unlikely, and
// a taken candidate is retried with a nonce, then a longer length.

namespace idgen;

import std;
import math;
import .sha256;
import .sha1;

let BASE36 = "0123456789abcdefghijklmnopqrstuvwxyz";

let MIN_LENGTH = 3;
let MAX_LENGTH = 8;
let MAX_COLLISION_PROB = 0.25;

// How many leading hash bytes make an ID of each length (Go's switch).
fn hash_bytes(length: i64) -> i64 {
    match length {
        3 => 2,
        4 => 3,
        5, 6 => 4,
        7, 8 => 5,
        _ => 3,
    }
}

// bytes as a big-endian number in base36, zero-padded to `length` and cut
// to its last `length` digits (Go's EncodeBase36). At most 8 bytes.
fn encode_base36(out: u8[>..]&, bytes: const u8[:], length: i64) {
    var n: u64 = 0;
    for b in bytes { n = (n << 8) | b; }
    var digits: u8[..16] = [];
    while n > 0 {
        digits.push(BASE36[(n % 36) as! i64]);
        n = n / 36;
    }
    for i in max(0, length - digits.len) { out.push('0'); }
    var i = min(digits.len, length) - 1;
    while i >= 0 {
        out.push(digits[i]);
        i--;
    }
}

// One candidate ID.
fn hash_id(prefix: const u8[:], title: const u8[:], description: const u8[:], creator: const u8[:],
           unix_nano: i64, length: i64, nonce: i64) -> u8[>..] {
    var content: u8[>..] = [];
    format(content, title, "|", description, "|", creator, "|", unix_nano, "|", nonce);
    let digest = sha256::digest(content);
    var id: u8[>..] = [];
    format(id, prefix, "-");
    encode_base36(id, digest[..hash_bytes(length)], length);
    return id;
}

// The shortest length in [min, max] at which n random IDs collide with
// probability at most `prob` (the birthday bound), else max.
fn adaptive_length(n: i64, lo: i64 = MIN_LENGTH, hi: i64 = MAX_LENGTH, prob: f64 = MAX_COLLISION_PROB) -> i64 {
    for length in lo..hi + 1 {
        let total = pow(36.0, length as f64);
        let p = 1.0 - exp(-((n * n) as f64) / (2.0 * total));
        if p <= prob { return length; }
    }
    return hi;
}

// The namespace of beads' dependency edge IDs (internal/storage/depid).
let EDGE_NAMESPACE: u8[16] = [0xbd, 0xd7, 0x4e, 0xb9, 0xa2, 0x0a, 0x55, 0x4a,
                              0x98, 0x5b, 0x54, 0xb8, 0xf3, 0xe6, 0x4d, 0x8b];

// The ID beads gives the edge from an issue to its target, as bytes: a
// version 5 UUID of the two joined by a unit separator, so the same edge has
// the same ID in every clone. Dolt keeps edges in this order, and bd show
// lists them in it.
fn edge_key(issue_id: const u8[:], target: const u8[:]) -> u8[16] {
    var name: u8[>..] = [];
    name.append(EDGE_NAMESPACE[..]);
    format(name, issue_id, "\x1f", target);
    let d = sha1::digest(name);
    var b: u8[16] = [0; 16];
    for k in 16 { b[k] = d[k]; }
    b[6] = (b[6] & 0x0f) | 0x50;
    b[8] = (b[8] & 0x3f) | 0x80;
    return b;
}

// The edge's ID in its text form.
fn edge_id(issue_id: const u8[:], target: const u8[:]) -> u8[>..] {
    let b = edge_key(issue_id, target);
    var out: u8[>..] = [];
    let hex = "0123456789abcdef";
    for k in 16 {
        if k == 4 || k == 6 || k == 8 || k == 10 { out.push('-'); }
        out.push(hex[(b[k] >> 4) as i64]);
        out.push(hex[(b[k] & 0x0f) as i64]);
    }
    return out;
}
