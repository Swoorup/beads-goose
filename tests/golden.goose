// Prints what the Goose port makes of each issue in a JSONL file on stdin,
// line for line as tests/golden/gen does for beads' Go types: the issue
// written back, its export record, its content hash, and its validation.

import std;
import os;
import beads from "../beads";
import beads.types;
import beads.issue_json;

fn verdict(err: const u8[:]) -> const u8[:] { if err.len > 0 { err } else { "ok" } }

fn main() {
    var input: u8[>..] = [];
    read_stdin(input);
    each_split(input, '\n') { line =>
        if line.len > 0 && line[0] != '#' {
            // Each line gets its own arena and output, freed when it is done.
            var text: u8[>..] = [];
            var strings: (const u8[:])[>..] = [];
            var deps: types::Dependency[>..] = [];
            var comments: types::Comment[>..] = [];
            var bonds: types::BondRef[>..] = [];
            var arena = types::Arena { text: text, strings: strings, deps: deps, comments: comments, bonds: bonds };
            var out: u8[>..] = [];
            let issue, err = types::parse_issue(line, arena);
            if err.len > 0 {
                out.append("error\n");
            } else {
                out.append("json\t");
                if !types::format_issue(out, issue) { out.append("marshal-error"); }
                out.append("\nexport\t");
                let counts = types::Counts { dependency_count: 1, dependent_count: 2, comment_count: 3 };
                if !types::format_export_record(out, issue, counts, issue.no_history) { out.append("marshal-error"); }
                format(out, "\nhash\t", types::content_hash(issue), "\n");
                format(out, "valid\t", verdict(types::validate(issue)), "\n");
                format(out, "import\t", verdict(types::validate_for_import(issue)), "\n");
                let d = types::with_defaults(issue);
                format(out, "defaults\t", d.status, " ", d.issue_type, "\n");
            }
            write_stdout(out);
        }
    };
}
