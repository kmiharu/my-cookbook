\set ON_ERROR_STOP on
\encoding UTF8

BEGIN;
DROP SCHEMA IF EXISTS cookbook CASCADE;
CREATE SCHEMA cookbook;

CREATE TABLE cookbook.customers (
    id bigint PRIMARY KEY,
    created_on date NOT NULL,
    value text NOT NULL,
    corrected boolean NOT NULL DEFAULT false,
    payload jsonb NOT NULL
);

WITH practice_data AS (
    SELECT id,
           CASE WHEN id = 2501 THEN DATE '2026-02-01'
                ELSE DATE '2026-01-01'
           END AS created_on,
           CASE id
               WHEN 1 THEN '東京都'
               WHEN 2 THEN '鳥取県'
               WHEN 3 THEN '髙橋'
               WHEN 4 THEN '半角ｶﾅ'
               WHEN 42 THEN E'東京都, "髙橋"\n鳥取県 半角ｶﾅ 🍣'
               ELSE '顧客 ' || id
           END AS value
    FROM generate_series(1, 2501) AS ids(id)
)
INSERT INTO cookbook.customers (id, created_on, value, payload)
SELECT id, created_on, value, jsonb_build_object('id', id, 'value', value)
FROM practice_data;

\ir setup_csv_patch.sql
\ir setup_patch.sql
COMMIT;
