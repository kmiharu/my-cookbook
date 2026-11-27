#!/usr/bin/env python3
"""Compare database execution, JDBC insert time and Spring Batch Step duration."""
import csv
import json
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path


INSERT = re.compile(r"insert-mode=(\w+) rows=(\d+) elapsedNs=(\d+)")


def timings(groups):
    return {
        case: {
            "trials": len(values),
            "median": statistics.median(values),
            "min": min(values),
            "max": max(values),
        }
        for case, values in sorted(groups.items())
    }


def physical_plan(node):
    selected = {key: node[key] for key in (
        "Node Type", "Index Name", "Plan Rows", "Actual Rows", "Actual Loops",
        "Sort Method", "Sort Space Type", "Sort Space Used",
        "Shared Hit Blocks", "Shared Read Blocks", "Local Hit Blocks", "Local Read Blocks",
        "Temp Read Blocks", "Temp Written Blocks",
    ) if key in node}
    selected["children"] = [physical_plan(child) for child in node.get("Plans", [])]
    return selected


def explain(directory, run):
    path = directory / f"{run}.plans.json"
    if path.exists():
        with path.open(encoding="utf-8") as source:
            return json.load(source)["plans"]
    return {}


def main(directory):
    execution_ms = defaultdict(list)
    planning_ms = defaultdict(list)
    insert_seconds = defaultdict(list)
    step_seconds = defaultdict(list)
    physical_plans = defaultdict(list)
    with (directory / "trials.tsv").open(encoding="utf-8") as source:
        for trial in csv.DictReader(source, delimiter="\t"):
            if trial["status"] != "ok" or trial["iteration"] == "0":
                continue
            run, case, job = trial["run"], trial["case"], trial["job"]
            for label, item in explain(directory, run).items():
                execution_ms[label].append(item["Execution Time"])
                planning_ms[label].append(item["Planning Time"])
                physical_plans[label].append({
                    "run": run, "rows": item["Plan"]["Actual Rows"],
                    "plan": physical_plan(item["Plan"]),
                })
            if job == "BatchInsertBenchmark":
                with (directory / f"{run}.log").open(encoding="utf-8") as log:
                    for line in log:
                        match = INSERT.search(line)
                        if match:
                            insert_seconds[match[1]].append(int(match[3]) / 1e9)
            with (directory / f"{run}.steps.tsv").open(encoding="utf-8") as source_steps:
                for step in csv.DictReader(source_steps, delimiter="\t"):
                    if step["step_seconds"]:
                        step_seconds[f"{case}/{step['step_name']}"].append(float(step["step_seconds"]))
    print(json.dumps({
        "explain_execution_ms": timings(execution_ms),
        "explain_planning_ms": timings(planning_ms),
        "jdbc_insert_seconds": timings(insert_seconds),
        "step_seconds": timings(step_seconds),
        "physical_plans": physical_plans,
    }, indent=2))


if __name__ == "__main__":
    main(Path(sys.argv[1]))
