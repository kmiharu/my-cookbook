#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/local-common.sh"
source "$(dirname -- "$0")/dynamodb-local.sh"

rows=${1:-1000000}
trial=${2:-ddb-measure-$(date -u +%Y%m%dT%H%M%S)-$$}
log_dir=${3:-$sample_dir/bench-results/raw/$trial}
if [[ ! "$rows" =~ ^[1-9][0-9]{0,6}$ || ! "$trial" =~ ^[A-Za-z0-9_-]{1,36}$ ]]; then
    printf 'Invoke with an item count between 1 and 9999999 and a unique trial prefix.\n' >&2
    exit 2
fi
mkdir -p "$log_dir"
input=$(batch_env BATCH_INPUT_BUCKET)
internal=$(batch_env BATCH_INTERNAL_BUCKET)
generation=${DDB_BENCH_SOURCE:-generation:$trial}
key=${DDB_BENCH_INPUT_KEY:-benchmarks/dynamodb/$trial.csv.gz}
page_limit=${DDB_BENCH_PAGE_LIMIT:-1000}
workers=${DDB_BENCH_WORKERS:-4}
batch_size=${DDB_BENCH_BATCH_SIZE:-25}
mode=${DDB_BENCH_MODE:-QUERY}

measure() {
    local stage=$1 code=0 start stop elapsed pid active_image
    shift
    start=$(date +%s%N)
    printf 'epoch_ns\trss_kib\thwm_kib\tcpu_ticks\tmemory_limit\tcgroup_peak\n' > "$log_dir/$stage.resources.tsv"
    if [[ -n ${BATCH_SCENARIO_HOST_JAR:-} ]]; then
        dynamo_host_exec "$@" > "$log_dir/$stage.log" 2>&1 &
        pid=$!
        while kill -0 "$pid" 2>/dev/null; do
            rss=$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status" 2>/dev/null || true)
            hwm=$(awk '/^VmHWM:/ {print $2}' "/proc/$pid/status" 2>/dev/null || true)
            cpu=$(awk '{print $14 + $15}' "/proc/$pid/stat" 2>/dev/null || true)
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s%N)" "${rss:-0}" "${hwm:-0}" "${cpu:-0}" \
                host host >> "$log_dir/$stage.resources.tsv"
            sleep 1
        done
        wait "$pid" || code=$?
    else
        active_image="$trial-$stage"
        local connections=()
        if [[ -n ${DDB_BENCH_DATABASE_URL:-} ]]; then
            connections+=(-e "BATCH_DB_URL=$DDB_BENCH_DATABASE_URL")
        fi
        if [[ -n ${DDB_BENCH_DYNAMO_ENDPOINT:-} ]]; then
            connections+=(-e "BATCH_DYNAMO_ENDPOINT=$DDB_BENCH_DYNAMO_ENDPOINT")
        fi
        if ! "${compose[@]}" --profile batch run -d -T --no-deps --name "$active_image" \
            -e 'JAVA_TOOL_OPTIONS=-Xmx512m -XX:+ExitOnOutOfMemoryError -Xlog:gc*:stdout:uptime,level,tags' \
            "${connections[@]}" batch "$@" > "$log_dir/$stage.launch" 2>&1; then
            printf 'stage=%s failed during Docker launch\n' "$stage" | tee -a "$log_dir/summary.txt" >&2
            cat "$log_dir/$stage.launch" >&2
            return 1
        fi
        while [[ $(docker inspect -f '{{.State.Running}}' "$active_image") == true ]]; do
            docker exec "$active_image" sh -ec '
                printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$(date +%s%N)" \
                    "$(awk "/^VmRSS:/ {print \$2}" /proc/1/status)" \
                    "$(awk "/^VmHWM:/ {print \$2}" /proc/1/status)" \
                    "$(awk "{print \$14 + \$15}" /proc/1/stat)" \
                    "$(cat /sys/fs/cgroup/memory.max 2>/dev/null || printf unavailable)" \
                    "$(cat /sys/fs/cgroup/memory.peak 2>/dev/null || printf unavailable)"
            ' >> "$log_dir/$stage.resources.tsv" 2>/dev/null || true
            sleep 1
        done
        code=$(docker wait "$active_image")
        docker logs "$active_image" > "$log_dir/$stage.log" 2>&1
        docker inspect -f '{{json .State}}' "$active_image" > "$log_dir/$stage.state.json"
        docker rm "$active_image" >/dev/null
    fi
    stop=$(date +%s%N)
    elapsed=$(awk -v start="$start" -v end="$stop" 'BEGIN {printf "%.3f", (end-start)/1e9}')
    printf 'stage=%s exit=%s elapsed_seconds=%s\n' "$stage" "$code" "$elapsed" | tee -a "$log_dir/summary.txt"
    if [[ "$code" != 0 ]]; then
        tail -60 "$log_dir/$stage.log" >&2
        return 1
    fi
    grep -E 'DynamoDB source|DynamoDB delivery|artifact=customers' "$log_dir/$stage.log" |
        tee -a "$log_dir/summary.txt"
}

