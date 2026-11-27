SELECT COUNT(*)
FROM cookbook.customers
WHERE created_on >= :'start_date'::date
  AND created_on < :'end_date'::date;
