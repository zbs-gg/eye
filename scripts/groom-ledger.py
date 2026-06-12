#!/usr/bin/env python3
"""Append ONE grooming-run entry to the experiment ledger (workspace/groom/ledger.jsonl).

Каждый bi-daily прогон логируется: модель, ризонинг, токены, стоимость, длительность + решения
(из workspace/groom/last-run.json, который пишет сам груминг). Это даёт «ревью ревью» — любое
изменение бэклога обосновано evidence и откатываемо (commit sha в записи + git).

Usage: groom-ledger.py <claude_output_json> <iso_ts> <model> <duration_s>
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LEDGER = ROOT / "workspace/groom/ledger.jsonl"
LAST = ROOT / "workspace/groom/last-run.json"


def main() -> int:
    raw, ts, model, dur = (sys.argv + ["", "", "", "0"])[1:5]
    entry = {"ts": ts, "trigger": "scheduled", "model": model, "duration_s": int(dur or 0)}
    try:
        r = json.loads(raw)
        entry["cost_usd"] = r.get("total_cost_usd")
        entry["num_turns"] = r.get("num_turns")
        u = r.get("usage") or {}
        entry["tokens_in"] = u.get("input_tokens")
        entry["tokens_out"] = u.get("output_tokens")
        entry["tokens_cache_read"] = u.get("cache_read_input_tokens")
    except Exception as e:  # noqa: BLE001
        entry["parse_error"] = f"{type(e).__name__}: {e}"
    try:
        entry["run"] = json.loads(LAST.read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001
        entry["run"] = None
    try:
        entry["commit"] = subprocess.check_output(
            ["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"], text=True).strip()
    except Exception:  # noqa: BLE001
        entry["commit"] = None
    with LEDGER.open("a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    print(f"ledger += 1 (cost={entry.get('cost_usd')}, model={model})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
