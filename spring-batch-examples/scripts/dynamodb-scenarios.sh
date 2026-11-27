#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/local-common.sh"
source "$(dirname -- "$0")/dynamodb-local.sh"

run=${1:-ddb-$(date -u +%Y%m%dT%H%M%S)-$$}
if [[ ! "$run" =~ ^[A-Za-z0-9_-]{1,42}$ ]]; then
    printf 'Use 1–42 letters, digits, hyphens or underscores for the run prefix.\n' >&2
    exit 2
fi
log_dir=${2:-$sample_dir/bench-results/raw/$run}
mkdir -p "$log_dir"
input=$(batch_env BATCH_INPUT_BUCKET)
internal=$(batch_env BATCH_INTERNAL_BUCKET)
table=$(batch_env BATCH_DYNAMO_TABLE)
partition="$run"
base=$(( $(date -u +%s) * 10000 + $$ % 9990 ))
first=$((base + 1))
second=$((base + 2))
third=$((base + 3))
upload="dynamodb/$run"
psql_local() {
    "${compose[@]}" exec -T postgres sh -ec         'exec psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" "$@"' sh "$@"
}
record() {
    local label=$1
    shift
    if ! dynamo_batch "$@" > "$log_dir/$label.log" 2>&1; then
        tail -60 "$log_dir/$label.log" >&2
        return 1
    fi
    printf 'PASS %s\n' "$label"
}
file_job() {
    local label=$1 job=$2 run_suffix=$3 rows=$4 fixture=$5 digest
    shift 5
    digest=$("$fixture" | sha256sum | cut -d ' ' -f 1)
    "$fixture" | local_aws s3 cp - "s3://$input/$upload/$run_suffix.csv.gz" --only-show-errors
    record "$label" "job=$job" "runId=$run-$run_suffix" "input.key=$upload/$run_suffix.csv.gz"         "input.sha256=$digest" "input.rows=$rows" input.compression=gzip "dynamo.partition=$partition" "$@"
}
get_item() {
    local pk=$1 sk=$2 result
    result=$(local_aws dynamodb get-item --consistent-read --output json --table-name "$table" \
        --key "$(jq -nc --arg pk "$pk" --arg sk "$sk" '{pk:{S:$pk},sk:{S:$sk}}')")
    if [[ -n "$result" ]]; then
        printf '%s\n' "$result"
    else
        printf '{}\n'
    fi
}
fixture() {
    printf 'pk,sk,version,status,balance,memo_state,memo\n%s,%s,0,ACTIVE,2.125,VALUE,"多行\n名前"\n%s,%s,0,ACTIVE,0,NULL,\n%s,%s,0,INACTIVE,0,VALUE,""\n'  \
        "$partition" "$first" "$partition" "$second" "$partition" "$third" | gzip -n
}
addition() { printf 'pk,sk,version,delta\n%s,%s,0,1.25\n' "$partition" "$first" | gzip -n; }
update() {
    printf 'pk,sk,version,status,balance,memo_state,memo\n%s,%s,1,ACTIVE,3.375,ABSENT,\n'  \
        "$partition" "$first" | gzip -n
}
deletion() { printf 'pk,sk,version\n%s,%s,0\n' "$partition" "$second" | gzip -n; }

record setup-migrate job=Migrate "runId=$run-migrate"
file_job 44-insert-only DynamoDbImport import 3 fixture dynamo.workers=2 chunkSize=1
get_item "$partition" "$first" | jq -e '.Item.balance.N == "2.125" and .Item.version.N == "0"' >/dev/null
get_item "$partition" "$second" | jq -e '.Item.memo.NULL == true' >/dev/null
get_item "$partition" "$third" | jq -e '.Item.memo.S == ""' >/dev/null
generation_partition="generation:$run-replace"
previous_partition=$partition
partition=$generation_partition
file_job 44-replace-generation DynamoDbImport replace 3 fixture dynamo.writeMode=replace dynamo.batchSize=2
get_item "$partition" "$first" | jq -e '.Item.status.S == "ACTIVE"' >/dev/null
partition=$previous_partition

record 42-query job=DynamoDbQueryExport "runId=$run-query" "dynamo.partition=$partition"     dynamo.pageLimit=1 dynamo.expectedItems=3 output.compression=gzip
record 42-gsi job=DynamoDbQueryExport "runId=$run-gsi" "dynamo.partition=$partition"     dynamo.pageLimit=1 dynamo.gsi=true dynamo.status=ACTIVE dynamo.expectedItems=2 output.compression=gzip
record 43-scan job=DynamoDbScanExport "runId=$run-scan" "dynamo.partition=$partition"     dynamo.pageLimit=1 dynamo.expectedItems=3 output.compression=gzip
object_hash() {
    local_aws s3 cp "s3://$internal/$1/$2/customers.csv.gz" - --only-show-errors | sha256sum | cut -d ' ' -f 1
}
[[ $(object_hash DynamoDbQueryExport "$run-query") == "$(object_hash DynamoDbScanExport "$run-scan")" ]]
local_aws s3 cp "s3://$internal/DynamoDbQueryExport/$run-query/customers.csv.gz" - --only-show-errors |
    gzip -dc | python3 -c '
