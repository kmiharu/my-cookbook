CREATE TABLE products (
    id uuid PRIMARY KEY,
    name varchar(120) NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 120),
    category varchar(40) NOT NULL CHECK (category ~ '^[a-z0-9][a-z0-9-]{0,39}$'),
    price_minor bigint NOT NULL CHECK (price_minor BETWEEN 0 AND 999999999),
    status varchar(8) NOT NULL CHECK (status IN ('ACTIVE', 'INACTIVE')),
    version bigint NOT NULL CHECK (version > 0),
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    deleted boolean NOT NULL DEFAULT false
);

CREATE INDEX products_listing_idx
    ON products (created_at DESC, id DESC) WHERE NOT deleted;
CREATE INDEX products_category_listing_idx
    ON products (category, created_at DESC, id DESC) WHERE NOT deleted;
