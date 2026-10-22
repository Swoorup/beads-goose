// bd export: the issues (and, when asked, the memories) as JSONL, one
// record per line, to stdout or a file.

namespace cli;

import std;
import .gojson;
import .flags;
import .types;
import .issue_json;
import .store;
import .cli;

let EXPORT_FLAGS = [
    flags::Spec { name: "output", short: 'o', kind: flags::STRING, usage: "Output file path (default: stdout)" },
    flags::Spec { name: "all", usage: "Include all records (infra, templates, gates, memories)" },
    flags::Spec { name: "include-infra", usage: "Include infrastructure beads (agents, roles, messages)" },
    flags::Spec { name: "scrub", usage: "Exclude test/pollution records" },
    flags::Spec { name: "include-memories", usage: "Include persistent memories (from 'bd remember') in the export" },
    flags::Spec { name: "no-memories", usage: "Exclude persistent memories (deprecated: now the default)" },
    flags::Spec { name: "exclude-owner", kind: flags::ARRAY, usage: "Exclude issues created by this identity (repeatable; also reads export.exclude_owners config)" },
    flags::Spec { name: "verbose", usage: "Print filtered issue count when owners are excluded" },
];

// The issue types export leaves out unless asked: infrastructure beads.
let INFRA_TYPES = ["agent", "role", "message"];

// Whether a title reads as test data (beads' isTestIssue): one of a few
// words, then a separator.
fn is_test_title(title: const u8[:]) -> bool {
    for w in ["test", "benchmark", "sample", "tmp", "temp", "debug", "dummy"] {
        if title.len > w.len && types::ascii_lower_equals(title[..w.len], w) {
            let c = title[w.len];
            if c == '-' || c == '_' || is_space(c) { return true; }
        }
    }
    return false;
}

fn export_command(c: Ctx&) -> i64 {
    guard c.ws.beads_dir.len > 0 else { return no_workspace(c.io); }
    let all = flags::get_bool(c.flags, "all");
    let infra = all || flags::get_bool(c.flags, "include-infra");
    let scrub = flags::get_bool(c.flags, "scrub");
    let no_memories = flags::get_bool(c.flags, "no-memories");
    let memories = (flags::get_bool(c.flags, "include-memories") || all) && !no_memories;
    var excluded: (const u8[:])[>..] = [];
    flags::array(c.flags, "exclude-owner", excluded);
    config_list(c.store, "export.exclude_owners", excluded);

    var order: i64[>..] = [];
    store::listing(c.store, order) { i =>
        (infra || !contains(INFRA_TYPES, i.issue_type)) && (all || (!i.is_template && !i.ephemeral))
            && !(scrub && is_test_title(i.title))
    };
    var filtered = 0;
    if excluded.len > 0 {
        let before = order.len;
        order.retain() { !contains(excluded, c.store.issues[it].created_by) };
        filtered = before - order.len;
    }
    let output = flags::get_string(c.flags, "output");
    if order.len == 0 && no_memories {
        if output.len > 0 { c.io.err.append("No issues to export.\n"); }
        return 0;
    }

    var text: u8[>..] = [];
    for at in order {
        let i = c.store.issues[at];
        let wisp_plane = i.no_history && !i.ephemeral;
        types::format_export_record(text, i, store::counts(c.store, i), wisp_plane);
        text.push('\n');
    }
    var memory_count = 0;
    if memories {
        var keys: i64[>..] = [];
        for m, n in c.store.memories { if m.key.len > 0 { keys.push(n); } }
        sort(keys) { a, b => compare(c.store.memories[a].key, c.store.memories[b].key) < 0 };
        for n in keys {
            let m = c.store.memories[n];
            let record_type = json_string("memory");
            let key = json_string(m.key);
            let value = json_string(m.value);
            var members = [gojson::Member { key: "_type", value: record_type },
                           gojson::Member { key: "key", value: key },
                           gojson::Member { key: "value", value: value }];
            gojson::format_map(text, members);
            text.push('\n');
            memory_count++;
        }
    }
    if output.len == 0 {
        c.io.out.append(text);
        return 0;
    }
    effect(c, WRITE, output, text, SHARED);
    if memory_count > 0 {
        format(c.io.err, "Exported ", order.len, " issues and ", memory_count, " memories to ", output, "\n");
    } else {
        format(c.io.err, "Exported ", order.len, " issues to ", output, "\n");
    }
    if flags::get_bool(c.flags, "verbose") && filtered > 0 {
        format(c.io.err, "  (", filtered, " filtered as personal by owner exclusion)\n");
    }
    return 0;
}
