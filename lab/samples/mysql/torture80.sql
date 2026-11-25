-- What MySQL has from 8.0 on: CHECK constraints, expression index parts, invisible columns and indexes, descending
-- parts, expression defaults, multi-valued JSON indexes.
CREATE TABLE torture.modern (
  id INT PRIMARY KEY,
  qty INT NOT NULL DEFAULT (1),
  price DECIMAL(10,2) NOT NULL,
  secret VARCHAR(40) INVISIBLE,
  tags JSON,
  created DATETIME NOT NULL DEFAULT (NOW()),
  CONSTRAINT ck_qty CHECK (qty > 0),
  CONSTRAINT ck_price CHECK (price >= 0) NOT ENFORCED,
  KEY k_lower ((LOWER(secret))),
  KEY k_desc (created DESC, id),
  KEY k_hidden (price) INVISIBLE,
  KEY k_tags ((CAST(tags->'$[*]' AS UNSIGNED ARRAY)))
) ENGINE=InnoDB;
