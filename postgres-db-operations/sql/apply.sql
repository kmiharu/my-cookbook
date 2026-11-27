BEGIN ISOLATION LEVEL REPEATABLE READ;

-- 同じ確認IDの反映を並行して実行しても二重に適用しない。
WITH selected_review AS (
    SELECT review_id
    FROM cookbook.csv_patch_reviews
    WHERE review_id = :'review_id'::uuid
    FOR UPDATE
)
SELECT EXISTS (SELECT 1 FROM selected_review) AS has_review
\gset

\if :has_review
\else
DO $$ BEGIN
    RAISE EXCEPTION USING ERRCODE = 'P0702', MESSAGE = '確認IDが存在しません';
END $$;
\endif

-- 確認後に対象行が消えたり、値が変わったりしていたら反映しない。
WITH locked_customers AS (
    SELECT c.id, c.value
    FROM cookbook.customers AS c
    JOIN cookbook.csv_patch_review_rows AS r ON r.id = c.id
    WHERE r.review_id = :'review_id'::uuid
    ORDER BY c.id
    FOR UPDATE OF c
)
SELECT EXISTS (
    SELECT 1
    FROM cookbook.csv_patch_review_rows AS r
    LEFT JOIN locked_customers AS c ON c.id = r.id
    WHERE r.review_id = :'review_id'::uuid
      AND (c.id IS NULL OR c.value IS DISTINCT FROM r.old_value)
) AS has_stale_row
\gset

\if :has_stale_row
DO $$ BEGIN
    RAISE EXCEPTION USING ERRCODE = 'P0703', MESSAGE = '確認後に対象行が変わりました';
END $$;
\endif

WITH updated AS (
    UPDATE cookbook.customers AS c
    SET value = r.new_value
    FROM cookbook.csv_patch_review_rows AS r
    WHERE r.review_id = :'review_id'::uuid
      AND c.id = r.id
      AND c.value IS DISTINCT FROM r.new_value
    RETURNING c.id
)
SELECT count(*) AS updated_count FROM updated
\gset

DELETE FROM cookbook.csv_patch_reviews WHERE review_id = :'review_id'::uuid;

COMMIT;
\echo :updated_count
