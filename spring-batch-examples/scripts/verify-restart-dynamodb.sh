#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/local-common.sh"
source "$(dirname -- "$0")/dynamodb-local.sh"

run=ddb-stop-$(date -u +%Y%m%dT%H%M%S)-$$
log_dir=${1:-$sample_dir/bench-results/raw/$run}
mkdir -p "$log_dir"
container="$run-old"
input=$(batch_env BATCH_INPUT_BUCKET)
table=$(batch_env BATCH_DYNAMO_TABLE)
key="dynamodb/$run.csv.gz"
rows=15

fixture() {
    printf 'pk,sk,version,status,balance,memo_state,memo\n'
    for ((i=1; i<=rows; i++)); do
        printf '%s,%d,0,ACTIVE,0,ABSENT,\n' "$run" "$i"
    done
}
checksum=$(fixture | gzip -n | sha256sum | cut -d ' ' -f 1)
fixture | gzip -n | local_aws s3 cp - "s3://$input/$key" --only-show-errors
args=(job=DynamoDbImport "runId=$run" "input.key=$key" "input.rows=$rows" "input.sha256=$checksum"
    input.compression=gzip "dynamo.partition=$run" dynamo.rateLimit=2)

pid=
cleanup() {
    if [[ -n "$pid" ]]; then
        kill -TERM "$pid" 2>/dev/null || true
    fi
    if docker inspect "$container" >/dev/null 2>&1; then
        docker stop --timeout 120 "$container" >/dev/null 2>&1 || true
        docker rm "$container" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

if [[ -n ${BATCH_SCENARIO_HOST_JAR:-} ]]; then
    dynamo_host_exec "${args[@]}" > "$log_dir/initial.log" 2>&1 &
    pid=$!
else
    "${compose[@]}" --profile batch run -d -T --no-deps --name "$container" batch "${args[@]}" > "$log_dir/launch.txt"
fi
deadline=$((SECONDS + 45))
delivered_sql="select count(*) from dynamo_work where run_key='DynamoDbImport:$run' and delivered"
for ((;;)); do
    delivered=$(local_psql -Atc "$delivered_sql")
    if (( delivered > 0 )); then break; fi
    if (( SECONDS >= deadline )); then
        printf 'DynamoDB fixture did not start delivery\n' >&2
        exit 1
    fi
    sleep 0.25
done
timestamp=$(date +%s)
code=0
if [[ -n "$pid" ]]; then
    kill -TERM "$pid"
    wait "$pid" || code=$?
    pid=
else
    docker stop --timeout 120 "$container" >/dev/null
    code=$(docker wait "$container")
    docker logs "$container" > "$log_dir/initial.log" 2>&1
    docker inspect -f '{{json .State}}' "$container" > "$log_dir/state.json"
fi
elapsed=$(( $(date +%s) - timestamp ))
[[ "$code" != 0 && "$elapsed" -lt 30 ]]
interrupted=$(local_psql -Atc "$delivered_sql")
(( interrupted > 0 && interrupted < rows ))

attempts_sql="select j.job_instance_id,j.job_execution_id,j.status from batch_job_execution j
    join batch_job_execution_params p on j.job_execution_id=p.job_execution_id
    join batch_job_instance i on j.job_instance_id=i.job_instance_id
    where i.job_name='DynamoDbImport' and p.parameter_name='runId' and p.parameter_value='$run'
    order by j.job_execution_id"
local_psql -Atc "$attempts_sql" > "$log_dir/before.tsv"
grep -q '|STOPPED$' "$log_dir/before.tsv"
dynamo_batch "${args[@]}" > "$log_dir/resumed.log" 2>&1
local_psql -Atc "$attempts_sql" > "$log_dir/after.tsv"
awk -F '|' '
    NR == 1 { if ($3 != "STOPPED") exit 1; instance=$1; execution=$2 }
    NR == 2 { if ($1 != instance || $2 == execution || $3 != "COMPLETED") exit 1 }
    END { if (NR != 2) exit 1 }
' "$log_dir/after.tsv"
[[ $(local_psql -Atc "$delivered_sql") == "$rows" ]]
local_aws dynamodb query --table-name "$table" --consistent-read --key-condition-expression 'pk = :pk' \
    --expression-attribute-values "$(jq -nc --arg value "$run" '{":pk":{"S":$value}}')" |
    jq -e --argjson rows "$rows" '.Count == $rows and all(.Items[]; .version.N == "0")' >/dev/null
printf 'DynamoDB SIGTERM exit=%s stop_seconds=%s before_resume_rows=%s resumed_rows=%s logs=%s\n' \
    "$code" "$elapsed" "$interrupted" "$rows" "$log_dir"
