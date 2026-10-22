"""Case files: plain POSIX sh scripts plus optional `# bdiff:` directives.

A case is run once per implementation with `bd` on PATH resolving to a
recording shim, so ordinary shell (variables, $(...), pipes) is available:

    A=$(bd create 'Blocker' --silent)
    bd dep add "$B" "$A"

Directives (one per line, anywhere in the file):

    # bdiff: replace <regex> <replacement>   extra normalization for this case
    # bdiff: no-snapshot                     skip the storage snapshot
"""

from __future__ import annotations

import re
import shlex
from dataclasses import dataclass
from pathlib import Path

DIRECTIVE = re.compile(r"^#\s*bdiff:\s*(?P<body>.+?)\s*$")


@dataclass(frozen=True)
class Case:
    name: str
    path: Path
    replacements: tuple[tuple[str, str], ...] = ()
    snapshot: bool = True


def parse_case(path: Path) -> Case:
    directives = [
        shlex.split(m["body"])
        for line in path.read_text().splitlines()
        if (m := DIRECTIVE.match(line))
    ]
    unknown = [d for d in directives if d[0] not in ("replace", "no-snapshot")]
    if unknown:
        raise ValueError(f"{path}: unknown directive {unknown[0][0]!r}")
    return Case(
        name=path.stem,
        path=path,
        replacements=tuple((d[1], d[2]) for d in directives if d[0] == "replace"),
        snapshot=not any(d[0] == "no-snapshot" for d in directives),
    )


def load_cases(cases_dir: Path, only: list[str]) -> list[Case]:
    paths = sorted(cases_dir.glob("*.sh"))
    known = {p.stem for p in paths}
    missing = [name for name in only if name not in known]
    if missing:
        raise ValueError(f"no such case(s): {', '.join(missing)}")
    return [parse_case(p) for p in paths if not only or p.stem in only]
