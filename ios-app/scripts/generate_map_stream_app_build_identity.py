#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path


FULL_GIT_SHA = re.compile(r"[0-9a-f]{40}")


def git_identity(repo_root: Path) -> str:
    try:
        git_sha = subprocess.check_output(
            ["git", "rev-parse", "--verify", "HEAD"],
            cwd=repo_root,
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        dirty = subprocess.check_output(
            [
                "git",
                "status",
                "--porcelain",
                "--untracked-files=normal",
                "--",
                "ios-app",
            ],
            cwd=repo_root,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return "unidentified"
    if not FULL_GIT_SHA.fullmatch(git_sha):
        return "unidentified"
    return git_sha if not dirty.strip() else f"dirty-{git_sha}"


def source_inputs(repo_root: Path) -> list[tuple[str, Path]]:
    roots = (
        "ios-app/BikeComputer/BikeComputer",
        "ios-app/BikeComputer/BikeComputer.xcodeproj/project.pbxproj",
        "ios-app/scripts/generate_map_stream_app_build_identity.py",
    )
    inputs: list[tuple[str, Path]] = []
    for relative in roots:
        path = repo_root / relative
        if path.is_file():
            inputs.append((relative, path))
            continue
        if not path.is_dir():
            raise ValueError(f"missing iOS build input: {relative}")
        for child in sorted(path.rglob("*")):
            if child.is_file():
                inputs.append((child.relative_to(repo_root).as_posix(), child))
    return inputs


def component_sha256(
    inputs: list[tuple[str, Path]],
    inventory: dict[str, str | int],
) -> str:
    digest = hashlib.sha256()
    for logical_name, path in sorted(inputs):
        name = logical_name.encode("utf-8")
        data = path.read_bytes()
        digest.update(b"file\0")
        digest.update(len(name).to_bytes(8, "big"))
        digest.update(name)
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)
    encoded_inventory = json.dumps(
        inventory,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    digest.update(b"build-inventory\0")
    digest.update(len(encoded_inventory).to_bytes(8, "big"))
    digest.update(encoded_inventory)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--configuration", required=True)
    parser.add_argument("--platform", required=True)
    parser.add_argument("--architectures", required=True)
    parser.add_argument("--xcode-version", required=True)
    parser.add_argument("--sdk-build", required=True)
    parser.add_argument("--swift-version", required=True)
    parser.add_argument("--deployment-target", required=True)
    args = parser.parse_args()
    repo_root = args.repo_root.resolve()
    git_sha = git_identity(repo_root)
    inventory: dict[str, str | int] = {
        "schemaVersion": 1,
        "build": args.build,
        "gitSha": git_sha,
        "configuration": args.configuration,
        "platform": args.platform,
        "architectures": args.architectures,
        "xcodeVersion": args.xcode_version,
        "sdkBuild": args.sdk_build,
        "swiftVersion": args.swift_version,
        "deploymentTarget": args.deployment_target,
    }
    document = {
        **inventory,
        "componentSha256": component_sha256(source_inputs(repo_root), inventory),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(document, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
