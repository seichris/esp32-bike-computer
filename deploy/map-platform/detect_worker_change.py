#!/usr/bin/env python3
"""Determine whether a Git range changes signed worker build inputs."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath
from typing import Iterable


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "backend"))

from map_platform.map_stream_build_identity import WORKER_SOURCE_ROOTS  # noqa: E402


COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}")


def normalize_repo_path(value: str) -> str:
    path = PurePosixPath(value.strip())
    if path.is_absolute() or ".." in path.parts:
        raise ValueError(f"changed path is outside the repository: {value}")
    return path.as_posix()


def worker_inputs_changed(paths: Iterable[str]) -> bool:
    roots = tuple(root.rstrip("/") for root in WORKER_SOURCE_ROOTS)
    for raw_path in paths:
        path = normalize_repo_path(raw_path)
        if any(path == root or path.startswith(f"{root}/") for root in roots):
            return True
    return False


def git_changed_paths(repo_root: Path, before: str, after: str) -> list[str] | None:
    if (
        COMMIT_PATTERN.fullmatch(before) is None
        or set(before) == {"0"}
        or COMMIT_PATTERN.fullmatch(after) is None
    ):
        return None
    ancestor = subprocess.run(
        ["git", "merge-base", "--is-ancestor", before, after],
        cwd=repo_root,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if ancestor.returncode != 0:
        return None
    completed = subprocess.run(
        ["git", "diff", "--name-only", "-z", before, after],
        cwd=repo_root,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    return [
        value.decode("utf-8")
        for value in completed.stdout.split(b"\0")
        if value
    ]


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Print true when a Git range changes map worker identity inputs",
    )
    parser.add_argument("--before", default="")
    parser.add_argument("--after", required=True)
    parser.add_argument("--repo-root", type=Path, default=REPO_ROOT)
    args = parser.parse_args()

    paths = git_changed_paths(args.repo_root.resolve(), args.before, args.after)
    # Unknown ranges, including manual dispatches, conservatively propose the
    # candidate as both control plane and worker for explicit human review.
    changed = True if paths is None else worker_inputs_changed(paths)
    print("true" if changed else "false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
