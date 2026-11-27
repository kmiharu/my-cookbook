#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$0")/local-common.sh"

business=$(batch_env BATCH_DYNAMO_TABLE)
operations=$(batch_env BATCH_DYNAMO_OPERATIONS_TABLE)
pk="probe-$(date -u +%Y%m%dT%H%M%S)-$$"
key() { jq -cn --arg pk "$pk" --arg sk "$1" '{pk:{S:$pk}, sk:{S:$sk}}'; }
operation_key=$(jq -cn --arg op "$pk" '{operation_id:{S:$op}}')
cleanup() {
    for sk in 001 002; do
        local_aws dynamodb delete-item --table-name "$business" --key "$(key "$sk")" >/dev/null || true
    done
    local_aws dynamodb delete-item --table-name "$operations" --key "$operation_key" >/dev/null || true
}
trap cleanup EXIT

for sk in 001 002; do
    item=$(jq -cn --argjson key "$(key "$sk")" --arg status "$pk" --arg gsi_sk "${#pk}:$pk$sk" --arg sk "$sk" \
        '$key + {gsi_pk:{S:$status}, gsi_sk:{S:$gsi_sk}, status:{S:$status}, memo:{S:$sk}, version:{N:"1"}, balance:{N:"1.25"}}')
    local_aws dynamodb put-item --table-name "$business" --item "$item" --condition-expression 'attribute_not_exists(pk)'
done
values=$(jq -cn --arg pk "$pk" '{":p":{S:$pk}, ":later":{S:"002"}}')
first=$(local_aws dynamodb query --table-name "$business" --no-paginate --limit 1 \
    --key-condition-expression 'pk = :p' --filter-expression 'memo = :later' --expression-attribute-values "$values")
jq -e '.Count == 0 and .ScannedCount == 1 and (.LastEvaluatedKey | has("pk") and has("sk"))' <<< "$first" >/dev/null
second=$(local_aws dynamodb query --table-name "$business" --no-paginate --limit 1 \
    --key-condition-expression 'pk = :p' --filter-expression 'memo = :later' --expression-attribute-values "$values" \
    --exclusive-start-key "$(jq -c .LastEvaluatedKey <<< "$first")")
jq -e '.Count == 1 and .Items[0].sk.S == "002"' <<< "$second" >/dev/null

gsi_values=$(jq -cn --arg pk "$pk" '{":p":{S:$pk}}')
local_aws dynamodb query --table-name "$business" --index-name by-status --key-condition-expression 'gsi_pk = :p' \
    --expression-attribute-values "$gsi_values" | jq -e '.Count == 2' >/dev/null
local_aws dynamodb scan --table-name "$business" --filter-expression 'pk = :p' \
    --expression-attribute-values "$gsi_values" | jq -e '.Count == 2' >/dev/null

transaction=$(jq -cn --arg business "$business" --arg operations "$operations" --argjson key "$(key 001)" \
    --argjson operation_key "$operation_key" \
    '[{Update:{TableName:$business,Key:$key,UpdateExpression:"SET #v = :next ADD balance :delta",ConditionExpression:"#v = :old",
       ExpressionAttributeNames:{"#v":"version"},ExpressionAttributeValues:{":old":{N:"1"},":next":{N:"2"},":delta":{N:"2.25"}}}},
      {Put:{TableName:$operations,Item:($operation_key+{payload_hash:{S:"probe-hash"}}),ConditionExpression:"attribute_not_exists(operation_id)"}}]')
local_aws dynamodb transact-write-items --transact-items "$transaction"
if output=$(local_aws dynamodb transact-write-items --transact-items "$transaction" 2>&1); then
    printf 'DynamoDB accepted a duplicate conditional update.\n' >&2
    exit 1
fi
case "$output" in *TransactionCanceledException*) ;; *) printf '%s\n' "$output" >&2; exit 1 ;; esac
local_aws dynamodb get-item --table-name "$business" --key "$(key 001)" --consistent-read |
    jq -e '.Item.version.N == "2" and (.Item.balance.N | tonumber) == 3.5' >/dev/null
local_aws dynamodb get-item --table-name "$operations" --key "$operation_key" --consistent-read |
    jq -e '.Item.payload_hash.S == "probe-hash"' >/dev/null
printf 'DynamoDB Query/Scan, empty-page continuation, GSI and conditional transactional deduplication passed.\n'
