#!/usr/bin/env python3
"""Recompute the published paired-round statistics from the numeric trial CSV."""
import argparse
import csv
import json
from pathlib import Path
import sys

import analysis_core


def load(path):
    data = {(i, c, a): [] for i in range(1, 7) for c in ("R", "S") for a in ("scroll", "type", "menu")}
    with path.open(newline="") as stream:
        for row in csv.DictReader(stream):
            key = int(row["round"]), row["client"], row["action"]
            if key not in data:
                raise ValueError("Unexpected round/client/action")
            trial = {"index": int(row["index"]), "direction": row["direction"], "status": row["status"],
                "inputSent": {"true": True, "false": False}[row["input_sent"]],
                "latencyMS": float(row["latency_ms"]) if row["latency_ms"] else None}
            na = trial["status"] == "menu_already_closed"
            if na:
                if key[2] != "menu" or trial["direction"] != "reverse" or trial["inputSent"] or trial["latencyMS"] is not None:
                    raise ValueError("Invalid nonperformed workflow outcome")
            elif trial["status"] != "observed_change" or not trial["inputSent"] or trial["latencyMS"] is None:
                raise ValueError("Invalid performed latency")
            data[key].append(trial)
    for rows in data.values():
        if len(rows) != 16 or [r["index"] for r in rows] != list(range(16)):
            raise ValueError("Missing, duplicate or out-of-order planned trials")
        for index, row in enumerate(rows):
            if row["direction"] != ("forward" if index % 2 == 0 else "reverse"):
                raise ValueError("Invalid direction sequence")
        for direction in ("forward", "reverse"):
            if not any(row["inputSent"] and row["direction"] == direction for row in rows):
                raise ValueError("An action/direction/round has no performed input")
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Compare the recomputation with summary.json")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    observed = analysis_core.analyze(load(root / "trials.csv"))
    if args.check:
        expected = json.loads((root / "summary.json").read_text())["analysis"]
        if observed != expected:
            print("Recomputed analysis differs from the published summary", file=sys.stderr)
            return 1
        print("Every recomputed analysis field matches summary.json.")
    else:
        print(json.dumps(observed, indent=2, allow_nan=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
