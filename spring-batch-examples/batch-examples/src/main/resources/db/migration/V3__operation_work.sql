CREATE TABLE batch_operation_work (
    job_name text NOT NULL,
    run_id text NOT NULL,
    id bigint NOT NULL,
    name text NOT NULL,
    email text,
    status text NOT NULL,
    updated_at timestamptz NOT NULL,
    version bigint NOT NULL,
    detail text,
    applied boolean NOT NULL DEFAULT false,
    PRIMARY KEY (job_name, run_id, id)
);

CREATE TABLE batch_customer_totals (
    period text NOT NULL CHECK (period IN ('day', 'month')),
    bucket_date date NOT NULL,
    status text NOT NULL,
    customer_count bigint NOT NULL CHECK (customer_count > 0),
    PRIMARY KEY (period, bucket_date, status)
);

CREATE TABLE batch_patch_plan (
    plan_id text PRIMARY KEY,
    patch_id text NOT NULL,
    preview_run text NOT NULL,
    definition text NOT NULL,
    expected_rows bigint NOT NULL CHECK (expected_rows >= 0),
    state text NOT NULL CHECK (state IN ('PREVIEWED', 'APPLYING', 'APPLIED', 'RESTORING', 'RESTORED')),
    apply_run text,
    restore_run text,
    mode text,
    created_at timestamptz NOT NULL DEFAULT transaction_timestamp()
);

CREATE TABLE batch_patch_claim (
    patch_id text PRIMARY KEY,
    plan_id text NOT NULL REFERENCES batch_patch_plan(plan_id)
);

CREATE TABLE batch_patch_row (
    plan_id text NOT NULL REFERENCES batch_patch_plan(plan_id),
    id bigint NOT NULL,
    old_status text NOT NULL,
    new_status text NOT NULL,
    old_version bigint NOT NULL,
    applied_version bigint,
    restored_version bigint,
    PRIMARY KEY (plan_id, id)
);

CREATE TABLE batch_watermark (
    watermark_id text PRIMARY KEY,
    next_lower timestamptz NOT NULL
);

CREATE TABLE batch_watermark_run (
    job_name text NOT NULL,
    run_id text NOT NULL,
    watermark_id text NOT NULL REFERENCES batch_watermark(watermark_id),
    lower_bound timestamptz NOT NULL,
    upper_bound timestamptz NOT NULL,
    PRIMARY KEY (job_name, run_id)
);

CREATE TABLE batch_operation_cleanup (
    job_name text NOT NULL,
    run_id text NOT NULL,
    removed_rows bigint NOT NULL,
    PRIMARY KEY (job_name, run_id)
);
