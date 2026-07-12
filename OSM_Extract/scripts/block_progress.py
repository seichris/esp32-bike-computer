from __future__ import annotations

import sys
from collections.abc import Iterable, Iterator
from typing import TextIO, TypeVar


T = TypeVar("T")


class BlockProgressReporter:
    def __init__(self, total: int, *, stream: TextIO | None = None):
        if total <= 0:
            raise ValueError("progress total must be positive")
        self.total = total
        self.completed = 0
        self.stream = stream or sys.stdout

    def advance(self) -> None:
        if self.completed >= self.total:
            raise ValueError("progress cannot exceed total")
        self.completed += 1
        print(
            "  Step 5/5 Building map. {:.0%}  ".format(self.completed / self.total),
            end="\r",
            file=self.stream,
            flush=True,
        )
        print(
            f"\nMAP_PROGRESS:{self.completed}:{self.total}",
            file=self.stream,
            flush=True,
        )

    def track(self, items: Iterable[T]) -> Iterator[T]:
        for item in items:
            yield item
            self.advance()
