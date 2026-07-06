#!/usr/bin/env python3
import argparse
import json
import re
from collections import Counter, defaultdict
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TESTES_DIR = ROOT / "lua-5.5.0" / "testes"
TESTC_ZIG = ROOT / "src" / "lua" / "testc.zig"

# testC command surface, baked from PUC Lua 5.5.0 ltests.c (the `else if EQ(...)`
# dispatch list). This is a fixed API for the 5.5.0 release; we vendor it here so
# the inventory does not depend on the upstream development repo. If a newer ltests.c
# is available, pass --ltests-c to override this set with a live extraction.
UPSTREAM_COMMANDS_FALLBACK: set[str] = {
    "abort", "absindex", "alloccount", "append", "argerror", "arith", "call",
    "callk", "checkstack", "closeslot", "compare", "concat", "copy", "error",
    "func2num", "getfield", "getglobal", "getmetatable", "gettable", "gettop",
    "gsub", "insert", "iscfunction", "isfunction", "isnil", "isnull", "isnumber",
    "isstring", "istable", "isudataval", "isuserdata", "isyieldable", "len",
    "Llen", "loadfile", "loadstring", "Ltolstring", "newmetatable", "newtable",
    "newthread", "newuserdata", "next", "objsize", "pcall", "pcallk", "pop",
    "print", "printstack", "pushbool", "pushcclosure", "pushfstringI",
    "pushfstringP", "pushfstringS", "pushint", "pushnil", "pushnum", "pushstatus",
    "pushstring", "pushupvalueindex", "pushvalue", "rawcheckstack", "rawget",
    "rawgeti", "rawgetp", "rawset", "rawseti", "rawsetp", "remove", "replace",
    "resetthread", "resume", "return", "rotate", "setfield", "setglobal",
    "sethook", "seti", "setmetatable", "settable", "settop", "testudata",
    "threadstatus", "throw", "tobool", "tocfunction", "toclose", "tointeger",
    "tonumber", "topointer", "tostring", "touserdata", "traceback", "type",
    "warning", "warningC", "xmove", "yield", "yieldk",
}


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


def parse_upstream_commands(ltests_c: Path | None = None) -> set[str]:
    # Prefer a live extraction when an ltests.c path is supplied and exists;
    # otherwise fall back to the baked 5.5.0 command surface above.
    if ltests_c is not None and ltests_c.is_file():
        text = ltests_c.read_text(encoding="utf-8", errors="replace")
        return set(re.findall(r'else if EQ\("([^"]+)"\)', text))
    return set(UPSTREAM_COMMANDS_FALLBACK)


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


def build_inventory(ltests_c: Path | None = None) -> dict:
    supported = set(parse_supported_commands())
    upstream = parse_upstream_commands(ltests_c)
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
    parser.add_argument("--ltests-c", default=None, help="Optional path to upstream ltests.c to extract the command set; defaults to the baked 5.5.0 surface.")
    args = parser.parse_args()

    ltests_c = Path(args.ltests_c) if args.ltests_c else None
    inv = build_inventory(ltests_c)
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
