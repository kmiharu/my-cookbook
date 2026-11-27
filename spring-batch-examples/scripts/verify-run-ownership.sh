#!/usr/bin/env bash
# Exercise the run mutex with two independent JVMs against the same PostgreSQL.
set -euo pipefail
source "$(dirname -- "$0")/local-common.sh"

name=${1:-ownership-$(date -u +%Y%m%dT%H%M%S)-$$}
[[ "$name" =~ ^[a-zA-Z0-9-]{1,64}$ ]] || exit 2
log_dir="${BATCH_LOG_DIR:-$sample_dir/bench-results/raw/$name}"
jar="${BATCH_SCENARIO_HOST_JAR:-$sample_dir/batch-examples/build/libs/batch-examples.jar}"
[[ -f "$jar" ]] || { printf 'Build :batch-examples:bootJar first.\n' >&2; exit 2; }
mkdir -p "$log_dir"
local_host=127.0.0.1
postgres_address=$("${compose[@]}" port postgres 5432)
s3_address=$("${compose[@]}" port s3 8333)
compose_db_url=$(batch_env BATCH_DB_URL)
export SPRING_PROFILES_ACTIVE=local
export BATCH_DB_URL="jdbc:postgresql://$local_host:${postgres_address##*:}/${compose_db_url##*/}"
for variable in BATCH_DB_USER BATCH_DB_PASSWORD BATCH_INPUT_BUCKET BATCH_S3_ACCESS_KEY BATCH_S3_SECRET_KEY; do
    printf -v "$variable" '%s' "$(batch_env "$variable")"
    export "$variable"
done
export BATCH_S3_ENDPOINT="http://$local_host:${s3_address##*:}"
key="ownership/$name.ready"
sha=$(printf 'ready\n' | sha256sum | cut -d' ' -f1)
args=(job=FileArrivalCheck "runId=$name" "input.key=$key" "input.sha256=$sha")
runner=(java -Xmx512m -jar "$jar")
leader=
trap 'if [[ -n "$leader" ]]; then kill -TERM "$leader" 2>/dev/null || true; wait "$leader" || true; fi' EXIT

"${runner[@]}" "${args[@]}" arrivalTimeoutSeconds=45 > "$log_dir/leader.log" 2>&1 &
leader=$!
active=0
for (( tries=0; tries<30; tries++ )); do
    state=$(local_psql -Atc "SELECT state FROM batch_run WHERE job_name='FileArrivalCheck' AND run_id='$name'")
    if [[ "$state" == ACTIVE ]]; then
        active=1
        break
    fi
    kill -0 "$leader" 2>/dev/null || break
    sleep 1
done
[[ "$active" == 1 ]]
second=0
"${runner[@]}" "${args[@]}" arrivalTimeoutSeconds=45 > "$log_dir/duplicate.log" 2>&1 || second=$?
[[ "$second" == 1 ]]
grep -q 'Run already owns the lock' "$log_dir/duplicate.log"
kill -0 "$leader"

printf 'ready\n' | local_aws s3 cp - "s3://$BATCH_INPUT_BUCKET/$key" --only-show-errors
wait "$leader"
leader=

changed=0
"${runner[@]}" "${args[@]}" arrivalTimeoutSeconds=44 > "$log_dir/changed.log" 2>&1 || changed=$?
[[ "$changed" == 2 ]]
grep -q 'Resolved settings or code changed' "$log_dir/changed.log"
printf 'Duplicate live owner rejected, first run completed and changed settings were rejected. Logs: %s\n' "$log_dir"
