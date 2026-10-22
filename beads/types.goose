// The core data model: beads' Issue and the records hanging off it, ported
// from internal/types/types.go. Field names are the JSON names and the
// fields are in the order Go writes them, so the struct reads as the wire
// format does. (Dependency.dep_type is the one exception: its JSON name,
// "type", is a keyword.)
//
// Every string is a `const u8[:]`: a view of text the caller keeps, such as
// the JSONL buffer an issue was read from, or the scratch its escaped
// strings were decoded onto. Lists are views of arrays the caller keeps the
// same way. An Issue is therefore fixed-size, indexable and sortable, and
// owns nothing: its storage is whatever arena it was built in.

namespace types;

import std;
import .gotime;
import .gojson;
import .sha256;

// A value that may be absent: what beads keeps in a Go pointer field.
struct Opt<T> { has: bool, v: T }

fn some<T>(v: T) -> Opt<T> { Opt<T> { has: true, v: v } }

// A string list, such as labels or waiters.
type Strings = const (const u8[:])[:];

struct Dependency {
    id: const u8[:],             // the edge's surrogate key; omitted when empty
    issue_id: const u8[:],
    depends_on_id: const u8[:],
    dep_type: const u8[:],       // "type" in JSON, a keyword here
    created_at: gotime::Time,
    created_by: const u8[:],
    metadata: const u8[:],       // type-specific edge data, a JSON text
    thread_id: const u8[:],      // the conversation root of a replies-to edge
}

struct Comment {
    id: const u8[:],
    issue_id: const u8[:],
    author: const u8[:],
    text: const u8[:],
    created_at: gotime::Time,
}

// Compound molecule lineage: which source was bonded in, and how.
struct BondRef {
    source_id: const u8[:],
    bond_type: const u8[:],      // sequential, parallel, conditional, root
    bond_point: const u8[:],     // attachment site, empty for the root
}

struct Issue {
    // Core identification
    id: const u8[:],

    // Content
    title: const u8[:],
    description: const u8[:],
    design: const u8[:],
    acceptance_criteria: const u8[:],
    notes: const u8[:],
    spec_id: const u8[:],

    // Status and workflow
    status: const u8[:],
    priority: i64,               // 0 (P0, critical) to 4; never omitted
    issue_type: const u8[:],
    is_blocked: bool,            // the readiness projection journal snapshots carry

    // Assignment
    assignee: const u8[:],
    owner: const u8[:],
    estimated_minutes: Opt<i64>,

    // Timestamps
    created_at: gotime::Time,
    created_by: const u8[:],
    updated_at: gotime::Time,
    started_at: Opt<gotime::Time>,
    closed_at: Opt<gotime::Time>,
    close_reason: const u8[:],
    closed_by_session: const u8[:],

    // Leasing
    lease_expires_at: Opt<gotime::Time>,
    heartbeat_at: Opt<gotime::Time>,
    lease_granted_node: const u8[:],

    // Scheduling
    due_at: Opt<gotime::Time>,
    defer_until: Opt<gotime::Time>,

    // External integration
    external_ref: Opt<const u8[:]>,
    source_system: const u8[:],

    // Custom metadata, a JSON text kept as written
    metadata: const u8[:],

    // Compaction
    compaction_level: i64,
    compacted_at: Opt<gotime::Time>,
    compacted_at_commit: Opt<const u8[:]>,
    original_size: i64,

    // Relational data, populated for export and import
    labels: Strings,
    dependencies: const Dependency[:],
    comments: const Comment[:],

    // Messaging
    sender: const u8[:],
    ephemeral: bool,
    no_history: bool,
    wisp_type: const u8[:],
    storage_class: const u8[:],

    // Context markers
    pinned: bool,
    is_template: bool,

    // Bonding
    bonded_from: const BondRef[:],

    // Gates
    await_type: const u8[:],
    await_id: const u8[:],
    timeout: i64,                // nanoseconds, as Go's time.Duration
    waiters: Strings,

    // Source tracing
    source_formula: const u8[:],
    source_location: const u8[:],

    // Molecule and work types
    mol_type: const u8[:],
    work_type: const u8[:],

    // Events
    event_kind: const u8[:],
    actor: const u8[:],
    target: const u8[:],
    payload: const u8[:],
}

// The relationship counts an exported issue carries.
struct Counts { dependency_count: i64, dependent_count: i64, comment_count: i64 }

