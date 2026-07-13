"""Shared fail-closed data contracts for the benchmark tooling."""

from __future__ import annotations


def exact_keys(value: object, expected: set[str], subject: str) -> None:
    """Require an object to have exactly the locked schema keys."""

    if not isinstance(value, dict) or set(value) != expected:
        raise ValueError(f"{subject} keys do not match the locked schema")
