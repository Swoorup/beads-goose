# Working on beads-goose

The goal is a drop-in replacement for bd v1.3.0 (gastownhall/beads), in Goose,
fast and in a functional style. Read README.md for the layout and design.

## Rules

- Compatibility is checked, not assumed. Anything bd prints or stores (JSON,
  hashes, error messages, timestamps) must match beads byte for byte. Add the
  case to `tests/golden/issues.jsonl`, run `make golden-update` (needs Go and
  network, or `BEADS_DIR` pointing at a beads checkout), and `make golden`.
- Keep `beads/` pure: functions from data to data. Process I/O happens in
  `bd.goose` (or a future equivalent edge), never in the library.
- Keep the model backend-independent: a native Goose store comes first and a
  Dolt adapter later; neither may leak into `types` or the JSON contract.
- Port the Go doc comments' intent, not their history: say what a thing is
  and why, in the present tense.
- Goose toolchain is pinned in `scripts/install-goose.sh`; bump it in its own
  change, with `make test` passing.

## Goose pitfalls met so far

- `return` inside a trailing block (`each_split(s, '\n') { ... return; }`)
  returns from the enclosing *function*, not the block. Use `if`.
- `block`, `type`, `bool` and `null` are keywords; they cannot name fields,
  functions or parameters. `Dependency.dep_type` is JSON's `"type"`.
- There are no lambdas. Use a nested `fn`; it sees the enclosing locals.
- A view read through a struct that holds one (`r.text` of a `json::Reader`)
  is rooted at the struct, not at the text it views, so it cannot be stored
  in an arena that outlives the struct. The readers take the text again as a
  `src` parameter and slice that.
- A slice variable commits to its first root. To pick between views with
  different roots, assign struct fields instead of rebinding a variable.
- `u8[:][:]` does not coerce to `const (const u8[:])[:]` (element constness
  is invariant): copy into a `(const u8[:])[>..]` at the edge.
- An `if` used as an operand needs parentheses: `a + (if c { 1 } else { 0 })`.
- Inside `beads/`, modules import each other as `import .name;` so that both
  `bd.goose` (as plain modules) and `tests/` (through
  `import beads from "../beads";`) resolve them.
- A resizable field (`u8[>..]`) must be a struct's last field, and a struct
  holding one cannot be an array element. Keep such text in one shared
  buffer and store `Span`s.
- A struct of references (`types::Arena`) is treated as possibly reaching
  anything its callee's other arguments view. A function that pushes a
  caller's views into it then needs the arena to outlive them all, which
  rarely holds; copy the bytes into `a.text` first (`lifecycle::own`).
- `guard` is a keyword too.
- `goose file.goose` runs in-process through TinyCC (fast to start);
  `goose build` compiles with the system C compiler at -O2. Tests build.
