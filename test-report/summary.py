"""Print a Markdown summary of <dir>/junit.xml and <dir>/coverage.xml.

Exits non-zero, with a workflow error annotation, if either file is missing
or unreadable: every test run must leave both (the CI dashboard reads them).
Test failures do not fail this script; the test step itself does that.
"""

import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def error(msg: str) -> None:
    print(f"::error::{msg}", file=sys.stderr)


def junit_counts(path: Path):
    root = ET.parse(path).getroot()
    passed = failed = skipped = 0
    failures = []
    time = float(root.get("time") or 0)
    for case in root.iter("testcase"):
        name = f"{case.get('classname', '')} {case.get('name', '')}".strip()
        if case.find("failure") is not None or case.find("error") is not None:
            failed += 1
            failures.append(name)
        elif case.find("skipped") is not None:
            skipped += 1
        else:
            passed += 1
    return passed, failed, skipped, time, failures


def coverage_percent(path: Path):
    rate = ET.parse(path).getroot().get("line-rate")
    return None if rate is None else float(rate) * 100


def main() -> int:
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "reports")
    junit, cobertura = out / "junit.xml", out / "coverage.xml"
    ok = True

    print("## Tests\n")
    try:
        passed, failed, skipped, time, failures = junit_counts(junit)
        icon = "❌" if failed else "✅"
        print(f"{icon} **{passed} passed**, {failed} failed, {skipped} skipped in {time:.1f}s\n")
        if failures:
            print("Failed:\n")
            for name in failures[:50]:
                print(f"- `{name}`")
            print()
    except (OSError, ET.ParseError) as e:
        error(f"{junit}: {e}")
        print(f"No readable `{junit}`.\n")
        ok = False

    try:
        pct = coverage_percent(cobertura)
        print(f"**Line coverage:** {pct:.1f}%\n" if pct is not None else "Line coverage: not reported\n")
    except (OSError, ET.ParseError) as e:
        error(f"{cobertura}: {e}")
        print(f"No readable `{cobertura}`.\n")
        ok = False

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
