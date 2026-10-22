// How bd names an issue in its one-line confirmations ("✓ Updated issue:
// bd-1 — Fix it"), ported from cmd/bd's formatFeedbackID: the title is cut
// to output.title-length runes, or left out when that is 0 or less.

namespace feedback;

import std;
import .gojson;

// output.title-length when nothing sets it.
let DEFAULT_TITLE_LENGTH = 255;

// The title cut to max runes, the last one an ellipsis when cut (Go's
// truncateTitle); "" when titles are hidden.
fn title(out: u8[>..]&, t: const u8[:], max: i64) {
    guard t.len > 0 && max > 0 else { return; }
    if gojson::rune_count(t) <= max { out.append(t); return; }
    var i = 0;
    var n = 0;
    while n < max - 1 {
        let cp, size = gojson::decode_rune(t, i);
        if cp == 0xFFFD && size == 1 { push_utf8(out, 0xFFFD); } else { out.append(t[i..i + size]); }
        i += size;
        n++;
    }
    out.append("…");
}

// "id — title", or the id alone when the title is empty or hidden.
fn id(out: u8[>..]&, issue_id: const u8[:], t: const u8[:], max: i64) {
    out.append(issue_id);
    var cut: u8[>..] = [];
    title(cut, t, max);
    if cut.len > 0 { format(out, " — ", cut); }
}

// "id (title)", the form multi-ID messages use.
fn id_paren(out: u8[>..]&, issue_id: const u8[:], t: const u8[:], max: i64) {
    out.append(issue_id);
    var cut: u8[>..] = [];
    title(cut, t, max);
    if cut.len > 0 { format(out, " (", cut, ")"); }
}
