#!/usr/bin/env bash
set -euo pipefail

checks_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
sample_dir="$checks_dir/../../App/Samples/Fixtures/Booking"
output_dir="$(mktemp -d)"
trap 'rm -rf -- "$output_dir"' EXIT

"${SWIFTC:-swiftc}" -swift-version 6 "$sample_dir/BookingModel.swift" "$sample_dir/../Support/FixtureDisk.swift" "$checks_dir/main.swift" -o "$output_dir/verify-booking"
"$output_dir/verify-booking"
