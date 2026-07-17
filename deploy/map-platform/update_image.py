#!/usr/bin/env python3
"""Validate or update immutable map-platform production images."""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from pathlib import Path


IMAGE_REPOSITORY = "ghcr.io/seichris/open-bike-computer-map-platform"
DIGEST_PATTERN = re.compile(r"sha256:[0-9a-f]{64}")
REFERENCE_PATTERN = re.compile(
    rf"{re.escape(IMAGE_REPOSITORY)}@(?P<digest>sha256:[0-9a-f]{{64}})"
)
COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}")
CONTROL_SOURCE_PATTERN = re.compile(
    r"^# control-plane-source-commit: (?P<commit>[0-9a-f]{40})$",
    re.MULTILINE,
)
WORKER_SOURCE_PATTERN = re.compile(
    r"^# worker-source-commit: (?P<commit>[0-9a-f]{40})$",
    re.MULTILINE,
)
CONTROL_IMAGE_PATTERN = re.compile(
    rf"^(?P<prefix>  control-plane: &map-platform-control-plane-image )(?P<reference>{re.escape(IMAGE_REPOSITORY)}@sha256:[0-9a-f]{{64}})$",
    re.MULTILINE,
)
WORKER_IMAGE_PATTERN = re.compile(
    rf"^(?P<prefix>  worker: &map-platform-worker-image )(?P<reference>{re.escape(IMAGE_REPOSITORY)}@sha256:[0-9a-f]{{64}})$",
    re.MULTILINE,
)
CONTROL_SERVICE_IMAGE_PATTERN = re.compile(
    r"^    image: \*map-platform-control-plane-image$",
    re.MULTILINE,
)
WORKER_SERVICE_IMAGE_PATTERN = re.compile(
    r"^    image: \*map-platform-worker-image$",
    re.MULTILINE,
)
IDENTITY_ENV_PATTERN = re.compile(
    r"^      MAP_PLATFORM_WORKER_IMAGE_REFERENCE: \*map-platform-worker-image$",
    re.MULTILINE,
)


@dataclass(frozen=True)
class DeploymentImages:
    control_plane_source_commit: str
    control_plane_reference: str
    worker_source_commit: str
    worker_reference: str

    @staticmethod
    def _digest(reference: str) -> str:
        match = REFERENCE_PATTERN.fullmatch(reference)
        if match is None:  # pragma: no cover - guarded by validation
            raise ValueError("production image reference is invalid")
        return match.group("digest")

    @property
    def control_plane_digest(self) -> str:
        return self._digest(self.control_plane_reference)

    @property
    def worker_digest(self) -> str:
        return self._digest(self.worker_reference)


def _single_match(pattern: re.Pattern[str], text: str, description: str) -> re.Match[str]:
    matches = list(pattern.finditer(text))
    if len(matches) != 1:
        raise ValueError(f"production Compose must contain exactly one {description}")
    return matches[0]


def validate_manifest_text(text: str) -> DeploymentImages:
    control_source = _single_match(
        CONTROL_SOURCE_PATTERN,
        text,
        "control-plane source-commit marker",
    )
    worker_source = _single_match(
        WORKER_SOURCE_PATTERN,
        text,
        "worker source-commit marker",
    )
    control_image = _single_match(
        CONTROL_IMAGE_PATTERN,
        text,
        "pinned control-plane image anchor",
    )
    worker_image = _single_match(
        WORKER_IMAGE_PATTERN,
        text,
        "pinned worker image anchor",
    )
    if len(CONTROL_SERVICE_IMAGE_PATTERN.findall(text)) != 2:
        raise ValueError("API and maintenance must use the pinned control-plane image")
    if len(WORKER_SERVICE_IMAGE_PATTERN.findall(text)) != 1:
        raise ValueError("the worker service must use the pinned worker image")
    if len(IDENTITY_ENV_PATTERN.findall(text)) != 2:
        raise ValueError("API and worker must receive the pinned worker image identity")
    if "MAP_PLATFORM_WORKER_IMAGE}" in text or "MAP_PLATFORM_WORKER_IMAGE:-" in text:
        raise ValueError("production Compose must not depend on a mutable Coolify image variable")

    control_reference = control_image.group("reference")
    worker_reference = worker_image.group("reference")
    if REFERENCE_PATTERN.fullmatch(control_reference) is None:
        raise ValueError("control-plane image must use the expected repository and OCI digest")
    if REFERENCE_PATTERN.fullmatch(worker_reference) is None:
        raise ValueError("worker image must use the expected repository and OCI digest")
    return DeploymentImages(
        control_plane_source_commit=control_source.group("commit"),
        control_plane_reference=control_reference,
        worker_source_commit=worker_source.group("commit"),
        worker_reference=worker_reference,
    )


