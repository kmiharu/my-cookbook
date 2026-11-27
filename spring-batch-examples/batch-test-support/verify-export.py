#!/usr/bin/env python3
"""Read each stored object once and verify its ledger and customer positions."""
import csv
import gzip
import hashlib
import io
import json
import subprocess
import sys
from collections import defaultdict
from contextlib import nullcontext
from pathlib import Path


class Metered(io.RawIOBase):
    def __init__(self, source):
        self.source = source
        self.digest = hashlib.sha256()
        self.size = 0

    def readable(self):
        return True

    def readinto(self, target):
        count = self.source.readinto(target)
        view = memoryview(target)[:count]
        self.digest.update(view)
        self.size += count
        return count


def observe(aws, entry):
    if entry["state"] != "COMPLETE":
        raise ValueError("incomplete artifact")
    url = f's3://{entry["bucket"]}/{entry["object_key"]}'
    with subprocess.Popen([aws, "s3", "cp", url, "-", "--only-show-errors"], stdout=subprocess.PIPE) as process:
        stored = Metered(process.stdout)
        source = io.BufferedReader(stored)
        reading = gzip.GzipFile(fileobj=source, mode="rb") if entry["object_key"].endswith(".gz") else nullcontext(source)
        with source, reading as data:
            decoded = Metered(data)
            with io.TextIOWrapper(io.BufferedReader(decoded), encoding="utf-8", newline="") as characters:
                reader = csv.reader(characters, strict=True)
                if next(reader, None) != ["id", "name", "email", "status"]:
                    raise ValueError(f"unexpected customer header in {entry['object_key']}")
                first = last = None
                count = 0
                for record in reader:
                    if len(record) != 4:
                        raise ValueError("unexpected customer column count")
                    current = int(record[0])
                    if last is not None and current != last + 1:
                        raise ValueError("customer IDs are missing or duplicated")
                    first = current if first is None else first
                    last = current
                    count += 1
        if process.wait() != 0:
            raise ValueError("S3 GET failed")
    if (count, stored.size, stored.digest.hexdigest()) != (entry["row_count"], entry["size_bytes"], entry["sha256"]):
        raise ValueError("streamed rows, bytes or SHA-256 disagree with the artifact ledger")
    return {
        "artifact": entry["artifact_id"], "rows": count, "first": first, "last": last,
        "stored_bytes": stored.size, "decoded_bytes": decoded.size,
        "stored_sha256": stored.digest.hexdigest(), "decoded_sha256": decoded.digest.hexdigest(),
    }


def main():
    aws, ledger, count = sys.argv[1:]
    rows = int(count)
    by_destination = defaultdict(list)
    for entry in json.loads(Path(ledger).read_text(encoding="utf-8")):
        by_destination[entry["destination"]].append(observe(aws, entry))
    if len(by_destination) != 2:
        raise ValueError("expected artifacts in two destinations")
    first_destination, second_destination = by_destination.values()
    if first_destination != second_destination:
        raise ValueError("payload differs between the two destinations")
    position = 1
    for part in sorted((part for part in first_destination if part["rows"]), key=lambda item: item["first"]):
        if part["first"] != position:
            raise ValueError("partition ranges overlap or have gaps")
        position = part["last"] + 1
    if position - 1 != rows:
        raise ValueError(f"expected {rows} customers but found {position - 1}")
    print(json.dumps({
        "rows": rows, "destinations": sorted(by_destination),
        "stored_bytes_one_destination": sum(part["stored_bytes"] for part in first_destination),
        "decoded_bytes_one_destination": sum(part["decoded_bytes"] for part in first_destination),
        "objects": first_destination,
    }, indent=2))


if __name__ == "__main__":
    main()
