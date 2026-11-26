BEGIN ISOLATION LEVEL REPEATABLE READ;

CREATE TEMP TABLE patch_input (
    id bigint NOT NULL,
    new_value text NOT NULL
) ON COMMIT DROP;

\copy pg_temp.patch_input (id, new_value) FROM 'patch_input.csv' WITH (FORMAT CSV, HEADER MATCH, FORCE_NOT_NULL (new_value))

CREATE TEMP TABLE patch_input_errors ON COMMIT DROP AS
SELECT '重複ID' AS reason, id
FROM pg_temp.patch_input
GROUP BY id
HAVING count(*) > 1
UNION ALL
SELECT DISTINCT 'DBに存在しないID', i.id
FROM pg_temp.patch_input AS i
LEFT JOIN cookbook.customers AS c ON c.id = i.id
WHERE c.id IS NULL;

SELECT EXISTS (SELECT 1 FROM pg_temp.patch_input_errors) AS invalid_input
\gset

\if :invalid_input
SELECT reason AS "区分", id FROM pg_temp.patch_input_errors ORDER BY id, reason;
DO $$ BEGIN
    RAISE EXCEPTION USING ERRCODE = 'P0701', MESSAGE = 'CSVの入力IDが無効です';
END $$;
\endif

-- 確認時点の値を、反映時にも同じ確認IDで取り出せるように保存する。
INSERT INTO cookbook.csv_patch_reviews (review_id) VALUES (:'review_id'::uuid);

INSERT INTO cookbook.csv_patch_review_rows (review_id, id, old_value, new_value)
SELECT :'review_id'::uuid, i.id, c.value, i.new_value
FROM pg_temp.patch_input AS i
JOIN cookbook.customers AS c ON c.id = i.id;

SELECT (SELECT count(*) FROM pg_temp.patch_input) AS "入力件数",
       count(*) AS "DBに存在する件数",
       count(*) FILTER (WHERE old_value IS DISTINCT FROM new_value) AS "値が変わる件数"
FROM cookbook.csv_patch_review_rows
WHERE review_id = :'review_id'::uuid;

SELECT id, old_value AS "変更前", new_value AS "変更後"
FROM cookbook.csv_patch_review_rows
WHERE review_id = :'review_id'::uuid
  AND old_value IS DISTINCT FROM new_value
ORDER BY id;

COMMIT;
\echo 確認ID = :review_id
