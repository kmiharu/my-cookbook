#!/usr/bin/env bash

dynamo_host_exec() {
    local config name value pg_port s3_port dynamo_port url
    config=$("${compose[@]}" --profile batch config --format json)
    for name in BATCH_DB_USER BATCH_DB_PASSWORD BATCH_INPUT_BUCKET BATCH_INTERNAL_BUCKET \
        BATCH_PARTNER_BUCKET BATCH_S3_ACCESS_KEY BATCH_S3_SECRET_KEY BATCH_DYNAMO_TABLE BATCH_DYNAMO_OPERATIONS_TABLE; do
        value=$(jq -er --arg key "$name" '.services.batch.environment[$key]' <<<"$config")
        export "$name=$value"
    done
    pg_port=$(jq -er '.services.postgres.ports[0].published' <<<"$config")
    s3_port=$(jq -er '.services.s3.ports[0].published' <<<"$config")
    dynamo_port=$(jq -er '.services.dynamodb.ports[0].published' <<<"$config")
    url=$(jq -er '.services.batch.environment.BATCH_DB_URL' <<<"$config")
    export BATCH_DB_URL=${url/postgres:5432/127.0.0.1:$pg_port}
    export SPRING_PROFILES_ACTIVE="${DDB_SCENARIO_PROFILE:-local}"
    export BATCH_S3_ENDPOINT="http://127.0.0.1:$s3_port" BATCH_DYNAMO_ENDPOINT="http://127.0.0.1:$dynamo_port"
    export BATCH_FAULT_PHASE="${DDB_SCENARIO_FAULT:-}" BATCH_FAULT_ACTION=fail
    exec "${JAVA_HOME:+$JAVA_HOME/bin/}java" -Xmx512m -Xlog:gc*:stdout:uptime,level,tags -jar "$BATCH_SCENARIO_HOST_JAR" "$@"
}

dynamo_batch() {
    if [[ -n ${BATCH_SCENARIO_HOST_JAR:-} ]]; then
        (dynamo_host_exec "$@")
    else
        "${compose[@]}" --profile batch run --rm -T --no-deps \
            -e "SPRING_PROFILES_ACTIVE=${DDB_SCENARIO_PROFILE:-local}" \
            -e "BATCH_FAULT_PHASE=${DDB_SCENARIO_FAULT:-}" -e BATCH_FAULT_ACTION=fail batch "$@"
    fi
}
