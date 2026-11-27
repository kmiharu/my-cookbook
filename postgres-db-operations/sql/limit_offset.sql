SELECT id
FROM cookbook.customers
ORDER BY id LIMIT :batch_size OFFSET :batch_offset;
