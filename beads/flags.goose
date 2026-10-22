// Command-line flags as cobra and pflag read them, which is what bd's users
// and scripts are written against: `--name value` and `--name=value`, short
// names grouped (`-qv`) or with the value attached (`-p0`, `-t=bug`), flags
// and arguments in any order, `--` ending the flags, and string-slice flags
// that take repeats and commas alike (`-l a,b -l c`). Errors carry pflag's
// own wording.

namespace flags;

import std;

// What a flag holds.
let BOOL = 0;
let STRING = 1;
let SLICE = 2;      // StringSlice: repeats and commas
let ARRAY = 3;      // StringArray: repeats, commas kept
let INT = 4;

struct Spec {
    name: const u8[:],          // the long name, without dashes
    short: u8 = 0,              // the one-letter name, or 0
    kind: i64 = BOOL,
    default: const u8[:] = "",  // as the help text shows it
    usage: const u8[:] = "",
}

// One occurrence of a flag on the command line, in order. A slice flag's
// value is as given, commas and all.
struct Flag { name: const u8[:], value: const u8[:] }

type Strings = const (const u8[:])[:];

// The flag named, from the command's own or the global ones, and whether
// there is one.
fn find_long(specs: const Spec[:], globals: const Spec[:], name: const u8[:]) -> Spec, bool {
    for s in specs { if s.name == name { return s, true; } }
    for s in globals { if s.name == name { return s, true; } }
    return Spec { .. }, false;
}

fn find_short(specs: const Spec[:], globals: const Spec[:], c: u8) -> Spec, bool {
    for s in specs { if s.short == c { return s, true; } }
    for s in globals { if s.short == c { return s, true; } }
    return Spec { .. }, false;
}

// How pflag names a flag in an error: "-e, --estimate" or "--title".
fn format_names(out: u8[>..]&, s: Spec) {
    if s.short != 0 {
        out.push('-');
        out.push(s.short);
        out.append(", ");
    }
    format(out, "--", s.name);
}

// pflag's complaint about a value it cannot read as the flag's kind.
fn check_value(s: Spec, value: const u8[:]) -> u8[>..] {
    if s.kind == INT {
        let n, ok = parse_int(value);
        guard !ok else { return str(); }
        var names: u8[>..] = [];
        format_names(names, s);
        return str("invalid argument \"", value, "\" for \"", names, "\" flag: strconv.ParseInt: parsing \"",
                   value, "\": invalid syntax");
    }
    if s.kind == BOOL && !is_bool_text(value) {
        var names: u8[>..] = [];
        format_names(names, s);
        return str("invalid argument \"", value, "\" for \"", names, "\" flag: strconv.ParseBool: parsing \"",
                   value, "\": invalid syntax");
    }
    return str();
}

// The spellings Go's strconv.ParseBool accepts.
fn is_bool_text(v: const u8[:]) -> bool {
    contains(["1", "t", "T", "TRUE", "true", "True", "0", "f", "F", "FALSE", "false", "False"], v)
}

fn bool_text_true(v: const u8[:]) -> bool { contains(["1", "t", "T", "TRUE", "true", "True"], v) }

