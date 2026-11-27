#!/usr/bin/env bash
set -euo pipefail
support=$(cd -- "$(dirname -- "$0")" && pwd)
source "$support/../scripts/local-common.sh"
source "$support/measure.sh"

rows=${1:-100000}
width=${2:-1024}
repetitions=${3:-3}
families=${4:-fetch,gzip,multipart,partition,chunk}
case "${BATCH_BENCH_WARMUP:-1}" in
    0) first_iteration=1 ;;
    1) first_iteration=0 ;;
    *) exit 2 ;;
esac
[[ -n "${BATCH_BENCH_DB:-}" || "${COMPOSE_PROJECT_NAME:-}" =~ ^cookbook-bench-[a-z0-9-]+$ ]] || {
    printf 'Use a dedicated cookbook-bench-* project or set BATCH_BENCH_DB to a new local benchmark database.\n' >&2
    exit 2
}
[[ "$rows" =~ ^[1-9][0-9]{0,7}$ && "$width" =~ ^[1-9][0-9]{0,3}$ && "$repetitions" =~ ^[1-9][0-9]?$ ]] || exit 2
(( rows <= 10000000 && width >= 64 && width <= 4096 )) || exit 2
if (( rows > 1000000 )) && [[ "$families" != representative ]]; then
    printf 'Use the representative family above 1,000,000 rows.\n' >&2
    exit 2
fi

prefix=compare-$(date -u +%Y%m%dT%H%M%S)-$$
directory=${5:-$sample_dir/bench-results/raw/$prefix}
mkdir -p "$directory"
trap batch_measure_stop EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "${BATCH_BENCH_SERVICES_READY:-0}" != 1 ]]; then
    "$sample_dir/scripts/setup-local.sh"
fi
if [[ -z "${BATCH_BENCH_HOST_JAR:-}" && "${BATCH_BENCH_SKIP_BUILD:-0}" != 1 ]]; then
    "${compose[@]}" --profile batch build batch
fi
batch_create_database
batch_configure_isolated_s3
if [[ -n "${BATCH_BENCH_HOST_JAR:-}" ]]; then
    batch_host_configure
    batch() { batch_host "$@"; }
else
    batch() { "${compose[@]}" --profile batch run --rm -T --no-deps "${benchmark_db_override[@]}" "${benchmark_s3_base_override[@]}" batch "$@"; }
fi
if [[ "${BATCH_BENCH_REUSE_SEED:-0}" == 1 ]]; then
    [[ -n "${BATCH_BENCH_DB:-}" ]] || exit 2
    batch_psql -At -v rows="$rows" -v width="$width" > "$directory/reused-seed.log" <<'SQL'
SELECT run_id FROM batch_run
WHERE job_name='Seed' AND state='COMPLETED'
  AND settings::jsonb->'jobOptions' @> jsonb_build_object('rows', :'rows', 'rowWidth', :'width', 'seed', '31')
ORDER BY updated_at DESC LIMIT 1;
SQL
    if [[ ! -s "$directory/reused-seed.log" ]] ||
        [[ $(batch_psql -Atc 'SELECT count(*) || chr(58) || min(id) || chr(58) || max(id) FROM customer') != "$rows:1:$rows" ]]; then
        printf 'Existing benchmark dataset does not match the requested Seed.\n' >&2
        exit 1
    fi
else
    batch job=Migrate "runId=$prefix-migrate" > "$directory/migrate.log" 2>&1
    if [[ $(batch_psql -Atc 'SELECT count(*) FROM customer') != 0 ]]; then
        printf 'The comparison project must start with an empty customer table.\n' >&2
        exit 1
    fi
    batch job=Seed "runId=$prefix-seed" "rows=$rows" "rowWidth=$width" seed=31 > "$directory/seed.log" 2>&1
    [[ $(batch_psql -Atc 'SELECT count(*) FROM customer') == "$rows" ]]
fi
{
    uname -srm
    docker version --format '{{.Server.Version}}'
    docker compose version
    printf 'clock_ticks_per_second=%s\n' "$(getconf CLK_TCK)"
    if [[ -n "${BATCH_BENCH_HOST_JAR:-}" ]]; then
        printf 'mode=host\njar_sha256=%s\n' "$benchmark_jar_sha256"
        "${BATCH_BENCH_JAVA:-java}" -version 2>&1
    else
        printf 'mode=container\n'
    fi
    printf 'rows=%s\nrow_width_requested=%s\nseed=31\nrepetitions=%s\n' "$rows" "$width" "$repetitions"
    for f in /sys/fs/cgroup/cpu.max /sys/fs/cgroup/memory.max; do
        if [[ -r "$f" ]]; then printf '%s=%s\n' "${f##*/}" "$(cat "$f")"; fi
    done
    batch_psql -Atc 'SELECT version()'
    batch_psql -Atc 'SELECT avg(pg_column_size(c)) FROM customer c WHERE id <= 10000'
    benchmark_pg_exec df -h /var/lib/postgresql/data
    docker info --format '{{json .Warnings}}'
    printf 'postgres_container=%s\ns3_container=%s\n'         "${BATCH_BENCH_PG_CONTAINER:-compose-postgres}" "${BATCH_BENCH_S3_CONTAINER:-compose-s3}"
} > "$directory/environment.log"
printf 'case\trun\tjob\titeration\trows\tstatus\n' > "$directory/trials.tsv"

