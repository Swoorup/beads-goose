// A small test harness: expectations that count and report failures, and a
// summary that sets the exit code.

namespace check;

import std;

var checks = 0;
var failures = 0;

fn expect(ok: bool, what: const u8[:]) {
    checks++;
    if !ok {
        failures++;
        print("FAIL ", what);
    }
}

// got == want, printing both when they differ. Any two comparable values:
// a string builder against a literal compares the text.
fn expect_eq(got, want, what: const u8[:]) {
    checks++;
    if !(got == want) {
        failures++;
        print("FAIL ", what, "\n  got:  ", got, "\n  want: ", want);
    }
}

// Prints the tally and exits non-zero if anything failed.
fn report(suite: const u8[:]) {
    print(suite, ": ", checks - failures, "/", checks, " checks passed");
    if failures > 0 { exit(1); }
}
