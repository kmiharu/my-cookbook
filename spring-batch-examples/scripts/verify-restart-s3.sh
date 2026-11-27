#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/local-common.sh"

run=complete-crash-$(date -u +%Y%m%dT%H%M%S)-$$
owner="$run-old"
log_dir=${1:-$sample_dir/bench-results/raw/$run}
mkdir -p "$log_dir"
cleanup() { docker rm "$owner" >/dev/null 2>&1 || true; }
trap cleanup EXIT
batch_args=(job=WorkTableExport "runId=$run" destinations=both output.compression=gzip)
exit_code=0
"${compose[@]}" --profile batch run -T --no-deps --name "$owner" \
    -e SPRING_PROFILES_ACTIVE=local,fault-test -e "BATCH_EXECUTION_OWNER=$owner" \
    -e BATCH_FAULT_PHASE=OBJECT_COMPLETE -e BATCH_FAULT_DESTINATION=partner -e BATCH_FAULT_ACTION=halt \
    batch "${batch_args[@]}" > "$log_dir/initial.log" 2>&1 || exit_code=$?
docker inspect -f '{{json .State}}' "$owner" > "$log_dir/initial.state.json"
[[ "$exit_code" == 97 ]]
jq -e '.Running == false and .Status == "exited" and .ExitCode == 97' "$log_dir/initial.state.json" >/dev/null
docker rm "$owner" >/dev/null

attempts_sql="select e.job_instance_id,e.job_execution_id,e.status from batch_job_execution e
    join batch_job_execution_params p on p.job_execution_id=e.job_execution_id
    join batch_job_instance i on i.job_instance_id=e.job_instance_id
    where i.job_name='WorkTableExport' and p.parameter_name='runId' and p.parameter_value='$run'
    order by e.job_execution_id"
local_psql -Atc "$attempts_sql" > "$log_dir/before.attempts.tsv"
IFS='|' read -r instance_id execution_id batch_status < "$log_dir/before.attempts.tsv"
[[ "$instance_id" =~ ^[0-9]+$ && "$execution_id" =~ ^[0-9]+$ && "$batch_status" == STARTED ]]
local_psql -Atc "select state from batch_run where job_name='WorkTableExport' and run_id='$run' and owner_location='$owner'" | grep -qx ACTIVE
local_psql -Atc "select state from batch_artifact where object_key='WorkTableExport/$run/customers.csv.gz' and destination='partner'" | grep -qx EXPECTED

partner=$(batch_env BATCH_PARTNER_BUCKET)
internal=$(batch_env BATCH_INTERNAL_BUCKET)
key="WorkTableExport/$run/customers.csv.gz"
local_aws s3api head-object --bucket "$partner" --key "$key" > "$log_dir/before.partner.json"
version=$(jq -er '.VersionId | select(length > 0)' "$log_dir/before.partner.json")
exit_code=0
"${compose[@]}" --profile batch run --rm -T --no-deps batch "${batch_args[@]}" > "$log_dir/refused.log" 2>&1 || exit_code=$?
[[ "$exit_code" == 1 ]]
grep -q 'verify it has stopped' "$log_dir/refused.log"

"${compose[@]}" --profile batch run --rm -T --no-deps batch "${batch_args[@]}" \
    "recover.executionId=$execution_id" "recover.owner=$owner" > "$log_dir/resumed.log" 2>&1
local_aws s3api head-object --bucket "$partner" --key "$key" > "$log_dir/after.partner.json"
jq -e --arg version "$version" '.VersionId == $version' "$log_dir/after.partner.json" >/dev/null
for bucket in "$internal" "$partner"; do
    local_aws s3 cp "s3://$bucket/$key" - --only-show-errors | sha256sum | cut -d ' ' -f 1 > "$log_dir/$bucket.sha256"
done
cmp "$log_dir/$internal.sha256" "$log_dir/$partner.sha256"
local_psql -Atc "$attempts_sql" > "$log_dir/after.attempts.tsv"
awk -F '|' -v instance="$instance_id" -v old="$execution_id" '
    NR == 1 && $1 == instance && $2 == old && $3 == "FAILED" {retried=1}
    NR == 2 && $1 == instance && $2 != old && $3 == "COMPLETED" {done=1}
    END {exit !(NR == 2 && retried && done)}
' "$log_dir/after.attempts.tsv"
local_psql -Atc "select count(*) from batch_artifact where object_key='$key' and state='COMPLETE'" | grep -qx 2
printf 'Recovered %s after Complete/ledger failure. Both copies match and partner version %s is unchanged.\n' "$run" "$version"