// --- statuses -------------------------------------------------------------------

let STATUS_OPEN = "open";
let STATUS_IN_PROGRESS = "in_progress";
let STATUS_BLOCKED = "blocked";
let STATUS_DEFERRED = "deferred";        // deliberately put on ice
let STATUS_CLOSED = "closed";
let STATUS_PINNED = "pinned";            // a persistent bead that stays open
let STATUS_HOOKED = "hooked";            // work claimed by a worker

let ALL_STATUSES = [STATUS_OPEN, STATUS_IN_PROGRESS, STATUS_BLOCKED, STATUS_DEFERRED,
                    STATUS_CLOSED, STATUS_PINNED, STATUS_HOOKED];

// How a status behaves in views: active ones are ready work, wip ones are
// listed but not ready, done and frozen ones are neither.
let CATEGORY_ACTIVE = "active";
let CATEGORY_WIP = "wip";
let CATEGORY_DONE = "done";
let CATEGORY_FROZEN = "frozen";
let CATEGORY_UNSPECIFIED = "unspecified";

fn is_builtin_status(s: const u8[:]) -> bool { contains(ALL_STATUSES, s) }

fn is_valid_status(s: const u8[:], custom: Strings) -> bool { is_builtin_status(s) || contains(custom, s) }

fn builtin_status_category(s: const u8[:]) -> const u8[:] {
    if s == STATUS_OPEN { return CATEGORY_ACTIVE; }
    if s == STATUS_IN_PROGRESS || s == STATUS_BLOCKED || s == STATUS_HOOKED { return CATEGORY_WIP; }
    if s == STATUS_CLOSED { return CATEGORY_DONE; }
    if s == STATUS_DEFERRED || s == STATUS_PINNED { return CATEGORY_FROZEN; }
    return CATEGORY_UNSPECIFIED;
}

// --- issue types ----------------------------------------------------------------

let TYPE_BUG = "bug";
let TYPE_FEATURE = "feature";
let TYPE_TASK = "task";
let TYPE_EPIC = "epic";
let TYPE_CHORE = "chore";
let TYPE_DECISION = "decision";
let TYPE_MESSAGE = "message";
let TYPE_MOLECULE = "molecule";          // swarm coordination
let TYPE_GATE = "gate";                  // async coordination
let TYPE_SPIKE = "spike";                // a timeboxed investigation
let TYPE_STORY = "story";
let TYPE_MILESTONE = "milestone";
let TYPE_EVENT = "event";                // set-state audit beads; built in, not a work type

let ALL_ISSUE_TYPES = [TYPE_BUG, TYPE_FEATURE, TYPE_TASK, TYPE_EPIC, TYPE_CHORE, TYPE_DECISION,
                       TYPE_MESSAGE, TYPE_MOLECULE, TYPE_GATE, TYPE_SPIKE, TYPE_STORY, TYPE_MILESTONE];

// A core work type (Go's IssueType.IsValid).
fn is_work_type(t: const u8[:]) -> bool { contains(ALL_ISSUE_TYPES, t) }

// A work type or a system-internal one (Go's IssueType.IsBuiltIn).
fn is_builtin_type(t: const u8[:]) -> bool { is_work_type(t) || t == TYPE_EVENT }

fn is_valid_type(t: const u8[:], custom: Strings) -> bool { is_builtin_type(t) || contains(custom, t) }

// Whether s is `lower`, an ASCII lowercase word, in any ASCII case.
fn ascii_lower_equals(s: const u8[:], lower: const u8[:]) -> bool { gojson::is_key(s, lower) }

// The canonical type for an alias, matched without regard to case
// ("enhancement" is a feature); any other type as it is.
fn normalize_issue_type(t: const u8[:]) -> const u8[:] {
    fn is(name: const u8[:]) -> bool { ascii_lower_equals(t, name) }
    if is("enhancement") || is("feat") { return TYPE_FEATURE; }
    if is("dec") || is("adr") { return TYPE_DECISION; }
    if is("investigation") || is("timebox") { return TYPE_SPIKE; }
    if is("user-story") || is("user_story") { return TYPE_STORY; }
    if is("ms") { return TYPE_MILESTONE; }
    return t;
}

// --- molecule, wisp, work and storage classes -----------------------------------

