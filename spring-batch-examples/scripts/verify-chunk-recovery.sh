#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/local-common.sh"

prefix=chunk-loss-$(date -u +%Y%m%dT%H%M%S)-$$
log_dir=${1:-$sample_dir/bench-results/raw/$prefix}
mkdir -p "$log_dir"
owner=
cleanup() {
    if [[ -n "$owner" ]]; then
        docker stop --time 120 "$owner" >/dev/null 2>&1 || true
        docker rm "$owner" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT
bucket=$(batch_env BATCH_INPUT_BUCKET)
base=$(( $(date -u +%s) * 10000 + $$ % 9000 ))

for action in pause oom; do
    run="$prefix-$action"
    owner="$run-old"
    first=$((base + 10))
    last=$((base + 15))
    base=$last
    key="chunk-fault/$run.csv.gz"
    payload() {
        printf 'id,name,email,status\n%s,first,,ACTIVE\n%s,invalid,,UNKNOWN\n%s,"multiple\nlines",,ACTIVE\n%s,end,,INACTIVE\n' \
            "$first" "$((first + 1))" "$((first + 2))" "$last" | gzip -n -6
    }
    sha=$(payload | sha256sum | cut -d ' ' -f 1)
    payload | local_aws s3 cp - "s3://$bucket/$key" --only-show-errors
    batch_args=(job=Restartable "runId=$run" "input.key=$key" "input.sha256=$sha" input.rows=4 \
        input.compression=gzip chunkSize=2 skipLimit=1)
    "${compose[@]}" --profile batch run -d -T --no-deps --name "$owner" \
        -e SPRING_PROFILES_ACTIVE=local,fault-test -e "BATCH_EXECUTION_OWNER=$owner" \
        -e BATCH_FAULT_PHASE=AFTER_CHUNK_COMMIT -e "BATCH_FAULT_ACTION=$action" \
        -e 'JAVA_TOOL_OPTIONS=-Xmx512m -XX:+ExitOnOutOfMemoryError' batch "${batch_args[@]}" >/dev/null
    stage_sql="select count(*) from batch_input_work where job_name='Restartable' and run_id='$run'"
    errors_sql="select file_index,ordinal from batch_input_error where job_name='Restartable' and run_id='$run' order by file_index,ordinal"
    if [[ "$action" == pause ]]; then
        deadline=$((SECONDS + 90))
        while ! docker logs "$owner" 2>&1 | grep 'Fault test waiting at AFTER_CHUNK_COMMIT' >/dev/null; do
            if [[ $(docker inspect -f '{{.State.Running}}' "$owner") != true ]] || ((SECONDS >= deadline)); then
                docker logs "$owner" > "$log_dir/$action.initial.log" 2>&1
                printf 'Chunk test did not reach the interruption point. See %s.\n' "$log_dir" >&2
                exit 1
            fi
            sleep 1
        done
        docker kill --signal KILL "$owner" >/dev/null
    fi
    timeout 120 docker wait "$owner" > "$log_dir/$action.exit-code"
    docker logs "$owner" > "$log_dir/$action.initial.log" 2>&1
    docker inspect -f '{{json .State}}' "$owner" > "$log_dir/$action.state.json"
    if [[ "$action" == pause ]]; then
        jq -e '.Status == "exited" and .ExitCode == 137 and .OOMKilled == false' "$log_dir/$action.state.json" >/dev/null
    else
        jq -e '.Status == "exited" and .ExitCode != 0 and .OOMKilled == false' "$log_dir/$action.state.json" >/dev/null
        grep -q 'OutOfMemoryError: Java heap space' "$log_dir/$action.initial.log"
    fi
    [[ $(local_psql -Atc "$stage_sql") == 1 ]]
    [[ $(local_psql -Atc "$errors_sql") == '0|2' ]]
    local_psql -Atc "select count(*) from customer where id between $first and $last" | grep -qx 0

    attempts_sql="select e.job_instance_id,e.job_execution_id,e.status from batch_job_execution e
        join batch_job_execution_params p on p.job_execution_id=e.job_execution_id
        join batch_job_instance i on i.job_instance_id=e.job_instance_id
        where i.job_name='Restartable' and p.parameter_name='runId' and p.parameter_value='$run' order by e.job_execution_id"
    local_psql -Atc "$attempts_sql" > "$log_dir/$action.before.tsv"
    IFS='|' read -r instance execution status < "$log_dir/$action.before.tsv"
    [[ "$status" == STARTED && "$instance" =~ ^[0-9]+$ && "$execution" =~ ^[0-9]+$ ]]
    docker rm "$owner" >/dev/null
    local_batch "${batch_args[@]}" "recover.executionId=$execution" "recover.owner=$owner" > "$log_dir/$action.resumed.log" 2>&1
    local_psql -Atc "$attempts_sql" > "$log_dir/$action.after.tsv"
    awk -F '|' -v instance="$instance" -v old="$execution" '
        NR == 1 && $1 == instance && $2 == old && $3 == "FAILED" {retried=1}
        NR == 2 && $1 == instance && $2 != old && $3 == "COMPLETED" {done=1}
        END {exit !(NR == 2 && retried && done)}
    ' "$log_dir/$action.after.tsv"
    [[ $(local_psql -Atc "$stage_sql") == 3 ]]
    [[ $(local_psql -Atc "$errors_sql") == '0|2' ]]
    [[ $(local_psql -Atc "select string_agg(id::text, ',' order by id) from customer where id between $first and $last") \
        == "$first,$((first + 2)),$last" ]]
    owner=
    printf 'Recovered same job instance after %s. Three logical rows applied and one error retained once.\n' "$action"
done
