#!/usr/bin/env bash
set -euo pipefail

if (( $# < 3 )); then
  printf 'Usage: %s TERRAFORM_ROOT job=JOB runId=RUN [key=value ...]\n' "$0" >&2
  exit 64
fi

terraform_root=$1
shift
job=''
run_id=''
for argument in "$@"; do
  case "$argument" in
    job=*)
      [[ -z $job && -n ${argument#job=} ]] || { printf 'Specify one nonempty job.\n' >&2; exit 64; }
      job=${argument#job=}
      ;;
    runId=*)
      [[ -z $run_id && -n ${argument#runId=} ]] || { printf 'Specify one nonempty runId.\n' >&2; exit 64; }
      run_id=${argument#runId=}
      ;;
    *=*) ;;
    *) printf 'Job arguments must use key=value.\n' >&2; exit 64 ;;
  esac
done
[[ -n $job && -n $run_id ]] || { printf 'Both job and runId are required.\n' >&2; exit 64; }

wait_seconds=${ECS_WAIT_SECONDS:-3600}
poll_seconds=${ECS_POLL_SECONDS:-5}
if ! [[ $wait_seconds =~ ^[1-9][0-9]{0,6}$ && $poll_seconds =~ ^[1-9][0-9]{0,3}$ ]]; then
  printf 'ECS_WAIT_SECONDS and ECS_POLL_SECONDS must be positive integers.\n' >&2
  exit 64
fi

cluster=$(terraform -chdir="$terraform_root" output -raw cluster)
definition=$(terraform -chdir="$terraform_root" output -raw task_definition)
network=$(terraform -chdir="$terraform_root" output -json network)
container_name=$(terraform -chdir="$terraform_root" output -raw container_name)
image_uri=$(terraform -chdir="$terraform_root" output -raw image_uri)
log_group=$(terraform -chdir="$terraform_root" output -raw log_group)
region=$(terraform -chdir="$terraform_root" output -raw region)
if [[ -z $definition || $definition == null || -z $image_uri || $image_uri == null ]]; then
  printf 'The Terraform root has no task definition with an image digest.\n' >&2
  exit 65
fi

read -r owner </proc/sys/kernel/random/uuid
command_json=$(jq -nc --args '$ARGS.positional' -- "$@")
request=$(jq -nc --arg cluster "$cluster" --arg definition "$definition" --arg name "$container_name" \
  --arg owner "$owner" --argjson network "$network" --argjson command "$command_json" '{
    cluster: $cluster,
    taskDefinition: $definition,
    launchType: "FARGATE",
    startedBy: $owner,
    clientToken: $owner,
    platformVersion: "1.4.0",
    count: 1,
    networkConfiguration: {awsvpcConfiguration: $network},
    overrides: {containerOverrides: [{name: $name, command: $command, environment: [{name: "BATCH_EXECUTION_OWNER", value: $owner}]}]}
  }')

aws_ecs=(aws --region "$region" --no-cli-pager --output json --cli-connect-timeout 5 --cli-read-timeout 15 ecs)
printf 'job=%q runId=%q taskDefinition=%s image=%s owner=%s\n' "$job" "$run_id" "$definition" "$image_uri" "$owner"
start=$("${aws_ecs[@]}" run-task --cli-input-json "$request")
if ! task_arn=$(jq -er 'select((.failures | type) == "array" and (.failures | length) == 0)
  | select((.tasks | length) == 1) | .tasks[0].taskArn | select(type == "string" and length > 0)' <<<"$start"); then
  printf 'RunTask failed to return one accepted task.\n' >&2
  jq -c '.failures // [] | map({arn, reason, detail})' <<<"$start" >&2
  exit 69
fi

printf 'task=%s logs=aws\ logs\ tail\ %s\ --region\ %s\ --log-stream-names\ job/%s/%s\n' \
  "$task_arn" "$log_group" "$region" "$container_name" "${task_arn##*/}"
deadline=$((SECONDS + wait_seconds))
while (( SECONDS < deadline )); do
  remaining=$((deadline - SECONDS))
  if observed=$(timeout "${remaining}s" "${aws_ecs[@]}" describe-tasks --cluster "$cluster" --tasks "$task_arn"); then
    task=$(jq -c --arg arn "$task_arn" '(.tasks // []) | map(select(.taskArn == $arn)) | first // empty' <<<"$observed")
    if [[ -n $task && $(jq -r '.lastStatus' <<<"$task") == STOPPED ]]; then
      jq -c --arg name "$container_name" '{
        taskArn, lastStatus, stopCode, stoppedReason, createdAt, pullStartedAt, pullStoppedAt, startedAt, stoppedAt,
        containers: [(.containers // [])[] | select(.name == $name) | {name, imageDigest, exitCode, reason}]
      }' <<<"$task"
      code=$(jq -er --arg name "$container_name" '[(.containers // [])[] | select(.name == $name)] |
        select(length == 1) | .[0].exitCode | select(type == "number" and . == floor and . >= 0 and . <= 255)' <<<"$task") || {
        printf 'Task stopped without a usable batch container exitCode.\n' >&2
        exit 70
      }
      stop_code=$(jq -r '.stopCode // ""' <<<"$task")
      stop_reason=$(jq -r '[(.stoppedReason // ""), ((.containers // [])[] | .reason // "")] | join(" ")' <<<"$task")
      if [[ $stop_code == TaskFailedToStart || ${stop_reason,,} == *outofmemory* || ${stop_reason,,} == *"out of memory"* ]]; then
        exit 70
      fi
      exit "$code"
    fi
    if ! jq -e 'all((.failures // [])[]; .reason == "MISSING")' <<<"$observed" >/dev/null; then
      jq -c '.failures' <<<"$observed" >&2
      exit 69
    fi
  fi
  remaining=$((deadline - SECONDS))
  if (( remaining > 0 )); then
    sleep "$((poll_seconds < remaining ? poll_seconds : remaining))"
  fi
done

printf 'Timed out waiting for STOPPED. Task ARN: %s\n' "$task_arn" >&2
exit 124
