-- What the review of PR #169 (SF-156, engine_mysql in Rust) found no sample proved, for every MySQL from 5.7 (loaded
-- after common.sql and the version's own file, by tools/app/mysql.py only): each line is a bug that passed green round
-- trips because nothing here used it. The frozen Python prototype is not asked to load it.
SET NAMES utf8mb4;
SET sql_mode = 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION';

-- a table named like a database: a view reading other.shop must keep the qualifier `other`.`shop`
CREATE DATABASE other CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE TABLE other.shop (id INT UNSIGNED NOT NULL, label VARCHAR(20) DEFAULT NULL, PRIMARY KEY (id)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

USE shop;

CREATE VIEW labelled_customers AS
  SELECT c.id, c.email, s.label FROM customers c JOIN other.shop s ON s.id = c.id;

-- a binary column's literal default (8.0 gives it as hex)
CREATE TABLE codes (
  id INT NOT NULL,
  flag BINARY(2) NOT NULL DEFAULT 'ab',
  PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- a unique key with the same name as a foreign key on the same table
CREATE TABLE order_refs (
  order_id BIGINT NOT NULL,
  ref VARCHAR(20) NOT NULL,
  UNIQUE KEY fk_refs_order (order_id),
  CONSTRAINT fk_refs_order FOREIGN KEY (order_id) REFERENCES orders (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- subpartitions named one by one, partitions and subpartitions with their own options (the server writes the names bare)
CREATE TABLE sales_named (
  id INT NOT NULL,
  sold DATE NOT NULL,
  PRIMARY KEY (id, sold)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
PARTITION BY RANGE (YEAR(sold))
SUBPARTITION BY HASH (id)
(PARTITION p_old VALUES LESS THAN (2024) COMMENT = 'old' (SUBPARTITION s_old_a, SUBPARTITION s_old_b COMMENT = 'second'),
 PARTITION p_new VALUES LESS THAN MAXVALUE (SUBPARTITION s_new_a, SUBPARTITION s_new_b));

-- a MERGE table uniting a table of another database
CREATE TABLE legacy.archive_2018 (
  id INT NOT NULL,
  note VARCHAR(50) DEFAULT NULL,
  KEY ix_id (id)
) ENGINE=MyISAM DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE archive_wide (
  id INT NOT NULL,
  note VARCHAR(50) DEFAULT NULL,
  KEY ix_id (id)
) ENGINE=MRG_MyISAM DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci INSERT_METHOD=NO UNION=(legacy.archive_2018,archive_2019);

DELIMITER $$
-- a view calling a stored function: the function must exist when the view is created
CREATE VIEW customer_spending AS SELECT id, customer_spent(id) AS spent FROM customers$$

-- a program made under NO_BACKSLASH_ESCAPES, its comment and body holding a backslash; what follows it must not inherit it
SET sql_mode = 'NO_BACKSLASH_ESCAPES'$$
CREATE PROCEDURE windows_path() COMMENT 'C:\tmp' SELECT 'C:\tmp' AS path$$
SET sql_mode = 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION'$$
DELIMITER ;
