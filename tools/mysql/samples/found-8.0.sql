-- What the review of PR #169 found no sample proved, for MySQL 8.0 and later, loaded after server-8.0.sql. The Rust
-- round trip (tools/app/mysql.py) loads it; the frozen Python prototype is not asked to.
SET NAMES utf8mb4;
SET sql_mode = 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION';
USE shop;

-- a check and an expression default holding strings (8.0's catalog escapes their quotes)
CREATE TABLE labels (
  id INT NOT NULL,
  state VARCHAR(8) NOT NULL DEFAULT 'live',
  tag VARCHAR(10) NOT NULL DEFAULT (concat('x', '-', 'y')),
  PRIMARY KEY (id),
  CONSTRAINT chk_state CHECK (state IN ('live', 'gone', 'it''s'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- a read-only database holding a view and a procedure: it can only be closed after they are made
CREATE DATABASE frozen_ro CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE TABLE frozen_ro.items (id INT NOT NULL, PRIMARY KEY (id)) ENGINE=InnoDB;
CREATE VIEW frozen_ro.item_ids AS SELECT id FROM frozen_ro.items;
CREATE PROCEDURE frozen_ro.count_items() SELECT COUNT(*) FROM frozen_ro.items;
ALTER DATABASE frozen_ro READ ONLY = 1;

-- (sample-only passwords, strong enough for the validate_password component server-8.0.sql installs)
-- an account that must give its current password to change it, written bare
CREATE USER 'auditor'@'%' IDENTIFIED BY 'Sample-only-4!' PASSWORD REQUIRE CURRENT;
-- an account's attributes holding a backslash, written after programs of other sessions
CREATE USER 'pathy'@'%' IDENTIFIED BY 'Sample-only-5!' ATTRIBUTE '{"home": "C:\\\\ops"}';
