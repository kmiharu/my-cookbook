#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
export PATH="$test_dir:$PATH"
export TEST_ECS_DIR=$test_dir
export ECS_POLL_SECONDS=1
export ECS_WAIT_SECONDS=3

cat > "$test_dir/terraform" <<'SH'
#!/usr/bin/env bash
set -eu
[[ $1 == -chdir=sample && $2 == output && $# == 4 ]]
case "$4" in
  cluster) printf 'test-cluster' ;;
  task_definition) printf 'arn:aws:ecs:us-east-1:111111111111:task-definition/test:42' ;;
  network) printf '{"subnets":["subnet-test"],"securityGroups":["sg-test"],"assignPublicIp":"DISABLED"}' ;;
  container_name) printf 'batch' ;;
  image_uri) printf 'example/cookbook@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ;;
  log_group) printf '/ecs/test' ;;
  region) printf 'us-east-1' ;;
  *) exit 99 ;;
esac
SH

cat > "$test_dir/aws" <<'SH'
#!/usr/bin/env bash
set -eu
arn=arn:aws:ecs:us-east-1:111111111111:task/test-cluster/test-task
for argument in "$@"; do
  if [[ $argument == run-task || $argument == describe-tasks ]]; then
    action=$argument
  fi
done
case "$action" in
  run-task)
    printf '%s' "${!#}" > "$TEST_ECS_DIR/request.json"
    if [[ $TEST_ECS_CASE == rejected ]]; then
      printf '{"tasks":[],"failures":[{"reason":"ACCESS_DENIED"}]}'
    else
      printf '{"tasks":[{"taskArn":"%s"}],"failures":[]}' "$arn"
    fi
    ;;
  describe-tasks)
    case "$TEST_ECS_CASE" in
      success|failed|missing|oom|start_failed)
        if [[ $TEST_ECS_CASE == success && ! -e $TEST_ECS_DIR/observed ]]; then
          touch "$TEST_ECS_DIR/observed"
          printf '{"tasks":[],"failures":[{"reason":"MISSING"}]}'
          exit 0
        fi
        case "$TEST_ECS_CASE" in
          success) batch='{"name":"batch","exitCode":0}' ;;
          failed) batch='{"name":"batch","exitCode":17}' ;;
          missing) batch='{"name":"batch"}' ;;
          oom) batch='{"name":"batch","reason":"OutOfMemoryError","exitCode":137}' ;;
          start_failed) batch='{"name":"batch","exitCode":0}' ;;
        esac
        stop_code=EssentialContainerExited
        if [[ $TEST_ECS_CASE == start_failed ]]; then
          stop_code=TaskFailedToStart
        fi
        printf '{"tasks":[{"taskArn":"%s","lastStatus":"STOPPED","stopCode":"%s","containers":[{"name":"other","exitCode":0},%s]}],"failures":[]}'           "$arn" "$stop_code" "$batch"
        ;;
      timeout) printf '{"tasks":[{"taskArn":"%s","lastStatus":"RUNNING"}],"failures":[]}' "$arn" ;;
      *) exit 98 ;;
    esac
    ;;
  *) exit 97 ;;
esac
SH
chmod +x "$test_dir/terraform" "$test_dir/aws"

verify_exit() {
  local scenario=$1 expected=$2 actual=0
  shift 2
  TEST_ECS_CASE=$scenario "$here/run-task.sh" sample "$@" >"$test_dir/output" 2>&1 || actual=$?
  if [[ $actual != "$expected" ]]; then
    cat "$test_dir/output" >&2
    printf '%s returned %s, expected %s\n' "$scenario" "$actual" "$expected" >&2
    exit 1
  fi
  printf 'PASS %s\n' "$scenario"
}

value=$'sql.status=日本語 "quoted" $(echo unchanged)\nnext line'
verify_exit success 0 job=CustomerExport runId=run-123 "$value"
jq -e --arg value "$value" '
  .cluster == "test-cluster" and .platformVersion == "1.4.0" and .count == 1 and
  .networkConfiguration.awsvpcConfiguration.assignPublicIp == "DISABLED" and
  .clientToken == .startedBy and (.startedBy | test("^[0-9a-f-]{36}$")) and
  .overrides.containerOverrides == [{name:"batch",command:["job=CustomerExport","runId=run-123",$value],environment:[{name:"BATCH_EXECUTION_OWNER",value:.startedBy}]}]
' "$test_dir/request.json" >/dev/null
grep -q 'taskDefinition=.*:42 image=.*@sha256:' "$test_dir/output"
grep -Fq '"lastStatus":"STOPPED"' "$test_dir/output"
verify_exit rejected 69 job=CustomerExport runId=r
verify_exit failed 17 job=CustomerExport runId=r
verify_exit missing 70 job=CustomerExport runId=r
verify_exit oom 70 job=CustomerExport runId=r
verify_exit start_failed 70 job=CustomerExport runId=r
ECS_WAIT_SECONDS=1 verify_exit timeout 124 job=CustomerExport runId=r
verify_exit duplicate 64 job=CustomerExport runId=r runId=another
