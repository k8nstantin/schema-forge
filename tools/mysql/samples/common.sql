-- The every-object sample every MySQL from 5.7 loads: databases, tables of every storage engine and every table
-- option, every kind of column, key and index, partitioning of every method, views, procedures, functions, triggers
-- and events, each with the options its statement writes. tools/mysql/roundtrip.py reads it from a server, stores it,
-- writes it back into a fresh server of the same version, and reads it again: nothing may differ.
SET NAMES utf8mb4;
SET time_zone = '+00:00';
SET sql_mode = 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION';

CREATE DATABASE shop CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE legacy CHARACTER SET latin1 COLLATE latin1_swedish_ci;
USE shop;

CREATE TABLE customers (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'the customer',
  email VARCHAR(191) NOT NULL,
  name VARCHAR(100) CHARACTER SET latin1 COLLATE latin1_bin DEFAULT NULL,
  status ENUM('new','active','gone') NOT NULL DEFAULT 'new',
  tags SET('vip','wholesale','test') DEFAULT NULL,
  balance DECIMAL(12,2) NOT NULL DEFAULT '0.00',
  rating FLOAT(7,3) DEFAULT NULL,
  code INT(6) UNSIGNED ZEROFILL DEFAULT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  notes TEXT,
  email_domain VARCHAR(191) GENERATED ALWAYS AS (substring_index(email, '@', -1)) VIRTUAL,
  name_upper VARCHAR(100) GENERATED ALWAYS AS (upper(name)) STORED,
  PRIMARY KEY (id),
  UNIQUE KEY uq_email (email),
  KEY ix_name_prefix (name(20)),
  KEY ix_status_created (status, created_at DESC),
  FULLTEXT KEY ft_notes (notes)
) ENGINE=InnoDB AUTO_INCREMENT=1001 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC STATS_PERSISTENT=1 STATS_SAMPLE_PAGES=32 COMMENT='who buys';

