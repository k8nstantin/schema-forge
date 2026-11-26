-- The live read's sample (specs/tasks/SF-121-mysql-live.xml): a small shop every MySQL from 5.7 takes as written, with
-- a view, a procedure, a trigger and an event, an index the workload never reads, and a few rows.
CREATE DATABASE shop;
CREATE TABLE shop.customers (
  id INT PRIMARY KEY AUTO_INCREMENT,
  email VARCHAR(100) NOT NULL,
  country CHAR(2),
  created DATETIME,
  UNIQUE KEY uk_email (email),
  KEY k_country (country),
  KEY k_created_unused (created)
) ENGINE=InnoDB;
CREATE TABLE shop.products (
  id INT PRIMARY KEY AUTO_INCREMENT,
  sku VARCHAR(20) NOT NULL,
  price DECIMAL(10,2),
  UNIQUE KEY uk_sku (sku)
) ENGINE=InnoDB;
CREATE TABLE shop.orders (
  id INT PRIMARY KEY AUTO_INCREMENT,
  customer_id INT NOT NULL,
  placed DATETIME,
  status VARCHAR(10),
  KEY k_status (status),
  CONSTRAINT fk_cust FOREIGN KEY (customer_id) REFERENCES shop.customers (id)
) ENGINE=InnoDB;
CREATE TABLE shop.order_items (
  order_id INT,
  product_id INT,
  qty INT,
  PRIMARY KEY (order_id, product_id),
  CONSTRAINT fk_o FOREIGN KEY (order_id) REFERENCES shop.orders (id),
  CONSTRAINT fk_p FOREIGN KEY (product_id) REFERENCES shop.products (id)
) ENGINE=InnoDB;
CREATE VIEW shop.big_orders AS SELECT o.id, c.email FROM shop.orders o JOIN shop.customers c ON c.id = o.customer_id;
CREATE PROCEDURE shop.paid_orders() SELECT id FROM shop.orders WHERE status = 'paid';
CREATE TRIGGER shop.orders_status BEFORE INSERT ON shop.orders FOR EACH ROW SET NEW.status = COALESCE(NEW.status, 'new');
CREATE EVENT shop.nightly ON SCHEDULE EVERY 1 DAY DO DELETE FROM shop.order_items WHERE qty = 0;
INSERT INTO shop.customers (email, country, created) VALUES ('a@x.io','US',NOW()),('b@x.io','DE',NOW()),('c@x.io','US',NOW()),('d@x.io','FR',NOW());
INSERT INTO shop.products (sku, price) VALUES ('S1',10),('S2',20),('S3',30);
INSERT INTO shop.orders (customer_id, placed, status) VALUES (1,NOW(),'new'),(2,NOW(),'paid'),(1,NOW(),'paid'),(3,NOW(),'new');
INSERT INTO shop.order_items VALUES (1,1,2),(1,2,1),(2,3,5),(3,1,1),(4,2,2);
