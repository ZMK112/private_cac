#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


REQUIRED_UPSTREAM_KEYS = (
    "Upstream repository",
    "Vendored path",
    "Source acquisition method",
    "Initial pinned tag",
    "Initial pinned commit",
)

REQUIRED_PATCH_IDS = {
    "CAC-BOOT-001": "implemented",
    "CAC-S6-001": "implemented",
    "CAC-PATH-001": "implemented",
    "CAC-AUTH-001": "implemented",
    "CAC-SHELL-001": "implemented",
    "CAC-UPDATE-001": "implemented",
    "CAC-VAL-001": "implemented",
}


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def parse_upstream(md: str) -> dict[str, str]:
    data: dict[str, str] = {}
    for line in md.splitlines():
        match = re.match(r"- ([^:]+): `([^`]+)`", line.strip())
        if match:
            data[match.group(1)] = match.group(2)
    return data


def parse_patches(md: str) -> list[dict[str, object]]:
    patches: list[dict[str, object]] = []
    current: dict[str, object] | None = None
    in_files = False
    current_key: str | None = None

    for raw_line in md.splitlines():
        line = raw_line.rstrip("\n")
        stripped = line.strip()

        if stripped.startswith("### `") and stripped.endswith("`"):
            patch_id = stripped[len("### `") : -1]
            current = {
                "id": patch_id,
                "status": "",
                "files": [],
                "reason": [],
                "verification": [],
                "upstream_status": [],
            }
            patches.append(current)
            in_files = False
            current_key = None
            continue

        if current is None:
            continue

        if stripped.startswith("- Status:"):
            current["status"] = stripped.split(":", 1)[1].strip()
            in_files = False
            current_key = None
            continue

        if stripped == "- Files:":
            in_files = True
            current_key = "files"
            continue

        if in_files:
            if stripped.startswith("- ") and not line.startswith("  "):
                in_files = False
                current_key = None
            elif stripped.startswith("- `") and stripped.endswith("`"):
                current["files"].append(stripped[len("- `") : -1])
                continue
            elif stripped.startswith("- "):
                current["files"].append(stripped[2:].strip())
                continue
            elif stripped.startswith("Reason:") or stripped.startswith("- Reason:"):
                in_files = False
                current_key = None

        if stripped.startswith("- Reason:"):
            value = stripped.split(":", 1)[1].strip()
            if value:
                current["reason"].append(value)
            current_key = "reason"
            continue

        if stripped.startswith("- Verification:"):
            current_key = "verification"
            continue

        if stripped.startswith("- Upstream status:"):
            value = stripped.split(":", 1)[1].strip()
            if value:
                current["upstream_status"].append(value)
            current_key = "upstream_status"
            continue

        if line.startswith("  - ") and current_key in {"reason", "verification", "upstream_status"}:
            current[current_key].append(stripped[2:].strip())
            continue

        if line.startswith("  ") and current_key in {"reason", "upstream_status"}:
            value = stripped
            if value:
                current[current_key].append(value)
            continue

    return patches


def check_upstream(root: Path, data: dict[str, str]) -> list[str]:
    errors: list[str] = []
    for key in REQUIRED_UPSTREAM_KEYS:
        if not data.get(key):
            errors.append(f"UPSTREAM.md missing required key: {key}")

    vendored_path = data.get("Vendored path")
    if vendored_path:
        vendored = root / vendored_path
        if not vendored.exists():
            errors.append(f"Vendored path does not exist: {vendored_path}")
        elif not (vendored / "package.json").exists():
            errors.append(f"Vendored path is missing package.json: {vendored_path}")

    return errors


