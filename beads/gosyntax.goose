// Go's JSON syntax errors: what encoding/json says about text that is not
// JSON, word for word, since bd passes those messages on (import's "failed
// to parse JSONL line: invalid character 'b' looking for beginning of object
// key string"). The checker follows Go's scanner state by state.

namespace gosyntax;

import std;

// A byte as Go's quoteChar shows it in a message: in single quotes, with
// strconv.Quote's escapes, and a byte at or above 0x80 read as the code
// point of that value.
fn format_char(out: u8[>..]&, c: u8) {
    out.push('\'');
    if c == '\'' { out.append("\\'"); }
    else if c == '"' { out.push('"'); }
    else if c == '\\' { out.append("\\\\"); }
    else if c == 7 { out.append("\\a"); }
    else if c == 8 { out.append("\\b"); }
    else if c == 12 { out.append("\\f"); }
    else if c == '\n' { out.append("\\n"); }
    else if c == '\r' { out.append("\\r"); }
    else if c == '\t' { out.append("\\t"); }
    else if c == 11 { out.append("\\v"); }
    else if c < 0x20 || c == 0x7F { out.append("\\x"); format_int(out, c, 16, 2, '0'); }
    else if c < 0x80 { out.push(c); }
    else if c < 0xA0 { out.append("\\u00"); format_int(out, c, 16, 2, '0'); }
    else if c == 0xAD { out.append("\\u00ad"); }
    else { out.push(0xC0 | (c >> 6)); out.push(0x80 | (c & 0x3F)); }
    out.push('\'');
}

