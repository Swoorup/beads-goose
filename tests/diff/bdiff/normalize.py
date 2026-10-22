"""Turns a raw run into a canonical transcript. Pure functions only.

Values that legitimately differ between two correct runs (random hash IDs,
clock-derived timestamps, UUIDs, temp paths) are replaced by placeholders.
Numbered placeholders are assigned by order of first appearance, so the
transcript still records *where* a value recurs: `<ID:2>` in a `dep add`
argument and `<ID:2>` in a later `show` output must be the same issue on both
sides, even though the real hashes differ.
"""

from __future__ import annotations

import re
import shlex
from collections.abc import Callable, Iterable
from datetime import date, timedelta
from functools import reduce

from .runner import Run, Step

Transform = Callable[[str], str]

ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
UUID = re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b")
TIMESTAMP = re.compile(
    r"(?P<date>\d{4}-\d{2}-\d{2})"
    r"(?:(?P<sep>[T ])(?P<time>\d{2}:\d{2}(?::\d{2})?)(?:\.(?P<frac>\d+))?"
    r"(?P<tz>Z|[+-]\d{2}:?\d{2})?)?"
)
# Mixed-digit-and-letter hex runs: commit hashes, repository/clone IDs.
HEX = re.compile(r"\b(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{7,64}\b")
DURATION = re.compile(r"\b\d+(?:\.\d+)?(?:ns|µs|us|ms|s)\b")
# Optimistic-concurrency token: a random int64 rewritten on every write.
REVISION = re.compile(r'("revision":\s*")-?\d+(")')
UNORDERED_HEADER = "--- unordered "
# Build identity says which binary this is, not how it behaves: upstream prints
# `bd version 1.3.1 (c1c4b642a: HEAD@c1c4b642ac1c)`, a port its own tag. The
# version number itself is still compared.
VERSION_BUILD = re.compile(r"^(bd version \S+) \(.*\)$", re.MULTILINE)
BUILD_FIELDS = re.compile(r'("(?:branch|build|commit)":\s*)"[^"]*"')


def number_by_appearance(pattern: re.Pattern[str], label: str) -> Transform:
    """Replace each distinct match with <label:n>, n = order of first appearance."""

    def apply(text: str) -> str:
        seen: dict[str, int] = {}
        return pattern.sub(
            lambda m: f"<{label}:{seen.setdefault(m[0], len(seen) + 1)}>", text
        )

    return apply


def clock_timestamps(today: date, window_days: int = 2) -> Transform:
    """Mask dates near `today`; fixed dates a case passes in (2099-01-15) stay."""
    near = {(today + timedelta(days=d)).isoformat() for d in range(-window_days, window_days + 1)}

    def mask(m: re.Match[str]) -> str:
        if m["date"] not in near:
            return m[0]
        if not m["time"]:
            return "<DATE>"
        time = "<TIME>" if m["time"].count(":") == 2 else "<HH:MM>"
        frac = ".<FRAC>" if m["frac"] else ""
        return f"<DATE>{m['sep']}{time}{frac}{m['tz'] or ''}"

    return lambda text: TIMESTAMP.sub(mask, text)


def literal(old: str, new: str) -> Transform:
    return lambda text: text.replace(old, new)


def regex(pattern: str, repl: str) -> Transform:
    compiled = re.compile(pattern, re.MULTILINE)
    return lambda text: compiled.sub(repl, text)


def compose(transforms: Iterable[Transform]) -> Transform:
    fns = tuple(transforms)
    return lambda text: reduce(lambda acc, f: f(acc), fns, text)


def normalizer(run: Run, id_prefix: str, today: date) -> Transform:
    """The ordered rule set for one run. Order matters: specific before general."""
    id_pattern = re.compile(rf"\b{re.escape(id_prefix)}-[0-9a-z]{{3,16}}\b")
    return compose([
        lambda text: ANSI.sub("", text),
        # Longest path first: <WS> and <HOME> live under <ROOT>.
        *(literal(real, ph) for real, ph in sorted(run.paths, key=lambda p: -len(p[0]))),
        lambda text: VERSION_BUILD.sub(r"\1 (<BUILD>)", text),
        lambda text: BUILD_FIELDS.sub(r'\1"<BUILD>"', text),
        number_by_appearance(UUID, "UUID"),
        clock_timestamps(today),
        number_by_appearance(id_pattern, "ID"),
        number_by_appearance(HEX, "HEX"),
        lambda text: DURATION.sub("<DUR>", text),
        lambda text: REVISION.sub(r"\1<REV>\2", text),
        *(regex(p, r) for p, r in run.case.replacements),
    ])


def render(run: Run) -> str:
    """The raw (un-normalized) transcript: every observation, in a fixed order."""
    sections = [
        *(_step(f"step {i}", s) for i, s in enumerate(run.steps, 1)),
        *([_step("snapshot: bd export", run.snapshot)] if run.snapshot else []),
        *([_section("snapshot: tree", "".join(f"{p}\n" for p in run.tree))] if run.tree else []),
        *(_section(f"snapshot: file {path}", body) for path, body in run.files),
        *([_section("harness error", run.error + "\n")] if run.error else []),
    ]
    return "".join(sections)


def transcript(run: Run, id_prefix: str, today: date) -> str:
    return sort_unordered(normalizer(run, id_prefix, today)(render(run)))


def sort_unordered(text: str) -> str:
    """Within a step marked `--- unordered <regex>`, sort each run of
    consecutive matching lines. Runs after normalization, so the sort key is
    the placeholder (creation order), not the random hash."""
    out: list[str] = []
    run: list[str] = []
    pattern: re.Pattern[str] | None = None
    for line in text.splitlines(keepends=True):
        if pattern and pattern.search(line):
            run.append(line)
            continue
        out += sorted(run)
        run = []
        if line.startswith("=== "):
            pattern = None
        elif line.startswith(UNORDERED_HEADER):
            pattern = re.compile(line[len(UNORDERED_HEADER):].rstrip("\n"))
        out.append(line)
    return "".join(out + sorted(run))


def _step(title: str, step: Step) -> str:
    cwd = "" if step.cwd == "." else f"(in {step.cwd}) "
    head = f"=== {title} ===\n{cwd}$ {shlex.join(('bd', *step.argv))}\n--- exit {step.rc}\n"
    unordered = f"{UNORDERED_HEADER}{step.unordered}\n" if step.unordered else ""
    return head + unordered + _block("stdout", step.out) + _block("stderr", step.err)


def _section(title: str, body: str) -> str:
    return f"=== {title} ===\n{_body(body)}"


def _block(name: str, body: str) -> str:
    return f"--- {name}\n{_body(body)}" if body else ""


def _body(body: str) -> str:
    return body if body.endswith("\n") or not body else body + "\n\\ no newline at end\n"