{
    df -h "$sample_dir"
    uname -srm
    docker info --format '{{.ServerVersion}} {{json .Warnings}}'
    printf 'application=%s\n' "${BATCH_SCENARIO_HOST_JAR:-$(local_image)}"
    printf 'rows=%s page_limit=%s workers=%s batch_size=%s mode=%s\n' \
        "$rows" "$page_limit" "$workers" "$batch_size" "$mode"
    getconf CLK_TCK
} > "$log_dir/environment.log"
if [[ ${DDB_BENCH_SKIP_SEED:-0} != 1 ]]; then
    if [[ ${DDB_BENCH_RESUME_SEED:-0} != 1 ]]; then
        python3 - "$generation" "$rows" <<'PY' | gzip -n -1 | local_aws s3 cp - "s3://$input/$key" --only-show-errors
import csv
import hashlib
import sys
generation, count = sys.argv[1], int(sys.argv[2])
writer = csv.writer(sys.stdout, lineterminator="\n")
writer.writerow(("pk", "sk", "version", "status", "balance", "memo_state", "memo"))
for item in range(1, count + 1):
    status = "INACTIVE" if item % 10 == 0 else "ACTIVE"
    value = hashlib.sha256(f"seed:31:{item}".encode()).hexdigest()
    writer.writerow((generation, f"{item:09}", 0, status, item % 100, "VALUE", value))
PY
    fi
    sha=$(local_aws s3 cp "s3://$input/$key" - --only-show-errors | sha256sum | cut -d ' ' -f 1)
    measure seed job=DynamoDbImport "runId=$trial-seed" "input.key=$key" "input.rows=$rows" \
        "input.sha256=$sha" input.compression=gzip "dynamo.partition=$generation" \
        dynamo.writeMode=replace "dynamo.batchSize=$batch_size" "dynamo.workers=$workers"
fi
if [[ ${DDB_BENCH_PREPARE_ONLY:-0} == 1 ]]; then
    printf 'DynamoDB fixed generation %s is prepared. Logs %s\n' "$generation" "$log_dir"
    exit 0
fi
bench_run="$trial-export"
extra=()
if [[ -n ${DDB_BENCH_TARGET:-} ]]; then
    extra=("dynamo.targetPartition=$DDB_BENCH_TARGET")
fi
measure export job=DynamoDbBenchmark "runId=$bench_run" "dynamo.partition=$generation" \
    "dynamo.expectedItems=$rows" "dynamo.pageLimit=$page_limit" "dynamo.readMode=$mode" \
    "dynamo.batchSize=$batch_size" "dynamo.workers=$workers" output.compression=gzip "${extra[@]}"
output="s3://$internal/DynamoDbBenchmark/$bench_run/customers.csv.gz"
local_aws s3 cp "$output" - --only-show-errors | gzip -dc | python3 -c '
import csv
import hashlib
import sys
generation, expected = sys.argv[1], int(sys.argv[2])
data = csv.reader(sys.stdin, strict=True)
assert next(data) == ["pk", "sk", "version", "status", "balance", "memo_state", "memo"]
count = 0
for count, row in enumerate(data, 1):
    value = hashlib.sha256(f"seed:31:{count}".encode()).hexdigest()
    status = "INACTIVE" if count % 10 == 0 else "ACTIVE"
    assert row == [generation, f"{count:09}", "0", status, str(count % 100), "VALUE", value], count
assert count == expected, (count, expected)
print(f"verified_rows={count}")
' "$generation" "$rows" | tee -a "$log_dir/summary.txt"
printf 'DynamoDB benchmark logs %s\n' "$log_dir"
