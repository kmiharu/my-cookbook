#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/local-common.sh"

rows=${1:-1000000}
width=${2:-256}
repetitions=${3:-3}
[[ "$rows" =~ ^[1-9][0-9]*$ && "$width" =~ ^[1-9][0-9]*$ && "$repetitions" =~ ^[1-9][0-9]*$ ]] || exit 2
prefix=bench-$(date -u +%Y%m%dT%H%M%S)-$$
log_dir=${4:-$sample_dir/bench-results/raw/$prefix}
mkdir -p "$log_dir"

active_container=
stop_active() {
    if [[ -n "$active_container" ]]; then
        docker stop --time 120 "$active_container" >/dev/null 2>&1 || true
        docker rm "$active_container" >/dev/null 2>&1 || true
    fi
}
trap stop_active EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"$sample_dir/scripts/setup-local.sh"
build_local_image
{
    uname -srm
    docker version --format '{{.Server.Version}}'
    docker info --format '{{json .Warnings}}'
    docker compose version
    "${compose[@]}" exec -T postgres psql --version
    "${compose[@]}" exec -T postgres df -h /var/lib/postgresql/data
    printf 'rows=%s row_width_requested=%s repetitions=%s\n' "$rows" "$width" "$repetitions"
} > "$log_dir/environment.log"
local_batch job=Migrate "runId=$prefix-migrate" > "$log_dir/migrate.log" 2>&1
[[ $(local_psql -Atc 'select count(*) from customer') == 0 ]] || {
    printf 'Benchmark requires an empty customer table in a dedicated local Compose project.\n' >&2
    exit 1
}
local_batch job=Seed "runId=$prefix-seed" "rows=$rows" "rowWidth=$width" > "$log_dir/seed.log" 2>&1
[[ $(local_psql -Atc 'select count(*) from customer') == "$rows" ]]

internal=$(batch_env BATCH_INTERNAL_BUCKET)
partner=$(batch_env BATCH_PARTNER_BUCKET)
input=$(batch_env BATCH_INPUT_BUCKET)
measure() {
    local run=$1 job=$2 code
    shift 2
    active_container="$run"
    "${compose[@]}" --profile batch run -d -T --no-deps --name "$active_container" \
        -e 'JAVA_TOOL_OPTIONS=-Xmx512m -XX:+ExitOnOutOfMemoryError -Xlog:gc*:stdout:uptime,level,tags' \
        batch "job=$job" "runId=$run" "$@" > "$log_dir/$run.launch"
    printf 'timestamp\trss_kib\thwm_kib\tcpu_ticks\tcgroup_limit_bytes\tcgroup_peak_bytes\tcgroup_cpu_usec\n' > "$log_dir/$run.samples.tsv"
    while [[ $(docker inspect -f '{{.State.Running}}' "$active_container") == true ]]; do
        docker exec "$active_container" sh -ec '
            rss=$(awk "/^VmRSS:/ {print \$2}" /proc/1/status)
            hwm=$(awk "/^VmHWM:/ {print \$2}" /proc/1/status)
            cpu=$(awk "{print \$14 + \$15}" /proc/1/stat)
            limit=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || printf unknown)
            peak=$(cat /sys/fs/cgroup/memory.peak 2>/dev/null || printf unknown)
            cpu_usage=$(awk "/^usage_usec / {print \$2}" /sys/fs/cgroup/cpu.stat 2>/dev/null || printf unknown)
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$(date -u +%FT%TZ)" "$rss" "$hwm" "$cpu" "$limit" "$peak" "$cpu_usage"
        ' >> "$log_dir/$run.samples.tsv" 2>/dev/null || true
        sleep 1
    done
    code=$(docker wait "$active_container")
    docker logs "$active_container" > "$log_dir/$run.log" 2>&1
    docker inspect -f '{{json .State}}' "$active_container" > "$log_dir/$run.state.json"
    printf '%s\n' "$code" > "$log_dir/$run.exit-code"
    docker rm "$active_container" >/dev/null
    active_container=
    [[ "$code" == 0 ]] || { printf 'Job %s failed with exit %s. Logs in %s\n' "$run" "$code" "$log_dir" >&2; return 1; }
}

for ((iteration=0; iteration<=repetitions; iteration++)); do
    run="$prefix-export-$iteration"
    measure "$run" CustomerExport destinations=both output.compression=gzip
    key="CustomerExport/$run/customers.csv.gz"
    for bucket in "$internal" "$partner"; do
        local_aws s3api head-object --bucket "$bucket" --key "$key" > "$log_dir/$run.$bucket.head.json"
        local_aws s3 cp "s3://$bucket/$key" - --only-show-errors | sha256sum | cut -d ' ' -f 1 > "$log_dir/$run.$bucket.sha256"
    done
    cmp "$log_dir/$run.$internal.sha256" "$log_dir/$run.$partner.sha256"
    cmp "$log_dir/$prefix-export-0.$internal.sha256" "$log_dir/$run.$internal.sha256"
    local_aws s3 cp "s3://$internal/$key" - --only-show-errors | gzip -dc | python3 -c '
import csv
import sys
rows = csv.reader(sys.stdin, strict=True)
assert next(rows) == ["id", "name", "email", "status"]
previous = count = 0
for row in rows:
    assert len(row) == 4
    item_id = int(row[0])
    assert item_id > previous
    previous = item_id
    count += 1
assert count == int(sys.argv[1]), count
print(count)
' "$rows" > "$log_dir/$run.rows"
done

if [[ "$rows" == 1000000 ]]; then
    import_run="$prefix-import"
    input_width=${BATCH_BENCHMARK_IMPORT_WIDTH:-1024}
    base=1000000000
    input_key="benchmark/$import_run.csv.gz"
    python3 - "$rows" "$input_width" "$base" <<'PY' | gzip -n -6 | local_aws s3 cp - "s3://$input/$input_key" --only-show-errors
import csv
import hashlib
import sys
count, width, base = map(int, sys.argv[1:])
writer = csv.writer(sys.stdout, lineterminator="\n")
writer.writerow(("id", "name", "email", "status"))
for offset in range(1, count + 1):
    customer = base + offset
    token = hashlib.sha256(f"seed:1:{customer}".encode()).hexdigest()
    name = (token * ((width + len(token) - 1) // len(token)))[:width]
    writer.writerow((customer, name, "" if offset % 10 == 0 else f"{customer}@example.invalid", "ACTIVE"))
PY
    input_hash=$(local_aws s3 cp "s3://$input/$input_key" - --only-show-errors | sha256sum | cut -d ' ' -f 1)
    measure "$import_run" CustomerUpsert "input.key=$input_key" input.compression=gzip "input.rows=$rows" "input.sha256=$input_hash"
    [[ $(local_psql -Atc "select count(*) from customer where id > $base and id <= $((base + rows))") == "$rows" ]]
fi
printf 'Raw benchmark observations and verification results are in %s. Export repetition 0 is the warm-up.\n' "$log_dir"
