#!/usr/bin/env bash
set -euo pipefail

sample=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$sample"
action=${1:-}
mode=${2:-dynamodb}
case "$mode" in
    dynamodb|aurora|hybrid) ;;
    *) echo "Unknown database mode: $mode" >&2; exit 2 ;;
esac
if [[ $# -ge 2 ]]; then shift 2; elif [[ $# == 1 ]]; then shift; fi

export DATABASE_TYPE=$mode
export COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME:-products-sample-$mode}
case "$action" in
    e2e|sam-test)
        export COMPOSE_PROJECT_NAME="products-${action}-${mode}-$$"
        export DYNAMODB_PORT='' POSTGRES_PORT='' API_PORT=''
        ;;
esac

compose() {
    docker compose -f "$sample/docker/compose.yml" --profile "$mode" "$@"
}

bound_port() {
    compose port "$1" "$2" | awk -F: 'NR == 1 { print $NF }'
}

wait_port() {
    python3 - "$1" <<'PY'
import socket
import sys
import time

port = int(sys.argv[1])
deadline = time.monotonic() + 45
while time.monotonic() < deadline:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.5):
            break
    except OSError:
        time.sleep(0.2)
else:
    raise SystemExit(f"Port {port} did not open")
PY
}

java_command() {
    compose run --rm --no-deps --entrypoint java api -cp "/opt/api/lib/*" "$@"
}

