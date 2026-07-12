from __future__ import annotations

import json
import math
import re
import shutil
import subprocess
import time
import uuid
from dataclasses import dataclass
from pathlib import Path

from .manifest import PipelineMetadata, build_manifest, stable_map_id, write_pack_archive
from .models import JobStatus, MapJob
from .source_cache import SourceCache


@dataclass(frozen=True)
class PipelinePaths:
    repo_root: Path
    work_root: Path
    pack_root: Path

    @property
    def osm_extract_root(self) -> Path:
        return self.repo_root / "OSM_Extract"


class CommandRunner:
    def run(self, args: list[str], *, cwd: Path | None = None) -> str:
        result = subprocess.run(args, cwd=cwd, check=True, text=True, capture_output=True)
        return (result.stdout or result.stderr).strip()

    def run_streaming(self, args: list[str], *, cwd: Path | None = None, on_output=None) -> str:
        process = subprocess.Popen(
            args,
            cwd=cwd,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            bufsize=1,
        )
        output: list[str] = []
        try:
            assert process.stdout is not None
            for line in process.stdout:
                output.append(line)
                if on_output:
                    on_output(line)
            return_code = process.wait()
        except BaseException:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            raise
        finally:
            if process.stdout is not None:
                process.stdout.close()
        combined_output = "".join(output)
        if return_code != 0:
            raise subprocess.CalledProcessError(return_code, args, output=combined_output)
        return combined_output.strip()


_MAP_PROGRESS_PATTERN = re.compile(r"MAP_PROGRESS:(\d+):(\d+)")


def parse_map_progress(line: str) -> tuple[int, int] | None:
    match = _MAP_PROGRESS_PATTERN.search(line)
    if match is None:
        return None
    completed, total = int(match.group(1)), int(match.group(2))
    if total <= 0 or completed < 0 or completed > total:
        return None
    return completed, total


class ProgressCoalescer:
    def __init__(self, *, min_interval_seconds: float = 2.0, min_fraction_delta: float = 0.01, clock=None):
        self.min_interval_seconds = min_interval_seconds
        self.min_fraction_delta = min_fraction_delta
        self.clock = clock or time.monotonic
        self.last_completed: int | None = None
        self.last_emitted_at: float | None = None

    def should_emit(self, completed: int, total: int) -> bool:
        now = self.clock()
        block_delta = max(1, math.ceil(total * self.min_fraction_delta))
        should_emit = (
            self.last_completed is None
            or completed >= total
            or completed - self.last_completed >= block_delta
            or self.last_emitted_at is None
            or now - self.last_emitted_at >= self.min_interval_seconds
        )
        if should_emit:
            self.last_completed = completed
            self.last_emitted_at = now
        return should_emit


