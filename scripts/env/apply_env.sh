#!/usr/bin/env bash
# Read env JSON (stdin or clipboard), find all *.example files under SEARCH_ROOT
# (default: git repo root), and write paired *.env files (arr.example -> arr.env).
#
# Accepts two JSON shapes:
#   - nested (current copy_env.sh output): {"containers/arr/arr.env": {"KEY": "value"}, ...}
#     keyed by file path relative to SEARCH_ROOT, so same-named keys in different
#     files never collide.
#   - flat (legacy copy_env.sh output, pre-dating the nested format): {"KEY": "value"}
#     applied to every *.example file, same as historical behavior — kept only so an
#     old vault export can still be restored.
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

read_clipboard() {
  if command -v wl-paste >/dev/null 2>&1; then
    wl-paste --no-newline 2>/dev/null || wl-paste
  elif command -v xsel >/dev/null 2>&1; then
    xsel --clipboard --output
  elif command -v xclip >/dev/null 2>&1; then
    xclip -selection clipboard -o
  elif command -v pbpaste >/dev/null 2>&1; then
    pbpaste
  else
    echo "error: no clipboard read tool found (wl-paste, xclip, xsel, or pbpaste)" >&2
    exit 1
  fi
}

load_json() {
  if [[ ! -t 0 ]]; then
    cat
  else
    read_clipboard
  fi
}

INPUT="$(load_json)"
if [[ -z "${INPUT//[[:space:]]/}" ]]; then
  echo "error: empty JSON (pipe JSON on stdin or place it on the clipboard)" >&2
  exit 1
fi

JSON_FILE="$(mktemp)"
trap 'rm -f "${JSON_FILE}"' EXIT
printf '%s' "${INPUT}" > "${JSON_FILE}"

export SEARCH_ROOT
export JSON_FILE
python3 - <<'PY'
import json
import os
import re
import sys
import pathlib

root = pathlib.Path(os.environ["SEARCH_ROOT"]).resolve()

try:
    with open(os.environ["JSON_FILE"], encoding="utf-8") as f:
        data = json.load(f)
except json.JSONDecodeError as e:
    print(f"error: invalid JSON: {e}", file=sys.stderr)
    sys.exit(1)

if not isinstance(data, dict):
    print("error: JSON root must be an object", file=sys.stderr)
    sys.exit(1)


def normalize_scalar(v: object) -> str:
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    return str(v)


# Detect shape: nested (values are objects, keyed by file path relative to
# SEARCH_ROOT) vs legacy flat (values are scalars, applied to every *.example).
has_dict_values = any(isinstance(v, dict) for v in data.values())
has_scalar_values = any(not isinstance(v, (dict, list)) for v in data.values())

legacy_flat_mode = False
sections: dict[str, dict[str, str]] = {}
flat: dict[str, str] = {}

if has_dict_values and has_scalar_values:
    print(
        "error: JSON mixes nested sections and top-level scalar keys; "
        "expected either all-object (nested by path) or all-scalar (legacy flat)",
        file=sys.stderr,
    )
    sys.exit(1)
elif has_scalar_values and not has_dict_values:
    legacy_flat_mode = True
    for k, v in data.items():
        if not isinstance(k, str):
            print("error: JSON keys must be strings", file=sys.stderr)
            sys.exit(1)
        if isinstance(v, list):
            print(f"error: unexpected list value for {k!r}", file=sys.stderr)
            sys.exit(1)
        flat[k] = normalize_scalar(v)
    print(
        "warning: input JSON is the legacy flat format — same-named keys in "
        "different *.env files will collide. Re-run copy_env.sh to get the "
        "current nested-by-path format.",
        file=sys.stderr,
    )
