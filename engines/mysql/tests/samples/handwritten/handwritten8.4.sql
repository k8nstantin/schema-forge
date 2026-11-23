# Hand-written MySQL 8.4 DDL: what a person writes, and a dump never does. No database is named, so the tables go
# in one called `default`.
DROP TABLE IF EXISTS widgets;
CREATE TABLE widgets (
  id int PRIMARY KEY AUTO_INCREMENT,
  sku varchar(32) UNIQUE,
  maker_id int REFERENCES makers (id),            -- parsed and ignored by MySQL 8.4: a link it does not enforce
  warehouse_id int,
  price decimal(10,2) NOT NULL DEFAULT 0 CHECK (price >= 0),
  CONSTRAINT widgets_warehouse FOREIGN KEY (warehouse_id) REFERENCES inventory.warehouses (id)
) ENGINE=InnoDB;
CREATE TABLE makers (id int NOT NULL, name varchar(100) NOT NULL, PRIMARY KEY (id));
CREATE UNIQUE INDEX makers_name ON makers (name);
CREATE INDEX widgets_price ON widgets (price DESC) COMMENT 'cheapest last';
CREATE OR REPLACE VIEW cheap AS SELECT id, sku FROM widgets WHERE price < 10;
CREATE OR REPLACE VIEW cheap AS SELECT id, sku, price FROM widgets WHERE price < 10;
ALTER TABLE widgets ADD COLUMN colour varchar(20);
CREATE USER 'reporter'@'%' IDENTIFIED BY 'not-a-real-password';
GRANT SELECT ON `default`.* TO 'reporter'@'%';
CREATE RESOURCE GROUP batch TYPE = USER VCPU = 0 THREAD_PRIORITY = 10;
CREATE SERVER remote FOREIGN DATA WRAPPER mysql OPTIONS (HOST 'db.example', DATABASE 'shop', USER 'reader');
INSERT INTO makers VALUES (1, 'Acme');
