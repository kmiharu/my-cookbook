#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/local-common.sh"
if (($# == 0)); then
    printf 'Usage: %s {s3|s3api|dynamodb} [arguments ...]\n' "$0" >&2
    exit 2
fi
local_aws "$@"
