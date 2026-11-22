-- MySQL 8.0 schema, written by Schema Forge
SET FOREIGN_KEY_CHECKS = 0;

CREATE DATABASE `shop` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE `shop`;

CREATE TABLESPACE `shop_space` ADD DATAFILE 'shop_space.ibd' ENGINE=InnoDB;

CREATE TABLE `customers` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `email` varchar(255) NOT NULL COMMENT 'Unique, lowercased',
  `name` varchar(200) NOT NULL,
  `code` char(8) CHARACTER SET ascii COLLATE ascii_bin DEFAULT NULL,
  `status` enum('new','active','closed') NOT NULL DEFAULT 'new',
  `tags` set('vip','wholesale','test') DEFAULT NULL,
  `profile` json DEFAULT NULL,
  `balance` decimal(18,2) NOT NULL DEFAULT '0.00',
  `score` double DEFAULT NULL,
  `rating` float DEFAULT NULL,
  `flags` bit(8) DEFAULT NULL,
  `avatar` mediumblob,
  `note` text,
  `bio` longtext,
  `birth` date DEFAULT NULL,
  `wake` time(3) DEFAULT NULL,
  `seen` datetime(6) DEFAULT NULL,
  `born` year DEFAULT NULL,
  `active` tinyint(1) NOT NULL DEFAULT '1',
  `tiny` tinyint DEFAULT NULL,
  `small` smallint unsigned DEFAULT NULL,
  `medium` mediumint DEFAULT NULL,
  `raw` varbinary(64) DEFAULT NULL,
  `fixed_raw` binary(16) DEFAULT NULL,
  `location` point NOT NULL SRID 4326,
  `area` polygon DEFAULT NULL,
  `created_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `email_domain` varchar(255) GENERATED ALWAYS AS (substring_index(email, '@', -1)) VIRTUAL,
  `name_upper` varchar(200) GENERATED ALWAYS AS (upper(name)) STORED,
  `secret` varchar(64) DEFAULT NULL INVISIBLE,
  `uid` binary(16) NOT NULL DEFAULT (uuid_to_bin(uuid())),
  PRIMARY KEY (`id`),
  UNIQUE KEY `customers_email` (`email`),
  KEY `customers_name_prefix` (`name`(20)),
  KEY `customers_seen_desc` (`seen` DESC),
  KEY `customers_lower_email` ((lower(email))),
  KEY `customers_status_hidden` (`status`) INVISIBLE,
  FULLTEXT KEY `customers_note_text` (`note`) WITH PARSER `ngram`,
  SPATIAL KEY `customers_location` (`location`),
  CONSTRAINT `customers_balance_positive` CHECK (balance >= 0)
) ENGINE=InnoDB AUTO_INCREMENT=1000 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci STATS_PERSISTENT=1 ROW_FORMAT=DYNAMIC COMMENT='People who order';

CREATE TABLE `orders` (
  `order_id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `customer_id` bigint unsigned NOT NULL,
  `placed_at` datetime NOT NULL,
  `total` decimal(12,2) NOT NULL,
  `currency` char(3) NOT NULL DEFAULT 'EUR',
  PRIMARY KEY (`order_id`),
  KEY `orders_customer_placed` (`customer_id`,`placed_at`) COMMENT 'For a customer''s history',
  CONSTRAINT `orders_customer` FOREIGN KEY (`customer_id`) REFERENCES `customers` (`id`) ON DELETE CASCADE ON UPDATE RESTRICT,
  CONSTRAINT `orders_total_sane` CHECK (total < 1000000) NOT ENFORCED
) TABLESPACE `shop_space` ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE `events_log` (
  `id` bigint NOT NULL,
  `happened` datetime NOT NULL,
  `kind` varchar(20) NOT NULL,
  PRIMARY KEY (`id`,`happened`)
) ENGINE=InnoDB
PARTITION BY RANGE (YEAR(happened))
(PARTITION `p2024` VALUES LESS THAN (2025) COMMENT = 'last year',
 PARTITION `p2025` VALUES LESS THAN (2026),
 PARTITION `pmax` VALUES LESS THAN MAXVALUE);

CREATE TABLE `regions` (
  `region` varchar(10) NOT NULL,
  `amount` int NOT NULL
) ENGINE=InnoDB
PARTITION BY LIST COLUMNS (`region`)
(PARTITION `eu` VALUES IN ('de','fr'),
 PARTITION `us` VALUES IN ('us','ca'));

