"""Hook runner protocol. 0.0.1 placeholder.

Hook script paths are configurable by the consumer; ``core-harness`` does not
hard-code script locations. Default path conventions are TBD and will be
introduced in a later minor.
"""

from typing import Any, Protocol, runtime_checkable


@runtime_checkable
class HookRunner(Protocol):
    """Protocol for executing harness hooks. Concrete shape TBD in 0.1+."""

    def run(self, *args: Any, **kwargs: Any) -> Any: ...


__all__ = ["HookRunner"]
