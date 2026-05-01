"""Audit / journal protocol. 0.0.1 placeholder."""

from typing import Any, Protocol, runtime_checkable


@runtime_checkable
class Journal(Protocol):
    """Protocol for harness audit journals. Concrete shape TBD in 0.1+."""

    def record(self, *args: Any, **kwargs: Any) -> None: ...


__all__ = ["Journal"]
