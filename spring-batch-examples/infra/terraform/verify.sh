#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
verification_dir=$(mktemp -d)
trap 'rm -rf -- "$verification_dir"' EXIT
export TF_IN_AUTOMATION=1
export TF_PLUGIN_CACHE_DIR=${TF_PLUGIN_CACHE_DIR:-"$verification_dir/plugins"}
mkdir -p "$TF_PLUGIN_CACHE_DIR"

terraform -chdir="$here" fmt -check -recursive
for root in bootstrap existing new partner-policy modules/task modules/data modules/network-db; do
  printf 'Checking %s\n' "$root"
  export TF_DATA_DIR="$verification_dir/${root//\//_}"
  terraform -chdir="$here/$root" init -backend=false -input=false -lockfile=readonly -no-color
  terraform -chdir="$here/$root" validate -no-color
  if [[ $root != modules/* ]]; then
    terraform -chdir="$here/$root" test -no-color
  fi
done
"$here/../ecs/test-run-task.sh"
