// Issue text as bd show prints it on a terminal that is not one: beads hands
// it to glamour with its no-TTY style at 80 columns, which keeps the source's
// own line breaks, word-wraps long lines, sets every line in a two-column
// margin padded to the full width, and separates blocks with a blank line.
// Markup mostly stays as written; bullets become "•", inline code loses its
// backticks, links become "text url" and fenced code is indented. This is
// the subset beads' issue text uses; anything else is passed through.

namespace markdown;

import std;
import .gojson;

// The width glamour wraps to off a terminal, margin included, and the margin.
let WIDTH = 78;
let MARGIN = 2;

fn is_alnum(c: u8) -> bool { (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c >= 0x80 }

fn is_blank(s: const u8[:]) -> bool { s.all() { it == ' ' || it == '\t' } }

fn is_fence(s: const u8[:]) -> bool { starts_with(trim_start(s), "```") || starts_with(trim_start(s), "~~~") }

fn is_heading(s: const u8[:]) -> bool { s.len > 0 && s[0] == '#' }

// The width of a list marker that opens s ("- ", "* ", "+ ", "1. "), or 0.
fn list_marker(s: const u8[:]) -> i64 {
    if s.len >= 2 && (s[0] == '-' || s[0] == '*' || s[0] == '+') && s[1] == ' ' { return 2; }
    var i = 0;
    while i < s.len && s[i] >= '0' && s[i] <= '9' { i++; }
    if i > 0 && i + 1 < s.len && (s[i] == '.' || s[i] == ')') && s[i + 1] == ' ' { return i + 2; }
    return 0;
}

// The line with its inline markup as glamour's no-TTY style shows it.
recursive fn inline(out: u8[>..]&, s: const u8[:]) {
    var i = 0;
    while i < s.len {
        let c = s[i];
        if c == '`' {
            let end = find(s[i + 1..], "`");
            if end >= 0 {
                out.append(s[i + 1..i + 1 + end]);
                i += end + 2;
                continue;
            }
        }
        if c == '[' {
            let close = find(s[i..], "](");
            if close > 0 {
                let rest = s[i + close + 2..];
                let paren = find(rest, ")");
                if paren >= 0 {
                    out.append(s[i + 1..i + close]);
                    out.push(' ');
                    out.append(rest[..paren]);
                    i += close + 2 + paren + 1;
                    continue;
                }
            }
        }
        // _word_ is emphasis, shown with asterisks; an underscore inside a
        // word (snake_case) is not.
        if c == '_' && (i == 0 || !is_alnum(s[i - 1])) && i + 1 < s.len && s[i + 1] != ' ' && s[i + 1] != '_' {
            var j = i + 1;
            while j < s.len && !(s[j] == '_' && s[j - 1] != ' ' && (j + 1 == s.len || !is_alnum(s[j + 1]))) { j++; }
            if j < s.len {
                out.push('*');
                inline(out, s[i + 1..j]);
                out.push('*');
                i = j + 1;
                continue;
            }
        }
        out.push(c);
        i++;
    }
}

// Appends one output line: margin, text, and padding to the full width.
fn emit(out: u8[>..]&, first: bool&, indent: const u8[:], text: const u8[:]) {
    if !first { out.push('\n'); }
    first = false;
    let start = out.len;
    for k in MARGIN { out.push(' '); }
    out.append(indent);
    out.append(text);
    let width = gojson::rune_count(out[start..]);
    for k in max(0, WIDTH - width) { out.push(' '); }
}

// Appends text word-wrapped to the width left after the margin and indent;
// continuation lines get `hang` instead of `indent`.
fn wrapped(out: u8[>..]&, first: bool&, indent: const u8[:], hang: const u8[:], text: const u8[:]) {
    let room = WIDTH - MARGIN - gojson::rune_count(indent);
    var line: u8[>..] = [];
    var lead = indent;
    each_split(text, ' ') { word =>
        if line.len > 0 && gojson::rune_count(line) + 1 + gojson::rune_count(word) > room {
            emit(out, first, lead, line);
            lead = hang;
            line.clear();
        }
        if line.len > 0 { line.push(' '); }
        line.append(word);
    };
    emit(out, first, lead, line);
}

// The text rendered. "" stays "".
fn render(out: u8[>..]&, text: const u8[:]) {
    var lines: (const u8[:])[>..] = [];
    each_split(text, '\n') { lines.push(it); };
    while lines.len > 0 && is_blank(lines[lines.len - 1]) { lines.pop(); }
    out.push('\n');
    var first = true;
    var i = 0;
    // What the previous line was, so a change of block puts a blank line between.
    var prev = 0;   // 0: none or blank, 1: paragraph, 2: list, 3: heading
    while i < lines.len {
        let l = lines[i];
        if is_blank(l) {
            if prev != 0 { emit(out, first, "", ""); }
            prev = 0;
            i++;
            continue;
        }
        if is_fence(l) {
            if prev != 0 { emit(out, first, "", ""); }
            i++;
            while i < lines.len && !is_fence(lines[i]) {
                emit(out, first, "  ", lines[i]);
                i++;
            }
            i++;
            prev = 3;
            continue;
        }
        var expanded: u8[>..] = [];
        inline(expanded, l);
        if is_heading(l) {
            if prev != 0 { emit(out, first, "", ""); }
            emit(out, first, "", expanded);
            prev = 3;
        } else {
            let m = list_marker(l);
            if m > 0 {
                if prev == 1 || prev == 3 { emit(out, first, "", ""); }
                var bullet: u8[>..] = [];
                if l[0] == '-' || l[0] == '*' || l[0] == '+' { bullet.append("• "); } else { bullet.append(l[..m]); }
                var body: u8[>..] = [];
                inline(body, l[m..]);
                var hang: u8[>..] = [];
                for k in gojson::rune_count(bullet) { hang.push(' '); }
                wrapped(out, first, bullet, hang, body);
                prev = 2;
            } else {
                if prev == 2 || prev == 3 { emit(out, first, "", ""); }
                wrapped(out, first, "", "", expanded);
                prev = 1;
            }
        }
        i++;
    }
    out.append("\n\n");
}