else:
    # Nested (or empty) — values are per-file dicts keyed by relative path.
    for k, v in data.items():
        if not isinstance(k, str):
            print("error: JSON keys must be strings", file=sys.stderr)
            sys.exit(1)
        if not isinstance(v, dict):
            print(
                f"error: expected an object of key/value pairs for {k!r}, got {type(v).__name__}",
                file=sys.stderr,
            )
            sys.exit(1)
        section: dict[str, str] = {}
        for sk, sv in v.items():
            if not isinstance(sk, str):
                print(f"error: keys in section {k!r} must be strings", file=sys.stderr)
                sys.exit(1)
            if isinstance(sv, (dict, list)):
                print(
                    f"error: expected a scalar value for {k!r}.{sk!r}, got {type(sv).__name__}",
                    file=sys.stderr,
                )
                sys.exit(1)
            section[sk] = normalize_scalar(sv)
        sections[k] = section

skip_parts = {".git", "node_modules", ".venv", "venv"}


def is_skipped(p: pathlib.Path) -> bool:
    return any(part in skip_parts for part in p.parts)


def is_example_file(p: pathlib.Path) -> bool:
    """arr.example -> paired arr.env; skip names without stem."""
    if not p.is_file() or is_skipped(p):
        return False
    if p.suffix != ".example":
        return False
    if not p.stem:
        return False
    return True


# Assignment line (logical line — we only rewrite full-line assignments).
assign_re = re.compile(
    r"^([ \t]*)(export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)([ \t]*=[ \t]*)(.*)$"
)


def format_env_value(val: str) -> str:
    if val == "":
        return ""
    if re.fullmatch(r"[A-Za-z0-9_@%^+\-.,/:]+", val) and not val.startswith("#"):
        return val
    escaped = (
        val.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
    )
    return f'"{escaped}"'


def rewrite_example(text: str, overrides: dict[str, str]) -> tuple[str, set[str]]:
    out_lines = []
    used: set[str] = set()
    for raw in text.splitlines(keepends=True):
        line = raw.rstrip("\r\n")
        end = raw[len(line) :]
        if not line.strip() or line.lstrip().startswith("#"):
            out_lines.append(raw)
            continue
        m = assign_re.match(line)
        if not m:
            out_lines.append(raw)
            continue
        lead, exp, key, eq, _rest = m.groups()
        if key not in overrides:
            out_lines.append(raw)
            continue
        used.add(key)
        new_tail = format_env_value(overrides[key])
        prefix = f"{lead}{exp or ''}{key}{eq}"
        out_lines.append(prefix + new_tail + end)
    return "".join(out_lines), used


examples = sorted(
    p
    for p in root.rglob("*")
    if is_example_file(p)
)

if not examples:
    print(f"error: no *.example files under {root}", file=sys.stderr)
    sys.exit(1)

matched_sections: set[str] = set()

for ex in examples:
    out_path = ex.parent / f"{ex.stem}.env"
    rel = str(out_path.relative_to(root))

    if legacy_flat_mode:
        overrides = flat
    else:
        if rel not in sections:
            print(
                f"warning: no JSON section for {rel} — writing template defaults only",
                file=sys.stderr,
            )
            overrides = {}
        else:
            matched_sections.add(rel)
            overrides = sections[rel]

    try:
        body = ex.read_text(encoding="utf-8")
    except OSError as e:
        print(f"error: cannot read {ex}: {e}", file=sys.stderr)
        sys.exit(1)
    new_body, used = rewrite_example(body, overrides)
    try:
        out_path.write_text(new_body, encoding="utf-8", newline="\n")
    except OSError as e:
        print(f"error: cannot write {out_path}: {e}", file=sys.stderr)
        sys.exit(1)
    print(f"wrote {rel}")

    if not legacy_flat_mode:
        unused = set(overrides) - used
        if unused:
            keys = ", ".join(sorted(unused))
            print(
                f"warning: keys in JSON section {rel} not found in template: {keys}",
                file=sys.stderr,
            )

if not legacy_flat_mode:
    orphans = set(sections) - matched_sections
    if orphans:
        keys = ", ".join(sorted(orphans))
        print(
            f"warning: JSON sections with no matching *.example file: {keys}",
            file=sys.stderr,
        )
PY
