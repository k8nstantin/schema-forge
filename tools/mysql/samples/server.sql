-- The server's own objects, for every MySQL from 5.7 (loaded after common.sql): accounts with their limits and
-- policies (their passwords are never read: the reader keeps the plugin alone), grants at every level, a general
-- tablespace holding a table, a FEDERATED server (its password never kept), and a loadable function from a library
-- every server image ships.
CREATE USER 'app'@'%' IDENTIFIED BY 'not-kept-1' REQUIRE SSL WITH MAX_QUERIES_PER_HOUR 5000 MAX_USER_CONNECTIONS 20 PASSWORD EXPIRE INTERVAL 90 DAY;
CREATE USER 'report'@'10.0.%' IDENTIFIED BY 'not-kept-2' ACCOUNT LOCK;
GRANT SELECT, INSERT, UPDATE, DELETE ON shop.* TO 'app'@'%' WITH GRANT OPTION;
GRANT SELECT (email, name), UPDATE (name) ON shop.customers TO 'report'@'10.0.%';
GRANT EXECUTE ON PROCEDURE shop.place_order TO 'app'@'%';
GRANT EXECUTE ON FUNCTION shop.customer_spent TO 'report'@'10.0.%';
GRANT PROCESS ON *.* TO 'report'@'10.0.%';
GRANT SELECT ON legacy.notes TO 'report'@'10.0.%';

CREATE TABLESPACE ts_shop ADD DATAFILE 'ts_shop.ibd' ENGINE=InnoDB;
CREATE TABLE shop.in_tablespace (id INT NOT NULL, PRIMARY KEY (id)) TABLESPACE ts_shop ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE SERVER fed_shop FOREIGN DATA WRAPPER mysql OPTIONS (HOST '127.0.0.1', PORT 3306, DATABASE 'shop', USER 'app');

CREATE FUNCTION service_get_read_locks RETURNS INTEGER SONAME 'locking_service.so';
