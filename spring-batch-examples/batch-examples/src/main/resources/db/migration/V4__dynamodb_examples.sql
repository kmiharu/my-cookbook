CREATE TABLE dynamo_run (
    run_key text PRIMARY KEY,
    next_page text NOT NULL DEFAULT '',
    state text NOT NULL DEFAULT 'PREPARING' CHECK (state IN ('PREPARING', 'READY', 'APPLIED')),
    input_rows bigint,
    input_sha256 text
);

CREATE TABLE dynamo_work (
    run_key text NOT NULL REFERENCES dynamo_run(run_key) ON DELETE CASCADE,
    pk text COLLATE "C" NOT NULL,
    sk text COLLATE "C" NOT NULL,
    version bigint NOT NULL CHECK (version >= 0),
    status text,
    balance numeric,
    memo_state text NOT NULL,
    memo text,
    ordinal bigint,
    delivered boolean NOT NULL DEFAULT false,
    PRIMARY KEY (run_key, pk, sk),
    UNIQUE (run_key, ordinal)
);
CREATE INDEX dynamo_work_pending ON dynamo_work (run_key, pk, sk) WHERE NOT delivered;

CREATE TABLE dynamo_generation (
    pk text PRIMARY KEY,
    run_key text NOT NULL REFERENCES dynamo_run(run_key),
    delivered boolean NOT NULL DEFAULT false
);

CREATE TABLE dynamo_outbox (
    pk text NOT NULL,
    sk text NOT NULL,
    version bigint NOT NULL CHECK (version > 0),
    run_key text NOT NULL REFERENCES dynamo_run(run_key),
    status text NOT NULL,
    memo text NOT NULL,
    delivered boolean NOT NULL DEFAULT false,
    PRIMARY KEY (pk, sk, version)
);
CREATE INDEX dynamo_outbox_pending ON dynamo_outbox (run_key, pk, sk, version) WHERE NOT delivered;

CREATE TABLE dynamo_input_applied (
    job_name text NOT NULL,
    input_revision text NOT NULL,
    partition_key text NOT NULL,
    run_key text NOT NULL REFERENCES dynamo_run(run_key),
    PRIMARY KEY (job_name, input_revision, partition_key)
);
