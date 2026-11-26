-- MySQL sample: one of each object kind and table option, MySQL 5.7 and later.
CREATE DATABASE features DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE TABLE features.kinds (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'the row',
  tiny TINYINT(1) NOT NULL DEFAULT 0,
  small SMALLINT ZEROFILL,
  money DECIMAL(18,4) NOT NULL DEFAULT 0.0000,
  ratio DOUBLE,
  born DATE, seen DATETIME(6) DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6), stamp TIMESTAMP NULL,
  yr YEAR, t TIME(3),
  name VARCHAR(100) CHARACTER SET latin1 COLLATE latin1_swedish_ci NOT NULL,
  note TEXT, blob_ BLOB, bits BIT(8),
  status ENUM('new','paid','shipped') NOT NULL DEFAULT 'new',
  flags SET('a','b','c'),
  doc JSON,
  shape GEOMETRY NOT NULL,
  name_upper VARCHAR(100) AS (UPPER(name)) VIRTUAL,
  money_cents BIGINT AS (money * 100) STORED,
  PRIMARY KEY (id),
  UNIQUE KEY uk_name (name),
  KEY k_status_seen (status, seen),
  KEY k_note (note(20)),
  FULLTEXT KEY ft_note (note),
  SPATIAL KEY sp_shape (shape)
) ENGINE=InnoDB AUTO_INCREMENT=1000 ROW_FORMAT=DYNAMIC COMMENT='every column type';
CREATE TABLE features.parent (id INT PRIMARY KEY, code CHAR(3) NOT NULL, UNIQUE KEY uk_code (code)) ENGINE=InnoDB;
CREATE TABLE features.child (
  id INT PRIMARY KEY, parent_id INT, parent_code CHAR(3),
  CONSTRAINT fk_parent FOREIGN KEY (parent_id) REFERENCES features.parent (id) ON DELETE CASCADE ON UPDATE SET NULL,
  CONSTRAINT fk_code FOREIGN KEY (parent_code) REFERENCES features.parent (code) ON DELETE RESTRICT
) ENGINE=InnoDB;
CREATE TABLE features.by_range (id INT NOT NULL, d DATE NOT NULL, PRIMARY KEY (id, d))
  PARTITION BY RANGE (YEAR(d)) (PARTITION p2024 VALUES LESS THAN (2025), PARTITION p2025 VALUES LESS THAN (2026), PARTITION pmax VALUES LESS THAN MAXVALUE);
CREATE TABLE features.by_list (id INT NOT NULL, region INT NOT NULL, PRIMARY KEY (id, region))
  PARTITION BY LIST (region) (PARTITION p_east VALUES IN (1,2), PARTITION p_west VALUES IN (3,4));
CREATE TABLE features.by_hash (id INT NOT NULL PRIMARY KEY) PARTITION BY HASH (id) PARTITIONS 4;
CREATE TABLE features.by_key_sub (id INT NOT NULL, d DATE NOT NULL, PRIMARY KEY (id, d))
  PARTITION BY RANGE (YEAR(d)) SUBPARTITION BY HASH (id) SUBPARTITIONS 2 (PARTITION a VALUES LESS THAN (2025), PARTITION b VALUES LESS THAN MAXVALUE);
CREATE TABLE features.myisam_log (id INT PRIMARY KEY, msg VARCHAR(200)) ENGINE=MyISAM CHECKSUM=1 DELAY_KEY_WRITE=1 PACK_KEYS=1;
CREATE TABLE features.merged (id INT PRIMARY KEY, msg VARCHAR(200)) ENGINE=MRG_MyISAM UNION=(features.myisam_log) INSERT_METHOD=LAST;
CREATE ALGORITHM=MERGE SQL SECURITY INVOKER VIEW features.v_paid AS SELECT id, name FROM features.kinds WHERE status = 'paid' WITH CASCADED CHECK OPTION;
CREATE ALGORITHM=TEMPTABLE VIEW features.v_by_status AS SELECT status, COUNT(*) AS n FROM features.kinds GROUP BY status;
CREATE VIEW features.v_join AS SELECT c.id, p.code FROM features.child c JOIN features.parent p ON p.id = c.parent_id;
DELIMITER //
CREATE PROCEDURE features.p_count(IN p_status VARCHAR(10), OUT p_n INT, INOUT p_seen INT)
  COMMENT 'counts rows' READS SQL DATA SQL SECURITY INVOKER
BEGIN
  SELECT COUNT(*) INTO p_n FROM features.kinds WHERE status = p_status;
  SET p_seen = p_seen + 1;
END//
CREATE PROCEDURE features.p_purge(IN p_before INT) MODIFIES SQL DATA
  DELETE FROM features.myisam_log WHERE id < p_before//
CREATE FUNCTION features.f_cents(m DECIMAL(18,4)) RETURNS BIGINT DETERMINISTIC NO SQL
RETURN m * 100//
CREATE TRIGGER features.t_child_bi BEFORE INSERT ON features.child FOR EACH ROW SET NEW.parent_code = UPPER(NEW.parent_code)//
CREATE TRIGGER features.t_child_bi2 BEFORE INSERT ON features.child FOR EACH ROW FOLLOWS t_child_bi SET NEW.id = NEW.id//
CREATE EVENT features.e_purge ON SCHEDULE EVERY 1 DAY STARTS '2030-01-01 00:00:00' ON COMPLETION PRESERVE DISABLE
  COMMENT 'nightly' DO DELETE FROM features.myisam_log WHERE id < 0//
DELIMITER ;
