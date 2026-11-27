CREATE TABLE customer (
    id bigint PRIMARY KEY,
    name text NOT NULL,
    email text,
    status text NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    version bigint NOT NULL DEFAULT 0
);
CREATE INDEX customer_export_period ON customer (updated_at, id);
CREATE INDEX customer_export_status_period ON customer (status, updated_at, id);

CREATE TABLE membership (
    customer_id bigint NOT NULL REFERENCES customer(id) ON DELETE CASCADE,
    member_id bigint NOT NULL CHECK (member_id > 0),
    tier text NOT NULL,
    PRIMARY KEY (customer_id, member_id)
);

CREATE TABLE batch_run (
    job_name text NOT NULL,
    run_id text NOT NULL,
    state text NOT NULL,
    settings text NOT NULL,
    owner text NOT NULL,
    owner_location text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (job_name, run_id)
);

CREATE TABLE batch_input (
    job_name text NOT NULL,
    run_id text NOT NULL,
    file_index integer NOT NULL,
    bucket text NOT NULL,
    object_key text NOT NULL,
    version_id text,
    etag text NOT NULL,
    size_bytes bigint NOT NULL,
    PRIMARY KEY (job_name, run_id, file_index),
    FOREIGN KEY (job_name, run_id) REFERENCES batch_run (job_name, run_id)
);
CREATE TABLE batch_input_work (
    job_name text NOT NULL,
    run_id text NOT NULL,
    file_index integer NOT NULL,
    ordinal bigint NOT NULL,
    customer_id bigint NOT NULL,
    name text,
    email text,
    status text,
    expected_version bigint,
    PRIMARY KEY (job_name, run_id, file_index, ordinal),
    UNIQUE (job_name, run_id, customer_id)
);
CREATE TABLE batch_input_error (
    job_name text NOT NULL,
    run_id text NOT NULL,
    file_index integer NOT NULL,
    ordinal bigint NOT NULL,
    reason text NOT NULL,
    PRIMARY KEY (job_name, run_id, file_index, ordinal)
);
CREATE TABLE batch_input_check (
    job_name text NOT NULL,
    run_id text NOT NULL,
    file_index integer NOT NULL,
    row_count bigint NOT NULL,
    sha256 text NOT NULL,
    PRIMARY KEY (job_name, run_id, file_index)
);
CREATE TABLE batch_input_applied (
    consumer text NOT NULL,
    bucket text NOT NULL,
    object_key text NOT NULL,
    revision text NOT NULL,
    run_id text NOT NULL,
    PRIMARY KEY (consumer, bucket, object_key, revision)
);

CREATE TABLE batch_work_status (
    job_name text NOT NULL,
    run_id text NOT NULL,
    work_kind text NOT NULL,
    state text NOT NULL CHECK (state IN ('PREPARING','READY','APPLIED')),
    PRIMARY KEY (job_name, run_id, work_kind)
);
CREATE TABLE batch_customer_export (
    job_name text NOT NULL,
    run_id text NOT NULL,
    artifact text NOT NULL,
    customer_id bigint NOT NULL,
    member_id bigint NOT NULL,
    name text NOT NULL,
    email text,
    status text NOT NULL,
    updated_at timestamptz NOT NULL,
    version bigint NOT NULL,
    tier text,
    PRIMARY KEY (job_name, run_id, artifact, customer_id, member_id)
);
CREATE TABLE batch_artifact (
    run_id text NOT NULL,
    artifact_id text NOT NULL,
    destination text NOT NULL,
    bucket text NOT NULL,
    object_key text NOT NULL,
    upload_id text,
    row_count bigint,
    size_bytes bigint,
    sha256 text,
    version_id text,
    state text NOT NULL CHECK (state IN ('UPLOADING','EXPECTED','COMPLETE','FAILED')),
    failure text,
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (run_id, artifact_id, destination),
    UNIQUE (bucket, object_key)
);
CREATE TABLE batch_copy_stage (
    job_name text NOT NULL DEFAULT current_setting('batch.job_name'),
    run_id text NOT NULL DEFAULT current_setting('batch.run_id'),
    ordinal bigint GENERATED ALWAYS AS IDENTITY,
    id_text text,
    name text,
    email text,
    status text,
    PRIMARY KEY (job_name, run_id, ordinal)
);