class MapBuildPipeline:
    def __init__(self, paths: PipelinePaths, runner: CommandRunner | None = None, source_cache: SourceCache | None = None):
        self.paths = paths
        self.runner = runner or CommandRunner()
        self.source_cache = source_cache or SourceCache(paths.repo_root)

    def build(self, job: MapJob, on_status=None, on_progress=None) -> tuple[str, Path]:
        map_id = stable_map_id(job)
        job.map_id = map_id
        attempt_id = re.sub(r"[^a-zA-Z0-9_-]", "-", job.worker_id or f"attempt-{job.attempts}")
        job_dir = self.paths.work_root / job.job_id / attempt_id
        clipped_pbf = job_dir / "clipped.osm.pbf"
        geojson_prefix = job_dir / "features"
        raw_output_dir = job_dir / "raw-map"
        pack_root = job_dir / "pack"
        vectmap_output = pack_root / "VECTMAP" / map_id
        archive_path = job_dir / f"{map_id}.zip"

        if job_dir.exists():
            shutil.rmtree(job_dir)
        job_dir.mkdir(parents=True)

        if on_status:
            on_status(JobStatus.RESOLVING_SOURCE)
        source_pbf = self._source_pbf_path(job)
        if on_status:
            on_status(JobStatus.EXTRACTING_PBF)
        self._extract_pbf(job, source_pbf, clipped_pbf)
        if on_status:
            on_status(JobStatus.CONVERTING_FEATURES)
        self._convert_to_geojson(job, clipped_pbf, geojson_prefix)
        self._extract_features(job, geojson_prefix, raw_output_dir, on_progress=on_progress)
        if on_status:
            on_status(JobStatus.PACKAGING)
        self._stage_vectmap(raw_output_dir, vectmap_output)

        manifest = build_manifest(job, pack_root, self._pipeline_metadata())
        write_pack_archive(pack_root, manifest, archive_path)
        return map_id, archive_path

    def published_archive_path(self, map_id: str, job_id: str) -> Path:
        return self.paths.pack_root / map_id / f"{job_id}.zip"

    def _source_pbf_path(self, job: MapJob) -> Path:
        return self.source_cache.ensure(job.source_region).path

    def _extract_pbf(self, job: MapJob, source_pbf: Path, clipped_pbf: Path) -> None:
        bounds = job.geometry.bounds
        args = [
            "osmium",
            "extract",
            "--strategy=smart",
            "-b",
            f"{bounds.min_lon},{bounds.min_lat},{bounds.max_lon},{bounds.max_lat}",
            str(source_pbf),
            "-o",
            str(clipped_pbf),
            "--overwrite",
        ]
        if job.geometry.geometry and job.geometry.mode.value == "custom_polygon":
            polygon_path = clipped_pbf.parent / "clip.geojson"
            polygon_path.write_text(json.dumps(job.geometry.geometry))
            args = [
                "osmium",
                "extract",
                "--strategy=smart",
                "-p",
                str(polygon_path),
                str(source_pbf),
                "-o",
                str(clipped_pbf),
                "--overwrite",
            ]
        self.runner.run(args)

    def _convert_to_geojson(self, job: MapJob, clipped_pbf: Path, geojson_prefix: Path) -> None:
        bounds = job.geometry.bounds
        script = self.paths.osm_extract_root / "scripts" / "pbf_to_geojson.sh"
        self.runner.run(
            [
                "bash",
                str(script),
                str(bounds.min_lon),
                str(bounds.min_lat),
                str(bounds.max_lon),
                str(bounds.max_lat),
                str(clipped_pbf),
                str(geojson_prefix),
            ],
            cwd=self.paths.osm_extract_root / "scripts",
        )

    def _extract_features(self, job: MapJob, geojson_prefix: Path, raw_output_dir: Path, on_progress=None) -> None:
        bounds = job.geometry.bounds
        script = self.paths.osm_extract_root / "scripts" / "extract_features.py"
        args = [
            "python",
            str(script),
            str(bounds.min_lon),
            str(bounds.min_lat),
            str(bounds.max_lon),
            str(bounds.max_lat),
            str(geojson_prefix),
            str(raw_output_dir),
        ]
        progress_coalescer = ProgressCoalescer()

        def handle_output(line: str) -> None:
            progress = parse_map_progress(line)
            if progress is not None and on_progress and progress_coalescer.should_emit(*progress):
                on_progress(*progress)

        if on_progress and hasattr(self.runner, "run_streaming"):
            self.runner.run_streaming(
                args,
                cwd=self.paths.osm_extract_root / "scripts",
                on_output=handle_output,
            )
            return

        output = self.runner.run(args, cwd=self.paths.osm_extract_root / "scripts")
        if on_progress:
            for line in output.splitlines():
                handle_output(line)

    def _stage_vectmap(self, raw_output_dir: Path, vectmap_output: Path) -> None:
        if not raw_output_dir.exists():
            raise FileNotFoundError(f"OSM_Extract output is missing: {raw_output_dir}")
        vectmap_output.mkdir(parents=True, exist_ok=True)
        for child in raw_output_dir.iterdir():
            destination = vectmap_output / child.name
            if child.is_dir():
                shutil.copytree(child, destination)
            elif child.suffix in {".fmb", ".fmp"}:
                shutil.copy2(child, destination)

    def _pipeline_metadata(self) -> PipelineMetadata:
        osmium_version = "unknown"
        try:
            osmium_version = self.runner.run(["osmium", "--version"]).splitlines()[0]
        except Exception:
            pass
        return PipelineMetadata(osmium_version=osmium_version)


def run_job(store, pipeline: MapBuildPipeline, job_id: str, *, heartbeat_interval_seconds: float = 30.0) -> MapJob:
    worker_id = f"api-{uuid.uuid4().hex[:8]}"
    job = store.claim(job_id, worker_id)

    def update(status: JobStatus) -> None:
        store.update_status_unless_cancelled(job_id, status, worker_id=worker_id)

    def update_progress(completed: int, total: int) -> None:
        store.update_progress_unless_cancelled(job_id, completed, total, worker_id=worker_id)

    try:
        with store.keep_worker_lease_alive(
            job_id,
            worker_id=worker_id,
            interval_seconds=heartbeat_interval_seconds,
        ):
            map_id, archive_path = pipeline.build(job, on_status=update, on_progress=update_progress)
        published_archive = (
            pipeline.published_archive_path(map_id, job.job_id)
            if hasattr(pipeline, "published_archive_path")
            else archive_path
        )
        return store.complete_job(
            job_id,
            worker_id=worker_id,
            map_id=map_id,
            built_archive=archive_path,
            published_archive=published_archive,
        )
    except Exception as exc:
        current = store.get(job_id)
        if current.status == JobStatus.CANCELLED or current.worker_id != worker_id:
            return current
        return store.update_status_unless_cancelled(
            job_id,
            JobStatus.FAILED,
            error=str(exc),
            worker_id=worker_id,
        )