def check_patches(root: Path, patches: list[dict[str, object]]) -> list[str]:
    errors: list[str] = []
    seen: set[str] = set()

    for patch in patches:
        patch_id = str(patch["id"])
        status = str(patch.get("status", "")).strip()
        files = list(patch.get("files", []))

        if patch_id in seen:
            errors.append(f"Duplicate patch id in PATCHES.md: {patch_id}")
        seen.add(patch_id)

        if not status:
            errors.append(f"Patch {patch_id} is missing a status")

        if status == "implemented" and not files:
            errors.append(f"Implemented patch {patch_id} should list at least one file")

        for rel in files:
            candidate = root / str(rel)
            if not candidate.exists():
                errors.append(f"Patch {patch_id} references missing file: {rel}")

    for patch_id, expected_status in REQUIRED_PATCH_IDS.items():
        matches = [p for p in patches if p["id"] == patch_id]
        if not matches:
            errors.append(f"Required patch id missing from PATCHES.md: {patch_id}")
            continue
        actual_status = str(matches[0].get("status", "")).strip()
        if actual_status != expected_status:
            errors.append(
                f"Required patch {patch_id} has status '{actual_status}', expected '{expected_status}'"
            )

    return errors


def print_summary(root: Path, upstream: dict[str, str], patches: list[dict[str, object]]) -> None:
    print("CloudCLI upstream summary")
    print(f"  repo:    {upstream.get('Upstream repository', '?')}")
    print(f"  path:    {upstream.get('Vendored path', '?')}")
    print(f"  tag:     {upstream.get('Initial pinned tag', '?')}")
    print(f"  commit:  {upstream.get('Initial pinned commit', '?')}")
    print("  patches:")
    for patch in patches:
        patch_id = str(patch['id'])
        status = str(patch.get("status", "")).strip() or "missing-status"
        files = len(list(patch.get("files", [])))
        print(f"    - {patch_id}: {status} ({files} files)")
    print(f"  root:    {root}")


def normalize_patch(patch: dict[str, object]) -> dict[str, object]:
    return {
        "id": str(patch["id"]),
        "status": str(patch.get("status", "")).strip(),
        "files": list(patch.get("files", [])),
        "reason": list(patch.get("reason", [])),
        "verification": list(patch.get("verification", [])),
        "upstream_status": list(patch.get("upstream_status", [])),
    }


def print_patch_report(patches: list[dict[str, object]], patch_id: str | None = None) -> int:
    selected = [normalize_patch(p) for p in patches if patch_id is None or p["id"] == patch_id]
    if patch_id and not selected:
        print(f"Patch not found: {patch_id}", file=sys.stderr)
        return 1

    for idx, patch in enumerate(selected):
        if idx:
            print()
        print(f"{patch['id']} [{patch['status']}]")
        print("  Files:")
        for rel in patch["files"]:
            print(f"    - {rel}")
        if patch["reason"]:
            print("  Reason:")
            for item in patch["reason"]:
                print(f"    - {item}")
        if patch["verification"]:
            print("  Verification:")
            for item in patch["verification"]:
                print(f"    - {item}")
        if patch["upstream_status"]:
            print("  Upstream status:")
            for item in patch["upstream_status"]:
                print(f"    - {item}")
    return 0


def print_json_report(root: Path, upstream: dict[str, str], patches: list[dict[str, object]]) -> None:
    payload = {
        "repo_root": str(root),
        "upstream": upstream,
        "patches": [normalize_patch(p) for p in patches],
    }
    print(json.dumps(payload, indent=2, ensure_ascii=False))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="exit non-zero if metadata is inconsistent")
    parser.add_argument("--report", action="store_true", help="print a detailed patch report")
    parser.add_argument("--patch", help="show only one patch id when used with --report")
    parser.add_argument("--json", action="store_true", help="print upstream + patch metadata as JSON")
    args = parser.parse_args()

    root = repo_root()
    upstream_path = root / "docker/vendor/cloudcli/UPSTREAM.md"
    patches_path = root / "docker/vendor/cloudcli/PATCHES.md"

    upstream = parse_upstream(upstream_path.read_text(encoding="utf-8"))
    patches = parse_patches(patches_path.read_text(encoding="utf-8"))
    if args.json:
        print_json_report(root, upstream, patches)
    elif args.report:
        report_rc = print_patch_report(patches, args.patch)
        if report_rc != 0:
            return report_rc
    else:
        print_summary(root, upstream, patches)

    if not args.check:
      return 0

    errors = []
    errors.extend(check_upstream(root, upstream))
    errors.extend(check_patches(root, patches))

    if errors:
        print("\nAudit errors:", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
