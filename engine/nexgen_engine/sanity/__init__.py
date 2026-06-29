"""Sanity framework — consistency/linter result types (Finding/Level/SanityReport),
a registry-driven `audit` runner (`audit.py`), and the engine's built-in generic
checks (`checks/`, installed via `register_core_checks`). Pack checks register the
same way via `EngineRegistry.register_sanity_check`."""
