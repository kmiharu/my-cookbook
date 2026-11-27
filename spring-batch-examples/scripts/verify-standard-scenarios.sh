#!/usr/bin/env bash
# Local PostgreSQL and SeaweedFS. Start with scripts/setup-local.sh and a migrated schema.
set -euo pipefail
cd "$(dirname "$0")/.."
prefix="${BATCH_SCENARIO_PREFIX:-standard-$(date +%s)-$$}"
[[ "$prefix" =~ ^[a-zA-Z0-9-]{1,50}$ ]] || { echo "Invalid test prefix" >&2; exit 2; }
logs="${BATCH_LOG_DIR:-bench-results/raw/$prefix}"
mkdir -p "$logs"
compose=(docker compose)
db="test_${prefix//-/_}"
dbuser="${BATCH_DB_USER:-cookbook}"
internal="${BATCH_INTERNAL_BUCKET:-batch-internal}"
partner="${BATCH_PARTNER_BUCKET:-batch-partner}"
input="${BATCH_INPUT_BUCKET:-batch-input}"
export BATCH_DB_URL="jdbc:postgresql://127.0.0.1:${BATCH_POSTGRES_PORT:-15432}/$db"
export BATCH_TARGET_DB_URL=""
export BATCH_DB_USER="$dbuser" BATCH_DB_PASSWORD="${BATCH_DB_PASSWORD:-local-cookbook}"
export BATCH_S3_ENDPOINT="${BATCH_S3_ENDPOINT:-http://127.0.0.1:${BATCH_S3_PORT:-18333}}"
export BATCH_S3_ACCESS_KEY="${BATCH_S3_ACCESS_KEY:-localcookbook}" BATCH_S3_SECRET_KEY="${BATCH_S3_SECRET_KEY:-localcookbooksecret}"
export BATCH_INTERNAL_BUCKET="$internal" BATCH_PARTNER_BUCKET="$partner" BATCH_INPUT_BUCKET="$input"