def validate_manifest(path: Path) -> DeploymentImages:
    return validate_manifest_text(path.read_text(encoding="utf-8"))


def _validate_update_value(value: str, pattern: re.Pattern[str], description: str) -> None:
    if pattern.fullmatch(value) is None:
        raise ValueError(description)


def update_manifest(
    path: Path,
    *,
    control_plane_digest: str,
    source_commit: str,
    worker_digest: str | None = None,
) -> DeploymentImages:
    _validate_update_value(
        control_plane_digest,
        DIGEST_PATTERN,
        "control-plane digest must be sha256 followed by 64 lowercase hexadecimal characters",
    )
    if worker_digest is not None:
        _validate_update_value(
            worker_digest,
            DIGEST_PATTERN,
            "worker digest must be sha256 followed by 64 lowercase hexadecimal characters",
        )
    _validate_update_value(
        source_commit,
        COMMIT_PATTERN,
        "source commit must be a full 40-character lowercase Git SHA",
    )

    text = path.read_text(encoding="utf-8")
    validate_manifest_text(text)
    control_reference = f"{IMAGE_REPOSITORY}@{control_plane_digest}"
    updated = CONTROL_SOURCE_PATTERN.sub(
        f"# control-plane-source-commit: {source_commit}",
        text,
    )
    updated = CONTROL_IMAGE_PATTERN.sub(
        lambda match: f"{match.group('prefix')}{control_reference}",
        updated,
    )
    if worker_digest is not None:
        worker_reference = f"{IMAGE_REPOSITORY}@{worker_digest}"
        updated = WORKER_SOURCE_PATTERN.sub(
            f"# worker-source-commit: {source_commit}",
            updated,
        )
        updated = WORKER_IMAGE_PATTERN.sub(
            lambda match: f"{match.group('prefix')}{worker_reference}",
            updated,
        )

    deployment = validate_manifest_text(updated)
    if (
        deployment.control_plane_source_commit != source_commit
        or deployment.control_plane_reference != control_reference
    ):
        raise ValueError("control-plane update did not persist the requested identity")
    if worker_digest is not None and (
        deployment.worker_source_commit != source_commit
        or deployment.worker_digest != worker_digest
    ):
        raise ValueError("worker update did not persist the requested identity")
    if updated != text:
        path.write_text(updated, encoding="utf-8")
    return deployment


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate or update digest-pinned map-platform production images",
    )
    parser.add_argument("compose", type=Path)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--control-plane-digest")
    parser.add_argument("--worker-digest")
    parser.add_argument("--source-commit")
    args = parser.parse_args()

    if args.check:
        if args.worker_digest is not None or args.source_commit is not None:
            parser.error("update arguments are not valid with --check")
        deployment = validate_manifest(args.compose)
    else:
        if args.source_commit is None:
            parser.error("--source-commit is required with --control-plane-digest")
        deployment = update_manifest(
            args.compose,
            control_plane_digest=args.control_plane_digest,
            worker_digest=args.worker_digest,
            source_commit=args.source_commit,
        )
    print(
        f"control-plane {deployment.control_plane_source_commit} "
        f"{deployment.control_plane_reference}"
    )
    print(f"worker {deployment.worker_source_commit} {deployment.worker_reference}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
