"""core-harness: reusable safety primitives for Claude Code orchestrator harnesses.

Layer 1 of a consumer harness architecture. See README.md and
docs/canonical-ownership.md.

Public surface (0.3.2, see docs/api-surface-v0.x.md):

* ``core_harness.schema``    — framework JSON Schema + merge helper.
* ``core_harness.validator`` — settings.local.json audit engine.
* ``core_harness.generator`` — worker_role template renderer.
"""

from core_harness.generator import (
    UnresolvedPlaceholderError,
    generate_settings,
    render_role,
)
from core_harness.schema import (
    SchemaError,
    framework_schema_path,
    load_framework_schema,
    merge_schemas,
)
from core_harness.validator import (
    Finding,
    ValidationResult,
    check_worker_settings,
    extract_role_blocks,
    matches_worker_template,
    validate_config,
    validate_schema_integrity,
    validate_settings,
)

__version__ = "0.3.2"

__all__ = [
    "__version__",
    # schema
    "SchemaError",
    "load_framework_schema",
    "framework_schema_path",
    "merge_schemas",
    # validator
    "Finding",
    "ValidationResult",
    "validate_settings",
    "validate_config",
    "validate_schema_integrity",
    "extract_role_blocks",
    "check_worker_settings",
    "matches_worker_template",
    # generator
    "UnresolvedPlaceholderError",
    "generate_settings",
    "render_role",
]