import csv
import sys
rows = csv.reader(sys.stdin, strict=True)
assert next(rows) == ["pk", "sk", "version", "status", "balance", "memo_state", "memo"]
expected = [sys.argv[1:4], [sys.argv[4]] * 3]
for index, (pk, sk, version, status, balance, state, memo) in enumerate(rows):
    assert pk == expected[1][index] and sk == expected[0][index] and version == "0"
    assert state == ["VALUE", "NULL", "VALUE"][index]
    assert memo == ["多行\n名前", "", ""][index]
assert index == 2
' "$first" "$second" "$third" "$partition"

digest=$(addition | sha256sum | cut -d ' ' -f 1)
addition | local_aws s3 cp - "s3://$input/$upload/add.csv.gz" --only-show-errors
add_args=(job=DynamoDbConditionalUpdate "runId=$run-add" "input.key=$upload/add.csv.gz"
    "input.sha256=$digest" input.rows=1 input.compression=gzip "dynamo.partition=$partition" dynamo.operation=add)
exit_code=0
DDB_SCENARIO_PROFILE=local,fault-test DDB_SCENARIO_FAULT=AFTER_DYNAMO_WRITE \
    dynamo_batch "${add_args[@]}" > "$log_dir/45-interrupted.log" 2>&1 || exit_code=$?
if [[ "$exit_code" != 1 ]] || ! grep -q 'Test failure after DynamoDB success' "$log_dir/45-interrupted.log"; then
    tail -60 "$log_dir/45-interrupted.log" >&2
    exit 1
fi
get_item "$partition" "$first" | jq -e '.Item.balance.N == "3.375" and .Item.version.N == "1"' >/dev/null
psql_local -Atc "select delivered from dynamo_work where run_key='DynamoDbConditionalUpdate:$run-add'" | grep -qx f
record 45-resumed "${add_args[@]}"
get_item "$partition" "$first" | jq -e '.Item.balance.N == "3.375" and .Item.version.N == "1"' >/dev/null
psql_local -Atc "select delivered from dynamo_work where run_key='DynamoDbConditionalUpdate:$run-add'" | grep -qx t
file_job 45-update DynamoDbConditionalUpdate update 1 update
get_item "$partition" "$first" | jq -e '.Item.balance.N == "3.375" and .Item.version.N == "2"
    and .Item.memo.S == "多行\n名前"' >/dev/null

file_job 46-delete DynamoDbDelete delete 1 deletion
get_item "$partition" "$second" | jq -e 'has("Item") | not' >/dev/null

seed_id=$((base + 4))
year=$((2200 + base % 600))
date_from="$year-01-01"
date_to="$year-01-02"
psql_local -c "insert into customer(id,name,email,status,updated_at)
    values ($seed_id,'PG seed',null,'ACTIVE','$date_from 12:00:00+00')" >/dev/null
record 47-fixed job=PostgreSqlToDynamoDb "runId=$run-pg-fixed" "dynamo.partition=pg-$partition"     "sql.fromDate=$date_from" "sql.toDate=$date_to"
get_item "pg-$partition" "$seed_id" | jq -e '.Item.memo.S == "PG seed" and .Item.version.N == "0"' >/dev/null
record 47-outbox job=PostgreSqlToDynamoDb "runId=$run-pg-outbox" "dynamo.partition=pg-$partition"     "sql.fromDate=$date_from" "sql.toDate=$date_to" dynamo.operation=outbox dynamo.status=INACTIVE
get_item "pg-$partition" "$seed_id" | jq -e '.Item.status.S == "INACTIVE" and .Item.version.N == "1"' >/dev/null
psql_local -Atc "select count(*) from dynamo_outbox where run_key='PostgreSqlToDynamoDb:$run-pg-outbox'
    and delivered and sk='$seed_id' and version=1" | grep -qx 1
psql_local -Atc "select count(*) from customer where id=$seed_id and status='INACTIVE' and version=1" | grep -qx 1

record 48-postgresql job=DynamoDbToPostgreSql "runId=$run-to-pg" "dynamo.partition=$partition"     dynamo.readMode=SCAN dynamo.expectedItems=2 dynamo.pageLimit=1
psql_local -Atc "select count(*) from customer where (id=$first and name=E'多行\n名前' and status='ACTIVE')
    or (id=$third and name='' and status='INACTIVE')" | grep -qx 2
psql_local -Atc "select count(*) from customer where id=$second" | grep -qx 0

for mode in QUERY SCAN; do
    worker=1
    [[ "$mode" == QUERY ]] || worker=2
    label=${mode,,}
    target="generation:$run-$label"
    record "49-$label" job=DynamoDbBenchmark "runId=$run-bench-$label" "dynamo.partition=$partition"         "dynamo.readMode=$mode" dynamo.expectedItems=2 "dynamo.pageLimit=$worker"         "dynamo.batchSize=$worker" "dynamo.workers=$worker" "dynamo.targetPartition=$target"
    get_item "$target" "$first" | jq -e '.Item.balance.N == "3.375"' >/dev/null
    grep 'DynamoDB source\|DynamoDB delivery' "$log_dir/49-$label.log"
done
printf 'DynamoDB scenarios 42–49 passed against DynamoDB Local, S3 and PostgreSQL. Logs %s\n' "$log_dir"
