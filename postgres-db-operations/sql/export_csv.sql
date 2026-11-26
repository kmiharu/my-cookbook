\copy (SELECT id, created_on, value, corrected FROM cookbook.customers ORDER BY id) TO 'customers.csv' WITH (FORMAT CSV, HEADER, ENCODING 'UTF8')
