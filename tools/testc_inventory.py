#!/usr/bin/env python3
import argparse
import pathlib
import re
from collections import Counter, defaultdict

PAT = re.compile(r"\bT\.([A-Za-z0-9_]+)")


def scan(paths):
    counts = Counter()
    files = defaultdict(Counter)
    for p in paths:
        text = p.read_text(encoding="utf-8", errors="replace")
        for m in PAT.finditer(text):
            name = m.group(1)
            counts[name] += 1
            files[p.name][name] += 1
    return counts, files


def fmt_markdown(counts, files):
    lines = []
    lines.append("# testC/T Inventory")
    lines.append("")
    lines.append("Generated from `third_party/lua-upstream/testes/*.lua`.")
    lines.append("")
    lines.append("## Global")
    lines.append("")
    lines.append("| Command | Uses |")
    lines.append("|---|---:|")
    for name, n in counts.most_common():
        lines.append(f"| `T.{name}` | {n} |")
    lines.append("")
    lines.append("## Per File")
    lines.append("")
    for fname in sorted(files):
        lines.append(f"### `{fname}`")
        lines.append("")
        lines.append("| Command | Uses |")
        lines.append("|---|---:|")
        for name, n in files[fname].most_common():
            lines.append(f"| `T.{name}` | {n} |")
        lines.append("")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tests-dir", default="third_party/lua-upstream/testes")
    ap.add_argument("--out", default="docs/testc_inventory.md")
    args = ap.parse_args()

    tests_dir = pathlib.Path(args.tests_dir)
    paths = sorted(tests_dir.glob("*.lua"))
    counts, files = scan(paths)
    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(fmt_markdown(counts, files), encoding="utf-8")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
