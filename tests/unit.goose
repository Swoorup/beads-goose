// Unit tests for what the golden corpus does not reach: the calendar and
// RFC 3339 edge cases, SHA-256 vectors, the enum helpers, Go's JSON layout,
// and the command line, which is a function and is tested as one.

import std;
import beads from "../beads";
import beads.sha256;
import beads.gotime;
import beads.gojson;
import beads.types;
import beads.cli;
import .check;

fn test_sha256() {
    check::expect_eq(sha256::hex_digest(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "sha256 of nothing");
    check::expect_eq(sha256::hex_digest("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256 of abc");
    // 56 bytes: the length no longer fits the first block.
    check::expect_eq(sha256::hex_digest("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
                     "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1", "sha256 across two blocks");
    var million: u8[>..] = [];
    for i in 1000000 { million.push('a'); }
    check::expect_eq(sha256::hex_digest(million), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0", "sha256 of a million a's");
}

fn rfc3339(t: gotime::Time) -> u8[>..] {
    var out: u8[>..] = [];
    gotime::format(out, t);
    return out;
}

fn roundtrip(s: const u8[:]) -> u8[>..] {
    let t, ok = gotime::parse(s);
    check::expect(ok, str("parses: ", s));
    return rfc3339(t);
}

fn test_time() {
    check::expect(gotime::is_zero(gotime::Time { .. }), "a default Time is Go's zero time");
    check::expect_eq(rfc3339(gotime::Time { .. }), "0001-01-01T00:00:00Z", "the zero time");
    check::expect_eq(rfc3339(gotime::from_unix(0)), "1970-01-01T00:00:00Z", "the epoch");
    check::expect_eq(rfc3339(gotime::from_unix(951782400)), "2000-02-29T00:00:00Z", "a leap day");
    check::expect_eq(rfc3339(gotime::from_unix(-1, 500000000)), "1969-12-31T23:59:59.5Z", "before the epoch");
    check::expect_eq(roundtrip("2026-10-22T13:17:08Z"), "2026-10-22T13:17:08Z", "UTC");
    check::expect_eq(roundtrip("2026-10-22T13:17:08.000Z"), "2026-10-22T13:17:08Z", "a zero fraction is dropped");
    check::expect_eq(roundtrip("2026-10-22T13:17:08.120Z"), "2026-10-22T13:17:08.12Z", "trailing zeros are dropped");
    check::expect_eq(roundtrip("2026-10-22T13:17:08+00:00"), "2026-10-22T13:17:08Z", "a zero offset is Z");
    check::expect_eq(roundtrip("2026-10-22T13:17:08-04:00"), "2026-10-22T13:17:08-04:00", "an offset is kept");
    check::expect_eq(roundtrip("2026-10-22T13:17:08.1234567899Z"), "2026-10-22T13:17:08.123456789Z", "past nine digits is dropped");
    let a, ok_a = gotime::parse("2026-10-22T13:17:08-04:00");
    let b, ok_b = gotime::parse("2026-10-22T17:17:08Z");
    check::expect(gotime::equal(a, b) && !gotime::before(a, b), "offsets name the same instant");
    check::expect_eq(rfc3339(gotime::utc(a)), "2026-10-22T17:17:08Z", "utc");
    for bad in ["", "2026-10-22", "2026-10-22T13:17:08", "2026-10-22t13:17:08Z", "2026-13-01T00:00:00Z",
                "2026-02-29T00:00:00Z", "2026-10-22T24:00:00Z", "2026-10-22T13:17:08+0400",
                "2026-10-22T13:17:08.Z", "2026-10-22T13:17:08+24:00", "+2026-10-22T13:17:08Z"] {
        let t, ok = gotime::parse(bad);
        check::expect(!ok, str("rejects ", bad));
    }
}

fn test_types() {
    check::expect_eq(types::normalize_issue_type("Enhancement"), "feature", "enhancement is a feature");
    check::expect_eq(types::normalize_issue_type("ADR"), "decision", "adr is a decision");
    check::expect_eq(types::normalize_issue_type("timebox"), "spike", "timebox is a spike");
    check::expect_eq(types::normalize_issue_type("User_Story"), "story", "user_story is a story");
    check::expect_eq(types::normalize_issue_type("ms"), "milestone", "ms is a milestone");
    check::expect_eq(types::normalize_issue_type("convoy"), "convoy", "anything else is itself");
    check::expect(types::is_failure_close("Won't Fix: out of scope"), "won't fix is a failure");
    check::expect(types::is_failure_close("TIMEOUT"), "case does not matter");
    check::expect(!types::is_failure_close("shipped"), "shipped is not a failure");
    check::expect(!types::is_failure_close(""), "no reason is not a failure");
    check::expect_eq(types::builtin_status_category("open"), "active", "open is active");
    check::expect_eq(types::builtin_status_category("hooked"), "wip", "hooked is wip");
    check::expect_eq(types::builtin_status_category("closed"), "done", "closed is done");
    check::expect_eq(types::builtin_status_category("pinned"), "frozen", "pinned is frozen");
    check::expect_eq(types::builtin_status_category("review"), "unspecified", "custom statuses are unspecified");
    check::expect(types::affects_ready_work("parent-child") && !types::is_blocking_edge("parent-child"),
                  "parent-child holds back ready work without blocking");
    check::expect(types::is_blocking_edge("waits-for") && !types::affects_ready_work("related"), "blocking edges");
    check::expect(types::is_valid_dependency_type("my-custom-edge") && !types::is_well_known_dependency_type("my-custom-edge"),
                  "custom dependency types are valid");
    check::expect(!types::is_valid_dependency_type("") && !types::is_valid_dependency_type("x123456789x123456789x123456789xyz"),
                  "dependency types are 1 to 32 bytes");
    check::expect(types::is_valid_mol_type("") && types::is_valid_mol_type("patrol") && !types::is_valid_mol_type("x"), "mol types");
    check::expect(types::is_valid_wisp_type("gc_report") && !types::is_valid_wisp_type("x"), "wisp types");
    check::expect(types::is_valid_work_type("open_competition") && !types::is_valid_work_type("x"), "work types");
    check::expect_eq(types::normalize_storage_class("versioned"), "", "versioned is stored as empty");

    var i = types::Issue { id: "bd-1", title: "t", status: "review", issue_type: "convoy", priority: 2, .. };
    check::expect_eq(types::validate(i), "invalid status: review", "custom status needs configuring");
    check::expect_eq(types::validate(i, ["review"]), "invalid issue type: convoy", "custom type needs configuring");
    check::expect_eq(types::validate(i, ["review"], ["convoy"]), "", "configured custom status and type");
    check::expect_eq(types::validate_for_import(i, ["review"]), "", "import trusts custom types");
    check::expect_eq(types::effective_storage_class(i), "versioned", "durable by default");
    i.ephemeral = true;
    check::expect_eq(types::effective_storage_class(i), "ephemeral", "wisps are ephemeral");
    let d = types::with_defaults(types::Issue { id: "x", title: "t", priority: 0, .. });
    check::expect_eq(d.status, "open", "default status");
    check::expect_eq(d.issue_type, "task", "default type");
    check::expect_eq(d.priority, 0, "priority 0 is kept");
}

fn test_json_layout() {
    var a: u8[>..] = [];
    gojson::format_indented(a, "{\"a\":[1,{\"b\":\"x,y:{\\\"}\"}],\"e\":{},\"f\":[]}");
    check::expect_eq(a, """
        {
          "a": [
            1,
            {
              "b": "x,y:{\"}"
            }
          ],
          "e": {},
          "f": []
        }
        """, "indented as Go's json.Indent");
    var m: u8[>..] = [];
    var members = [gojson::Member { key: "zeta", value: "1" }, gojson::Member { key: "alpha", value: "\"a\"" },
                   gojson::Member { key: "Beta", value: "true" }];
    gojson::format_map(m, members);
    check::expect_eq(m, "{\"Beta\":true,\"alpha\":\"a\",\"zeta\":1}", "map keys in byte order");
    var raw: u8[>..] = [];
    check::expect(!gojson::format_raw(raw, "{\"a\":"), "malformed raw JSON is refused");
    check::expect_eq(raw.len, 0, "and nothing is written");
}

// Runs the command line on args: its exit code, stdout and stderr.
fn bd(args: const (const u8[:])[:], envelope: bool = false, commit: const u8[:] = "", branch: const u8[:] = "")
        -> i64, u8[>..], u8[>..] {
    var out: u8[>..] = [];
    var err: u8[>..] = [];
    let env = cli::Env { json_envelope: envelope, commit: commit, branch: branch, .. };
    let code = cli::run(args, env, out, err);
    return code, out, err;
}

fn test_cli() {
    {
        let code, out, err = bd(["version"]);
        check::expect_eq(code, 0, "bd version succeeds");
        check::expect_eq(out, "bd version 1.3.0 (goose)\n", "bd version");
    }
    {
        let code, out, err = bd(["-V"]);
        check::expect_eq(out, "bd version 1.3.0 (goose)\n", "bd -V");
    }
    {
        let code, out, err = bd(["version", "--json"]);
        check::expect_eq(out, "{\n  \"build\": \"goose\",\n  \"schema_version\": 1,\n  \"version\": \"1.3.0\"\n}\n", "bd version --json");
    }
    {
        let code, out, err = bd(["--json", "version"], true);
        check::expect_eq(out, "{\n  \"data\": {\n    \"build\": \"goose\",\n    \"version\": \"1.3.0\"\n  },\n  \"schema_version\": 1\n}\n",
                         "bd version --json with BD_JSON_ENVELOPE=1");
    }
    {
        let code, out, err = bd(["version"], false, "9d6fff760b7a314b476539198504d77ce0959656", "main");
        check::expect_eq(out, "bd version 1.3.0 (goose: main@9d6fff760b7a)\n", "bd version with commit and branch");
    }
    {
        let code, out, err = bd(["version"], false, "9d6fff760b7a314b476539198504d77ce0959656");
        check::expect_eq(out, "bd version 1.3.0 (goose: 9d6fff760b7a)\n", "bd version with a commit only");
    }
    {
        let code, out, err = bd(["-V"], false, "9d6fff760b7a314b476539198504d77ce0959656", "main");
        check::expect_eq(out, "bd version 1.3.0 (goose)\n", "bd -V names no commit, as in bd");
    }
    {
        let code, out, err = bd(["version", "--json"], false, "abc", "main");
        check::expect_eq(out, "{\n  \"branch\": \"main\",\n  \"build\": \"goose\",\n  \"commit\": \"abc\",\n  \"schema_version\": 1,\n  \"version\": \"1.3.0\"\n}\n",
                         "bd version --json with commit and branch");
    }
    {
        let code, out, err = bd(["version", "bd-123"]);
        check::expect_eq(code, 1, "bd version takes no arguments");
        check::expect_eq(err, "Error: bd version prints bd's own version information and takes no arguments.\nDid you mean:  bd versions bd-123\n",
                         "bd version suggests bd versions");
    }
    {
        let code, out, err = bd(["frobnicate"]);
        check::expect_eq(code, 1, "an unknown command fails");
        check::expect_eq(err, "Error: unknown command \"frobnicate\" for \"bd\"\nRun 'bd --help' for usage.\n", "cobra's message");
    }
    {
        let code, out, err = bd([]);
        check::expect(code == 0 && find(out, "Available Commands:") >= 0, "bd alone prints help");
    }
}

fn main() {
    test_sha256();
    test_time();
    test_types();
    test_json_layout();
    test_cli();
    check::report("unit");
}
