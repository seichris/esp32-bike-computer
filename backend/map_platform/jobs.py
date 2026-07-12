from __future__ import annotations

import json
import os
import re
import threading
import time
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .geometry import GeometryError, normalize_geometry
from .limits import JobLimits, LimitError
from .models import JobStatus, MapJob, utc_now_iso
from .sources import SourceIndex, SourceResolutionError


class JobStore:
    def __init__(self, root: str | Path, *, lock_stale_seconds: float = 300.0):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self.lock_path = self.root / ".queue.lock"
        self.lock_stale_seconds = lock_stale_seconds

    def save(self, job: MapJob) -> None:
        path = self._path(job.job_id)
        tmp_path = path.with_suffix(".json.tmp")
        tmp_path.write_text(json.dumps(job.to_dict(), indent=2, sort_keys=True) + "\n")
        tmp_path.replace(path)

    def get(self, job_id: str) -> MapJob:
        path = self._path(job_id)
        if not path.exists():
            raise KeyError(job_id)
        return MapJob.from_dict(json.loads(path.read_text()))

    def list(self) -> list[MapJob]:
        return [MapJob.from_dict(json.loads(path.read_text())) for path in sorted(self.root.glob("*.json"))]

    def update_status(
        self,
        job_id: str,
        status: JobStatus,
        *,
        error: str | None = None,
        map_id: str | None = None,
        pack_path: str | None = None,
        pack_bytes: int | None = None,
        worker_id: str | None = None,
        event: str | None = None,
        finished: bool = False,
    ) -> MapJob:
        with self._queue_lock():
            return self._update_status_unlocked(
                job_id,
                status,
                error=error,
                map_id=map_id,
                pack_path=pack_path,
                pack_bytes=pack_bytes,
                worker_id=worker_id,
                event=event,
                finished=finished,
            )

    def update_status_unless_cancelled(
        self,
        job_id: str,
        status: JobStatus,
        *,
        error: str | None = None,
        map_id: str | None = None,
        pack_path: str | None = None,
        pack_bytes: int | None = None,
        worker_id: str | None = None,
        event: str | None = None,
        finished: bool = False,
    ) -> MapJob:
        with self._queue_lock():
            current = self.get(job_id)
            if current.status == JobStatus.CANCELLED:
                raise RuntimeError("job was cancelled")
            if worker_id is not None and current.worker_id not in {None, worker_id}:
                raise RuntimeError("job is owned by another worker")
            return self._update_status_unlocked(
                job_id,
                status,
                error=error,
                map_id=map_id,
                pack_path=pack_path,
                pack_bytes=pack_bytes,
                worker_id=worker_id,
                event=event,
                finished=finished,
            )

    def _update_status_unlocked(
        self,
        job_id: str,
        status: JobStatus,
        *,
        error: str | None = None,
        map_id: str | None = None,
        pack_path: str | None = None,
        pack_bytes: int | None = None,
        worker_id: str | None = None,
        event: str | None = None,
        finished: bool = False,
    ) -> MapJob:
        job = self.get(job_id)
        previous_status = job.status
        job.status = status
        job.updated_at = utc_now_iso()
        job.error = error
        if previous_status != status and status in {JobStatus.QUEUED, JobStatus.VALIDATING}:
            job.progress_completed = None
            job.progress_total = None
        if status in {JobStatus.VALIDATING, JobStatus.RESOLVING_SOURCE, JobStatus.EXTRACTING_PBF} and job.started_at is None:
            job.started_at = job.updated_at
        if finished or status in {JobStatus.READY, JobStatus.FAILED, JobStatus.EXPIRED, JobStatus.CANCELLED}:
            job.finished_at = job.updated_at
        else:
            job.finished_at = None
        if map_id is not None:
            job.map_id = map_id
        if pack_path is not None:
            job.pack_path = pack_path
        if pack_bytes is not None:
            job.pack_bytes = pack_bytes
        if worker_id is not None:
            job.worker_id = worker_id
        if event or previous_status != status:
            job.events.append(
                {
                    "at": job.updated_at,
                    "status": status.value,
                    "message": event or f"entered {status.value}",
                }
            )
        self.save(job)
        return job

    def update_progress_unless_cancelled(
        self,
        job_id: str,
        completed: int,
        total: int,
        *,
        worker_id: str | None = None,
    ) -> MapJob:
        if total <= 0:
            raise ValueError("progress total must be positive")
        with self._queue_lock():
            job = self.get(job_id)
            if job.status == JobStatus.CANCELLED:
                raise RuntimeError("job was cancelled")
            if worker_id is not None and job.worker_id not in {None, worker_id}:
                raise RuntimeError("job is owned by another worker")
            job.progress_completed = max(0, min(int(completed), int(total)))
            job.progress_total = int(total)
            job.updated_at = utc_now_iso()
            if worker_id is not None:
                job.worker_id = worker_id
            self.save(job)
            return job

    def heartbeat_unless_cancelled(self, job_id: str, *, worker_id: str) -> MapJob:
        with self._queue_lock():
            job = self.get(job_id)
            if job.status == JobStatus.CANCELLED:
                raise RuntimeError("job was cancelled")
            if job.worker_id != worker_id:
                raise RuntimeError("job is owned by another worker")
            job.updated_at = utc_now_iso()
            self.save(job)
            return job

    @contextmanager
    def keep_worker_lease_alive(self, job_id: str, *, worker_id: str, interval_seconds: float = 30.0):
        if interval_seconds <= 0:
            raise ValueError("heartbeat interval must be positive")
        stop = threading.Event()

        def heartbeat_loop() -> None:
            while not stop.wait(interval_seconds):
                try:
                    self.heartbeat_unless_cancelled(job_id, worker_id=worker_id)
                except (KeyError, RuntimeError):
                    return

        thread = threading.Thread(target=heartbeat_loop, name=f"map-job-heartbeat-{job_id}", daemon=True)
        thread.start()
        try:
            yield
        finally:
            stop.set()
            thread.join(timeout=max(interval_seconds, 1.0))

    def claim(self, job_id: str, worker_id: str) -> MapJob:
        with self._queue_lock():
            job = self.get(job_id)
            if job.status != JobStatus.QUEUED:
                raise JobClaimError(f"job is {job.status.value}, not queued")
            return self._claim_unlocked(job, worker_id)

    def claim_next(self, worker_id: str, *, interrupted_job_stale_seconds: float | None = None) -> MapJob | None:
        with self._queue_lock():
            for job in self.list():
                if job.status != JobStatus.QUEUED:
                    continue
                claimed = self._claim_unlocked(job, worker_id)
                if claimed.status == JobStatus.VALIDATING:
                    return claimed
            if interrupted_job_stale_seconds is None:
                return None
            for job in self.list():
                if not self._is_interrupted(job, worker_id, interrupted_job_stale_seconds):
                    continue
                job.status = JobStatus.QUEUED
                job.updated_at = utc_now_iso()
                job.finished_at = None
                job.progress_completed = None
                job.progress_total = None
                job.events.append(
                    {
                        "at": job.updated_at,
                        "status": JobStatus.QUEUED.value,
                        "message": "requeued after worker restart",
                    }
                )
                claimed = self._claim_unlocked(job, worker_id)
                if claimed.status == JobStatus.VALIDATING:
                    return claimed
            return None

    def _claim_unlocked(self, job: MapJob, worker_id: str) -> MapJob:
        if job.attempts >= job.max_attempts:
            return self._update_status_unlocked(
                job.job_id,
                JobStatus.FAILED,
                error="maximum retry attempts exceeded",
                finished=True,
            )
        job.status = JobStatus.VALIDATING
        job.updated_at = utc_now_iso()
        job.started_at = job.started_at or job.updated_at
        job.worker_id = worker_id
        job.attempts += 1
        job.error = None
        job.progress_completed = None
        job.progress_total = None
        job.events.append(
            {
                "at": job.updated_at,
                "status": job.status.value,
                "message": f"claimed by worker {worker_id}",
            }
        )
        self.save(job)
        return job

    def requeue_retryable_failures(self) -> int:
        count = 0
        with self._queue_lock():
            for job in self.list():
                if job.status == JobStatus.FAILED and job.attempts < job.max_attempts:
                    job.status = JobStatus.QUEUED
                    job.updated_at = utc_now_iso()
                    job.finished_at = None
                    job.progress_completed = None
                    job.progress_total = None
                    job.events.append({"at": job.updated_at, "status": job.status.value, "message": "requeued for retry"})
                    self.save(job)
                    count += 1
        return count

    def _is_interrupted(self, job: MapJob, worker_id: str, stale_after_seconds: float) -> bool:
        active_statuses = {
            JobStatus.VALIDATING,
            JobStatus.RESOLVING_SOURCE,
            JobStatus.EXTRACTING_PBF,
            JobStatus.CONVERTING_FEATURES,
            JobStatus.PACKAGING,
        }
        return (
            job.status in active_statuses
            and bool(job.worker_id)
            and job.worker_id != worker_id
            and _age_seconds(job.updated_at) >= stale_after_seconds
        )

    def _path(self, job_id: str) -> Path:
        if not re.match(r"^[a-zA-Z0-9_-]+$", job_id):
            raise ValueError("invalid job id")
        return self.root / f"{job_id}.json"

    @contextmanager
    def _queue_lock(self):
        deadline = time.monotonic() + 30
        fd: int | None = None
        while fd is None:
            try:
                fd = os.open(self.lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                os.write(fd, str(os.getpid()).encode("utf-8"))
            except FileExistsError:
                self._remove_stale_lock()
                if time.monotonic() > deadline:
                    raise TimeoutError("timed out waiting for job queue lock")
                time.sleep(0.05)
        try:
            yield
        finally:
            if fd is not None:
                os.close(fd)
            self.lock_path.unlink(missing_ok=True)

    def _remove_stale_lock(self) -> None:
        try:
            age_seconds = time.time() - self.lock_path.stat().st_mtime
        except FileNotFoundError:
            return
        if age_seconds > self.lock_stale_seconds:
            self.lock_path.unlink(missing_ok=True)


class MapJobService:
    def __init__(self, source_index: SourceIndex, store: JobStore, limits: JobLimits | None = None):
        self.source_index = source_index
        self.store = store
        self.limits = limits or JobLimits()

    def create_job(self, request: dict[str, Any]) -> MapJob:
        try:
            geometry = normalize_geometry(request)
            self.limits.validate_geometry(geometry)
            self.limits.validate_active_jobs(self.store.list())
            source = self.source_index.resolve_for_bounds(geometry.bounds)
        except (GeometryError, LimitError, SourceResolutionError) as exc:
            raise ValueError(str(exc)) from exc
        job = MapJob(
            job_id=self._new_job_id(),
            status=JobStatus.QUEUED,
            request=dict(request),
            geometry=geometry,
            source_region=source,
        )
        self.store.save(job)
        return job

    def get_job(self, job_id: str) -> MapJob:
        return self.store.get(job_id)

    def list_jobs(self) -> list[MapJob]:
        return self.store.list()

    def find_by_map_id(self, map_id: str) -> MapJob | None:
        for job in self.store.list():
            if job.map_id == map_id:
                return job
        return None

    def cancel_job(self, job_id: str) -> MapJob:
        job = self.store.get(job_id)
        if job.status in {JobStatus.READY, JobStatus.FAILED, JobStatus.EXPIRED, JobStatus.CANCELLED}:
            return job
        return self.store.update_status(job_id, JobStatus.CANCELLED, event="cancelled by request", finished=True)

    def _new_job_id(self) -> str:
        return uuid.uuid4().hex[:20]


class JobClaimError(RuntimeError):
    pass


def _age_seconds(value: str) -> float:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return float("inf")
    return max((datetime.now(timezone.utc) - parsed).total_seconds(), 0)
