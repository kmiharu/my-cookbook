#!/usr/bin/env python3
"""Summarize completed and failed trials using the captured Docker, JVM and S3 observations."""
import csv
import json
import re
import statistics
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path


HEAP = re.compile(r" \d+[KMG]->\d+[KMG]\(\d+[KMG]\)")
DURATION = re.compile(r" ([0-9.]+)ms$")
GC_SUMMARY = re.compile(r"\[gc\s*\]\s+GC\(")
BYTE_UNITS = {"K": 1024, "M": 1024**2, "G": 1024**3}


def load(path):
    if not path.exists():
        return None
    data = path.read_text(encoding="utf-8").strip()
    return json.loads(data) if data else None


def observed_max(records, column):
    return max((int(row[column]) for row in records if (row.get(column) or "").isdigit()), default=None)


def collect(directory, trial):
    run = trial["run"]
    state = load(directory / f"{run}.state.json") or {}
    runtime = load(directory / f"{run}.runtime.json") or {}
    verification = load(directory / f"{run}.verified.json") or {}
    sample_file = directory / f"{run}.samples.tsv"
    samples = []
    if sample_file.exists():
        with sample_file.open(encoding="utf-8") as stream:
            samples = list(csv.DictReader(stream, delimiter="\t"))
    elapsed = None
    if state.get("StartedAt") and state.get("FinishedAt"):
        elapsed = (datetime.fromisoformat(state["FinishedAt"]) - datetime.fromisoformat(state["StartedAt"])).total_seconds()
    log_file = directory / f"{run}.log"
    pause_ms = 0.0
    pause_count = 0
    heap_before_gc = 0
    if log_file.exists():
        with log_file.open(encoding="utf-8", errors="replace") as log:
            for line in log:
                if not GC_SUMMARY.search(line):
                    continue
                match = HEAP.search(line)
                if match:
                    token = match[0].strip().split("->", 1)[0]
                    heap_before_gc = max(heap_before_gc, int(token[:-1]) * BYTE_UNITS[token[-1]])
                match = DURATION.search(line)
                if "Pause" in line and match:
                    pause_count += 1
                    pause_ms += float(match[1])
    stored_bytes = verification.get("stored_bytes_one_destination")
    decoded_bytes = verification.get("decoded_bytes_one_destination")
    destinations = verification.get("destinations")
    rows = int(trial["rows"])
    verified = state.get("ExitCode") == 0 and verification.get("rows") == rows
    total_bytes = stored_bytes * len(destinations) if stored_bytes is not None and destinations else stored_bytes
    configured_limit = runtime.get("memory")
    observed_limit = observed_max(samples, "cgroup_limit_bytes")
    peak = observed_max(samples, "cgroup_peak_bytes")
    measured_cgroup = configured_limit is not None and observed_limit == configured_limit
    mode = runtime.get("mode", "container") if runtime else None
    result = dict(trial)
    result.update(
        exit_code=state.get("ExitCode"),
        oom_killed=state.get("OOMKilled"),
        image=runtime.get("image"),
        launch_mode=mode,
        jar_sha256=runtime.get("jar_sha256"),
        configured_container_memory_limit_bytes=configured_limit,
        observed_cgroup_memory_limit_bytes=observed_limit,
        elapsed_seconds=elapsed,
        container_seconds=elapsed if mode == "container" else None,
        host_process_seconds=elapsed if mode == "host" else None,
        verified=verified,
        rows_per_second=rows / elapsed if elapsed and verified else None,
        storage_bytes_one_destination=stored_bytes,
        transmitted_or_read_bytes=total_bytes,
        mib_per_second=total_bytes / 1024**2 / elapsed if total_bytes is not None and elapsed else None,
        compression_ratio=stored_bytes / decoded_bytes if stored_bytes is not None and decoded_bytes else None,
        sampled_rss_hwm_kib=observed_max(samples, "hwm_kib"),
        sampled_cgroup_peak_bytes=peak if measured_cgroup else None,
        sampled_shared_cgroup_peak_bytes=peak if not measured_cgroup else None,
        sampled_process_cpu_ticks=observed_max(samples, "cpu_ticks"),
        sampled_cgroup_cpu_usec=observed_max(samples, "cgroup_cpu_usec") if measured_cgroup else None,
        observed_heap_before_gc_bytes=heap_before_gc or None,
        gc_pause_count=pause_count if log_file.exists() else None,
        gc_pause_ms=pause_ms if log_file.exists() else None,
    )
    return result


def representative_trials(directory):
    environment = (directory / "environment.log").read_text(encoding="utf-8")
    rows = int(re.search(r"(?m)^rows=(\d+)", environment)[1])
    for state in sorted(directory.glob("*.state.json")):
        run = state.name.removesuffix(".state.json")
        job = "CustomerExport" if "-export-" in run else "CustomerUpsert"
        label = "representative-export" if job == "CustomerExport" else "representative-import"
        verified = directory / f"{run}.verified.json"
        status = "ok" if load(state)["ExitCode"] == 0 and verified.exists() else "not-verified"
        yield {"case": label, "run": run, "job": job, "rows": rows, "status": status,
               "iteration": run.rsplit("-", 1)[-1] if "-export-" in run else "1"}


def main():
    directory = Path(sys.argv[1])
    trials_file = directory / "trials.tsv"
    if trials_file.exists():
        with trials_file.open(encoding="utf-8") as stream:
            trials = list(csv.DictReader(stream, delimiter="\t"))
    else:
        trials = list(representative_trials(directory))
    observations = [collect(directory, trial) for trial in trials]
    groups = defaultdict(list)
    for item in observations:
        if item["verified"] and item["iteration"] != "0":
            groups[item["case"]].append(item)
    summaries = {}
    for name, group in groups.items():
        statistics_by_metric = {}
        for metric in ("elapsed_seconds", "rows_per_second", "mib_per_second", "compression_ratio",
                       "sampled_rss_hwm_kib", "sampled_cgroup_peak_bytes", "sampled_process_cpu_ticks",
                       "sampled_cgroup_cpu_usec", "observed_heap_before_gc_bytes", "gc_pause_ms"):
            values = [sample[metric] for sample in group if sample[metric] is not None]
            if values:
                statistics_by_metric[metric] = {
                    "median": statistics.median(values), "min": min(values), "max": max(values),
                }
        summaries[name] = {"trials": len(group), "metrics": statistics_by_metric}
    print(json.dumps({"cases": summaries, "observations": observations}, indent=2))


if __name__ == "__main__":
    main()
