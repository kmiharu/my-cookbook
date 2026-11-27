#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/local-common.sh"

"${compose[@]}" up -d --wait --wait-timeout 90 postgres postgres-target s3 dynamodb awscli
await_local local_aws s3api list-buckets
await_local local_aws dynamodb list-tables

for var in BATCH_INPUT_BUCKET BATCH_INTERNAL_BUCKET BATCH_PARTNER_BUCKET; do
    bucket=$(batch_env "$var")
    local_aws s3api head-bucket --bucket "$bucket" >/dev/null
    local_aws s3api put-bucket-versioning --bucket "$bucket" --versioning-configuration Status=Enabled
    local_aws s3api get-bucket-versioning --bucket "$bucket" --output json | jq -e '.Status == "Enabled"' >/dev/null
done

business_table=$(batch_env BATCH_DYNAMO_TABLE)
operations_table=$(batch_env BATCH_DYNAMO_OPERATIONS_TABLE)
require_table() {
    local table=$1 describe
    shift
    if ! describe=$(local_aws dynamodb describe-table --table-name "$table" 2>&1); then
        case "$describe" in
            *ResourceNotFoundException*)
                if ! describe=$(local_aws dynamodb create-table --table-name "$table" --billing-mode PAY_PER_REQUEST "$@" 2>&1); then
                    case "$describe" in
                        *ResourceInUseException*) ;; # A concurrent setup created it. Describe and check the schema below.
                        *) printf '%s\n' "$describe" >&2; return 1 ;;
                    esac
                fi
                ;;
            *) printf '%s\n' "$describe" >&2; return 1 ;;
        esac
    fi
    local_aws dynamodb wait table-exists --table-name "$table"
    local_aws dynamodb describe-table --table-name "$table"
}

require_table "$business_table" \
    --attribute-definitions AttributeName=pk,AttributeType=S AttributeName=sk,AttributeType=S \
        AttributeName=gsi_pk,AttributeType=S AttributeName=gsi_sk,AttributeType=S \
    --key-schema AttributeName=pk,KeyType=HASH AttributeName=sk,KeyType=RANGE \
    --global-secondary-indexes '[{"IndexName":"by-status","KeySchema":[{"AttributeName":"gsi_pk","KeyType":"HASH"},{"AttributeName":"gsi_sk","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}}]' |
    jq -e '.Table | .KeySchema == [{"AttributeName":"pk","KeyType":"HASH"},{"AttributeName":"sk","KeyType":"RANGE"}]
        and (.AttributeDefinitions | map(select(.AttributeType == "S") | .AttributeName) | sort) == ["gsi_pk","gsi_sk","pk","sk"]
        and (.GlobalSecondaryIndexes | length) == 1
        and (.GlobalSecondaryIndexes[0] | .IndexName == "by-status" and .Projection.ProjectionType == "ALL"
            and .KeySchema == [{"AttributeName":"gsi_pk","KeyType":"HASH"},{"AttributeName":"gsi_sk","KeyType":"RANGE"}])' >/dev/null
require_table "$operations_table" \
    --attribute-definitions AttributeName=operation_id,AttributeType=S \
    --key-schema AttributeName=operation_id,KeyType=HASH |
    jq -e '.Table | .KeySchema == [{"AttributeName":"operation_id","KeyType":"HASH"}]
        and .AttributeDefinitions == [{"AttributeName":"operation_id","AttributeType":"S"}]' >/dev/null
printf 'Local PostgreSQL, S3 buckets/versioning, DynamoDB tables and GSI are ready.\n'
