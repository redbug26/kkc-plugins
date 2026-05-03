#!/usr/bin/env python3
"""release.sh - Prepare and publish a kkc-plugins release.

What this script does:
1. Computes the next repository tag from the latest git tag.
2. Syncs local plugin descriptors from their Lua registration metadata.
3. Syncs github plugin versions from upstream source trees or releases.
4. Rebuilds dist/store-index.json.
5. Commits pending changes, pushes main, creates/pushes the new tag.
6. Waits for CI to regenerate the tagged store index, then pulls main.

Usage:
    ./release.sh              # Increment patch: 0.0.0 -> 0.0.1
    ./release.sh minor        # Increment minor: 0.0.1 -> 0.1.0
    ./release.sh major        # Increment major: 0.1.0 -> 1.0.0
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:
    print("ERROR: Python 3.11+ is required (tomllib missing)", file=sys.stderr)
    raise SystemExit(2)


REPO_ROOT = Path(__file__).resolve().parent
PLUGINS_DIR = REPO_ROOT / "plugins"
BUMP_TYPES = {"major", "minor", "patch"}
REGISTER_BLOCK_RE = re.compile(
    r"kkc\.register_(viewer|archive|action|other)_plugin\s*\(\s*\{(.*?)\}\s*\)",
    re.S,
)


def run(cmd: list[str], capture_output: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=REPO_ROOT,
        check=True,
        text=True,
        capture_output=capture_output,
    )


def http_get_text(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "kkc-release-script"})
    with urllib.request.urlopen(req, timeout=20) as response:
        return response.read().decode("utf-8")


def parse_lua_version(lua_text: str) -> str | None:
    match = re.search(r'version\s*=\s*["\']([^"\']+)["\']', lua_text)
    return match.group(1).strip() if match else None


def quote_toml_string(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def parse_string_list(value: str) -> list[str]:
    return re.findall(r'"([^\"]+)"', value)


def parse_lua_plugin_registrations(lua_text: str) -> list[dict[str, object]]:
    str_pat = lambda key: re.compile(rf"\b{key}\s*=\s*\"([^\"]*)\"")
    list_pat = lambda key: re.compile(rf"\b{key}\s*=\s*\{{(.*?)\}}", re.S)
    registrations: list[dict[str, object]] = []
    for match in REGISTER_BLOCK_RE.finditer(lua_text):
        reg_type = match.group(1)
        block = match.group(2)
        name_match = str_pat("name").search(block)
        version_match = str_pat("version").search(block)
        description_match = str_pat("description").search(block)
        mime_match = list_pat("mime_types").search(block)
        modes_match = list_pat("modes").search(block)
        registrations.append(
            {
                "type": reg_type,
                "name": name_match.group(1) if name_match else "",
                "version": version_match.group(1) if version_match else "",
                "description": description_match.group(1) if description_match else "",
                "mime_types": parse_string_list(mime_match.group(1)) if mime_match else [],
                "modes": parse_string_list(modes_match.group(1)) if modes_match else [],
            }
        )
    return registrations


def find_section_ranges(lines: list[str]) -> dict[str, tuple[int, int]]:
    sections: dict[str, int] = {}
    for index, line in enumerate(lines):
        match = re.match(r"^\[([^\]]+)\]$", line.strip())
        if match:
            sections[match.group(1)] = index

    ordered = sorted((start, name) for name, start in sections.items())
    ranges: dict[str, tuple[int, int]] = {}
    for idx, (start, name) in enumerate(ordered):
        end = ordered[idx + 1][0] if idx + 1 < len(ordered) else len(lines)
        ranges[name] = (start, end)
    return ranges


def find_section_value(lines: list[str], ranges: dict[str, tuple[int, int]], section: str, key: str) -> tuple[int | None, str | None]:
    start, end = ranges[section]
    key_re = re.compile(rf"^\s*{re.escape(key)}\s*=\s*(.*)$")
    for index in range(start + 1, end):
        match = key_re.match(lines[index])
        if match:
            return index, match.group(1).strip()
    return None, None


def set_section_value(lines: list[str], ranges: dict[str, tuple[int, int]], section: str, key: str, rendered_value: str) -> None:
    start, end = ranges[section]
    key_re = re.compile(rf"^\s*{re.escape(key)}\s*=")
    for index in range(start + 1, end):
        if key_re.match(lines[index]):
            lines[index] = f"{key} = {rendered_value}"
            return
    lines.insert(end, f"{key} = {rendered_value}")


def update_plugin_descriptor_from_metadata(
    manifest_path: Path,
    plugin_type: str,
    lua_path: Path,
    location_path: str,
) -> list[tuple[str, str, str]]:
    raw = manifest_path.read_text(encoding="utf-8")
    lines = raw.splitlines()
    ranges = find_section_ranges(lines)
    if "plugin" not in ranges or "location" not in ranges:
        print(f"WARN: {manifest_path}: invalid structure (missing [plugin] or [location])")
        return []

    lua_text = lua_path.read_text(encoding="utf-8")
    registrations = parse_lua_plugin_registrations(lua_text)
    if not registrations:
        print(f"WARN: {manifest_path}: no kkc.register_*_plugin found in {lua_path}")
        return []

    metadata = next((item for item in registrations if item["type"] == "viewer"), None)
    if metadata is None:
        metadata = next((item for item in registrations if item["type"] == plugin_type), None)
    if metadata is None:
        metadata = registrations[0]

    desired = {
        "id": str(metadata["name"]).replace("_", "-") if metadata.get("name") else "",
        "name": str(metadata.get("name") or ""),
        "version": str(metadata.get("version") or ""),
        "type": str(metadata.get("type") or ""),
        "description": str(metadata.get("description") or ""),
        "mime_types": list(metadata.get("mime_types") or []),
        "modes": list(metadata.get("modes") or []),
    }

    changes: list[tuple[str, str, str]] = []

    def maybe_set_str(key: str, value: str) -> None:
        if not value:
            return
        _, old = find_section_value(lines, ranges, "plugin", key)
        new = quote_toml_string(value)
        if old != new:
            changes.append((f"plugin.{key}", old or "<missing>", new))
            set_section_value(lines, ranges, "plugin", key, new)

    def maybe_set_list(key: str, values: list[str]) -> None:
        if not values:
            return
        _, old = find_section_value(lines, ranges, "plugin", key)
        new = "[" + ", ".join(quote_toml_string(item) for item in values) + "]"
        if old != new:
            changes.append((f"plugin.{key}", old or "<missing>", new))
            set_section_value(lines, ranges, "plugin", key, new)

    maybe_set_str("id", desired["id"])
    maybe_set_str("name", desired["name"])
    maybe_set_str("version", desired["version"])
    maybe_set_str("type", desired["type"])
    maybe_set_str("description", desired["description"])
    maybe_set_list("mime_types", desired["mime_types"])
    if desired["type"] == "viewer":
        maybe_set_list("modes", desired["modes"])

    _, old_path = find_section_value(lines, ranges, "location", "path")
    new_path = quote_toml_string(location_path)
    if old_path != new_path:
        changes.append(("location.path", old_path or "<missing>", new_path))
        set_section_value(lines, ranges, "location", "path", new_path)

    if changes:
        manifest_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return changes


def sync_local_plugin_versions() -> None:
    print("Syncing local plugin descriptors from assets/plugin.lua...")
    checked = 0
    changed = 0
    missing_assets = 0

    for manifest_path in sorted(PLUGINS_DIR.glob("*/plugin.toml")):
        raw = manifest_path.read_text(encoding="utf-8")
        data = tomllib.loads(raw)
        location = data.get("location")
        plugin = data.get("plugin")
        if not isinstance(location, dict) or not isinstance(plugin, dict):
            continue
        if str(location.get("kind", "")).strip() != "local":
            continue

        checked += 1
        plugin_dir = manifest_path.parent
        plugin_id = str(plugin.get("id", "")).strip()
        plugin_type = str(plugin.get("type", "")).strip()

        candidate_lua = plugin_dir / "assets" / "plugin.lua"
        if not candidate_lua.is_file() and plugin_id:
            fallback_lua = PLUGINS_DIR / plugin_id.replace("-", "_") / "assets" / "plugin.lua"
            if fallback_lua.is_file():
                candidate_lua = fallback_lua

        if not candidate_lua.is_file():
            print(f"WARN: {manifest_path}: no assets/plugin.lua found")
            missing_assets += 1
            continue

        assets_dir = candidate_lua.parent
        location_path = os.path.relpath(assets_dir, plugin_dir).replace("\\", "/")

        print(f"CHECK: {manifest_path.relative_to(REPO_ROOT)}")
        changes = update_plugin_descriptor_from_metadata(
            manifest_path,
            plugin_type,
            candidate_lua,
            location_path,
        )
        if changes:
            changed += 1
            for key, old, new in changes:
                print(f"  {key}: {old} -> {new}")
        else:
            print("  unchanged")

    print(
        f"Local plugins checked: {checked}, updated: {changed}, missing assets/plugin.lua: {missing_assets}"
    )


def latest_release_version(repo: str) -> str | None:
    url = f"https://api.github.com/repos/{repo}/releases/latest"
    try:
        payload = http_get_text(url)
    except urllib.error.HTTPError as err:
        if err.code == 404:
            return None
        raise
    data = json.loads(payload)
    tag = str(data.get("tag_name") or "").strip()
    if not tag:
        return None
    return tag[1:] if tag.startswith("v") else tag


def fetch_upstream_plugin_version(
    repo: str,
    git_ref: str,
    repo_path: str | None,
    has_asset_url: bool,
) -> str | None:
    if repo_path:
        path = repo_path.strip("/")
        if path:
            for filename in ("plugin.toml", "plugin.lua"):
                raw_url = f"https://raw.githubusercontent.com/{repo}/{git_ref}/{path}/{filename}"
                try:
                    body = http_get_text(raw_url)
                except urllib.error.HTTPError as err:
                    if err.code == 404:
                        continue
                    raise

                if filename == "plugin.toml":
                    try:
                        manifest = tomllib.loads(body)
                        version = manifest.get("plugin", {}).get("version")
                        if isinstance(version, str) and version.strip():
                            return version.strip()
                    except Exception:
                        continue
                else:
                    version = parse_lua_version(body)
                    if version:
                        return version

    if has_asset_url:
        return latest_release_version(repo)

    return None


def sync_github_plugin_versions() -> None:
    print("Syncing github plugin versions from upstream sources...")

    updated: list[tuple[Path, str, str]] = []
    checked: list[tuple[Path, str, str | None]] = []

    for manifest_path in sorted(PLUGINS_DIR.glob("*/plugin.toml")):
        raw = manifest_path.read_text(encoding="utf-8")
        data = tomllib.loads(raw)

        location = data.get("location")
        plugin = data.get("plugin")
        if not isinstance(location, dict) or not isinstance(plugin, dict):
            continue
        if str(location.get("kind", "")).strip() != "github":
            continue

        repo = str(location.get("repo", "")).strip()
        git_ref = str(location.get("ref", "main")).strip() or "main"
        repo_path = location.get("path")
        repo_path = str(repo_path) if repo_path is not None else None
        has_asset_url = bool(str(location.get("asset_url", "")).strip())

        if not repo:
            print(f"WARN: {manifest_path}: missing location.repo, skipping", file=sys.stderr)
            continue

        current = str(plugin.get("version", "")).strip()
        latest = fetch_upstream_plugin_version(repo, git_ref, repo_path, has_asset_url)
        checked.append((manifest_path, current, latest))

        if latest and latest != current:
            new_raw, count = re.subn(
                r'(?m)^(version\s*=\s*")[^"]*("\s*)$',
                rf'\g<1>{latest}\2',
                raw,
                count=1,
            )
            if count != 1:
                print(f"WARN: {manifest_path}: unable to patch version line", file=sys.stderr)
                continue
            manifest_path.write_text(new_raw, encoding="utf-8")
            updated.append((manifest_path, current, latest))

    for path, current, latest in checked:
        print(f"CHECK: {path.relative_to(REPO_ROOT)} current={current} latest={latest or '-'}")

    if updated:
        print("UPDATED:")
        for path, old, new in updated:
            print(f"  {path.relative_to(REPO_ROOT)}: {old} -> {new}")
    else:
        print("No github plugin version changes needed.")


def latest_tag() -> str:
    try:
        out = run(["git", "describe", "--tags", "--abbrev=0"], capture_output=True).stdout.strip()
        return out or "0.0.0"
    except subprocess.CalledProcessError:
        return "0.0.0"


def compute_new_tag(current_tag: str, bump_type: str) -> str:
    current_version = current_tag[1:] if current_tag.startswith("v") else current_tag
    try:
        major, minor, patch = [int(p) for p in current_version.split(".")]
    except Exception as err:
        raise SystemExit(f"ERROR: Invalid current tag version '{current_tag}': {err}")

    if bump_type == "major":
        major += 1
        minor = 0
        patch = 0
    elif bump_type == "minor":
        minor += 1
        patch = 0
    else:
        patch += 1

    return f"{major}.{minor}.{patch}"


def tag_exists(tag: str) -> bool:
    try:
        run(["git", "rev-parse", tag], capture_output=True)
        return True
    except subprocess.CalledProcessError:
        return False


def remote_store_tag() -> str | None:
    try:
        text = run(["git", "show", "origin/main:dist/store-index.json"], capture_output=True).stdout
    except subprocess.CalledProcessError:
        return None
    match = re.search(r'"tag"\s*:\s*"([^"]*)"', text)
    return match.group(1) if match else None


def main() -> int:
    bump_type = sys.argv[1] if len(sys.argv) > 1 else "patch"
    if bump_type not in BUMP_TYPES:
        print(f"ERROR: Invalid bump type '{bump_type}'. Must be major, minor, or patch.")
        return 1

    previous_tag = latest_tag()
    new_tag = compute_new_tag(previous_tag, bump_type)
    if tag_exists(new_tag):
        print(f"ERROR: Tag '{new_tag}' already exists.")
        return 1

    sync_local_plugin_versions()
    sync_github_plugin_versions()

    print("Compiling store index...")
    run(["python3", "scripts/compile_store.py"])

    print("Staging all changes...")
    run(["git", "add", "-A"])

    has_staged = True
    try:
        run(["git", "diff", "--cached", "--quiet"])
        has_staged = False
    except subprocess.CalledProcessError:
        has_staged = True

    if has_staged:
        commit_msg = f"chore: prepare release {new_tag}"
        print(f"Committing changes: {commit_msg}")
        run(["git", "commit", "-m", commit_msg])
    else:
        print("No staged changes to commit.")

    print("Pushing branch updates before tagging...")
    run(["git", "push", "origin", "HEAD"])

    print(f"Creating tag: {new_tag} (previous: {previous_tag})")
    run(["git", "tag", "-a", new_tag, "-m", f"Version {new_tag}"])
    run(["git", "push", "origin", new_tag])
    print(f"✓ Tag '{new_tag}' created and pushed successfully")

    print("Waiting for GitHub Actions workflow to complete...")
    print(f"Checking dist/store-index.json for tag '{new_tag}' (polling every 15s)...")

    max_attempts = 120
    for attempt in range(1, max_attempts + 1):
        try:
            run(["git", "fetch", "origin"], capture_output=True)
        except subprocess.CalledProcessError:
            pass

        remote_tag = remote_store_tag()
        if remote_tag == new_tag:
            print(f"✓ Store index updated with tag '{new_tag}'")
            print("Pulling latest changes from GitHub...")
            run(["git", "pull", "origin", "main"])
            print("✓ Repository synced successfully")
            return 0

        if attempt < max_attempts:
            print(f"  [{attempt}/{max_attempts}] Tag mismatch or not yet updated. Retrying in 15s...")
            time.sleep(15)

    print(f"ERROR: Timeout waiting for store-index.json to be updated with tag '{new_tag}'")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
