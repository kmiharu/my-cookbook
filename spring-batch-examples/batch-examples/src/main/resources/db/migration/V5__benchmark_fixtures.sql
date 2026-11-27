-- Bound database rows before the JDBC driver fetches them.
ALTER TABLE customer ADD CONSTRAINT customer_export_width
    CHECK (octet_length(name) <= 16384 AND octet_length(email) <= 4096 AND octet_length(status) <= 32);
ALTER TABLE membership ADD CONSTRAINT membership_export_width CHECK (octet_length(tier) <= 1024);

CREATE TABLE benchmark_index_before (
    run_id text NOT NULL,
    id bigint NOT NULL,
    status text NOT NULL,
    updated_at timestamptz NOT NULL
);
CREATE TABLE benchmark_index_after (LIKE benchmark_index_before INCLUDING CONSTRAINTS);
CREATE INDEX benchmark_status_period ON benchmark_index_after (run_id,status,updated_at,id);
CREATE TABLE benchmark_insert (
    run_id text NOT NULL,
    id bigint NOT NULL,
    name text NOT NULL,
    PRIMARY KEY (run_id,id)
);