let MOL_TYPES = ["swarm", "patrol", "work"];
let WISP_TYPES = ["heartbeat", "ping", "patrol", "gc_report", "recovery", "error", "escalation"];
let WORK_TYPES = ["mutex", "open_competition"];

let STORAGE_VERSIONED = "versioned";     // durable, replicated with history; written as ""
let STORAGE_UNVERSIONED = "unversioned"; // durable, current state only
let STORAGE_EPHEMERAL = "ephemeral";     // never exported or replicated
let STORAGE_CLASSES = [STORAGE_VERSIONED, STORAGE_UNVERSIONED, STORAGE_EPHEMERAL];

// Empty is valid for each of these: it means the default.
fn is_valid_mol_type(m: const u8[:]) -> bool { m.len == 0 || contains(MOL_TYPES, m) }
fn is_valid_wisp_type(w: const u8[:]) -> bool { w.len == 0 || contains(WISP_TYPES, w) }
fn is_valid_work_type(w: const u8[:]) -> bool { w.len == 0 || contains(WORK_TYPES, w) }
fn is_valid_storage_class(s: const u8[:]) -> bool { s.len == 0 || contains(STORAGE_CLASSES, s) }

// The record's class: a declared one wins; otherwise wisp-plane records
// (ephemeral or no-history) are ephemeral and the rest versioned.
fn effective_storage_class(i: const Issue&) -> const u8[:] {
    if i.storage_class.len > 0 { return i.storage_class; }
    if i.ephemeral || i.no_history { return STORAGE_EPHEMERAL; }
    return STORAGE_VERSIONED;
}

// "versioned" and "" mean the same, and storage keeps the empty spelling.
fn normalize_storage_class(s: const u8[:]) -> const u8[:] { if s == STORAGE_VERSIONED { "" } else { s } }

// --- dependency types -----------------------------------------------------------

let DEP_BLOCKS = "blocks";
let DEP_PARENT_CHILD = "parent-child";
let DEP_CONDITIONAL_BLOCKS = "conditional-blocks";   // B runs only if A fails
let DEP_WAITS_FOR = "waits-for";                     // a fanout gate
let DEP_RELATED = "related";
let DEP_DISCOVERED_FROM = "discovered-from";
let DEP_REPLIES_TO = "replies-to";
let DEP_RELATES_TO = "relates-to";
let DEP_DUPLICATES = "duplicates";
let DEP_SUPERSEDES = "supersedes";
let DEP_AUTHORED_BY = "authored-by";
let DEP_ASSIGNED_TO = "assigned-to";
let DEP_APPROVED_BY = "approved-by";
let DEP_ATTESTS = "attests";
let DEP_TRACKS = "tracks";
let DEP_UNTIL = "until";
let DEP_CAUSED_BY = "caused-by";
let DEP_VALIDATES = "validates";
let DEP_DELEGATED_FROM = "delegated-from";

let ALL_DEPENDENCY_TYPES = [
    DEP_BLOCKS, DEP_PARENT_CHILD, DEP_CONDITIONAL_BLOCKS, DEP_WAITS_FOR,
    DEP_RELATED, DEP_DISCOVERED_FROM,
    DEP_REPLIES_TO, DEP_RELATES_TO, DEP_DUPLICATES, DEP_SUPERSEDES,
    DEP_AUTHORED_BY, DEP_ASSIGNED_TO, DEP_APPROVED_BY, DEP_ATTESTS,
    DEP_TRACKS,
    DEP_UNTIL, DEP_CAUSED_BY, DEP_VALIDATES,
    DEP_DELEGATED_FROM,
];

// The widest type the dependency tables' VARCHAR(32) column holds.
let MAX_DEPENDENCY_TYPE_LEN = 32;

// Any non-empty type that fits the column; custom types are valid.
fn is_valid_dependency_type(d: const u8[:]) -> bool { d.len > 0 && d.len <= MAX_DEPENDENCY_TYPE_LEN }

fn is_well_known_dependency_type(d: const u8[:]) -> bool { contains(ALL_DEPENDENCY_TYPES, d) }

// Whether an edge of this type holds back ready work.
fn affects_ready_work(d: const u8[:]) -> bool {
    d == DEP_BLOCKS || d == DEP_PARENT_CHILD || d == DEP_CONDITIONAL_BLOCKS || d == DEP_WAITS_FOR
}

