-- MySQL 8.4 schema, written by Schema Forge
SET FOREIGN_KEY_CHECKS = 0;

CREATE DATABASE `default`;
USE `default`;

CREATE TABLE `widgets` (
  `id` int NOT NULL AUTO_INCREMENT,
  `sku` varchar(32),
  `maker_id` int REFERENCES `makers` (`id`),
  `warehouse_id` int,
  `price` decimal(10,2) NOT NULL DEFAULT 0,
  PRIMARY KEY (`id`),
  UNIQUE KEY (`sku`),
  KEY `widgets_price` (`price` DESC) COMMENT 'cheapest last',
  FOREIGN KEY (warehouse_id) REFERENCES inventory.warehouses (id),
  CHECK (price >= 0)
) ENGINE=InnoDB;

CREATE TABLE `makers` (
  `id` int NOT NULL,
  `name` varchar(100) NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `makers_name` (`name`)
);

CREATE VIEW `cheap` AS SELECT id, sku, price FROM widgets WHERE price < 10;

ALTER TABLE widgets ADD COLUMN colour varchar(20);

CREATE USER 'reporter'@'%' ACCOUNT LOCK;

GRANT SELECT ON `default`.* TO 'reporter'@'%';

CREATE RESOURCE GROUP batch TYPE = USER VCPU = 0 THREAD_PRIORITY = 10;

CREATE SERVER remote FOREIGN DATA WRAPPER mysql OPTIONS (HOST 'db.example', DATABASE 'shop', USER 'reader');

SET FOREIGN_KEY_CHECKS = 1;
