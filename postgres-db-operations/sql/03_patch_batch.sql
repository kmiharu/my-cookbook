-- OFFSETは更新で件数が変わらない固定一覧に適用する。
WITH batch AS (
    SELECT id
    FROM cookbook.batch_patch_targets
    ORDER BY id
    LIMIT :batch_size OFFSET :batch_offset
),
updated AS (
    UPDATE cookbook.customers AS customer
    SET value = '補正済み ' || customer.value,
        corrected = true
    FROM batch
    WHERE customer.id = batch.id
      AND customer.corrected IS NOT TRUE
    RETURNING customer.id
)
SELECT COUNT(*) FROM updated;