CREATE TABLE `metrics` (
  `id` int NOT NULL,
  `taken` date NOT NULL,
  `value` double NOT NULL,
  PRIMARY KEY (`id`,`taken`)
) ENGINE=InnoDB
PARTITION BY RANGE (TO_DAYS(taken))
SUBPARTITION BY HASH (id)
SUBPARTITIONS 2
(PARTITION `m2025` VALUES LESS THAN (TO_DAYS('2026-01-01')),
 PARTITION `mrest` VALUES LESS THAN MAXVALUE);

CREATE TABLE `sessions` (
  `token` varchar(64) NOT NULL,
  `started` datetime NOT NULL,
  PRIMARY KEY (`token`)
) ENGINE=InnoDB
PARTITION BY LINEAR KEY (`token`)
PARTITIONS 4;

CREATE TABLE `cache_entries` (
  `k` varchar(64) NOT NULL,
  `v` blob,
  `hits` int unsigned zerofill DEFAULT NULL,
  PRIMARY KEY (`k`)
) ENGINE=MyISAM DEFAULT CHARSET=latin1 CHECKSUM=1 PACK_KEYS=1;

CREATE ALGORITHM=MERGE SQL SECURITY INVOKER VIEW `big_orders` AS SELECT order_id, customer_id, total FROM orders WHERE total > 100 WITH CASCADED CHECK OPTION;

CREATE VIEW `customer_totals` (`customer`,`orders`,`spent`) AS SELECT c.name, COUNT(o.order_id), SUM(o.total) FROM customers c LEFT JOIN orders o ON o.customer_id = c.id
  GROUP BY c.name;

DELIMITER ;;
CREATE PROCEDURE `close_customer`(IN `p_id` bigint unsigned, OUT `p_orders` int)
    MODIFIES SQL DATA
    SQL SECURITY INVOKER
    COMMENT 'Closes a customer and counts their orders'
BEGIN
  UPDATE customers SET status = 'closed' WHERE id = p_id;
  SELECT COUNT(*) INTO p_orders FROM orders WHERE customer_id = p_id;
END ;;
DELIMITER ;

DELIMITER ;;
CREATE FUNCTION `with_tax`(`amount` decimal(12,2)) RETURNS decimal(12,2)
    NO SQL
    DETERMINISTIC
RETURN amount * 1.2 ;;
DELIMITER ;

DELIMITER ;;
CREATE TRIGGER `orders_currency` BEFORE INSERT ON `orders` FOR EACH ROW BEGIN
  IF NEW.currency = '' THEN SET NEW.currency = 'EUR'; END IF;
END ;;
DELIMITER ;

DELIMITER ;;
CREATE TRIGGER `orders_total` BEFORE INSERT ON `orders` FOR EACH ROW FOLLOWS `orders_currency` SET NEW.total = ROUND(NEW.total, 2) ;;
DELIMITER ;

DELIMITER ;;
CREATE TRIGGER `customers_seen` AFTER UPDATE ON `customers` FOR EACH ROW INSERT INTO events_log (id, happened, kind) VALUES (NEW.id, NOW(), 'seen') ;;
DELIMITER ;

DELIMITER ;;
CREATE EVENT `purge_old_events` ON SCHEDULE EVERY 1 DAY STARTS '2027-01-01 03:00:00' ON COMPLETION PRESERVE DISABLE COMMENT 'Keeps two years of events' DO DELETE FROM events_log WHERE happened < NOW() - INTERVAL 2 YEAR ;;
DELIMITER ;

DELIMITER ;;
CREATE EVENT `once_cleanup` ON SCHEDULE AT '2030-01-01 00:00:00' ON COMPLETION NOT PRESERVE ENABLE DO DELETE FROM sessions ;;
DELIMITER ;

CREATE SPATIAL REFERENCE SYSTEM 900001 NAME 'shop wgs 84' DEFINITION 'GEOGCS["shop wgs 84",DATUM["World Geodetic System 1984",SPHEROID["WGS 84",6378137,298.257223563,AUTHORITY["EPSG","7030"]],AUTHORITY["EPSG","6326"]],PRIMEM["Greenwich",0,AUTHORITY["EPSG","8901"]],UNIT["degree",0.017453292519943278,AUTHORITY["EPSG","9122"]],AXIS["Lat",NORTH],AXIS["Lon",EAST]]' DESCRIPTION 'WGS 84 under the shop''s own id';

SET FOREIGN_KEY_CHECKS = 1;
