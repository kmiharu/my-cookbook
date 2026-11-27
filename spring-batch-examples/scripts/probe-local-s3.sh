#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/local-common.sh"

bucket=$(batch_env BATCH_INPUT_BUCKET)
key="probes/multipart-$(date -u +%Y%m%dT%H%M%S)-$$"
probe_dir=$("${compose[@]}" exec -T awscli mktemp -d)
upload_id=
old_version=
new_version=
cleanup() {
    if [[ -n "$upload_id" ]]; then
        local_aws s3api abort-multipart-upload --bucket "$bucket" --key "$key" --upload-id "$upload_id" >/dev/null || true
    fi
    for version in "$old_version" "$new_version"; do
        if [[ -n "$version" ]]; then
            local_aws s3api delete-object --bucket "$bucket" --key "$key" --version-id "$version" >/dev/null || true
        fi
    done
    "${compose[@]}" exec -T awscli rm -rf -- "$probe_dir"
}
trap cleanup EXIT

"${compose[@]}" exec -T awscli sh -ec '
    dd if=/dev/zero of="$1/part1" bs=1M count=5 status=none
    printf "local multipart probe\n" > "$1/part2"
' sh "$probe_dir"
expected_hash=$("${compose[@]}" exec -T awscli sh -ec 'cat "$1/part1" "$1/part2" | sha256sum | cut -d " " -f 1' sh "$probe_dir")
create_upload() {
    local_aws s3api create-multipart-upload --bucket "$bucket" --key "$key" \
        --metadata fixture=local-probe --query UploadId --output text
}
verify_upload_list() {
    local predicate=$1
    local_aws s3api list-multipart-uploads --bucket "$bucket" --prefix "$key" --output json |
        jq -e --arg id "$upload_id" "$predicate" >/dev/null
}

upload_id=$(create_upload)
verify_upload_list 'any(.Uploads[]?; .UploadId == $id)'
etag1=$(local_aws s3api upload-part --bucket "$bucket" --key "$key" --upload-id "$upload_id" \
    --part-number 1 --body "$probe_dir/part1" --query ETag --output text)
etag2=$(local_aws s3api upload-part --bucket "$bucket" --key "$key" --upload-id "$upload_id" \
    --part-number 2 --body "$probe_dir/part2" --query ETag --output text)
parts=$(jq -cn --arg first "$etag1" --arg last "$etag2" '{Parts:[{PartNumber:1,ETag:$first},{PartNumber:2,ETag:$last}]}')
old_version=$(local_aws s3api complete-multipart-upload --bucket "$bucket" --key "$key" --upload-id "$upload_id" \
    --if-none-match '*' --multipart-upload "$parts" --query VersionId --output text)
verify_upload_list 'all(.Uploads[]?; .UploadId != $id)'
upload_id=
[[ -n "$old_version" && "$old_version" != None ]]
head=$(local_aws s3api head-object --bucket "$bucket" --key "$key" --output json)
jq -e --arg version "$old_version" '.Metadata.fixture == "local-probe" and .VersionId == $version and .ContentLength == 5242902' <<< "$head" >/dev/null
etag=$(jq -er .ETag <<< "$head")
local_aws s3api get-object --bucket "$bucket" --key "$key" --if-match "$etag" "$probe_dir/get" >/dev/null
actual_hash=$("${compose[@]}" exec -T awscli sha256sum "$probe_dir/get" | cut -d ' ' -f 1)
[[ "$expected_hash" == "$actual_hash" ]]

new_version=$(local_aws s3api put-object --bucket "$bucket" --key "$key" --body "$probe_dir/part2" --query VersionId --output text)
[[ -n "$new_version" && "$new_version" != None && "$new_version" != "$old_version" ]]
if output=$(local_aws s3api get-object --bucket "$bucket" --key "$key" --if-match "$etag" "$probe_dir/latest" 2>&1); then
    printf 'An overwritten object still matched the previous ETag.\n' >&2
    exit 1
fi
case "$output" in *PreconditionFailed*|*412*) ;; *) printf '%s\n' "$output" >&2; exit 1 ;; esac
local_aws s3api get-object --bucket "$bucket" --key "$key" --version-id "$old_version" "$probe_dir/old" >/dev/null
old_hash=$("${compose[@]}" exec -T awscli sha256sum "$probe_dir/old" | cut -d ' ' -f 1)
[[ "$old_hash" == "$expected_hash" ]]

upload_id=$(create_upload)
verify_upload_list 'any(.Uploads[]?; .UploadId == $id)'
single_etag=$(local_aws s3api upload-part --bucket "$bucket" --key "$key" --upload-id "$upload_id" \
    --part-number 1 --body "$probe_dir/part2" --query ETag --output text)
single_part=$(jq -cn --arg tag "$single_etag" '{Parts:[{PartNumber:1,ETag:$tag}]}')
if output=$(local_aws s3api complete-multipart-upload --bucket "$bucket" --key "$key" --upload-id "$upload_id" \
    --if-none-match '*' --multipart-upload "$single_part" 2>&1); then
    printf 'Conditional Complete overwrote a versioned object.\n' >&2
    exit 1
fi
case "$output" in *PreconditionFailed*|*412*) ;; *) printf '%s\n' "$output" >&2; exit 1 ;; esac
local_aws s3api abort-multipart-upload --bucket "$bucket" --key "$key" --upload-id "$upload_id"
verify_upload_list 'all(.Uploads[]?; .UploadId != $id)'
upload_id=
printf 'S3 multipart create/upload/complete/abort/list, HEAD/GET, ETag mismatch and versioned GET passed.\n'
