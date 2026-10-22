// Hash IDs, as beads mints them (internal/idgen and issueops'
// GenerateIssueIDInTable): `prefix-` and a few base36 characters of the
// SHA-256 of the issue's title, description, creator and creation time. The
// length grows with the number of issues so collisions stay unlikely, and
// a taken candidate is retried with a nonce, then a longer length.

namespace idgen;

import std;
import math;
import .sha256;

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