// A hard blocker: affects_ready_work without the structural parent-child.
fn is_blocking_edge(d: const u8[:]) -> bool {
    d == DEP_BLOCKS || d == DEP_CONDITIONAL_BLOCKS || d == DEP_WAITS_FOR
}

// --- closing --------------------------------------------------------------------

let FAILURE_CLOSE_KEYWORDS = ["failed", "rejected", "wontfix", "won't fix", "canceled", "cancelled",
                              "abandoned", "blocked", "error", "timeout", "aborted"];

// Whether a close reason says the issue failed: it contains one of the
// failure keywords, in any case. conditional-blocks edges run on failure.
fn is_failure_close(reason: const u8[:]) -> bool {
    guard reason.len > 0 else { return false; }
    var lower: u8[>..] = [];
    lower.append(reason);
    to_lower(lower);
    return FAILURE_CLOSE_KEYWORDS.any() { find(lower, it) >= 0 };
}

// --- issues ---------------------------------------------------------------------

fn is_compound(i: const Issue&) -> bool { i.bonded_from.len > 0 }

// The issue with the defaults Go's SetDefaults fills in after decoding: an
// open task. Priority is left alone, since 0 is a real priority.
fn with_defaults(i: Issue) -> Issue {
    var d = i;
    if d.status.len == 0 { d.status = STATUS_OPEN; }
    if d.issue_type.len == 0 { d.issue_type = TYPE_TASK; }
    return d;
}

// --- validation -----------------------------------------------------------------

// Bounded text fields are VARCHAR(255), counted in characters.
let MAX_FIELD_LEN = 255;
let MAX_TITLE_BYTES = 500;
let ERR_FIELD_TOO_LONG = "field exceeds maximum length";

// The error Go's CheckFieldLen gives for val, or "".
fn check_field_len(name: const u8[:], val: const u8[:]) -> u8[>..] {
    let n = gojson::rune_count(val);
    if n > MAX_FIELD_LEN { return str(ERR_FIELD_TOO_LONG, ": ", name, " is ", n, " characters (max ", MAX_FIELD_LEN, ")"); }
    return str();
}

// Why a title is unacceptable (Go's ValidateIssueTitle), or "".
fn validate_title(title: const u8[:]) -> u8[>..] {
    if title.len == 0 { return str("title is required"); }
    if title.len > MAX_TITLE_BYTES { return str("title must be 500 characters or less (got ", title.len, ")"); }
    return str();
}

fn title_ok(title: const u8[:]) -> bool { title.len > 0 && title.len <= MAX_TITLE_BYTES }

// Why a priority is out of range (Go's ValidateIssuePriority), or "".
fn validate_priority(p: i64) -> u8[>..] {
    if !priority_ok(p) { return str("priority must be between 0 and 4 (got ", p, ")"); }
    return str();
}

fn priority_ok(p: i64) -> bool { p >= 0 && p <= 4 }

fn field_len_ok(val: const u8[:]) -> bool { gojson::rune_count(val) <= MAX_FIELD_LEN }

// s quoted as Go's %q quotes it, for the messages that use it.
fn format_quoted(out: u8[>..]&, s: const u8[:]) {
    out.push('"');
    var i = 0;
    while i < s.len {
        let c = s[i];
        if c >= 0x80 {
            let cp, size = gojson::decode_rune(s, i);
            if cp == 0xFFFD && size == 1 { out.append("\\x"); format_int(out, c, 16, 2, '0'); } else { out.append(s[i..i + size]); }
            i += size;
            continue;
        }
        i++;
        match c {
            '"', '\\' => { out.push('\\'); out.push(c); },
            7 => out.append("\\a"),
            8 => out.append("\\b"),
            12 => out.append("\\f"),
            '\n' => out.append("\\n"),
            '\r' => out.append("\\r"),
            '\t' => out.append("\\t"),
            11 => out.append("\\v"),
            _ => if c < 0x20 || c == 0x7F { out.append("\\x"); format_int(out, c, 16, 2, '0'); } else { out.push(c); },
        }
    }
    out.push('"');
}

fn quoted(s: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    format_quoted(out, s);
    return out;
}

