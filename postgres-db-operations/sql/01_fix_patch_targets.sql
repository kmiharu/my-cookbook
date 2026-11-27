-- 初回は印と対象IDを同じ文で保存する。0件でも印が残る。
WITH new_run AS (
    INSERT INTO cookbook.batch_patch_run (singleton)
    VALUES (true)
    ON CONFLICT DO NOTHING
    RETURNING singleton
)
INSERT INTO cookbook.batch_patch_targets (id)
SELECT customer.id
FROM cookbook.customers AS customer
CROSS JOIN new_run
WHERE customer.corrected IS NOT TRUE;
