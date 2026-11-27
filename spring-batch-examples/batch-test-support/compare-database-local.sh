#!/usr/bin/env bash
set -euo pipefail
support=$(cd -- "$(dirname -- "$0")" && pwd)
source "$support/../scripts/local-common.sh"
source "$support/measure.sh"

rows=${1:-6000}
width=${2:-256}
repetitions=${3:-3}
[[ "$rows" =~ ^[1-9][0-9]{0,5}$ && "$width" =~ ^[1-9][0-9]{0,3}$ && "$repetitions" =~ ^[1-9][0-9]?$ ]] || exit 2
(( rows <= 100000 && width >= 64 && width <= 4096 )) || exit 2

epoch=$(date -u +%s)
prefix="dbcmp-$epoch-$$"
export BATCH_BENCH_DB=${BATCH_BENCH_DB:-"cookbook_bench_db_${epoch}_$$"}
directory=${4:-$sample_dir/bench-results/raw/$prefix}
mkdir -p "$directory"
trap batch_measure_stop EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ ${BATCH_BENCH_SERVICES_READY:-0} != 1 ]]; then
    "$sample_dir/scripts/setup-local.sh"
fi
batch_create_database
if [[ -n ${BATCH_BENCH_HOST_JAR:-} ]]; then
    batch_host_configure
elif [[ ${BATCH_BENCH_SKIP_BUILD:-0} != 1 ]]; then
    build_local_image
fi
launch() {
    if [[ -n ${BATCH_BENCH_HOST_JAR:-} ]]; then
        batch_host "$@"
    else
        "${compose[@]}" --profile batch run --rm -T --no-deps "${benchmark_db_override[@]}" batch "$@"
    fi
}

launch job=Migrate "runId=$prefix-migrate" > "$directory/migrate.log" 2>&1
launch job=Seed "runId=$prefix-seed" "rows=$rows" "rowWidth=$width" seed=31 > "$directory/seed.log" 2>&1
[[ $(batch_psql -Atc 'SELECT count(*) FROM customer') == "$rows" ]]
batch_psql -c "UPDATE customer SET name=E'引用,改行\n二行目', email='' WHERE id=2" > "$directory/setup.log"
batch_psql -c 'ANALYZE customer' >> "$directory/setup.log"

input=$(batch_env BATCH_INPUT_BUCKET)
source_key="benchmark/$prefix/fixture.csv.gz"
python3 - "$rows" "$width" <<'PY' | gzip -n -6 | local_aws s3 cp - "s3://$input/$source_key" --only-show-errors
import sys

rows, width = map(int, sys.argv[1:])
print("id,name,email,status")
for offset in range(1, rows + 1):
    item_id = 1_000_000_000 + offset
    name = f"bench-{item_id}-" + "X" * (width - 40)
    if offset % 10 == 0:
        email = ""
    elif offset % 10 == 1:
        email = '""'
    else:
        email = f"{item_id}@example.invalid"
    print(f"{item_id},{name},{email},ACTIVE")
PY
input_sha=$(local_aws s3 cp "s3://$input/$source_key" - --only-show-errors | sha256sum | cut -d' ' -f1)
input_bytes=$(local_aws s3api head-object --bucket "$input" --key "$source_key" --query ContentLength --output text)

{
    date -u +%FT%TZ
    uname -srm
    docker version --format '{{.Server.Version}}'
    docker compose version
    "${BATCH_BENCH_JAVA:-java}" -version 2>&1 || true
    printf 'rows=%s\nrow_width_requested=%s\nseed=31\nrepetitions=%s\ndatabase=%s\n' \
        "$rows" "$width" "$repetitions" "$BATCH_BENCH_DB"
    printf 'source_key=%s\ninput_bytes=%s\ninput_sha256=%s\n' "$source_key" "$input_bytes" "$input_sha"
    printf 'clock_ticks_per_second=%s\n' "$(getconf CLK_TCK)"
    for f in /sys/fs/cgroup/cpu.max /sys/fs/cgroup/memory.max; do
        if [[ -r "$f" ]]; then printf '%s=%s\n' "${f##*/}" "$(cat "$f")"; fi
    done
    batch_psql -Atc 'SELECT version()'
    batch_psql -Atc 'SELECT avg(pg_column_size(c)) FROM customer c'
} > "$directory/environment.log"

printf 'case\trun\tjob\titeration\trows\tstatus\n' > "$directory/trials.tsv"
failed=0

verify_import() {
    local name=$1 found
    found=$(batch_psql -At -v rows="$rows" -v width="$width" <<'SQL'
SELECT count(*)
FROM customer
WHERE id BETWEEN 1000000001 AND 1000000000 + :'rows'::bigint
  AND name = ('bench-' || id || '-' || repeat('X', :'width'::int - 40))
  AND status = 'ACTIVE' AND version = 0
  AND email IS NOT DISTINCT FROM CASE
      WHEN id % 10 = 0 THEN NULL
      WHEN id % 10 = 1 THEN ''
      ELSE id || '@example.invalid'
  END;
SQL
    ) || return 1
    [[ "$found" == "$rows" ]] || return 1
    jq -n --argjson rows "$rows" --argjson bytes "$input_bytes" --arg sha "$input_sha" \
        '{rows: $rows, stored_bytes_one_destination: $bytes, input_sha256: $sha}' > "$directory/$name.verified.json"
}

