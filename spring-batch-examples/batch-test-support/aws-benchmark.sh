#!/usr/bin/env bash
set -euo pipefail
support=$(cd -- "$(dirname -- "$0")" && pwd)
source "$support/../scripts/local-common.sh"
source "$support/measure.sh"
benchmark_aws "$@"