// Reads argv against the command's flags and the global ones: the flags
// given, in order, onto `flags`, and everything else onto `args`. The error,
// in pflag's words, or "".
fn parse(specs: const Spec[:], globals: const Spec[:], argv: Strings,
         flags: Flag[>..]&, args: (const u8[:])[>..]&) -> u8[>..] {
    var i = 0;
    while i < argv.len {
        let a = argv[i];
        i++;
        if a == "--" {
            for rest in argv[i..] { args.push(rest); }
            break;
        }
        if a.len < 2 || a[0] != '-' {
            args.push(a);
            continue;
        }
        if a[1] == '-' {
            let body = a[2..];
            let eq = find(body, "=");
            let name = if eq >= 0 { body[..eq] } else { body };
            let s, known = find_long(specs, globals, name);
            guard known else { return str("unknown flag: --", name); }
            if eq >= 0 {
                let value = body[eq + 1..];
                let bad = check_value(s, value);
                guard bad.len == 0 else { return bad; }
                flags.push(Flag { name: s.name, value: value });
            } else if s.kind == BOOL {
                flags.push(Flag { name: s.name, value: "true" });
            } else {
                guard i < argv.len else { return str("flag needs an argument: --", name); }
                let value = argv[i];
                i++;
                let bad = check_value(s, value);
                guard bad.len == 0 else { return bad; }
                flags.push(Flag { name: s.name, value: value });
            }
            continue;
        }
        // A group of short names: bools until one that takes a value, which
        // takes the rest of the group, or else the next argument.
        var j = 1;
        while j < a.len {
            let c = a[j];
            let s, known = find_short(specs, globals, c);
            guard known else { return str("unknown shorthand flag: '", c, "' in ", a); }
            j++;
            if j < a.len && a[j] == '=' {
                let value = a[j + 1..];
                let bad = check_value(s, value);
                guard bad.len == 0 else { return bad; }
                flags.push(Flag { name: s.name, value: value });
                break;
            }
            if s.kind == BOOL {
                flags.push(Flag { name: s.name, value: "true" });
                continue;
            }
            if j < a.len {
                let value = a[j..];
                let bad = check_value(s, value);
                guard bad.len == 0 else { return bad; }
                flags.push(Flag { name: s.name, value: value });
                break;
            }
            guard i < argv.len else { return str("flag needs an argument: '", c, "' in -", c); }
            let value = argv[i];
            i++;
            let bad = check_value(s, value);
            guard bad.len == 0 else { return bad; }
            flags.push(Flag { name: s.name, value: value });
            break;
        }
    }
    return str();
}

// The first word that is not a flag or a flag's value: the command name,
// and its position in argv, or -1. Only the global flags are known here.
fn command_word(globals: const Spec[:], argv: Strings) -> i64 {
    var i = 0;
    while i < argv.len {
        let a = argv[i];
        if a == "--" { return if i + 1 < argv.len { i + 1 } else { -1 }; }
        if a.len < 2 || a[0] != '-' { return i; }
        i++;
        if a[1] == '-' {
            guard find(a, "=") < 0 else { continue; }
            let s, known = find_long(globals, globals, a[2..]);
            if known && s.kind != BOOL { i++; }
        } else {
            // A group ending in a short flag that takes a value takes the
            // next argument when nothing follows it in the group.
            let s, known = find_short(globals, globals, a[a.len - 1]);
            if known && s.kind != BOOL && a.len == 2 { i++; }
        }
    }
    return -1;
}

// --- reading the result --------------------------------------------------------

fn changed(fs: const Flag[:], name: const u8[:]) -> bool { fs.any() { it.name == name } }

// The last value given for the flag, or `otherwise`.
fn get_string(fs: const Flag[:], name: const u8[:], otherwise: const u8[:] = "") -> const u8[:] {
    var i = fs.len - 1;
    while i >= 0 {
        if fs[i].name == name { return fs[i].value; }
        i--;
    }
    return otherwise;
}

fn get_bool(fs: const Flag[:], name: const u8[:]) -> bool {
    let v = get_string(fs, name, "false");
    return bool_text_true(v);
}

fn get_int(fs: const Flag[:], name: const u8[:], otherwise: i64 = 0) -> i64 {
    guard changed(fs, name) else { return otherwise; }
    let n, ok = parse_int(get_string(fs, name));
    return n;
}

// Every value given for a slice flag, commas split as pflag's CSV reading
// splits them, onto out.
fn strings(fs: const Flag[:], name: const u8[:], out: (const u8[:])[>..]&) {
    for f in fs {
        if f.name == name {
            if f.value.len > 0 { each_split(f.value, ',') { out.push(it); }; }
        }
    }
}

// Every value given for an array flag, as given.
fn array(fs: const Flag[:], name: const u8[:], out: (const u8[:])[>..]&) {
    for f in fs { if f.name == name { out.push(f.value); } }
}
