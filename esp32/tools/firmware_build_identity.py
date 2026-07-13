from __future__ import annotations

import re
import subprocess
from pathlib import Path


FULL_GIT_SHA = re.compile(r"[0-9a-f]{40}")


def firmware_git_identity(repo_root: Path) -> str:
    """Return a release-grade source identity, or a fail-closed dirty marker."""
    try:
        git_sha = subprocess.check_output(
            ["git", "rev-parse", "--verify", "HEAD"],
            cwd=repo_root,
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        if not FULL_GIT_SHA.fullmatch(git_sha):
            return "unidentified"
        dirty = subprocess.check_output(
            ["git", "status", "--porcelain", "--untracked-files=normal"],
            cwd=repo_root,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        return git_sha if not dirty.strip() else f"dirty-{git_sha}"
    except (OSError, subprocess.CalledProcessError):
        return "unidentified"
