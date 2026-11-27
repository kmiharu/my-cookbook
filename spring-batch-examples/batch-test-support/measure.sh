#!/usr/bin/env bash
# Functions shared by the isolated local benchmark runners.
batch_measure_stop() {
    if [[ -n ${measured_pid:-} ]]; then
        kill -TERM "$measured_pid" 2>/dev/null || true
        wait "$measured_pid" 2>/dev/null || true
    fi
    if [[ -n ${measured_container:-} ]]; then
        docker stop --time 120 "$measured_container" >/dev/null 2>&1 || true
        docker rm "$measured_container" >/dev/null 2>&1 || true
    fi
    if [[ -n ${service_sampler:-} ]]; then
        kill "$service_sampler" 2>/dev/null || true
        wait "$service_sampler" 2>/dev/null || true
    fi
}

batch_measure() {
    local directory=$1 name=$2 job=$3 exit_code
    shift 3
    if [[ -n ${BATCH_BENCH_HOST_JAR:-} ]]; then
        batch_measure_host "$directory" "$name" "$job" "$@"
        return
    fi
    measured_container=$name
    batch_database_counters > "$directory/$name.database-before.json" || true
    "${compose[@]}" --profile batch run -d -T --no-deps --name "$name" "${benchmark_db_override[@]}" "${benchmark_s3_base_override[@]}" "${benchmark_s3_override[@]}" \
        -e 'JAVA_TOOL_OPTIONS=-Xmx512m -XX:+ExitOnOutOfMemoryError -Xlog:gc*:stdout:uptime,level,tags' \
        batch "job=$job" "runId=$name" "$@" > "$directory/$name.launch" || return 1
    local -a service_ids=()
    mapfile -t service_ids < <("${compose[@]}" ps -q dynamodb)
    if [[ -n ${BATCH_BENCH_PG_CONTAINER:-} ]]; then
        service_ids+=("$BATCH_BENCH_PG_CONTAINER")
    else
        service_ids+=("$("${compose[@]}" ps -q postgres)")
    fi
    if [[ -n ${BATCH_BENCH_S3_CONTAINER:-} ]]; then
        service_ids+=("$BATCH_BENCH_S3_CONTAINER")
    else
        service_ids+=("$("${compose[@]}" ps -q s3)")
    fi
    if (( ${#service_ids[@]} )); then
        (
            while [[ $(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null) == true ]]; do
                docker stats --no-stream --format '{{json .}}' "${service_ids[@]}" |
                    jq -c --arg at "$(date -u +%FT%TZ)" '. + {timestamp: $at}' || true
                batch_psql -Atc "SELECT json_build_object('timestamp', clock_timestamp(),
                    'connections', count(*), 'waiting_for_locks', count(*) FILTER (WHERE wait_event_type='Lock'),
                    'longest_transaction_seconds', MAX(EXTRACT(EPOCH FROM clock_timestamp()-xact_start)))
                    FROM pg_stat_activity WHERE datname=current_database() AND pid<>pg_backend_pid()" \
                    >> "$directory/$name.database-samples.jsonl" || true
                sleep 2
            done
        ) > "$directory/$name.services.jsonl" 2> "$directory/$name.services.log" &
        service_sampler=$!
    fi

    printf 'timestamp\trss_kib\thwm_kib\tcpu_ticks\tcgroup_limit_bytes\tcgroup_peak_bytes\tcgroup_cpu_usec\n' \
        > "$directory/$name.samples.tsv"
    while [[ $(docker inspect -f '{{.State.Running}}' "$name") == true ]]; do
        docker exec "$name" sh -ec '
            rss=$(awk "/^VmRSS:/ {print \$2}" /proc/1/status)
            hwm=$(awk "/^VmHWM:/ {print \$2}" /proc/1/status)
            cpu=$(awk "{print \$14 + \$15}" /proc/1/stat)
            limit=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || printf unknown)
            peak=$(cat /sys/fs/cgroup/memory.peak 2>/dev/null || printf unknown)
            cgroup_cpu=$(awk "\$1 == \"usage_usec\" {print \$2}" /sys/fs/cgroup/cpu.stat 2>/dev/null || printf unknown)
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$(date -u +%FT%TZ)" "$rss" "$hwm" "$cpu" "$limit" "$peak" "$cgroup_cpu"
        ' >> "$directory/$name.samples.tsv" 2>/dev/null || true
        sleep 0.5
    done
    exit_code=$(docker wait "$name")
    docker logs "$name" > "$directory/$name.log" 2>&1
    docker inspect -f '{{json .State}}' "$name" > "$directory/$name.state.json"
    docker inspect -f '{"image":"{{.Image}}","memory":{{.HostConfig.Memory}},"nanoCpus":{{.HostConfig.NanoCpus}}}' \
        "$name" > "$directory/$name.runtime.json"
    docker rm "$name" >/dev/null
    measured_container=
    batch_database_counters > "$directory/$name.database-after.json" || true
    if [[ -n ${service_sampler:-} ]]; then
        wait "$service_sampler" || true
        service_sampler=
    fi
    [[ "$exit_code" == 0 ]]
}

batch_measure_host() {
    local directory=$1 name=$2 job=$3 started ended exit_code=0 rss hwm cpu
    shift 3
    started=$(date -u +%FT%T.%NZ)
    "${benchmark_host_command[@]}" "job=$job" "runId=$name" "$@" > "$directory/$name.log" 2>&1 &
    measured_pid=$!
    printf '%s\n' "$measured_pid" > "$directory/$name.launch"
    printf 'timestamp\trss_kib\thwm_kib\tcpu_ticks\tcgroup_limit_bytes\tcgroup_peak_bytes\tcgroup_cpu_usec\n' \
        > "$directory/$name.samples.tsv"
    while [[ -r /proc/$measured_pid/status ]]; do
        read -r rss hwm < <(awk '/^VmRSS:/ {r=$2} /^VmHWM:/ {h=$2} END {print r,h}' "/proc/$measured_pid/status" 2>/dev/null) || break
        cpu=$(awk '{print $14 + $15}' "/proc/$measured_pid/stat" 2>/dev/null) || break
        printf '%s\t%s\t%s\t%s\tunknown\tunknown\tunknown\n' \
            "$(date -u +%FT%TZ)" "$rss" "$hwm" "$cpu" >> "$directory/$name.samples.tsv"
        sleep 0.5
    done
    wait "$measured_pid" || exit_code=$?
    measured_pid=
    ended=$(date -u +%FT%T.%NZ)
    jq -n --arg started "$started" --arg ended "$ended" --argjson status "$exit_code" \
        '{StartedAt:$started, FinishedAt:$ended, ExitCode:$status, OOMKilled:null}' > "$directory/$name.state.json"
    jq -n --arg sha "$benchmark_jar_sha256" '{mode:"host", jar_sha256:$sha}' > "$directory/$name.runtime.json"
    [[ "$exit_code" == 0 ]]
}

batch_host_configure() {
    [[ -n ${BATCH_BENCH_DB:-} && -z ${BATCH_BENCH_PG_CONTAINER:-} && -f "$BATCH_BENCH_HOST_JAR" ]] || {
        printf 'Host benchmarks require an executable JAR and a separate local BATCH_BENCH_DB.\n' >&2
        return 2
    }
    export SPRING_PROFILES_ACTIVE=local AWS_EC2_METADATA_DISABLED=true AWS_REGION=us-east-1
    export BATCH_DB_URL="jdbc:postgresql://127.0.0.1:${BATCH_POSTGRES_PORT:-15432}/$BATCH_BENCH_DB"
    export BATCH_DB_USER BATCH_DB_PASSWORD BATCH_S3_ACCESS_KEY BATCH_S3_SECRET_KEY
    export BATCH_INPUT_BUCKET BATCH_INTERNAL_BUCKET BATCH_PARTNER_BUCKET
    BATCH_DB_USER=$(batch_env BATCH_DB_USER)
    BATCH_DB_PASSWORD=$(batch_env BATCH_DB_PASSWORD)
    BATCH_S3_ACCESS_KEY=$(batch_env BATCH_S3_ACCESS_KEY)
    BATCH_S3_SECRET_KEY=$(batch_env BATCH_S3_SECRET_KEY)
    BATCH_INPUT_BUCKET=$(batch_env BATCH_INPUT_BUCKET)
    BATCH_INTERNAL_BUCKET=$(batch_env BATCH_INTERNAL_BUCKET)
    BATCH_PARTNER_BUCKET=$(batch_env BATCH_PARTNER_BUCKET)
    export BATCH_S3_ENDPOINT="http://127.0.0.1:${BATCH_S3_PORT:-18333}"
    export BATCH_DYNAMO_ENDPOINT="http://127.0.0.1:${BATCH_DYNAMO_PORT:-18000}"
    export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
    export NO_PROXY="${NO_PROXY:-},localhost,127.0.0.1" no_proxy="${no_proxy:-},localhost,127.0.0.1"
    benchmark_jar_sha256=$(sha256sum "$BATCH_BENCH_HOST_JAR" | cut -d' ' -f1)
    benchmark_host_command=("${BATCH_BENCH_JAVA:-java}" -Xmx512m -XX:+ExitOnOutOfMemoryError
        -Xlog:gc*:stdout:uptime,level,tags -jar "$BATCH_BENCH_HOST_JAR")
}

batch_host() {
    "${benchmark_host_command[@]}" "$@"
}

benchmark_db_override=()
benchmark_s3_base_override=()
benchmark_s3_override=()

benchmark_aws() {
    if [[ -z ${BATCH_BENCH_S3_CONTAINER:-} ]]; then
        local_aws "$@"
        return
    fi
    if [[ ! "$BATCH_BENCH_S3_CONTAINER" =~ ^cookbook-bench-s3-[a-z0-9-]+$ || "$1" != s3 && "$1" != s3api ]]; then
        printf 'Use a disposable local cookbook-bench-s3-* container.\n' >&2
        return 2
    fi
    "${compose[@]}" exec -T -e "NO_PROXY=$BATCH_BENCH_S3_CONTAINER" -e "no_proxy=$BATCH_BENCH_S3_CONTAINER" awscli \
        aws --no-cli-pager --cli-connect-timeout 3 --cli-read-timeout 60 \
        --endpoint-url "http://$BATCH_BENCH_S3_CONTAINER:8333" "$@"
}

batch_configure_isolated_s3() {
    if [[ -z ${BATCH_BENCH_S3_CONTAINER:-} ]]; then
        return
    fi
    if [[ -n ${BATCH_BENCH_HOST_JAR:-} ]]; then
        printf 'Isolated S3 requires the local batch container.\n' >&2
        return 2
    fi
    benchmark_aws s3api list-buckets >/dev/null
    benchmark_s3_base_override=(-e "BATCH_S3_ENDPOINT=http://$BATCH_BENCH_S3_CONTAINER:8333"
        -e "NO_PROXY=$BATCH_BENCH_S3_CONTAINER" -e "no_proxy=$BATCH_BENCH_S3_CONTAINER")
}

benchmark_pg_exec() {
    if [[ -n ${BATCH_BENCH_PG_CONTAINER:-} ]]; then
        docker exec -i "$BATCH_BENCH_PG_CONTAINER" "$@"
    else
        "${compose[@]}" exec -T postgres "$@"
    fi
}

batch_psql() {
    benchmark_pg_exec sh -ec '
        requested=$1
        shift
        exec psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "${requested:-$POSTGRES_DB}" "$@"
    ' sh "${BATCH_BENCH_DB:-}" "$@"
}

batch_create_database() {
    if [[ -z ${BATCH_BENCH_DB:-} ]]; then
        return
    fi
    if [[ ! "$BATCH_BENCH_DB" =~ ^cookbook_bench_[a-z0-9_]{1,35}$ ]]; then
        printf 'BATCH_BENCH_DB must begin with cookbook_bench_ and name a disposable database.\n' >&2
        return 2
    fi
    local default_url host=postgres
    default_url=$(batch_env BATCH_DB_URL)
    if [[ "$default_url" != jdbc:postgresql://postgres:5432/* || "$default_url" == */"$BATCH_BENCH_DB" ]]; then
        printf 'Benchmark database must use the local Compose PostgreSQL and differ from the application database.\n' >&2
        return 2
    fi
    if [[ -n ${BATCH_BENCH_PG_CONTAINER:-} ]]; then
        if [[ ! "$BATCH_BENCH_PG_CONTAINER" =~ ^cookbook-bench-pg-[a-z0-9-]+$ ]]; then
            printf 'Use a disposable local cookbook-bench-pg-* container.\n' >&2
            return 2
        fi
        host=$BATCH_BENCH_PG_CONTAINER
    fi
    if [[ "${BATCH_BENCH_REUSE_SEED:-0}" != 1 ]]; then
        benchmark_pg_exec sh -ec 'exec createdb -U "$POSTGRES_USER" "$1"' sh "$BATCH_BENCH_DB"
    fi
    benchmark_db_override=(-e "BATCH_DB_URL=jdbc:postgresql://$host:5432/$BATCH_BENCH_DB")
}

batch_database_counters() {
    batch_psql -Atc "SELECT json_build_object('timestamp', clock_timestamp(),
        'connections', numbackends, 'commit', xact_commit, 'rollback', xact_rollback, 'blocks_read', blks_read,
        'blocks_hit', blks_hit, 'temp_bytes', temp_bytes, 'deadlocks', deadlocks)
        FROM pg_stat_database WHERE datname=current_database()"
}

batch_step_metrics() {
    local destination=$1 run=$2
    batch_psql -A -F $'\t' -v run="$run" > "$destination" <<'SQL'
SELECT s.step_name,
       EXTRACT(EPOCH FROM s.end_time - s.start_time) AS step_seconds,
       s.read_count, s.write_count, s.commit_count, s.rollback_count, s.status
FROM batch_step_execution s
JOIN batch_job_execution_params p USING (job_execution_id)
WHERE p.parameter_name = 'runId' AND p.parameter_value = :'run'
ORDER BY s.step_execution_id;
SQL
}

batch_artifacts() {
    local destination=$1 run=$2
    batch_psql -At -v run="$run" > "$destination" <<'SQL'
SELECT COALESCE(json_agg(a ORDER BY artifact_id, destination), '[]')
FROM (
    SELECT artifact_id, destination, bucket, object_key, row_count, size_bytes, sha256, version_id, state
    FROM batch_artifact
    WHERE run_id = :'run' AND artifact_id NOT LIKE '%/manifest'
) a;
SQL
}
