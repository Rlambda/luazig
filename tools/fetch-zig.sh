#!/bin/sh
set -eu

version="${1:-}"
if [ -z "$version" ]; then
  echo "usage: $0 <zig-version>" >&2
  echo "example: $0 0.15.2" >&2
  exit 2
fi

fetch() {
  url="$1"
  out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$out"
    return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url"
    return 0
  fi
  echo "error: need curl or wget" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

index="$tmp/index.json"
fetch "https://ziglang.org/download/index.json" "$index"

python3 - "$index" "$version" "$tmp" <<'PY'
import json, sys, os

index_path, version, tmp = sys.argv[1:4]
with open(index_path, "rb") as f:
    data = json.load(f)

node = data.get(version)
if not node:
    print(f"error: version '{version}' not found in index.json", file=sys.stderr)
    sys.exit(1)

plat = node.get("x86_64-linux") or node.get("x86_64-linux-musl")  # prefer glibc if present
if not plat:
    print("error: no linux x86_64 build entry for this version", file=sys.stderr)
    sys.exit(1)

tarball = plat.get("tarball")
shasum = plat.get("shasum")
if not tarball or not shasum:
    print("error: malformed index entry (missing tarball/shasum)", file=sys.stderr)
    sys.exit(1)

with open(os.path.join(tmp, "tarball.url"), "w", encoding="utf-8") as f:
    f.write(tarball)
with open(os.path.join(tmp, "tarball.sha256"), "w", encoding="utf-8") as f:
    f.write(shasum)
PY

tar_url="$(cat "$tmp/tarball.url")"
tar_sha="$(cat "$tmp/tarball.sha256")"
tar_path="$tmp/zig.tar.xz"

fetch "$tar_url" "$tar_path"
printf "%s  %s\n" "$tar_sha" "$tar_path" | sha256sum -c -

rm -rf tools/zig-bin
mkdir -p tools/zig-bin
tar -xJf "$tar_path" -C tools/zig-bin --strip-components=1

if [ ! -x tools/zig-bin/zig ]; then
  echo "error: extracted toolchain does not contain tools/zig-bin/zig" >&2
  exit 1
fi

echo "installed: $(tools/zig-bin/zig version)"

