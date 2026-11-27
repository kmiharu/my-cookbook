#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/local-common.sh"

prefix=${1:-ops-$(date -u +%Y%m%dT%H%M%S)-$$}
if [[ ! "$prefix" =~ ^[a-zA-Z0-9_-]{1,40}$ ]]; then
    printf 'Use a prefix of up to 40 letters, digits, underscores, and hyphens.\n' >&2
    exit 2
fi
database="test_${prefix//-/_}"
internal=$(batch_env BATCH_INTERNAL_BUCKET)
input=$(batch_env BATCH_INPUT_BUCKET)
user=$(batch_env BATCH_DB_USER)
password=$(batch_env BATCH_DB_PASSWORD)

psql_at() {
    local service=$1
    shift
    "${compose[@]}" exec -T "$service" psql -U "$user" -X -Aqt -v ON_ERROR_STOP=1 "$@"
}

for service in postgres postgres-target; do
    printf "SELECT format('CREATE DATABASE %%I', :'db')\n\\gexec\n" |
        psql_at "$service" -d postgres -v "db=$database"
done

query() {
    psql_at postgres -d "$database" -c "$1"
}

expect() {
    local expected=$1 result
    result=$(query "$2")
    if [[ "$result" != "$expected" ]]; then
        printf 'Expected %s, got %s for SQL %s\n' "$expected" "$result" "$2" >&2
        return 1
    fi
}

launch() {
    local job_name=$1 run_suffix=$2 profiles=local
    shift 2
    local args=("job=$job_name" "runId=$prefix-$run_suffix" "$@")
    local halt_after_commit=${operations_fault_now:-false}
    if [[ "$halt_after_commit" == true ]]; then
        profiles=local,fault-test
    fi
    if [[ -n "${BATCH_LOCAL_JAR:-}" ]]; then
        env "SPRING_PROFILES_ACTIVE=$profiles" \
            "BATCH_MIGRATION_HALT_AFTER_TARGET_COMMIT=$halt_after_commit" \
            "BATCH_EXECUTION_OWNER=operations-$prefix" \
            "BATCH_DB_URL=jdbc:postgresql://127.0.0.1:${BATCH_POSTGRES_PORT:-15432}/$database" \
            "BATCH_DB_USER=$user" "BATCH_DB_PASSWORD=$password" \
            "BATCH_TARGET_DB_URL=jdbc:postgresql://127.0.0.1:${BATCH_TARGET_POSTGRES_PORT:-15433}/$database" \
            "BATCH_TARGET_DB_USER=$user" "BATCH_TARGET_DB_PASSWORD=$password" \
            "BATCH_S3_ENDPOINT=http://127.0.0.1:${BATCH_S3_PORT:-18333}" \
            "BATCH_S3_ACCESS_KEY=$(batch_env BATCH_S3_ACCESS_KEY)" \
            "BATCH_S3_SECRET_KEY=$(batch_env BATCH_S3_SECRET_KEY)" \
            "BATCH_INPUT_BUCKET=$input" "BATCH_INTERNAL_BUCKET=$internal" \
            "${BATCH_JAVA:-java}" -Xmx512m -jar "$BATCH_LOCAL_JAR" "${args[@]}"
    else
        "${compose[@]}" --profile batch run --rm -T --no-deps \
            -e "SPRING_PROFILES_ACTIVE=$profiles" \
            -e "BATCH_MIGRATION_HALT_AFTER_TARGET_COMMIT=$halt_after_commit" \
            -e "BATCH_EXECUTION_OWNER=operations-$prefix" \
            -e "BATCH_DB_URL=jdbc:postgresql://postgres:5432/$database" \
            -e "BATCH_TARGET_DB_URL=jdbc:postgresql://postgres-target:5432/$database" \
            batch "${args[@]}"
    fi
}

upload() {
    local object="operations/$prefix/$1.csv" data=$2
    current_sha=$(printf '%s' "$data" | sha256sum | cut -d' ' -f1)
    current_key=$object
    printf '%s' "$data" | local_aws s3 cp - "s3://$input/$object" --only-show-errors
}