fn is_space(c: u8) -> bool { c == ' ' || c == '\t' || c == '\n' || c == '\r' }
fn is_digit(c: u8) -> bool { c >= '0' && c <= '9' }
fn is_hex(c: u8) -> bool { is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') }

// Why text is not one JSON value, as Go's json.Valid/Unmarshal says it, or
// "" if it is one. At the end of the text Go's scanner steps once more with
// a space, so a token cut short there is blamed on ' ', and only text that
// stops between tokens is "unexpected end of JSON input".
fn syntax_error(text: const u8[:]) -> u8[>..] {
    // What the scanner expects next, as Go's step functions.
    let BEGIN_VALUE = 0;
    let BEGIN_KEY_OR_EMPTY = 1;      // after {
    let BEGIN_KEY = 2;               // after , in an object
    let BEGIN_VALUE_OR_EMPTY = 3;    // after [
    let END_VALUE = 4;               // after a value or key
    let END_TOP = 5;
    // The containers open around the cursor: true for an object key, false
    // for an array; an object's value is marked by `in_value`.
    var stack: u8[>..<] = [];        // 'k' object at a key, 'v' object at a value, 'a' array
    var state = BEGIN_VALUE;
    var i = 0;

    fn fail(c: u8, context: const u8[:]) -> u8[>..] {
        var out: u8[>..] = [];
        out.append("invalid character ");
        format_char(out, c);
        out.push(' ');
        out.append(context);
        return out;
    }

    while i < text.len {
        let c = text[i];
        if state == END_TOP {
            if !is_space(c) { return fail(c, "after top-level value"); }
            i++;
            continue;
        }
        if is_space(c) { i++; continue; }
        if state == BEGIN_KEY_OR_EMPTY && c == '}' {
            stack.pop();
            state = if stack.len == 0 { END_TOP } else { END_VALUE };
            i++;
            continue;
        }
        if state == BEGIN_VALUE_OR_EMPTY && c == ']' {
            stack.pop();
            state = if stack.len == 0 { END_TOP } else { END_VALUE };
            i++;
            continue;
        }
        if state == BEGIN_KEY_OR_EMPTY || state == BEGIN_KEY {
            if c != '"' { return fail(c, "looking for beginning of object key string"); }
        }
        if state == END_VALUE {
            let top = stack[stack.len - 1];
            if top == 'k' {
                if c != ':' { return fail(c, "after object key"); }
                stack[stack.len - 1] = 'v';
                state = BEGIN_VALUE;
                i++;
                continue;
            }
            if top == 'v' {
                if c == ',' { stack[stack.len - 1] = 'k'; state = BEGIN_KEY; i++; continue; }
                if c == '}' { stack.pop(); state = if stack.len == 0 { END_TOP } else { END_VALUE }; i++; continue; }
                return fail(c, "after object key:value pair");
            }
            if c == ',' { state = BEGIN_VALUE; i++; continue; }
            if c == ']' { stack.pop(); state = if stack.len == 0 { END_TOP } else { END_VALUE }; i++; continue; }
            return fail(c, "after array element");
        }
        // The start of a value (or of a key, which is a string).
        if c == '{' { stack.push('k'); state = BEGIN_KEY_OR_EMPTY; i++; continue; }
        if c == '[' { stack.push('a'); state = BEGIN_VALUE_OR_EMPTY; i++; continue; }
        if c == '"' {
            i++;
            loop {
                if i >= text.len { return str("unexpected end of JSON input"); }
                let s = text[i];
                if s == '"' { i++; break; }
                if s < 0x20 { return fail(s, "in string literal"); }
                if s != '\\' { i++; continue; }
                i++;
                if i >= text.len { return fail(' ', "in string escape code"); }
                let e = text[i];
                if e == 'u' {
                    for k in 4 {
                        i++;
                        if i >= text.len { return fail(' ', "in \\u hexadecimal character escape"); }
                        if !is_hex(text[i]) { return fail(text[i], "in \\u hexadecimal character escape"); }
                    }
                    i++;
                    continue;
                }
                if e != 'b' && e != 'f' && e != 'n' && e != 'r' && e != 't' && e != '\\' && e != '/' && e != '"' {
                    return fail(e, "in string escape code");
                }
                i++;
            }
            state = if stack.len == 0 { END_TOP } else { END_VALUE };
            continue;
        }
        if c == '-' || is_digit(c) {
            if c == '-' {
                i++;
                if i >= text.len { return fail(' ', "in numeric literal"); }
                if !is_digit(text[i]) { return fail(text[i], "in numeric literal"); }
            }
            if text[i] == '0' { i++; } else { while i < text.len && is_digit(text[i]) { i++; } }
            if i < text.len && text[i] == '.' {
                i++;
                if i >= text.len { return fail(' ', "after decimal point in numeric literal"); }
                if !is_digit(text[i]) { return fail(text[i], "after decimal point in numeric literal"); }
                while i < text.len && is_digit(text[i]) { i++; }
            }
            if i < text.len && (text[i] == 'e' || text[i] == 'E') {
                i++;
                if i < text.len && (text[i] == '+' || text[i] == '-') { i++; }
                if i >= text.len { return fail(' ', "in exponent of numeric literal"); }
                if !is_digit(text[i]) { return fail(text[i], "in exponent of numeric literal"); }
                while i < text.len && is_digit(text[i]) { i++; }
            }
            state = if stack.len == 0 { END_TOP } else { END_VALUE };
            continue;
        }
        if c == 't' || c == 'f' || c == 'n' {
            let word = if c == 't' { "true" } else if c == 'f' { "false" } else { "null" };
            for k in 1..word.len {
                // At the end Go's scanner reads one more space.
                let got = if i + k < text.len { text[i + k] } else { ' ' };
                if got != word[k] {
                    var context: u8[>..] = [];
                    format(context, "in literal ", word, " (expecting ");
                    format_char(context, word[k]);
                    context.push(')');
                    return fail(got, context);
                }
            }
            i += word.len;
            state = if stack.len == 0 { END_TOP } else { END_VALUE };
            continue;
        }
        return fail(c, "looking for beginning of value");
    }
    if state != END_TOP { return str("unexpected end of JSON input"); }
    return str();
}

// What kind of JSON value text holds, as Go names it in an unmarshal type
// error: object, array, string, number, bool or null.
fn kind(text: const u8[:]) -> const u8[:] {
    var i = 0;
    while i < text.len && is_space(text[i]) { i++; }
    guard i < text.len else { return ""; }
    let c = text[i];
    if c == '{' { return "object"; }
    if c == '[' { return "array"; }
    if c == '"' { return "string"; }
    if c == 't' || c == 'f' { return "bool"; }
    if c == 'n' { return "null"; }
    return "number";
}
