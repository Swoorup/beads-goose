// Unit tests for what import builds on: Dolt's JSON normalization and the
// deterministic row ids, against values bd 1.3.0 wrote.

namespace import_cases;

import std;
import beads from "../beads";
import beads.doltjson;
import beads.rowid;
import beads.sha256;
import beads.gosyntax;
import .check;

fn mysql(text: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    check::expect(doltjson::mysql_text(out, text), str("is JSON: ", text));
    return out;
}

fn compact(text: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    check::expect(doltjson::go_compact(out, text), str("is JSON: ", text));
    return out;
}

fn test_doltjson() {
    check::expect_eq(compact("""{"a":1,"a":2,"b":{"z":1,"y":[1.0,2.50,1e3,-0,0.1,1e21,123456789012345678901234,1E-7,"\u00e9<>&\u2028"]}}"""),
                     """{"a":2,"b":{"y":[1,2.5,1000,0,0.1,1000000000000000000000,123456789012345690000000,0.0000001,"é\u003c\u003e\u0026\u2028"],"z":1}}""",
                     "issue metadata: last key wins, keys by length, numbers as doubles");
    check::expect_eq(compact("""{"i":9007199254740993,"n":-5,"neg":-1.25e-10,"x":12345678901234567,"f":0.30000000000000004,"e":1e20}"""),
                     """{"e":100000000000000000000,"f":0.30000000000000004,"i":9007199254740992,"n":-5,"x":12345678901234568,"neg":-0.000000000125}""",
                     "integers past 2^53 round as doubles");
    check::expect_eq(compact("""[3,{"b":1,"a":true}]"""), """[3,{"a":true,"b":1}]""", "arrays keep their order");
    check::expect_eq(compact("\"{\\\"x\\\": 1}\""), "\"{\\\"x\\\": 1}\"", "a string stays a string");
    check::expect_eq(mysql("""{"zz":1,"a":[1,2.50],"bb":1e3,"c":"é<\u00e9","a":3}"""),
                     """{"a": 3, "c": "é<é", "bb": 1000, "zz": 1}""", "dependency metadata as MySQL text");
    check::expect_eq(mysql("""{"s":"a\nb\u0001\"\\/\t","u":"\ud83d\ude00","i":9007199254740993,"o":{},"l":[],"t":true,"nn":null}"""),
                     """{"i": 9007199254740992, "l": [], "o": {}, "s": "a\nb\u0001\"\\/\t", "t": true, "u": "😀", "nn": null}""",
                     "MySQL text escapes as Go does, without HTML escapes");
    var out: u8[>..] = [];
    check::expect(!doltjson::mysql_text(out, "{\"a\":") && out.len == 0, "not JSON");
}

fn test_rowid() {
    var hex: u8[>..] = [];
    sha256::format_hex(hex, rowid::sha1("abc"));
    check::expect_eq(hex, "a9993e364706816aba3e25717850c26c9cd0d89d", "sha1 of abc");
    hex.clear();
    sha256::format_hex(hex, rowid::sha1("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"));
    check::expect_eq(hex, "84983e441c3bd26ebaae4aa1f95129e5e54670f1", "sha1 across two blocks");
    check::expect_eq(rowid::uuid5("6ba7b810-9dad-11d1-80b4-00c04fd430c8", "python.org"), "886313e1-3b8a-5372-9b90-0c9aee199e5d",
                     "uuid5 in the DNS namespace");
    check::expect_eq(rowid::comment_id("t-6", "me", "hello", "2024-01-01 00:00:00"), "37144eda-ee92-5d3f-802d-405763dfa071",
                     "an imported comment's id, as bd 1.3.0 derived it");
}