sql() { "${compose[@]}" exec -T postgres psql -XAt -v ON_ERROR_STOP=1 -U "$dbuser" -d "$db" -c "$1"; }
s3() { "${compose[@]}" exec -T awscli aws --endpoint-url http://s3:8333 s3 "$@"; }
batch() {
  if [[ "${BATCH_SCENARIO_RUNNER:-docker}" == host ]]; then
    java -Xmx512m -XX:+ExitOnOutOfMemoryError -jar "${BATCH_JAR:-batch-examples/build/libs/batch-examples.jar}" \
      "--spring.profiles.active=${TEST_PROFILE:-local}" "$@"
  else
    "${compose[@]}" --profile batch run --rm --no-deps \
      -e "BATCH_DB_URL=jdbc:postgresql://postgres:5432/$db" -e BATCH_TARGET_DB_URL= \
      -e "SPRING_PROFILES_ACTIVE=${TEST_PROFILE:-local}" -e "BATCH_FAULT_PHASE=${BATCH_FAULT_PHASE:-}" \
      -e "BATCH_FAULT_ACTION=${BATCH_FAULT_ACTION:-}" batch "$@"
  fi
}
invoke() {
  local name="$1" key="$2"
  shift 2
  batch "job=$name" "runId=$prefix-$key" "$@" > "$logs/$key.log" 2>&1 || {
    tail -50 "$logs/$key.log" >&2
    return 1
  }
}
assert() {
  if [[ "$1" != "$2" ]]; then
    printf 'Assertion failed: %s (actual=%s expected=%s)\n' "$3" "$1" "$2" >&2
    exit 1
  fi
}
publish() {
  local key="$1" body="$2"
  printf '%s' "$body" | s3 cp - "s3://$input/$prefix/$key" --only-show-errors
  printf '%s' "$body" | sha256sum | cut -d' ' -f1
}
hash_object() { s3 cp "s3://$1/$2" - --only-show-errors | sha256sum | cut -d' ' -f1; }
rows_of() {
  s3 cp "s3://$internal/$1" - --only-show-errors | python3 -c '
import csv,sys
rows=csv.reader(sys.stdin)
next(rows)
print(sum(1 for _ in rows))'
}
job_rows() {
  sql "SELECT COALESCE(sum(row_count),0) FROM batch_artifact WHERE run_id='$prefix-$1' AND artifact_id NOT LIKE '%/manifest' AND destination='internal' AND state='COMPLETE'"
}
"${compose[@]}" exec -T postgres createdb -U "$dbuser" "$db"
batch job=Migrate "runId=$prefix-migrate" > "$logs/migrate.log" 2>&1 || {
  tail -40 "$logs/migrate.log" >&2
  exit 1
}
printf 'Test database=%s logs=%s\n' "$db" "$logs"

# Seed a private date slice and one 1:N association. This SQL runs only against the local practice DB.
sql "INSERT INTO customer(id,name,email,status,updated_at) VALUES
(710000101,'空,欄',NULL,'ACTIVE','2026-03-01T00:00:00Z'),
(710000102,'二口',NULL,'ACTIVE','2026-03-01T00:00:00Z'),
(710000103,'範囲外',NULL,'ACTIVE','2026-03-02T00:00:00Z')
ON CONFLICT DO NOTHING;
INSERT INTO membership(customer_id,member_id,tier) VALUES (710000102,1,'A'),(710000102,2,'B') ON CONFLICT DO NOTHING;" >/dev/null
scope=(sql.fromDate=2026-03-01 sql.toDate=2026-03-02)
invoke CustomerExport export "${scope[@]}" destinations=both output.compression=gzip
key="CustomerExport/$prefix-export/customers.csv.gz"
assert "$(hash_object "$internal" "$key")" "$(hash_object "$partner" "$key")" '01 fanout equality'
assert "$(job_rows export)" 2 '01 date boundary'
echo 'PASS 01'
invoke WorkTableExport work "${scope[@]}"
assert "$(rows_of "WorkTableExport/$prefix-work/customers.csv")" 2 '02 work rows'
echo 'PASS 02'
invoke MultiFileExport multi "${scope[@]}"
assert "$(rows_of "MultiFileExport/$prefix-multi/customers.csv")" 2 '03 simple'
assert "$(rows_of "MultiFileExport/$prefix-multi/customer-members.csv")" 3 '03 1:N + absent'
echo 'PASS 03'
invoke ParallelStep parallel "${scope[@]}"
assert "$(job_rows parallel)" 5 '21 parallel'
echo 'PASS 21'
invoke Partitioned part "${scope[@]}" partitions=2
assert "$(job_rows part)" 2 '22 partitions'
assert "$(sql "SELECT count(*) FROM batch_artifact WHERE run_id='$prefix-part' AND artifact_id LIKE 'Partitioned/customers-part-%'")" 2 '22 object count'
printf '%s\n' 'PASS 22'
TEST_PROFILE=local,fault-test BATCH_FAULT_PHASE=RETRY_SNAPSHOT invoke Retry retry "${scope[@]}"
grep -q 'retrying transient PostgreSQL error' "$logs/retry.log"
assert "$(job_rows retry)" 2 '23 retry'
echo 'PASS 23'
invoke FullExport full "${scope[@]}"
assert "$(job_rows full)" 2 '29 full'
echo 'PASS 29'

header=$'id,name,email,status\n'
sha=$(publish direct.csv "${header}"$'710000111,first,,ACTIVE\n710000112,second,,INACTIVE\n')
invoke CustomerImport direct "input.key=$prefix/direct.csv" "input.sha256=$sha" input.rows=2 chunkSize=1
assert "$(sql 'SELECT count(*) FROM customer WHERE id BETWEEN 710000111 AND 710000112')" 2 '04 direct insert'
echo 'PASS 04'
sha=$(publish upsert.csv "${header}"$'710000111,new,,ACTIVE\n')
invoke CustomerUpsert upsert "input.key=$prefix/upsert.csv" "input.sha256=$sha" input.rows=1
assert "$(sql 'SELECT name||version FROM customer WHERE id=710000111')" new1 '05 upsert version'
echo 'PASS 05'
sha=$(publish validated.csv "${header}"$'bad,one,,ACTIVE\n710000113,"double\nline",,ACTIVE\n')
invoke ValidatedImport validated "input.key=$prefix/validated.csv" "input.sha256=$sha" input.rows=2 skipLimit=1 chunkSize=1
assert "$(rows_of "ValidatedImport/$prefix-validated/errors.csv")" 1 '07 rejected record'
assert "$(sql "SELECT strpos(name,chr(10))>0 FROM customer WHERE id=710000113")" t '07 multiline'
echo 'PASS 07'
one=$(publish one.csv "${header}"$'710000114,one,,ACTIVE\n')
two=$(publish two.csv "${header}"$'710000115,two,,INACTIVE\n')
invoke MultiFileImport multi-in "input.keys=$prefix/one.csv,$prefix/two.csv" "input.sha256=$one,$two" input.rows=1,1
assert "$(sql "SELECT string_agg(file_index::text,',' ORDER BY file_index) FROM batch_input_check WHERE run_id='$prefix-multi-in'")" 0,1 '08 input order'
echo 'PASS 08'
sha=$(publish apply-export.csv "${header}"$'710000116,fresh,,INACTIVE\n')
invoke ImportAndExport apply-export "input.key=$prefix/apply-export.csv" "input.sha256=$sha" input.rows=1
assert "$(rows_of "ImportAndExport/$prefix-apply-export/customers.csv")" 1 '13 applied output'
echo 'PASS 13'
sha=$(publish skip.csv "${header}"$'bad,skip,,ACTIVE\n710000117,after,,INACTIVE\n')
invoke SkipRecord skip "input.key=$prefix/skip.csv" "input.sha256=$sha" input.rows=2 skipLimit=1 chunkSize=1
assert "$(sql "SELECT ordinal FROM batch_input_error WHERE run_id='$prefix-skip'")" 1 '24 ordinal'
echo 'PASS 24'

sha=$(publish restart.csv "${header}"$'bad,skip,,ACTIVE\n710000118,after,,INACTIVE\n710000119,last,,ACTIVE\n')
restart=("job=Restartable" "runId=$prefix-restart" "input.key=$prefix/restart.csv" "input.sha256=$sha" input.rows=3 skipLimit=1 chunkSize=2)
code=0
TEST_PROFILE=local,fault-test BATCH_FAULT_PHASE=AFTER_CHUNK_COMMIT BATCH_FAULT_ACTION=halt \
  batch "${restart[@]}" > "$logs/restart-fault.log" 2>&1 || code=$?
assert "$code" 97 '25 injected halt'
assert "$(sql "SELECT count(*) FROM batch_input_work WHERE run_id='$prefix-restart'")" 1 '25 staged before halt'
assert "$(sql 'SELECT count(*) FROM customer WHERE id BETWEEN 710000118 AND 710000119')" 0 '25 no early business apply'
instance=$(sql "SELECT max(e.job_instance_id) FROM batch_job_execution e JOIN batch_job_execution_params p USING(job_execution_id) WHERE p.parameter_name='runId' AND p.parameter_value='$prefix-restart'")
execution=$(sql "SELECT max(job_execution_id) FROM batch_job_execution WHERE job_instance_id=$instance")
owner=$(sql "SELECT owner_location FROM batch_run WHERE job_name='Restartable' AND run_id='$prefix-restart'")
batch "${restart[@]}" "recover.executionId=$execution" "recover.owner=$owner" > "$logs/restart.log" 2>&1
assert "$(sql "SELECT string_agg(status,',' ORDER BY job_execution_id) FROM batch_job_execution WHERE job_instance_id=$instance")" FAILED,COMPLETED '25 same instance'
assert "$(sql "SELECT count(*) FROM batch_input_error WHERE run_id='$prefix-restart'")" 1 '25 no repeated error'
assert "$(sql 'SELECT count(*) FROM customer WHERE id BETWEEN 710000118 AND 710000119')" 2 '25 apply once'
echo 'PASS 25'
publish ready 'ready' > /dev/null
invoke FileArrivalCheck arrival "input.key=$prefix/restart.csv" "input.readyKey=$prefix/ready" "input.sha256=$sha" arrivalTimeoutSeconds=2
echo 'PASS 26'

invoke FileTransfer transfer "input.key=$prefix/restart.csv" "input.sha256=$sha" destinations=both
assert "$(hash_object "$internal" "FileTransfer/$prefix-transfer/transferred.bin")" "$sha" '30 streaming checksum'
invoke FileTransfer copy-object "input.key=$prefix/restart.csv" "input.sha256=$sha" transferMode=copy
assert "$(hash_object "$internal" "FileTransfer/$prefix-copy-object/transferred.bin")" "$sha" '30 copy checksum'
echo 'PASS 30'
invoke ChecksumValidation checksum "input.key=$prefix/restart.csv" "input.sha256=$sha" input.rows=3 skipLimit=1
code=0
batch job=ChecksumValidation "runId=$prefix-checksum-invalid" "input.key=$prefix/restart.csv" \
   "input.sha256=$(printf '%064d' 0)" input.rows=3 skipLimit=1 > "$logs/checksum-invalid.log" 2>&1 || code=$?
assert "$code" 1 '31 incorrect SHA rejected'
echo 'PASS 31'
invoke SqlOptimization sql-plan
grep -q 'explain=after-range' "$logs/sql-plan.log"
echo 'PASS 32'
invoke IndexOptimization index-plan
grep -q 'explain=after-composite-index' "$logs/index-plan.log"
echo 'PASS 33'
invoke FetchSizeBenchmark fetch "${scope[@]}" fetchSize=100
assert "$(job_rows fetch)" 2 '34 fetch size'
echo 'PASS 34'
for mode in sequential batch rewrite; do
  invoke BatchInsertBenchmark "insert-$mode" "mode=$mode" rows=12 chunkSize=3
  grep -q "insert-mode=$mode rows=12" "$logs/insert-$mode.log"
done
echo 'PASS 35'
invoke CopyExport copy-out "${scope[@]}"
assert "$(rows_of "CopyExport/$prefix-copy-out/customers.csv")" 2 '36 COPY TO'
echo 'PASS 36'
sha=$(publish copy.csv "${header}"$'710000120,"copy,quoted","",ACTIVE\n')
invoke CopyImport copy-in "input.key=$prefix/copy.csv" "input.sha256=$sha" input.rows=1
assert "$(sql "SELECT name||'/'||(email='')::text FROM customer WHERE id=710000120")" 'copy,quoted/true' '37 COPY FROM'
echo 'PASS 37'
invoke ParallelMultipartUpload concurrent "${scope[@]}" destinations=both transferWorkers=2 totalBuffers=3
assert "$(job_rows concurrent)" 2 '38 parallel multipart'
echo 'PASS 38'
invoke PartitionBenchmark partition-bench "${scope[@]}" partitions=2
assert "$(job_rows partition-bench)" 2 '39 partition benchmark'
echo 'PASS 39'
invoke GzipBenchmark gzip "${scope[@]}" output.compression=gzip output.gzipLevel=1
assert "$(job_rows gzip)" 2 '40 gzip benchmark'
echo 'PASS 40'
sha=$(publish chunk.csv "${header}"$'710000121,chunk,,ACTIVE\n')
invoke ChunkSizeBenchmark chunk "input.key=$prefix/chunk.csv" "input.sha256=$sha" input.rows=1 chunkSize=1
assert "$(sql 'SELECT name FROM customer WHERE id=710000121')" chunk '41 chunk benchmark'
echo 'PASS 41'
