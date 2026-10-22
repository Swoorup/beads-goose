#!/usr/bin/env python3
"""Entry point: `tests/diff/run.py {record,check,diff} ...` (see README.md)."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from bdiff.cli import main  # noqa: E402

sys.exit(main())
