#!/usr/bin/python3
"""Command-line entrypoint for the private temporal-v4 annotation pipeline."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from annotation.temporal_v4.pipeline import (
    aggregate,
    finalize,
    prepare,
    prepare_audit,
    prepare_final,
    validate_audit,
    validate_labels,
)


def _path(parser: argparse.ArgumentParser, name: str) -> None:
    parser.add_argument(name, required=True, type=Path)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Candidate-blind temporal screen annotation v4 tooling."
    )
    phases = parser.add_subparsers(dest="phase", required=True)

    prepare_parser = phases.add_parser("prepare")
    _path(prepare_parser, "--corpus-root")
    _path(prepare_parser, "--output-root")
    prepare_parser.add_argument("--seed", default="screen-understanding-temporal-v4")

    labels_parser = phases.add_parser("validate-labels")
    _path(labels_parser, "--packet")
    _path(labels_parser, "--output")
    _path(labels_parser, "--receipt")
    labels_parser.add_argument(
        "--role",
        required=True,
        choices=("annotation-pass1", "annotation-pass2"),
    )

    audit_parser = phases.add_parser("prepare-audit")
    _path(audit_parser, "--work-root")
    _path(audit_parser, "--pass1-output")
    _path(audit_parser, "--pass1-receipt")
    _path(audit_parser, "--pass2-output")
    _path(audit_parser, "--pass2-receipt")
    _path(audit_parser, "--output-root")
    audit_parser.add_argument(
        "--seed", default="screen-understanding-temporal-audit-v4"
    )

    validate_audit_parser = phases.add_parser("validate-audit")
    _path(validate_audit_parser, "--packet")
    _path(validate_audit_parser, "--output")
    _path(validate_audit_parser, "--receipt")
    validate_audit_parser.add_argument(
        "--role",
        required=True,
        choices=("correctness-auditor-1", "correctness-auditor-2"),
    )

    aggregate_parser = phases.add_parser("aggregate")
    _path(aggregate_parser, "--audit-root")
    _path(aggregate_parser, "--auditor-one")
    _path(aggregate_parser, "--receipt-one")
    _path(aggregate_parser, "--auditor-two")
    _path(aggregate_parser, "--receipt-two")
    _path(aggregate_parser, "--output-root")
    aggregate_parser.add_argument("--tiebreak-output", type=Path)
    aggregate_parser.add_argument("--tiebreak-receipt", type=Path)

    final_parser = phases.add_parser("prepare-final")
    _path(final_parser, "--work-root")
    _path(final_parser, "--aggregate-root")
    _path(final_parser, "--output-root")
    final_parser.add_argument(
        "--seed", default="screen-understanding-temporal-final-v4"
    )

    finalize_parser = phases.add_parser("finalize")
    _path(finalize_parser, "--final-audit-root")
    _path(finalize_parser, "--final-output")
    _path(finalize_parser, "--final-receipt")
    _path(finalize_parser, "--output-root")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.phase == "prepare":
        result = prepare(args.corpus_root, args.output_root, args.seed)
    elif args.phase == "validate-labels":
        validated = validate_labels(
            args.packet, args.output, args.receipt, args.role
        )
        result = {
            key: validated[key]
            for key in ("count", "pass", "opportunityCount", "annotator")
        }
    elif args.phase == "prepare-audit":
        result = prepare_audit(
            args.work_root,
            args.pass1_output,
            args.pass1_receipt,
            args.pass2_output,
            args.pass2_receipt,
            args.output_root,
            args.seed,
        )
    elif args.phase == "validate-audit":
        validated = validate_audit(
            args.packet, args.output, args.receipt, args.role
        )
        result = {
            key: validated[key]
            for key in ("count", "opportunityCount", "auditor")
        }
    elif args.phase == "aggregate":
        result = aggregate(
            args.audit_root,
            args.auditor_one,
            args.receipt_one,
            args.auditor_two,
            args.receipt_two,
            args.output_root,
            args.tiebreak_output,
            args.tiebreak_receipt,
        )
    elif args.phase == "prepare-final":
        result = prepare_final(
            args.work_root, args.aggregate_root, args.output_root, args.seed
        )
    else:
        result = finalize(
            args.final_audit_root,
            args.final_output,
            args.final_receipt,
            args.output_root,
        )
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
