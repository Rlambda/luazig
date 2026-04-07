#!/usr/bin/env python3
import argparse
import json
import re
from collections import Counter, defaultdict
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TESTES_DIR = ROOT / "third_party" / "lua-upstream" / "testes"
TESTC_ZIG = ROOT / "src" / "lua" / "testc.zig"
LTESTS_C = ROOT / "third_party" / "lua-upstream" / "ltests.c"


def parse_supported_commands() -> list[str]:
    text = TESTC_ZIG.read_text(encoding="utf-8")
    names = re.findall(r'if \(std\.mem\.eql\(u8, name, "([^"]+)"\)\) return \.', text)
    if names:
        return names
    m = re.search(r"pub const Command = enum \{(.*?)\n\};", text, re.S)
    if not m:
        raise SystemExit("failed to parse Command enum from src/lua/testc.zig")
    body = m.group(1)
    out: list[str] = []
    for raw in body.splitlines():
        line = raw.strip()
        if not line or line.startswith("//"):
            continue
        if line.endswith(","):
            line = line[:-1]
        if line.startswith('@"') and line.endswith('"'):
            line = line[2:-1]
        out.append(line)
    return out


def parse_upstream_commands() -> set[str]:
    text = LTESTS_C.read_text(encoding="utf-8", errors="replace")
    return set(re.findall(r'else if EQ\("([^"]+)"\)', text))


def decode_lua_string(lit: str) -> str:
    if lit.startswith("[[") and lit.endswith("]]"):
        return lit[2:-2]
    if lit.startswith('"') and lit.endswith('"'):
        return bytes(lit[1:-1], "utf-8").decode("unicode_escape")
    if lit.startswith("'") and lit.endswith("'"):
        return bytes(lit[1:-1], "utf-8").decode("unicode_escape")
    return lit


def extract_testc_scripts(text: str) -> list[str]:
    patterns = [
        r"T\.testC\s*\(\s*[A-Za-z_][A-Za-z0-9_]*\s*,\s*(\[\[.*?\]\]|\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*')",
        r"T\.testC\s*\(\s*(\[\[.*?\]\]|\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*')",
        r"T\.testC\s*(\[\[.*?\]\]|\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*')",
        r"pcall\s*\(\s*T\.testC\s*,\s*(\[\[.*?\]\]|\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*')",
        r"pcall\s*\(\s*T\.testC\s*,\s*[A-Za-z_][A-Za-z0-9_]*\s*,\s*(\[\[.*?\]\]|\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*')",
    ]
    scripts: list[str] = []
    for pat in patterns:
        for lit in re.findall(pat, text, re.S):
            scripts.append(decode_lua_string(lit))
    return scripts


def split_statements(script: str) -> list[str]:
    parts: list[str] = []
    cur: list[str] = []
    in_single = False
    in_double = False
    escape = False
    for ch in script:
        if escape:
            cur.append(ch)
            escape = False
            continue
        if ch == "\\" and (in_single or in_double):
            cur.append(ch)
            escape = True
            continue
        if ch == "'" and not in_double:
            in_single = not in_single
            cur.append(ch)
            continue
        if ch == '"' and not in_single:
            in_double = not in_double
            cur.append(ch)
            continue
        if not in_single and not in_double and ch in ";\n,":
            stmt = "".join(cur).strip()
            if stmt:
                parts.append(stmt)
            cur.clear()
            continue
        cur.append(ch)
    tail = "".join(cur).strip()
    if tail:
        parts.append(tail)
    return parts


def command_name(stmt: str, allowed: set[str]) -> str | None:
    stmt = stmt.strip()
    if not stmt or stmt.startswith("#") or stmt.startswith("--"):
        return None
    m = re.match(r"([A-Za-z_][A-Za-z0-9_]*)", stmt)
    if not m:
        return None
    name = m.group(1)
    if not name[0].islower():
        return None
    if name not in allowed:
        return None
    return name


def build_inventory() -> dict:
    supported = set(parse_supported_commands())
    upstream = parse_upstream_commands()
    used_counter: Counter[str] = Counter()
    files_for_command: dict[str, set[str]] = defaultdict(set)

    for path in sorted(TESTES_DIR.glob("*.lua")):
        text = path.read_text(encoding="utf-8", errors="replace")
        for script in extract_testc_scripts(text):
            stripped = "\n".join(line.split("#", 1)[0] for line in script.splitlines())
            for stmt in split_statements(stripped):
                name = command_name(stmt, upstream)
                if not name:
                    continue
                used_counter[name] += 1
                files_for_command[name].add(path.name)

    used = sorted(used_counter)
    supported_used = [name for name in used if name in supported]
    missing = [name for name in used if name not in supported]
    unused_supported = sorted(name for name in supported if name not in used)

    return {
        "supported_count": len(supported),
        "upstream_count": len(upstream),
        "used_count": len(used),
        "supported_used_count": len(supported_used),
        "missing_count": len(missing),
        "supported_used": supported_used,
        "missing": [
            {
                "command": name,
                "count": used_counter[name],
                "files": sorted(files_for_command[name]),
            }
            for name in missing
        ],
        "unused_supported": unused_supported,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Inventory upstream testC command usage vs luazig support.")
    parser.add_argument("--json", action="store_true", help="Print JSON instead of text summary.")
    args = parser.parse_args()

    inv = build_inventory()
    if args.json:
        print(json.dumps(inv, indent=2, ensure_ascii=False))
        return 0

    print(f"supported commands: {inv['supported_count']}")
    print(f"commands used in upstream testes/*.lua: {inv['used_count']}")
    print(f"covered by current parser: {inv['supported_used_count']}")
    print(f"missing commands: {inv['missing_count']}")
    if inv["missing"]:
        print("missing:")
        for item in inv["missing"]:
            files = ", ".join(item["files"])
            print(f"  - {item['command']}: count={item['count']} files={files}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