CREATE TABLE orders (
  id BIGINT NOT NULL AUTO_INCREMENT,
  customer_id INT UNSIGNED NOT NULL,
  placed_at DATETIME NOT NULL,
  total DECIMAL(14,2) NOT NULL,
  PRIMARY KEY (id),
  KEY ix_customer (customer_id),
  CONSTRAINT fk_orders_customer FOREIGN KEY (customer_id) REFERENCES customers (id) ON DELETE CASCADE ON UPDATE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE order_lines (
  order_id BIGINT NOT NULL,
  line SMALLINT NOT NULL,
  sku CHAR(12) NOT NULL,
  qty INT NOT NULL DEFAULT '1',
  PRIMARY KEY (order_id, line),
  CONSTRAINT fk_lines_order FOREIGN KEY (order_id) REFERENCES orders (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci KEY_BLOCK_SIZE=8 ROW_FORMAT=COMPRESSED;

CREATE TABLE places (
  id INT NOT NULL AUTO_INCREMENT,
  pos POINT NOT NULL,
  PRIMARY KEY (id),
  SPATIAL KEY sx_pos (pos)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE sales (
  id INT NOT NULL,
  sold DATE NOT NULL,
  region VARCHAR(8) NOT NULL,
  amount DECIMAL(10,2) DEFAULT NULL,
  PRIMARY KEY (id, sold)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
PARTITION BY RANGE (YEAR(sold))
SUBPARTITION BY HASH (id) SUBPARTITIONS 2
(PARTITION p2023 VALUES LESS THAN (2024) COMMENT = 'last year',
 PARTITION p2024 VALUES LESS THAN (2025),
 PARTITION pmax VALUES LESS THAN MAXVALUE);

CREATE TABLE regions (
  code VARCHAR(8) NOT NULL,
  name VARCHAR(40) NOT NULL,
  PRIMARY KEY (code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
PARTITION BY LIST COLUMNS (code)
(PARTITION p_east VALUES IN ('NE','SE'),
 PARTITION p_west VALUES IN ('NW','SW'));

CREATE TABLE events_log (
  id BIGINT NOT NULL,
  happened DATETIME NOT NULL,
  PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
PARTITION BY HASH (id) PARTITIONS 4;

CREATE TABLE keyed (
  k VARCHAR(16) NOT NULL,
  PRIMARY KEY (k)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
PARTITION BY KEY ALGORITHM = 2 (k) PARTITIONS 3;

CREATE TABLE archive_2019 (
  id INT NOT NULL,
  note VARCHAR(50) DEFAULT NULL,
  KEY ix_id (id)
) ENGINE=MyISAM DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci PACK_KEYS=1 CHECKSUM=1 DELAY_KEY_WRITE=1 MAX_ROWS=100000 MIN_ROWS=10 AVG_ROW_LENGTH=60;

CREATE TABLE archive_2020 LIKE archive_2019;

CREATE TABLE archive_all (
  id INT NOT NULL,
  note VARCHAR(50) DEFAULT NULL,
  KEY ix_id (id)
) ENGINE=MRG_MyISAM DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci INSERT_METHOD=LAST UNION=(archive_2019,archive_2020);

CREATE TABLE session_cache (
  k VARCHAR(64) NOT NULL,
  v VARCHAR(255) DEFAULT NULL,
  PRIMARY KEY (k) USING HASH
) ENGINE=MEMORY DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE audit_trail (
  id INT NOT NULL,
  what VARCHAR(200) DEFAULT NULL
) ENGINE=ARCHIVE DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE export_rows (
  id INT NOT NULL,
  line VARCHAR(200) NOT NULL
) ENGINE=CSV DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE sink (
  id INT DEFAULT NULL
) ENGINE=BLACKHOLE DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE ALGORITHM=MERGE SQL SECURITY INVOKER VIEW active_customers AS
  SELECT id, email, name FROM customers WHERE status = 'active' WITH CASCADED CHECK OPTION;

CREATE ALGORITHM=TEMPTABLE VIEW customer_totals AS
  SELECT c.id, c.email, SUM(o.total) AS spent FROM customers c JOIN orders o ON o.customer_id = c.id GROUP BY c.id, c.email;

DELIMITER $$
CREATE PROCEDURE place_order(IN p_customer INT UNSIGNED, IN p_total DECIMAL(14,2), OUT p_id BIGINT)
  MODIFIES SQL DATA
  COMMENT 'places an order'
BEGIN
  INSERT INTO orders (customer_id, placed_at, total) VALUES (p_customer, NOW(), p_total);
  SET p_id = LAST_INSERT_ID();
END$$

CREATE FUNCTION customer_spent(p_customer INT UNSIGNED) RETURNS DECIMAL(14,2)
  DETERMINISTIC READS SQL DATA SQL SECURITY INVOKER
BEGIN
  RETURN (SELECT COALESCE(SUM(total), 0) FROM orders WHERE customer_id = p_customer);
END$$

CREATE TRIGGER orders_before_insert BEFORE INSERT ON orders FOR EACH ROW
BEGIN
  IF NEW.total < 0 THEN SET NEW.total = 0; END IF;
END$$

CREATE TRIGGER orders_before_insert_2 BEFORE INSERT ON orders FOR EACH ROW FOLLOWS orders_before_insert
  SET NEW.placed_at = COALESCE(NEW.placed_at, NOW())$$

CREATE TRIGGER customers_after_update AFTER UPDATE ON customers FOR EACH ROW
  INSERT INTO audit_trail (id, what) VALUES (NEW.id, 'updated')$$

CREATE EVENT purge_sessions ON SCHEDULE EVERY 1 DAY STARTS '2030-01-01 03:00:00' ENDS '2031-01-01 00:00:00'
  ON COMPLETION PRESERVE ENABLE COMMENT 'clears the cache'
  DO DELETE FROM session_cache$$

CREATE EVENT one_off ON SCHEDULE AT '2030-06-01 00:00:00' ON COMPLETION NOT PRESERVE DISABLE
  DO DELETE FROM sink$$
DELIMITER ;

USE legacy;

CREATE TABLE notes (
  id INT NOT NULL AUTO_INCREMENT,
  body VARCHAR(255) DEFAULT NULL,
  PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=latin1;
