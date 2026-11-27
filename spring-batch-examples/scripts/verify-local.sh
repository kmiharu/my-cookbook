#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/local-common.sh"

run_prefix=${1:-smoke-$(date -u +%Y%m%dT%H%M%S)-$$}
if [[ ! "$run_prefix" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    printf 'Use letters, digits, underscores and hyphens for the smoke run prefix.\n' >&2
    exit 2
fi

"$sample_dir/scripts/setup-local.sh"
"$sample_dir/scripts/probe-local-s3.sh"
"$sample_dir/scripts/probe-local-dynamodb.sh"
build_local_image
image=$(local_image)
docker run --rm --memory 4g --entrypoint sh "$image" -ec '
    test "$(id -u)" = 10001
    test -r /opt/batch/certs/rds-global-bundle.pem
    ! command -v javac >/dev/null
    if test -r /sys/fs/cgroup/memory.max; then
        printf "Image cgroup memory.max=%s (requested 4294967296 bytes)\n" "$(cat /sys/fs/cgroup/memory.max)"
    fi
'
local_batch job=Migrate "runId=$run_prefix-migrate"
local_batch job=Seed "runId=$run_prefix-seed" rows=8 rowWidth=256
customer_count=$(local_psql -Atc 'select count(*) from customer')
[[ "$customer_count" =~ ^[0-9]+$ && "$customer_count" -ge 8 ]]

local_batch job=WorkTableExport "runId=$run_prefix-export" destinations=both output.compression=gzip
internal=$(batch_env BATCH_INTERNAL_BUCKET)
partner=$(batch_env BATCH_PARTNER_BUCKET)
input=$(batch_env BATCH_INPUT_BUCKET)
output_key="WorkTableExport/$run_prefix-export/customers.csv.gz"
internal_hash=$(local_aws s3 cp "s3://$internal/$output_key" - --only-show-errors | sha256sum | cut -d ' ' -f 1)
partner_hash=$(local_aws s3 cp "s3://$partner/$output_key" - --only-show-errors | sha256sum | cut -d ' ' -f 1)
[[ "$internal_hash" == "$partner_hash" && "$internal_hash" =~ ^[a-f0-9]{64}$ ]]
for bucket in "$internal" "$partner"; do
    local_aws s3 cp "s3://$bucket/WorkTableExport/$run_prefix-export/manifest.json" - --only-show-errors |
        jq -e --arg run "$run_prefix-export" --arg sha "$internal_hash" --argjson rows "$customer_count" \
            '.runId == $run and (.artifacts | length == 2) and
            all(.artifacts[]; .artifact == "customers" and .rows == $rows and .sha256 == $sha and (.versionId | length > 0))' >/dev/null
done
local_aws s3 cp "s3://$internal/$output_key" - --only-show-errors | gzip -dc | python3 -c '
import csv
import sys
rows = csv.reader(sys.stdin, strict=True)
expected = int(sys.argv[1])
assert next(rows) == ["id", "name", "email", "status"]
last = 0
count = 0
for row in rows:
    assert len(row) == 4
    current = int(row[0])
    assert current > last
    last = current
    count += 1
assert count == expected, (count, expected)
' "$customer_count"

base_id=$(( $(date -u +%s) * 10000 + $$ % 10000 ))
input_key="smoke/$run_prefix.csv.gz"
fixture() {
    printf 'id,name,email,status\n%s,"確認,一行目\n二行目",test@example.invalid,ACTIVE\n%s,空欄,,INACTIVE\n' \
        "$base_id" "$((base_id + 1))" | gzip -n -6
}
input_hash=$(fixture | sha256sum | cut -d ' ' -f 1)
fixture | local_aws s3 cp - "s3://$input/$input_key" --only-show-errors
local_batch job=CustomerUpsert "runId=$run_prefix-import" "input.key=$input_key" "input.sha256=$input_hash" input.rows=2 input.compression=gzip
local_psql -Atc "select count(*) from customer where id in ($base_id, $((base_id + 1)))" | grep -qx 2
local_psql -Atc "select count(*) from customer where id = $base_id and name = E'確認,一行目\n二行目' and status = 'ACTIVE'" | grep -qx 1

invalid_exit=0
local_batch job=CustomerUpsert "runId=$run_prefix-invalid" unknown.argument=true || invalid_exit=$?
[[ "$invalid_exit" == 2 ]]
printf 'Image smoke passed: %s export rows, SHA-256 %s in both destinations, 2 import rows, invalid arguments exit 2.\n' \
    "$customer_count" "$internal_hash"