verify_trial() {
    local name=$1 job=$2
    shift 2
    case "$job" in
        SqlOptimization|IndexOptimization)
            "$support/read-database-plans.py" "$directory/$name.log" "$job" > "$directory/$name.plans.json"
            ;;
        BatchInsertBenchmark)
            local mode=${1#mode=}
            grep -q "insert-mode=$mode rows=$rows elapsedNs=" "$directory/$name.log"
            ;;
        WorkTableExport|CopyExport)
            batch_artifacts "$directory/$name.artifacts.json" "$name" &&
                "$support/verify-export.py" "$sample_dir/scripts/aws-local.sh" "$directory/$name.artifacts.json" "$rows" \
                    > "$directory/$name.verified.json"
            ;;
        ChunkSizeBenchmark|CopyImport)
            verify_import "$name"
            ;;
    esac
}

trial() {
    local family=$1 iteration=$2 job=$3 measured_rows=$4 status=ok
    shift 4
    local name="$prefix-$family-$iteration"
    if ! batch_measure "$directory" "$name" "$job" "$@"; then
        status=run-failed
    elif ! batch_step_metrics "$directory/$name.steps.tsv" "$name"; then
        status=collect-failed
    elif ! verify_trial "$name" "$job" "$@"; then
        status=verify-failed
    fi
    if [[ $status == ok && -f "$directory/$name.plans.json" ]]; then
        measured_rows=$(jq -er '.rows' "$directory/$name.plans.json")
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$family" "$name" "$job" "$iteration" "$measured_rows" "$status" >> "$directory/trials.tsv"
    printf '%s %s %s\n' "$family" "$iteration" "$status"
    if [[ "$status" != ok ]]; then
        failed=1
        tail -25 "$directory/$name.log" >&2 || true
    fi
}

import_trial() {
    local family=$1 iteration=$2 job=$3 key="benchmark/$prefix/$1-$2.csv.gz"
    batch_psql -v rows="$rows" >> "$directory/reset.log" <<'SQL'
DELETE FROM customer WHERE id BETWEEN 1000000001 AND 1000000000 + :'rows'::bigint;
SQL
    local_aws s3 cp "s3://$input/$source_key" "s3://$input/$key" --only-show-errors
    trial "$family" "$iteration" "$job" "$rows" "input.key=$key" "input.sha256=$input_sha" \
        "input.rows=$rows" input.compression=gzip chunkSize=1000
}

compare_exports() {
    local iteration=$1 a="$prefix-cursor-export-$1" b="$prefix-copy-export-$1"
    local first second
    first=$(jq -er '.objects[0].decoded_sha256' "$directory/$a.verified.json") || return 1
    second=$(jq -er '.objects[0].decoded_sha256' "$directory/$b.verified.json") || return 1
    if [[ "$first" != "$second" ]]; then
        printf '%s\t%s\t%s\t%s\n' "$iteration" "$first" "$second" mismatch >> "$directory/export-equivalence.tsv"
        return 1
    fi
    printf '%s\t%s\t%s\t%s\n' "$iteration" "$first" "$second" equal >> "$directory/export-equivalence.tsv"
}

printf 'iteration\tcursor_uncompressed_sha256\tcopy_uncompressed_sha256\tstatus\n' > "$directory/export-equivalence.tsv"
export_options=(destinations=both output.compression=gzip sql.fromDate=2026-01-01 sql.toDate=2026-01-02)
for ((iteration=0; iteration<=repetitions; iteration++)); do
    trial sql "$iteration" SqlOptimization "$rows"
    trial index "$iteration" IndexOptimization 0 "rows=$rows"
    modes=(sequential batch rewrite)
    for ((offset=0; offset<3; offset++)); do
        mode=${modes[(iteration + offset) % 3]}
        trial "insert-$mode" "$iteration" BatchInsertBenchmark "$rows" "mode=$mode" "rows=$rows" "rowWidth=$width" chunkSize=1000
    done
    trial cursor-export "$iteration" WorkTableExport "$rows" "${export_options[@]}"
    trial copy-export "$iteration" CopyExport "$rows" "${export_options[@]}"
    if ! compare_exports "$iteration"; then
        failed=1
        printf 'COPY export and cursor export failed byte equivalence (trial %s).\n' "$iteration" >&2
    fi
    import_trial chunk-import "$iteration" ChunkSizeBenchmark
    import_trial copy-import "$iteration" CopyImport
done

"$support/summarize.py" "$directory" > "$directory/summary.json"
printf 'Database benchmark observations and verification: %s\n' "$directory"
exit "$failed"
