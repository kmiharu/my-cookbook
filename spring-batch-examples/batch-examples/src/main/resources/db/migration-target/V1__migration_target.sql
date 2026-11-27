CREATE TABLE customer (
    id bigint PRIMARY KEY,
    name text NOT NULL,
    email text,
    status text NOT NULL,
    updated_at timestamptz NOT NULL,
    version bigint NOT NULL
);

CREATE TABLE batch_migration_progress (
    run_id text NOT NULL,
    customer_id bigint NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
    PRIMARY KEY (run_id, customer_id)
);
