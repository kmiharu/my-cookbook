#!/usr/bin/env python3
"""Validate matching PostgreSQL EXPLAIN rows and retain the raw server plans."""
import json
import re
import sys
from pathlib import Path


PLAN_LABELS = {
    "SqlOptimization": {"before-non-sargable", "after-range"},
    "IndexOptimization": {"before-index", "after-composite-index"},
}


def read_plans(lines):
    plans = {}
    for line in lines:
        match = re.search(r"explain=([-a-z]+) (\[.*)", line)
        if match is None:
            continue
        label, opening = match.groups()
        payload = [opening, "\n"]
        if not opening.rstrip().endswith("]"):
            for continuation in lines:
                payload.append(continuation)
                if continuation.rstrip("\r\n") == "]":
                    break
        [plan] = json.loads("".join(payload))
        if label in plans:
            raise ValueError(f"duplicate SQL plan {label}")
        plans[label] = plan
    return plans


def main():
    log, job = sys.argv[1:]
    with Path(log).open(encoding="utf-8") as stream:
        plans = read_plans(stream)
    if plans.keys() != PLAN_LABELS[job]:
        raise ValueError(f"unexpected SQL plans: {plans.keys()}")
    observed_rows = {item["Plan"]["Actual Rows"] for item in plans.values()}
    if len(observed_rows) != 1:
        raise ValueError(f"SQL plan output row counts differ: {observed_rows}")
    print(json.dumps({"rows": observed_rows.pop(), "plans": plans}, indent=2))


if __name__ == "__main__":
    main()