sync_maintenance() (
    local operation=$1 running service
    local -a paused=()
    [[ $mode == hybrid && ( $operation == backfill || $operation == rebuild ) ]]
    running=$(compose ps --status running --services)
    for service in api worker; do
        if [[ $'\n'$running$'\n' == *$'\n'"$service"$'\n'* ]]; then
            paused+=("$service")
        fi
    done
    if (( ${#paused[@]} > 0 )); then
        trap 'compose start "${paused[@]}"' EXIT
        compose stop "${paused[@]}"
    fi
    compose run --rm --no-deps worker "$operation"
)

infra() {
    scripts/gradle.sh --quiet installDist
    if [[ $mode == aurora ]]; then
        compose build api
    else
        compose build api dynamodb
    fi
    case "$mode" in
        dynamodb) compose --profile '*' stop postgres worker ;;
        aurora) compose --profile '*' stop dynamodb worker ;;
    esac
    if [[ $mode != aurora ]]; then
        compose up -d dynamodb
        wait_port "$(bound_port dynamodb 8000)"
        java_command cookbook.api.db.DynamoAdmin init
    fi
    if [[ $mode != dynamodb ]]; then
        compose up -d --wait --wait-timeout 50 postgres
        java_command cookbook.api.db.PostgresAdmin migrate
    fi
    if [[ $mode == hybrid && ${START_WORKER:-1} == 1 ]]; then
        compose up -d worker
    fi
}

api_up() {
    infra
    compose up -d api
    api_port=$(bound_port api 8080)
    wait_port "$api_port"
    local deadline=$((SECONDS + 40))
    until curl -fsS --noproxy '*' --connect-timeout 1 --max-time 2 "http://127.0.0.1:$api_port/health" >/dev/null 2>&1; do
        if (( SECONDS >= deadline )); then
            compose logs api >&2
            return 1
        fi
        sleep 0.2
    done
    printf 'API http://127.0.0.1:%s\n' "$api_port"
}

setup_sam() {
    sam_bin=$(scripts/tools.sh install sam)
    sam_image='public.ecr.aws/lambda/java@sha256:d8656dee5c3d4be9bf99d41888848fd855d8b8ff8aeef0472b6567d0472a5190'
    if ! docker image inspect "$sam_image" >/dev/null 2>&1; then
        docker pull --platform linux/amd64 "$sam_image" >&2
    fi
    scripts/gradle.sh --quiet lambdaZip
    printf '{"Parameters":{"DATABASE_TYPE":"%s"}}\n' "$mode" > "$scratch/sam-env.json"
}

sam_run() {
    local subcommand=$1 template=$2
    shift 2
    unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_SESSION_TOKEN AWS_SECURITY_TOKEN AWS_WEB_IDENTITY_TOKEN_FILE \
        AWS_ROLE_ARN AWS_CONTAINER_CREDENTIALS_RELATIVE_URI AWS_CONTAINER_CREDENTIALS_FULL_URI
    export AWS_ACCESS_KEY_ID=local AWS_SECRET_ACCESS_KEY=local AWS_EC2_METADATA_DISABLED=true
    export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_DEFAULT_REGION=us-east-1
    export SAM_CLI_TELEMETRY=0
    exec "$sam_bin" local "$subcommand" --template "$sample/sam/$template" --region us-east-1 \
        --docker-network "${COMPOSE_PROJECT_NAME}_default" --env-vars "$scratch/sam-env.json" \
        --invoke-image "$sam_image" --skip-pull-image "$@"
}

test_cleanup() {
    local result=$?
    trap - EXIT
    if [[ -n ${sam_pid:-} ]]; then
        kill "$sam_pid" 2>/dev/null || true
        wait "$sam_pid" 2>/dev/null || true
    fi
    if (( result != 0 )); then
        local log_dir="$sample/.local/verification/$COMPOSE_PROJECT_NAME"
        mkdir -p "$log_dir" || true
        if [[ -f $scratch/sam.log ]]; then
            cp "$scratch/sam.log" "$log_dir/sam.log" || true
            tail -100 "$scratch/sam.log" >&2
        fi
        compose logs --no-color > "$log_dir/compose.log" 2>&1 || true
        if [[ -f $log_dir/compose.log ]]; then tail -100 "$log_dir/compose.log" >&2; fi
        printf 'Failure logs: %s\n' "$log_dir" >&2
    fi
    # The emulator may leave an invocation container after an interrupted request.
    local container
    while IFS= read -r container; do
        [[ -n $container ]] || continue
        docker stop --time 5 "$container" >/dev/null 2>&1 || true
        docker rm "$container" >/dev/null 2>&1 || true
    done < <(docker ps -aq --filter "network=${COMPOSE_PROJECT_NAME}_default" --filter label=sam.cli.container.type=lambda)
    compose down --volumes --remove-orphans --rmi local >&2 || true
    docker image rm "${COMPOSE_PROJECT_NAME}-products-api" >/dev/null 2>&1 || true
    rm -rf -- "$scratch"
    exit "$result"
}

case "$action" in
    up) api_up ;;
    infra) infra ;;
    down)
        if [[ ${CLEAN_VOLUMES:-0} == 1 ]]; then set -- "$@" --volumes; fi
        compose --profile '*' down --remove-orphans "$@"
        ;;
    compose) compose "$@" ;;
    exec) java_command "$@" ;;
    sync) compose run --rm --no-deps worker "$@" ;;
    sync-maintenance) sync_maintenance "$@" ;;
    e2e)
        scratch=$(mktemp -d)
        trap test_cleanup EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        api_up
        python3 tests/e2e.py "http://127.0.0.1:$api_port" "$mode"
        ;;
    sam-start)
        scratch=$(mktemp -d)
        trap 'rm -rf -- "$scratch"' EXIT
        infra
        setup_sam
        case ${SAM_API_TYPE:-http} in
            http) template=template.yml ;;
            rest) template=rest-template.yml ;;
            *) echo 'SAM_API_TYPE must be http or rest' >&2; exit 2 ;;
        esac
        (sam_run start-api "$template" --host 127.0.0.1 --port "${SAM_PORT:-3000}" --warm-containers LAZY)
        ;;
    sam-test)
        scratch=$(mktemp -d)
        trap test_cleanup EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        infra
        setup_sam
        sam_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
        (sam_run start-api template.yml --host 127.0.0.1 --port "$sam_port" --warm-containers LAZY) > "$scratch/sam.log" 2>&1 &
        sam_pid=$!
        wait_port "$sam_port"
        curl -fsS --noproxy '*' --max-time 150 --retry 3 --retry-max-time 240 \
            "http://127.0.0.1:$sam_port/products?limit=1" >/dev/null
        HTTP_REQUEST_TIMEOUT=120 python3 tests/e2e.py "http://127.0.0.1:$sam_port" "$mode"
        (sam_run invoke template.yml ApiFunction -e sam/events/create-v2.json) > "$scratch/create.json"
        python3 scripts/check-sam.py created "$scratch/create.json" > "$scratch/id"
        deadline=$((SECONDS + 40))
        until (sam_run invoke template.yml ApiFunction -e sam/events/list-v2.json) > "$scratch/list.json" &&
            python3 scripts/check-sam.py listed "$scratch/list.json" "$(cat "$scratch/id")"; do
            if (( SECONDS >= deadline )); then exit 1; fi
            sleep 0.25
        done
        (sam_run invoke rest-template.yml RestFunction -e sam/events/list-v1.json) > "$scratch/list-v1.json"
        python3 scripts/check-sam.py listed "$scratch/list-v1.json" "$(cat "$scratch/id")"
        ;;
    sam-invoke)
        function=${1:?function name required}
        event=${2:?event file required}
        scratch=$(mktemp -d)
        trap 'rm -rf -- "$scratch"' EXIT
        setup_sam
        template=template.yml
        if [[ $function == RestFunction ]]; then template=rest-template.yml; fi
        (sam_run invoke "$template" "$function" -e "$event")
        ;;
    *)
        printf '%s\n' "Usage: $0 {up|infra|down|e2e|sam-start|sam-test|sam-invoke|exec|sync|sync-maintenance|compose} [dynamodb|aurora|hybrid] [args...]" >&2
        exit 2
        ;;
esac
