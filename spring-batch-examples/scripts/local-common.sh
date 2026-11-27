#!/usr/bin/env bash

sample_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compose=(docker compose --project-directory "$sample_dir" -f "$sample_dir/compose.yaml" --profile tools)

local_aws() {
    local group=$1 endpoint
    shift
    case "$group" in
        s3|s3api) endpoint=http://s3:8333 ;;
        dynamodb) endpoint=http://dynamodb:8000 ;;
        *) printf 'Unsupported local AWS command group: %s\n' "$group" >&2; return 2 ;;
    esac
    "${compose[@]}" exec -T awscli aws --no-cli-pager --cli-connect-timeout 3 --cli-read-timeout 60 \
        --endpoint-url "$endpoint" "$group" "$@"
}

batch_env() {
    "${compose[@]}" --profile batch config --format json | jq -er --arg key "$1" '.services.batch.environment[$key]'
}

await_local() {
    local deadline=$((SECONDS + 60))
    local output
    while ! output=$("$@" 2>&1); do
        if ((SECONDS >= deadline)); then
            printf 'Local service did not become ready: %s\n%s\n' "$*" "$output" >&2
            return 1
        fi
        sleep 2
    done
}

local_batch() {
    "${compose[@]}" --profile batch run --rm -T --no-deps batch "$@"
}

local_psql() {
    "${compose[@]}" exec -T postgres sh -ec 'exec psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" "$@"' sh "$@"
}

local_image() {
    "${compose[@]}" --profile batch config --format json | jq -er '.services.batch.image'
}

build_local_image() {
    if [[ ${BATCH_USE_EXISTING_IMAGE:-0} == 1 ]]; then
        docker image inspect -f 'Using image {{.Id}}' "$(local_image)"
    else
        "${compose[@]}" --profile batch build batch
    fi
}
