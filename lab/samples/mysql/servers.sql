-- What the server holds beside its databases, MySQL 5.7 and later: general tablespaces (one compressed) with tables in
-- them, a table in the system tablespace, and a loadable function from a library every image ships.
CREATE TABLESPACE ts_shared ADD DATAFILE 'ts_shared.ibd' ENGINE = InnoDB;
CREATE TABLESPACE ts_small ADD DATAFILE 'ts_small.ibd' FILE_BLOCK_SIZE = 8192 ENGINE = InnoDB;
CREATE TABLE features.in_shared (id INT PRIMARY KEY, note VARCHAR(40)) TABLESPACE ts_shared;
CREATE TABLE features.in_small (id INT PRIMARY KEY) TABLESPACE ts_small ROW_FORMAT=COMPRESSED KEY_BLOCK_SIZE=8;
CREATE TABLE features.in_system (id INT PRIMARY KEY) TABLESPACE innodb_system;
CREATE FUNCTION keyring_key_fetch RETURNS STRING SONAME 'keyring_udf.so';