// Go's own messages for text that is not JSON (encoding/json, go1.24).
fn test_syntax_errors() {
    check::expect_eq(gosyntax::syntax_error("{bad"), "invalid character 'b' looking for beginning of object key string", "{bad");
    check::expect_eq(gosyntax::syntax_error("{\"a\" 1}"), "invalid character '1' after object key", "{\"a\" 1}");
    check::expect_eq(gosyntax::syntax_error("{\"a\":1 x"), "invalid character 'x' after object key:value pair", "{\"a\":1 x");
    check::expect_eq(gosyntax::syntax_error("[1 2]"), "invalid character '2' after array element", "[1 2]");
    check::expect_eq(gosyntax::syntax_error("1 2"), "invalid character '2' after top-level value", "1 2");
    check::expect_eq(gosyntax::syntax_error("\"a\x01\""), "invalid character '\\x01' in string literal", "\"a\x01\"");
    check::expect_eq(gosyntax::syntax_error("\"\\q\""), "invalid character 'q' in string escape code", "\"\\q\"");
    check::expect_eq(gosyntax::syntax_error("\"\\u12g4\""), "invalid character 'g' in \\u hexadecimal character escape", "\"\\u12g4\"");
    check::expect_eq(gosyntax::syntax_error("-x"), "invalid character 'x' in numeric literal", "-x");
    check::expect_eq(gosyntax::syntax_error("1.x"), "invalid character 'x' after decimal point in numeric literal", "1.x");
    check::expect_eq(gosyntax::syntax_error("1ex"), "invalid character 'x' in exponent of numeric literal", "1ex");
    check::expect_eq(gosyntax::syntax_error("tru"), "invalid character ' ' in literal true (expecting 'e')", "tru");
    check::expect_eq(gosyntax::syntax_error("trux"), "invalid character 'x' in literal true (expecting 'e')", "trux");
    check::expect_eq(gosyntax::syntax_error("nul!"), "invalid character '!' in literal null (expecting 'l')", "nul!");
    check::expect_eq(gosyntax::syntax_error("{\"a\":"), "unexpected end of JSON input", "{\"a\":");
    check::expect_eq(gosyntax::syntax_error(""), "unexpected end of JSON input", "");
    check::expect_eq(gosyntax::syntax_error("  "), "unexpected end of JSON input", "  ");
    check::expect_eq(gosyntax::syntax_error("]"), "invalid character ']' looking for beginning of value", "]");
    check::expect_eq(gosyntax::syntax_error("\xe9"), "invalid character 'é' looking for beginning of value", "\xe9");
    check::expect_eq(gosyntax::syntax_error("\x7f"), "invalid character '\\x7f' looking for beginning of value", "\x7f");
    check::expect_eq(gosyntax::syntax_error("{\"a\":1,}"), "invalid character '}' looking for beginning of object key string", "{\"a\":1,}");
    check::expect_eq(gosyntax::syntax_error("[1,]"), "invalid character ']' looking for beginning of value", "[1,]");
    check::expect_eq(gosyntax::syntax_error("{}"), "", "{}");
    check::expect_eq(gosyntax::syntax_error("[]"), "", "[]");
    check::expect_eq(gosyntax::syntax_error("{\"a\":[1,{\"b\":null}]}"), "", "{\"a\":[1,{\"b\":null}]}");
    check::expect_eq(gosyntax::syntax_error("'x'"), "invalid character '\\'' looking for beginning of value", "'x'");
    check::expect_eq(gosyntax::syntax_error("{\"a\":1}}"), "invalid character '}' after top-level value", "{\"a\":1}}");
    check::expect_eq(gosyntax::syntax_error("01"), "invalid character '1' after top-level value", "01");
    check::expect_eq(gosyntax::syntax_error("-"), "invalid character ' ' in numeric literal", "-");
    check::expect_eq(gosyntax::syntax_error("1."), "invalid character ' ' after decimal point in numeric literal", "1.");
    check::expect_eq(gosyntax::syntax_error("1e"), "invalid character ' ' in exponent of numeric literal", "1e");
    check::expect_eq(gosyntax::syntax_error("1e+"), "invalid character ' ' in exponent of numeric literal", "1e+");
    check::expect_eq(gosyntax::syntax_error("\"\\"), "invalid character ' ' in string escape code", "\"\\");
    check::expect_eq(gosyntax::syntax_error("\"\\u1"), "invalid character ' ' in \\u hexadecimal character escape", "\"\\u1");
    check::expect_eq(gosyntax::syntax_error("\"ab"), "unexpected end of JSON input", "\"ab");
    check::expect_eq(gosyntax::syntax_error("fals"), "invalid character ' ' in literal false (expecting 'e')", "fals");
    check::expect_eq(gosyntax::syntax_error("n"), "invalid character ' ' in literal null (expecting 'u')", "n");
    check::expect_eq(gosyntax::syntax_error("{\"a\":tr"), "invalid character ' ' in literal true (expecting 'u')", "{\"a\":tr");
    check::expect_eq(gosyntax::syntax_error("\x85"), "invalid character '\\u0085' looking for beginning of value", "\x85");
    check::expect_eq(gosyntax::syntax_error("\xad"), "invalid character '\\u00ad' looking for beginning of value", "\xad");
    check::expect_eq(gosyntax::syntax_error("\"\t\""), "invalid character '\\t' in string literal", "\"\t\"");
    check::expect_eq(gosyntax::kind(" [1]"), "array", "kind of an array");
    check::expect_eq(gosyntax::kind("12"), "number", "kind of a number");
}

fn run() {
    test_doltjson();
    test_rowid();
    test_syntax_errors();
}
