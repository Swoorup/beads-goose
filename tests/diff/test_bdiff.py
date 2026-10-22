"""Unit tests for the harness's pure parts: `python3 -m unittest discover -s tests/diff`."""

import tempfile
import unittest
from datetime import date
from pathlib import Path

from bdiff.case import Case, parse_case
from bdiff.cli import Outcome
from bdiff.normalize import (
    HEX, backend_equivalence, clock_timestamps, number_by_appearance, render, sort_unordered, transcript,
)
from bdiff.runner import Run, Step

TODAY = date(2026, 10, 22)


def make_run(*steps: Step, replacements=(), paths=()) -> Run:
    case = Case("t", Path("t.sh"), replacements=replacements)
    return Run(case, steps, None, (), (), paths)


class NumberByAppearance(unittest.TestCase):
    def test_numbers_distinct_values_in_order_and_reuses_them(self):
        f = number_by_appearance(HEX, "HEX")
        self.assertEqual(f("a1b2c3d e4f5a6b a1b2c3d"), "<HEX:1> <HEX:2> <HEX:1>")

    def test_hex_needs_both_digits_and_letters(self):
        f = number_by_appearance(HEX, "HEX")
        self.assertEqual(f("1234567 deadbeef 1a2b3c4"), "1234567 deadbeef <HEX:1>")


class ClockTimestamps(unittest.TestCase):
    mask = staticmethod(clock_timestamps(TODAY))

    def test_masks_timestamps_near_today_keeping_shape(self):
        self.assertEqual(self.mask("2026-10-22T13:19:20.5296Z"), "<DATE>T<TIME>.<FRAC>Z")
        self.assertEqual(self.mask("2026-10-21 09:00"), "<DATE> <HH:MM>")
        self.assertEqual(self.mask("Created: 2026-10-23"), "Created: <DATE>")

    def test_keeps_fixed_dates_from_case_input(self):
        self.assertEqual(self.mask("due 2099-01-15T00:00:00Z"), "due 2099-01-15T00:00:00Z")


class Transcript(unittest.TestCase):
    def test_ids_in_args_and_output_share_placeholders(self):
        run = make_run(
            Step(("create", "x", "--silent"), ".", 0, "test-icv\n", ""),
            Step(("dep", "add", "test-00i", "test-icv"), ".", 0, "ok test-00i\n", ""),
        )
        text = transcript(run, "test", TODAY)
        self.assertIn("$ bd dep add <ID:2> <ID:1>\n", text)
        self.assertIn("<ID:1>\n", text)
        self.assertIn("ok <ID:2>\n", text)

    def test_paths_revision_and_case_replacements(self):
        run = make_run(
            Step(("info",), ".", 0, 'at /tmp/r/ws "revision": "-42" v9\n', ""),
            paths=(("/tmp/r/ws", "<WS>"), ("/tmp/r", "<ROOT>")),
            replacements=((r"v\d", "v<N>"),),
        )
        self.assertIn('at <WS> "revision": "<REV>" v<N>\n', transcript(run, "test", TODAY))

    def test_masks_build_identity_but_not_version(self):
        run = make_run(Step(("version",), ".", 0,
                            'bd version 1.3.1 (c1c4b642a: HEAD@c1c4b642ac1c)\n"build": "c1c4b642a"\n', ""))
        text = transcript(run, "test", TODAY)
        self.assertIn('bd version 1.3.1 (<BUILD>)\n"build": "<BUILD>"\n', text)
        self.assertNotIn("HEX", text)

    def test_marks_missing_trailing_newline_and_omits_empty_streams(self):
        text = render(make_run(Step(("x",), ".", 1, "", "boom")))
        self.assertIn("--- exit 1\n--- stderr\nboom\n\\ no newline at end\n", text)
        self.assertNotIn("--- stdout", text)


class BackendEquivalence(unittest.TestCase):
    def test_maps_both_stores_to_one_form(self):
        dolt = ('{\n  "database": "dolt",\n  "backend": "dolt",\n  "dolt_mode": "embedded",\n'
                '  "dolt_database": "test",\n  "project_id": "x"\n}\n.beads/embeddeddolt/\n')
        goose = '{\n  "database": "goose",\n  "backend": "goose",\n  "project_id": "x"\n}\n.beads/goose/\n'
        self.assertEqual(backend_equivalence(dolt), backend_equivalence(goose))
        self.assertIn('"backend": "<BACKEND>"', backend_equivalence(goose))

    def test_drops_dolt_remote_advice_only(self):
        text = "--- stderr\n\n⚠ No Dolt remote configured\n  Run bd dolt remote add\n=== step 2 ===\n"
        self.assertEqual(backend_equivalence(text), "=== step 2 ===\n")
        self.assertEqual(backend_equivalence("Issue count: 3\n"), "Issue count: 3\n")


class SortUnordered(unittest.TestCase):
    def test_sorts_only_matching_runs_inside_marked_step(self):
        text = (
            "=== step 1 ===\n--- unordered ^- \n--- stdout\nhead\n- b\n- a\ntail\n- d\n- c\n"
            "=== step 2 ===\n- z\n- y\n"
        )
        self.assertEqual(sort_unordered(text), (
            "=== step 1 ===\n--- unordered ^- \n--- stdout\nhead\n- a\n- b\ntail\n- c\n- d\n"
            "=== step 2 ===\n- z\n- y\n"
        ))


class ParseCase(unittest.TestCase):
    def test_reads_directives(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d, "c.sh")
            path.write_text("# bdiff: replace 'a b' c\n# bdiff: no-snapshot\nbd list\n")
            case = parse_case(path)
        self.assertEqual(case.replacements, (("a b", "c"),))
        self.assertFalse(case.snapshot)

    def test_rejects_unknown_directive(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d, "c.sh")
            path.write_text("# bdiff: sort\n")
            with self.assertRaises(ValueError):
                parse_case(path)


class OutcomeStatus(unittest.TestCase):
    def test_xfail_ratchet(self):
        xfail = frozenset({"a"})
        self.assertEqual(Outcome("a", "diff").status(xfail), "XFAIL")
        self.assertEqual(Outcome("a", "").status(xfail), "XPASS")
        self.assertEqual(Outcome("b", "diff").status(xfail), "FAIL")
        self.assertEqual(Outcome("b", "").status(xfail), "ok")


if __name__ == "__main__":
    unittest.main()
