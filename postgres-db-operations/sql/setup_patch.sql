CREATE TABLE cookbook.batch_patch_run (
    singleton boolean PRIMARY KEY CHECK (singleton)
);

CREATE TABLE cookbook.batch_patch_targets (
    id bigint PRIMARY KEY
);
