SELECT COUNT(*)
FROM cookbook.batch_patch_targets AS target
LEFT JOIN cookbook.customers AS customer ON customer.id = target.id
WHERE customer.corrected IS NOT TRUE;
