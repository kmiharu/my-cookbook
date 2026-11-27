#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/local-common.sh"

run=stop-arrival-$(date -u +%Y%m%dT%H%M%S)-$$
owner="$run-old"
log_dir=${1:-$sample_dir/bench-results/raw/$run}
mkdir -p "$log_dir"
cleanup() {
    if [[ $(docker inspect -f '{{.State.Running}}' "$owner" 2>/dev/null) == true ]]; then
        docker stop --time 120 "$owner" >/dev/null 2>&1 || true
    fi
    docker rm "$owner" >/dev/null 2>&1 || true
}
trap cleanup EXIT
state_sql="select state from batch_run where job_name='FileArrivalCheck' and run_id='$run'"
key="stop-probe/$run.csv"
payload() { printf 'id,name,email,status\n1,stop-probe,,ACTIVE\n'; }
sha=$(payload | sha256sum | cut -d ' ' -f 1)
batch_args=(job=FileArrivalCheck "runId=$run" "input.key=$key" "input.sha256=$sha" arrivalTimeoutSeconds=120)
"${compose[@]}" --profile batch run -d -T --no-deps --name "$owner" -e "BATCH_EXECUTION_OWNER=$owner" batch "${batch_args[@]}" >/dev/null
deadline=$((SECONDS + 35))
while [[ $(local_psql -Atc "$state_sql") != ACTIVE ]]; do
    if [[ $(docker inspect -f '{{.State.Running}}' "$owner") != true ]] || ((SECONDS >= deadline)); then
        docker logs "$owner" > "$log_dir/initial.log" 2>&1
        printf 'Test run did not reach the input arrival wait. See %s.\n' "$log_dir" >&2
        exit 1
    fi
    sleep 1
done
docker stop --time 120 "$owner" >/dev/null
docker logs "$owner" > "$log_dir/initial.log" 2>&1
docker inspect -f '{{json .State}}' "$owner" > "$log_dir/initial.state.json"
jq -e '.Running == false and .OOMKilled == false and .ExitCode != 0 and .ExitCode != 137' "$log_dir/initial.state.json" >/dev/null
local_psql -Atc "$state_sql" | grep -qx STOPPED
bucket=$(batch_env BATCH_INPUT_BUCKET)
payload | local_aws s3 cp - "s3://$bucket/$key" --only-show-errors
"${compose[@]}" --profile batch run --rm -T --no-deps batch "${batch_args[@]}" > "$log_dir/restarted.log" 2>&1
local_psql -Atc "$state_sql" | grep -qx COMPLETED
printf 'SIGTERM stopped the waiting input probe with exit %s; same run completed after the object arrived.\n' \
    "$(jq -er .ExitCode "$log_dir/initial.state.json")"
