-- What came after 8.4, loaded after source.sql into 9.7 and later only.
USE shop;

CREATE TABLE embeddings (
  id bigint NOT NULL,
  customer_id bigint unsigned NOT NULL REFERENCES customers (id),
  embedding vector(8) NOT NULL,
  PRIMARY KEY (id)
) ENGINE=InnoDB;
