"""Runs one case against one implementation in a sealed workspace.

This is the only module with side effects. It returns a `Run` holding raw
observations; rendering and normalization happen elsewhere, as pure functions.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

from .case import Case

# Holds the recording `bd` shim. It is a checked-in executable put on PATH as is:
# copying it per run raced with forks from parallel runs (ETXTBSY on exec).
SHIM_DIR = Path(__file__).with_name("bin")

# Directories whose contents are engine internals: only their presence is
# compared. Everything else under the workspace is listed and, if it is small
# text, compared byte for byte.
OPAQUE_DIRS = (".git", ".beads/embeddeddolt", ".beads/dolt", ".beads/goose")
MAX_TEXT_FILE = 64 * 1024

# A fixed, minimal environment so runs are reproducible across machines and
# match between implementations. Nothing from the caller's env leaks in except
# PATH (for sh, git and friends).
BASE_ENV = {
    "BEADS_ACTOR": "tester",
    "BD_DISABLE_METRICS": "1",
    "DO_NOT_TRACK": "1",
    "BD_NON_INTERACTIVE": "1",
    "BD_NO_PAGER": "1",
    "BEADS_TIP_SEED": "1",
    "NO_COLOR": "1",
    "TERM": "dumb",
    "TZ": "UTC",
    "LANG": "C.UTF-8",
    "LC_ALL": "C.UTF-8",
    "GIT_CONFIG_NOSYSTEM": "1",
}

GITCONFIG = """\
[user]
\tname = Beads Tester
\temail = tester@example.com
[init]
\tdefaultBranch = main
"""


@dataclass(frozen=True)
class Step:
    argv: tuple[str, ...]
    cwd: str
    rc: int
    out: str
    err: str
    unordered: str = ""  # regex: output lines whose relative order is unspecified


@dataclass(frozen=True)
class Run:
    case: Case
    steps: tuple[Step, ...]
    snapshot: Step | None
    tree: tuple[str, ...]
    files: tuple[tuple[str, str], ...]
    # Real paths that leak into output, mapped to stable placeholders.
    paths: tuple[tuple[str, str], ...]
    error: str | None = None


def run_case(case: Case, impl: Path, timeout: float, keep: bool = False) -> Run:
    root = Path(tempfile.mkdtemp(prefix=f"bdiff-{case.name}-")).resolve()
    try:
        return _run_in(root, case, impl, timeout)
    finally:
        if not keep:
            shutil.rmtree(root, ignore_errors=True)


def _run_in(root: Path, case: Case, impl: Path, timeout: float) -> Run:
    ws, home, log = (root / d for d in ("ws", "home", "log"))
    for d in (ws, home, log):
        d.mkdir()
    (home / ".gitconfig").write_text(GITCONFIG)
    (log / "count").write_text("0\n")

    env = {
        **BASE_ENV,
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(home / ".config"),
        "XDG_DATA_HOME": str(home / ".local/share"),
        "XDG_CACHE_HOME": str(home / ".cache"),
        "GIT_CONFIG_GLOBAL": str(home / ".gitconfig"),
        "PATH": f"{SHIM_DIR}{os.pathsep}{os.environ.get('PATH', '/usr/bin:/bin')}",
        "BDIFF_IMPL": str(impl),
        "BDIFF_LOG": str(log),
    }
    paths = ((str(ws), "<WS>"), (str(home), "<HOME>"), (str(root), "<ROOT>"))

    script = str(case.path.resolve())
    error = None
    try:
        p = subprocess.run(
            ["sh", script], cwd=ws, env=env, timeout=timeout,
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )
        # The shell's own complaints (syntax errors, a `bd` it could not run)
        # are prefixed with the script path; bd's replayed stderr never is.
        shell_errors = [
            line for line in p.stderr.decode(errors="replace").splitlines()
            if line.startswith(f"{script}:")
        ]
        error = "\n".join(shell_errors) or None
    except subprocess.TimeoutExpired:
        error = f"case timed out after {timeout:.0f}s"

    steps = tuple(_read_step(log, n, ws) for n in range(1, _count(log) + 1))
    snapshot = (
        _export(impl, ws, env, timeout)
        if error is None and case.snapshot and (ws / ".beads").is_dir()
        else None
    )
    tree, files = _scan(ws) if case.snapshot else ((), ())
    return Run(case, steps, snapshot, tree, files, paths, error)


def _count(log: Path) -> int:
    return int((log / "count").read_text().strip() or 0)


def _text(path: Path) -> str:
    return path.read_bytes().decode("utf-8", errors="replace") if path.exists() else ""


def _read_step(log: Path, n: int, ws: Path) -> Step:
    stem = log / f"{n:04d}"
    argv = tuple(_text(stem.with_suffix(".argv")).split("\0")[:-1])
    cwd = Path(_text(stem.with_suffix(".cwd")).strip() or ws)
    rc_text = _text(stem.with_suffix(".rc")).strip()
    return Step(
        argv=argv,
        cwd=os.path.relpath(cwd, ws),
        # A missing exit code means the step was still running at a timeout.
        rc=int(rc_text) if rc_text else -1,
        out=_text(stem.with_suffix(".out")),
        err=_text(stem.with_suffix(".err")),
        unordered=_text(stem.with_suffix(".unordered")),
    )


def _export(impl: Path, ws: Path, env: dict[str, str], timeout: float) -> Step:
    argv = ("export",)
    try:
        p = subprocess.run(
            [str(impl), *argv], cwd=ws, env={**env, "BDIFF_INNER": "1"},
            capture_output=True, timeout=timeout, stdin=subprocess.DEVNULL,
        )
        # Stored state is a set of records; line order is not part of it
        # (and upstream breaks same-second ties on random hash IDs).
        return Step(argv, ".", p.returncode, p.stdout.decode(errors="replace"),
                    p.stderr.decode(errors="replace"), unordered=r"^\{")
    except subprocess.TimeoutExpired:
        return Step(argv, ".", -1, "", f"timed out after {timeout:.0f}s")


def _scan(ws: Path) -> tuple[tuple[str, ...], tuple[tuple[str, str], ...]]:
    """List the workspace tree and read its small text files."""
    tree: list[str] = []
    files: list[tuple[str, str]] = []
    for dirpath, dirnames, filenames in os.walk(ws):
        rel_dir = os.path.relpath(dirpath, ws)
        opaque = {d for d in dirnames if _rel(rel_dir, d) in OPAQUE_DIRS}
        dirnames[:] = sorted(d for d in dirnames if d not in opaque)
        tree += [_rel(rel_dir, d) + "/" for d in sorted(opaque) + dirnames]
        for name in sorted(filenames):
            rel, path = _rel(rel_dir, name), Path(dirpath, name)
            tree.append(f"{rel} ({path.lstat().st_mode & 0o777:04o})")
            content = _small_text(path)
            if content is not None:
                files.append((rel, content))
    return tuple(sorted(tree)), tuple(sorted(files))


def _rel(rel_dir: str, name: str) -> str:
    return name if rel_dir == "." else f"{rel_dir}/{name}"


def _small_text(path: Path) -> str | None:
    if path.is_symlink() or path.stat().st_size > MAX_TEXT_FILE:
        return None
    try:
        return path.read_bytes().decode("utf-8")
    except UnicodeDecodeError:
        return None
