CREATE TABLE cookbook.csv_patch_reviews (
    review_id uuid PRIMARY KEY
);

CREATE TABLE cookbook.csv_patch_review_rows (
    review_id uuid NOT NULL REFERENCES cookbook.csv_patch_reviews ON DELETE CASCADE,
    id bigint NOT NULL,
    old_value text NOT NULL,
    new_value text NOT NULL,
    PRIMARY KEY (review_id, id)
);