verify_object() {
    local job_name=$1 run_suffix=$2 artifact=$3 expected_rows=$4 actual_hash stored_hash
    actual_hash=$(local_aws s3 cp "s3://$internal/$job_name/$prefix-$run_suffix/$artifact.csv" - --only-show-errors |
        sha256sum | cut -d' ' -f1)
    stored_hash=$(query "SELECT sha256 FROM batch_artifact
        WHERE artifact_id='$job_name/$artifact' AND run_id='$prefix-$run_suffix' AND state='COMPLETE'
          AND row_count=$expected_rows")
    test "$actual_hash" = "$stored_hash"
}

launch Migrate migrate
psql_at postgres -d "$database" <<'SQL'
INSERT INTO customer(id,name,email,status,updated_at) VALUES
(6, 'delete', NULL, 'ACTIVE', '2020-01-01Z'),
(9, ' Name ', ' SAMPLE@EXAMPLE.INVALID ', 'ACTIVE', '2020-01-01Z'),
(10, 'aggregate', NULL, 'ACTIVE', '2021-02-01Z'),
(11, 'status', NULL, 'INACTIVE', '2020-01-01Z'),
(12, 'bulk-one', NULL, 'INACTIVE', '2020-01-01Z'),
(13, 'bulk-two', NULL, 'INACTIVE', '2020-01-01Z'),
(14, 'reconcile-before', NULL, 'ACTIVE', '2020-01-01Z'),
(15, 'migration', NULL, 'ACTIVE', '2020-01-01Z'),
(16, 'patch', NULL, 'INACTIVE', '2020-01-01Z'),
(17, 'backfill', NULL, 'ACTIVE', '2020-01-01Z'),
(18, 'archive', NULL, 'ACTIVE', '2020-01-01Z'),
(20, 'conditional', NULL, 'INACTIVE', '2020-01-01Z'),
(28, 'incremental', NULL, 'ACTIVE', '2021-03-01Z');
SQL

upload delete $'id,version\n6,0\n'
launch CustomerDelete delete "input.key=$current_key" "input.sha256=$current_sha" input.rows=1 expectedRows=1
expect 0 'SELECT count(*) FROM customer WHERE id=6'
printf 'Scenario 06 passed\n'

launch DataTransform transform idFrom=9 idTo=9 expectedRows=1
expect 'Name|sample@example.invalid|NORMALIZED' "SELECT name,email,detail FROM batch_operation_work WHERE job_name='DataTransform'"
verify_object DataTransform transform transformed 1
printf 'Scenario 09 passed\n'

launch Aggregation aggregation-day period=day sql.fromDate=2021-02-01 sql.toDate=2021-03-01
launch Aggregation aggregation-month period=month sql.fromDate=2021-02-01 sql.toDate=2021-03-01
launch Aggregation aggregation-replay period=day sql.fromDate=2021-02-01 sql.toDate=2021-03-01
expect 'day|1
month|1' "SELECT period,customer_count FROM batch_customer_totals WHERE bucket_date='2021-02-01' ORDER BY period"
printf 'Scenario 10 passed\n'

launch StatusUpdate status idFrom=11 idTo=11 targetStatus=ACTIVE expectedRows=1
expect 'ACTIVE|1' 'SELECT status,version FROM customer WHERE id=11'
printf 'Scenario 11 passed\n'

launch BulkUpdate bulk-single idFrom=12 idTo=12 targetStatus=ACTIVE expectedRows=1 mode=single
launch BulkUpdate bulk-chunk idFrom=13 idTo=13 targetStatus=ACTIVE expectedRows=1 mode=chunk chunkSize=1
expect 2 "SELECT count(*) FROM customer WHERE id IN (12,13) AND status='ACTIVE' AND version=1"
printf 'Scenario 12 passed\n'

upload reconcile $'id,name,email,status\n14,reconcile-after,,INACTIVE\n140,new,,ACTIVE\n'
launch DataReconciliation reconcile "input.key=$current_key" "input.sha256=$current_sha" input.rows=2
expect '14|CHANGED
140|NEW' "SELECT id,detail FROM batch_operation_work WHERE job_name='DataReconciliation'
    AND id IN (14,140) ORDER BY id"
expect 1 "SELECT count(*) FROM batch_operation_work WHERE job_name='DataReconciliation' AND id=15 AND detail='MISSING'"
verify_object DataReconciliation reconcile reconciliation "$(query "SELECT count(*) FROM batch_operation_work WHERE job_name='DataReconciliation'")"
printf 'Scenario 14 passed\n'

launch DataMigration migration idFrom=15 idTo=15 expectedRows=1 chunkSize=1
test "$(psql_at postgres-target -d "$database" -c 'SELECT name FROM customer WHERE id=15')" = migration
test "$(psql_at postgres-target -d "$database" -c "SELECT count(*) FROM batch_migration_progress WHERE run_id='$prefix-migration'")" = 1
migration_exit=0
operations_fault_now=true launch DataMigration migration-restart idFrom=12 idTo=13 expectedRows=2 chunkSize=1 || migration_exit=$?
test "$migration_exit" = 97
test "$(psql_at postgres-target -d "$database" -c "SELECT count(*) FROM batch_migration_progress WHERE run_id='$prefix-migration-restart'")" = 1
old_execution=$(query "SELECT job_execution_id FROM batch_job_execution_params
    WHERE parameter_name='runId' AND parameter_value='$prefix-migration-restart'")
expect STARTED "SELECT status FROM batch_job_execution WHERE job_execution_id=$old_execution"
launch DataMigration migration-restart idFrom=12 idTo=13 expectedRows=2 chunkSize=1 \
    "recover.executionId=$old_execution" "recover.owner=operations-$prefix"
test "$(psql_at postgres-target -d "$database" -c "SELECT count(*) FROM batch_migration_progress WHERE run_id='$prefix-migration-restart'")" = 2
expect 1 "SELECT count(DISTINCT e.job_instance_id) FROM batch_job_execution e
    JOIN batch_job_execution_params p USING (job_execution_id)
    WHERE p.parameter_name='runId' AND p.parameter_value='$prefix-migration-restart'"
printf 'Scenario 15 passed\n'

patch="patchId=$prefix-patch"
plan="planId=$prefix-patch-plan"
launch DataPatch preview "$patch" "$plan" idFrom=16 idTo=16 expectedRows=1
expect 'INACTIVE|0' 'SELECT status,version FROM customer WHERE id=16'
verify_object DataPatchPreview preview patch-preview 1
launch DataPatchApply apply "$patch" "$plan" mode=chunk chunkSize=1 expectedRows=1
expect 'ACTIVE|1' 'SELECT status,version FROM customer WHERE id=16'
verify_object DataPatchApply apply patch-backup 1
verify_object DataPatchApply apply patch-diff 1
launch DataPatchRestore restore "$patch" "$plan" expectedRows=1
expect 'INACTIVE|2' 'SELECT status,version FROM customer WHERE id=16'
verify_object DataPatchRestore restore patch-restore 1
printf 'Scenario 16 passed\n'

launch DataBackfill backfill idFrom=17 idTo=17 expectedRows=1
expect 'customer-17@example.invalid|1' 'SELECT email,version FROM customer WHERE id=17'
printf 'Scenario 17 passed\n'

launch DataArchive archive idFrom=18 idTo=18 expectedRows=1
expect 0 'SELECT count(*) FROM customer WHERE id=18'
verify_object DataArchive archive archive 1
printf 'Scenario 18 passed\n'

query "UPDATE batch_run SET updated_at=clock_timestamp()-interval '90 days'
    WHERE job_name='DataTransform' AND run_id='$prefix-transform'"
query "INSERT INTO batch_run(job_name,run_id,state,settings,owner,owner_location,updated_at)
    VALUES ('DataTransform','$prefix-active','ACTIVE','{}','test','smoke',clock_timestamp()-interval '90 days')"
query "INSERT INTO batch_operation_work(job_name,run_id,id,name,status,updated_at,version)
    VALUES ('DataTransform','$prefix-active',900,'active','ACTIVE',clock_timestamp(),0)"
launch DataCleanup cleanup retainDays=30
expect "$prefix-active" "SELECT run_id FROM batch_operation_work WHERE job_name='DataTransform' ORDER BY run_id"
printf 'Scenario 19 passed\n'

launch ConditionalFlow branch-preview branch=preview idFrom=20 idTo=20 expectedRows=1
expect INACTIVE 'SELECT status FROM customer WHERE id=20'
launch ConditionalFlow branch-apply branch=apply idFrom=20 idTo=20 expectedRows=1
expect ACTIVE 'SELECT status FROM customer WHERE id=20'
verify_object ConditionalFlow branch-preview conditional 1
verify_object ConditionalFlow branch-apply conditional 1
printf 'Scenario 20 passed\n'

launch IncrementalExport incremental "watermarkId=$prefix" sql.fromDate=2021-03-01 sql.toDate=2021-03-02
expect '2021-03-02' "SELECT (next_lower AT TIME ZONE 'UTC')::date FROM batch_watermark WHERE watermark_id='$prefix'"
verify_object IncrementalExport incremental incremental 1
printf 'Scenario 28 passed\n'

upload master-default $'id,name,email,status\n14,master-after,,ACTIVE\n270,new-master,,ACTIVE\n'
launch MasterSync sync-no-delete "input.key=$current_key" "input.sha256=$current_sha" input.rows=2 expectedRows=2
expect 1 'SELECT count(*) FROM customer WHERE id=15'
expect 'master-after|ACTIVE' 'SELECT name,status FROM customer WHERE id=14'
upload master-delete $'id,name,email,status\n14,master-complete,,ACTIVE\n270,new-master,,ACTIVE\n'
launch MasterSync sync-delete "input.key=$current_key" "input.sha256=$current_sha" input.rows=2 expectedRows=2 deleteMissing=true
expect '14|master-complete
270|new-master' 'SELECT id,name FROM customer ORDER BY id'
printf 'Scenario 27 passed\n'

printf 'Passed 14 scenarios. PostgreSQL smoke database: %s on both local services.\n' "$database"
