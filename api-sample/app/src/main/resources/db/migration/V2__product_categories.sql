-- The common API permits any valid category code. The optional master enriches SQL searches.
CREATE TABLE product_categories (
    code varchar(40) PRIMARY KEY,
    display_name varchar(120) NOT NULL
);

INSERT INTO product_categories (code, display_name) VALUES
    ('books', 'Books'),
    ('food', 'Food'),
    ('tools', 'Tools');
