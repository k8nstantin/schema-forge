-- What MySQL 8.0 and later add to the every-object sample (loaded after common.sql): CHECK constraints enforced and
-- not, invisible columns and indexes, functional index parts, expression defaults, a spatial column with its SRID,
-- descending index parts, a database's default encryption and read only.
USE shop;

CREATE TABLE products (
  id INT NOT NULL AUTO_INCREMENT,
  sku VARCHAR(32) NOT NULL,
  price DECIMAL(10,2) NOT NULL,
  discount DECIMAL(10,2) NOT NULL DEFAULT (0),
  added DATE NOT NULL DEFAULT (CURRENT_DATE),
  meta JSON DEFAULT NULL,
  ref BINARY(16) NOT NULL DEFAULT (UUID_TO_BIN(UUID())),
  secret_note VARCHAR(50) DEFAULT NULL /*!80023 INVISIBLE */,
  location POINT NOT NULL /*!80003 SRID 4326 */,
  PRIMARY KEY (id),
  UNIQUE KEY uq_sku (sku),
  KEY ix_price_desc (price DESC, id),
  KEY ix_lower_sku ((LOWER(sku))),
  KEY ix_hidden (discount) /*!80000 INVISIBLE */,
  SPATIAL KEY sx_location (location),
  CONSTRAINT chk_price CHECK (price >= 0),
  CONSTRAINT chk_discount CHECK (discount <= price) /*!80016 NOT ENFORCED */
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE DATABASE archive_ro CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE TABLE archive_ro.frozen (id INT NOT NULL, PRIMARY KEY (id)) ENGINE=InnoDB;
ALTER DATABASE archive_ro READ ONLY = 1;
