#!/bin/bash
set -euo pipefail

# Update local plugin descriptors based on assets/plugin.lua:
# - sync [location].path
# - sync [plugin] metadata from kkc.register_*_plugin
# Default mode is dry-run (preview only).
# Usage:
#   ./scripts/update-local-plugin-paths.sh            # dry-run
#   ./scripts/update-local-plugin-paths.sh --apply    # write changes

MODE="dry-run"
if [[ "${1:-}" == "--apply" ]]; then
  MODE="apply"
elif [[ -n "${1:-}" ]]; then
  echo "Usage: $0 [--apply]"
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

changed=0
checked=0
missing_assets=0
missing_register=0

is_local_kind() {
  local toml="$1"
  awk '
    /^\[location\]$/ { in_loc=1; next }
    /^\[/ && !/^\[location\]$/ { in_loc=0 }
    in_loc && $0 ~ /^kind[[:space:]]*=[[:space:]]*"local"$/ { print "yes"; exit }
  ' "$toml"
}

read_plugin_id() {
  local toml="$1"
  awk -F'"' '
    /^\[plugin\]$/ { in_plugin=1; next }
    /^\[/ && !/^\[plugin\]$/ { in_plugin=0 }
    in_plugin && $1 ~ /^id[[:space:]]*=[[:space:]]*$/ { print $2; exit }
  ' "$toml"
}

read_location_path() {
  local toml="$1"
  awk -F'"' '
    /^\[location\]$/ { in_loc=1; next }
    /^\[/ && !/^\[location\]$/ { in_loc=0 }
    in_loc && $1 ~ /^path[[:space:]]*=[[:space:]]*$/ { print $2; exit }
  ' "$toml"
}

read_plugin_type() {
  local toml="$1"
  awk -F'"' '
    /^\[plugin\]$/ { in_plugin=1; next }
    /^\[/ && !/^\[plugin\]$/ { in_plugin=0 }
    in_plugin && $1 ~ /^type[[:space:]]*=[[:space:]]*$/ { print $2; exit }
  ' "$toml"
}

sync_toml_from_lua() {
  local toml="$1"
  local lua_file="$2"
  local plugin_type="$3"
  local new_path="$4"
  local mode="$5"

  python3 - "$toml" "$lua_file" "$plugin_type" "$new_path" "$mode" <<'PY'
import json
import re
import sys
from pathlib import Path

toml_path = Path(sys.argv[1])
lua_path = Path(sys.argv[2])
wanted_type = (sys.argv[3] or "").strip()
new_path = sys.argv[4]
mode = sys.argv[5]

toml_lines = toml_path.read_text(encoding="utf-8").splitlines()
lua_text = lua_path.read_text(encoding="utf-8")

reg_pat = re.compile(r"kkc\.register_(viewer|archive|action|other)_plugin\s*\(\s*\{(.*?)\}\s*\)", re.S)
str_pat = lambda key: re.compile(rf"\b{key}\s*=\s*\"([^\"]*)\"")
list_pat = lambda key: re.compile(rf"\b{key}\s*=\s*\{{(.*?)\}}", re.S)
str_in_list_pat = re.compile(r'"([^\"]+)"')

registrations = []
for m in reg_pat.finditer(lua_text):
  rtype = m.group(1)
  block = m.group(2)
  name_m = str_pat("name").search(block)
  version_m = str_pat("version").search(block)
  description_m = str_pat("description").search(block)
  mime_m = list_pat("mime_types").search(block)
  modes_m = list_pat("modes").search(block)
  registrations.append(
    {
      "type": rtype,
      "name": name_m.group(1) if name_m else "",
      "version": version_m.group(1) if version_m else "",
      "description": description_m.group(1) if description_m else "",
      "mime_types": str_in_list_pat.findall(mime_m.group(1)) if mime_m else [],
      "modes": str_in_list_pat.findall(modes_m.group(1)) if modes_m else [],
    }
  )

if not registrations:
  print("NO_REGISTER")
  sys.exit(0)

meta = None
# Prefer viewer registration when available.
for r in registrations:
  if r["type"] == "viewer":
    meta = r
    break

if meta is None and wanted_type:
  for r in registrations:
    if r["type"] == wanted_type:
      meta = r
      break
if meta is None:
  meta = registrations[0]

def quote_toml_string(value: str) -> str:
  escaped = value.replace("\\", "\\\\").replace('"', '\\"')
  return f'"{escaped}"'

def list_literal(items):
  return "[" + ", ".join(quote_toml_string(x) for x in items) + "]"

sections = {}
for i, line in enumerate(toml_lines):
  sm = re.match(r"^\[([^\]]+)\]$", line.strip())
  if sm:
    sections[sm.group(1)] = i

if "plugin" not in sections or "location" not in sections:
  print("INVALID_TOML")
  sys.exit(0)

section_starts = sorted((idx, name) for name, idx in sections.items())

def section_range(name):
  start = sections[name]
  end = len(toml_lines)
  for idx, nm in section_starts:
    if idx > start:
      end = idx
      break
  return start, end

def find_value(name, key):
  start, end = section_range(name)
  key_re = re.compile(rf"^\s*{re.escape(key)}\s*=\s*(.*)$")
  for i in range(start + 1, end):
    m = key_re.match(toml_lines[i])
    if m:
      return i, m.group(1).strip()
  return None, None

def set_key(name, key, rendered_value):
  start, end = section_range(name)
  key_re = re.compile(rf"^\s*{re.escape(key)}\s*=")
  for i in range(start + 1, end):
    if key_re.match(toml_lines[i]):
      toml_lines[i] = f"{key} = {rendered_value}"
      return
  toml_lines.insert(end, f"{key} = {rendered_value}")

desired = {
  "id": meta["name"].replace("_", "-") if meta["name"] else "",
  "name": meta["name"],
  "version": meta["version"],
  "type": meta["type"],
  "description": meta["description"],
  "mime_types": meta["mime_types"],
  "modes": meta["modes"],
}

changes = []

def maybe_set_plugin_str(key, value):
  if not value:
    return
  _, old = find_value("plugin", key)
  new_rendered = quote_toml_string(value)
  if old != new_rendered:
    changes.append((f"plugin.{key}", old or "<missing>", new_rendered))
    set_key("plugin", key, new_rendered)

def maybe_set_plugin_list(key, items):
  if items is None or len(items) == 0:
    return
  _, old = find_value("plugin", key)
  new_rendered = list_literal(items)
  if old != new_rendered:
    changes.append((f"plugin.{key}", old or "<missing>", new_rendered))
    set_key("plugin", key, new_rendered)

maybe_set_plugin_str("id", desired["id"])
maybe_set_plugin_str("name", desired["name"])
maybe_set_plugin_str("version", desired["version"])
maybe_set_plugin_str("type", desired["type"])
maybe_set_plugin_str("description", desired["description"])
maybe_set_plugin_list("mime_types", desired["mime_types"])
if desired["type"] == "viewer":
  maybe_set_plugin_list("modes", desired["modes"])

_, old_path = find_value("location", "path")
new_path_rendered = quote_toml_string(new_path)
if old_path != new_path_rendered:
  changes.append(("location.path", old_path or "<missing>", new_path_rendered))
  set_key("location", "path", new_path_rendered)

if not changes:
  print("UNCHANGED")
  sys.exit(0)

print("CHANGED")
for key, old, new in changes:
  print(f"  {key}: {old} -> {new}")

if mode == "apply":
  toml_path.write_text("\n".join(toml_lines) + "\n", encoding="utf-8")
PY
}

while IFS= read -r toml; do
  checked=$((checked + 1))

  if [[ "$(is_local_kind "$toml")" != "yes" ]]; then
    continue
  fi

  plugin_dir="$(dirname "$toml")"
  plugin_id="$(read_plugin_id "$toml")"
  plugin_type="$(read_plugin_type "$toml")"
  current_path="$(read_location_path "$toml")"

  # 1) Preferred: assets/plugin.lua next to the descriptor.
  candidate_lua="$plugin_dir/assets/plugin.lua"

  # 2) Fallback: assets/plugin.lua in plugins/<normalized-id>/
  if [[ ! -f "$candidate_lua" && -n "$plugin_id" ]]; then
    normalized_id="${plugin_id//-/_}"
    fallback_lua="plugins/$normalized_id/assets/plugin.lua"
    if [[ -f "$fallback_lua" ]]; then
      candidate_lua="$fallback_lua"
    fi
  fi

  if [[ ! -f "$candidate_lua" ]]; then
    echo "WARN: no assets/plugin.lua found for $toml"
    missing_assets=$((missing_assets + 1))
    continue
  fi

  assets_dir="$(dirname "$candidate_lua")"
  new_path="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[2], sys.argv[1]))' "$plugin_dir" "$assets_dir")"

  echo "CHECK: $toml"
  result="$(sync_toml_from_lua "$toml" "$candidate_lua" "$plugin_type" "$new_path" "$MODE")"
  if [[ "$result" == "NO_REGISTER" ]]; then
    echo "WARN: no kkc.register_*_plugin found in $candidate_lua"
    missing_register=$((missing_register + 1))
    continue
  fi
  if [[ "$result" == "INVALID_TOML" ]]; then
    echo "WARN: invalid structure (missing [plugin] or [location]) in $toml"
    continue
  fi
  if [[ "$result" == "UNCHANGED" ]]; then
    echo "OK: $toml (unchanged: $current_path)"
    continue
  fi

  echo "$result"
  if [[ "$MODE" == "apply" ]]; then
    changed=$((changed + 1))
  fi
done < <(find plugins -name plugin.toml -type f | sort)

echo
echo "Checked plugin descriptors: $checked"
echo "Missing assets/plugin.lua: $missing_assets"
echo "Missing kkc.register_*_plugin: $missing_register"
if [[ "$MODE" == "apply" ]]; then
  echo "Updated files: $changed"
else
  echo "Dry-run mode: no files modified (use --apply to write changes)"
fi
