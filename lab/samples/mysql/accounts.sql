-- Accounts and what they may do, MySQL 5.7 and later: an application account with limits, a locked read-only one, a
-- grant at every level (the server, a database, a table, a column, a routine), a view and a routine whose definer is an
-- account the server holds, and a routine whose definer is an account that is gone. No account has a password.
CREATE USER 'lab_app'@'%' WITH MAX_USER_CONNECTIONS 5 MAX_QUERIES_PER_HOUR 1000;
CREATE USER 'lab_ro'@'10.%' ACCOUNT LOCK;
GRANT PROCESS ON *.* TO 'lab_app'@'%';
GRANT SELECT, SHOW VIEW ON features.* TO 'lab_ro'@'10.%';
GRANT SELECT, INSERT ON features.parent TO 'lab_app'@'%' WITH GRANT OPTION;
GRANT UPDATE (name) ON features.kinds TO 'lab_app'@'%';
GRANT EXECUTE ON PROCEDURE features.p_count TO 'lab_app'@'%';
CREATE DEFINER='lab_app'@'%' SQL SECURITY DEFINER VIEW features.v_by_app AS SELECT id, code FROM features.parent;
DELIMITER //
CREATE DEFINER='lab_app'@'%' PROCEDURE features.p_as_app() READS SQL DATA SELECT COUNT(*) FROM features.parent//
CREATE DEFINER='lab_gone'@'%' PROCEDURE features.p_orphan() READS SQL DATA SELECT 1//
DELIMITER ;
