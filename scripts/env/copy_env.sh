#!/usr/bin/env bash
# Discover all *.env files under SEARCH_ROOT (default: git repo root), emit one JSON object
# nested by file path (relative to SEARCH_ROOT) -> {key: value}, copy to clipboard.
# Nesting by path means same-named keys in different files never collide or get merged.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "${SCRIPT_DIR}/.." rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${REPO_ROOT}" ]]; then
  REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
fi

SEARCH_ROOT="${1:-$REPO_ROOT}"
if [[ ! -d "${SEARCH_ROOT}" ]]; then
  echo "error: not a directory: ${SEARCH_ROOT}" >&2
  exit 1
fi
SEARCH_ROOT="$(cd "${SEARCH_ROOT}" && pwd)"

copy_to_clipboard() {
  if command -v wl-copy >/dev/null 2>&1; then
    wl-copy
  elif command -v xsel >/dev/null 2>&1; then
    xsel --clipboard --input
  elif command -v xclip >/dev/null 2>&1; then
    xclip -selection clipboard
  elif command -v pbcopy >/dev/null 2>&1; then
    pbcopy
  else
    echo "error: no clipboard tool found (install wl-copy, xclip, xsel, or use macOS pbcopy)" >&2
    exit 1
  fi
}

export SEARCH_ROOT
COUNT_FILE="$(mktemp)"
trap 'rm -f "${COUNT_FILE}"' EXIT
export COUNT_FILE
OUT="$(
  SEARCH_ROOT="${SEARCH_ROOT}" COUNT_FILE="${COUNT_FILE}" python3 - <<'PY'
import json
import os
import re
import sys
import pathlib

root = pathlib.Path(os.environ["SEARCH_ROOT"]).resolve()
skip_parts = {".git", "node_modules", ".venv", "venv"}


def is_skipped(p: pathlib.Path) -> bool:
    return any(part in skip_parts for part in p.parts)


def is_env_file(p: pathlib.Path) -> bool:
    """service.env or legacy directory .env; not *.example."""
    if not p.is_file() or is_skipped(p):
        return False
    if p.name == ".env":
        return True
    return p.suffix == ".env"


paths = sorted(p for p in root.rglob("*") if is_env_file(p))
if not paths:
    print("error: no *.env files found", file=sys.stderr)
    sys.exit(1)

count_file = os.environ.get("COUNT_FILE")
if count_file:
    pathlib.Path(count_file).write_text(str(len(paths)), encoding="utf-8")

assign_re = re.compile(r"^[ \t]*(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$")


def unquote_double(s: str) -> str:
    out: list[str] = []
    i = 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            if n in '"\\':
                out.append(n)
                i += 2
                continue
            if n == "n":
                out.append("\n")
                i += 2
                continue
            if n == "r":
                out.append("\r")
                i += 2
                continue
            if n == "t":
                out.append("\t")
                i += 2
                continue
            out.append(n)
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def parse_value(raw_val: str) -> str:
    v = raw_val.strip()
    if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
        return unquote_double(v[1:-1])
    if len(v) >= 2 and v[0] == "'" and v[-1] == "'":
        return v[1:-1].replace("\\'", "'").replace("\\\\", "\\")
    return raw_val.rstrip()


def unquote_value(inner: str, quote: str) -> str:
    if quote == '"':
        return unquote_double(inner)
    return inner.replace("\\'", "'").replace("\\\\", "\\")


def find_closing_quote(s: str, quote: str, start: int) -> int:
    """Index of the closing quote in s at/after start, or -1. Backslash-escapes
    only recognized inside double quotes, matching unquote_double."""
    i = start
    while i < len(s):
        c = s[i]
        if quote == '"' and c == "\\" and i + 1 < len(s):
            i += 2
            continue
        if c == quote:
            return i
        i += 1
    return -1


def parse_env_text(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    lines = text.split("\n")
    n = len(lines)
    i = 0
    while i < n:
        line = lines[i]
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            i += 1
            continue
        m = assign_re.match(line)
        if not m:
            i += 1
            continue
        key, rest = m.group(1), m.group(2)
        quote = rest[:1]
        if quote in ('"', "'"):
            # Value may span multiple lines if the quote doesn't close on this line.
            combined = rest
            j = i
            close_idx = find_closing_quote(combined, quote, 1)
            while close_idx == -1 and j + 1 < n:
                j += 1
                combined += "\n" + lines[j]
                close_idx = find_closing_quote(combined, quote, 1)
            if close_idx != -1:
                out[key] = unquote_value(combined[1:close_idx], quote)
                i = j + 1
                continue
            # Unterminated quote even at EOF: fall back to treating the first line as-is.
            out[key] = parse_value(rest)
            i += 1
            continue
        out[key] = parse_value(rest)
        i += 1
    return out


nested: dict[str, dict[str, str]] = {}
for p in paths:
    try:
        data = p.read_text(encoding="utf-8")
    except OSError as e:
        print(f"error: cannot read {p}: {e}", file=sys.stderr)
        sys.exit(1)
    rel = str(p.relative_to(root))
    nested[rel] = parse_env_text(data)

print(json.dumps(nested, ensure_ascii=False, indent=2))
PY
)"

COUNT="$(cat "${COUNT_FILE}")"

printf '%s\n' "${OUT}" | copy_to_clipboard
printf 'Copied nested JSON (keyed by file path) for %s env file(s) to the clipboard (%s).\n' "${COUNT}" "${SEARCH_ROOT}"