failed=0
trial() {
    local label=$1 iteration=$2 job=$3
    shift 3
    local run="$prefix-$label-$iteration" status=ok
    local -a benchmark_s3_override=() trial_buckets=()
    if [[ "${BATCH_BENCH_TRIAL_BUCKETS:-0}" == 1 && "$job" != ChunkSizeBenchmark && "$job" != CustomerUpsert ]]; then
        create_trial_buckets "$run"
    fi
    if ! batch_measure "$directory" "$run" "$job" "$@"; then
        status=run-failed
    elif ! batch_step_metrics "$directory/$run.steps.tsv" "$run"; then
        status=collect-failed
    elif [[ "$job" == ChunkSizeBenchmark || "$job" == CustomerUpsert ]]; then
        if ! verify_import "$run"; then status=verify-failed; fi
    elif ! batch_artifacts "$directory/$run.artifacts.json" "$run" ||
        ! "$support/verify-export.py" "$support/aws-benchmark.sh" "$directory/$run.artifacts.json" "$rows" \
            > "$directory/$run.verified.json"; then
        status=verify-failed
    fi
    if [[ "$status" == ok ]]; then
        if (( ${#trial_buckets[@]} )); then
            if ! remove_trial_buckets "$run"; then status=cleanup-failed; fi
        elif [[ "${BATCH_BENCH_DELETE_OBJECTS:-0}" == 1 && -f "$directory/$run.artifacts.json" ]]; then
            if ! remove_verified_objects "$run"; then status=cleanup-failed; fi
        fi
    fi
    if [[ "$status" != ok ]]; then
        failed=1
        printf '%s failed (%s), see %s\n' "$run" "$status" "$directory" >&2
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$run" "$job" "$iteration" "$rows" "$status" >> "$directory/trials.tsv"
}

create_trial_buckets() {
    [[ -z "${BATCH_BENCH_HOST_JAR:-}" ]] || {
        printf 'Trial bucket isolation requires the local batch container.\n' >&2
        return 2
    }
    local run=$1 token bucket
    token=$(printf '%s' "$run" | sha256sum | cut -c1-20)
    trial_buckets=("cookbook-bench-$token-internal" "cookbook-bench-$token-partner")
    printf '%s\n' "${trial_buckets[@]}" > "$directory/$run.created-buckets"
    for bucket in "${trial_buckets[@]}"; do
        benchmark_aws s3api create-bucket --bucket "$bucket" >/dev/null
        benchmark_aws s3api put-bucket-versioning --bucket "$bucket" --versioning-configuration Status=Enabled
    done
    benchmark_s3_override=(-e "BATCH_INTERNAL_BUCKET=${trial_buckets[0]}" -e "BATCH_PARTNER_BUCKET=${trial_buckets[1]}")
}

remove_trial_buckets() {
    local run=$1 bucket contents key version
    for bucket in "${trial_buckets[@]}"; do
        contents=$(benchmark_aws s3api list-object-versions --bucket "$bucket") || return 1
        while IFS=$'\t' read -r key version; do
            [[ "$key" == */"$run"/* && -n "$version" ]] || return 1
            benchmark_aws s3api delete-object --bucket "$bucket" --key "$key" --version-id "$version" \
                >> "$directory/$run.object-cleanup.jsonl" || return 1
        done < <(jq -r '((.Versions // []) + (.DeleteMarkers // []))[] | [.Key,.VersionId] | @tsv' <<< "$contents")
        if [[ -z "${BATCH_BENCH_S3_CONTAINER:-}" ]]; then
            benchmark_aws s3api delete-bucket --bucket "$bucket" || return 1
        fi
    done
}

remove_verified_objects() {
    local run=$1 bucket key version
    while IFS=$'\t' read -r bucket key version; do
        [[ "$key" == */"$run"/* && -n "$version" ]] || return 1
        benchmark_aws s3api delete-object --bucket "$bucket" --key "$key" --version-id "$version" \
            >> "$directory/$run.object-cleanup.jsonl" || return 1
    done < <(jq -r '.[] | [.bucket, .object_key, (.version_id // "")] | @tsv' "$directory/$run.artifacts.json")
}

export_case() {
    local label=$1 job=$2 compression=$3
    shift 3
    for (( iteration=first_iteration; iteration<=repetitions; iteration++ )); do
        trial "$label" "$iteration" "$job" destinations=both "output.compression=$compression" "$@"
    done
}

prepare_import_fixture() {
    source_key="benchmark/$prefix/chunk-fixture.csv.gz"
    input_bucket=$(batch_env BATCH_INPUT_BUCKET)
    import_width=${BATCH_BENCH_IMPORT_WIDTH:-$width}
    [[ "$import_width" =~ ^[1-9][0-9]{0,3}$ ]] && (( import_width >= 64 && import_width <= 4096 ))
    python3 - "$rows" "$import_width" <<'PY' | gzip -n -6 | benchmark_aws s3 cp - "s3://$input_bucket/$source_key" --only-show-errors
import csv
import sys

rows, width = map(int, sys.argv[1:])
writer = csv.writer(sys.stdout, lineterminator="\n")
writer.writerow(("id", "name", "email", "status"))
for offset in range(1, rows + 1):
    item_id = 1_000_000_000 + offset
    name = f"bench-{item_id}-" + "X" * (width - 40)
    email = "" if offset % 10 == 0 else f"{item_id}@example.invalid"
    writer.writerow((item_id, name, email, "ACTIVE"))
PY
    input_sha=$(benchmark_aws s3 cp "s3://$input_bucket/$source_key" - --only-show-errors | sha256sum | cut -d' ' -f1)
    input_bytes=$(benchmark_aws s3api head-object --bucket "$input_bucket" --key "$source_key" --query ContentLength --output text)
}

verify_import() {
    local run=$1 found
    found=$(batch_psql -At -v rows="$rows" -v width="$import_width" <<'SQL'
SELECT count(*)
FROM customer
WHERE id BETWEEN 1000000001 AND 1000000000 + :'rows'::bigint
  AND name = ('bench-' || id || '-' || repeat('X', :'width'::int - 40))
  AND status = 'ACTIVE'
  AND email IS NOT DISTINCT FROM CASE WHEN id % 10 = 0 THEN NULL ELSE id || '@example.invalid' END;
SQL
    ) || return 1
    [[ "$found" == "$rows" ]] || return 1
    jq -n --argjson rows "$rows" --argjson bytes "$input_bytes" --arg sha "$input_sha" \
        '{rows: $rows, stored_bytes_one_destination: $bytes, input_sha256: $sha}' > "$directory/$run.verified.json"
}

chunk_case() {
    local size=$1 run label="chunk-$1"
    for (( iteration=first_iteration; iteration<=repetitions; iteration++ )); do
        run="$prefix-$label-$iteration"
        batch_psql -v rows="$rows" >> "$directory/reset-chunk.log" <<'SQL'
DELETE FROM customer WHERE id BETWEEN 1000000001 AND 1000000000 + :'rows'::bigint;
SQL
        key="benchmark/$run.csv.gz"
        benchmark_aws s3 cp "s3://$input_bucket/$source_key" "s3://$input_bucket/$key" --only-show-errors
        trial "$label" "$iteration" ChunkSizeBenchmark "chunkSize=$size" "input.key=$key" \
            "input.rows=$rows" "input.sha256=$input_sha" input.compression=gzip
    done
}

IFS=, read -r -a selected <<< "$families"
for family in "${selected[@]}"; do
    case "$family" in
        representative)
            export_case representative-export CustomerExport gzip
            if [[ "${BATCH_BENCH_INCLUDE_IMPORT:-0}" == 1 ]]; then
                prepare_import_fixture
                trial representative-import 1 CustomerUpsert "input.key=$source_key" "input.rows=$rows" \
                    "input.sha256=$input_sha" input.compression=gzip
            fi ;;
        fetch)
            for size in 100 1000 10000; do export_case "fetch-$size" FetchSizeBenchmark gzip "fetchSize=$size"; done ;;
        gzip)
            for level in 1 6 9; do export_case "gzip-$level" GzipBenchmark gzip "output.gzipLevel=$level"; done ;;
        multipart)
            for workers in 1 4; do
                export_case "multipart-$workers" ParallelMultipartUpload none "transferWorkers=$workers" totalBuffers=6
            done ;;
        partition)
            for workers in 1 2 4 8; do export_case "partition-$workers" PartitionBenchmark gzip "partitions=$workers"; done ;;
        partition-1|partition-2|partition-4|partition-8)
            export_case "$family" PartitionBenchmark gzip "partitions=${family#partition-}" ;;
        chunk)
            prepare_import_fixture
            for size in 100 1000 2000; do chunk_case "$size"; done ;;
        chunk-100|chunk-1000|chunk-2000)
            prepare_import_fixture
            chunk_case "${family#chunk-}" ;;
        *)
            printf 'Unknown comparison family: %s\n' "$family" >&2
            exit 2 ;;
    esac
done
"$support/summarize.py" "$directory" > "$directory/summary.json"
printf 'Benchmark observations and verification: %s\n' "$directory"
exit "$failed"