// The checks shared by validate and validate_for_import, after title,
// priority, status and type: the error Go reports, or "".
fn validate_rest(i: const Issue&, storage: bool) -> u8[>..] {
    if i.estimated_minutes.has && i.estimated_minutes.v < 0 { return str("estimated_minutes cannot be negative"); }
    // closed_at is set exactly when the issue is closed.
    if i.status == STATUS_CLOSED && !i.closed_at.has { return str("closed issues must have closed_at timestamp"); }
    if i.status != STATUS_CLOSED && i.closed_at.has { return str("non-closed issues cannot have closed_at timestamp"); }
    if i.metadata.len > 0 && !gojson::valid(i.metadata) { return str("metadata must be valid JSON"); }
    if storage {
        if i.ephemeral && i.no_history { return str("ephemeral and no_history are mutually exclusive"); }
        // A declared class must agree with the wisp-plane flags.
        if !is_valid_storage_class(i.storage_class) {
            return str("invalid storage class ", quoted(i.storage_class), " (must be versioned, unversioned, or ephemeral)");
        }
        if i.storage_class.len > 0 {
            let wisp_plane = i.ephemeral || i.no_history;
            if wisp_plane && i.storage_class != STORAGE_EPHEMERAL {
                return str("storage class ", quoted(i.storage_class),
                           " conflicts with ephemeral/no_history (wisp-plane records are storage class ephemeral)");
            }
            if !wisp_plane && i.storage_class == STORAGE_EPHEMERAL {
                return str("storage class ephemeral requires the ephemeral flag (create with --ephemeral)");
            }
        }
    }
    if !field_len_ok(i.assignee) { return check_field_len("assignee", i.assignee); }
    return check_field_len("owner", i.owner);
}

// Why the issue is invalid, as Go's ValidateWithCustom words it, or "" if
// it is valid. Custom statuses and types are accepted beside the built-in ones.
fn validate(i: const Issue&, custom_statuses: Strings = [], custom_types: Strings = []) -> u8[>..] {
    if !title_ok(i.title) { return validate_title(i.title); }
    if !priority_ok(i.priority) { return validate_priority(i.priority); }
    if !is_valid_status(i.status, custom_statuses) { return str("invalid status: ", i.status); }
    if !is_valid_type(i.issue_type, custom_types) { return str("invalid issue type: ", i.issue_type); }
    return validate_rest(i, true);
}

// Validation for an imported issue, which trusts the source repository's
// types (Go's ValidateForImport): any issue type passes.
fn validate_for_import(i: const Issue&, custom_statuses: Strings = []) -> u8[>..] {
    if !title_ok(i.title) { return validate_title(i.title); }
    if !priority_ok(i.priority) { return validate_priority(i.priority); }
    if !is_valid_status(i.status, custom_statuses) { return str("invalid status: ", i.status); }
    return validate_rest(i, false);
}

// --- content hash ---------------------------------------------------------------

// The bytes Go's ComputeContentHash feeds SHA-256: the substantive fields in
// a fixed order, each followed by a NUL. IDs, timestamps and compaction
// metadata are left out, so identical content hashes identically in every
// clone.
fn canonical_content(i: const Issue&) -> u8[>..] {
    var b: u8[>..] = [];
    fn field(s: const u8[:]) { b.append(s); b.push(0); }
    fn flag(on: bool, label: const u8[:]) { if on { b.append(label); } b.push(0); }
    field(i.title);
    field(i.description);
    field(i.design);
    field(i.acceptance_criteria);
    field(i.notes);
    field(i.spec_id);
    field(i.status);
    format(b, i.priority); b.push(0);
    field(i.issue_type);
    field(i.assignee);
    field(i.owner);
    field(i.created_by);
    field(if i.external_ref.has { i.external_ref.v } else { "" });
    field(i.source_system);
    flag(i.pinned, "pinned");
    field(i.metadata);
    flag(i.is_template, "template");
    for br in i.bonded_from {
        field(br.source_id);
        field(br.bond_type);
        field(br.bond_point);
    }
    field(i.await_type);
    field(i.await_id);
    format(b, i.timeout); b.push(0);
    for w in i.waiters { field(w); }
    field(i.mol_type);
    field(i.work_type);
    field(i.event_kind);
    field(i.actor);
    field(i.target);
    field(i.payload);
    return b;
}

// The SHA-256 of the issue's content, as 64 hex digits.
fn content_hash(i: const Issue&) -> u8[>..] { sha256::hex_digest(canonical_content(i)) }
