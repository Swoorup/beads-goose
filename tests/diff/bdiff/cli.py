"""Command line: record goldens, check an implementation against them, or diff two live."""

from __future__ import annotations

import argparse
import difflib
import os
import sys
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from .case import Case, load_cases
from .normalize import transcript
from .runner import run_case

HERE = Path(__file__).resolve().parent.parent


@dataclass(frozen=True)
class Outcome:
    case: str
    diff: str  # empty when the two sides agree

    def status(self, xfail: frozenset[str]) -> str:
        if self.case in xfail:
            return "XPASS" if not self.diff else "XFAIL"
        return "FAIL" if self.diff else "ok"


def unified(expected: str, actual: str, a: str, b: str) -> str:
    return "".join(difflib.unified_diff(
        expected.splitlines(keepends=True), actual.splitlines(keepends=True), a, b))


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    os.umask(0o022)
    try:
        cases = load_cases(args.cases_dir, args.cases)
    except ValueError as e:
        print(f"bdiff: {e}", file=sys.stderr)
        return 2
    return args.command(args, cases)


def observe(args: argparse.Namespace, impl: Path) -> Callable[[Case], str]:
    today = datetime.now(timezone.utc).date()
    return lambda case: transcript(
        run_case(case, impl, args.timeout, args.keep), args.id_prefix, today)


def parallel(args: argparse.Namespace, fn: Callable[[Case], object], cases: list[Case]) -> list:
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        return list(pool.map(fn, cases))


def cmd_record(args: argparse.Namespace, cases: list[Case]) -> int:
    run = observe(args, require_binary(args.impl))
    args.golden_dir.mkdir(parents=True, exist_ok=True)

    def record(case: Case) -> str:
        golden = args.golden_dir / f"{case.name}.txt"
        before = golden.read_text() if golden.exists() else None
        after = run(case)
        golden.write_text(after)
        return f"{'new' if before is None else 'changed' if before != after else 'same':8} {case.name}"

    print("\n".join(parallel(args, record, cases)))
    return 0


def cmd_check(args: argparse.Namespace, cases: list[Case]) -> int:
    run = observe(args, require_binary(args.impl))

    def check(case: Case) -> Outcome:
        golden = args.golden_dir / f"{case.name}.txt"
        expected = golden.read_text() if golden.exists() else ""
        actual = run(case)
        write_actual(args.out, case.name, actual)
        return Outcome(case.name, unified(expected, actual, f"golden/{case.name}", f"{args.impl}/{case.name}"))

    return report(args, parallel(args, check, cases))


def cmd_diff(args: argparse.Namespace, cases: list[Case]) -> int:
    ref, impl = observe(args, require_binary(args.ref)), observe(args, require_binary(args.impl))

    def diff(case: Case) -> Outcome:
        expected, actual = ref(case), impl(case)
        write_actual(args.out, case.name, actual)
        return Outcome(case.name, unified(expected, actual, f"{args.ref}/{case.name}", f"{args.impl}/{case.name}"))

    return report(args, parallel(args, diff, cases))


def report(args: argparse.Namespace, outcomes: list[Outcome]) -> int:
    xfail = read_xfail(args.xfail)
    statuses = [(o, o.status(xfail)) for o in outcomes]
    for o, status in statuses:
        if o.diff and (args.verbose or status == "FAIL"):
            sys.stdout.write(o.diff)
        if args.out and o.diff:
            (args.out / f"{o.case}.diff").write_text(o.diff)
    print()
    for o, status in statuses:
        print(f"{status:6} {o.case}")
    counts = {s: sum(1 for _, st in statuses if st == s) for s in ("ok", "FAIL", "XFAIL", "XPASS")}
    print("\n" + ", ".join(f"{n} {s}" for s, n in counts.items() if n))
    if counts["XPASS"]:
        print(f"remove now-passing cases from {args.xfail}")
    return 1 if counts["FAIL"] or counts["XPASS"] else 0


def write_actual(out: Path | None, name: str, text: str) -> None:
    if out:
        out.mkdir(parents=True, exist_ok=True)
        (out / f"{name}.txt").write_text(text)


def read_xfail(path: Path | None) -> frozenset[str]:
    if not path or not path.exists():
        return frozenset()
    lines = (line.split("#", 1)[0].strip() for line in path.read_text().splitlines())
    return frozenset(line for line in lines if line)


def require_binary(path: Path) -> Path:
    resolved = path.resolve()
    if not (resolved.is_file() and os.access(resolved, os.X_OK)):
        sys.exit(f"bdiff: not an executable: {path}")
    return resolved


def parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("cases", nargs="*", help="case names (default: all)")
    common.add_argument("--cases-dir", type=Path, default=HERE / "cases")
    common.add_argument("--golden-dir", type=Path, default=HERE / "golden")
    common.add_argument("--id-prefix", default="test", help="issue prefix the cases init with")
    common.add_argument("--timeout", type=float, default=300, help="seconds per case")
    common.add_argument("-j", "--jobs", type=int, default=min(4, os.cpu_count() or 1))
    common.add_argument("--keep", action="store_true", help="keep workspaces for inspection")

    compare = argparse.ArgumentParser(add_help=False)
    compare.add_argument("--out", type=Path, help="write actual transcripts and diffs here")
    compare.add_argument("--xfail", type=Path, help="file of case names expected to differ")
    compare.add_argument("-v", "--verbose", action="store_true", help="print xfail diffs too")

    p = argparse.ArgumentParser(prog="bdiff", description=__doc__)
    sub = p.add_subparsers(required=True)
    rec = sub.add_parser("record", parents=[common], help="write goldens from a reference bd")
    rec.add_argument("--impl", type=Path, required=True)
    rec.set_defaults(command=cmd_record)
    chk = sub.add_parser("check", parents=[common, compare], help="compare an implementation to goldens")
    chk.add_argument("--impl", type=Path, required=True)
    chk.set_defaults(command=cmd_check)
    dif = sub.add_parser("diff", parents=[common, compare], help="run two implementations and diff them live")
    dif.add_argument("--ref", type=Path, required=True)
    dif.add_argument("--impl", type=Path, required=True)
    dif.set_defaults(command=cmd_diff)
    return p
