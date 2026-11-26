COPY (
    SELECT id, created_on, value, corrected
    FROM cookbook.customers
    WHERE created_on >= :'start_date'::date
      AND created_on < :'end_date'::date
    ORDER BY id
    LIMIT :batch_size OFFSET :batch_offset
) TO STDOUT WITH (FORMAT CSV, HEADER);
